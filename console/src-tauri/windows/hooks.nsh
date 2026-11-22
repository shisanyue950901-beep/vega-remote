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
;   * t6-fix（用户 2026-11-22）：曾一度隐藏“选择安装目录”页、把安装路径固定为
;     $PROGRAMFILES64\Vega。原因：长期密码助手 resources\vega-pwhelper.ps1 必须位于
;     非管理员不可写的目录，否则 UAC 之后拉起该脚本等于把提权执行权交给普通用户。
;   * t6b（用户 2026-11-22，放开目录限制）：用户要求能装到 D: 等自选目录，因此恢复目录页，
;     规则改为「只允许 $PROGRAMFILES64\Vega 或 <X>:\Vega（本地固定 NTFS 盘根下的 Vega），
;     安装器把目录 ACL 收紧成只有管理员可写」。
;     目标校验集中在模板 installer.nsi 的 VegaValidateTarget（目录页回调与安装节开头
;     都调用）；安装目录由 VegaLockInstallDir / VegaTightenInstallDir 共用
;     `VegaApplyInstallDirAcl` 收紧 ACL——**总是**执行，Program Files 下也一样
;     （t6c-fix1 起根 DACL 用 SDDL 精确替换，不再用 inheritance:r/grant:r；已有子项再用
;     子项 /reset 清掉旧自定义目录留下的显式 ACE）；
;     控制台 password.rs 在每次提权前校验助手父目录的 ACL。
;   * t6b-fix2（架构裁定）：ACL 锁定改到解包之前——安装节在校验通过后先
;     CreateDirectory $INSTDIR 并 Call VegaLockInstallDir，任一步失败立即
;     SetErrorLevel 2 + Abort，不会把文件解到未锁定的目录；POSTINSTALL 再收紧一次
;     （第二次失败只写完成页告警）。VegaValidateTarget 同时拒绝目标树里的重解析点
;     和无法枚举的目录；/D= 判定改为 .onInit 开头备份 $INSTDIR（$CMDLINE 里已无 /D=）。
;   * t6c（架构裁定 3，0.6.2，修复真机空 DACL 事故）：ACL 布局固定为「根目录显式 ACL 且
;     断继承，所有子项只靠继承、不带显式 ACE」。解包前的 VegaLockInstallDir 与解包后的
;     VegaTightenInstallDir 都只打日志后 Call 同一个 `VegaApplyInstallDirAcl`，四步逐条
;     检查退出码、失败即停：
;       1) 根目录 /setowner *S-1-5-32-544（只根目录）；
;       2) 根 DACL 用 SDDL `O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)`
;          精确替换（受保护 DACL，替换全部 ACE，包括显式拒绝和其他 SID）；
;       3) /setowner *S-1-5-32-544 /T（含子树）；
;       4) 子项三态枚举（1=有 / 0=空 / E=失败）；1 时 `"$INSTDIR\*" /reset /T`，E 即失败。
;     t6c-fix1：删除旧的 `/inheritance:r /grant:r` 两步调用，根 DACL 改用 SDDL 精确替换；
;     0.6.1 的教训仍成立——绝不对 `"$INSTDIR"` 同时带 `/T` 与断继承：对文件来说会删光
;     继承 ACE，而 `(OI)(CI)` 授权落不到文件上（`/C` 又吞掉错误），结果
;     D:\Vega\vega-console.exe 的 DACL 为空——用户无法运行、管理员身份的安装器也
;     覆盖不了（"无法打开要写入的文件"）、连卸载都删不掉。
;     t6b-fix3 的「解包之后禁止 /reset」被本条裁定取代：子项 `"$INSTDIR\*" /reset /T`
;     只把子项改回继承**已锁定**的根目录，不会让根目录重新继承盘根 ACL。
;   * t6-fix2（用户 2026-11-22）：旧安装器有目录选择页，旧版可能装在 D:\Vega 这类固定目录
;     之外。PREINSTALL 从 Tauri 的卸载注册表项读出旧安装目录，清理旧目录，避免机器上
;     两份 Vega 并存。旧目录清理失败只提示，不阻断安装；RustDesk 配置、%ProgramData%\Vega
;     与用户 AppData 都不在删除范围（RMDir 不加 /r，只删旧安装目录本身）。
;   * t6-fix3b（架构裁定）：目录页必须改模板，!undef 宏不生效，已删除该死代码；
;     旧版迁移绝不运行旧卸载器（旧卸载器会回滚 RustDesk），只在 PREINSTALL 里删除
;     已知程序文件；/UPDATE 模式完全跳过 RustDesk 安装脚本。
;   * t6-fix4（架构裁定）：安装器模板删除重装页，永不运行旧卸载器；PREINSTALL 先用
;     Var 记住「安装前是否已有 Vega 卸载注册表项」，POSTINSTALL 只在全新安装时运行
;     RustDesk 脚本；重装与 /UPDATE 默认跳过，只有 Program Files 下找不到 rustdesk.exe
;     时才补跑（补装并配置）。旧目录迁移在 /UPDATE 下也执行（只删文件）；比较前用
;     GetLongPathNameW 解析 8.3 短名，旧目录 / 旧 resources / 其子目录是重解析点时整段跳过。
;
; 注意：本文件在 tauri 的 installer.nsi 顶部（MUI 页面插入之前）被 include，
; 所以这里的 !define 能影响完成页文案；MUI_FINISHPAGE_TEXT 里放的是运行时变量。

