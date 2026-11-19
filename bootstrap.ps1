#Requires -Version 5.1
<#
.SYNOPSIS
  Vega Remote 一行安装引导脚本。

.DESCRIPTION
  下载 GitHub 最新 Release 的 vega-remote-<版本>.zip，用同 Release 的 SHA256SUMS.txt
  校验后解压，再调用 host/install-host.ps1 或 client/install-client.ps1。
  需要管理员 PowerShell（被控端要装服务、改防火墙）。
  不接收、不保存任何密码；RustDesk 固定密码请装完后在 RustDesk 界面自行设置。

  用法（默认读取 latest Release）：
    irm https://raw.githubusercontent.com/shisanyue950901-beep/vega-remote/main/bootstrap.ps1 | iex
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/shisanyue950901-beep/vega-remote/main/bootstrap.ps1))) -Role host -RustDeskServer relay.example.com -RustDeskKey KEY

  下载失败时可指定镜像或本地可访问的 zip：
    ... -Role host -ZipUrl https://mirror.example.com/vega-remote-0.2.0.zip

.PARAMETER Role
  host = 被控主机，client = 控制端。不提供时交互询问。

.PARAMETER ZipUrl
  直接指定 zip 下载地址。SHA256SUMS.txt 从同一目录获取。

.PARAMETER Repo
  GitHub 仓库，默认 shisanyue950901-beep/vega-remote。

.PARAMETER ApiUrl
  覆盖 Release API 地址（测试或镜像用）。

.PARAMETER DownloadDir
  下载与解压目录，默认 %TEMP%\vega-remote-bootstrap。

.PARAMETER InstallerScript
  跳过下载解压，直接调用指定的安装脚本（离线或测试用）。

.PARAMETER SkipAdminCheck
  跳过管理员检查（仅测试或受限环境用）。

.PARAMETER RemainingArguments
  其余参数原样透传给安装脚本；也可以直接使用下面声明的安装参数。
#>
[CmdletBinding()]
param(
    [ValidateSet('host', 'client')]
    [string]$Role = '',

    [string]$ZipUrl = '',
    [string]$Repo = 'shisanyue950901-beep/vega-remote',
    [string]$ApiUrl = '',
    [string]$DownloadDir = '',
    [string]$InstallerScript = '',
    [switch]$SkipAdminCheck,
    [switch]$SkipTls12,
    [switch]$NoExit,

    [switch]$SkipTailscale,
    [switch]$WithRustDesk,
    [switch]$Force,
    [switch]$Uninstall,
    [switch]$RemoveApps,
    [string]$RustDeskServer = '',
    [string]$RustDeskKey = '',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments = @()
)

$ErrorActionPreference = 'Stop'

function Test-VegaBootstrapAdmin {
    <#
      当前进程是否以管理员身份运行。非 Windows 返回 $false。
    #>
    [CmdletBinding()]
    param()

    if ($env:OS -ne 'Windows_NT') { return $false }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Resolve-VegaBootstrapRole {
    <#
      未指定 Role 时交互询问，只接受 1 / 2。
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('host', 'client', '')]
        [string]$Role = ''
    )

    if ($Role -eq 'host' -or $Role -eq 'client') { return $Role }

    Write-Host '请选择要安装的角色：' -ForegroundColor Cyan
    Write-Host '  1 = 被控主机（要被远程的电脑，安装 Sunshine + Tailscale）'
    Write-Host '  2 = 控制端（你操作的电脑，安装 Moonlight + Tailscale）'
    $answer = Read-Host '输入 1 或 2'
    switch ($answer.Trim()) {
        '1' { return 'host' }
        '2' { return 'client' }
        default { throw '没有选择有效角色（1=被控主机，2=控制端），已退出。' }
    }
}

