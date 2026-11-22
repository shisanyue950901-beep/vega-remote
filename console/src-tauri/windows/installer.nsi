; ---------------------------------------------------------------------------
; Vega 定制 NSIS 模板（t6-fix3b）
;
; 上游：tauri-cli v2.12.6
;   crates/tauri-bundler/src/bundle/windows/nsis/installer.nsi
;   https://github.com/tauri-apps/tauri/blob/tauri-cli-v2.12.6/crates/tauri-bundler/src/bundle/windows/nsis/installer.nsi
;
; 与上游的差异（全部列出，其余原样保留，便于逐版本重新同步）：
;   1. 恢复「选择安装目录」页（上游的 MUI_PAGE_DIRECTORY +
;      MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive），并加 LEAVE 回调 VegaDirectoryLeave。
;      允许的位置只有两种：$PROGRAMFILES64\Vega，或 <X>:\Vega（本地固定 NTFS 盘根目录下的
;      Vega）。其它选择由 VegaValidateTarget 规范化并提示用户：落在 Program Files 里的收成
;      $PROGRAMFILES64\Vega，其余按所选路径的盘符收成 <X>:\Vega。
;      原因见 hooks.nsh 的 t6b 说明（ACL 由安装器收紧）。
;   2. 目标校验只有一份：VegaValidateTarget 同时被目录页回调与安装节开头调用，
;      静默 / 被动 / `/D=` 安装不会绕过。t6b-fix2 起 /D= 不再搜 $CMDLINE（NSIS 已把它
;      写进 $INSTDIR 并从 $CMDLINE 移除），而是在 .onInit 第一行把 $INSTDIR 备份到
;      $vegaCmdlineDir：非空即给了 /D=，否则优先沿用卸载注册表里校验通过的旧位置，
;      最后才用 $PROGRAMFILES64\Vega。InstallDir 属性留空，避免内置占位路径混进判断。
;      t6b-fix2 还让校验拒绝目标树里的重解析点、无法枚举的目录，以及是重解析点的父目录。
;   3. 删除「重新安装 / 已安装」页（PageReinstall、PageReinstallUpdateSelection、
;      PageLeaveReinstall 及 Var ReinstallPageCheck）。安装器永远不运行旧卸载器，
;      也不再询问卸载/重装，直接在安装目录上覆盖安装。
;   4. 删除 `Var WixMode` 及快捷方式里「从 WiX 迁移时强制重建」的分支（迁移路径已不存在）。
;   5. 删除 `choowHowToInstall` 的 LangString 兜底与其注释（只有已删除的重装页会读它）。
;   6. 降级检查（ALLOWDOWNGRADES=false）改为在所有模式执行：页面删除后，交互模式
;      不再有「先卸载再降级」的选择，必须在 .onInit 直接拒绝。
;   7. 保留 FindWixInstall：它仍用于降级检查时比较 WiX 安装的版本号，但不再触发卸载。
;   8. 安装节开头先 `Call VegaValidateTarget`（在任何 SetOutPath 之前）：静默 / 被动
;      / `/D=` 安装与交互安装共用同一份目标校验，失败 `SetErrorLevel 2` 并中止。
;      t6b-fix2 接着 CreateDirectory + Call VegaLockInstallDir 预锁定 ACL，任何一条
;      icacls 失败都在解包之前中止；POSTINSTALL 再锁第二次（失败只写完成页告警）。
;
; 为什么不用宏覆盖：MUI2.nsh 在 include 时就把 MUI_PAGE_DIRECTORY 展开成页面序号，
; hooks.nsh 里 !undef + 空宏不起作用（页面照样出现）。只能改模板本体。
; ---------------------------------------------------------------------------
Unicode true
ManifestDPIAware true
; Add in `dpiAwareness` `PerMonitorV2` to manifest for Windows 10 1607+ (note this should not affect lower versions since they should be able to ignore this and pick up `dpiAware` `true` set by `ManifestDPIAware true`)
; Currently undocumented on NSIS's website but is in the Docs folder of source tree, see
; https://github.com/kichik/nsis/blob/5fc0b87b819a9eec006df4967d08e522ddd651c9/Docs/src/attributes.but#L286-L300
; https://github.com/tauri-apps/tauri/pull/10106
ManifestDPIAwareness PerMonitorV2

!if "{{compression}}" == "none"
  SetCompress off
!else
  ; Set the compression algorithm. We default to LZMA.
  SetCompressor /SOLID "{{compression}}"
!endif