Var vegaSetupExitCode
Var vegaFinishText
Var vegaMigratePending
Var vegaOldRegUninst
Var vegaOldRegLoc
Var vegaOldRegIcon
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
Var vegaHadPreviousInstall
Var vegaAclWarning

; t6b：默认安装目录。$PROGRAMFILES64 保留原生 Program Files（Tauri 的 NSIS stub 是
; 32 位进程，$PROGRAMFILES 会被重定向到 Program Files (x86)，所以这里不用它）。
; 只作为默认值使用；真正的安装目录是运行时 $INSTDIR（用户可在目录页改，或命令行 /D=，
; 或沿用卸载注册表里的 InstallLocation）。t6b 之前的代码把它当固定目录强制写入。
!ifndef VEGA_INSTALL_DIR
  !define VEGA_INSTALL_DIR "$PROGRAMFILES64\Vega"
!endif

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
  ; 完成页文案已在 NSIS_HOOK_PREINSTALL 无条件打底（各语言默认文案），这里不再重置，
  ; 否则会在重装/更新路径上把迁移告警抹掉。失败时下面才换成具体提示。
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
    ; t6-fix2：迁移告警不在这里追加（跳过脚本的路径会漏），统一由
    ; NSIS_HOOK_POSTINSTALL 末尾的 vega_postinstall_notes 追加在最后。
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
; 旧版 / 手改过的值可能是裸路径或带尾反斜杠，两种都要能对得上本次的 $INSTDIR。
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

; t6-fix3b（架构裁定）：旧版装在本次安装目录之外（例如用户这次选了 D:\Vega，
; 旧版在 C:\Program Files\Vega）时，只删除旧目录里的 Vega 程序文件，绝不运行旧卸载器。
; 原因：旧卸载器会执行 install-rustdesk.ps1 -Uninstall，把 RustDesk 中继配置回滚掉，
; 等于用一次目录迁移毁掉现有远程协助。
;
; 注册表位置与 Tauri 的 installer.nsi 完全一致：
;   SHCTX\Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCTNAME}
; installMode=perMachine + SetContext（x64 → SetRegView 64）意味着它落在 HKLM 的 64 位视图；
; Tauri 自己也是用这个键的 InstallLocation / UninstallString 判断旧安装，读同一个值不会跑偏。
;
; 行为约定：
;   * 只在「新安装目录」与旧版记录不同时处理；/UPDATE 也执行（只删文件，不碰注册表）。
;     /UPDATE 时旧版通常就在原目录（= $INSTDIR），比较后相等即跳过；若用户改选了新目录，
;     这次在线更新也会清掉那个旧目录，避免残留可执行文件。
;   * InstallLocation / UninstallString 先归一化（去引号、去尾反斜杠），再用 Win32
;     GetFullPathNameW + GetLongPathNameW 规范化（解析 8.3 短名、. / .. 与重复分隔符），
;     与本次安装目录 $INSTDIR 大小写不敏感比较；长路径相同则不做。
;   * 旧目录本身、旧目录 \resources 以及 Vega 安装的每个 resources 子目录
;     (\resources\host、\resources\host\lib) 是重解析点（junction/symlink）时整段跳过：
;     否则逐文件 Delete 会跟着链接删到旧目录之外。旧目录的「祖先目录」不在检查范围
;     （架构裁定，见 ROADMAP「T6 加固」）。
;   * 盘根、UNC、Windows/ProgramData/用户配置目录一律拒绝（护栏）。
;   * 旧目录里必须有 vega-console.exe，否则一概不碰。
;   * 先把 $OUTDIR 指到本次安装目录，再 Delete 已知文件、非递归 RMDir 子目录与旧目录。
;     不加 /r，所以 RustDesk 配置、%ProgramData%\Vega、用户 AppData 都不会被删。
;   * 旧版还在运行导致主程序删不掉时，不做 taskkill / wmic / PowerShell 按映像路径
;     筛进程（架构裁定：安装器里不按路径杀进程），直接放弃整个旧目录清理，旧目录原样
;     保留，处理方式写进完成页提示。
;   * 旧快捷方式只有指向旧目录时才删除，并且立刻按本次安装目录重建同名快捷方式
;     （/UPDATE 下 Tauri 的 CreateOrUpdate*Shortcut 直接 Return，不重建就会没有快捷方式）。
;   * 任何失败都只追加完成页提示，绝不 Abort；卸载注册表键由新安装重写。
;   * FileFunc.nsh v3.4 没有 GetFullPathName 宏，这里直接调 Win32。
;   * GetLongPathNameW 对不存在的路径返回 0（缓冲区内容不可靠），失败时保留
;     GetFullPathNameW 的结果；真正要比较的旧目录通常存在，不存在时后续也删不到东西。
; 注意：System::Call 的 r0–r5 对应 $0–$5（不是 $R0–$R5）。这里全程只用 $0–$5，
; 并在进出宏时 Push/Pop，避免污染调用方使用的 $R0–$R9 与 nsExec/file 用的 $0–$5。
!macro VegaCanonicalDir ID VAR
  Push $0
  Push $1
  Push $2
  Push $3
  Push $4
  StrCpy $0 "${VAR}"
  System::Call 'kernel32::GetFullPathNameW(w r0, i 1024, w .r1, i 0) i .r2'
  StrCmp $2 "0" vega_canon_done_${ID}
    StrCpy ${VAR} "$1"
    ; 8.3 短名（PROGRA~1）与长名是两个不同字符串，先解析成长名再比较。
    System::Call 'kernel32::GetLongPathNameW(w r1, w .r3, i 1024) i .r4'
    StrCmp $4 "0" vega_canon_trim_${ID}
      StrCpy ${VAR} "$3"