function Get-VegaBootstrapRelease {
    <#
      查询 latest Release，返回 { Version, Tag, ZipUrl, ChecksumUrl, AssetName }。
      -ZipUrl 给定时只推导同目录的 SHA256SUMS.txt，不查询 API。
    #>
    [CmdletBinding()]
    param(
        [string]$Repo = 'shisanyue950901-beep/vega-remote',
        [string]$ApiUrl = '',
        [string]$ZipUrl = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($ZipUrl)) {
        $base = $ZipUrl.Substring(0, $ZipUrl.LastIndexOf('/') + 1)
        $assetName = $ZipUrl.Substring($ZipUrl.LastIndexOf('/') + 1)
        $version = $assetName
        if ($version -match '^vega-remote-(?<ver>.+)\.zip$') { $version = $Matches['ver'] }
        return [pscustomobject]@{
            Version     = $version
            Tag         = ''
            ZipUrl      = $ZipUrl
            ChecksumUrl = ($base + 'SHA256SUMS.txt')
            AssetName   = $assetName
        }
    }

    if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
        $ApiUrl = "https://api.github.com/repos/$Repo/releases/latest"
    }

    try {
        $release = Invoke-RestMethod -Uri $ApiUrl -Headers @{ 'User-Agent' = 'vega-remote-bootstrap' } -UseBasicParsing
    }
    catch {
        throw ("查询 GitHub 最新 Release 失败：{0}。可稍后重试，或用 -ZipUrl 指定镜像/本地可访问的 zip。" -f $_.Exception.Message)
    }

    if ($null -eq $release -or $null -eq $release.assets) {
        throw 'GitHub Release 返回为空，暂时无法确定下载地址；请稍后重试或用 -ZipUrl 指定 zip。'
    }

    $zipAsset = @($release.assets | Where-Object { [string]$_.name -match '^vega-remote-.+\.zip$' } | Select-Object -First 1)
    $sumAsset = @($release.assets | Where-Object { [string]$_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1)
    if ($zipAsset.Count -eq 0) {
        throw '最新 Release 里没有 vega-remote-<版本>.zip；请稍后重试或用 -ZipUrl 指定 zip。'
    }
    if ($sumAsset.Count -eq 0) {
        throw '最新 Release 里没有 SHA256SUMS.txt，无法校验下载内容；请稍后重试或用 -ZipUrl 指定版本。'
    }

    $tag = [string]$release.tag_name
    $version = $tag.TrimStart('v')
    if ([string]::IsNullOrWhiteSpace($version)) { $version = [string]$zipAsset[0].name }

    return [pscustomobject]@{
        Version     = $version
        Tag         = $tag
        ZipUrl      = [string]$zipAsset[0].browser_download_url
        ChecksumUrl = [string]$sumAsset[0].browser_download_url
        AssetName   = [string]$zipAsset[0].name
    }
}

function Save-VegaBootstrapFile {
    <#
      下载单个文件到本地，失败时附带镜像提示。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        Invoke-WebRequest -Uri $Uri -OutFile $Path -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw ("下载失败：{0}（{1}）。如果 GitHub 直连受限，可用 -ZipUrl 指定镜像地址，或先手动下载后解压运行安装脚本。" -f $Uri, $_.Exception.Message)
    }
}

function Test-VegaBootstrapChecksum {
    <#
      校验 zip 的 SHA256 是否与 SHA256SUMS.txt 中对应文件一致。
      不匹配或找不到条目都抛异常。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ArchivePath,

        [Parameter(Mandatory)]
        [string]$ChecksumPath
    )

    $leaf = Split-Path -Leaf $ArchivePath
    $expected = ''
    foreach ($line in @(Get-Content -LiteralPath $ChecksumPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^(?<hash>[0-9A-Fa-f]{64})\s+\*?(?<name>.+)$') {
            $name = $Matches['name'].Trim()
            if ([string]::Equals($name, $leaf, [StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals((Split-Path -Leaf $name), $leaf, [StringComparison]::OrdinalIgnoreCase)) {
                $expected = $Matches['hash'].ToLowerInvariant()
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($expected)) {
        throw "SHA256SUMS.txt 里没有 $leaf 的校验值，拒绝运行。"
    }

    $actual = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "SHA256 校验失败：期望 $expected，实际 $actual。下载可能被截断或被篡改，已停止。"
    }

    return $true
}

function Expand-VegaBootstrapArchive {
    <#
      解压并定位安装脚本；返回解压目录和可执行脚本路径。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ArchivePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [ValidateSet('host', 'client')]
        [string]$Role
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Recurse -Force
    }
    $null = New-Item -ItemType Directory -Path $DestinationPath -Force

    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationPath -Force -ErrorAction Stop

    $leaf = $(if ($Role -eq 'host') { 'install-host.ps1' } else { 'install-client.ps1' })
    $found = @(Get-ChildItem -LiteralPath $DestinationPath -Recurse -Filter $leaf -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match ('[\\/]' + [regex]::Escape($Role) + '[\\/]' + [regex]::Escape($leaf) + '$') } |
        Select-Object -First 1)
    if ($found.Count -eq 0) {
        $found = @(Get-ChildItem -LiteralPath $DestinationPath -Recurse -Filter $leaf -File -ErrorAction SilentlyContinue |
            Select-Object -First 1)
    }
    if ($found.Count -eq 0) {
        throw "解压后找不到 $Role/$leaf，压缩包可能不完整。"
    }

    return [pscustomobject]@{
        ExtractRoot = $DestinationPath
        Installer   = $found[0].FullName
    }
}

function Get-VegaBootstrapInstallerArgument {
    <#
      纯函数：把引导脚本收到的安装参数整理成安装脚本的参数表。
      密码永远不在其中：这里没有任何密码参数。
    #>
    [CmdletBinding()]
    param(
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$Force,
        [switch]$Uninstall,
        [switch]$RemoveApps,
        [string]$RustDeskServer = '',
        [string]$RustDeskKey = '',
        [string[]]$RemainingArguments = @()
    )

    $installerArgs = @{}
    if ($SkipTailscale) { $installerArgs['SkipTailscale'] = $true }
    if ($WithRustDesk) { $installerArgs['WithRustDesk'] = $true }
    if ($Force) { $installerArgs['Force'] = $true }
    if ($Uninstall) { $installerArgs['Uninstall'] = $true }
    if ($RemoveApps) { $installerArgs['RemoveApps'] = $true }
    if (-not [string]::IsNullOrWhiteSpace($RustDeskServer)) { $installerArgs['RustDeskServer'] = $RustDeskServer }
    if (-not [string]::IsNullOrWhiteSpace($RustDeskKey)) { $installerArgs['RustDeskKey'] = $RustDeskKey }

    foreach ($item in @($RemainingArguments)) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        if ($item -match '^-{1,2}(?<name>[A-Za-z][A-Za-z0-9]*)$') {
            $installerArgs[$Matches['name']] = $true
        }
    }

    return $installerArgs
}

