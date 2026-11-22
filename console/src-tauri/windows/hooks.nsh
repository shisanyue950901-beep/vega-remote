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
;   * t3-fix7：退出码 2 的完成页显示脚本给出的具体降级原因，不写死“服务级已写入”。
;     服务未注册且 RustDesk 正在运行时脚本一行配置都不写，完成页要求用户完全退出客户端、
;     启用服务后重跑。
;   * t3-fix8 P1-1：原因不再靠 ANSI 的 FileRead 扫 UTF-8 日志（中文会乱码）。每次运行
;     生成唯一的 UTF-16LE 结果文件，脚本写入一行降级/失败原因，这里用 FileReadUTF16LE
;     读取并显示，读完删除。
;   * t3-fix9 P2：去掉日志 WARN 兜底解析。结果文件缺失（旧脚本 / 写失败）时完成页
;     显示固定中文指引：完全退出 RustDesk、在 RustDesk 里启用服务后重新运行 Vega 安装。
;   * t6-fix（用户 2026-11-22）：安装器不再显示“选择安装目录”页，安装路径固定为
;     $PROGRAMFILES64\Vega。原因：长期密码助手 resources\vega-pwhelper.ps1 必须位于
;     系统 Program Files 下（默认 ACL 只允许管理员写），用户自选目录可能落在普通用户
;     可写的位置，UAC 之后拉起该目录里的脚本就等于把提权执行权交给普通用户。
;   * t6-fix2（用户 2026-11-22）：旧安装器有目录选择页，旧版可能装在 D:\Vega 这类固定目录
;     之外。PREINSTALL 从 Tauri 的卸载注册表项读出旧安装目录，清理旧目录，避免机器上
;     两份 Vega 并存。旧目录清理失败只提示，不阻断安装；RustDesk 配置、%ProgramData%\Vega
;     与用户 AppData 都不在删除范围（RMDir 不加 /r，只删旧安装目录本身）。
;   * t6-fix3b（架构裁定）：目录页必须改模板，!undef 宏不生效，已删除该死代码；
;     旧版迁移绝不运行旧卸载器（旧卸载器会回滚 RustDesk），只在 PREINSTALL 里删除
;     已知程序文件；/UPDATE 模式完全跳过 RustDesk 安装脚本。
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
Var vegaResultFile
Var vegaResultReason
Var vegaOldInstallDir
Var vegaOldInstallWarning
Var vegaFixedDir

; t6-fix：安装路径固定。$PROGRAMFILES64 保留原生 Program Files（Tauri 的 NSIS stub 是
; 32 位进程，$PROGRAMFILES 会被重定向到 Program Files (x86)，所以这里不用它）。
!ifndef VEGA_INSTALL_DIR
  !define VEGA_INSTALL_DIR "$PROGRAMFILES64\Vega"
!endif

; t6-fix：去掉“选择安装目录”页。页面本体已从定制模板 windows/installer.nsi 中删除
; （宏覆盖在 MUI2 include 时无效，见文件头 t6-fix3b）。$INSTDIR 在模板 .onInit 末尾与
; 下面 PREINSTALL 里两处强制为固定目录。

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

; t3-fix8 P1-1：本次运行专用的结果文件路径。GetTempFileName 每次给出唯一名，
; 先删掉占位文件，让脚本以 UTF-16LE + BOM 重新创建（避免读到空文件或上一次残留）。
; 日志目录 ACL 已收紧就放日志目录，没收紧就放 $TEMP。
!macro VegaPrepareResultFile ID
  StrCpy $vegaResultFile ""
  StrCpy $vegaResultReason ""
  StrCmp $vegaLogUsable "1" 0 vega_result_temp_${ID}
    GetTempFileName $vegaResultFile "$COMMONPROGRAMDATA\Vega\logs"
    Goto vega_result_ready_${ID}
vega_result_temp_${ID}:
    GetTempFileName $vegaResultFile "$TEMP"