vega_canon_trim_${ID}:
    !insertmacro VegaTrimDirPath canon_${ID} ${VAR}
vega_canon_done_${ID}:
  Pop $4
  Pop $3
  Pop $2
  Pop $1
  Pop $0
!macroend

!define FILE_ATTRIBUTE_REPARSE_POINT 0x400

; 检查路径是否带 FILE_ATTRIBUTE_REPARSE_POINT（junction / symlink / mount point）。
; 不存在（GetFileAttributesW 返回 INVALID_FILE_ATTRIBUTES = -1）不算重解析点。
; 同样只用 $0/$1（System::Call 的 r0/r1），进出宏 Push/Pop。
;
; t6b-fix3c（架构裁定）：标签只用调用方传入的 ID，**不再拼行号宏**。
; 以前标签带行号宏，但它在宏展开时按行取值：跳转语句所在行与标签定义所在行得到的
; 数字不同，于是 Goto/IntCmp 引用的名称与标签定义对不上，NSIS 报
; could not resolve label "…_1194.6" 阻断构建。唯一性改由调用点保证：同一函数内每次
; 插入都用不同的 ID（VegaValidateTarget: parent_root / parent_pf；
; VegaRemovePreviousInstall: old_dir / old_res / old_res_host / old_res_host_lib）。
; 宏体内每个跳转引用的标签名都与下面定义的完全一致。
!macro VegaIsReparsePoint ID PATH VAR
  Push $0
  Push $1
  StrCpy ${VAR} "0"
  System::Call 'kernel32::GetFileAttributesW(w "${PATH}") i .r0'
  ; INVALID_FILE_ATTRIBUTES（0xFFFFFFFF）表示路径不存在，不算重解析点。
  IntCmpU $0 0xFFFFFFFF vega_reparse_done_${ID} vega_reparse_check_${ID} vega_reparse_done_${ID}
vega_reparse_check_${ID}:
  IntOp $1 ${FILE_ATTRIBUTE_REPARSE_POINT} & $0
  StrCmp $1 "0" vega_reparse_done_${ID}
    StrCpy ${VAR} "1"
vega_reparse_done_${ID}:
  Pop $1
  Pop $0
!macroend

; t6b-fix（架构裁定）：安装目录的 ACL **总是**用 icacls 收紧（解包前预锁定 + 解包后收紧）。
; 为什么必须收紧：长期密码助手 resources\vega-pwhelper.ps1 由控制台以 runas 提权执行，
; 如果普通用户能改这个文件（或把它换掉、把所在目录换成 junction），等于把提权执行权交给
; 普通用户。$PROGRAMFILES64\Vega 靠继承 ACL 本来是对的，但旧版自选目录（D:\Vega 之类）
; 和继承了盘根 Users 写权限的目录都不可信，而且同一台机器上可能残留旧的显式 ACE，
; 按 SID 授权，中文/本地化系统里账户名不同也不会失配。$SYSDIR 绝对路径调用 icacls：
; 提权上下文里按名称搜索会被 PATH 劫持。
;
; t6c-fix1（审计 P2）：判断目录 $INSTDIR 下是否还有子项（跳过 `.` 与 `..`），三态输出：
;   "1" = 有子项；"0" = 确认为空；"E" = 枚举失败。
; t6c-fix2（架构裁定）：FindFirst 失败**或句柄为空一律输出 "E"**，不再用
; `IfFileExists "${PATH}\*.*"` 二次判定。
;   理由：此时目录刚由提权安装器 CreateDirectory 并改过 DACL，管理员枚举失败本身就是
;   异常，不该被降级成「确认为空，跳过 /reset」。旧写法还有两个副作用：`IfFileExists`
;   对**目录**的判断依赖通配符展开的语义，目录不存在与拒绝访问也分不开；多一次文件系统
;   访问又把 TOCTOU 窗口拉长。所以调用方拿到的只有「有子项 / 空 / 失败」三态，失败即
;   fail closed（第 4 步跳 vega_acl_fail）。
; FindNext 出错仍按「枚举结束」处理（NSIS 内置 FindNext 不暴露错误码，已在 ROADMAP 记录）。
; $0 先清零再 FindFirst：句柄只有真正分配成功时才非空，出错路径上不会去 FindClose 一个
; 调用方留下的陈旧句柄。
; 只用 $0/$1（句柄 / 文件名），进宏 Push，出宏 Pop；标签按调用方 ID 区分。
!macro VegaHasChildEntries ID PATH VAR
  Push $0
  Push $1
  StrCpy ${VAR} "0"
  StrCpy $0 ""
  ClearErrors
  FindFirst $0 $1 "${PATH}\*.*"
  IfErrors vega_has_child_first_error_${ID}
  StrCmp $0 "" vega_has_child_first_error_${ID}