function Invoke-VegaBootstrapInstaller {
    <#
      调用安装脚本并透传参数。安装脚本可能调用 exit，因此不做返回值包装。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Installer,

        [hashtable]$Arguments = @{}
    )

    if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {
        throw "找不到安装脚本：$Installer"
    }
    if (-not $PSCmdlet.ShouldProcess($Installer, '运行 Vega 安装脚本')) { return }

    & $Installer @Arguments
}

function Invoke-VegaBootstrap {
    <#
      主流程：检查管理员 -> TLS 1.2 -> 查询 Release -> 下载 -> 校验 -> 解压 -> 调用安装脚本。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('host', 'client', '')]
        [string]$Role = '',
        [string]$ZipUrl = '',
        [string]$Repo = 'shisanyue950901-beep/vega-remote',
        [string]$ApiUrl = '',
        [string]$DownloadDir = '',
        [string]$InstallerScript = '',
        [switch]$SkipAdminCheck,
        [switch]$SkipTls12,
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$Force,
        [switch]$Uninstall,
        [switch]$RemoveApps,
        [string]$RustDeskServer = '',
        [string]$RustDeskKey = '',
        [string[]]$RemainingArguments = @()
    )

    if (-not $SkipAdminCheck -and -not (Test-VegaBootstrapAdmin)) {
        throw '一键安装需要管理员 PowerShell：请在开始菜单搜索 PowerShell，右键“以管理员身份运行”，然后重新执行这条命令。'
    }

    if (-not $SkipTls12) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        catch {
            Write-Warning "设置 TLS 1.2 失败：$($_.Exception.Message)"
        }
    }

    $resolvedRole = Resolve-VegaBootstrapRole -Role $Role
    $installerArgs = Get-VegaBootstrapInstallerArgument -SkipTailscale:$SkipTailscale -WithRustDesk:$WithRustDesk `
        -Force:$Force -Uninstall:$Uninstall -RemoveApps:$RemoveApps `
        -RustDeskServer $RustDeskServer -RustDeskKey $RustDeskKey `
        -RemainingArguments $RemainingArguments

    if (-not [string]::IsNullOrWhiteSpace($InstallerScript)) {
        $resolved = [pscustomobject]@{ Installer = $InstallerScript; ExtractRoot = (Split-Path -Parent $InstallerScript) }
    }
    else {
        $release = Get-VegaBootstrapRelease -Repo $Repo -ApiUrl $ApiUrl -ZipUrl $ZipUrl
        if ([string]::IsNullOrWhiteSpace($DownloadDir)) {
            $DownloadDir = Join-Path $env:TEMP 'vega-remote-bootstrap'
        }
        $downloadRoot = Join-Path $DownloadDir $release.Version
        $null = New-Item -ItemType Directory -Path $downloadRoot -Force

        $archivePath = Join-Path $downloadRoot $release.AssetName
        $checksumPath = Join-Path $downloadRoot 'SHA256SUMS.txt'

        Write-Host ("下载 {0} ..." -f $release.ZipUrl) -ForegroundColor Cyan
        Save-VegaBootstrapFile -Uri $release.ZipUrl -Path $archivePath
        Save-VegaBootstrapFile -Uri $release.ChecksumUrl -Path $checksumPath
        $null = Test-VegaBootstrapChecksum -ArchivePath $archivePath -ChecksumPath $checksumPath
        Write-Host 'SHA256 校验通过' -ForegroundColor Green

        $extractRoot = Join-Path $downloadRoot 'extract'
        $resolved = Expand-VegaBootstrapArchive -ArchivePath $archivePath -DestinationPath $extractRoot -Role $resolvedRole
    }

    Write-Host ("运行 {0}（角色：{1}）" -f $resolved.Installer, $resolvedRole) -ForegroundColor Cyan
    Invoke-VegaBootstrapInstaller -Installer $resolved.Installer -Arguments $installerArgs -Confirm:$false
}

# 点源（测试）时只加载函数，不执行主流程。
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-VegaBootstrap -Role $Role -ZipUrl $ZipUrl -Repo $Repo -ApiUrl $ApiUrl -DownloadDir $DownloadDir `
            -InstallerScript $InstallerScript -SkipAdminCheck:$SkipAdminCheck -SkipTls12:$SkipTls12 `
            -SkipTailscale:$SkipTailscale -WithRustDesk:$WithRustDesk -Force:$Force -Uninstall:$Uninstall `
            -RemoveApps:$RemoveApps -RustDeskServer $RustDeskServer -RustDeskKey $RustDeskKey `
            -RemainingArguments $RemainingArguments -Confirm:$false
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        if (-not $NoExit) { exit 1 }
        throw
    }
}
