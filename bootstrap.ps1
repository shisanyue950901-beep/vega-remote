#Requires -Version 5.1
<#
.SYNOPSIS
  Vega Remote 一行安装引导脚本。

.DESCRIPTION
  下载 GitHub 最新 Release 的 vega-remote-<版本>.zip，先对下载到的字节算 SHA256，
  校验通过后把同一份字节写进受保护的临时工作目录（%ProgramData%\Vega\bootstrap\<GUID>），
  从该文件解压、从该目录执行安装脚本，结束后删除工作目录。
  工作目录创建后立即收紧 ACL：禁用继承，仅 Administrators 与 SYSTEM 完全控制；
  父目录或工作目录本身是重解析点时中止。

  只接受 https 的 -ZipUrl；镜像同时控制 zip 与校验文件，因此只使用可信镜像。
  需要管理员 PowerShell（被控端要装服务、改防火墙）。
  不接收、不保存任何密码；RustDesk 固定密码请装完后在 RustDesk 界面自行设置。

  用法（默认读取 latest Release）：
    irm https://raw.githubusercontent.com/shisanyue950901-beep/vega-remote/main/bootstrap.ps1 | iex
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/shisanyue950901-beep/vega-remote/main/bootstrap.ps1))) -Role host -RustDeskServer relay.example.com -RustDeskKey KEY

  下载失败时可指定可信镜像的 zip：
    ... -Role host -ZipUrl https://mirror.example.com/vega-remote-0.2.0.zip
  也可以自己从 GitHub Release 页面取得摘要后校验（优先于镜像同源的 SHA256SUMS.txt）：
    ... -Role host -ZipUrl https://mirror.example.com/vega-remote-0.2.0.zip -Sha256 <64位十六进制>

.PARAMETER Role
  host = 被控主机，client = 控制端。不提供时交互询问。

.PARAMETER ZipUrl
  直接指定 zip 下载地址。只接受 https；SHA256SUMS.txt 从同一目录获取。

.PARAMETER Sha256
  可选的 SHA256 摘要（64 位十六进制）。由用户从 GitHub Release 页面独立取得；
  给出时优先于 -ZipUrl 同源的 SHA256SUMS.txt。

.PARAMETER Repo
  GitHub 仓库，默认 shisanyue950901-beep/vega-remote。

.PARAMETER ApiUrl
  覆盖 Release API 地址（测试或镜像用）。

.PARAMETER WorkRoot
  受保护工作目录的根，默认 %ProgramData%\Vega\bootstrap。

.PARAMETER InstallerScript
  跳过下载解压，直接调用指定的安装脚本（离线或测试用）。

.PARAMETER SkipAdminCheck
  跳过管理员检查（仅测试或受限环境用）。

.PARAMETER SkipTailscale
  透传给安装脚本：不安装 Tailscale。

.PARAMETER WithRustDesk
  透传给安装脚本：额外安装 RustDesk。

.PARAMETER Force
  透传给安装脚本：强制重装组件。

.PARAMETER Uninstall
  透传给安装脚本：卸载模式。

.PARAMETER RemoveApps
  透传给安装脚本：卸载清单里由 Vega 安装的组件。

.PARAMETER RustDeskServer
  透传给安装脚本的 RustDesk 中继地址。

.PARAMETER RustDeskKey
  透传给安装脚本的 RustDesk 中继公钥。
#>
[CmdletBinding()]
param(
    [ValidateSet('host', 'client', '')]
    [string]$Role = '',

    [string]$ZipUrl = '',
    [string]$Sha256 = '',
    [string]$Repo = 'shisanyue950901-beep/vega-remote',
    [string]$ApiUrl = '',
    [string]$WorkRoot = '',
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
    [string]$RustDeskKey = ''
)

$ErrorActionPreference = 'Stop'

function Test-VegaBootstrapWindows {
    <#
      是否运行在 Windows 上。非 Windows 只用于本地跑 Pester，没有 ACL。
    #>
    [CmdletBinding()]
    param()

    return ($env:OS -eq 'Windows_NT')
}

