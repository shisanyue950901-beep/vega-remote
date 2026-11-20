#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Vega Remote - 被控端安装 / 卸载脚本。

.DESCRIPTION
  安装：Sunshine + Tailscale（可选 RustDesk），写入自适应配置，只放行串流端口，关闭插电睡眠。
  管理密码不在脚本里设置：装完后在本机浏览器打开 https://localhost:47990，由 Sunshine
  页面引导首次设密。脚本会把管理页限制为本机访问（origin_web_ui_allowed = pc），
  不放行 47990，并禁用 Sunshine 安装器自带的对 47990 的放行规则。
  卸载：只按 %ProgramData%\Vega\host-state.json 清单回滚（回滚前逐条过白名单）。
  可重复执行：已安装的组件跳过，配置只更新 Vega 管理的键，防火墙规则先删后建。
  兼容 Windows PowerShell 5.1 与 PowerShell 7。

.PARAMETER SkipTailscale
  不安装（卸载模式下不卸载）Tailscale。

.PARAMETER WithRustDesk
  额外安装（卸载模式下额外卸载）RustDesk。

.PARAMETER Uninstall
  卸载模式：按状态清单回滚防火墙、配置和服务状态。

.PARAMETER RemoveApps
  仅在 -Uninstall 时有效：卸载清单里记录的、由 Vega 安装的组件。

.PARAMETER Force
  安装模式下强制重装组件（交给 winget install --force 语义）。

.PARAMETER RustDeskServer
  RustDesk 中继服务器地址（主机名/IPv4/IPv6，可带 :端口）。必须与 -RustDeskKey 同时提供；
  都不提供时读取仓库根目录可选的 vega.config.json，仍没有就跳过并提示。

.PARAMETER RustDeskKey
  RustDesk 中继公钥（base64 样式，约 44 字符）。脚本不接收、不保存任何密码。

.EXAMPLE
  .\install-host.ps1

.EXAMPLE
  .\install-host.ps1 -Uninstall

.EXAMPLE
  .\install-host.ps1 -Uninstall -RemoveApps
#>
[CmdletBinding()]
param(
    [switch]$SkipTailscale,
    [switch]$WithRustDesk,
    [switch]$Uninstall,
    [switch]$RemoveApps,
    [switch]$Force,
    [string]$RustDeskServer = '',
    [string]$RustDeskKey = ''
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Join-Path $PSScriptRoot 'lib') 'Vega.Common.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "缺少共享模块：$modulePath"
}
Import-Module $modulePath -Force

# 控制台的「安装 RustDesk」只认管理员目录里的脚本：提权前不再读取
# %VEGA_HOST_SCRIPT% 或仓库 checkout，避免普通用户可写的路径被 UAC 提权执行。
# 安装模式下把本脚本与共享模块固定发布到 %ProgramData%\Vega\host（该目录
# 继承 ProgramData ACL，只有管理员可写）。
if (-not $Uninstall) {
    try {
        $publishRoot = Join-Path (Join-Path $env:ProgramData 'Vega') 'host'
        $publishLib = Join-Path $publishRoot 'lib'
        $publishScript = Join-Path $publishRoot 'install-host.ps1'
        $publishModule = Join-Path $publishLib 'Vega.Common.psm1'
        $null = New-Item -ItemType Directory -Path $publishLib -Force
        # 从发布目录再次运行时源和目标是同一个文件，跳过复制。
        if ($PSCommandPath -ne $publishScript) {
            Copy-Item -LiteralPath $PSCommandPath -Destination $publishScript -Force
        }
        if ($modulePath -ne $publishModule) {
            Copy-Item -LiteralPath $modulePath -Destination $publishModule -Force
        }
    }
    catch {
        Write-Host "警告：未能发布安装脚本到 %ProgramData%\Vega\host，控制台内的「安装 RustDesk」将不可用：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$result = $null
try {
    if ($Uninstall) {
        $result = Invoke-VegaHostUninstall -SkipTailscale:$SkipTailscale -WithRustDesk:$WithRustDesk -RemoveApps:$RemoveApps -Confirm:$false
    }
    else {
        $result = Invoke-VegaHostInstall -SkipTailscale:$SkipTailscale -WithRustDesk:$WithRustDesk -Force:$Force `
            -RustDeskServer $RustDeskServer -RustDeskKey $RustDeskKey -Confirm:$false
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
