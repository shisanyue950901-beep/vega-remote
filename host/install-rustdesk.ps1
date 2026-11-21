#Requires -Version 5.1
<#
.SYNOPSIS
  Vega 安装包内的 RustDesk 一键安装 / 配置 / 回滚脚本。

.DESCRIPTION
  由 Vega-Setup.exe 的 NSIS 钩子在提权上下文里调用（perMachine，只提权这一次），
  也可以在被控端管理员 PowerShell 里手动运行。

  安装：
    - 读取随包的 vega-defaults.json（idServer / relayServer / key）；
    - 已装 RustDesk 就跳过安装，只写中继配置；
    - 未装时从官方 GitHub Release 下载固定版本（AGPL：不内嵌二进制），
      校验 SHA256 后以 --silent-install 静默安装，等待 RustDesk 服务出现；
    - 复用 Vega.Common 里 T2 的 RustDesk2.toml 写入逻辑（ACL 校验、原子写入）：
      NSIS 钩子把当前登录交互用户的 SID / Roaming AppData 传进来，只写该用户自己的
      用户级配置 + LocalService 服务级配置，两处回读一致才算成功；取不到交互用户时
      退回只写服务级，并让完成页提示。绝不写提权账户的 %APPDATA%；
    - 若这次是 Vega 装的，把安装记录写进 host-state.json，卸载时据此回滚。

  回滚（-Uninstall）：
    - 只按 state.json / host-state.json 里的记录恢复受管键；
    - 只卸载本次由 Vega 安装、且 state.json 记录了安装路径的 RustDesk；
      -KeepRustDesk 可保留，卸载失败时保留记录作为重试入口。

  脚本失败不会让 Vega 安装失败：NSIS 钩子只提示用户到 Vega 里手动安装。

.PARAMETER DefaultsFile
  默认中继配置。默认取脚本同级目录的上一级（安装包里的 resources\vega-defaults.json）。

.PARAMETER LogFile
  日志路径，默认 %ProgramData%\Vega\logs\setup.log。写日志失败不影响安装。

.PARAMETER Uninstall
  回滚模式：恢复 RustDesk 配置，并按记录决定是否卸载 RustDesk。

.PARAMETER KeepRustDesk
  回滚模式下不卸载 RustDesk，只恢复配置。

.PARAMETER StatePath
  被控端清单路径，默认 %ProgramData%\Vega\host-state.json。

.PARAMETER ServiceStatePath
  服务模式清单路径，默认 %ProgramData%\Vega\state.json。

.PARAMETER InteractiveUserSid
  当前登录交互用户（explorer.exe 所有者或活动会话用户）的 SID，由 NSIS 钩子解析后传入。
  用于把用户级 RustDesk2.toml 写到该用户自己的 Roaming AppData，而不是提权账户。

.PARAMETER InteractiveUserAppData
  该交互用户的 Roaming AppData 路径（HKU\<SID>\...\Shell Folders\AppData 或
  ProfileList 的 ProfileImagePath\AppData\Roaming），与 -InteractiveUserSid 一起传入。
  取不到时脚本只写服务级配置，并在完成页提示。

.EXAMPLE
  .\install-rustdesk.ps1 -DefaultsFile .\resources\vega-defaults.json

.EXAMPLE
  .\install-rustdesk.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$DefaultsFile = '',
    [string]$LogFile = '',
    [switch]$Uninstall,
    [switch]$KeepRustDesk,
    [string]$StatePath = '',
    [string]$ServiceStatePath = '',
    [string]$InteractiveUserSid = '',
    [string]$InteractiveUserAppData = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) { $programData = $env:TEMP }
    $LogFile = Join-Path (Join-Path (Join-Path $programData 'Vega') 'logs') 'setup.log'
}

if ([string]::IsNullOrWhiteSpace($DefaultsFile)) {
    $DefaultsFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'vega-defaults.json'
}

$modulePath = Join-Path (Join-Path $PSScriptRoot 'lib') 'Vega.Common.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host "缺少共享模块：$modulePath" -ForegroundColor Red
    exit 1
}
Import-Module $modulePath -Force

Write-VegaSetupLog -Path $LogFile -Message ("开始：Uninstall={0} DefaultsFile={1}" -f [bool]$Uninstall, $DefaultsFile)

if (-not (Test-VegaProcessElevated)) {
    # 安装包调用时一定是提权的；手动运行时给出可执行的原因，而不是等到写配置才报错。
    Write-Host '需要管理员权限：请右键以管理员身份运行，或由 Vega-Setup.exe 调用。' -ForegroundColor Red
    Write-VegaSetupLog -Path $LogFile -Message 'FAIL 当前进程未提权'
    exit 1
}

if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = Get-VegaHostStatePath }
if ([string]::IsNullOrWhiteSpace($ServiceStatePath)) { $ServiceStatePath = Get-VegaRustDeskServiceStatePath }

try {
    if ($Uninstall) {
        $rollback = Invoke-VegaRustDeskRollback -HostStatePath $StatePath -ServiceStatePath $ServiceStatePath `
            -InteractiveUserAppData $InteractiveUserAppData -KeepRustDesk:$KeepRustDesk -Confirm:$false

        foreach ($message in @($rollback.Messages)) {
            Write-Host $message
            Write-VegaSetupLog -Path $LogFile -Message $message
        }
        foreach ($failure in @($rollback.Failures)) {
            Write-Host $failure -ForegroundColor Yellow
            Write-VegaSetupLog -Path $LogFile -Message "FAIL $failure"
        }
        exit $rollback.ExitCode
    }

    $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $DefaultsFile -HostStatePath $StatePath `
        -ServiceStatePath $ServiceStatePath -InteractiveUserSid $InteractiveUserSid `
        -InteractiveUserAppData $InteractiveUserAppData -LogFile $LogFile -Confirm:$false

    foreach ($message in @($result.Messages)) {
        Write-Host $message
        Write-VegaSetupLog -Path $LogFile -Message $message
    }

    if (-not $result.Success) {
        Write-Host $result.Error -ForegroundColor Yellow
        Write-Host '也可以打开 https://rustdesk.com/download 手动下载安装，装完回到 Vega 设置页查看配置。'
        Write-VegaSetupLog -Path $LogFile -Message "FAIL $($result.Error)"
        exit 1
    }

    Write-Host 'RustDesk 已安装并写入自建中继配置。' -ForegroundColor Green
    Write-VegaSetupLog -Path $LogFile -Message '完成'
    exit 0
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-VegaSetupLog -Path $LogFile -Message "FAIL 未捕获异常：$($_.Exception.Message)"
    exit 1
}