vega_has_child_loop_${ID}:
  StrCmp $1 "." vega_has_child_next_${ID}
  StrCmp $1 ".." vega_has_child_next_${ID}
  StrCpy ${VAR} "1"
  Goto vega_has_child_done_${ID}
vega_has_child_next_${ID}:
  ClearErrors
  FindNext $0 $1
  IfErrors vega_has_child_done_${ID}
  StrCmp $1 "" vega_has_child_done_${ID}
  Goto vega_has_child_loop_${ID}
vega_has_child_first_error_${ID}:
  ; t6c-fix2：枚举失败一律 "E"，与「确认为空」不再混淆（见上方宏注释）。
  StrCpy ${VAR} "E"
vega_has_child_done_${ID}:
  StrCmp $0 "" vega_has_child_closed_${ID}
    FindClose $0
vega_has_child_closed_${ID}:
  Pop $1
  Pop $0
!macroend

; t6c（架构裁定 3）+ t6c-fix1（审计 P1/P2）：安装目录 ACL 的唯一实现。
; VegaLockInstallDir（解包前）与 VegaTightenInstallDir（解包后）都只负责 DetailPrint
; 然后 Call 这里，失败只写 $vegaAclWarning；预锁定调用方据此 SetErrorLevel 2 + Abort，
; 解包后调用方只把告警写进完成页。四个步骤严格按顺序执行，每步 nsExec 后立刻 Pop 并
; 检查，失败即跳 vega_acl_fail，绝不继续执行后续步骤：
;   1. `"$INSTDIR" /setowner *S-1-5-32-544 /C /Q`（只根目录）——先确保所有者是
;      Administrators，否则下一步改 DACL 可能因 WRITE_DAC 不足失败。
;   2. 用 PowerShell `SetSecurityDescriptorSddlForm` 写入**精确的根 DACL**，替换全部 ACE
;      （包括继承、显式拒绝和其他 SID）：
;        O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)
;      即 SYSTEM / Administrators 完全控制，Users 只读+执行，且为受保护 DACL（P，不继承）。
;      这同时完成 0.6.1 里 `/inheritance:r` 的断继承意图——但比 `/inheritance:r /grant:r`
;      更彻底：旧目录上残留的可继承显式拒绝项、其他 SID 的可继承写权限都会被替换掉，
;      不会被子项 `/reset` 带到程序文件上。
;   3. `"$INSTDIR" /setowner *S-1-5-32-544 /T /C /Q` —— 所有者（含子树）改成
;      Administrators；第 4 步的自愈依赖这一点。
;   4. 枚举 $INSTDIR 子项（三态）："E" → 失败；"1" → `"$INSTDIR\*" /reset /T /C /Q`
;      让子树回到「只继承已锁定的根目录」，并自愈旧版留下的空 DACL 文件；"0" → 确认空，
;      跳过视为成功。
;
;   $INSTDIR 只可能来自 VegaValidateTarget（`$PROGRAMFILES64\Vega` 或 `X:\Vega`），不含
;   单引号；这里仍在写入前检查一次，命中即失败，避免 PowerShell 单引号字符串被截断。
;
;   为什么不能对整个目录带 /T 做 `/inheritance:r`（0.6.1 的 bug）：对**文件**来说
;   `/inheritance:r` 会删掉全部继承 ACE，而 `(OI)(CI)` 授权无法落到文件上，`/C` 又吞掉
;   这类错误 → D:\Vega\vega-console.exe 的 DACL 变成空：用户跑不起来、管理员安装器也
;   覆盖不了（"无法打开要写入的文件"）、连删除都失败。
;
; 失败结果写进 $vegaAclWarning（空 = 四步都成功）。
;
; 残余风险（架构裁定 3）：CreateDirectory 到第 2 步写入受保护 DACL 之间仍有一瞬目录
; 继承着盘根 ACL，这一瞬的替换风险不在这份脚本能消除的范围内，已记在 ROADMAP「T6 加固」。
Function VegaApplyInstallDirAcl
  Push $0
  Push $1
  Push $2
  Push $3
  Push $R0
  Push $R1
  Push $R2
  StrCpy $vegaAclWarning ""
  StrCpy $0 "-"
  StrCpy $1 "-"
  StrCpy $2 "-"
  StrCpy $3 "-"
  ; 0. $INSTDIR 不得含单引号（PowerShell 单引号字符串会被截断）。
  ;    NSIS 没有内置的 StrStr/StrLoc 指令，裸写 StrStr 会让 makensis 报
  ;    `Invalid command: StrStr`（t6c-fix2 P1）。这里用 StrFunc.nsh 的 ${StrLoc}：
  ;    installer.nsi 在第 70-72 行 `!include "StrFunc.nsh"` + `${StrLoc}` 之后才
  ;    `!include` 本文件，宏已展开可用。${StrLoc} 找到返回下标（非空），找不到返回 ""。
  ${StrLoc} $R0 "$INSTDIR" "'" ">"
  StrCmp $R0 "" vega_acl_no_quote
    StrCpy $R2 "quote"
    Goto vega_acl_fail