function Test-VegaBootstrapAdmin {
    <#
      当前进程是否以管理员身份运行。非 Windows 返回 $false。
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-VegaBootstrapWindows)) { return $false }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Hide-VegaBootstrapUri {
    <#
      日志/错误里显示 URL 前去掉 userinfo 与查询参数（可能带凭据或 token）。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Uri = ''
    )

    if ([string]::IsNullOrWhiteSpace($Uri)) { return '' }
    try {
        $builder = New-Object System.UriBuilder($Uri)
        $builder.UserName = ''
        $builder.Password = ''
        $builder.Query = ''
        $builder.Fragment = ''
        return $builder.Uri.AbsoluteUri
    }
    catch {
        return '(URL 无法解析)'
    }
}

function Test-VegaBootstrapSecureUrl {
    <#
      纯函数：-ZipUrl 只接受 https（拒绝 http 及其他协议）。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Uri = ''
    )

    if ([string]::IsNullOrWhiteSpace($Uri)) { return $false }
    if ($Uri -match '\s') { return $false }
    return [bool]($Uri -match '^https://[^/\s]+')
}

function Test-VegaBootstrapReparsePoint {
    <#
      路径是否重解析点/符号链接。取不到元数据时按可疑处理。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        return $true
    }
    if ($null -eq $item) { return $true }
    if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $true }
    if ($null -ne $item.PSObject.Properties['LinkType'] -and -not [string]::IsNullOrEmpty([string]$item.LinkType)) { return $true }
    return $false
}

function Set-VegaBootstrapDirectoryAcl {
    <#
      禁用继承，只留 Administrators 与 SYSTEM 完全控制，所有者设为 Administrators。
      任何一步失败都抛异常（调用方据此中止）。非 Windows 直接返回。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-VegaBootstrapWindows)) { return }
    if (-not $PSCmdlet.ShouldProcess($Path, '收紧工作目录 ACL 为 Administrators/SYSTEM 专用')) { return }

    try {
        $administrators = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')

        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRule($rule) }
        foreach ($sid in @($system, $administrators)) {
            $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
            $null = $acl.AddAccessRule($accessRule)
        }
        $acl.SetOwner($administrators)
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    }
    catch {
        throw "无法为工作目录设置 Administrators/SYSTEM 专用 ACL：$Path（$($_.Exception.Message)）"
    }
}

function Get-VegaBootstrapSid {
    <#
      把 ACL 里的 IdentityReference 转成 SID 字符串；取不到返回空串（按可疑处理）。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        $IdentityReference
    )

    if ($null -eq $IdentityReference) { return '' }
    if ($IdentityReference -is [System.Security.Principal.SecurityIdentifier]) { return $IdentityReference.Value }

    $text = [string]$IdentityReference
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    if ($text -match '^S-1-') { return $text }

    try {
        $account = New-Object System.Security.Principal.NTAccount($text)
        return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return ''
    }
}

function Test-VegaBootstrapWriteRights {
    <#
      纯函数：判断一组文件系统权限里是否含写/删除/改权限/取得所有权等写类权限。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Rights
    )

    # Write(278) Delete(65536) ChangePermissions(262144) TakeOwnership(524288)
    # FullControl(2032127) WriteData(2) AppendData(4) WriteExtendedAttributes(16)
    # WriteAttributes(256) DeleteSubdirectoriesAndFiles(64)
    $writeMask = 2 -bor 4 -bor 16 -bor 64 -bor 256 -bor 278 -bor 65536 -bor 262144 -bor 524288 -bor 2032127
    return ((([int]$Rights) -band $writeMask) -ne 0)
}

function Test-VegaBootstrapDirectoryAclTrusted {
    <#
      目录是否满足：不是重解析点、所有者是 SYSTEM 或 Administrators、
      没有任何非管理员 SID 持有写类权限。非 Windows 只用于跑 Pester，直接返回 $true。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-VegaBootstrapWindows)) { return $true }
    if (Test-VegaBootstrapReparsePoint -Path $Path) { return $false }

    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        return $false
    }
    if ($null -eq $acl) { return $false }

    $allowedOwnerSids = @('S-1-5-32-544', 'S-1-5-18')
    $ownerSid = Get-VegaBootstrapSid -IdentityReference $acl.Owner
    if ($allowedOwnerSids -notcontains $ownerSid) { return $false }

    foreach ($rule in @($acl.Access)) {
        if ($null -eq $rule) { continue }
        if ([string]$rule.AccessControlType -ne 'Allow') { continue }

        $sid = Get-VegaBootstrapSid -IdentityReference $rule.IdentityReference
        if ($allowedOwnerSids -contains $sid) { continue }
        if (Test-VegaBootstrapWriteRights -Rights $rule.FileSystemRights) { return $false }
    }

    return $true
}

