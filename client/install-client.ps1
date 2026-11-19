#Requires -Version 5.1
<#
.SYNOPSIS
  Vega Remote - 主控端安装 / 卸载脚本。

.DESCRIPTION
  安装：Moonlight + Tailscale（可选 RustDesk）。
  卸载：按 %ProgramData%\Vega\state.json 清单，用 -RemoveApps 卸载 Vega 装过的组件。
  已安装的组件自动跳过，可重复执行。
  兼容 Windows PowerShell 5.1 与 PowerShell 7。

.PARAMETER SkipTailscale
  不安装 / 不卸载 Tailscale。

.PARAMETER WithRustDesk
  额外安装（卸载模式下额外卸载）RustDesk。

.PARAMETER Uninstall
  卸载模式：配合 -RemoveApps 按清单卸载组件。

.PARAMETER RemoveApps
  用 winget 卸载清单里由 Vega 安装的 Moonlight / Tailscale / RustDesk。

.PARAMETER Force
  已安装时仍重新执行 winget install。

.EXAMPLE
  .\install-client.ps1

.EXAMPLE
  .\install-client.ps1 -Uninstall -RemoveApps
#>
[CmdletBinding()]
param(
    [switch]$SkipTailscale,
    [switch]$WithRustDesk,
    [switch]$Uninstall,
    [switch]$RemoveApps,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "缺少共享模块：$modulePath"
}
Import-Module $modulePath -Force

$result = $null
try {
    if ($Uninstall) {
        $result = Invoke-VegaClientUninstall -SkipTailscale:$SkipTailscale -WithRustDesk:$WithRustDesk -RemoveApps:$RemoveApps -Confirm:$false
    }
    else {
        $result = Invoke-VegaClientInstall -SkipTailscale:$SkipTailscale -WithRustDesk:$WithRustDesk -Force:$Force -Confirm:$false
    }
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

if ($result.Failures.Count -gt 0) {
    Write-Host "`n以下步骤失败，退出码 1：" -ForegroundColor Red
    foreach ($line in $result.Failures) { Write-Host "  - $line" -ForegroundColor Red }
}

exit $result.ExitCode
