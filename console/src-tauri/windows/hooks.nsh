; Vega-Setup.exe 的 NSIS 钩子（Tauri 2 bundle.windows.nsis.installerHooks）。
;
; 设计约束（T3 架构决策）：
;   * 安装包启动时 UAC 提权一次（perMachine），此后 Vega 控制台运行时不提权。
;   * 安装阶段只装 RustDesk 并写中继配置；Sunshine/Moonlight/Tailscale 改为控制台里的
;     可选「高性能模式」，不在这里安装。
;   * RustDesk 是 AGPL：安装包绝不内嵌其二进制，脚本在目标机从官方 Release 下载固定版本
;     并校验 SHA256。
;   * 脚本失败不阻断安装本身：安装照常完成，只在完成页提示用户到 Vega 里手动安装。
;   * 用户级配置写当前登录交互用户（explorer.exe 所有者 / 活动会话用户）的 Roaming
;     AppData，不写提权账户的 %APPDATA%；取不到时只写服务级并在完成页提示。
;
; 注意：本文件在 tauri 的 installer.nsi 顶部（MUI 页面插入之前）被 include，
; 所以这里的 !define 能影响完成页文案；MUI_FINISHPAGE_TEXT 里放的是运行时变量。

Var vegaSetupExitCode
Var vegaFinishText
Var vegaPowerShell
Var vegaLogUsable
Var vegaSetupLogLine
Var vegaUserContextB64
Var vegaLogArgument
Var vegaRetryCommand

; 安装失败时改写完成页文案（$vegaFinishText 在页面显示时按当时的值展开）。
; MUI2 在 include 时已给出默认 MUI_FINISHPAGE_TEXT，这里先 undef 再定义，避免重定义告警。
!ifdef MUI_FINISHPAGE_TEXT
  !undef MUI_FINISHPAGE_TEXT
!endif
!define MUI_FINISHPAGE_TEXT "$vegaFinishText"

; P1-2：Tauri 默认 NSIS stub 是 32 位，$SYSDIR 会被 WOW64 重定向到 SysWOW64，
; 那样启动的 PowerShell 也看不到 64 位 Program Files。Sysnative 只在 32 位进程里存在，
; 优先用它拿原生 64 位 PowerShell；不存在（已是 64 位进程）就用 $SYSDIR。
; 宏会展开两次（安装/卸载），标签名按 ID 区分，避免重名。
!macro VegaSelectPowerShell ID
  StrCpy $vegaPowerShell "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists "$vegaPowerShell" vega_ps_done_${ID} vega_ps_fallback_${ID}
vega_ps_fallback_${ID}:
  StrCpy $vegaPowerShell "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
vega_ps_done_${ID}:
!macroend

; P1-4：日志目录只允许 Administrators/SYSTEM 写，按 SID 授权，避免本地化系统里账户名不同。
; icacls 必须用绝对路径（提权上下文里按名称搜索可执行文件会被 PATH 劫持）。
; ACL 收紧失败就跳过本次文件日志，不往不可信目录追加。
!macro VegaPrepareLogDirectory ID
  StrCpy $vegaLogUsable "0"
  CreateDirectory "$COMMONPROGRAMDATA\Vega"
  CreateDirectory "$COMMONPROGRAMDATA\Vega\logs"
  nsExec::ExecToStack '"$SYSDIR\icacls.exe" "$COMMONPROGRAMDATA\Vega\logs" /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F'
  Pop $0
  Pop $1
  StrCmp $0 "0" vega_log_ok_${ID} vega_log_skip_${ID}
vega_log_ok_${ID}:
  StrCpy $vegaLogUsable "1"
vega_log_skip_${ID}:
!macroend

; 只有 $vegaLogUsable=1（ACL 已收紧）时才追加一行 [nsis] 日志。
; $vegaSetupLogLine 由调用方先填好。
!macro VegaAppendSetupLog ID
  StrCmp $vegaLogUsable "1" vega_log_append_${ID} vega_log_append_done_${ID}
vega_log_append_${ID}:
  FileOpen $2 "$COMMONPROGRAMDATA\Vega\logs\setup.log" a
  IfErrors vega_log_append_done_${ID} 0
  FileWrite $2 "$\r$\n[nsis] $vegaSetupLogLine$\r$\n"
  FileClose $2
vega_log_append_done_${ID}:
!macroend