vega_result_ready_${ID}:
  StrCmp $vegaResultFile "" vega_result_prepare_done_${ID}
  Delete "$vegaResultFile"
vega_result_prepare_done_${ID}:
!macroend

; t3-fix8 P1-1：读脚本写的一行原因。FileReadUTF16LE 跳过 BOM，不会把中文读成乱码。
; 读完（读成功或读失败）都删除：结果文件只服务本次运行。
!macro VegaReadResultFile ID
  StrCpy $vegaResultReason ""
  StrCmp $vegaResultFile "" vega_result_read_done_${ID}
  IfFileExists "$vegaResultFile" 0 vega_result_read_done_${ID}
  ClearErrors
  FileOpen $2 "$vegaResultFile" r
  IfErrors vega_result_read_done_${ID} 0
  FileReadUTF16LE $2 $3
  IfErrors vega_result_read_close_${ID} 0
  StrCpy $vegaResultReason $3
vega_result_read_close_${ID}:
  FileClose $2
vega_result_read_done_${ID}:
  StrCmp $vegaResultFile "" vega_result_read_finish_${ID}
  Delete "$vegaResultFile"
vega_result_read_finish_${ID}:
  ; FileRead 带回行尾 CR/LF：只留一行给完成页。
  StrCmp $vegaResultReason "" vega_result_trim_done_${ID}
vega_result_trim_${ID}:
  StrCpy $4 $vegaResultReason 1 -1
  StrCmp $4 "$\r" vega_result_trim_one_${ID}
  StrCmp $4 "$\n" vega_result_trim_one_${ID}
  Goto vega_result_trim_done_${ID}
vega_result_trim_one_${ID}:
  StrCpy $vegaResultReason $vegaResultReason -1
  Goto vega_result_trim_${ID}
vega_result_trim_done_${ID}:
!macroend

; 退出码 0 时脚本不写原因；仍删掉占位文件，避免在日志目录留下垃圾。
!macro VegaDeleteResultFile ID
  StrCmp $vegaResultFile "" vega_result_delete_done_${ID}
  Delete "$vegaResultFile"
vega_result_delete_done_${ID}:
!macroend

; t3-fix9 P2：结果文件缺失（旧脚本 / 写失败）时的固定指引。日志路径在运行时展开。
!define VEGA_RESULT_MISSING_GUIDE "安装未完全成功，请完全退出 RustDesk、在 RustDesk 中启用服务后重新运行 Vega 安装；详细日志见 $COMMONPROGRAMDATA\Vega\logs\setup.log。"

!macro VegaRunInstallRustDesk
  ; 先用各语言默认文案打底；失败时才换成具体提示。
  StrCpy $vegaFinishText "$(MUI_TEXT_FINISH_INFO_TEXT)"

  !insertmacro VegaSelectPowerShell install
  !insertmacro VegaPrepareLogDirectory install
  !insertmacro VegaSelectLogArgument install
  ; t3-fix8 P1-1：每次运行生成唯一结果文件路径，传给脚本写降级/失败原因。
  !insertmacro VegaPrepareResultFile install
  !insertmacro VegaResolveInteractiveUser install

  DetailPrint "正在安装并配置 RustDesk（自建中继）…"
  ; -WindowStyle Hidden 兜底：nsExec 本身不弹控制台，但 Windows PowerShell 启动器
  ; 仍可能闪一下窗口。
  ; t3-fix5 P2：-InteractiveUserContextB64 总是显式传（取不到时是空串）。脚本用
  ; PSBoundParameters 区分“钩子确认没有交互用户”（直接只写服务级，退出码 2）与
  ; “手动调用省略参数”（才回退解析），所以这里不要去条件拼接这个参数。
  nsExec::ExecToStack '"$vegaPowerShell" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$INSTDIR\resources\host\install-rustdesk.ps1" -DefaultsFile "$INSTDIR\resources\vega-defaults.json" $vegaLogArgument -InteractiveUserContextB64 "$vegaUserContextB64" -ResultFile "$vegaResultFile"'
  Pop $0
  Pop $1
  StrCpy $vegaSetupExitCode $0

  ; 不把 Base64 上下文（含用户名/路径）写进日志，只记录是否取到。
  StrCpy $vegaSetupLogLine "install-rustdesk.ps1 exit code: $0"
  StrCmp $vegaUserContextB64 "" vega_install_log_done
    StrCpy $vegaSetupLogLine "install-rustdesk.ps1 exit code: $0 (interactive user context provided)"
