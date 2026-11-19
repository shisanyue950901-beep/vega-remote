#Requires -Version 5.1
<#
.SYNOPSIS
  Vega Remote 一键诊断（只读，不修改任何系统设置）。

.DESCRIPTION
  检查并打印：
    - 显卡列表与推荐编码器（NVENC / AMF / QSV）
    - Sunshine 是否安装、服务状态、版本、配置路径
    - Vega 防火墙规则是否存在
    - 公网 IPv6
    - Tailscale 是否安装、`tailscale status` 摘要
    - 带 -Peer 时运行 `tailscale ping -c 3 <Peer>`，判断直连还是 DERP 中继
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

function Get-VegaSunshineInstall {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'Sunshine'
        $exe = Join-Path $candidate 'sunshine.exe'
        if (-not (Test-Path -LiteralPath $exe)) { continue }

        $version = ''
        try {
            $version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
        }
        catch {
            $version = ''
        }

        return [pscustomobject]@{
            Directory = $candidate
            Exe       = $exe
            Config    = (Join-Path (Join-Path $candidate 'config') 'sunshine.conf')
            Version   = $version
        }
    }
    return $null
}

function Get-VegaTailscaleExe {
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidate = Join-Path (Join-Path $env:ProgramFiles 'Tailscale') 'tailscale.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }

    return $null
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
$encoderId = Get-VegaEncoderId -AdapterName $preferred

if ($preferred) {
    Write-Host "推荐显卡: $preferred" -ForegroundColor Green
    Write-Host "推荐编码器: $encoderName（sunshine.conf 中 encoder 取值：$encoderId）" -ForegroundColor Green
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
    Write-Host '服务: 未找到 sunshine 服务'
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
    Write-Host '未检测到 Tailscale（tailscale.exe 不在 PATH，也不在默认安装目录）' -ForegroundColor Yellow
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
            if ($pingResult.Mode -eq 'Direct') {
                Write-Host "结论: 直连（$($pingResult.Endpoint)，$($pingResult.LatencyMs)ms）" -ForegroundColor Green
            }
            else {
                Write-Host "结论: 走 DERP 中继（$($pingResult.Region)）" -ForegroundColor Yellow
            }
            if ($pingResult.DerpCount -gt 0 -and $pingResult.DirectCount -gt 0) {
                Write-Host "过程: 前 $($pingResult.DerpCount) 次中继，后 $($pingResult.DirectCount) 次直连（打洞成功）"
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
}

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
