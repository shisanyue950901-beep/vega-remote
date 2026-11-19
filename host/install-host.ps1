#Requires -RunAsAdministrator
<#
  Vega Remote - 被控端安装脚本
  安装 Sunshine + Tailscale，写入自适应配置，放行防火墙，关闭睡眠。
#>
param(
    [string]$WebUser = "vega",
    [switch]$SkipTailscale,
    [switch]$WithRustDesk
)

$ErrorActionPreference = "Stop"
function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "未找到 winget。请先从微软商店安装「应用安装程序」(App Installer)。"
}

function Install-Pkg($id) {
    $installed = winget list --id $id -e 2>$null | Select-String $id
    if ($installed) { Write-Host "已安装: $id"; return }
    winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements
}

Step "安装 Sunshine"
Install-Pkg "LizardByte.Sunshine"

if (-not $SkipTailscale) {
    Step "安装 Tailscale"
    Install-Pkg "Tailscale.Tailscale"
}
if ($WithRustDesk) {
    Step "安装 RustDesk（备用）"
    Install-Pkg "RustDesk.RustDesk"
}

$SunDir  = Join-Path $env:ProgramFiles "Sunshine"
$ConfDir = Join-Path $SunDir "config"
$Conf    = Join-Path $ConfDir "sunshine.conf"
$Exe     = Join-Path $SunDir "sunshine.exe"
if (-not (Test-Path $Exe)) { throw "未找到 $Exe，Sunshine 安装可能失败。" }

Step "检测显卡"
$gpus = Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name
$gpus | ForEach-Object { Write-Host "  - $_" }
# 优先独显：NVIDIA > AMD 独显 > Intel
$preferred = ($gpus | Where-Object { $_ -match "NVIDIA" } | Select-Object -First 1)
if (-not $preferred) { $preferred = ($gpus | Where-Object { $_ -match "Radeon RX|Radeon Pro" } | Select-Object -First 1) }
if (-not $preferred) { $preferred = ($gpus | Select-Object -First 1) }
Write-Host "编码将使用: $preferred" -ForegroundColor Green

Step "写入 Sunshine 配置"
New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null
if (Test-Path $Conf) { Copy-Item $Conf "$Conf.bak" -Force; Write-Host "已备份原配置到 sunshine.conf.bak" }
$template = Get-Content (Join-Path $PSScriptRoot "sunshine.conf") -Raw
$template = $template -replace "__ADAPTER__", $preferred
Set-Content -Path $Conf -Value $template -Encoding UTF8

Step "设置 Web 管理账号"
$sec = Read-Host "为用户 '$WebUser' 设置 Sunshine 管理密码" -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
& $Exe --creds $WebUser $plain | Out-Null
$plain = $null

Step "放行防火墙"
$rules = @(
    @{Name="Vega-Sunshine-TCP"; Proto="TCP"; Ports="47984,47989,47990,48010"},
    @{Name="Vega-Sunshine-UDP"; Proto="UDP"; Ports="47998-48000,48002,48010"}
)
foreach ($r in $rules) {
    Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
        -Protocol $r.Proto -LocalPort ($r.Ports -split ",") -Profile Any | Out-Null
}

Step "关闭插电睡眠"
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

Step "重启 Sunshine 服务"
$svc = Get-Service | Where-Object { $_.Name -match "sunshine" } | Select-Object -First 1
if ($svc) { Restart-Service $svc.Name -Force; Set-Service $svc.Name -StartupType Automatic }
else { Write-Warning "未找到 Sunshine 服务，请手动启动 Sunshine。" }

Step "完成"
$v6 = Get-NetIPAddress -AddressFamily IPv6 -PrefixOrigin RouterAdvertisement -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -notmatch "^fe80" } | Select-Object -First 1 -ExpandProperty IPAddress
Write-Host "管理页面: 本机浏览器打开 localhost 的 47990 端口（https）"
if (-not $SkipTailscale) { Write-Host "下一步: 打开 Tailscale 登录，记下本机 100.x.x.x 地址" }
if ($v6) { Write-Host "检测到公网 IPv6: $v6 （可在 Moonlight 中直接添加）" -ForegroundColor Green }
else { Write-Host "未检测到公网 IPv6，将使用 Tailscale 组网" }