function New-VegaBootstrapProtectedDirectory {
    <#
      创建目录时就用 DirectorySecurity 应用 ACL：禁用继承，只留 SYSTEM 与
      Administrators 完全控制，所有者设为 Administrators。已存在则拒绝。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) { throw "目录已存在，拒绝覆盖：$Path" }

    if (-not (Test-VegaBootstrapWindows)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
        return $Path
    }

    try {
        $administrators = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')

        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($system, $administrators)) {
            $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
            $security.AddAccessRule($accessRule)
        }
        $security.SetOwner($administrators)

        $null = [System.IO.Directory]::CreateDirectory($Path, $security)
    }
    catch {
        throw "创建受保护目录失败：$Path（$($_.Exception.Message)）"
    }

    if (Test-VegaBootstrapReparsePoint -Path $Path) { throw "新建目录是重解析点，拒绝使用：$Path" }
    return $Path
}

function Initialize-VegaBootstrapProtectedRoot {
    <#
      建立或复用受保护目录：父目录不得是重解析点；
      新建时在 CreateDirectory 阶段应用 ACL；已存在时必须通过 ACL 可信校验，
      否则中止并提示用户以管理员身份删除或修复后重试。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path -LiteralPath $parent)) {
        if (Test-VegaBootstrapReparsePoint -Path $parent) { throw "受保护目录的父目录是重解析点，拒绝使用：$parent" }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return (New-VegaBootstrapProtectedDirectory -Path $Path)
    }

    if (Test-VegaBootstrapReparsePoint -Path $Path) {
        throw "目录是重解析点，拒绝使用：$Path。请以管理员身份删除或修复该目录后重试。"
    }
    if (-not (Test-VegaBootstrapDirectoryAclTrusted -Path $Path)) {
        throw ((("目录的权限不安全（所有者不是 SYSTEM/Administrators，或存在非管理员可写/可删除的权限）：{0}。" -f $Path)) +
            '请以管理员身份删除或修复该目录后重试。')
    }

    return $Path
}

function Initialize-VegaBootstrapVegaRoot {
    <#
      默认工作根 %ProgramData%\Vega：先确认 %ProgramData% 不是重解析点，
      再按受保护目录规则创建或校验 Vega 目录。
    #>
    [CmdletBinding()]
    param()

    $programData = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($programData)) {
        throw '环境变量 %ProgramData% 为空，无法建立受保护的引导工作目录。'
    }
    if (Test-Path -LiteralPath $programData) {
        if (Test-VegaBootstrapReparsePoint -Path $programData) {
            throw "%ProgramData% 是重解析点，拒绝使用：$programData"
        }
    }

    $vegaRoot = Join-Path $programData 'Vega'
    return (Initialize-VegaBootstrapProtectedRoot -Path $vegaRoot)
}

function Initialize-VegaBootstrapDirectory {
    <#
      建立（或复用）一个目录并收紧 ACL。
      父目录与目标目录都不得是重解析点；已存在的目录必须通过 ACL 可信校验。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path -LiteralPath $parent)) {
        if (Test-VegaBootstrapReparsePoint -Path $parent) { throw "工作目录的父目录是重解析点，拒绝使用：$parent" }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-VegaBootstrapProtectedDirectory -Path $Path
    }
    else {
        if (Test-VegaBootstrapReparsePoint -Path $Path) { throw "工作目录是重解析点，拒绝使用：$Path" }
        Set-VegaBootstrapDirectoryAcl -Path $Path
    }

    return $Path
}

function Get-VegaBootstrapWorkRoot {
    <#
      受保护工作目录的根：默认 %ProgramData%\Vega\bootstrap。
      默认根建立在已验证的 %ProgramData%\Vega 下；自定义根同样要求父目录可信。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Root = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Root)) { return $Root }

    $vegaRoot = Initialize-VegaBootstrapVegaRoot
    return (Join-Path $vegaRoot 'bootstrap')
}