vega_acl_no_quote:
  ; 1. 只对根目录改所有者。
  StrCpy $R2 "1"
  nsExec::ExecToLog '"$SYSDIR\icacls.exe" "$INSTDIR" /setowner *S-1-5-32-544 /C /Q'
  Pop $0
  StrCmp $0 "0" 0 vega_acl_fail
  ; 2. 用 SDDL 精确替换根 DACL（受保护 DACL，只有 SYSTEM / BA / BU 三条 ACE）。
  ;    先拼进 $R1 再交给 ExecToLog，降低引号嵌套复杂度。$$ → 字面 $，$INSTDIR 由 NSIS 展开。
  StrCpy $R2 "2"
  StrCpy $R1 "$\"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe$\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $\"$$ErrorActionPreference='Stop'; $$p='$INSTDIR'; $$a=Get-Acl -LiteralPath $$p; $$a.SetSecurityDescriptorSddlForm('O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)', 'Owner,Access'); Set-Acl -LiteralPath $$p -AclObject $$a; exit 0$\""
  nsExec::ExecToLog "$R1"
  Pop $1
  StrCmp $1 "0" 0 vega_acl_fail
  ; 3. 所有者（含子树）改成 Administrators。
  StrCpy $R2 "3"
  nsExec::ExecToLog '"$SYSDIR\icacls.exe" "$INSTDIR" /setowner *S-1-5-32-544 /T /C /Q'
  Pop $3
  StrCmp $3 "0" 0 vega_acl_fail
  ; 4. 子项三态：E = 枚举失败；1 = 有子项，重置子树；0 = 确认为空，跳过。
  StrCpy $R2 "4"
  !insertmacro VegaHasChildEntries acl "$INSTDIR" $2
  StrCmp $2 "E" 0 vega_acl_enum_ok
    Goto vega_acl_fail
vega_acl_enum_ok:
  StrCmp $2 "1" 0 vega_acl_reset_skip
  nsExec::ExecToLog '"$SYSDIR\icacls.exe" "$INSTDIR\*" /reset /T /C /Q'
  Pop $2
  StrCmp $2 "0" 0 vega_acl_fail
  Goto vega_acl_done
vega_acl_reset_skip:
  DetailPrint "安装目录为空，跳过子项 /reset（无子项可重置）"
vega_acl_done:
  Goto vega_acl_exit
vega_acl_fail:
  StrCpy $vegaAclWarning "安装目录权限设置失败（步骤 $R2，返回 $0/$1/$2/$3），长期密码不可用"
  DetailPrint "$vegaAclWarning"
vega_acl_exit:
  Pop $R2
  Pop $R1
  Pop $R0
  Pop $3
  Pop $2
  Pop $1
  Pop $0
FunctionEnd

; 解包前的预锁定：只打日志后调用共用实现。安装节据 $vegaAclWarning 决定 SetErrorLevel 2 + Abort。
Function VegaLockInstallDir
  DetailPrint "锁定安装目录权限（解包前，仅管理员可写）：$INSTDIR"
  Call VegaApplyInstallDirAcl
FunctionEnd

; 解包后的收紧：同样调用共用实现；失败只写 $vegaAclWarning，完成页显示，不 Abort。
Function VegaTightenInstallDir
  DetailPrint "收紧安装目录权限（解包后，仅管理员可写）：$INSTDIR"
  Call VegaApplyInstallDirAcl
FunctionEnd

; 旧快捷方式：只有确实指向旧目录的主程序时才删，删完立刻按本次安装目录重建同名快捷方式。
; 这样 /UPDATE（Tauri 的 CreateOrUpdate*Shortcut 在 UpdateMode 下直接 Return）结束时
; 不会留下没有任何快捷方式的安装。$R5 由 IsShortcutTarget 压栈返回。
;   * 不重建到旧目录：旧目录正在被删除，指向它的快捷方式必然失效。
;   * 不用 SetLnkAppUserModelId：目标文件此刻还没从安装包里解出来，重建只保证路径正确。
!macro VegaMigrateShortcut ID LINK DIR
  !insertmacro IsShortcutTarget "${LINK}" "$vegaOldInstallDir\vega-console.exe"
  Pop $R5
  StrCmp $R5 "1" 0 vega_sc_done_${ID}
    Delete "${LINK}"
    CreateDirectory "${DIR}"
    CreateShortcut "${LINK}" "$INSTDIR\vega-console.exe" "" "$INSTDIR\vega-console.exe" 0 SW_SHOWNORMAL "" "$INSTDIR"
    DetailPrint "快捷方式 ${LINK} 已改指向 $INSTDIR\vega-console.exe"