vega_install_log_done:
  !insertmacro VegaAppendSetupLog install

  ; 退出码 2 = 降级（成功但只写了一处配置，或服务未注册且 RustDesk 正在运行而未写配置）；
  ; 不能当成失败，也不能当成完整成功。
  StrCmp $0 "0" vega_install_finish_done

  ; t3-fix9 P1：非零退出统一在这里读一次结果文件，读完再按退出码 2 / 其他分流。
  ; VegaReadResultFile 含标签，同一段内只能展开一次（NSIS 拒绝同段重名标签）。
  !insertmacro VegaReadResultFile install
  StrCmp $0 "2" vega_install_degraded 0
  Goto vega_install_failed

vega_install_degraded:
    ; t3-fix9 P2：结果文件缺失时不再扫日志，直接给固定的重跑指引。
    StrCmp $vegaResultReason "" vega_install_degraded_missing
    StrCpy $vegaResultReason "RustDesk 中继配置没有完全生效：$vegaResultReason"
    Goto vega_install_degraded_show
vega_install_degraded_missing:
    StrCpy $vegaResultReason "${VEGA_RESULT_MISSING_GUIDE}"
vega_install_degraded_show:
    StrCpy $vegaFinishText "$(MUI_TEXT_FINISH_INFO_TEXT)$\r$\n$\r$\n$vegaResultReason"
    DetailPrint "RustDesk 中继配置降级（退出码 2）：$vegaResultReason"
    Goto vega_install_finish_done
vega_install_failed:
    ; 不 Abort：RustDesk 没装好也要把 Vega 装完，用户可以在控制台里按提示重试。
    ; 交互模式只改完成页文案；/S 与 /P 不弹模态框，只留日志和 DetailPrint。
    DetailPrint "RustDesk 未装好（退出码 $0），继续完成 Vega 安装。"
    StrCpy $vegaFinishText "Vega 已安装，但 RustDesk 未装好（退出码 $0）。请打开 Vega，按设置页提示手动安装，或到 https://rustdesk.com/download 下载安装。"
    ; t3-fix9 P2：结果文件缺失同样给固定指引（不再靠日志猜原因）。
    StrCmp $vegaResultReason "" vega_install_failed_missing
      StrCpy $vegaFinishText "$vegaFinishText$\r$\n$\r$\n$vegaResultReason"
      Goto vega_install_finish_done
vega_install_failed_missing:
      StrCpy $vegaFinishText "$vegaFinishText$\r$\n$\r$\n${VEGA_RESULT_MISSING_GUIDE}"
vega_install_finish_done:
    ; t6-fix2：旧目录清理的告警不能盖掉 RustDesk 的文案，统一追加在最后。
    StrCmp $vegaOldInstallWarning "" vega_install_finish_warned
      StrCpy $vegaFinishText "$vegaFinishText$\r$\n$\r$\n$vegaOldInstallWarning"
vega_install_finish_warned:
    ; 成功时脚本不写原因；统一清理占位/残留结果文件。
    !insertmacro VegaDeleteResultFile install
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

; t6-fix2：去掉首尾成对引号、去掉尾部反斜杠（"C:\" 这种盘根保持原样），结果写回传入变量。
; Tauri 的 installer.nsi 写注册表时 InstallLocation 是 "$\"$INSTDIR$\""（带引号），
; 旧版 / 手改过的值可能是裸路径或带尾反斜杠，两种都要能对上 ${VEGA_INSTALL_DIR}。
!macro VegaTrimDirPath ID VAR
  StrCpy $R0 ${VAR}
  StrCpy $R1 $R0 1
  StrCmp $R1 '"' 0 vega_trim_tail_${ID}
    StrCpy $R0 $R0 -1 1