function New-VegaBootstrapWorkDirectory {
    <#
      在工作根下建一个带新 GUID 的工作目录，创建时即应用 ACL；
      父目录与工作目录都不得是重解析点。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowEmptyString()]
        [string]$Root = ''
    )

    $rootPath = Get-VegaBootstrapWorkRoot -Root $Root
    $null = Initialize-VegaBootstrapDirectory -Path $rootPath

    $workDirectory = Join-Path $rootPath ([guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $workDirectory) { throw "工作目录已存在，拒绝复用：$workDirectory" }

    if (-not $PSCmdlet.ShouldProcess($workDirectory, '创建受保护的引导工作目录')) { return '' }

    $null = New-VegaBootstrapProtectedDirectory -Path $workDirectory
    return $workDirectory
}

function Remove-VegaBootstrapWorkDirectory {
    <#
      删除工作目录（结束清理）。删不掉只警告，不影响已完成的安装。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowEmptyString()]
        [string]$Path = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-VegaBootstrapReparsePoint -Path $Path) {
        Write-Warning "工作目录是重解析点，跳过清理，请手动检查：$Path"
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Path, '删除引导工作目录')) { return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "清理工作目录失败，请手动删除：$Path（$($_.Exception.Message)）"
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

function Get-VegaBootstrapAssetName {
    <#
      从 URL 的 AbsolutePath 末段取资产文件名（查询串不参与），URL 解码后只允许
      [A-Za-z0-9._-]。错误信息只显示脱敏后的 URL。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $shown = Hide-VegaBootstrapUri -Uri $Uri
    try {
        $parsed = [System.Uri]$Uri
    }
    catch {
        throw "下载地址无效：$shown"
    }

    $path = $parsed.AbsolutePath
    $leaf = $path.Substring($path.LastIndexOf('/') + 1)
    try {
        $leaf = [System.Uri]::UnescapeDataString($leaf)
    }
    catch {
        throw "下载地址里的资产文件名无法解码：$shown"
    }

    if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -notmatch '^[A-Za-z0-9._-]+$') {
        throw "下载地址里的资产文件名无效（只允许字母、数字、点、下划线和连字符）：$shown"
    }
    return $leaf
}

function Get-VegaBootstrapAssetBaseUri {
    <#
      取 URL 的目录部分（保留 scheme/host/port，去掉文件名、查询串与片段），
      用于推导同目录的 SHA256SUMS.txt。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $shown = Hide-VegaBootstrapUri -Uri $Uri
    try {
        $parsed = [System.Uri]$Uri
        $path = $parsed.AbsolutePath
        $basePath = $path.Substring(0, $path.LastIndexOf('/') + 1)
        $builder = New-Object System.UriBuilder($parsed)
        $builder.Path = $basePath
        $builder.Query = ''
        $builder.Fragment = ''
        return $builder.Uri.AbsoluteUri
    }
    catch {
        throw "下载地址无效：$shown"
    }
}

function Get-VegaBootstrapRelease {
    <#
      查询 latest Release，返回 { Version, Tag, ZipUrl, ChecksumUrl, AssetName }。
      -ZipUrl 给定时只推导同目录的 SHA256SUMS.txt，不查询 API。
      资产名一律从 Uri 的 AbsolutePath 末段提取，带令牌的查询串不进入文件名与错误信息。
    #>
    [CmdletBinding()]
    param(
        [string]$Repo = 'shisanyue950901-beep/vega-remote',
        [string]$ApiUrl = '',
        [string]$ZipUrl = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($ZipUrl)) {
        $assetName = Get-VegaBootstrapAssetName -Uri $ZipUrl
        $base = Get-VegaBootstrapAssetBaseUri -Uri $ZipUrl
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
        throw ("查询 GitHub 最新 Release 失败：{0}。可稍后重试，或用 -ZipUrl 指定可信镜像的 zip。" -f $_.Exception.Message)
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

    $zipUrl = [string]$zipAsset[0].browser_download_url
    $assetName = Get-VegaBootstrapAssetName -Uri $zipUrl

    return [pscustomobject]@{
        Version     = $version
        Tag         = $tag
        ZipUrl      = $zipUrl
        ChecksumUrl = [string]$sumAsset[0].browser_download_url
        AssetName   = $assetName
    }
}

function Get-VegaBootstrapByteArray {
    <#
      下载到内存字节数组（不落盘）。手动跟随重定向，并检查最终响应 URI 仍是 https；
      失败时附带镜像提示，URL 去掉 userinfo 与查询参数。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $shown = Hide-VegaBootstrapUri -Uri $Uri
    $client = $null
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        $handler.MaxAutomaticRedirections = 5

        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(60)

        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw ("HTTP {0}" -f [int]$response.StatusCode)
        }

        $finalUri = ''
        if ($null -ne $response.RequestMessage -and $null -ne $response.RequestMessage.RequestUri) {
            $finalUri = $response.RequestMessage.RequestUri.AbsoluteUri
        }
        if (-not (Test-VegaBootstrapSecureUrl -Uri $finalUri)) {
            throw "下载被重定向到非 https 地址：$(Hide-VegaBootstrapUri -Uri $finalUri)"
        }

        return , $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    }
    catch {
        throw ("下载失败：{0}（{1}）。只使用可信镜像，镜像同时控制 zip 和校验文件；也可先手动下载后解压运行安装脚本。" -f $shown, $_.Exception.Message)
    }
    finally {
        if ($null -ne $client) { $client.Dispose() }
    }
}

