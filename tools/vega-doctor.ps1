#Requires -Version 5.1
<#
.SYNOPSIS
  Vega Remote 一键诊断（只读，不修改任何系统设置）。

.DESCRIPTION
  检查并打印：
    - 显卡列表与推荐编码器（NVENC / AMF / QSV）
    - Sunshine 是否安装、SunshineService 服务状态、版本、配置路径
    - Vega 防火墙规则是否存在
    - 公网 IPv6
    - Tailscale 是否安装、`tailscale status` 摘要
    - 带 -Peer 时运行 `tailscale ping -c 3 <Peer>`，判断直连 / DERP 中继 / Peer Relay
  最后给出中文结论与建议。

  脚本本身不安装、不删除、不改配置，可放心重复运行。
  兼容 Windows PowerShell 5.1 与 PowerShell 7。

.PARAMETER Peer
  被控端的 Tailscale 机器名，例如 vega-host。不填只做本机检查。

.EXAMPLE
  .\tools\vega-doctor.ps1

.EXAMPLE
  .\tools\vega-doctor.ps1 -Peer vega-host
#>
[CmdletBinding()]
param(
    [string]$Peer = ''
)

$ErrorActionPreference = 'Continue'

$modulePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "缺少共享模块：$modulePath"
}
Import-Module $modulePath -Force

function Write-Section {
    param([string]$Title)
    Write-Host "`n==> $Title" -ForegroundColor Cyan
}