vega_trim_tail_${ID}:
  StrCpy $R1 $R0 1 -1
  StrCmp $R1 '"' 0 vega_trim_slash_${ID}
    StrCpy $R0 $R0 -1
vega_trim_slash_${ID}:
  StrCmp $R0 "" vega_trim_done_${ID}
  StrCpy $R1 $R0 1 -1
  StrCmp $R1 "\" 0 vega_trim_done_${ID}
  StrCpy $R2 $R0 1 -2
  StrCmp $R2 ":" 0 vega_trim_one_${ID}
  Goto vega_trim_done_${ID}
vega_trim_one_${ID}:
  StrCpy $R0 $R0 -1
  Goto vega_trim_slash_${ID}
vega_trim_done_${ID}:
  StrCpy ${VAR} $R0
!macroend

; t6-fix3b（架构裁定）：旧版装在 ${VEGA_INSTALL_DIR} 之外（旧安装器有目录页，
; 例如 D:\Vega）时，只删除旧目录里的 Vega 程序文件，绝不运行旧卸载器。
; 原因：旧卸载器会执行 install-rustdesk.ps1 -Uninstall，把 RustDesk 中继配置回滚掉，
; 等于用一次目录迁移毁掉现有远程协助。
;
; 注册表位置与 Tauri 的 installer.nsi 完全一致：
;   SHCTX\Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCTNAME}
; installMode=perMachine + SetContext（x64 → SetRegView 64）意味着它落在 HKLM 的 64 位视图；
; Tauri 自己也是用这个键的 InstallLocation / UninstallString 判断旧安装，读同一个值不会跑偏。
;
; 行为约定：
;   * 只在非 /UPDATE 模式处理；/UPDATE 时旧版就在固定目录，无需迁移。
;   * InstallLocation / UninstallString 先归一化（去引号、去尾反斜杠），再用 Win32
;     GetFullPathNameW 规范化，与 ${VEGA_INSTALL_DIR} 大小写不敏感比较；相同则不做。
;   * 盘根、UNC、Windows/ProgramData/用户配置目录一律拒绝（护栏）。
;   * 旧目录里必须有 vega-console.exe，否则一概不碰。
;   * 先把 $OUTDIR 指到固定目录，再 Delete 已知文件、非递归 RMDir 子目录与旧目录。
;     不加 /r，所以 RustDesk 配置、%ProgramData%\Vega、用户 AppData 都不会被删。
;   * 旧快捷方式只有指向旧目录时才删除（Tauri 随后按新目录重建）。
;   * 任何失败都只追加完成页提示，绝不 Abort；卸载注册表键由新安装重写。
;   * FileFunc.nsh v3.4 没有 GetFullPathName 宏，这里直接调 Win32。
!macro VegaCanonicalDir ID VAR
  StrCpy $R0 "${VAR}"
  System::Call 'kernel32::GetFullPathNameW(w r0, i 1024, w .r1, i 0) i .r2'
  StrCmp $R2 "0" vega_canon_done_${ID}
    StrCpy ${VAR} "$R1"
    !insertmacro VegaTrimDirPath canon_${ID} ${VAR}
vega_canon_done_${ID}:
!macroend

!macro VegaRemovePreviousInstall
  StrCpy $vegaOldInstallDir ""
  StrCpy $vegaOldInstallWarning ""

  StrCmp $UpdateMode "1" 0 vega_old_read_reg
    DetailPrint "更新模式：跳过旧目录迁移（旧版就在 ${VEGA_INSTALL_DIR}）。"
    Goto vega_old_done

