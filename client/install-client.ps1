<#
  Vega Remote - 主控端安装脚本
  安装 Moonlight + Tailscale（可选 RustDesk）。
#>
param([switch]$SkipTailscale, [switch]$WithRustDesk)
$ErrorActionPreference = "Stop"

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "未找到 winget。请先从微软商店安装「应用安装程序」(App Installer)。"
}
function Install-Pkg($id) {
    $installed = winget list --id $id -e 2>$null | Select-String $id
    if ($installed) { Write-Host "已安装: $id"; return }
    winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements
}

Install-Pkg "MoonlightGameStreamingProject.Moonlight"
if (-not $SkipTailscale) { Install-Pkg "Tailscale.Tailscale" }
if ($WithRustDesk) { Install-Pkg "RustDesk.RustDesk" }

Write-Host "`n完成。接下来："
Write-Host "1. 登录 Tailscale（与被控端同一账号）"
Write-Host "2. 打开 Moonlight → 右上角 + → 输入被控端 100.x.x.x 或 IPv6 地址"
Write-Host "3. 在被控端 Sunshine 管理页的 PIN 页面输入 Moonlight 显示的 PIN"
Write-Host "4. Moonlight 设置：分辨率选原生，帧率 60，码率默认，开启 HEVC"
