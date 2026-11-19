#Requires -Version 5.1
<#
.SYNOPSIS
  Vega Remote - 主控端安装 / 卸载脚本。

.DESCRIPTION
  安装：Moonlight + Tailscale（可选 RustDesk）。
  卸载：可选 -RemoveApps 用 winget 卸载上述组件。
  已安装的组件自动跳过，可重复执行。
  兼容 Windows PowerShell 5.1 与 PowerShell 7。

.PARAMETER SkipTailscale
  不安装 / 不卸载 Tailscale。

.PARAMETER WithRustDesk
  额外安装（卸载模式下额外卸载）RustDesk。

.PARAMETER Uninstall
  卸载模式：配合 -RemoveApps 卸载组件。

.PARAMETER RemoveApps
  用 winget 卸载 Moonlight / Tailscale / RustDesk。

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

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Test-VegaWingetAvailable {
    return [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
}

$selected = New-Object System.Collections.Generic.List[string]
$selected.Add('Moonlight')
if (-not $SkipTailscale) { $selected.Add('Tailscale') }
if ($WithRustDesk) { $selected.Add('RustDesk') }

if (-not (Test-VegaWingetAvailable)) {
    if ($Uninstall -and -not $RemoveApps) {
        Write-Host '没有指定 -RemoveApps，卸载模式不会改动系统（winget 不可用也不影响）。'
        exit 0
    }
    throw '未找到 winget。请先从微软商店安装「应用安装程序」(App Installer)。'
}

if ($Uninstall) {
    if (-not $RemoveApps) {
        Write-Host '没有指定 -RemoveApps，卸载模式不会改动系统。'
        Write-Host '如需卸载 Moonlight / Tailscale / RustDesk，请运行：.\install-client.ps1 -Uninstall -RemoveApps'
        exit 0
    }

    Write-Step '用 winget 卸载组件'
    foreach ($name in $selected) {
        $component = Get-VegaComponent -Name $name
        try {
            $done = Uninstall-VegaPackage -PackageId $component.PackageId -DisplayName $component.Name -Confirm:$false
            if ($done) { Write-Host "已卸载 $($component.Name)" }
            else { Write-Host "$($component.Name) 未安装，跳过" }
        }
        catch {
            Write-Warning "卸载 $($component.Name) 失败：$($_.Exception.Message)"
        }
    }

    Write-Step '卸载完成'
    Write-Host '提示：Tailscale 卸载后需要重新登录才能恢复 100.x.x.x 地址。'
    exit 0
}

Write-Step '安装 Moonlight'
$moonlight = Get-VegaComponent -Name 'Moonlight'
$null = Install-VegaPackage -PackageId $moonlight.PackageId -DisplayName $moonlight.Name -Force:$Force

if (-not $SkipTailscale) {
    Write-Step '安装 Tailscale'
    $tailscale = Get-VegaComponent -Name 'Tailscale'
    $null = Install-VegaPackage -PackageId $tailscale.PackageId -DisplayName $tailscale.Name -Force:$Force
}

if ($WithRustDesk) {
    Write-Step '安装 RustDesk（备用）'
    $rustdesk = Get-VegaComponent -Name 'RustDesk'
    $null = Install-VegaPackage -PackageId $rustdesk.PackageId -DisplayName $rustdesk.Name -Force:$Force
}

Write-Step '完成'
Write-Host '接下来：'
Write-Host '1. 登录 Tailscale（与被控端同一账号）'
Write-Host '2. 打开 Moonlight → 右上角 + → 输入被控端 100.x.x.x 或 IPv6 地址'
Write-Host '3. 在被控端 Sunshine 管理页的 PIN 页面输入 Moonlight 显示的 PIN'
Write-Host '4. Moonlight 设置：分辨率选原生，帧率 60，码率默认，开启 HEVC'
Write-Host '诊断：.\tools\vega-doctor.ps1 -Peer <被控端机器名>'