vega_old_read_reg:
  StrCpy $R7 "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCTNAME}"
  ReadRegStr $R8 SHCTX "$R7" "InstallLocation"
  StrCmp $R8 "" 0 vega_old_have_path

  ; InstallLocation 缺失（旧版本 / 被清理过）时退回 UninstallString："<old>\uninstall.exe"。
  ReadRegStr $R8 SHCTX "$R7" "UninstallString"
  StrCmp $R8 "" vega_old_done
  !insertmacro VegaTrimDirPath old_uninst $R8
  StrCpy $R9 $R8 14 -14
  ${StrCase} $R9 "$R9" "L"
  StrCmp $R9 "\uninstall.exe" 0 vega_old_have_path
    StrCpy $R8 $R8 -14

vega_old_have_path:
  StrCpy $vegaOldInstallDir $R8
  !insertmacro VegaTrimDirPath old_inst $vegaOldInstallDir
  StrCmp $vegaOldInstallDir "" vega_old_done
  ; 规范化（相对路径按当前目录解析，去掉 . / .. 与重复分隔符）。
  !insertmacro VegaCanonicalDir old_inst $vegaOldInstallDir
  StrCmp $vegaOldInstallDir "" vega_old_done

  StrCpy $vegaFixedDir "${VEGA_INSTALL_DIR}"
  !insertmacro VegaCanonicalDir fixed $vegaFixedDir

  ; 大小写不敏感比较，尾部反斜杠已在上一步去掉。
  ${StrCase} $R8 "$vegaOldInstallDir" "L"
  ${StrCase} $R9 "$vegaFixedDir" "L"
  StrCmp $R8 $R9 0 vega_old_differs
    DetailPrint "旧版安装目录就是 ${VEGA_INSTALL_DIR}，按就地升级处理。"
    Goto vega_old_done

vega_old_differs:
  ; 护栏一：UNC（\\server\share）不处理。
  StrCpy $R1 "$vegaOldInstallDir" 2
  StrCmp $R1 "\\" vega_old_refused

  ; 护栏二：长度 <= 3 的路径（C:\）、系统/配置目录不处理。
  StrLen $R6 "$vegaOldInstallDir"
  IntCmp $R6 3 vega_old_refused vega_old_refused vega_old_guard_config

vega_old_guard_config:
  ${StrCase} $R6 "$WINDIR" "L"
  StrCmp $R8 $R6 vega_old_refused
  ${StrCase} $R6 "$COMMONPROGRAMDATA" "L"
  StrCmp $R8 $R6 vega_old_refused
  ${StrCase} $R6 "$APPDATA" "L"
  StrCmp $R8 $R6 vega_old_refused
  ${StrCase} $R6 "$LOCALAPPDATA" "L"
  StrCmp $R8 $R6 vega_old_refused
  ${StrCase} $R6 "$PROFILE" "L"
  StrCmp $R8 $R6 vega_old_refused
  Goto vega_old_check_binary

vega_old_refused:
  DetailPrint "旧版记录指向 $vegaOldInstallDir，看起来不是安装目录，跳过清理。"
  Goto vega_old_done

vega_old_check_binary:
  ; 护栏三：只处理确实含 vega-console.exe 的目录。
  IfFileExists "$vegaOldInstallDir\vega-console.exe" 0 vega_old_no_binary

  DetailPrint "发现旧版 Vega 装在 $vegaOldInstallDir，删除旧程序文件（不运行旧卸载器，RustDesk 与配置保持原样）…"

  ; 先保证当前解包目录是固定目录，避免后续 File 落回旧目录。
  StrCpy $INSTDIR "${VEGA_INSTALL_DIR}"
  SetOutPath "$INSTDIR"

  ; 只删 Tauri 安装的已知文件（主程序 + tauri.conf.json resources + 卸载器）。
  Delete "$vegaOldInstallDir\vega-console.exe"
  Delete "$vegaOldInstallDir\uninstall.exe"
  Delete "$vegaOldInstallDir\resources\vega-pwhelper.ps1"
  Delete "$vegaOldInstallDir\resources\vega-defaults.json"
  Delete "$vegaOldInstallDir\resources\host\install-rustdesk.ps1"
  Delete "$vegaOldInstallDir\resources\host\resolve-interactive-user.ps1"
  Delete "$vegaOldInstallDir\resources\host\lib\Vega.Common.psm1"
  RMDir "$vegaOldInstallDir\resources\host\lib"
  RMDir "$vegaOldInstallDir\resources\host"
  RMDir "$vegaOldInstallDir\resources"
  RMDir "$vegaOldInstallDir"

  ; 旧快捷方式只在指向旧目录时删除；Tauri 安装完会按固定目录重建。
  !insertmacro IsShortcutTarget "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$vegaOldInstallDir\vega-console.exe"
  Pop $R5
  StrCmp $R5 "1" 0 vega_old_shortcut_sm_done
    Delete "$SMPROGRAMS\${PRODUCTNAME}.lnk"
