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
;      Vega）。其它选择由 VegaValidateTarget 规范成 <X>:\Vega 并提示用户。
;      原因见 hooks.nsh 的 t6b 说明（ACL 由安装器收紧）。
;   2. 目标校验只有一份：VegaValidateTarget 同时被目录页回调与安装节开头调用，
;      静默 / 被动 / `/D=` 安装不会绕过。.onInit 用 $CMDLINE 里的 " /D=" 判定命令行是否
;      指定了目录；没指定时优先沿用卸载注册表里校验通过的旧位置，否则默认
;      $PROGRAMFILES64\Vega。
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
Var vegaTargetEmpty
Var vegaTmp1
Var vegaTmp2
Var vegaTmp3

Name "${PRODUCTNAME}"
BrandingText "${COPYRIGHT}"
OutFile "${OUTFILE}"

; We don't actually use this value as default install path,
; it's just for nsis to append the product name folder in the directory selector
; https://nsis.sourceforge.io/Reference/InstallDir
!define PLACEHOLDER_INSTALL_DIR "placeholder\${PRODUCTNAME}"
InstallDir "${PLACEHOLDER_INSTALL_DIR}"

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

  ; --- Vega customization (t6b-fix) ---------------------------------------
  ; 允许的安装位置只有两种（架构裁定）：
  ;   * $PROGRAMFILES64\Vega —— 默认；继承 ACL 已经是管理员独占写；
  ;   * <X>:\Vega —— 本地固定 NTFS 盘根目录下的 Vega；安装后由 icacls 收紧 ACL。
  ; 其它输入由 VegaValidateTarget 统一规范成 <X>:\Vega（取用户所选路径的盘符）。
  ;
  ; /D= 优先级（架构裁定）：NSIS 会把 `/D=<dir>` 直接写进 $INSTDIR，之后无法再与默认值
  ; 区分，所以一开始就在 $CMDLINE 里找 " /D="。整串先转大写，避免依赖 ${StrLoc} 的
  ; 大小写默认值；前面补一个空格，这样 `/D=` 紧跟在程序名后面也能命中。
  ;   * 给了 /D= —— 保留 $INSTDIR，不做任何覆盖（随后仍由安装节开头的
  ;     VegaValidateTarget 校验/规范化）；
  ;   * 没给   —— 先试卸载注册表里的旧安装位置（校验通过才沿用），否则用默认位置。
  ; 交互模式下目录页的选择会覆盖这里，离页时同样走 VegaValidateTarget。
  StrCpy $vegaTmp2 " $CMDLINE"
  ${StrCase} $vegaTmp2 "$vegaTmp2" "U"
  ${StrLoc} $vegaTmp1 $vegaTmp2 " /D=" ">"
  StrCmp $vegaTmp1 "" 0 vega_init_dir_done

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

vega_init_default:
  StrCpy $INSTDIR "$PROGRAMFILES64\Vega"

vega_init_dir_done:
  ; ------------------------------------------------------------------------


  !if "${INSTALLMODE}" == "both"
    !insertmacro MULTIUSER_INIT
  !endif

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

; t6b-fix（架构裁定）：唯一的目标校验入口。
;
; 允许的安装位置只有两种：
;   * $PROGRAMFILES64\Vega —— 默认位置，继承 ACL 已经是管理员独占写；
;   * <X>:\Vega —— 本地固定 NTFS 盘根目录下的 Vega（安装后由 icacls 收紧 ACL）。
; 用户选/输的其它路径一律规范成 <X>:\Vega（取该路径的盘符）；规范化确实改变了用户的
; 选择时置 $vegaTargetChanged=1，由目录页回调提示。
;
; 拒绝：空路径、相对路径、UNC（\\server\share）、驱动器类型不是 3（DRIVE_FIXED，排除
; U 盘/光驱/网络盘/内存盘）、文件系统不是 NTFS（FAT32/exFAT 没有可用的 DACL）。
;
; 已存在的目录只接受两种：空目录，或「已是 Vega 安装」——存在 vega-console.exe 且它是
; 文件（FILE_ATTRIBUTE_DIRECTORY 未置位）。空目录用 FindFirst/FindNext 判定并跳过
; "." 与 ".."；`IfFileExists "$DIR\*.*"` 会把空目录里的点目录项当命中，不能用。
; 任何别的非空目录都拒绝：否则等于把用户已有数据锁成管理员独占。
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
  ; 系统盘 Program Files 下的 Vega 原样保留；其余一律 <盘符>:\Vega。
  ${StrCase} $vegaTmp1 "$INSTDIR" "L"
  ${StrCase} $vegaTmp2 "$PROGRAMFILES64\Vega" "L"
  StrCmp $vegaTmp1 $vegaTmp2 vega_validate_keep_programfiles

  StrCpy $vegaTmp3 "$INSTDIR" 2
  StrCpy $vegaTmp3 "$vegaTmp3\Vega"
  ${StrCase} $vegaTmp1 "$vegaTmp3" "L"
  ${StrCase} $vegaTmp2 "$INSTDIR" "L"
  StrCmp $vegaTmp1 $vegaTmp2 vega_validate_nonempty
  StrCpy $INSTDIR "$vegaTmp3"
  StrCpy $vegaTargetChanged "1"
  Goto vega_validate_nonempty

vega_validate_keep_programfiles:
  StrCpy $INSTDIR "$PROGRAMFILES64\Vega"

vega_validate_nonempty:
  FindFirst $0 $1 "$INSTDIR\*.*"
  StrCmp $0 "" vega_validate_scan_closed
vega_validate_scan:
  StrCmp $1 "." vega_validate_scan_next
  StrCmp $1 ".." vega_validate_scan_next
  StrCpy $vegaTargetEmpty "0"
  Goto vega_validate_scan_done
vega_validate_scan_next:
  FindNext $0 $1
  StrCmp $1 "" vega_validate_scan_done
  Goto vega_validate_scan
vega_validate_scan_done:
  FindClose $0
vega_validate_scan_closed:
  StrCmp $vegaTargetEmpty "1" vega_validate_ok

  ; 非空：只接受已有的 Vega 安装。vega-console.exe 必须是文件——GetFileAttributesW
  ; 返回 0xFFFFFFFF 表示不存在，FILE_ATTRIBUTE_DIRECTORY (0x10) 置位表示同名目录。
  System::Call 'kernel32::GetFileAttributesW(w "$INSTDIR\vega-console.exe") i .r0'
  IntCmpU $0 0xFFFFFFFF vega_validate_not_vega vega_validate_exe_attr vega_validate_exe_attr
vega_validate_exe_attr:
  IntOp $1 $0 & 0x10
  StrCmp $1 "0" vega_validate_ok
vega_validate_not_vega:
  StrCpy $vegaTargetError "目录 $INSTDIR 已存在且不为空，但不是 Vega 安装目录。请选择空目录（或新建一个），或选择已有的 Vega 目录。"
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
