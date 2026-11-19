#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Vega Remote - 被控端安装 / 卸载脚本。

.DESCRIPTION
  安装：Sunshine + Tailscale（可选 RustDesk），写入自适应配置，放行防火墙，关闭插电睡眠。
  卸载：删除 Vega 创建的防火墙规则，恢复 sunshine.conf.bak（若存在）。
  可重复执行：已安装的组件跳过，防火墙规则先删后建，配置只在首次修改前备份一次。
  兼容 Windows PowerShell 5.1 与 PowerShell 7。

.PARAMETER WebUser
  Sunshine 管理页用户名。

.PARAMETER SkipTailscale
  不安装 / 不卸载 Tailscale。

.PARAMETER WithRustDesk
  额外安装（卸载模式下额外卸载）RustDesk。

.PARAMETER Uninstall
  卸载模式：删除 Vega 防火墙规则，恢复 sunshine.conf.bak（若存在），停止 Sunshine 服务。

.PARAMETER RemoveApps
  仅在 -Uninstall 时有效：用 winget 卸载本次方案装过的组件。

.PARAMETER Force
  安装模式下强制重装组件（交给 winget install --force 语义，已安装时仍会重新执行安装）。

.EXAMPLE
  .\install-host.ps1

.EXAMPLE
  .\install-host.ps1 -Uninstall

.EXAMPLE
  .\install-host.ps1 -Uninstall -RemoveApps
#>
[CmdletBinding()]
param(
    [string]$WebUser = 'vega',
    [switch]$SkipTailscale,
    [switch]$WithRustDesk,
    [switch]$Uninstall,
    [switch]$RemoveApps,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Join-Path $PSScriptRoot 'lib') 'Vega.Common.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "缺少共享模块：$modulePath"
}
Import-Module $modulePath -Force

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-VegaSunshinePath {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Sunshine'),
        (Join-Path ${env:ProgramFiles(x86)} 'Sunshine')
    )
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $exe = Join-Path $candidate 'sunshine.exe'
        if (Test-Path -LiteralPath $exe) {
            return [pscustomobject]@{
                Directory = $candidate
                Exe       = $exe
                Config    = (Join-Path (Join-Path $candidate 'config') 'sunshine.conf')
            }
        }
    }
    return $null
}