vega_sc_done_${ID}:
!macroend

!macro VegaRemovePreviousInstall
  StrCpy $vegaOldInstallDir ""
  StrCpy $vegaOldInstallWarning ""
  StrCpy $vegaMigratePending "0"

  ; t6-fix4：/UPDATE 也走这里。迁移只做文件删除，不会回滚 RustDesk 配置；
  ; 若旧版就在本次安装目录（t6b：$INSTDIR），下面的长路径比较会直接跳过。
  StrCpy $R7 "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCTNAME}"
  ; 原样保存旧卸载入口：迁移中止（新卸载器没写成）时在 POSTINSTALL 恢复，系统卸载入口不失效。
  ReadRegStr $vegaOldRegUninst SHCTX "$R7" "UninstallString"
  ReadRegStr $vegaOldRegLoc SHCTX "$R7" "InstallLocation"
  ReadRegStr $vegaOldRegIcon SHCTX "$R7" "DisplayIcon"
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

  ; t6b：比较对象是本次的最终安装目录 $INSTDIR（用户可能选在 D:\ 或沿用旧位置），
  ; 不再是比较固定的 Program Files 目录。
  StrCpy $vegaFixedDir "$INSTDIR"
  !insertmacro VegaCanonicalDir fixed $vegaFixedDir

  ; 大小写不敏感比较，尾部反斜杠已在上一步去掉。
  ${StrCase} $R8 "$vegaOldInstallDir" "L"
  ${StrCase} $R9 "$vegaFixedDir" "L"
  StrCmp $R8 $R9 0 vega_old_differs
    DetailPrint "旧版安装目录就是本次安装目录 $INSTDIR，按就地升级处理。"
    Goto vega_old_done

vega_old_differs:
  ; 护栏零：旧目录、旧 resources 以及 Vega 安装的每个 resources 子目录是重解析点
  ; （junction/symlink）时不删任何东西，否则 Delete 会沿着链接越出旧目录。
  !insertmacro VegaIsReparsePoint old_dir "$vegaOldInstallDir" $R0
  StrCmp $R0 "1" vega_old_reparse
  !insertmacro VegaIsReparsePoint old_res "$vegaOldInstallDir\resources" $R0
  StrCmp $R0 "1" vega_old_reparse
  !insertmacro VegaIsReparsePoint old_res_host "$vegaOldInstallDir\resources\host" $R0
  StrCmp $R0 "1" vega_old_reparse
  !insertmacro VegaIsReparsePoint old_res_host_lib "$vegaOldInstallDir\resources\host\lib" $R0
  StrCmp $R0 "1" vega_old_reparse

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

vega_old_reparse:
  DetailPrint "旧版目录 $vegaOldInstallDir 或其 resources 子目录是重解析点，跳过清理。"
  Goto vega_old_done

vega_old_refused:
  DetailPrint "旧版记录指向 $vegaOldInstallDir，看起来不是安装目录，跳过清理。"
  Goto vega_old_done

vega_old_check_binary:
  ; 护栏三：只处理确实含 vega-console.exe 的目录。
  IfFileExists "$vegaOldInstallDir\vega-console.exe" 0 vega_old_no_binary
  ; t6-fix5（r4 P2）：PREINSTALL 只判定，不删除。新文件写入成功、到 POSTINSTALL 时
  ; 才删旧文件并改快捷方式；新程序解包失败或用户取消时旧版仍然完整可用。
  StrCpy $vegaMigratePending "1"
  Goto vega_old_done

vega_old_no_binary:
  DetailPrint "旧版记录指向 $vegaOldInstallDir，但没有 vega-console.exe，跳过旧目录清理。"

vega_old_done:
!macroend

; POSTINSTALL 调用：新文件已写入本次安装目录后再清理旧目录。
!macro VegaFinishPreviousInstall
  StrCmp $vegaMigratePending "1" 0 vega_mig_done
  StrCpy $vegaMigratePending "0"
  ; 双保险：新主程序必须已在本次安装目录 $INSTDIR 里，否则保留旧版不动。
  ; 同名目录也会让 IfFileExists 成立：用「路径\*.*」排除目录，只认真正的文件。
  IfFileExists "$INSTDIR\uninstall.exe\*.*" vega_mig_new_missing
  IfFileExists "$INSTDIR\vega-console.exe\*.*" vega_mig_new_missing
  IfFileExists "$INSTDIR\uninstall.exe" 0 vega_mig_new_missing
  IfFileExists "$INSTDIR\vega-console.exe" vega_mig_new_same_check