; Keep above !include to stay ahead of any plugin command
; see https://github.com/tauri-apps/tauri/pull/15422#discussion_r3289239624
{{#if signed_plugins_path}}
!addplugindir "{{signed_plugins_path}}"
{{/if}}

!include MUI2.nsh
!include FileFunc.nsh
!include x64.nsh
!include WordFunc.nsh
!include "utils.nsh"
!include "FileAssociation.nsh"
!include "Win\COM.nsh"
!include "Win\Propkey.nsh"
!include "Win\RestartManager.nsh"
!include "StrFunc.nsh"
${StrCase}
${StrLoc}

{{#if installer_hooks}}
!include "{{installer_hooks}}"
{{/if}}

!define WEBVIEW2APPGUID "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

!define MANUFACTURER "{{manufacturer}}"
!define PRODUCTNAME "{{product_name}}"
!define VERSION "{{version}}"
!define VERSIONWITHBUILD "{{version_with_build}}"
!define HOMEPAGE "{{homepage}}"
!define INSTALLMODE "{{install_mode}}"
!define LICENSE "{{license}}"
!define INSTALLERICON "{{installer_icon}}"
!define SIDEBARIMAGE "{{sidebar_image}}"
!define HEADERIMAGE "{{header_image}}"
!define UNINSTALLERICON "{{uninstaller_icon}}"
!define UNINSTALLERHEADERIMAGE "{{uninstaller_header_image}}"
!define MAINBINARYNAME "{{main_binary_name}}"
!define MAINBINARYSRCPATH "{{main_binary_path}}"
!define BUNDLEID "{{bundle_id}}"
!define COPYRIGHT "{{copyright}}"
!define OUTFILE "{{out_file}}"
!define ARCH "{{arch}}"
!define ADDITIONALPLUGINSPATH "{{additional_plugins_path}}"
!define ALLOWDOWNGRADES "{{allow_downgrades}}"
!define DISPLAYLANGUAGESELECTOR "{{display_language_selector}}"
!define INSTALLWEBVIEW2MODE "{{install_webview2_mode}}"
!define WEBVIEW2INSTALLERARGS "{{webview2_installer_args}}"
!define WEBVIEW2BOOTSTRAPPERPATH "{{webview2_bootstrapper_path}}"
!define WEBVIEW2INSTALLERPATH "{{webview2_installer_path}}"
!define MINIMUMWEBVIEW2VERSION "{{minimum_webview2_version}}"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCTNAME}"
!define MANUKEY "Software\${MANUFACTURER}"
!define MANUPRODUCTKEY "${MANUKEY}\${PRODUCTNAME}"
!define UNINSTALLERSIGNCOMMAND "{{uninstaller_sign_cmd}}"
!define ESTIMATEDSIZE "{{estimated_size}}"
!define STARTMENUFOLDER "{{start_menu_folder}}"

Var PassiveMode
Var UpdateMode
Var NoShortcutMode
Var OldMainBinaryName

; t6b-fix（架构裁定）：VegaValidateTarget 的唯一输出与两个调用方共享的临时变量。
;   * $vegaTargetError   为空表示目标通过校验；否则是整句中文错误（调用方决定提示方式）。
;   * $vegaTargetChanged 1 表示规范化改变了用户选/输的路径（目录页提示用）。
;   * $vegaTargetEmpty   目标目录是否为空（FindFirst/FindNext 判定，跳过 . 与 ..）。
; vegaTmp* 只用于跨 ${StrCase} 暂存，避免依赖 StrFunc 内部用到的寄存器。
Var vegaTargetError
Var vegaTargetChanged
; t6b-fix2（架构裁定 4）：.onInit 第一行把 NSIS 预写的 $INSTDIR（= /D= 的值）备份
; 到这里。非空 ⇔ 命令行给了 /D=；$CMDLINE 里的 /D= 已被 NSIS 移除，不能再搜。
Var vegaCmdlineDir
Var vegaTargetEmpty
; t6b-fix2（架构裁定 2/3）：VegaScanReparseTree 的输入/输出。
;   * $vegaWalkPath  当前待检查的目录（栈式遍历的工作变量，入口放 $INSTDIR）。
;   * $vegaWalkFound 1 表示目标树里（含目标本身）出现重解析点。
;   * $vegaWalkError 1 表示某个已存在目录无法枚举（FindFirst 失败）。
Var vegaWalkPath
Var vegaWalkFound
Var vegaWalkError
; t6b-fix3（架构裁定 3/5）：最近一次枚举失败的 GetLastError 码（0 = 没有错误）。
; 预锁定后的重扫用它写中止原因，不再把「读不了」当成「不存在」。
Var vegaWalkErrCode
Var vegaTmp1
Var vegaTmp2
Var vegaTmp3

Name "${PRODUCTNAME}"
BrandingText "${COPYRIGHT}"
OutFile "${OUTFILE}"

; t6b-fix2（架构裁定 4）：InstallDir 留空。Tauri 模板原来放了一个占位路径
; `placeholder\${PRODUCTNAME}`，NSIS 会先把它写进 $INSTDIR，再在 .onInit 之前把
; `/D=` 覆盖上去，于是没法只凭 $INSTDIR 判断用户到底给没给 /D=。
; 留空后：没给 /D= 时 $INSTDIR 为空，给了就是命令行目录；默认值统一在 .onInit 里赋值。
; https://nsis.sourceforge.io/Reference/InstallDir
InstallDir ""

VIProductVersion "${VERSIONWITHBUILD}"
VIAddVersionKey "ProductName" "${PRODUCTNAME}"
VIAddVersionKey "FileDescription" "${PRODUCTNAME}"
VIAddVersionKey "LegalCopyright" "${COPYRIGHT}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"

# additional plugins
!addplugindir "${ADDITIONALPLUGINSPATH}"

; Uninstaller signing command
!if "${UNINSTALLERSIGNCOMMAND}" != ""
  !uninstfinalize '${UNINSTALLERSIGNCOMMAND}'
!endif

; Handle install mode, `perUser`, `perMachine` or `both`
!if "${INSTALLMODE}" == "perMachine"
  RequestExecutionLevel admin
!endif

!if "${INSTALLMODE}" == "currentUser"
  RequestExecutionLevel user
!endif

!if "${INSTALLMODE}" == "both"
  !define MULTIUSER_MUI
  !define MULTIUSER_INSTALLMODE_INSTDIR "${PRODUCTNAME}"
  !define MULTIUSER_INSTALLMODE_COMMANDLINE
  !if "${ARCH}" == "x64"
    !define MULTIUSER_USE_PROGRAMFILES64
  !else if "${ARCH}" == "arm64"
    !define MULTIUSER_USE_PROGRAMFILES64
  !endif
  !define MULTIUSER_INSTALLMODE_DEFAULT_REGISTRY_KEY "${UNINSTKEY}"
  !define MULTIUSER_INSTALLMODE_DEFAULT_REGISTRY_VALUENAME "CurrentUser"
  !define MULTIUSER_INSTALLMODEPAGE_SHOWUSERNAME
  !define MULTIUSER_INSTALLMODE_FUNCTION RestorePreviousInstallLocation
  !define MULTIUSER_EXECUTIONLEVEL Highest
  !include MultiUser.nsh
!endif

; Installer icon
!if "${INSTALLERICON}" != ""
  !define MUI_ICON "${INSTALLERICON}"
!endif

; Installer sidebar image
!if "${SIDEBARIMAGE}" != ""
  !define MUI_WELCOMEFINISHPAGE_BITMAP "${SIDEBARIMAGE}"
!endif

; Enable header images for installer and uninstaller pages when either image is configured.
!if "${HEADERIMAGE}" != ""
  !define MUI_HEADERIMAGE
!else if "${UNINSTALLERHEADERIMAGE}" != ""
  !define MUI_HEADERIMAGE
!endif

; Installer header image
!if "${HEADERIMAGE}" != ""
  !define MUI_HEADERIMAGE_BITMAP "${HEADERIMAGE}"
!endif

; Uninstaller header image
!if "${UNINSTALLERHEADERIMAGE}" != ""
  !define MUI_HEADERIMAGE_UNBITMAP "${UNINSTALLERHEADERIMAGE}"
!endif

; Uninstaller icon
!if "${UNINSTALLERICON}" != ""
  !define MUI_UNICON "${UNINSTALLERICON}"
!endif

; Define registry key to store installer language
!define MUI_LANGDLL_REGISTRY_ROOT "HKCU"
!define MUI_LANGDLL_REGISTRY_KEY "${MANUPRODUCTKEY}"
!define MUI_LANGDLL_REGISTRY_VALUENAME "Installer Language"

; Installer pages, must be ordered as they appear
; 1. Welcome Page
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
!insertmacro MUI_PAGE_WELCOME

; 2. License Page (if defined)
!if "${LICENSE}" != ""
  !define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
  !insertmacro MUI_PAGE_LICENSE "${LICENSE}"
!endif

; 3. Install mode (if it is set to `both`)
!if "${INSTALLMODE}" == "both"
  !define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
  !insertmacro MULTIUSER_PAGE_INSTALLMODE
!endif

; 4. 上游的「重新安装 / 已安装」页（PageReinstall / PageLeaveReinstall /
;    PageReinstallUpdateSelection）及其 Var ReinstallPageCheck 已整体删除：
;    安装器永远不运行旧卸载器，也不询问是否卸载，直接在固定目录上覆盖安装。
;    上游该页会先执行旧卸载器（旧卸载器会回滚 RustDesk 中继配置），这正是要杜绝的。
;    编号保留，便于与上游逐行对照。

; Find a previous WiX installation and set $R6 to its uninstall registry key, or to "" if none.
;
; A WiX installer stores the installation info in registry
; using a UUID and so we have to loop through all keys under
; `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`
; and check if `DisplayName` and `Publisher` keys match ${PRODUCTNAME} and ${MANUFACTURER}
;
; 本模板只在 .onInit 的降级检查里调用它来读取 DisplayVersion；不再据此运行 MSI 卸载器。
Function FindWixInstall
  StrCpy $R6 ""
  StrCpy $0 0
  wix_loop:
    EnumRegKey $1 HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" $0
    StrCmp $1 "" wix_loop_done ; Exit loop if there is no more keys to loop on
    IntOp $0 $0 + 1
    ReadRegStr $R0 HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$1" "DisplayName"
    ReadRegStr $R1 HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$1" "Publisher"
    StrCmp "$R0$R1" "${PRODUCTNAME}${MANUFACTURER}" 0 wix_loop
    ReadRegStr $R0 HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$1" "UninstallString"
    ${StrCase} $R1 $R0 "L"
    ${StrLoc} $R0 $R1 "msiexec" ">"
    StrCmp $R0 0 0 wix_loop_done
    StrCpy $R6 "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$1"
  wix_loop_done:
FunctionEnd

; 5. Directory page（t6b：用户要求可装到 D: 等本地固定 NTFS 目录，恢复该页）
;    用户可改安装目录；LEAVE 校验见文件末尾的 VegaDirectoryLeave。
;    静默 / 被动安装（/S、/P、/UPDATE）跳过该页，$INSTDIR 由 .onInit 决定。
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE VegaDirectoryLeave
!insertmacro MUI_PAGE_DIRECTORY

; 6. Start menu shortcut page
Var AppStartMenuFolder
!if "${STARTMENUFOLDER}" != ""
  !define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
  !define MUI_STARTMENUPAGE_DEFAULTFOLDER "${STARTMENUFOLDER}"
!else
  !define MUI_PAGE_CUSTOMFUNCTION_PRE Skip
!endif
!insertmacro MUI_PAGE_STARTMENU Application $AppStartMenuFolder

; 7. Installation page
!insertmacro MUI_PAGE_INSTFILES

; 8. Finish page
;
; Don't auto jump to finish page after installation page,
; because the installation page has useful info that can be used debug any issues with the installer.
!define MUI_FINISHPAGE_NOAUTOCLOSE
; Use show readme button in the finish page as a button create a desktop shortcut
!define MUI_FINISHPAGE_SHOWREADME
!define MUI_FINISHPAGE_SHOWREADME_TEXT "$(createDesktop)"
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION CreateOrUpdateDesktopShortcut
; Show run app after installation.
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION RunMainBinary
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
!insertmacro MUI_PAGE_FINISH

Function RunMainBinary
  nsis_tauri_utils::RunAsUser "$INSTDIR\${MAINBINARYNAME}.exe" ""
FunctionEnd

; Uninstaller Pages
; 1. Confirm uninstall page
Var DeleteAppDataCheckbox
Var DeleteAppDataCheckboxState
!define /ifndef WS_EX_LAYOUTRTL         0x00400000
!define MUI_PAGE_CUSTOMFUNCTION_SHOW un.ConfirmShow
Function un.ConfirmShow ; Add add a `Delete app data` check box
  ; $1 inner dialog HWND
  ; $2 window DPI
  ; $3 style
  ; $4 x
  ; $5 y
  ; $6 width
  ; $7 height
  FindWindow $1 "#32770" "" $HWNDPARENT ; Find inner dialog
  System::Call "user32::GetDpiForWindow(p r1) i .r2"
  ${If} $(^RTL) = 1
    StrCpy $3 "${__NSD_CheckBox_EXSTYLE} | ${WS_EX_LAYOUTRTL}"
    IntOp $4 50 * $2
  ${Else}
    StrCpy $3 "${__NSD_CheckBox_EXSTYLE}"
    IntOp $4 0 * $2
  ${EndIf}
  IntOp $5 100 * $2
  IntOp $6 400 * $2
  IntOp $7 25 * $2
  IntOp $4 $4 / 96
  IntOp $5 $5 / 96
  IntOp $6 $6 / 96
  IntOp $7 $7 / 96
  System::Call 'user32::CreateWindowEx(i r3, w "${__NSD_CheckBox_CLASS}", w "$(deleteAppData)", i ${__NSD_CheckBox_STYLE}, i r4, i r5, i r6, i r7, p r1, i0, i0, i0) i .s'
  Pop $DeleteAppDataCheckbox
  SendMessage $HWNDPARENT ${WM_GETFONT} 0 0 $1
  SendMessage $DeleteAppDataCheckbox ${WM_SETFONT} $1 1
FunctionEnd
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE un.ConfirmLeave
Function un.ConfirmLeave
  SendMessage $DeleteAppDataCheckbox ${BM_GETCHECK} 0 0 $DeleteAppDataCheckboxState
FunctionEnd
!define MUI_PAGE_CUSTOMFUNCTION_PRE un.SkipIfPassive
!insertmacro MUI_UNPAGE_CONFIRM

; 2. Uninstalling Page
!insertmacro MUI_UNPAGE_INSTFILES

;Languages
{{#each languages}}
!insertmacro MUI_LANGUAGE "{{this}}"
{{/each}}
!insertmacro MUI_RESERVEFILE_LANGDLL
{{#each language_files}}
  !include "{{this}}"
{{/each}}

Function .onInit
  ; t6b-fix2（架构裁定 4）：在任何模板代码碰 $INSTDIR 之前备份它。NSIS 已在进入
  ; .onInit 之前把 `/D=` 写进 $INSTDIR 并从 $CMDLINE 移除了该参数，所以这里
  ; 非空 ⇔ 命令行给了 /D=。后面一律用 $vegaCmdlineDir 判断，不再搜 $CMDLINE。
  StrCpy $vegaCmdlineDir "$INSTDIR"

  ${GetOptions} $CMDLINE "/P" $PassiveMode
  ${IfNot} ${Errors}
    StrCpy $PassiveMode 1
  ${EndIf}

  ${GetOptions} $CMDLINE "/NS" $NoShortcutMode
  ${IfNot} ${Errors}
    StrCpy $NoShortcutMode 1
  ${EndIf}

  ${GetOptions} $CMDLINE "/UPDATE" $UpdateMode
  ${IfNot} ${Errors}
    StrCpy $UpdateMode 1
  ${EndIf}

  !if "${DISPLAYLANGUAGESELECTOR}" == "true"
    !insertmacro MUI_LANGDLL_DISPLAY
  !endif

  !insertmacro SetContext

  !if "${INSTALLMODE}" == "both"
    !insertmacro MULTIUSER_INIT
  !endif

  ; --- Vega customization (t6b-fix / t6b-fix2) ----------------------------
  ; 允许的安装位置只有两种（架构裁定）：
  ;   * $PROGRAMFILES64\Vega —— 默认；继承 ACL 已经是管理员独占写；
  ;   * <X>:\Vega —— 本地固定 NTFS 盘根目录下的 Vega；安装后由 icacls 收紧 ACL。
  ; 其它输入由 VegaValidateTarget 统一规范成 <X>:\Vega（取用户所选路径的盘符）。
  ;
  ; 这段必须放在 MULTIUSER_INIT 之后：installMode=both 时 MULTIUSER_INIT（及其
  ; RestorePreviousInstallLocation）会按安装模式无条件重写 $INSTDIR（源码见
  ; MultiUser.nsh 的 MULTIUSER_INSTALLMODE_ALLUSERS/CURRENTUSER），先写会被覆盖。
  ; 本项目当前是 perMachine，该 !if 不展开，位置对结果没有影响。
  ;
  ; /D= 优先级（架构裁定 4）：$vegaCmdlineDir 是 .onInit 第一行对 $INSTDIR 的备份。
  ;   * 非空 —— 命令行给了 /D=，必须**原样**落在允许的位置上（见下面 vega_init_cmdline_dir）；
  ;   * 空   —— 先试卸载注册表里的旧安装位置（校验通过才沿用），否则用默认位置。
  ; 交互模式下目录页的选择会覆盖这里，离页时同样走 VegaValidateTarget。
  StrCmp $vegaCmdlineDir "" 0 vega_init_cmdline_dir

  ; t6b-fix3（架构裁定 4）：显式给了 /D= 却拿不到值（备份为空），不能静默回落到默认
  ; 位置——用户以为自己指定了目录，装到别处比失败更糟。只**检测** `/D=` 是否还在
  ; $CMDLINE 里，不用它解析路径：NSIS 要求 /D= 是最后一个参数，合法时会把它写进
  ; $INSTDIR 并从 $CMDLINE 摘掉；`/D=` 空值、`/D="D:\Test"`（带引号）这类写法会留下痕迹。
  ${StrCase} $R1 "$CMDLINE" "L"
  ${StrLoc} $R0 "$R1" "/d=" ">"
  StrCmp $R0 "" vega_init_no_cmdline_dir
    StrCpy $vegaTargetError "命令行 /D= 指定的安装目录无效（/D= 必须是最后一个参数、不能带引号，且要有实际路径）。请去掉 /D=，或改成 /D=X:\Vega 后重试。"
    Goto vega_init_cmdline_invalid

vega_init_no_cmdline_dir:
  ; 没有 /D=：沿用上一次的安装位置，但必须能通过同一份目标校验（旧版可能装在
  ; t6b 之前任意自定义目录里；那种位置不再允许，回落到默认位置，旧目录由
  ; PREINSTALL 的迁移逻辑清理）。
  ReadRegStr $R0 SHCTX "${UNINSTKEY}" "InstallLocation"
  StrCmp $R0 "" vega_init_default
  !insertmacro VegaTrimDirPath initdir $R0
  StrCmp $R0 "" vega_init_default
  StrCpy $INSTDIR "$R0"
  Call VegaValidateTarget
  StrCmp $vegaTargetError "" 0 vega_init_default
  StrCmp $vegaTargetChanged "1" vega_init_default
  DetailPrint "沿用上一次的安装目录：$INSTDIR"
  Goto vega_init_dir_done

vega_init_cmdline_dir:
  ; 恢复备份值：MULTIUSER_INIT 可能已经重写过 $INSTDIR，以 /D= 为准。
  StrCpy $INSTDIR "$vegaCmdlineDir"
  ; t6b-fix3（架构裁定 4）：显式 /D= 必须是**有效目标**。这里跑同一份 VegaValidateTarget：
  ;   * 有错误（不是本地固定 NTFS 盘、UNC、盘根写错……）→ 无效目标；
  ;   * 被规范化（`D:\Test` 这种不是 <盘符>:\Vega 的路径会被改成 `D:\Vega`）→ 也算
  ;     「用户给的 /D= 不是允许的位置」，不静默改到别处，直接按无效目标结束。
  ; 交互模式下用户还能改目录页，但 /D= 与界面选择打架只会更混乱，同样中止。
  Call VegaValidateTarget
  StrCmp $vegaTargetError "" 0 vega_init_cmdline_invalid
  StrCmp $vegaTargetChanged "1" vega_init_cmdline_moved
  Goto vega_init_dir_done

vega_init_cmdline_moved:
  StrCpy $vegaTargetError "命令行 /D= 指定的安装目录不是允许的位置（只能是 $PROGRAMFILES64\Vega 或 X:\Vega）。/D=X:\Vega 中的盘符必须是本地固定 NTFS 盘。"
vega_init_cmdline_invalid:
  DetailPrint "安装已中止：$vegaTargetError"
  ${If} $PassiveMode = 1
  ${OrIf} ${Silent}
    SetErrorLevel 2
  ${Else}
    MessageBox MB_OK|MB_ICONSTOP "$vegaTargetError"
  ${EndIf}
  Abort

vega_init_default:
  StrCpy $INSTDIR "$PROGRAMFILES64\Vega"

vega_init_dir_done:
  ; ------------------------------------------------------------------------

  ; Abort downgrades if they are disabled. 重装页删除后，交互模式也没有「先卸载再降级」
  ; 的选择，因此与 silent / passive / update 一样，在 .onInit 直接拒绝。
  !if "${ALLOWDOWNGRADES}" == "false"
    ; Compare with the installed version: a WiX one first
    Call FindWixInstall
    ${If} $R6 != ""
      ReadRegStr $R0 HKLM "$R6" "DisplayVersion"
    ${Else}
      ReadRegStr $R0 SHCTX "${UNINSTKEY}" "DisplayVersion"
    ${EndIf}
    nsis_tauri_utils::SemverCompare "${VERSION}" $R0
    Pop $R0
    ; If downgrading
    ${If} $R0 = -1
      ${If} ${Silent}
        System::Call 'kernel32::AttachConsole(i -1)i.r0'
        ${If} $0 <> 0
          System::Call 'kernel32::GetStdHandle(i -11)i.r0'
          System::call 'kernel32::SetConsoleTextAttribute(i r0, i 0x0004)' ; set red color
          FileWrite $0 "$(silentDowngrades)"
        ${EndIf}
      ${Else}
        MessageBox MB_ICONSTOP "$(silentDowngrades)"
      ${EndIf}
      Abort
    ${EndIf}
  !endif

FunctionEnd

Section WebView2
  ; Check if Webview2 is already installed and skip this section
  ${If} ${RunningX64}
    ReadRegStr $4 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\${WEBVIEW2APPGUID}" "pv"
  ${Else}
    ReadRegStr $4 HKLM "SOFTWARE\Microsoft\EdgeUpdate\Clients\${WEBVIEW2APPGUID}" "pv"
  ${EndIf}
  ${If} $4 == ""
    ReadRegStr $4 HKCU "SOFTWARE\Microsoft\EdgeUpdate\Clients\${WEBVIEW2APPGUID}" "pv"
  ${EndIf}

  ${If} $4 == ""
    ; Webview2 installation
    ;
    ; Skip if updating
    ${If} $UpdateMode <> 1
      !if "${INSTALLWEBVIEW2MODE}" == "downloadBootstrapper"
        Delete "$TEMP\MicrosoftEdgeWebview2Setup.exe"
        DetailPrint "$(webview2Downloading)"
        NSISdl::download "https://go.microsoft.com/fwlink/p/?LinkId=2124703" "$TEMP\MicrosoftEdgeWebview2Setup.exe"
        Pop $0
        ${If} $0 == "success"
          DetailPrint "$(webview2DownloadSuccess)"
        ${Else}
          DetailPrint "$(webview2DownloadError)"
          Abort "$(webview2AbortError)"
        ${EndIf}
        StrCpy $6 "$TEMP\MicrosoftEdgeWebview2Setup.exe"
        Goto install_webview2
      !endif

      !if "${INSTALLWEBVIEW2MODE}" == "embedBootstrapper"
        Delete "$TEMP\MicrosoftEdgeWebview2Setup.exe"
        File "/oname=$TEMP\MicrosoftEdgeWebview2Setup.exe" "${WEBVIEW2BOOTSTRAPPERPATH}"
        DetailPrint "$(installingWebview2)"
        StrCpy $6 "$TEMP\MicrosoftEdgeWebview2Setup.exe"
        Goto install_webview2
      !endif

      !if "${INSTALLWEBVIEW2MODE}" == "offlineInstaller"
        Delete "$TEMP\MicrosoftEdgeWebView2RuntimeInstaller.exe"
        File "/oname=$TEMP\MicrosoftEdgeWebView2RuntimeInstaller.exe" "${WEBVIEW2INSTALLERPATH}"
        DetailPrint "$(installingWebview2)"
        StrCpy $6 "$TEMP\MicrosoftEdgeWebView2RuntimeInstaller.exe"
        Goto install_webview2
      !endif

      Goto webview2_done

      install_webview2:
        DetailPrint "$(installingWebview2)"
        ; $6 holds the path to the webview2 installer
        ExecWait "$6 ${WEBVIEW2INSTALLERARGS} /install" $1
        ${If} $1 = 0
          DetailPrint "$(webview2InstallSuccess)"
        ${Else}
          DetailPrint "$(webview2InstallError)"
          Abort "$(webview2AbortError)"
        ${EndIf}
      webview2_done:
    ${EndIf}
  ${Else}
    !if "${MINIMUMWEBVIEW2VERSION}" != ""
      ${VersionCompare} "${MINIMUMWEBVIEW2VERSION}" "$4" $R0
      ${If} $R0 = 1
        update_webview:
          DetailPrint "$(installingWebview2)"
          ${If} ${RunningX64}
            ReadRegStr $R1 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate" "path"
          ${Else}
            ReadRegStr $R1 HKLM "SOFTWARE\Microsoft\EdgeUpdate" "path"
          ${EndIf}
          ${If} $R1 == ""
            ReadRegStr $R1 HKCU "SOFTWARE\Microsoft\EdgeUpdate" "path"
          ${EndIf}
          ${If} $R1 != ""
            ; Chromium updater docs: https://source.chromium.org/chromium/chromium/src/+/main:docs/updater/user_manual.md
            ; Modified from "HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView\ModifyPath"
            ExecWait `"$R1" /install appguid=${WEBVIEW2APPGUID}&needsadmin=true` $1
            ${If} $1 = 0
              DetailPrint "$(webview2InstallSuccess)"
            ${Else}
              MessageBox MB_ICONEXCLAMATION|MB_ABORTRETRYIGNORE "$(webview2InstallError)" IDIGNORE ignore IDRETRY update_webview
              Quit
              ignore:
            ${EndIf}
          ${EndIf}
      ${EndIf}
    !endif
  ${EndIf}
SectionEnd

; t6-fix7：不允许「忽略」写入失败的文件（全局安装器属性）。否则跳过新 vega-console.exe 后，
; POSTINSTALL 仍会清理旧版，留下两边都无法启动的控制台。
AllowSkipFiles off

Section Install
  ; t6b-fix（架构裁定）：静默 / 被动 / `/D=` 安装不经过目录页，必须在任何 SetOutPath
  ; 之前用同一份校验（VegaValidateTarget）确认目标。否则 `/D=` 选中别的应用的非空
  ; 目录时会直接覆盖它的 uninstall.exe，随后还会递归改这个目录的 ACL。
  Call VegaValidateTarget
  StrCmp $vegaTargetError "" vega_install_target_ok
    DetailPrint "安装已中止：$vegaTargetError"
    ${If} $PassiveMode = 1
    ${OrIf} ${Silent}
      SetErrorLevel 2
      MessageBox MB_OK|MB_ICONSTOP "$vegaTargetError" /SD IDOK
    ${Else}
      MessageBox MB_OK|MB_ICONSTOP "$vegaTargetError"
    ${EndIf}
    Abort
vega_install_target_ok:
  ; 规范化改变了 /D= 给的路径时只记日志（静默安装不能弹提示框等用户点）。
  StrCmp $vegaTargetChanged "0" vega_install_target_same
    DetailPrint "安装目录已规范为 $INSTDIR"
vega_install_target_same:

  ; t6b-fix3（架构裁定 2/3）：先建目录并做预锁定，再解包任何文件。此时还没有
  ; SetOutPath / File，锁不住就直接中止，文件不会落进普通账户可改的目录。
  ; 预锁定顺序是「先断继承 → setowner → 对已有子树 /reset → 重新 grant」，四条
  ; icacls 任一失败 → 固定提示 + SetErrorLevel 2 + Abort（静默安装靠 /SD IDOK
  ; 自动跳过提示）。POSTINSTALL 只做无 /reset 的收紧（失败只写完成页告警）。
  CreateDirectory "$INSTDIR"
  Call VegaLockInstallDir
  StrCmp $vegaAclWarning "" vega_install_lock_ok
    DetailPrint "安装已中止：$vegaAclWarning"
    MessageBox MB_OK|MB_ICONSTOP "无法锁定安装目录权限，安装已中止" /SD IDOK
    SetErrorLevel 2
    Abort
vega_install_lock_ok:

  ; t6b-fix3（架构裁定 3）：预锁定完成后**再次**完整扫描目标树。第一次扫描在
  ; VegaValidateTarget 里，跑在目录为空之前/之时；这里重扫是因为 icacls /reset /T
  ; 与 /T 授权都会沿着重解析点走到目录外（目标树在这一小段时间里可能被换成链接），
  ; 发现任何重解析点或枚举错误就中止：此刻还没解包，退出码 2 干净收场。
  StrCpy $vegaWalkPath "$INSTDIR"
  StrCpy $vegaWalkFound "0"
  StrCpy $vegaWalkError "0"
  StrCpy $vegaWalkErrCode "0"
  Call VegaScanReparseTree
  StrCmp $vegaWalkError "1" vega_install_rescan_bad
  StrCmp $vegaWalkFound "1" vega_install_rescan_bad
  Goto vega_install_rescan_ok
vega_install_rescan_bad:
    DetailPrint "安装已中止：安装目录或子项是重解析点，或无法枚举（错误码 $vegaWalkErrCode）"
    MessageBox MB_OK|MB_ICONSTOP "安装目录或其子项在锁定 ACL 后变成重解析点（junction 或符号链接），或无法读取。出于安全原因拒绝安装。" /SD IDOK
    SetErrorLevel 2
    Abort
vega_install_rescan_ok:

  SetOutPath $INSTDIR

  !ifmacrodef NSIS_HOOK_PREINSTALL
    !insertmacro NSIS_HOOK_PREINSTALL
  !endif

  !insertmacro CheckIfAppIsRunning "$INSTDIR\${MAINBINARYNAME}.exe" "${PRODUCTNAME}"

  ; Copy main executable
  File "${MAINBINARYSRCPATH}"

  ; Copy resources
  {{#each resources_dirs}}
    CreateDirectory "$INSTDIR\\{{this}}"
  {{/each}}
  {{#each resources}}
    File /a "/oname={{this.[1]}}" "{{no-escape @key}}"
  {{/each}}

  ; Copy external binaries
  {{#each binaries}}
    File /a "/oname={{this}}" "{{no-escape @key}}"
  {{/each}}

  ; Create file associations
  {{#each file_associations as |association| ~}}
    {{#each association.ext as |ext| ~}}
       !insertmacro APP_ASSOCIATE "{{ext}}" "{{or association.name ext}}" "{{association-description association.description ext}}" "$\"$INSTDIR\${MAINBINARYNAME}.exe$\",0" "Open with ${PRODUCTNAME}" "$\"$INSTDIR\${MAINBINARYNAME}.exe$\" $\"%1$\""
    {{/each}}
  {{/each}}

  ; Register deep links
  {{#each deep_link_protocols as |protocol| ~}}
    WriteRegStr SHCTX "Software\Classes\\{{protocol}}" "URL Protocol" ""
    WriteRegStr SHCTX "Software\Classes\\{{protocol}}" "" "URL:${BUNDLEID} protocol"
    WriteRegStr SHCTX "Software\Classes\\{{protocol}}\DefaultIcon" "" "$\"$INSTDIR\${MAINBINARYNAME}.exe$\",0"
    WriteRegStr SHCTX "Software\Classes\\{{protocol}}\shell\open\command" "" "$\"$INSTDIR\${MAINBINARYNAME}.exe$\" $\"%1$\""
  {{/each}}

  ; Create uninstaller
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; Save $INSTDIR in registry for future installations
  WriteRegStr SHCTX "${MANUPRODUCTKEY}" "" $INSTDIR

  !if "${INSTALLMODE}" == "both"
    ; Save install mode to be selected by default for the next installation such as updating
    ; or when uninstalling
    WriteRegStr SHCTX "${UNINSTKEY}" $MultiUser.InstallMode 1
  !endif

  ; Remove old main binary if it doesn't match new main binary name
  ReadRegStr $OldMainBinaryName SHCTX "${UNINSTKEY}" "MainBinaryName"
  ${If} $OldMainBinaryName != ""
  ${AndIf} $OldMainBinaryName != "${MAINBINARYNAME}.exe"
    Delete "$INSTDIR\$OldMainBinaryName"
  ${EndIf}

  ; Save current MAINBINARYNAME for future updates
  WriteRegStr SHCTX "${UNINSTKEY}" "MainBinaryName" "${MAINBINARYNAME}.exe"

  ; Registry information for add/remove programs
  WriteRegStr SHCTX "${UNINSTKEY}" "DisplayName" "${PRODUCTNAME}"
  WriteRegStr SHCTX "${UNINSTKEY}" "DisplayIcon" "$\"$INSTDIR\${MAINBINARYNAME}.exe$\""
  WriteRegStr SHCTX "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr SHCTX "${UNINSTKEY}" "Publisher" "${MANUFACTURER}"
  WriteRegStr SHCTX "${UNINSTKEY}" "InstallLocation" "$\"$INSTDIR$\""
  WriteRegStr SHCTX "${UNINSTKEY}" "UninstallString" "$\"$INSTDIR\uninstall.exe$\""
  WriteRegDWORD SHCTX "${UNINSTKEY}" "NoModify" "1"
  WriteRegDWORD SHCTX "${UNINSTKEY}" "NoRepair" "1"

  ${GetSize} "$INSTDIR" "/M=uninstall.exe /S=0K /G=0" $0 $1 $2
  IntOp $0 $0 + ${ESTIMATEDSIZE}
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD SHCTX "${UNINSTKEY}" "EstimatedSize" "$0"

  !if "${HOMEPAGE}" != ""
    WriteRegStr SHCTX "${UNINSTKEY}" "URLInfoAbout" "${HOMEPAGE}"
    WriteRegStr SHCTX "${UNINSTKEY}" "URLUpdateInfo" "${HOMEPAGE}"
    WriteRegStr SHCTX "${UNINSTKEY}" "HelpLink" "${HOMEPAGE}"
  !endif

  ; Create start menu shortcut
  !insertmacro MUI_STARTMENU_WRITE_BEGIN Application
    Call CreateOrUpdateStartMenuShortcut
  !insertmacro MUI_STARTMENU_WRITE_END

  ; Create desktop shortcut for silent and passive installers
  ; because finish page will be skipped
  ${If} $PassiveMode = 1
  ${OrIf} ${Silent}
    Call CreateOrUpdateDesktopShortcut
  ${EndIf}

  !ifmacrodef NSIS_HOOK_POSTINSTALL
    !insertmacro NSIS_HOOK_POSTINSTALL
  !endif

  ; Auto close this page for passive mode
  ${If} $PassiveMode = 1
    SetAutoClose true
  ${EndIf}
SectionEnd

Function .onInstSuccess
  ; Check for `/R` flag only in silent and passive installers because
  ; GUI installer has a toggle for the user to (re)start the app
  ${If} $PassiveMode = 1
  ${OrIf} ${Silent}
    ${GetOptions} $CMDLINE "/R" $R0
    ${IfNot} ${Errors}
      ${GetOptions} $CMDLINE "/ARGS" $R0
      nsis_tauri_utils::RunAsUser "$INSTDIR\${MAINBINARYNAME}.exe" "$R0"
    ${EndIf}
  ${EndIf}
FunctionEnd

Function un.onInit
  !insertmacro SetContext

  !if "${INSTALLMODE}" == "both"
    !insertmacro MULTIUSER_UNINIT
  !endif

  !insertmacro MUI_UNGETLANGUAGE

  ${GetOptions} $CMDLINE "/P" $PassiveMode
  ${IfNot} ${Errors}
    StrCpy $PassiveMode 1
  ${EndIf}

  ${GetOptions} $CMDLINE "/UPDATE" $UpdateMode
  ${IfNot} ${Errors}
    StrCpy $UpdateMode 1
  ${EndIf}
FunctionEnd

Section Uninstall

  !ifmacrodef NSIS_HOOK_PREUNINSTALL
    !insertmacro NSIS_HOOK_PREUNINSTALL
  !endif

  !insertmacro CheckIfAppIsRunning "$INSTDIR\${MAINBINARYNAME}.exe" "${PRODUCTNAME}"

  ; Delete the app directory and its content from disk
  ; Copy main executable
  Delete "$INSTDIR\${MAINBINARYNAME}.exe"

  ; Delete resources
  {{#each resources}}
    Delete "$INSTDIR\\{{this.[1]}}"
  {{/each}}

  ; Delete external binaries
  {{#each binaries}}
    Delete "$INSTDIR\\{{this}}"
  {{/each}}

  ; Delete app associations
  {{#each file_associations as |association| ~}}
    {{#each association.ext as |ext| ~}}
      !insertmacro APP_UNASSOCIATE "{{ext}}" "{{or association.name ext}}"
    {{/each}}
  {{/each}}

  ; Delete deep links
  {{#each deep_link_protocols as |protocol| ~}}
    ReadRegStr $R7 SHCTX "Software\Classes\\{{protocol}}\shell\open\command" ""
    ${If} $R7 == "$\"$INSTDIR\${MAINBINARYNAME}.exe$\" $\"%1$\""
      DeleteRegKey SHCTX "Software\Classes\\{{protocol}}"
    ${EndIf}
  {{/each}}


  ; Delete uninstaller
  Delete "$INSTDIR\uninstall.exe"

  {{#each resources_ancestors}}
  RMDir /REBOOTOK "$INSTDIR\\{{this}}"
  {{/each}}
  RMDir "$INSTDIR"

  ; Remove shortcuts if not updating
  ${If} $UpdateMode <> 1
    !insertmacro DeleteAppUserModelId

    ; Remove start menu shortcut
    !insertmacro MUI_STARTMENU_GETFOLDER Application $AppStartMenuFolder
    !insertmacro IsShortcutTarget "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    Pop $0
    ${If} $0 = 1
      !insertmacro UnpinShortcut "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk"
      Delete "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk"
      RMDir "$SMPROGRAMS\$AppStartMenuFolder"
    ${EndIf}
    !insertmacro IsShortcutTarget "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    Pop $0
    ${If} $0 = 1
      !insertmacro UnpinShortcut "$SMPROGRAMS\${PRODUCTNAME}.lnk"
      Delete "$SMPROGRAMS\${PRODUCTNAME}.lnk"
    ${EndIf}

    ; Remove desktop shortcuts
    !insertmacro IsShortcutTarget "$DESKTOP\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    Pop $0
    ${If} $0 = 1
      !insertmacro UnpinShortcut "$DESKTOP\${PRODUCTNAME}.lnk"
      Delete "$DESKTOP\${PRODUCTNAME}.lnk"
    ${EndIf}
  ${EndIf}

  ; Remove registry information for add/remove programs
  !if "${INSTALLMODE}" == "both"
    DeleteRegKey SHCTX "${UNINSTKEY}"
  !else if "${INSTALLMODE}" == "perMachine"
    DeleteRegKey HKLM "${UNINSTKEY}"
  !else
    DeleteRegKey HKCU "${UNINSTKEY}"
  !endif

  ; Removes the Autostart entry for ${PRODUCTNAME} from the HKCU Run key if it exists.
  ; This ensures the program does not launch automatically after uninstallation if it exists.
  ; If it doesn't exist, it does nothing.
  ; We do this when not updating (to preserve the registry value on updates)
  ${If} $UpdateMode <> 1
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${PRODUCTNAME}"
  ${EndIf}

  ; Delete app data if the checkbox is selected
  ; and if not updating
  ${If} $DeleteAppDataCheckboxState = 1
  ${AndIf} $UpdateMode <> 1
    ; Clear the install location $INSTDIR from registry
    DeleteRegKey SHCTX "${MANUPRODUCTKEY}"
    DeleteRegKey /ifempty SHCTX "${MANUKEY}"

    ; Clear the install language from registry
    DeleteRegValue HKCU "${MANUPRODUCTKEY}" "Installer Language"
    DeleteRegKey /ifempty HKCU "${MANUPRODUCTKEY}"
    DeleteRegKey /ifempty HKCU "${MANUKEY}"

    SetShellVarContext current
    RmDir /r "$APPDATA\${BUNDLEID}"
    RmDir /r "$LOCALAPPDATA\${BUNDLEID}"
  ${EndIf}

  !ifmacrodef NSIS_HOOK_POSTUNINSTALL
    !insertmacro NSIS_HOOK_POSTUNINSTALL
  !endif

  ; Auto close if passive mode or updating
  ${If} $PassiveMode = 1
  ${OrIf} $UpdateMode = 1
    SetAutoClose true
  ${EndIf}
SectionEnd

Function RestorePreviousInstallLocation
  ReadRegStr $4 SHCTX "${MANUPRODUCTKEY}" ""
  StrCmp $4 "" +2 0
    StrCpy $INSTDIR $4
FunctionEnd

Function Skip
  Abort
FunctionEnd

Function SkipIfPassive
  ${IfThen} $PassiveMode = 1  ${|} Abort ${|}
FunctionEnd
Function un.SkipIfPassive
  ${IfThen} $PassiveMode = 1  ${|} Abort ${|}
FunctionEnd

; t6b-fix2（架构裁定 2/3）：从 $vegaWalkPath 开始遍历整棵目标树，检查
; FILE_ATTRIBUTE_REPARSE_POINT（0x400，junction / symlink / mount point）。
;   * 目标本身、其下任意目录或文件命中 → $vegaWalkFound=1，立即停止；
;   * 命中重解析目录不再向下展开（不跟随链接）；
;   * 无法枚举 → $vegaWalkError=1，绝不当作空目录继续（裁定 3）。
;
; t6b-fix3（架构裁定 5）：**「读不到」和「不存在」必须分开。**
;   * 每次 GetFileAttributesW 都用 `?e` 把 GetLastError 取到 $vegaWalkErrCode；
;     只有 2 (ERROR_FILE_NOT_FOUND) / 3 (ERROR_PATH_NOT_FOUND) 才算「真不存在」
;     （新装目标、枚举途中被删的子项），其它错误码（5 拒绝访问、32 占用、206 太长、
;     IO 错误……）一律中止：读不了属性就说明这棵树不可信，跳过等于放行。
;   * FindNext 失败时取 GetLastError，只有 18 (ERROR_NO_MORE_FILES) 是正常结束；
;     其它错误码中止。FindFirst 失败同理（先取码，2/3 视为目录已消失，其余中止）。
;   * 子项属性读取失败也按上面的规则处理，绝不静默跳过。
; 用 NSIS 栈做迭代式深度优先：底部压哨兵，顶层压根；每弹出一个目录就枚举，
; 子目录压回栈顶。退出前（无论命中/出错/正常结束）都把栈清到哨兵，保持平衡。
; 函数进出 Push/Pop $0-$5，不污染调用方。
Function VegaScanReparseTree
  Push $0
  Push $1
  Push $2
  Push $3
  Push $4
  Push $5

  StrCpy $vegaWalkErrCode "0"
  Push "__VEGA_WALK_END__"
  Push "$vegaWalkPath"

vega_walk_pop:
  StrCmp $vegaWalkFound "1" vega_walk_cleanup
  StrCmp $vegaWalkError "1" vega_walk_cleanup
  Pop $vegaWalkPath
  StrCmp $vegaWalkPath "__VEGA_WALK_END__" vega_walk_done

  ; 属性 + GetLastError 一起取（?e 捕获调用后的错误码）。
  System::Call 'kernel32::GetFileAttributesW(w "$vegaWalkPath") i .r0 ?e .r1'
  IntCmpU $0 0xFFFFFFFF vega_walk_attrs_missing vega_walk_attrs_ok vega_walk_attrs_ok
vega_walk_attrs_missing:
  ; 只有 2 / 3 是「真不存在」；其它错误码一律中止，不跳过。
  StrCmp $1 "2" vega_walk_pop
  StrCmp $1 "3" vega_walk_pop
  StrCpy $vegaWalkErrCode "$1"
  StrCpy $vegaWalkError "1"
  Goto vega_walk_pop
vega_walk_attrs_ok:
  IntOp $1 ${FILE_ATTRIBUTE_REPARSE_POINT} & $0
  StrCmp $1 "0" vega_walk_not_reparse
    StrCpy $vegaWalkFound "1"
    Goto vega_walk_pop
vega_walk_not_reparse:
  ; 普通文件不枚举；只有目录才展开。
  IntOp $1 $0 & 0x10
  StrCmp $1 "0" vega_walk_pop

  ClearErrors
  FindFirst $1 $2 "$vegaWalkPath\*.*"
  IfErrors vega_walk_find_error
  StrCmp $1 "" vega_walk_find_error
vega_walk_entry:
  StrCmp $2 "." vega_walk_next
  StrCmp $2 ".." vega_walk_next
  StrCpy $3 "$vegaWalkPath\$2"
  ; 子项属性同样带 ?e：读不到就中止，不静默跳过（裁定 5）。
  System::Call 'kernel32::GetFileAttributesW(w "$3") i .r4 ?e .r5'
  IntCmpU $4 0xFFFFFFFF vega_walk_child_missing vega_walk_child_ok vega_walk_child_ok
vega_walk_child_missing:
  ; 2 / 3：枚举期间被删，跳过这一项；其它错误码中止整次扫描。
  StrCmp $5 "2" vega_walk_next
  StrCmp $5 "3" vega_walk_next
  StrCpy $vegaWalkErrCode "$5"
  StrCpy $vegaWalkError "1"
  Goto vega_walk_scan_done
vega_walk_child_ok:
  IntOp $0 ${FILE_ATTRIBUTE_REPARSE_POINT} & $4
  StrCmp $0 "0" vega_walk_child
    StrCpy $vegaWalkFound "1"
    Goto vega_walk_scan_done
vega_walk_child:
  IntOp $0 $4 & 0x10
  StrCmp $0 "0" vega_walk_next
  Push "$3"
vega_walk_next:
  ClearErrors
  FindNext $1 $2
  IfErrors vega_walk_next_error
  StrCmp $2 "" vega_walk_scan_done
  Goto vega_walk_entry
vega_walk_next_error:
  ; 只有 18 (ERROR_NO_MORE_FILES) 是正常结束；其余错误码中止。
  System::Call 'kernel32::GetLastError() i .r5'
  StrCmp $5 "18" vega_walk_scan_done
  StrCpy $vegaWalkErrCode "$5"
  StrCpy $vegaWalkError "1"
  Goto vega_walk_scan_done
vega_walk_scan_done:
  FindClose $1
  Goto vega_walk_pop
vega_walk_find_error:
  ; FindFirst 失败：取错误码；2 / 3 说明目录在扫描中途消失（等同于不存在），其它中止。
  System::Call 'kernel32::GetLastError() i .r5'
  StrCmp $5 "2" vega_walk_pop
  StrCmp $5 "3" vega_walk_pop
  StrCpy $vegaWalkErrCode "$5"
  StrCpy $vegaWalkError "1"
  Goto vega_walk_pop

vega_walk_cleanup:
  Pop $vegaWalkPath
  StrCmp $vegaWalkPath "__VEGA_WALK_END__" vega_walk_done
  Goto vega_walk_cleanup

vega_walk_done:
  Pop $5
  Pop $4
  Pop $3
  Pop $2
  Pop $1
  Pop $0
FunctionEnd

; t6b-fix（架构裁定）：唯一的目标校验入口。
;
; 允许的安装位置只有两种：
;   * $PROGRAMFILES64\Vega —— 默认位置，继承 ACL 已经是管理员独占写；
;   * <X>:\Vega —— 本地固定 NTFS 盘根目录下的 Vega（安装后由 icacls 收紧 ACL）。
; 用户选/输的其它路径一律规范化（取该路径的盘符）：落在 $PROGRAMFILES64 里（含 Program
; Files 本身与其子目录）的收成 $PROGRAMFILES64\Vega，其余收成 <X>:\Vega。规范化确实改变
; 了用户的选择时置 $vegaTargetChanged=1，由目录页回调提示。
;
; 拒绝：空路径、相对路径、UNC（\\server\share）、驱动器类型不是 3（DRIVE_FIXED，排除
; U 盘/光驱/网络盘/内存盘）、文件系统不是 NTFS（FAT32/exFAT 没有可用的 DACL）。
;
; 已存在的目录只接受两种：空目录，或「已是 Vega 安装」——存在 vega-console.exe 且它是
; 文件（FILE_ATTRIBUTE_DIRECTORY 未置位）。空目录用 FindFirst/FindNext 判定并跳过
; "." 与 ".."；`IfFileExists "$DIR\*.*"` 会把空目录里的点目录项当命中，不能用。
; 任何别的非空目录都拒绝：否则等于把用户已有数据锁成管理员独占。
;
; t6b-fix2（架构裁定 2/3）：规范化之后再拒绝两类目标——
;   * 重解析点：$INSTDIR 非空时，$INSTDIR 本身、其下任意目录/文件（VegaScanReparseTree
;     递归检查，不进入重解析目录）命中 0x400 即拒绝；父目录（$PROGRAMFILES64 或盘根
;     `X:\`）也是重解析点时同样拒绝。否则解包会沿链接覆盖树外文件、icacls 会改到链接
;     目标，卸载入口可被普通账户替换。
;   * 枚举失败：目标已存在但 FindFirst 失败（错误标志或空句柄）→ 「无法读取安装目录
;     内容」，绝不当作空目录放行；VegaScanReparseTree 内部同样处理。
;
; 结果：$vegaTargetError 为空表示通过（$INSTDIR 已规范化），否则是整句中文错误，
; 由调用方决定 MessageBox / SetErrorLevel + Abort。函数进出 Push/Pop $0-$5 与 $R0-$R5，
; 不污染调用方。System::Call 的输出寄存器一律写成 `.rN`，随后读对应的 `$N`（不是 `$RN`）。
Function VegaValidateTarget
  Push $0
  Push $1
  Push $2
  Push $3
  Push $4
  Push $5
  Push $R0
  Push $R1
  Push $R2
  Push $R3
  Push $R4
  Push $R5

  StrCpy $vegaTargetError ""
  StrCpy $vegaTargetChanged "0"
  StrCpy $vegaTargetEmpty "1"

  StrCmp $INSTDIR "" vega_validate_empty_path
  !insertmacro VegaTrimDirPath target $INSTDIR
  StrCmp $INSTDIR "" vega_validate_empty_path

  ; 形状：必须是 `X:\...`。`\\server\share` 与相对路径直接拒绝。
  StrLen $0 "$INSTDIR"
  IntCmp $0 2 vega_validate_shape vega_validate_bad_path vega_validate_shape
vega_validate_shape:
  StrCpy $1 "$INSTDIR" 1 1
  StrCmp $1 ":" 0 vega_validate_bad_path
  StrCpy $1 "$INSTDIR" 1 0
  StrCmp $1 "\" vega_validate_bad_path
  StrCpy $1 "$INSTDIR" 1 2
  StrCmp $1 "\" vega_validate_drive
  ; `D:` 与 `D:\`（盘根）先补成 `D:\`，随后统一规范成 `D:\Vega`。
  StrLen $0 "$INSTDIR"
  IntCmp $0 2 vega_validate_fix_root vega_validate_bad_path vega_validate_bad_path
vega_validate_fix_root:
  StrCpy $INSTDIR "$INSTDIR\"

vega_validate_drive:
  ; GetDriveTypeW：3 = DRIVE_FIXED（本地固定盘）。
  StrCpy $R0 "$INSTDIR" 2
  StrCpy $R0 "$R0\"
  System::Call 'kernel32::GetDriveTypeW(w R0) i .r0'
  StrCmp $0 "3" 0 vega_validate_bad_drive
  ; GetVolumeInformationW(lpRootPathName, lpVolumeNameBuffer, nVolumeNameSize,
  ;   lpVolumeSerialNumber, lpMaximumComponentLength, lpFileSystemFlags,
  ;   lpFileSystemNameBuffer, nFileSystemNameSize)：$3=0 表示失败，$2=文件系统名。
  System::Call 'kernel32::GetVolumeInformationW(w R0, w .r1, i 260, i 0, i 0, i 0, w .r2, i 260) i .r3'
  StrCmp $3 "0" vega_validate_bad_fs
  StrCmp $2 "NTFS" vega_validate_normalize
  StrCmp $2 "ntfs" vega_validate_normalize vega_validate_bad_fs

vega_validate_normalize:
  ; 落在系统盘 Program Files 里的选择统一收成 $PROGRAMFILES64\Vega（用户可能选的是
  ; Program Files 本身、或它下面的子目录）；其余一律取盘符改成 <盘符>:\Vega。
  ${StrCase} $vegaTmp1 "$INSTDIR" "L"
  ${StrCase} $vegaTmp2 "$PROGRAMFILES64" "L"
  StrCmp $vegaTmp1 $vegaTmp2 vega_validate_programfiles
  StrLen $vegaTmp3 "$vegaTmp2"
  StrCpy $R1 "$vegaTmp1" $vegaTmp3
  StrCmp $R1 $vegaTmp2 0 vega_validate_drive_path
  StrCpy $R1 "$vegaTmp1" 1 $vegaTmp3
  StrCmp $R1 "\" vega_validate_programfiles

vega_validate_drive_path:
  StrCpy $vegaTmp3 "$INSTDIR" 2
  StrCpy $vegaTmp3 "$vegaTmp3\Vega"
  ${StrCase} $vegaTmp1 "$vegaTmp3" "L"
  ${StrCase} $vegaTmp2 "$INSTDIR" "L"
  StrCmp $vegaTmp1 $vegaTmp2 vega_validate_nonempty
  StrCpy $INSTDIR "$vegaTmp3"
  StrCpy $vegaTargetChanged "1"
  Goto vega_validate_nonempty

vega_validate_programfiles:
  StrCpy $vegaTmp3 "$PROGRAMFILES64\Vega"
  ${StrCase} $vegaTmp1 "$vegaTmp3" "L"
  ${StrCase} $vegaTmp2 "$INSTDIR" "L"
  StrCmp $vegaTmp1 $vegaTmp2 vega_validate_nonempty
  StrCpy $INSTDIR "$vegaTmp3"
  StrCpy $vegaTargetChanged "1"
  Goto vega_validate_nonempty

vega_validate_nonempty:
  ; 裁定 3：目标已存在时，FindFirst 失败（错误标志或空句柄）说明读不了目录，
  ; 不能当作空目录放行；只有确认路径不存在才走「空目录」语义。
  ; t6b-fix3（架构裁定 5）：这个「不存在」也只认 GetLastError 2 / 3——其它错误码
  ; （拒绝访问、IO 错误……）是读不了，按错误中止，不能当成空目录往下走。
  System::Call 'kernel32::GetFileAttributesW(w "$INSTDIR") i .r0 ?e .r2'
  IntCmpU $0 0xFFFFFFFF vega_validate_attrs_missing vega_validate_scan_open vega_validate_scan_open
vega_validate_attrs_missing:
  StrCmp $2 "2" vega_validate_tree
  StrCmp $2 "3" vega_validate_tree
  StrCpy $vegaWalkErrCode "$2"
  Goto vega_validate_scan_error
vega_validate_scan_open:
  ClearErrors
  FindFirst $0 $1 "$INSTDIR\*.*"
  IfErrors vega_validate_scan_error
  StrCmp $0 "" vega_validate_scan_error
vega_validate_scan:
  StrCmp $1 "." vega_validate_scan_next
  StrCmp $1 ".." vega_validate_scan_next
  StrCpy $vegaTargetEmpty "0"
  Goto vega_validate_scan_done
vega_validate_scan_next:
  ClearErrors
  FindNext $0 $1
  IfErrors vega_validate_scan_next_error
  StrCmp $1 "" vega_validate_scan_done
  Goto vega_validate_scan
vega_validate_scan_next_error:
  ; 只有 18 (ERROR_NO_MORE_FILES) 是正常结束；其它错误码按读不了处理。
  System::Call 'kernel32::GetLastError() i .r2'
  StrCmp $2 "18" vega_validate_scan_done
  StrCpy $vegaWalkErrCode "$2"
  FindClose $0
  Goto vega_validate_scan_error
vega_validate_scan_done:
  FindClose $0
  StrCmp $vegaTargetEmpty "1" vega_validate_tree

  ; 非空：只接受已有的 Vega 安装。vega-console.exe 必须是文件——GetFileAttributesW
  ; 返回 0xFFFFFFFF 表示不存在，FILE_ATTRIBUTE_DIRECTORY (0x10) 置位表示同名目录。
  System::Call 'kernel32::GetFileAttributesW(w "$INSTDIR\vega-console.exe") i .r0'
  IntCmpU $0 0xFFFFFFFF vega_validate_not_vega vega_validate_exe_attr vega_validate_exe_attr
vega_validate_exe_attr:
  IntOp $1 $0 & 0x10
  StrCmp $1 "0" vega_validate_tree
vega_validate_not_vega:
  StrCpy $vegaTargetError "目录 $INSTDIR 已存在且不为空，但不是 Vega 安装目录。请选择空目录（或新建一个），或选择已有的 Vega 目录。"
  Goto vega_validate_done

vega_validate_scan_error:
  ; t6b-fix3（架构裁定 5）：错误码写进提示，便于区分「拒绝访问」和「IO 错误」。
  StrCpy $vegaTargetError "无法读取安装目录内容（错误码 $vegaWalkErrCode），请确认该目录存在且当前账户有读取权限。"
  Goto vega_validate_done

vega_validate_tree:
  ; 裁定 2：父目录（$PROGRAMFILES64 或盘根 `X:\`）本身是重解析点时也拒绝——
  ; 否则目标这个子项仍可被链接替换。
  ${StrCase} $vegaTmp1 "$INSTDIR" "L"
  StrCpy $vegaTmp2 "$PROGRAMFILES64\Vega"
  ${StrCase} $vegaTmp2 "$vegaTmp2" "L"
  StrCmp $vegaTmp1 $vegaTmp2 vega_validate_parent_pf
  StrCpy $vegaTmp3 "$INSTDIR" 3
  ; t6b-fix3c：宏内标签只用 ID，不再拼行号宏；同一函数内两次展开靠不同 ID 区分
  ; （parent_root / parent_pf），否则会展开出同名标签 vega_reparse_check_* 而阻断构建。
  !insertmacro VegaIsReparsePoint parent_root "$vegaTmp3" $vegaTmp1
  Goto vega_validate_parent_checked
vega_validate_parent_pf:
  !insertmacro VegaIsReparsePoint parent_pf "$PROGRAMFILES64" $vegaTmp1
vega_validate_parent_checked:
  StrCmp $vegaTmp1 "0" vega_validate_walk
  StrCpy $vegaTargetError "安装目录的上一级（盘根或 Program Files）是重解析点（junction 或符号链接），出于安全原因拒绝安装。"
  Goto vega_validate_done

vega_validate_walk:
  ; 裁定 2/3：目标本身及其整棵树不能有重解析点，且必须能枚举。
  StrCpy $vegaWalkPath "$INSTDIR"
  StrCpy $vegaWalkFound "0"
  StrCpy $vegaWalkError "0"
  Call VegaScanReparseTree
  StrCmp $vegaWalkError "1" vega_validate_walk_error
  StrCmp $vegaWalkFound "1" vega_validate_reparse
  Goto vega_validate_ok
vega_validate_walk_error:
  StrCpy $vegaTargetError "无法读取安装目录内容（错误码 $vegaWalkErrCode），请确认该目录存在且当前账户有读取权限。"
  Goto vega_validate_done
vega_validate_reparse:
  StrCpy $vegaTargetError "安装目录或其子项是重解析点（junction 或符号链接），解包和 ACL 会跟着链接跑到目录外，出于安全原因拒绝安装。请移除链接后重试。"
  Goto vega_validate_done

vega_validate_ok:
  Goto vega_validate_done

vega_validate_empty_path:
  StrCpy $vegaTargetError "安装路径不能为空。"
  Goto vega_validate_done

vega_validate_bad_path:
  StrCpy $vegaTargetError "安装路径必须是本地磁盘上的绝对路径，例如 D:\Vega。不支持网络路径（\\server\share）。"
  Goto vega_validate_done

vega_validate_bad_drive:
  StrCpy $vegaTargetError "安装目录必须位于本地固定磁盘（硬盘）。U 盘、光驱、网络盘和内存盘都不支持。"
  Goto vega_validate_done

vega_validate_bad_fs:
  StrCpy $vegaTargetError "安装目录所在磁盘必须是 NTFS 格式。长期密码依赖 NTFS 权限，其他格式无法保护提权助手。"
  Goto vega_validate_done

vega_validate_done:
  Pop $R5
  Pop $R4
  Pop $R3
  Pop $R2
  Pop $R1
  Pop $R0
  Pop $5
  Pop $4
  Pop $3
  Pop $2
  Pop $1
  Pop $0
FunctionEnd

; t6b-fix（架构裁定）：目录页离开时只做两件事——调 VegaValidateTarget，再按结果提示。
;   * 校验失败：MessageBox 显示整句原因并 Abort（留在目录页）。
;   * 路径被规范化：MB_OK 告知最终位置。
; 校验本体只有一份（安装节开头也调它），所以交互、静默、被动与 `/D=` 行为一致。
Function VegaDirectoryLeave
  Call VegaValidateTarget
  StrCmp $vegaTargetError "" vega_dir_leave_ok
    MessageBox MB_OK|MB_ICONSTOP "$vegaTargetError"
    Abort
vega_dir_leave_ok:
  StrCmp $vegaTargetChanged "0" vega_dir_leave_done
    MessageBox MB_OK "Vega 只能安装在 $PROGRAMFILES64\Vega 或某个盘根目录下的 Vega 文件夹，已改为 $INSTDIR"
vega_dir_leave_done:
  Return
FunctionEnd

Function CreateOrUpdateStartMenuShortcut
  ; We used to use product name as MAINBINARYNAME
  ; migrate old shortcuts to target the new MAINBINARYNAME
  StrCpy $R0 0

  !insertmacro IsShortcutTarget "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "$INSTDIR\$OldMainBinaryName"
  Pop $0
  ${If} $0 = 1
    !insertmacro SetShortcutTarget "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    StrCpy $R0 1
  ${EndIf}

  !insertmacro IsShortcutTarget "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$INSTDIR\$OldMainBinaryName"
  Pop $0
  ${If} $0 = 1
    !insertmacro SetShortcutTarget "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    StrCpy $R0 1
  ${EndIf}

  ${If} $R0 = 1
    Return
  ${EndIf}

  ; Skip creating shortcut if in update mode or no shortcut mode
  ${If} $UpdateMode = 1
  ${OrIf} $NoShortcutMode = 1
    Return
  ${EndIf}

  !if "${STARTMENUFOLDER}" != ""
    CreateDirectory "$SMPROGRAMS\$AppStartMenuFolder"
    CreateShortcut "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    !insertmacro SetLnkAppUserModelId "$SMPROGRAMS\$AppStartMenuFolder\${PRODUCTNAME}.lnk"
  !else
    CreateShortcut "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    !insertmacro SetLnkAppUserModelId "$SMPROGRAMS\${PRODUCTNAME}.lnk"
  !endif
FunctionEnd

Function CreateOrUpdateDesktopShortcut
  ; We used to use product name as MAINBINARYNAME
  ; migrate old shortcuts to target the new MAINBINARYNAME
  !insertmacro IsShortcutTarget "$DESKTOP\${PRODUCTNAME}.lnk" "$INSTDIR\$OldMainBinaryName"
  Pop $0
  ${If} $0 = 1
    !insertmacro SetShortcutTarget "$DESKTOP\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
    Return
  ${EndIf}

  ; Skip creating shortcut if in update mode or no shortcut mode
  ${If} $UpdateMode = 1
  ${OrIf} $NoShortcutMode = 1
    Return
  ${EndIf}

  CreateShortcut "$DESKTOP\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
  !insertmacro SetLnkAppUserModelId "$DESKTOP\${PRODUCTNAME}.lnk"
FunctionEnd