function Test-VegaWingetAvailable {
    return [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------

if ($Uninstall) {
    Write-Step '删除 Vega 创建的防火墙规则'
    $removed = Remove-VegaFirewallRule -Confirm:$false
    if ($removed -gt 0) { Write-Host "已删除 $removed 条规则" }
    else { Write-Host '没有需要删除的 Vega 防火墙规则' }

    Write-Step '恢复 Sunshine 配置'
    $sunshine = Get-VegaSunshinePath
    if ($sunshine) {
        if (Restore-VegaSunshineConfig -Path $sunshine.Config -Confirm:$false) {
            Write-Host "已用 sunshine.conf.bak 恢复 $($sunshine.Config)"
        }
        else {
            Write-Host '没有 sunshine.conf.bak，跳过恢复（配置保持现状）'
        }

        $services = @(Get-VegaSunshineService)
        foreach ($service in $services) {
            if ($service.Status -ne 'Stopped') {
                Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $service.Name -StartupType Manual -ErrorAction SilentlyContinue
        }
        if ($services.Count -gt 0) { Write-Host 'Sunshine 服务已停止并改为手动启动' }
    }
    else {
        Write-Host '未找到 Sunshine 安装目录，跳过配置恢复'
    }

    if ($RemoveApps) {
        Write-Step '用 winget 卸载组件'
        if (-not (Test-VegaWingetAvailable)) {
            Write-Warning '未找到 winget，跳过组件卸载；请从「设置 → 应用」手动卸载。'
        }
        else {
            $components = New-Object System.Collections.Generic.List[string]
            $components.Add('Sunshine')
            if (-not $SkipTailscale) { $components.Add('Tailscale') }
            if ($WithRustDesk) { $components.Add('RustDesk') }

            foreach ($name in $components) {
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
        }
    }

    Write-Step '卸载完成'
    Write-Host '已保留：睡眠设置、Sunshine 安装目录（未加 -RemoveApps 时）。'
    Write-Host '如需彻底清理，重新以管理员身份运行：.\install-host.ps1 -Uninstall -RemoveApps'
    exit 0
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------

if (-not (Test-VegaWingetAvailable)) {
    throw '未找到 winget。请先从微软商店安装「应用安装程序」(App Installer)。'
}

Write-Step '安装 Sunshine'
$sunshineComponent = Get-VegaComponent -Name 'Sunshine'
$null = Install-VegaPackage -PackageId $sunshineComponent.PackageId -DisplayName $sunshineComponent.Name -Force:$Force

if (-not $SkipTailscale) {
    Write-Step '安装 Tailscale'
    $tailscaleComponent = Get-VegaComponent -Name 'Tailscale'
    $null = Install-VegaPackage -PackageId $tailscaleComponent.PackageId -DisplayName $tailscaleComponent.Name -Force:$Force
}

if ($WithRustDesk) {
    Write-Step '安装 RustDesk（备用）'
    $rustdeskComponent = Get-VegaComponent -Name 'RustDesk'
    $null = Install-VegaPackage -PackageId $rustdeskComponent.PackageId -DisplayName $rustdeskComponent.Name -Force:$Force
}

$sunshine = Get-VegaSunshinePath
if (-not $sunshine) {
    throw '未找到 Sunshine 安装目录，安装可能失败。可手动执行：winget install --id LizardByte.Sunshine -e'
}

Write-Step '检测显卡'
$gpuNames = @()
try {
    $gpuNames = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
        ForEach-Object { [string]$_.Name } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
catch {
    Write-Warning "读取显卡列表失败：$($_.Exception.Message)"
}

foreach ($gpu in $gpuNames) { Write-Host "  - $gpu" }

$preferred = Select-VegaAdapter -GpuNames $gpuNames -SkipVirtual
if (-not $preferred) { $preferred = Select-VegaAdapter -GpuNames $gpuNames }
if (-not $preferred) {
    Write-Warning '没有检测到可用显卡，将使用 Sunshine 自动探测。'
    $preferred = ''
}

$encoder = Get-VegaEncoderId -AdapterName $preferred
if ([string]::IsNullOrWhiteSpace($preferred)) {
    Write-Host '编码器：自动探测' -ForegroundColor Yellow
}
else {
    Write-Host "编码将使用: $preferred（$(Get-VegaEncoderName -AdapterName $preferred)）" -ForegroundColor Green
}

Write-Step '写入 Sunshine 配置'
$templatePath = Join-Path $PSScriptRoot 'sunshine.conf'
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "缺少配置模板：$templatePath"
}
$template = Get-Content -LiteralPath $templatePath -Raw
$content = Resolve-VegaSunshineConfig -Template $template -AdapterName $preferred -Encoder $encoder
$configResult = Set-VegaSunshineConfig -Path $sunshine.Config -Content $content -Confirm:$false
if ($configResult.BackupCreated) {
    Write-Host "已备份原配置到 $($configResult.BackupPath)"
}
elseif (Test-Path -LiteralPath $configResult.BackupPath) {
    Write-Host "保留已有备份 $($configResult.BackupPath)（不覆盖最初的原配置）"
}
Write-Host "配置已写入 $($configResult.Path)"

Write-Step '设置 Web 管理账号'
$credentialSet = $false
try {
    $secure = Read-Host "为用户 '$WebUser' 设置 Sunshine 管理密码" -AsSecureString
    if ($null -ne $secure -and $secure.Length -gt 0) {
        $credentialSet = Set-VegaSunshineCredential -Executable $sunshine.Exe -User $WebUser -SecurePassword $secure -Confirm:$false
        $secure = $null
    }
    else {
        Write-Host '未输入密码，跳过（可稍后在 Sunshine 管理页设置）'
    }
}
catch {
    Write-Warning "设置管理密码失败：$($_.Exception.Message)"
    Write-Host '提示：密码不会写入日志；可稍后在 Sunshine 管理页重新设置。'
}
if ($credentialSet) { Write-Host "已设置管理账号：$WebUser" }

Write-Step '放行防火墙'
$created = Set-VegaFirewallRule -Confirm:$false
Write-Host "已重建 $created 条 Vega 防火墙规则（先删后建，可重复执行）"

Write-Step '关闭插电睡眠'
foreach ($argument in @(
        @('/change', 'standby-timeout-ac', '0'),
        @('/change', 'hibernate-timeout-ac', '0')
    )) {
    $result = Invoke-VegaCommand -FilePath 'powercfg.exe' -ArgumentList $argument -TimeoutSeconds 30
    if ($result.ExitCode -ne 0) {
        Write-Warning "powercfg $($argument -join ' ') 失败（退出码 $($result.ExitCode)），可手动在电源选项里设置。"
    }
}

Write-Step '重启 Sunshine 服务'
if (-not (Restart-VegaSunshineService -Confirm:$false)) {
    Write-Warning '未找到 Sunshine 服务，请手动启动 Sunshine。'
}

Write-Step '完成'
Write-Host '管理页面：本机浏览器打开 https://localhost:47990'
if (-not $SkipTailscale) {
    Write-Host '下一步：打开 Tailscale 登录，记下本机 100.x.x.x 地址'
}

$v6 = @(Get-VegaPublicIPv6)
if ($v6.Count -gt 0) {
    Write-Host "检测到公网 IPv6: $($v6[0])（可在 Moonlight 中直接添加）" -ForegroundColor Green
}
else {
    Write-Host '未检测到公网 IPv6，将使用 Tailscale 组网'
}

Write-Host "诊断：.\tools\vega-doctor.ps1 -Peer <被控端机器名>"