vega_mig_new_missing:
  ; 新卸载器/主程序无效（磁盘满、同名目录等）：模板已把卸载入口改到 $INSTDIR，
  ; 这里改回旧版的原值，旧版仍可从「应用和功能」卸载。
  StrCmp $vegaOldRegUninst "" vega_mig_reg_restored
    WriteRegStr SHCTX "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCTNAME}" "UninstallString" "$vegaOldRegUninst"
    WriteRegStr SHCTX "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCTNAME}" "InstallLocation" "$vegaOldRegLoc"
    WriteRegStr SHCTX "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCTNAME}" "DisplayIcon" "$vegaOldRegIcon"
    DetailPrint "已把系统卸载入口恢复为旧版：$vegaOldRegUninst"
vega_mig_reg_restored:
    StrCpy $vegaOldInstallWarning "新版主程序或卸载器没有写入 $INSTDIR，旧版 $vegaOldInstallDir 保持原样，请重新运行安装包。"
    DetailPrint "$vegaOldInstallWarning"
    Goto vega_mig_done
vega_mig_new_same_check:
  ; 盘符别名（subst）、挂载点等让两个字符串不同的路径指向同一目录：在 $INSTDIR 写一个
  ; 探针文件，再从旧路径看它是否出现。出现即同一目录，绝不删除。
  ClearErrors
  FileOpen $R0 "$INSTDIR\.vega-migrate-probe" w
  IfErrors vega_mig_probe_failed
  FileClose $R0
  IfFileExists "$vegaOldInstallDir\.vega-migrate-probe" 0 vega_mig_probe_differs
    Delete "$INSTDIR\.vega-migrate-probe"
    DetailPrint "旧版目录 $vegaOldInstallDir 与 $INSTDIR 是同一目录（别名），不清理。"
    Goto vega_mig_done
vega_mig_probe_failed:
    DetailPrint "无法在 $INSTDIR 写入迁移探针，为安全起见不清理旧目录。"
    Goto vega_mig_done
vega_mig_probe_differs:
  Delete "$INSTDIR\.vega-migrate-probe"
vega_mig_new_ok:
  DetailPrint "发现旧版 Vega 装在 $vegaOldInstallDir，删除旧程序文件（不运行旧卸载器，RustDesk 与配置保持原样）…"

  ; 先保证当前解包目录是本次安装目录，避免后续 File 落回旧目录。
  SetOutPath "$INSTDIR"

  ; 旧版还在运行（vega-console.exe 被占用）时 Delete 会失败。架构裁定：不做
  ; taskkill / wmic / PowerShell 按映像路径筛选进程（那需要按路径匹配，容易误杀，
  ; 也不该在安装器里调 PowerShell 找进程）；改成「先试删主程序，删不掉就整段放弃」，
  ; 只把处理方式写到完成页，旧目录原样保留。
  Delete "$vegaOldInstallDir\vega-console.exe"
  IfFileExists "$vegaOldInstallDir\vega-console.exe" 0 vega_old_delete_rest
    StrCpy $vegaOldInstallWarning "旧版 Vega 仍在运行（$vegaOldInstallDir\vega-console.exe 被占用），旧目录未清理。请完全退出旧版 Vega（托盘图标 → 退出）后手动删除该目录；快捷方式已指向 $INSTDIR。"
    DetailPrint "$vegaOldInstallWarning"
    Goto vega_old_shortcuts

vega_old_delete_rest:
  ; 只删 Tauri 安装的已知文件（主程序 + tauri.conf.json resources + 卸载器）。
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

vega_old_shortcuts:
  ; 快捷方式：指向旧目录的就地改成本次安装目录，删完立刻重建（/UPDATE 下 Tauri 不建快捷方式）。
  !insertmacro VegaMigrateShortcut old_sc_sm "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$SMPROGRAMS"
  StrCmp $AppStartMenuFolder "" vega_old_shortcut_sub_done
  !insertmacro VegaMigrateShortcut old_sc_sub "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "$SMPROGRAMS\$AppStartMenuFolder"
vega_old_shortcut_sub_done:
  !insertmacro VegaMigrateShortcut old_sc_desk "$DESKTOP\${PRODUCTNAME}.lnk" "$DESKTOP"

  ; 主程序没删掉（仍在运行）时不再检查目录内容，上面的告警已经说明原因。
  IfFileExists "$vegaOldInstallDir\vega-console.exe" vega_mig_done
  IfFileExists "$vegaOldInstallDir\*.*" 0 vega_old_cleaned
    StrCpy $vegaOldInstallWarning "旧版目录 $vegaOldInstallDir 的程序文件已删除，但目录里仍有其他文件（可能不是 Vega 的），已保留，可手动删除。"
    DetailPrint "$vegaOldInstallWarning"
    Goto vega_mig_done
vega_old_cleaned:
  DetailPrint "旧版目录 $vegaOldInstallDir 已清理。"

vega_mig_done:
!macroend

