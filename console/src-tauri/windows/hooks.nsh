; Vega-Setup.exe 的 NSIS 钩子（Tauri 2 bundle.windows.nsis.installerHooks）。
;
; 设计约束（T3 架构决策）：
;   * 安装包启动时 UAC 提权一次（perMachine），此后 Vega 控制台运行时不提权。
;   * 安装阶段只装 RustDesk 并写中继配置；Sunshine/Moonlight/Tailscale 改为控制台里的
;     可选「高性能模式」，不在这里安装。
;   * RustDesk 是 AGPL：安装包绝不内嵌其二进制，脚本在目标机从官方 Release 下载固定版本
;     并校验 SHA256。
;   * 脚本失败不阻断安装本身：安装照常完成，只在完成时提示用户到 Vega 里手动安装。

!macro VegaRunInstallRustDesk
  ; %ProgramData%\Vega\logs\setup.log：脚本自身写详细日志，这里只补一行退出码。
  CreateDirectory "$PROGRAMDATA\Vega\logs"

  DetailPrint "正在安装并配置 RustDesk（自建中继）…"
  ; -WindowStyle Hidden 兜底：nsExec 本身不弹控制台，但 Windows PowerShell 启动器
  ; 仍可能闪一下窗口。
  nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\resources\host\install-rustdesk.ps1" -DefaultsFile "$INSTDIR\resources\vega-defaults.json" -LogFile "$PROGRAMDATA\Vega\logs\setup.log"'
  Pop $0
  Pop $1

  FileOpen $2 "$PROGRAMDATA\Vega\logs\setup.log" a
  IfErrors +3
  FileWrite $2 "$\r$\n[nsis] install-rustdesk.ps1 exit code: $0$\r$\n"
  FileClose $2

  StrCmp $0 "0" +3
    ; 不 Abort：RustDesk 没装好也要把 Vega 装完，用户可以在控制台里按提示重试。
    DetailPrint "RustDesk 未装好（退出码 $0），继续完成 Vega 安装。"
    MessageBox MB_ICONEXCLAMATION|MB_OK "RustDesk 未装好，请打开 Vega 按提示手动安装。"
!macroend

!macro VegaRunUninstallRustDesk
  CreateDirectory "$PROGRAMDATA\Vega\logs"

  DetailPrint "正在回滚 RustDesk 中继配置…"
  ; -Uninstall 只回滚 state.json / host-state.json 里由 Vega 记录过的改动；
  ; 用户原有的 RustDesk 安装保留（除非那条安装记录标明是 Vega 装的，见脚本实现）。
  nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\resources\host\install-rustdesk.ps1" -Uninstall -DefaultsFile "$INSTDIR\resources\vega-defaults.json" -LogFile "$PROGRAMDATA\Vega\logs\setup.log"'
  Pop $0
  Pop $1

  FileOpen $2 "$PROGRAMDATA\Vega\logs\setup.log" a
  IfErrors +3
  FileWrite $2 "$\r$\n[nsis] install-rustdesk.ps1 -Uninstall exit code: $0$\r$\n"
  FileClose $2
!macroend

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro VegaRunInstallRustDesk
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  !insertmacro VegaRunUninstallRustDesk
!macroend
