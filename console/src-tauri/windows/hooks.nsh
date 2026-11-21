; Vega-Setup.exe 的 NSIS 钩子（Tauri 2 bundle.windows.nsis.installerHooks）。
;
; 设计约束（T3 架构决策）：
;   * 安装包启动时 UAC 提权一次（perMachine），此后 Vega 控制台运行时不提权。
;   * 安装阶段只装 RustDesk 并写中继配置；Sunshine/Moonlight/Tailscale 改为控制台里的
;     可选「高性能模式」，不在这里安装。
;   * RustDesk 是 AGPL：安装包绝不内嵌其二进制，脚本在目标机从官方 Release 下载固定版本
;     并校验 SHA256。
;   * 脚本失败不阻断安装本身：安装照常完成，只在完成页提示用户到 Vega 里手动安装。
;
; 注意：本文件在 tauri 的 installer.nsi 顶部（MUI 页面插入之前）被 include，
; 所以这里的 !define 能影响完成页文案；MUI_FINISHPAGE_TEXT 里放的是运行时变量。

Var vegaSetupExitCode
Var vegaFinishText

; 安装失败时改写完成页文案（$vegaFinishText 在页面显示时按当时的值展开）。
; MUI2 在 include 时已给出默认 MUI_FINISHPAGE_TEXT，这里先 undef 再定义，避免重定义告警。
!ifdef MUI_FINISHPAGE_TEXT
  !undef MUI_FINISHPAGE_TEXT
!endif
!define MUI_FINISHPAGE_TEXT "$vegaFinishText"

; 日志目录：$COMMONPROGRAMDATA 才是所有用户的 ProgramData。
; 目录只允许 Administrators/SYSTEM 写，按 SID 授权，避免本地化系统里账户名不同。
!macro VegaPrepareLogDirectory
  CreateDirectory "$COMMONPROGRAMDATA\Vega"
  CreateDirectory "$COMMONPROGRAMDATA\Vega\logs"
  nsExec::ExecToStack 'icacls "$COMMONPROGRAMDATA\Vega\logs" /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F'
  Pop $0
  Pop $1
!macroend

!macro VegaRunInstallRustDesk
  ; 先用各语言默认文案打底；失败时才换成具体提示。
  StrCpy $vegaFinishText "$(MUI_TEXT_FINISH_INFO_TEXT)"

  !insertmacro VegaPrepareLogDirectory

  DetailPrint "正在安装并配置 RustDesk（自建中继）…"
  ; -WindowStyle Hidden 兜底：nsExec 本身不弹控制台，但 Windows PowerShell 启动器
  ; 仍可能闪一下窗口。
  nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\resources\host\install-rustdesk.ps1" -DefaultsFile "$INSTDIR\resources\vega-defaults.json" -LogFile "$COMMONPROGRAMDATA\Vega\logs\setup.log"'
  Pop $0
  Pop $1
  StrCpy $vegaSetupExitCode $0

  FileOpen $2 "$COMMONPROGRAMDATA\Vega\logs\setup.log" a
  IfErrors vega_setup_log_done
  FileWrite $2 "$\r$\n[nsis] install-rustdesk.ps1 exit code: $0$\r$\n"
  FileClose $2
vega_setup_log_done:

  StrCmp $0 "0" vega_setup_installed
    ; 不 Abort：RustDesk 没装好也要把 Vega 装完，用户可以在控制台里按提示重试。
    ; 交互模式只改完成页文案；/S 与 /P 不弹模态框，只留日志和 DetailPrint。
    DetailPrint "RustDesk 未装好（退出码 $0），继续完成 Vega 安装。"
    StrCpy $vegaFinishText "Vega 已安装，但 RustDesk 未装好（退出码 $0）。请打开 Vega，按设置页提示手动安装，或到 https://rustdesk.com/download 下载安装。"
vega_setup_installed:
!macroend

!macro VegaRunUninstallRustDesk
  ; /UPDATE 只替换 Vega 程序文件，RustDesk 的安装与中继配置应保持原样。
  StrCmp $UpdateMode "1" vega_unsetup_skip

  !insertmacro VegaPrepareLogDirectory

  DetailPrint "正在回滚 RustDesk 中继配置…"
  ; -Uninstall 只回滚 state.json / host-state.json 里由 Vega 记录过的改动；
  ; 只卸载本安装包装过、且清单记录了安装路径的 RustDesk（见脚本实现）。
  nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\resources\host\install-rustdesk.ps1" -Uninstall -DefaultsFile "$INSTDIR\resources\vega-defaults.json" -LogFile "$COMMONPROGRAMDATA\Vega\logs\setup.log"'
  Pop $0
  Pop $1

  FileOpen $2 "$COMMONPROGRAMDATA\Vega\logs\setup.log" a
  IfErrors vega_unsetup_log_done
  FileWrite $2 "$\r$\n[nsis] install-rustdesk.ps1 -Uninstall exit code: $0$\r$\n"
  FileClose $2
vega_unsetup_log_done:

  StrCmp $0 "0" vega_unsetup_skip
    ; 回滚失败不能静默：脚本会保留安装记录，用户可重装/再卸载重试。
    DetailPrint "RustDesk 回滚未完成（退出码 $0），安装记录已保留，可在控制台重试。"
vega_unsetup_skip:
!macroend

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro VegaRunInstallRustDesk
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  !insertmacro VegaRunUninstallRustDesk
!macroend