function Get-VegaBootstrapText {
    <#
      下载文本（校验文件）。失败时附带镜像提示，URL 去掉 userinfo 与查询参数。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $bytes = Get-VegaBootstrapByteArray -Uri $Uri
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-VegaBootstrapSha256 {
    <#
      纯函数：对字节数组算 SHA256，返回小写十六进制。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Test-VegaBootstrapChecksum {
    <#
      纯函数：校验下载字节的 SHA256。
      给出 -ExpectedHash 时只用它（用户从 GitHub Release 页面独立取得，优先于同源校验文件）；
      否则从 SHA256SUMS.txt 文本里找 -AssetName 对应条目。
      摘要格式非法、找不到条目、不匹配都抛异常。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes,

        [AllowEmptyString()]
        [string]$ChecksumText = '',

        [AllowEmptyString()]
        [string]$ExpectedHash = '',

        [AllowEmptyString()]
        [string]$AssetName = ''
    )

    $expected = ''
    if (-not [string]::IsNullOrWhiteSpace($ExpectedHash)) {
        $expected = $ExpectedHash.Trim()
        if ($expected -notmatch '^[0-9A-Fa-f]{64}$') {
            throw 'SHA256 摘要格式无效：应为 64 位十六进制（可从 GitHub Release 页面的 SHA256SUMS.txt 复制）。'
        }
        $expected = $expected.ToLowerInvariant()
    }
    else {
        if ([string]::IsNullOrWhiteSpace($AssetName)) {
            throw '校验下载内容需要 -Sha256 摘要，或提供校验文件与文件名。'
        }
        foreach ($line in @($ChecksumText -split "\r?\n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^(?<hash>[0-9A-Fa-f]{64})\s+\*?(?<name>.+)$') {
                $name = $Matches['name'].Trim()
                if ([string]::Equals($name, $AssetName, [StringComparison]::OrdinalIgnoreCase) -or
                    [string]::Equals((Split-Path -Leaf $name), $AssetName, [StringComparison]::OrdinalIgnoreCase)) {
                    $expected = $Matches['hash'].ToLowerInvariant()
                    break
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($expected)) {
            throw "SHA256SUMS.txt 里没有 $AssetName 的校验值，拒绝运行。"
        }
    }

    $actual = Get-VegaBootstrapSha256 -Bytes $Bytes
    if ($actual -ne $expected) {
        throw "SHA256 校验失败：期望 $expected，实际 $actual。下载可能被截断或被篡改，已停止。"
    }

    return $true
}

function Write-VegaBootstrapFile {
    <#
      把内存字节写入受保护目录（先确认父目录不是重解析点）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $parent = Split-Path -Path $Path -Parent
    if (Test-VegaBootstrapReparsePoint -Path $parent) { throw "写入目录是重解析点，拒绝写入：$parent" }
    if (-not (Test-VegaBootstrapDirectoryAclTrusted -Path $parent)) {
        throw "写入目录的权限不安全（存在非管理员可写权限），拒绝写入：$parent"
    }

    try {
        [System.IO.File]::WriteAllBytes($Path, $Bytes)
    }
    catch {
        throw "写入受保护目录失败：$Path（$($_.Exception.Message)）"
    }

    if (Test-VegaBootstrapReparsePoint -Path $Path) { throw "写入的文件是重解析点，拒绝使用：$Path" }
    return $Path
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
    if (Test-VegaBootstrapReparsePoint -Path $DestinationPath) {
        throw "解压目录是重解析点，拒绝使用：$DestinationPath"
    }

    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationPath -Force -ErrorAction Stop

    # 解压后再检查子目录：压缩包里的目录联接/符号链接不能被当作可信内容执行。
    $reparseItems = @(Get-ChildItem -LiteralPath $DestinationPath -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { [bool]($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })
    if ($reparseItems.Count -gt 0) {
        throw "解压目录里包含重解析点，拒绝使用：$($reparseItems[0].FullName)"
    }

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
      纯函数：把引导脚本收到的安装参数整理成安装脚本的参数表（splat 用）。
      只包含明确的类型化参数；未知参数由 PowerShell 自己报错。
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
        [string]$RustDeskKey = ''
    )

    $installerArgs = @{}
    if ($SkipTailscale) { $installerArgs['SkipTailscale'] = $true }
    if ($WithRustDesk) { $installerArgs['WithRustDesk'] = $true }
    if ($Force) { $installerArgs['Force'] = $true }
    if ($Uninstall) { $installerArgs['Uninstall'] = $true }
    if ($RemoveApps) { $installerArgs['RemoveApps'] = $true }
    if (-not [string]::IsNullOrWhiteSpace($RustDeskServer)) { $installerArgs['RustDeskServer'] = $RustDeskServer }
    if (-not [string]::IsNullOrWhiteSpace($RustDeskKey)) { $installerArgs['RustDeskKey'] = $RustDeskKey }

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
      主流程：检查管理员 -> TLS 1.2 -> 查询 Release -> 下载到内存 -> 校验
      -> 写入受保护目录 -> 从该文件解压 -> 从受保护目录执行 -> 删除工作目录。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('host', 'client', '')]
        [string]$Role = '',
        [string]$ZipUrl = '',
        [string]$Sha256 = '',
        [string]$Repo = 'shisanyue950901-beep/vega-remote',
        [string]$ApiUrl = '',
        [string]$WorkRoot = '',
        [string]$InstallerScript = '',
        [switch]$SkipAdminCheck,
        [switch]$SkipTls12,
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$Force,
        [switch]$Uninstall,
        [switch]$RemoveApps,
        [string]$RustDeskServer = '',
        [string]$RustDeskKey = ''
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

    if (-not [string]::IsNullOrWhiteSpace($ZipUrl) -and -not (Test-VegaBootstrapSecureUrl -Uri $ZipUrl)) {
        throw '服务器地址格式无效：-ZipUrl 只接受 https 链接。只使用可信镜像，镜像同时控制 zip 和校验文件。'
    }

    # 显式传入空白 -Sha256 是调用错误：不能悄悄退回同源校验文件。
    if ($PSBoundParameters.ContainsKey('Sha256') -and [string]::IsNullOrWhiteSpace($Sha256)) {
        throw '-Sha256 不能为空：请提供 64 位十六进制摘要，或不传 -Sha256 使用 SHA256SUMS.txt。'
    }
    if (-not [string]::IsNullOrWhiteSpace($ApiUrl) -and -not (Test-VegaBootstrapSecureUrl -Uri $ApiUrl)) {
        throw '服务器地址格式无效：-ApiUrl 只接受 https 链接。'
    }

    $resolvedRole = Resolve-VegaBootstrapRole -Role $Role
    $installerArgs = Get-VegaBootstrapInstallerArgument -SkipTailscale:$SkipTailscale -WithRustDesk:$WithRustDesk `
        -Force:$Force -Uninstall:$Uninstall -RemoveApps:$RemoveApps `
        -RustDeskServer $RustDeskServer -RustDeskKey $RustDeskKey

    if (-not [string]::IsNullOrWhiteSpace($InstallerScript)) {
        Write-Host ("运行 {0}（角色：{1}）" -f $InstallerScript, $resolvedRole) -ForegroundColor Cyan
        Invoke-VegaBootstrapInstaller -Installer $InstallerScript -Arguments $installerArgs -Confirm:$false
        return
    }

    $release = Get-VegaBootstrapRelease -Repo $Repo -ApiUrl $ApiUrl -ZipUrl $ZipUrl
    if (-not (Test-VegaBootstrapSecureUrl -Uri $release.ZipUrl)) {
        throw '服务器地址格式无效：Release 里的 zip 下载地址不是 https，拒绝下载。'
    }

    $workDirectory = New-VegaBootstrapWorkDirectory -Root $WorkRoot
    try {
        $archiveName = Split-Path -Leaf ([string]$release.AssetName)
        if ([string]::IsNullOrWhiteSpace($archiveName) -or $archiveName -ne [string]$release.AssetName) {
            throw "Release 资产名无效：$($release.AssetName)"
        }

        Write-Host ("下载 {0} ..." -f (Hide-VegaBootstrapUri -Uri $release.ZipUrl)) -ForegroundColor Cyan
        $zipBytes = Get-VegaBootstrapByteArray -Uri $release.ZipUrl

        if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
            $null = Test-VegaBootstrapChecksum -Bytes $zipBytes -ExpectedHash $Sha256
            Write-Host 'SHA256 校验通过（使用 -Sha256，来源为 GitHub Release 页面）' -ForegroundColor Green
        }
        else {
            if (-not (Test-VegaBootstrapSecureUrl -Uri $release.ChecksumUrl)) {
                throw '服务器地址格式无效：校验文件地址不是 https，拒绝下载。'
            }
            $checksumText = Get-VegaBootstrapText -Uri $release.ChecksumUrl
            $null = Test-VegaBootstrapChecksum -Bytes $zipBytes -ChecksumText $checksumText -AssetName $archiveName
            Write-Host 'SHA256 校验通过' -ForegroundColor Green
        }

        # 校验通过后写的是同一份字节，不是重新下载的文件。
        $archivePath = Join-Path $workDirectory $archiveName
        $null = Write-VegaBootstrapFile -Path $archivePath -Bytes $zipBytes

        $extractRoot = Join-Path $workDirectory 'extract'
        $resolved = Expand-VegaBootstrapArchive -ArchivePath $archivePath -DestinationPath $extractRoot -Role $resolvedRole

        Write-Host ("运行 {0}（角色：{1}）" -f $resolved.Installer, $resolvedRole) -ForegroundColor Cyan
        Invoke-VegaBootstrapInstaller -Installer $resolved.Installer -Arguments $installerArgs -Confirm:$false
    }
    finally {
        Remove-VegaBootstrapWorkDirectory -Path $workDirectory
    }
}

# 点源（测试）时只加载函数，不执行主流程。
if ($MyInvocation.InvocationName -ne '.') {
    try {
        # 只透传用户实际给出的参数：否则空的 -Sha256 会被当成“显式传入空白”。
        $bootstrapArgs = @{ Role = $Role; Repo = $Repo }
        if ($PSBoundParameters.ContainsKey('ZipUrl') -and -not [string]::IsNullOrWhiteSpace($ZipUrl)) { $bootstrapArgs['ZipUrl'] = $ZipUrl }
        if ($PSBoundParameters.ContainsKey('Sha256')) { $bootstrapArgs['Sha256'] = $Sha256 }
        if ($PSBoundParameters.ContainsKey('ApiUrl') -and -not [string]::IsNullOrWhiteSpace($ApiUrl)) { $bootstrapArgs['ApiUrl'] = $ApiUrl }
        if ($PSBoundParameters.ContainsKey('WorkRoot') -and -not [string]::IsNullOrWhiteSpace($WorkRoot)) { $bootstrapArgs['WorkRoot'] = $WorkRoot }
        if ($PSBoundParameters.ContainsKey('InstallerScript') -and -not [string]::IsNullOrWhiteSpace($InstallerScript)) { $bootstrapArgs['InstallerScript'] = $InstallerScript }
        if ($SkipAdminCheck) { $bootstrapArgs['SkipAdminCheck'] = $true }
        if ($SkipTls12) { $bootstrapArgs['SkipTls12'] = $true }
        if ($SkipTailscale) { $bootstrapArgs['SkipTailscale'] = $true }
        if ($WithRustDesk) { $bootstrapArgs['WithRustDesk'] = $true }
        if ($Force) { $bootstrapArgs['Force'] = $true }
        if ($Uninstall) { $bootstrapArgs['Uninstall'] = $true }
        if ($RemoveApps) { $bootstrapArgs['RemoveApps'] = $true }
        if (-not [string]::IsNullOrWhiteSpace($RustDeskServer)) { $bootstrapArgs['RustDeskServer'] = $RustDeskServer }
        if (-not [string]::IsNullOrWhiteSpace($RustDeskKey)) { $bootstrapArgs['RustDeskKey'] = $RustDeskKey }

        Invoke-VegaBootstrap @bootstrapArgs -Confirm:$false
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        if (-not $NoExit) { exit 1 }
        throw
    }
}