function Get-VegaGpuName {
    try {
        return @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            ForEach-Object { [string]$_.Name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    catch {
        Write-Warning "读取显卡列表失败：$($_.Exception.Message)"
        return @()
    }
}

function Get-VegaTailscaleExe {
    <#
      优先用默认安装目录的绝对路径，避免走 PATH 上的同名程序。
    #>
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidate = Join-Path (Join-Path $env:ProgramFiles 'Tailscale') 'tailscale.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command -and -not [string]::IsNullOrWhiteSpace($command.Source)) { return $command.Source }

    return $null
}

function Format-VegaPingPath {
    param($Pong)
    switch ($Pong.Mode) {
        'Direct' { return ('直连({0})' -f $Pong.Endpoint) }
        'Derp' { return ('DERP({0})' -f $Pong.Region) }
        'PeerRelay' { return ('PeerRelay({0})' -f $Pong.Region) }
        default { return '未知' }
    }
}

# ---------------------------------------------------------------------------
# 显卡与编码器
# ---------------------------------------------------------------------------

Write-Section '显卡与编码器'
$gpuNames = Get-VegaGpuName
if ($gpuNames.Count -eq 0) {
    Write-Host '未检测到显卡。'
}
else {
    foreach ($gpu in $gpuNames) {
        Write-Host "  - $gpu"
    }
}

$preferred = Select-VegaAdapter -GpuNames $gpuNames -SkipVirtual
if (-not $preferred) { $preferred = Select-VegaAdapter -GpuNames $gpuNames }
$encoderName = Get-VegaEncoderName -AdapterName $preferred

if ($preferred) {
    Write-Host "推荐显卡: $preferred" -ForegroundColor Green
    Write-Host "推荐编码器: $encoderName（sunshine.conf 不写 encoder，由 Sunshine 自动选择）" -ForegroundColor Green
}
else {
    Write-Host '推荐编码器: SOFTWARE（未识别到可用显卡，将由 CPU 软编）' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Sunshine
# ---------------------------------------------------------------------------

Write-Section 'Sunshine'
$sunshine = Get-VegaSunshineInstall
if ($sunshine) {
    Write-Host "已安装: $($sunshine.Directory)"
    if ([string]::IsNullOrWhiteSpace($sunshine.Version)) {
        Write-Host '版本: 无法读取（文件版本信息为空）'
    }
    else {
        Write-Host "版本: $($sunshine.Version)"
    }
    Write-Host "配置: $($sunshine.Config)"
}
else {
    Write-Host '未检测到 Sunshine（Program Files 下没有 sunshine.exe）' -ForegroundColor Yellow
}

$sunshineServices = @(Get-VegaSunshineService)
$sunshineRunning = $false
if ($sunshineServices.Count -eq 0) {
    Write-Host '服务: 未找到 SunshineService（旧版为 sunshinesvc）'
}
else {
    foreach ($service in $sunshineServices) {
        Write-Host "服务: $($service.Name) / $($service.Status) / 启动类型 $($service.StartType)"
        if ($service.Status -eq 'Running') { $sunshineRunning = $true }
    }
}

# ---------------------------------------------------------------------------
# 防火墙
# ---------------------------------------------------------------------------

Write-Section '防火墙'
$missingRules = @(Get-VegaFirewallRuleMissing)
if ($missingRules.Count -eq 0) {
    Write-Host 'Vega-Sunshine-TCP / Vega-Sunshine-UDP 均存在' -ForegroundColor Green
}
else {
    Write-Host "缺少规则: $($missingRules -join '、')" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# RustDesk
# ---------------------------------------------------------------------------

Write-Section 'RustDesk'
$rustDeskExpected = $null
$repoConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'vega.config.json'
try {
    $rustDeskExpected = Resolve-VegaRustDeskSetting -ConfigPath $repoConfigPath
}
catch {
    Write-Host "读取 vega.config.json 失败：$($_.Exception.Message)" -ForegroundColor Yellow
}

$rustDeskToml = Get-VegaRustDeskConfigPath
$rustDeskActual = ''
if (Test-Path -LiteralPath $rustDeskToml -PathType Leaf) {
    $tomlText = Get-Content -LiteralPath $rustDeskToml -Raw -Encoding UTF8
    $tomlOptions = ConvertFrom-VegaRustDeskConfigText -Text $tomlText
    if ($tomlOptions.Contains('custom-rendezvous-server')) {
        $rustDeskActual = [string]$tomlOptions['custom-rendezvous-server']
    }
    Write-Host "配置: $rustDeskToml"
    if ([string]::IsNullOrWhiteSpace($rustDeskActual)) {
        Write-Host '中继服务器: 未配置（custom-rendezvous-server 为空）' -ForegroundColor Yellow
    }
    else {
        Write-Host "中继服务器: $rustDeskActual" -ForegroundColor Green
    }
}
else {
    Write-Host "未找到 RustDesk2.toml：$rustDeskToml（RustDesk 未安装或还没登录过）" -ForegroundColor Yellow
}

if ($null -ne $rustDeskExpected) {
    if ($rustDeskActual -eq $rustDeskExpected.Server) {
        Write-Host "与 vega.config.json 一致: $($rustDeskExpected.Server)" -ForegroundColor Green
    }
    else {
        Write-Host "与 vega.config.json 不一致：期望 $($rustDeskExpected.Server)，实际 $(if ($rustDeskActual) { $rustDeskActual } else { '未配置' })" -ForegroundColor Yellow
    }
}

$rustDeskDeviceId = ''
$rustDeskExe = Get-VegaRustDeskInstall
if ([string]::IsNullOrWhiteSpace($rustDeskExe)) {
    Write-Host '未检测到 rustdesk.exe（Program Files / LOCALAPPDATA\Programs 下都没有）' -ForegroundColor Yellow
}
else {
    Write-Host "已安装: $rustDeskExe"
    $device = Get-VegaRustDeskDeviceId -Exe $rustDeskExe
    if ($device.Success) {
        $rustDeskDeviceId = $device.DeviceId
        Write-Host ("设备码: {0}" -f (Format-VegaRustDeskId -DeviceId $device.DeviceId)) -ForegroundColor Green
    }
    else {
        Write-Host "设备码: 读取失败（$($device.Error)）" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# IPv6
# ---------------------------------------------------------------------------

Write-Section '公网 IPv6'
$ipv6 = @(Get-VegaPublicIPv6)
if ($ipv6.Count -gt 0) {
    foreach ($address in $ipv6) { Write-Host "  - $address" -ForegroundColor Green }
}
else {
    Write-Host '未检测到公网 IPv6'
}

# ---------------------------------------------------------------------------
# Tailscale
# ---------------------------------------------------------------------------

Write-Section 'Tailscale'
$tailscaleExe = Get-VegaTailscaleExe
$tailscaleInstalled = [bool]$tailscaleExe
if (-not $tailscaleInstalled) {
    Write-Host '未检测到 Tailscale（默认安装目录与 PATH 上都没有 tailscale.exe）' -ForegroundColor Yellow
}
else {
    Write-Host "已安装: $tailscaleExe"
    $status = Invoke-VegaCommand -FilePath $tailscaleExe -ArgumentList @('status') -TimeoutSeconds 30
    if ($status.ExitCode -ne 0) {
        Write-Host "tailscale status 退出码 $($status.ExitCode)，输出：" -ForegroundColor Yellow
        foreach ($line in $status.Output) { Write-Host "  $line" }
    }
    elseif ($status.Output.Count -eq 0) {
        Write-Host 'tailscale status 没有输出（可能未登录）'
    }
    else {
        $statusLines = @($status.Output)
        $maxLines = 12
        $count = [Math]::Min($statusLines.Count, $maxLines)
        for ($index = 0; $index -lt $count; $index++) {
            Write-Host "  $($statusLines[$index])"
        }
        if ($statusLines.Count -gt $maxLines) {
            Write-Host "  ...（共 $($statusLines.Count) 行，仅显示前 $maxLines 行）"
        }
    }
}

# ---------------------------------------------------------------------------
# Tailscale ping
# ---------------------------------------------------------------------------

$pingResult = $null
if (-not [string]::IsNullOrWhiteSpace($Peer)) {
    Write-Section "Tailscale ping $Peer"
    if (-not $tailscaleInstalled) {
        Write-Host '未安装 Tailscale，无法执行 tailscale ping。' -ForegroundColor Yellow
    }
    else {
        $ping = Invoke-VegaCommand -FilePath $tailscaleExe -ArgumentList @('ping', '-c', '3', $Peer) -TimeoutSeconds 60
        $pingResult = ConvertFrom-VegaTailscalePing -Output @($ping.Output)
        foreach ($line in $ping.Output) { Write-Host "  $line" }

        if ($pingResult.Succeeded) {
            switch ($pingResult.Mode) {
                'Direct' {
                    Write-Host "结论: 直连（$($pingResult.Endpoint)，$($pingResult.LatencyMs)ms）" -ForegroundColor Green
                }
                'PeerRelay' {
                    Write-Host "结论: 走 Peer Relay（$($pingResult.Endpoint)，$($pingResult.LatencyMs)ms），不是直连" -ForegroundColor Yellow
                }
                'Derp' {
                    Write-Host "结论: 走 DERP 中继（$($pingResult.Region)）" -ForegroundColor Yellow
                }
                default {
                    Write-Host '结论: 收到 pong，但无法识别连接类型（见上方原始输出）' -ForegroundColor Yellow
                }
            }

            # 按 pong 的实际顺序打印路径，不靠计数推断
            if (@($pingResult.Pongs).Count -gt 1) {
                $paths = @(foreach ($pong in @($pingResult.Pongs)) { Format-VegaPingPath -Pong $pong })
                Write-Host ("过程: {0}" -f ($paths -join ' → '))
            }
        }
        else {
            Write-Host '结论: 没有收到 pong（见上方原始输出）' -ForegroundColor Yellow
        }
    }
}

# ---------------------------------------------------------------------------
# 结论与建议
# ---------------------------------------------------------------------------

$facts = @{
    AdapterName          = $preferred
    Encoder              = $encoderName
    SunshineInstalled    = [bool]$sunshine
    SunshineRunning      = $sunshineRunning
    SunshineVersion      = $(if ($sunshine) { $sunshine.Version } else { '' })
    MissingFirewallRules = $missingRules
    Ipv6                 = $ipv6
    TailscaleInstalled   = $tailscaleInstalled
    Peer                 = $Peer
    RustDeskTomlServer   = $rustDeskActual
    RustDeskDeviceId     = $rustDeskDeviceId
}

if ($null -ne $rustDeskExpected) { $facts['RustDeskExpectedServer'] = $rustDeskExpected.Server }

if ($null -ne $pingResult) { $facts['Ping'] = $pingResult }

Write-Section '结论与建议'
$advice = @(Get-VegaDoctorAdvice -Facts $facts)
$number = 1
foreach ($line in $advice) {
    Write-Host ("{0}. {1}" -f $number, $line)
    $number++
}

Write-Host ''
Write-Host '本脚本只读，不会修改系统。重新检查只需再运行一次。' -ForegroundColor DarkGray