; P1-1（t3-fix4）：交互用户上下文只解析一次，并以 ASCII Base64(UTF-8) 传一串，
; 不再让 SID 和中文 AppData 走 nsExec 的 ANSI 代码页。脚本解码后校验路径存在。
; 取不到时字符串为空，脚本退回只写服务级配置并返回退出码 2（降级）。
; Get-VegaInteractiveUserContextPayload 只认可 explorer.exe 所有者 / 活动会话用户，
; 不会把提权账户当成交互用户。
!macro VegaResolveInteractiveUser ID
  StrCpy $vegaUserContextB64 ""
  nsExec::ExecToStack '"$vegaPowerShell" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\resources\host\resolve-interactive-user.ps1" -Field Context'
  Pop $0
  Pop $1
  StrCmp $0 "0" 0 vega_user_ctx_done_${ID}
  StrCpy $vegaUserContextB64 $1
vega_user_ctx_trim_${ID}:
  ; nsExec 可能带回尾部 CR/LF，Base64 里不会有空白，去掉再传。
  StrCpy $2 $vegaUserContextB64 1 -1
  StrCmp $2 "$\r" vega_user_ctx_trim_one_${ID}
  StrCmp $2 "$\n" vega_user_ctx_trim_one_${ID}
  Goto vega_user_ctx_done_${ID}
vega_user_ctx_trim_one_${ID}:
  StrCpy $vegaUserContextB64 $vegaUserContextB64 -1
  StrCmp $vegaUserContextB64 "" vega_user_ctx_done_${ID} vega_user_ctx_trim_${ID}
vega_user_ctx_done_${ID}:
!macroend

; P2（t3-fix4）：ACL 收紧失败时给脚本传 -NoFileLog，两层一起跳过文件日志。
!macro VegaSelectLogArgument ID
  StrCpy $vegaLogArgument '-LogFile "$COMMONPROGRAMDATA\Vega\logs\setup.log"'
  StrCmp $vegaLogUsable "1" vega_log_arg_done_${ID} 0
  StrCpy $vegaLogArgument '-NoFileLog'
vega_log_arg_done_${ID}:
!macroend

; P1-8：卸载前把回滚脚本复制到 ProgramData 下的固定位置。UNINSTALL 会删掉 $INSTDIR，
; 回滚失败时必须留下一个不用重新下载安装包就能直接重跑的入口；成功时再删掉。
!macro VegaPreserveRetryScript
  CreateDirectory "$COMMONPROGRAMDATA\Vega\retry"
  CreateDirectory "$COMMONPROGRAMDATA\Vega\retry\host"
  CreateDirectory "$COMMONPROGRAMDATA\Vega\retry\host\lib"
  CopyFiles /SILENT "$INSTDIR\resources\host\install-rustdesk.ps1" "$COMMONPROGRAMDATA\Vega\retry\host\install-rustdesk.ps1"
  CopyFiles /SILENT "$INSTDIR\resources\host\resolve-interactive-user.ps1" "$COMMONPROGRAMDATA\Vega\retry\host\resolve-interactive-user.ps1"
  CopyFiles /SILENT "$INSTDIR\resources\host\lib\Vega.Common.psm1" "$COMMONPROGRAMDATA\Vega\retry\host\lib\Vega.Common.psm1"
  CopyFiles /SILENT "$INSTDIR\resources\vega-defaults.json" "$COMMONPROGRAMDATA\Vega\retry\vega-defaults.json"
!macroend

!macro VegaRemoveRetryScript
  Delete "$COMMONPROGRAMDATA\Vega\retry\host\install-rustdesk.ps1"
  Delete "$COMMONPROGRAMDATA\Vega\retry\host\resolve-interactive-user.ps1"
  Delete "$COMMONPROGRAMDATA\Vega\retry\host\lib\Vega.Common.psm1"
  Delete "$COMMONPROGRAMDATA\Vega\retry\vega-defaults.json"
  RMDir "$COMMONPROGRAMDATA\Vega\retry\host\lib"
  RMDir "$COMMONPROGRAMDATA\Vega\retry\host"
  RMDir "$COMMONPROGRAMDATA\Vega\retry"
!macroend