vega_old_shortcut_sm_done:
  StrCmp $AppStartMenuFolder "" vega_old_shortcut_sub_done
  !insertmacro IsShortcutTarget "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "$vegaOldInstallDir\vega-console.exe"
  Pop $R5
  StrCmp $R5 "1" 0 vega_old_shortcut_sub_done
    Delete "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk"
vega_old_shortcut_sub_done:
  !insertmacro IsShortcutTarget "$DESKTOP\${PRODUCTNAME}.lnk" "$vegaOldInstallDir\vega-console.exe"
  Pop $R5
  StrCmp $R5 "1" 0 vega_old_shortcut_desk_done
    Delete "$DESKTOP\${PRODUCTNAME}.lnk"
vega_old_shortcut_desk_done:

  IfFileExists "$vegaOldInstallDir\*.*" 0 vega_old_cleaned
    StrCpy $vegaOldInstallWarning "旧版目录 $vegaOldInstallDir 的程序文件已删除，但目录里仍有其他文件（可能不是 Vega 的），已保留，可手动删除。"
    DetailPrint "$vegaOldInstallWarning"
    Goto vega_old_done
vega_old_cleaned:
  DetailPrint "旧版目录 $vegaOldInstallDir 已清理。"
  Goto vega_old_done

vega_old_no_binary:
  DetailPrint "旧版记录指向 $vegaOldInstallDir，但没有 vega-console.exe，跳过旧目录清理。"

vega_old_done:
!macroend

; t6-fix：安装路径固定。Tauri 在 PREINSTALL 之后才复制文件、写注册表与快捷方式，
; 所以在这里改写 $INSTDIR 就足以让整个安装（含 UninstallString、更新器的安装位置）
; 落到 $PROGRAMFILES64\Vega；/D 参数、旧版注册表里的 InstallLocation、目录页的选择
; 都不会改变结果。
!macro NSIS_HOOK_PREINSTALL
  ; 先处理旧安装目录。$INSTDIR 已在模板 .onInit 末尾强制为固定目录；这里从注册表
  ; 读旧安装记录做迁移，但不运行旧卸载器。
  !insertmacro VegaRemovePreviousInstall

  StrCmp $INSTDIR "${VEGA_INSTALL_DIR}" vega_preinstall_dir_done
    DetailPrint "安装目录固定为 ${VEGA_INSTALL_DIR}（忽略请求的 $INSTDIR）"
vega_preinstall_dir_done:
  StrCpy $INSTDIR "${VEGA_INSTALL_DIR}"
  ; 双保险：让 $OUTDIR 指向固定目录，后续 File 一定解到新目录。
  SetOutPath "$INSTDIR"
!macroend

!macro NSIS_HOOK_POSTINSTALL
  ; t6-fix3b：/UPDATE 只替换 Vega 程序文件，RustDesk 的安装与中继配置原样保留，
  ; 因此完全跳过安装脚本（不下载、不改配置），避免在线更新把中继配置改写。
  StrCmp $UpdateMode "1" vega_postinstall_done
    !insertmacro VegaRunInstallRustDesk
vega_postinstall_done:
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  !insertmacro VegaRunUninstallRustDesk
!macroend