; t6b：安装路径由模板 .onInit（/D=、卸载注册表 InstallLocation、默认
; $PROGRAMFILES64\Vega）与目录页选择共同决定；Tauri 在 PREINSTALL 之后才复制文件、
; 写注册表与快捷方式，所以这里只做兜底（$INSTDIR 为空时才用默认值）并 SetOutPath，
; 不再改写用户的选择。
!macro NSIS_HOOK_PREINSTALL
  ; t6-fix5 P3：完成页文案无条件先打底。VegaRunInstallRustDesk 在重装与 /UPDATE 下会被
  ; 跳过，如果只在脚本宏里初始化，/UPDATE 的完成页就是空白（MUI_FINISHPAGE_TEXT 引用
  ; 的是 $vegaFinishText 运行时值）。各语言默认文案在 .onInit 之后仍可用。
  StrCpy $vegaFinishText "$(MUI_TEXT_FINISH_INFO_TEXT)"

  ; t6-fix4：Tauri 在 PREINSTALL 之后才复制文件并重写卸载注册表项。先在这里
  ; 记录「安装前是否已有 Vega 卸载键」，POSTINSTALL 据此区分全新安装与重装/更新。
  StrCpy $vegaHadPreviousInstall "0"
  StrCpy $R0 "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCTNAME}"
  ReadRegStr $R1 SHCTX "$R0" ""
  ReadRegStr $R2 SHCTX "$R0" "UninstallString"
  ReadRegStr $R3 SHCTX "$R0" "InstallLocation"
  StrCmp "$R1$R2$R3" "" vega_preinstall_no_previous
    StrCpy $vegaHadPreviousInstall "1"
vega_preinstall_no_previous:

  ; t6b：安装目录由 .onInit（/D、卸载注册表 InstallLocation、默认 Program Files）
  ; 或目录页选择决定，这里只在极端情况下兜底，不再强制改写用户的选择。
  StrCmp $INSTDIR "" 0 vega_preinstall_dir_done
    DetailPrint "安装目录为空，使用默认目录 ${VEGA_INSTALL_DIR}"
    StrCpy $INSTDIR "${VEGA_INSTALL_DIR}"
vega_preinstall_dir_done:
  ; 先处理旧安装目录（与 $INSTDIR 比较）：从注册表读旧安装记录做迁移，但不运行旧卸载器。
  !insertmacro VegaRemovePreviousInstall
  ; 双保险：让 $OUTDIR 指向本次安装目录，后续 File 一定解到新目录。
  SetOutPath "$INSTDIR"
!macroend

!macro NSIS_HOOK_POSTINSTALL
  ; t6c（架构裁定 3）+ t6c-fix1：这里只调 VegaTightenInstallDir——它有 DetailPrint 后
  ; Call 共用 VegaApplyInstallDirAcl：根 setowner → 根 DACL 用 SDDL 精确替换 →
  ; setowner /T → 子项三态枚举并按需 `"$INSTDIR\*" /reset /T`。
  ; 子项 /reset 只把子项改回继承已锁定的根目录，不会让根目录重新继承盘根 ACL；
  ; 根目录本身**绝不再**带 /T 做断继承（0.6.1 的空 DACL bug）。
  ; 失败只写完成页告警，不 Abort（程序已经装好了）。
  Call VegaTightenInstallDir
  ; 新文件已就位：此时才清理旧目录、改快捷方式（见 VegaFinishPreviousInstall）。
  !insertmacro VegaFinishPreviousInstall
  ; t6-fix4（架构裁定）：
  ;   * 全新安装（PREINSTALL 没读到旧卸载键）→ 照旧运行 RustDesk 安装/配置脚本。
  ;   * 重装或 /UPDATE → 默认完全跳过脚本，不下载、不改中继配置；只有 Program Files
  ;     下找不到 rustdesk.exe 时才补跑（此时必须安装并配置，否则新控制台没有可用的
  ;     RustDesk）。$PROGRAMFILES 在 32 位 stub 里是 (x86)，两个都查。
  StrCmp $vegaHadPreviousInstall "1" vega_postinstall_skip
  StrCmp $UpdateMode "1" vega_postinstall_skip
  Goto vega_postinstall_run

vega_postinstall_skip:
  IfFileExists "$PROGRAMFILES64\RustDesk\rustdesk.exe" vega_postinstall_notes
  IfFileExists "$PROGRAMFILES\RustDesk\rustdesk.exe" vega_postinstall_notes
  DetailPrint "已有 Vega 安装记录，但 Program Files 下没有 rustdesk.exe：补装并配置 RustDesk。"

vega_postinstall_run:
  !insertmacro VegaRunInstallRustDesk

vega_postinstall_notes:
  ; t6-fix5 P3：迁移告警在「跑脚本」和「跳过脚本」两条路径下都要出现。
  StrCmp $vegaOldInstallWarning "" vega_postinstall_acl
    StrCpy $vegaFinishText "$vegaFinishText$\r$\n$\r$\n$vegaOldInstallWarning"
vega_postinstall_acl:
  ; t6b：ACL 收紧失败同样写进完成页（此时长期密码会被控制台拒绝）。
  StrCmp $vegaAclWarning "" vega_postinstall_done
    StrCpy $vegaFinishText "$vegaFinishText$\r$\n$\r$\n$vegaAclWarning"
vega_postinstall_done:
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  !insertmacro VegaRunUninstallRustDesk
!macroend