!macro VegaRunInstallRustDesk
  ; 先用各语言默认文案打底；失败时才换成具体提示。
  StrCpy $vegaFinishText "$(MUI_TEXT_FINISH_INFO_TEXT)"

  !insertmacro VegaSelectPowerShell install
  !insertmacro VegaPrepareLogDirectory install
  !insertmacro VegaSelectLogArgument install
  !insertmacro VegaResolveInteractiveUser install

  DetailPrint "正在安装并配置 RustDesk（自建中继）…"
  ; -WindowStyle Hidden 兜底：nsExec 本身不弹控制台，但 Windows PowerShell 启动器
  ; 仍可能闪一下窗口。
  nsExec::ExecToStack '"$vegaPowerShell" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\resources\host\install-rustdesk.ps1" -DefaultsFile "$INSTDIR\resources\vega-defaults.json" $vegaLogArgument -InteractiveUserContextB64 "$vegaUserContextB64"'
  Pop $0
  Pop $1
  StrCpy $vegaSetupExitCode $0

  StrCpy $vegaSetupLogLine "install-rustdesk.ps1 exit code: $0 (user context: $vegaUserContextB64)"
  !insertmacro VegaAppendSetupLog install

  ; 退出码 2 = 服务级已写入、用户级降级；不能当成失败，也不能当成完整成功。
  StrCmp $0 "0" vega_install_finish_done
  StrCmp $0 "2" vega_install_degraded 0
  Goto vega_install_failed
vega_install_degraded:
    StrCpy $vegaFinishText "$(MUI_TEXT_FINISH_INFO_TEXT)$\r$\n$\r$\nRustDesk 已写入服务级中继配置，但用户级配置未写入（未取到可用的交互用户或写入失败）。请在该用户的 RustDesk 设置 → 网络中填写服务器地址与公钥。"
    Goto vega_install_finish_done
vega_install_failed:
    ; 不 Abort：RustDesk 没装好也要把 Vega 装完，用户可以在控制台里按提示重试。
    ; 交互模式只改完成页文案；/S 与 /P 不弹模态框，只留日志和 DetailPrint。
    DetailPrint "RustDesk 未装好（退出码 $0），继续完成 Vega 安装。"
    StrCpy $vegaFinishText "Vega 已安装，但 RustDesk 未装好（退出码 $0）。请打开 Vega，按设置页提示手动安装，或到 https://rustdesk.com/download 下载安装。"
vega_install_finish_done:
!macroend

!macro VegaRunUninstallRustDesk
  ; /UPDATE 只替换 Vega 程序文件，RustDesk 的安装与中继配置应保持原样。
  StrCmp $UpdateMode "1" vega_unsetup_skip

  !insertmacro VegaSelectPowerShell uninstall
  !insertmacro VegaPrepareLogDirectory uninstall
  !insertmacro VegaSelectLogArgument uninstall
  !insertmacro VegaPreserveRetryScript
  !insertmacro VegaResolveInteractiveUser uninstall

  DetailPrint "正在回滚 RustDesk 中继配置…"
  ; -Uninstall 只回滚 state.json / host-state.json 里由 Vega 记录过的改动；
  ; 只卸载本安装包装过、且清单记录了安装路径的 RustDesk（见脚本实现）。
  nsExec::ExecToStack '"$vegaPowerShell" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\resources\host\install-rustdesk.ps1" -Uninstall -DefaultsFile "$INSTDIR\resources\vega-defaults.json" $vegaLogArgument -InteractiveUserContextB64 "$vegaUserContextB64"'
  Pop $0
  Pop $1

  StrCpy $vegaSetupLogLine "install-rustdesk.ps1 -Uninstall exit code: $0"
  !insertmacro VegaAppendSetupLog uninstall

  StrCmp $0 "0" 0 vega_unsetup_failed
    ; 回滚确认完成才删重试入口。
    !insertmacro VegaRemoveRetryScript
    Goto vega_unsetup_skip

vega_unsetup_failed:
    ; 回滚失败不能静默：保留安装记录和可直接重跑的脚本，用户重装/再卸载都能重试。
    StrCpy $vegaRetryCommand '"$vegaPowerShell" -NoProfile -ExecutionPolicy Bypass -File "$COMMONPROGRAMDATA\Vega\retry\host\install-rustdesk.ps1" -Uninstall'
    DetailPrint "RustDesk 回滚未完成（退出码 $0），安装记录已保留。"
    DetailPrint "可重试：$vegaRetryCommand"
vega_unsetup_skip:
!macroend

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro VegaRunInstallRustDesk
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  !insertmacro VegaRunUninstallRustDesk
!macroend
