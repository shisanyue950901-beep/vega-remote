<#
  Vega Remote - 共享函数库（被控端脚本 / 主控端脚本 / vega-doctor 共用）

  设计约定：
  - 所有函数兼容 Windows PowerShell 5.1 与 PowerShell 7。
  - 纯判断逻辑（显卡选择、编码器映射、Tailscale ping 解析、配置合并、
    诊断结论）不访问系统，便于 Pester 直接测试。
  - 访问系统的函数（winget、防火墙、服务、进程）都通过薄封装
    Invoke-VegaCommand / Invoke-VegaWinget，测试里用 Mock 替换即可，
    不会真的调用 winget 或任何系统命令。
  - 管理员权限下启动的外部程序一律使用绝对路径，不依赖 PATH 搜索。
  - 安装动作写进状态清单（%ProgramData%\Vega\state.json），卸载只按清单回滚。
  - 不在这里做任何“加载即执行”的动作，模块可安全反复导入。
#>

# ---------------------------------------------------------------------------
# 通用：进程调用与参数转义
# ---------------------------------------------------------------------------

function ConvertTo-VegaArgumentString {
    <#
      把参数数组拼成 Windows 命令行字符串。
      ProcessStartInfo.ArgumentList 只有 .NET Core 才有，PS 5.1 必须自己拼。
      规则与 CommandLineToArgvW 一致：含空格或引号的参数加双引号，
      参数内的反斜杠与引号按 2n+1 / 2n 规则转义。
      空字符串（以及 $null）转成 ""，避免原生参数往返时丢参数。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList
    )

    if ($null -eq $ArgumentList) { return '' }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($argument in $ArgumentList) {
        if ($null -eq $argument) {
            $parts.Add('""')
            continue
        }
        if ($argument.Length -eq 0) {
            $parts.Add('""')
            continue
        }
        if ($argument -notmatch '[\s"]') {
            $parts.Add($argument)
            continue
        }

        $builder = New-Object System.Text.StringBuilder
        $null = $builder.Append('"')
        $backslashes = 0
        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq '\') {
                $backslashes++
                continue
            }
            if ($character -eq '"') {
                $null = $builder.Append(('\' * (($backslashes * 2) + 1)))
                $null = $builder.Append('"')
                $backslashes = 0
                continue
            }
            if ($backslashes -gt 0) {
                $null = $builder.Append(('\' * $backslashes))
                $backslashes = 0
            }
            $null = $builder.Append($character)
        }
        if ($backslashes -gt 0) {
            $null = $builder.Append(('\' * ($backslashes * 2)))
        }
        $null = $builder.Append('"')
        $parts.Add($builder.ToString())
    }

    return ($parts -join ' ')
}

function Test-VegaAbsolutePath {
    <#
      判断路径是否是绝对路径（管理员子进程只接受绝对路径）。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    # 目标机器是 Windows：盘符路径与 UNC 路径在任何宿主平台（含 Linux 上的 pwsh 测试）
    # 都按绝对路径处理，不能只依赖当前平台的 IsPathRooted。
    if ($Path -match '^[A-Za-z]:[\\/]') { return $true }
    if ($Path -match '^\\\\[^\\]') { return $true }
    if ($Path -match '^[\\/]') { return $true }

    try {
        return [System.IO.Path]::IsPathRooted($Path)
    }
    catch {
        return $false
    }
}

function Invoke-VegaCommand {
    <#
      运行一个外部程序并收集输出（不经过 shell，不解析管道）。
      返回 { FilePath, ExitCode, Output, StdOut, StdErr, TimedOut }。
      超时会尝试 Kill 进程；杀不掉或读不到退出码时 ExitCode 保持 -1，不抛异常。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @(),

        [int]$TimeoutSeconds = 120
    )

    $result = [pscustomobject]@{
        FilePath = $FilePath
        ExitCode = -1
        Output   = @()
        StdOut   = @()
        StdErr   = @()
        TimedOut = $false
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = ConvertTo-VegaArgumentString -ArgumentList $ArgumentList
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        $null = $process.Start()
    }
    catch {
        $message = "无法启动 ${FilePath}：$($_.Exception.Message)"
        $result.StdErr = @($message)
        $result.Output = @($message)
        $process.Dispose()
        return $result
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $exited = $process.WaitForExit($TimeoutSeconds * 1000)
    if ($exited) {
        try { $result.ExitCode = $process.ExitCode } catch { $result.ExitCode = -1 }
    }
    else {
        $result.TimedOut = $true
        try {
            if (-not $process.HasExited) { $process.Kill() }
        }
        catch {
            $null = $_
        }
        $null = $process.WaitForExit(5000)
        # 只有确认退出后才读 ExitCode；没退出就保持 -1，避免抛异常
        try {
            if ($process.HasExited) { $result.ExitCode = $process.ExitCode }
        }
        catch {
            $result.ExitCode = -1
        }
    }

    $null = $stdoutTask.Wait(5000)
    $null = $stderrTask.Wait(5000)

    $stdoutText = ''
    $stderrText = ''
    if ($stdoutTask.IsCompleted) { $stdoutText = $stdoutTask.Result }
    if ($stderrTask.IsCompleted) { $stderrText = $stderrTask.Result }

    $result.StdOut = @($stdoutText -split "\r?\n" | Where-Object { $_ -ne '' })
    $result.StdErr = @($stderrText -split "\r?\n" | Where-Object { $_ -ne '' })
    $result.Output = @($result.StdOut + $result.StdErr)

    $process.Dispose()
    return $result
}

function Get-VegaPowerCfgPath {
    <#
      powercfg.exe 的绝对路径（不依赖 PATH，避免当前目录劫持）。
    #>
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { return $null }
    $candidate = Join-Path (Join-Path $env:SystemRoot 'System32') 'powercfg.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

function Write-VegaStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('Info', 'Ok', 'Warn')]
        [string]$Level = 'Info'
    )

    switch ($Level) {
        'Ok' { Write-Host $Message -ForegroundColor Green }
        'Warn' { Write-Host $Message -ForegroundColor Yellow }
        default { Write-Host $Message }
    }
}

# ---------------------------------------------------------------------------
# 文件写入（临时文件 + 原子替换）
# ---------------------------------------------------------------------------

function Write-VegaTextFileAtomic {
    <#
      同目录临时文件 + 原子替换，写出 UTF-8 无 BOM 文本。
      写入中断不会留下截断的目标文件。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text = ''
    )

    $directory = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrWhiteSpace($directory)) { $directory = (Get-Location).ProviderPath }
    if (-not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }

    $tempPath = Join-Path $directory ('.vega-tmp-' + [System.Guid]::NewGuid().ToString('N') + '.tmp')
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempPath, $Text, $utf8NoBom)

    try {
        if (Test-Path -LiteralPath $Path) {
            # 备份参数必须是 .NET 的 null 字符串：PowerShell 的 $null 会转成空路径，
            # File.Replace 随即报错。失败时原文件保持不变，绝不做“先删后移”。
            [System.IO.File]::Replace($tempPath, $Path, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    }
    catch {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }

    return $Path
}

function Get-VegaFileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }
    catch {
        return ''
    }
}

# ---------------------------------------------------------------------------
# winget 组件安装 / 卸载
# ---------------------------------------------------------------------------

function Get-VegaComponent {
    <#
      组件清单：唯一的事实来源，避免各脚本里散落包 ID。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Sunshine', 'Tailscale', 'RustDesk', 'Moonlight')]
        [string]$Name
    )

    $components = @{
        Sunshine  = [pscustomobject]@{ Name = 'Sunshine'; PackageId = 'LizardByte.Sunshine' }
        Tailscale = [pscustomobject]@{ Name = 'Tailscale'; PackageId = 'Tailscale.Tailscale' }
        RustDesk  = [pscustomobject]@{ Name = 'RustDesk'; PackageId = 'RustDesk.RustDesk' }
        Moonlight = [pscustomobject]@{ Name = 'Moonlight'; PackageId = 'MoonlightGameStreamingProject.Moonlight' }
    }

    return $components[$Name]
}

function Resolve-VegaWingetPath {
    <#
      从 App Installer 的注册信息解析 winget.exe 的绝对路径。
      解析不到返回 $null；调用方应报错退出，不要退回裸文件名。
    #>
    [CmdletBinding()]
    param()

    $packages = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue)
    foreach ($package in $packages) {
        if ($null -eq $package) { continue }
        $location = [string]$package.InstallLocation
        if ([string]::IsNullOrWhiteSpace($location)) { continue }
        $candidate = Join-Path $location 'winget.exe'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
        catch {
            return $candidate
        }
    }

    return $null
}

function Test-VegaWingetAvailable {
    [CmdletBinding()]
    param()

    return [bool](Resolve-VegaWingetPath)
}

function Invoke-VegaWinget {
    <#
      用解析出来的 winget.exe 绝对路径执行命令。
      找不到 winget 时返回失败结果（ExitCode = -1），不抛异常。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [int]$TimeoutSeconds = 900
    )

    $wingetPath = Resolve-VegaWingetPath
    if (-not $wingetPath) {
        return [pscustomobject]@{
            FilePath = 'winget.exe'
            ExitCode = -1
            Output   = @('未找到 winget.exe（App Installer 未安装或注册信息缺失）')
            StdOut   = @()
            StdErr   = @('未找到 winget.exe（App Installer 未安装或注册信息缺失）')
            TimedOut = $false
        }
    }

    return Invoke-VegaCommand -FilePath $wingetPath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds
}

function Get-VegaWingetPackageStatus {
    <#
      查询包是否已安装。区分三种结果：
        Installed    - 已安装
        NotInstalled - winget 明确回答“没有匹配”
        Failed       - 查询本身失败（源故障、超时、其他退出码）
      失败绝不能被折叠成“未安装”，否则卸载会静默跳过。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId
    )

    $result = Invoke-VegaWinget -ArgumentList @(
        'list', '--id', $PackageId, '-e', '--accept-source-agreements', '--disable-interactivity'
    ) -TimeoutSeconds 180

    $status = [pscustomobject]@{
        PackageId = $PackageId
        Installed = $false
        Status    = 'Failed'
        ExitCode  = $result.ExitCode
        Error     = ''
    }

    if ($result.TimedOut) {
        $status.Error = 'winget list 超时'
        return $status
    }

    if ($result.ExitCode -eq 0) {
        $pattern = '(?i)' + [regex]::Escape($PackageId)
        foreach ($line in @($result.Output)) {
            if ($line -match $pattern) {
                $status.Installed = $true
                $status.Status = 'Installed'
                return $status
            }
        }
        # 退出码 0 但列表里没有：按“未安装”处理（列表输出格式变化时不误报失败）
        $status.Status = 'NotInstalled'
        return $status
    }

    # 0x8A150014 / 0x8A15002B：No installed package / No package found matching input criteria
    if (@(-1978335212, -1978335189) -contains $result.ExitCode) {
        $status.Status = 'NotInstalled'
        return $status
    }

    $status.Error = "winget list 退出码 $($result.ExitCode)"
    return $status
}

function Install-VegaPackage {
    <#
      用 winget 安装组件；已安装则跳过（可重复执行）。
      返回 $true 表示本次真的装了。查询失败或安装失败都抛异常，
      由入口函数记入失败列表并反映到退出码。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [string]$DisplayName = '',

        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName)) { $DisplayName = $PackageId }

    if (-not $Force) {
        $status = Get-VegaWingetPackageStatus -PackageId $PackageId
        if ($status.Status -eq 'Failed') {
            throw "查询 $DisplayName 安装状态失败：$($status.Error)"
        }
        if ($status.Installed) {
            Write-Verbose "已安装，跳过：$PackageId"
            return $false
        }
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'winget install')) { return $false }

    $arguments = @(
        'install', '--id', $PackageId, '-e', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    )
    if ($Force) { $arguments += '--force' }

    $result = Invoke-VegaWinget -ArgumentList $arguments -TimeoutSeconds 1800
    if ($result.ExitCode -ne 0) {
        throw "安装 $DisplayName 失败（winget 退出码 $($result.ExitCode)）。可手动执行：winget install --id $PackageId -e --source winget"
    }

    return $true
}

function Uninstall-VegaPackage {
    <#
      winget 卸载组件；未安装则跳过。返回 $true 表示本次真的卸了。
      查询失败时抛异常，不把“查不到”当成“已卸载”。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [string]$DisplayName = ''
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName)) { $DisplayName = $PackageId }

    $status = Get-VegaWingetPackageStatus -PackageId $PackageId
    if ($status.Status -eq 'Failed') {
        throw "查询 $DisplayName 安装状态失败：$($status.Error)"
    }
    if (-not $status.Installed) {
        Write-Verbose "未安装，跳过：$PackageId"
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'winget uninstall')) { return $false }

    $arguments = @(
        'uninstall', '--id', $PackageId, '-e', '--silent',
        '--accept-source-agreements', '--disable-interactivity'
    )
    $result = Invoke-VegaWinget -ArgumentList $arguments -TimeoutSeconds 900
    if ($result.ExitCode -ne 0) {
        throw "卸载 $DisplayName 失败（winget 退出码 $($result.ExitCode)）。可手动执行：winget uninstall --id $PackageId -e"
    }

    return $true
}

# ---------------------------------------------------------------------------
# 状态清单：%ProgramData%\Vega\state.json
# ---------------------------------------------------------------------------

function Get-VegaStatePath {
    [CmdletBinding()]
    param()

    $root = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $root 'Vega') 'state.json')
}

function Get-VegaEmptyState {
    <#
      空清单。所有集合都是数组，便于 JSON 往返。
    #>
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        SchemaVersion         = 1
        UpdatedAt             = ''
        Packages              = @()
        Backups               = @()
        FirewallRules         = @()
        DisabledFirewallRules = @()
        Services              = @()
        ManagedConfigKeys     = @()
    }
}

function Read-VegaState {
    <#
      读取清单；文件不存在或损坏时返回空清单（不抛异常）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $state = Get-VegaEmptyState
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $state }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $state }

    try {
        $data = $raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "状态清单损坏，按空清单处理：$Path"
        return $state
    }

    if ($null -eq $data) { return $state }

    $properties = @($data.PSObject.Properties.Name)
    if ($properties -contains 'SchemaVersion') { $state.SchemaVersion = [int]$data.SchemaVersion }
    foreach ($name in @('Packages', 'Backups', 'FirewallRules', 'DisabledFirewallRules', 'Services', 'ManagedConfigKeys')) {
        if ($properties -contains $name) { $state.$name = @($data.$name) }
    }

    return $state
}

function Write-VegaState {
    <#
      原子写出清单（UTF-8 无 BOM）。目录不存在时创建。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $State.UpdatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $json = $State | ConvertTo-Json -Depth 8

    if (-not $PSCmdlet.ShouldProcess($Path, '写入状态清单')) { return $Path }

    $null = Write-VegaTextFileAtomic -Path $Path -Text $json
    return $Path
}

function Test-VegaStatePackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$PackageId
    )

    foreach ($entry in @($State.Packages)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.PackageId -eq $PackageId) { return $true }
    }
    return $false
}

function Add-VegaStatePackage {
    <#
      记录组件。-PreExisting 表示安装前就已存在（不是 Vega 装的），
      卸载时不删除它。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$PackageId,

        [string]$Name = '',

        [switch]$PreExisting
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $PackageId }
    if (Test-VegaStatePackage -State $State -PackageId $PackageId) { return $State }

    $entry = [pscustomobject]@{
        PackageId       = $PackageId
        Name            = $Name
        InstalledByVega = (-not $PreExisting.IsPresent)
        InstalledAt     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $State.Packages = @(@($State.Packages) + $entry)
    return $State
}

function Remove-VegaStatePackage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$PackageId
    )

    if (-not $PSCmdlet.ShouldProcess($PackageId, '从状态清单移除组件记录')) { return $State }

    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($State.Packages)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.PackageId -eq $PackageId) { continue }
        $kept.Add($entry)
    }
    $State.Packages = $kept.ToArray()
    return $State
}

function Add-VegaStateBackup {
    <#
      记录一次配置备份。同一路径只保留一条（重跑时更新写入内容的哈希）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$BackupPath = '',

        [bool]$OriginalExisted = $false,

        [string]$WrittenSha256 = '',

        [bool]$BackupCreated = $false
    )

    $entry = [pscustomobject]@{
        Path            = $Path
        BackupPath      = $BackupPath
        OriginalExisted = $OriginalExisted
        WrittenSha256   = $WrittenSha256
        BackupCreated   = $BackupCreated
        RecordedAt      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($State.Backups)) {
        if ($null -eq $item) { continue }
        if ([string]$item.Path -eq $Path) { continue }
        $kept.Add($item)
    }
    $kept.Add($entry)
    $State.Backups = $kept.ToArray()
    return $State
}

function Add-VegaStateDisabledFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Name
    )

    foreach ($item in @($State.DisabledFirewallRules)) {
        if ($null -ne $item -and [string]$item.Name -eq $Name) { return $State }
    }
    $State.DisabledFirewallRules = @(@($State.DisabledFirewallRules) + [pscustomobject]@{ Name = $Name })
    return $State
}

function Add-VegaStateFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Name
    )

    foreach ($item in @($State.FirewallRules)) {
        if ($null -ne $item -and [string]$item.Name -eq $Name) { return $State }
    }
    $State.FirewallRules = @(@($State.FirewallRules) + [pscustomobject]@{ Name = $Name })
    return $State
}

function Get-VegaStateServiceStartType {
    <#
      返回记录的原始启动类型；没有记录返回 $null。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Name
    )

    foreach ($entry in @($State.Services)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.Name -eq $Name) { return [string]$entry.OriginalStartType }
    }
    return $null
}

function Set-VegaStateServiceStartType {
    <#
      只在第一次记录服务的原始启动类型；重复执行不会用当前值覆盖原值。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$StartType
    )

    if ($null -ne (Get-VegaStateServiceStartType -State $State -Name $Name)) { return $State }
    if (-not $PSCmdlet.ShouldProcess($Name, '记录服务原始启动类型')) { return $State }

    $State.Services = @(@($State.Services) + [pscustomobject]@{
            Name              = $Name
            OriginalStartType = $StartType
        })
    return $State
}

# ---------------------------------------------------------------------------
# 显卡与编码器选择（纯函数）
# ---------------------------------------------------------------------------

function Test-VegaVirtualAdapter {
    <#
      判断显卡名是否是虚拟显示适配器（诱骗器、远程桌面、串流客户端等）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }

    $virtualPattern = 'Microsoft Basic Display|Microsoft Hyper-V|Parsec|Sunshine|Virtual Display|VirtualBox|VMware|Citrix|DisplayLink|DameWare|Spacedesk|IddSample|idd'
    return [bool]($Name -match $virtualPattern)
}

function Select-VegaAdapter {
    <#
      选出应该用于硬件编码的显卡。
      优先级：NVIDIA > AMD 独显(Radeon RX / Pro / VII) > Intel 或其他第一个。
      AMD 集显（如 "Radeon(TM) Graphics"、"Radeon 780M"）不参与第二优先级，
      因为大多数情况下 Intel/NVIDIA 独显的编码器更好用。
      空输入返回 $null。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$GpuNames,

        [switch]$SkipVirtual
    )

    $candidatePatterns = @(
        'NVIDIA|GeForce|Quadro|Tesla',
        'Radeon[^\r\n]*\b(?:RX|PRO|VII)\b'
    )

    $names = New-Object System.Collections.Generic.List[string]
    if ($null -ne $GpuNames) {
        foreach ($rawName in $GpuNames) {
            if ([string]::IsNullOrWhiteSpace($rawName)) { continue }
            if ($SkipVirtual -and (Test-VegaVirtualAdapter -Name $rawName)) { continue }
            $names.Add($rawName.Trim())
        }
    }

    if ($names.Count -eq 0) { return $null }

    foreach ($pattern in $candidatePatterns) {
        foreach ($name in $names) {
            if ($name -match $pattern) { return $name }
        }
    }

    return $names[0]
}

function Get-VegaEncoderName {
    <#
      按显卡名给出编码器显示名：NVENC / AMF / QSV / SOFTWARE。
      只用于提示；sunshine.conf 不写 encoder，保持自动探测。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$AdapterName
    )

    if ([string]::IsNullOrWhiteSpace($AdapterName)) { return 'SOFTWARE' }
    if ($AdapterName -match 'NVIDIA|GeForce|Quadro|Tesla') { return 'NVENC' }
    if ($AdapterName -match 'Radeon|Advanced Micro Devices|\bAMD\b') { return 'AMF' }
    if ($AdapterName -match 'Intel|Arc') { return 'QSV' }

    return 'SOFTWARE'
}

# ---------------------------------------------------------------------------
# Sunshine 安装路径
# ---------------------------------------------------------------------------

function Get-VegaSunshineInstall {
    <#
      在 Program Files 下找 Sunshine，返回 { Directory, Exe, Config, Version }。
      找不到返回 $null。
    #>
    [CmdletBinding()]
    param()

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'Sunshine'
        $exe = Join-Path $candidate 'sunshine.exe'
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }

        $version = ''
        try { $version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion }
        catch { $version = '' }

        return [pscustomobject]@{
            Directory = $candidate
            Exe       = $exe
            Config    = (Join-Path (Join-Path $candidate 'config') 'sunshine.conf')
            Version   = $version
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Sunshine 配置（解析 + 合并 + 落盘）
# ---------------------------------------------------------------------------

function ConvertFrom-VegaSunshineConfigText {
    <#
      纯函数：把配置文本解析成 键 -> 值 的有序字典。
      忽略注释与空行；同名键以第一次出现的为准。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    $values = [ordered]@{}
    if ([string]::IsNullOrEmpty($Text)) { return $values }

    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*(?<key>[A-Za-z0-9_]+)\s*=\s*(?<value>.*)$') {
            $key = $Matches['key']
            if (-not $values.Contains($key)) {
                $values[$key] = ([string]$Matches['value']).Trim()
            }
        }
    }

    return $values
}

function Merge-VegaSunshineConfigText {
    <#
      纯函数：只更新 $Values 里给出的键，其余行（用户自己加的键、注释、空行）
      原样保留。重复的受管键只保留第一条。缺失的受管键追加到文件末尾。
      返回以单个换行结尾的文本。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExistingText,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Values
    )

    $existingLines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($ExistingText)) {
        foreach ($line in ($ExistingText -split "\r?\n")) { $existingLines.Add($line) }
        while ($existingLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($existingLines[$existingLines.Count - 1])) {
            $existingLines.RemoveAt($existingLines.Count - 1)
        }
    }

    $written = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $output = New-Object System.Collections.Generic.List[string]

    foreach ($line in $existingLines) {
        $key = $null
        if ($line -match '^\s*(?<key>[A-Za-z0-9_]+)\s*=') { $key = $Matches['key'] }

        if ($null -ne $key -and $Values.Contains($key)) {
            if ($written.Contains($key)) { continue }
            $output.Add("$key = $($Values[$key])")
            $null = $written.Add($key)
            continue
        }

        $output.Add($line)
    }

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Values.Keys) {
        if (-not $written.Contains([string]$key)) { $missing.Add([string]$key) }
    }

    if ($missing.Count -gt 0) {
        if ($output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($output[$output.Count - 1])) {
            $output.Add('')
        }
        $output.Add('# Vega Remote 管理的设置（install-host.ps1 会维护这一段）')
        foreach ($key in $missing) {
            $output.Add("$key = $($Values[$key])")
        }
    }

    return (($output -join "`n") + "`n")
}

function Set-VegaSunshineConfig {
    <#
      写 sunshine.conf（UTF-8 无 BOM；Sunshine 不认 BOM）。
      同目录临时文件 + 原子替换；只在备份不存在时备份一次原配置。
      返回 { Path, BackupPath, BackupCreated, OriginalExisted, Sha256 }。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content,

        [switch]$NoBackup
    )

    $backupPath = "$Path.bak"
    $backupCreated = $false
    $originalExisted = Test-Path -LiteralPath $Path -PathType Leaf

    if (-not $NoBackup -and $originalExisted -and -not (Test-Path -LiteralPath $backupPath)) {
        if ($PSCmdlet.ShouldProcess($backupPath, '备份原配置')) {
            Copy-Item -LiteralPath $Path -Destination $backupPath -Force
            $backupCreated = $true
        }
    }

    if ($PSCmdlet.ShouldProcess($Path, '写入 Sunshine 配置')) {
        $null = Write-VegaTextFileAtomic -Path $Path -Text $Content
    }

    return [pscustomobject]@{
        Path            = $Path
        BackupPath      = $backupPath
        BackupCreated   = $backupCreated
        OriginalExisted = $originalExisted
        Sha256          = (Get-VegaFileSha256 -Path $Path)
    }
}

function Restore-VegaSunshineConfig {
    <#
      卸载用：按备份恢复 sunshine.conf。
      -ExpectedSha256 非空时先校验当前文件；被用户改过就报告冲突、不覆盖。
      -DeleteIfCreated 表示原配置本来不存在（Vega 新建的），校验通过后删除。
      返回 { Restored, Conflict, Message, BackupPath }。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$BackupPath = '',

        [string]$ExpectedSha256 = '',

        [switch]$DeleteIfCreated
    )

    if ([string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath = "$Path.bak" }

    $current = Get-VegaFileSha256 -Path $Path
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $current -ne $ExpectedSha256) {
        return [pscustomobject]@{
            Restored   = $false
            Conflict   = $true
            Message    = "配置在安装后被修改过，保留现状不覆盖：$Path（备份仍在 $BackupPath）"
            BackupPath = $BackupPath
        }
    }

    if ($DeleteIfCreated) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            if (-not $PSCmdlet.ShouldProcess($Path, '删除 Vega 新建的配置')) {
                return [pscustomobject]@{ Restored = $false; Conflict = $false; Message = '跳过删除配置'; BackupPath = $BackupPath }
            }
            Remove-Item -LiteralPath $Path -Force
        }
        return [pscustomobject]@{
            Restored   = $true
            Conflict   = $false
            Message    = "已删除 Vega 新建的配置：$Path"
            BackupPath = $BackupPath
        }
    }

    if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
        return [pscustomobject]@{
            Restored   = $false
            Conflict   = $false
            Message    = "没有备份可恢复：$BackupPath"
            BackupPath = $BackupPath
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, '从备份恢复')) {
        return [pscustomobject]@{ Restored = $false; Conflict = $false; Message = '跳过恢复配置'; BackupPath = $BackupPath }
    }

    Copy-Item -LiteralPath $BackupPath -Destination $Path -Force
    return [pscustomobject]@{
        Restored   = $true
        Conflict   = $false
        Message    = "已用 $BackupPath 恢复 $Path"
        BackupPath = $BackupPath
    }
}

# ---------------------------------------------------------------------------
# Sunshine 服务
# ---------------------------------------------------------------------------

function Get-VegaSunshineService {
    <#
      按精确服务名查找：新版 SunshineService，兼容旧名 sunshinesvc。
      不用 sunshine* 通配，避免命中同前缀的别的服务。
    #>
    [CmdletBinding()]
    param()

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('SunshineService', 'sunshinesvc')) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $service) { $result.Add($service) }
    }
    return $result.ToArray()
}

function Set-VegaSunshineServiceStartType {
    <#
      设置服务启动类型并回读验证。成功返回 $true。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Automatic', 'Manual', 'Disabled')]
        [string]$StartupType
    )

    if (-not $PSCmdlet.ShouldProcess($Name, "设置启动类型为 $StartupType")) { return $false }

    try {
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
    }
    catch {
        Write-Warning "设置服务 $Name 启动类型失败：$($_.Exception.Message)"
        return $false
    }

    $actual = ''
    try { $actual = [string](Get-Service -Name $Name -ErrorAction Stop).StartType }
    catch { $actual = '' }

    return ($actual -eq $StartupType)
}

function Restart-VegaSunshineService {
    <#
      设置自动启动并重启，然后回读状态确认 Running。
      返回 { Found, Name, Status, Success, Error }，不再静默吞掉失败。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Name = ''
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $services = @(Get-VegaSunshineService)
        if ($services.Count -eq 0) {
            $service = $null
        }
        else {
            $service = $services[0]
        }
    }
    else {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    }

    if ($null -eq $service) {
        return [pscustomobject]@{
            Found   = $false
            Name    = $Name
            Status  = ''
            Success = $false
            Error   = '未找到 SunshineService 服务'
        }
    }

    if (-not $PSCmdlet.ShouldProcess($service.Name, '设置自动启动并重启服务')) {
        return [pscustomobject]@{ Found = $true; Name = $service.Name; Status = [string]$service.Status; Success = $false; Error = '已跳过（WhatIf）' }
    }

    $errors = New-Object System.Collections.Generic.List[string]

    try {
        Set-Service -Name $service.Name -StartupType Automatic -ErrorAction Stop
    }
    catch {
        $errors.Add("设置自动启动失败：$($_.Exception.Message)")
    }

    try {
        Restart-Service -Name $service.Name -Force -ErrorAction Stop
    }
    catch {
        $errors.Add("重启失败：$($_.Exception.Message)")
    }

    $current = Get-Service -Name $service.Name -ErrorAction SilentlyContinue
    $status = ''
    if ($null -ne $current) { $status = [string]$current.Status }
    $success = ($status -eq 'Running')
    if (-not $success -and $errors.Count -eq 0) { $errors.Add("服务状态是 $status，不是 Running") }

    return [pscustomobject]@{
        Found   = $true
        Name    = $service.Name
        Status  = $status
        Success = $success
        Error   = ($errors -join '；')
    }
}

# ---------------------------------------------------------------------------
# 防火墙（Vega 自己创建的规则，固定内部 Name，限定 Program）
# ---------------------------------------------------------------------------

function Get-VegaSunshinePorts {
    <#
      纯函数：按 Sunshine 的端口偏移规则，从生效配置里的 port（默认 47989）
      算出全部端口。偏移相对默认 HTTP 端口 47989：
        HTTPS -5 / HTTP 0 / 管理页 +1 / RTSP +21
        UDP 视频 +9、控制 +10、音频 +11、麦克风 +13
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 65535)]
        [int]$BasePort = 47989
    )

    $ports = [pscustomobject]@{
        BasePort        = $BasePort
        Https           = $BasePort - 5
        Http            = $BasePort
        ManagementPort  = $BasePort + 1
        Rtsp            = $BasePort + 21
        Video           = $BasePort + 9
        Control         = $BasePort + 10
        Audio           = $BasePort + 11
        Microphone      = $BasePort + 13
    }

    foreach ($name in @('Https', 'ManagementPort', 'Rtsp', 'Video', 'Control', 'Audio', 'Microphone')) {
        if ($ports.$name -lt 1 -or $ports.$name -gt 65535) {
            throw "端口偏移越界：port = $BasePort，$name = $($ports.$name)"
        }
    }

    $ports | Add-Member -NotePropertyName TcpPorts -NotePropertyValue @(
        [string]$ports.Https, [string]$ports.Http, [string]$ports.Rtsp
    )
    $ports | Add-Member -NotePropertyName UdpPorts -NotePropertyValue @(
        ('{0}-{1}' -f $ports.Video, $ports.Audio), [string]$ports.Microphone, [string]$ports.Rtsp
    )

    return $ports
}

function Get-VegaSunshineBasePort {
    <#
      从生效的 sunshine.conf 读 port；读不到或非法时用默认 47989。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$ConfigPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { return 47989 }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return 47989 }

    $text = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    $values = ConvertFrom-VegaSunshineConfigText -Text $text
    if (-not $values.Contains('port')) { return 47989 }

    $port = 0
    if ([int]::TryParse(([string]$values['port']).Trim(), [ref]$port) -and $port -ge 1030 -and $port -le 65514) {
        return $port
    }

    Write-Warning "sunshine.conf 里的 port 无效（$($values['port'])），按默认 47989 计算端口。"
    return 47989
}

function Get-VegaFirewallRuleSpec {
    <#
      只放行串流端口（按生效配置计算）；管理端口不在列表里（管理页只允许本机访问）。
    #>
    [CmdletBinding()]
    param(
        [int]$BasePort = 47989
    )

    $ports = Get-VegaSunshinePorts -BasePort $BasePort
    return @(
        [pscustomobject]@{
            Name      = 'Vega-Sunshine-TCP'
            Protocol  = 'TCP'
            LocalPort = $ports.TcpPorts
        },
        [pscustomobject]@{
            Name      = 'Vega-Sunshine-UDP'
            Protocol  = 'UDP'
            LocalPort = $ports.UdpPorts
        }
    )
}

function Test-VegaPortInRange {
    <#
      纯函数：端口过滤器（"Any" / "47990" / "47998-48000"）是否覆盖指定端口。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Ports,

        [Parameter(Mandatory)]
        [int]$Port
    )

    if ($null -eq $Ports -or $Ports.Count -eq 0) { return $true }

    foreach ($entry in $Ports) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        if ($entry -eq 'Any') { return $true }
        if ($entry -match '^(?<start>\d+)$') {
            if ([int]$Matches['start'] -eq $Port) { return $true }
            continue
        }
        if ($entry -match '^(?<start>\d+)-(?<end>\d+)$') {
            if ($Port -ge [int]$Matches['start'] -and $Port -le [int]$Matches['end']) { return $true }
        }
    }

    return $false
}

function Select-VegaSunshineInstallerFirewallRule {
    <#
      纯函数：挑出 Sunshine 安装器自带、会放行管理端口的入站规则。
      规则对象字段：Name, DisplayName, Enabled, Program, LocalPort。
      Vega 自己的规则（Vega- 前缀）永不选中。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rules,

        [string]$SunshineExe = '',

        [int]$ManagementPort = 47990
    )

    $selected = New-Object System.Collections.Generic.List[object]
    foreach ($rule in @($Rules)) {
        if ($null -eq $rule) { continue }

        $name = ''
        if ($null -ne $rule.PSObject.Properties['Name']) { $name = [string]$rule.Name }
        if ($name -like 'Vega-*') { continue }

        $enabled = 'True'
        if ($null -ne $rule.PSObject.Properties['Enabled']) { $enabled = [string]$rule.Enabled }
        if ($enabled -eq 'False') { continue }

        $program = ''
        if ($null -ne $rule.PSObject.Properties['Program']) { $program = [string]$rule.Program }
        $display = ''
        if ($null -ne $rule.PSObject.Properties['DisplayName']) { $display = [string]$rule.DisplayName }

        $isSunshine = $false
        if (-not [string]::IsNullOrWhiteSpace($program) -and $program -match '(?i)\\sunshine\.exe$') { $isSunshine = $true }
        if (-not [string]::IsNullOrWhiteSpace($SunshineExe) -and $program -eq $SunshineExe) { $isSunshine = $true }
        if ([string]::IsNullOrWhiteSpace($program) -and $display -match '(?i)^sunshine') { $isSunshine = $true }
        if (-not $isSunshine) { continue }

        $ports = @()
        if ($null -ne $rule.PSObject.Properties['LocalPort']) { $ports = @($rule.LocalPort | ForEach-Object { [string]$_ }) }

        if (-not (Test-VegaPortInRange -Ports $ports -Port $ManagementPort)) { continue }

        $selected.Add($rule)
    }

    return $selected.ToArray()
}

function Get-VegaSunshineInstallerFirewallRule {
    <#
      枚举入站放行规则，返回 Sunshine 安装器自带、对管理端口放行的规则。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SunshineExe,

        [int]$ManagementPort = 47990
    )

    $collected = New-Object System.Collections.Generic.List[object]
    $rules = @(Get-NetFirewallRule -Direction Inbound -Action Allow -ErrorAction SilentlyContinue)
    foreach ($rule in $rules) {
        if ($null -eq $rule) { continue }

        $ruleName = [string]$rule.Name
        if ($ruleName -like 'Vega-*') { continue }

        $application = $null
        try { $application = $rule | Get-NetFirewallApplicationFilter -ErrorAction Stop }
        catch { $application = $null }

        $portFilter = $null
        try { $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction Stop }
        catch { $portFilter = $null }

        $program = ''
        if ($null -ne $application) { $program = [string]$application.Program }

        $ports = @('Any')
        if ($null -ne $portFilter -and $null -ne $portFilter.LocalPort) {
            $ports = @($portFilter.LocalPort | ForEach-Object { [string]$_ })
        }

        $collected.Add([pscustomobject]@{
                Name        = $ruleName
                DisplayName = [string]$rule.DisplayName
                Enabled     = [string]$rule.Enabled
                Program     = $program
                LocalPort   = $ports
            })
    }

    return @(Select-VegaSunshineInstallerFirewallRule -Rules $collected.ToArray() -SunshineExe $SunshineExe -ManagementPort $ManagementPort)
}

function Disable-VegaSunshineInstallerFirewallRule {
    <#
      禁用安装器自带的放行规则，回读确认 Enabled=False 后才算成功。
      返回成功禁用的规则名。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rules
    )

    $disabled = New-Object System.Collections.Generic.List[string]
    foreach ($rule in @($Rules)) {
        if ($null -eq $rule) { continue }
        $name = [string]$rule.Name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        if (-not $PSCmdlet.ShouldProcess($name, '禁用安装器自带的 Sunshine 放行规则')) { continue }

        try {
            Set-NetFirewallRule -Name $name -Enabled False -ErrorAction Stop
        }
        catch {
            Write-Warning "禁用防火墙规则 $name 失败：$($_.Exception.Message)"
            continue
        }

        $check = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $check -and [string]$check.Enabled -eq 'False') {
            $disabled.Add($name)
        }
        else {
            Write-Warning "防火墙规则 $name 未被禁用"
        }
    }

    return $disabled.ToArray()
}

function Enable-VegaSunshineInstallerFirewallRule {
    <#
      卸载用：重新启用记录过的安装器规则，返回成功的规则名。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Name
    )

    $enabled = New-Object System.Collections.Generic.List[string]
    foreach ($ruleName in @($Name)) {
        if ([string]::IsNullOrWhiteSpace($ruleName)) { continue }
        if (-not $PSCmdlet.ShouldProcess($ruleName, '恢复安装器防火墙规则')) { continue }

        try {
            Set-NetFirewallRule -Name $ruleName -Enabled True -ErrorAction Stop
        }
        catch {
            Write-Warning "恢复防火墙规则 $ruleName 失败：$($_.Exception.Message)"
            continue
        }
        $enabled.Add($ruleName)
    }

    return $enabled.ToArray()
}

function Test-VegaFirewallRule {
    <#
      按内部 Name 精确查找（不是 DisplayName，避免显示名撞车）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    return [bool]($null -ne $rule)
}

function Get-VegaFirewallRuleMissing {
    <#
      返回缺失的 Vega 防火墙规则名（诊断用，只读）。
    #>
    [CmdletBinding()]
    param()

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($spec in (Get-VegaFirewallRuleSpec)) {
        if (-not (Test-VegaFirewallRule -Name $spec.Name)) { $missing.Add($spec.Name) }
    }
    return $missing.ToArray()
}

function Remove-VegaFirewallRule {
    <#
      按内部 Name 删除规则，删除后回读确认；返回确认删除的条数。
      删不掉会写警告，不会假装成功。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Name = @('Vega-Sunshine-TCP', 'Vega-Sunshine-UDP')
    )

    if ($null -eq $Name) { return 0 }

    $removed = 0
    foreach ($ruleName in $Name) {
        if ([string]::IsNullOrWhiteSpace($ruleName)) { continue }
        if (-not (Test-VegaFirewallRule -Name $ruleName)) { continue }
        if (-not $PSCmdlet.ShouldProcess($ruleName, '删除防火墙规则')) { continue }

        try {
            Remove-NetFirewallRule -Name $ruleName -ErrorAction Stop
        }
        catch {
            Write-Warning "删除防火墙规则 $ruleName 失败：$($_.Exception.Message)"
            continue
        }

        if (Test-VegaFirewallRule -Name $ruleName) {
            Write-Warning "删除后规则仍存在：$ruleName"
            continue
        }
        $removed++
    }

    return $removed
}

function Test-VegaFirewallSpecSafe {
    <#
      纯函数：确认放行规则里不包含管理端口（管理页只允许本机访问）。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Specs,

        [Parameter(Mandatory)]
        [int]$ManagementPort
    )

    foreach ($spec in @($Specs)) {
        if ($null -eq $spec) { continue }
        if (Test-VegaPortInRange -Ports @($spec.LocalPort) -Port $ManagementPort) { return $false }
    }
    return $true
}

function Set-VegaFirewallRule {
    <#
      先删后建，规则限定 Program 为 sunshine.exe 绝对路径、只开按生效配置算出的串流端口。
      创建后逐条核对，失败抛异常。返回创建成功的规则名。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Program,

        [int]$BasePort = 47989
    )

    if (-not (Test-VegaAbsolutePath -Path $Program)) {
        throw "防火墙规则需要 sunshine.exe 的绝对路径，收到：$Program"
    }

    $ports = Get-VegaSunshinePorts -BasePort $BasePort
    $specs = @(Get-VegaFirewallRuleSpec -BasePort $BasePort)
    if (-not (Test-VegaFirewallSpecSafe -Specs $specs -ManagementPort $ports.ManagementPort)) {
        throw "放行规则覆盖了管理端口 $($ports.ManagementPort)，拒绝创建。"
    }

    $created = New-Object System.Collections.Generic.List[string]
    foreach ($spec in $specs) {
        if (-not $PSCmdlet.ShouldProcess($spec.Name, '重建防火墙规则')) { continue }

        $null = Remove-VegaFirewallRule -Name $spec.Name -Confirm:$false

        $params = @{
            Name        = $spec.Name
            DisplayName = $spec.Name
            Direction   = 'Inbound'
            Action      = 'Allow'
            Protocol    = $spec.Protocol
            LocalPort   = $spec.LocalPort
            Profile     = 'Any'
            Program     = $Program
            Enabled     = 'True'
            Description = 'Vega Remote：Sunshine 串流端口（不含管理端口）'
        }

        try {
            $null = New-NetFirewallRule @params -ErrorAction Stop
        }
        catch {
            throw "创建防火墙规则 $($spec.Name) 失败：$($_.Exception.Message)"
        }

        if (-not (Test-VegaFirewallRule -Name $spec.Name)) {
            throw "创建后未找到防火墙规则 $($spec.Name)"
        }
        $created.Add($spec.Name)
    }

    return $created.ToArray()
}

function Protect-VegaSunshineManagementPort {
    <#
      检测并禁用 Sunshine 安装器自带、对管理端口放行的入站规则，记录进清单。
      返回更新后的清单。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$SunshineExe,

        [int]$ManagementPort = 47990
    )

    if (-not (Test-Path -LiteralPath $SunshineExe -PathType Leaf)) { return $State }

    $rules = @(Get-VegaSunshineInstallerFirewallRule -SunshineExe $SunshineExe -ManagementPort $ManagementPort)
    if ($rules.Count -eq 0) { return $State }

    $disabled = @(Disable-VegaSunshineInstallerFirewallRule -Rules $rules -Confirm:$false)
    foreach ($ruleName in $disabled) {
        $State = Add-VegaStateDisabledFirewallRule -State $State -Name $ruleName
    }

    if ($disabled.Count -gt 0) {
        Write-VegaStatus ("已隔离管理端口 ${ManagementPort}：禁用安装器规则 {0}" -f ($disabled -join '、')) -Level Warn
    }

    return $State
}

# ---------------------------------------------------------------------------
# 网络探测（只读）
# ---------------------------------------------------------------------------

function Get-VegaPublicIPv6 {
    <#
      返回本机可用的公网风格 IPv6（排除回环、链路本地 fe80、组播 ff、ULA fc/fd）。
    #>
    [CmdletBinding()]
    param()

    $addresses = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $addresses) {
        $ip = [string]$entry.IPAddress
        if ([string]::IsNullOrWhiteSpace($ip)) { continue }
        if ($ip -eq '::1') { continue }
        if ($ip -match '^(fe80|ff)') { continue }
        if ($ip -match '^(fc|fd)') { continue }
        if ($result -contains $ip) { continue }
        $result.Add($ip)
    }
    return $result.ToArray()
}

function ConvertFrom-VegaTailscalePing {
    <#
      解析 `tailscale ping` 输出，判断直连 / DERP 中继 / Peer Relay。
      - 直连行：pong from host (100.x) via 1.2.3.4:41641 in 12ms
      - 中继行：pong from host (100.x) via DERP(tok) in 40ms
      - 对等中继：pong from host (100.x) via peer-relay(...) in 30ms
      以最后一条 pong 作为结论，同时保留每一条 pong 的先后顺序（Pongs），
      避免“仅凭计数推断顺序”。
      返回 { Mode, Succeeded, PongCount, DirectCount, DerpCount, PeerRelayCount,
             Endpoint, Region, LatencyMs, LastLine, Pongs }。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Output
    )

    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Output) {
        foreach ($line in $Output) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $lines.Add($line)
        }
    }

    $pongs = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        if ($line -notmatch '^\s*pong from ') { continue }

        $mode = 'Unknown'
        $endpoint = ''
        $region = ''

        if ($line -match '(?i)via\s+peer[- ]?relay\((?<relay>[^)]*)\)') {
            $mode = 'PeerRelay'
            $endpoint = "peer-relay($($Matches['relay']))"
            $region = $Matches['relay']
        }
        elseif ($line -match 'via DERP\((?<region>[^)]+)\)') {
            $mode = 'Derp'
            $region = $Matches['region']
            $endpoint = "DERP($region)"
        }
        elseif ($line -match 'via (?<endpoint>\S+)') {
            $mode = 'Direct'
            $endpoint = $Matches['endpoint']
        }

        $latency = $null
        if ($line -match 'in (?<ms>\d+(?:\.\d+)?)ms') {
            $latency = [double]$Matches['ms']
        }

        $pongs.Add([pscustomobject]@{
            Mode      = $mode
            Endpoint  = $endpoint
            Region    = $region
            LatencyMs = $latency
            Line      = $line.Trim()
        })
    }

    $result = [pscustomobject]@{
        Mode           = 'Unknown'
        Succeeded      = $false
        PongCount      = $pongs.Count
        DirectCount    = 0
        DerpCount      = 0
        PeerRelayCount = 0
        Endpoint       = ''
        Region         = ''
        LatencyMs      = $null
        LastLine       = ''
        Pongs          = $pongs.ToArray()
    }

    if ($pongs.Count -eq 0) {
        if ($lines.Count -gt 0) { $result.LastLine = $lines[$lines.Count - 1].Trim() }
        return $result
    }

    $direct = @($pongs | Where-Object { $_.Mode -eq 'Direct' })
    $derp = @($pongs | Where-Object { $_.Mode -eq 'Derp' })
    $peerRelay = @($pongs | Where-Object { $_.Mode -eq 'PeerRelay' })
    $last = $pongs[$pongs.Count - 1]

    $result.DirectCount = $direct.Count
    $result.DerpCount = $derp.Count
    $result.PeerRelayCount = $peerRelay.Count
    $result.Mode = $last.Mode
    $result.Endpoint = $last.Endpoint
    $result.Region = $last.Region
    $result.LatencyMs = $last.LatencyMs
    $result.LastLine = $last.Line
    $result.Succeeded = $true

    return $result
}

# ---------------------------------------------------------------------------
# 诊断结论（纯函数）
# ---------------------------------------------------------------------------

function Get-VegaDoctorAdvice {
    <#
      根据 vega-doctor 收集到的事实给出中文结论与建议。
      $Facts 键（缺省按“未知/不存在”处理）：
        AdapterName, Encoder, SunshineInstalled, SunshineRunning, SunshineVersion,
        MissingFirewallRules (string[]), Ipv6 (string[]),
        TailscaleInstalled, Peer, Ping (ConvertFrom-VegaTailscalePing 的结果)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Facts
    )

    $advice = New-Object System.Collections.Generic.List[string]

    $encoder = ''
    if ($Facts.ContainsKey('Encoder') -and $null -ne $Facts['Encoder']) { $encoder = [string]$Facts['Encoder'] }
    $sunshineInstalled = $false
    if ($Facts.ContainsKey('SunshineInstalled')) { $sunshineInstalled = [bool]$Facts['SunshineInstalled'] }
    $sunshineRunning = $false
    if ($Facts.ContainsKey('SunshineRunning')) { $sunshineRunning = [bool]$Facts['SunshineRunning'] }

    $missingRules = @()
    if ($Facts.ContainsKey('MissingFirewallRules') -and $null -ne $Facts['MissingFirewallRules']) {
        $missingRules = @($Facts['MissingFirewallRules'])
    }
    $ipv6 = @()
    if ($Facts.ContainsKey('Ipv6') -and $null -ne $Facts['Ipv6']) { $ipv6 = @($Facts['Ipv6']) }
    $tailscaleInstalled = $false
    if ($Facts.ContainsKey('TailscaleInstalled')) { $tailscaleInstalled = [bool]$Facts['TailscaleInstalled'] }

    if (-not $sunshineInstalled) {
        $advice.Add('未检测到 Sunshine：以管理员身份运行 host\install-host.ps1。')
    }
    elseif (-not $sunshineRunning) {
        $advice.Add('Sunshine 已安装但服务没在运行：管理员 PowerShell 执行 Restart-Service SunshineService（旧版服务名 sunshinesvc），或重新跑一次 install-host.ps1。')
    }

    if ($missingRules.Count -gt 0) {
        $advice.Add(("缺少 {0} 条 Vega 防火墙规则（{1}）：重新运行 install-host.ps1，脚本会先删后建。" -f $missingRules.Count, ($missingRules -join '、')))
    }

    if ($ipv6.Count -eq 0) {
        $advice.Add('未检测到公网 IPv6：走 Tailscale 直连；想用 IPv6 需在光猫/路由器开启 IPv6 下发。')
    }

    switch ($encoder) {
        'NVENC' { $advice.Add('推荐编码器 NVENC：Moonlight 里选 HEVC + 硬件解码，码率默认即可。') }
        'AMF' {
            $advice.Add('推荐编码器 AMF：请装 22.3.1 以上驱动；老 A 卡不支持 HEVC 时退回 H.264。')
        }
        'QSV' { $advice.Add('推荐编码器 QSV：核显 1080p 60 帧很稳，2K 建议把帧率降到 30～60。') }
        'SOFTWARE' { $advice.Add('没有可用的硬件编码器：先装最新显卡驱动；仍不行就降分辨率，由 CPU 软编。') }
        default { }
    }

    if (-not $tailscaleInstalled) {
        $advice.Add('未检测到 Tailscale：安装并登录同一账号后，才会有 100.x.x.x 地址可用于 Moonlight。')
    }

    $peer = ''
    if ($Facts.ContainsKey('Peer') -and $null -ne $Facts['Peer']) { $peer = [string]$Facts['Peer'] }

    if ($Facts.ContainsKey('Ping') -and $null -ne $Facts['Ping']) {
        $ping = $Facts['Ping']
        switch ($ping.Mode) {
            'Direct' {
                $advice.Add(("到 {0} 已直连（{1}，{2}ms），延迟正常。" -f $peer, $ping.Endpoint, $ping.LatencyMs))
            }
            'PeerRelay' {
                $advice.Add(("到 {0} 走 Peer Relay（{1}，{2}ms）：不是直连。两端放行 UDP 41641、路由器开 UPnP，通常能升级为直连。" -f $peer, $ping.Endpoint, $ping.LatencyMs))
            }
            'Derp' {
                $advice.Add(("到 {0} 走 DERP 中继（{1}）：两端重启 Tailscale、路由器开 UPnP，或改用 IPv6 直连，延迟通常能降 100ms 以上。" -f $peer, $ping.Region))
            }
            default {
                $advice.Add(("tailscale ping {0} 没有收到 pong：确认对端在线、已登录同一账号，且机器名没写错。" -f $peer))
            }
        }
    }
    elseif ($tailscaleInstalled -and [string]::IsNullOrWhiteSpace($peer)) {
        $advice.Add('想看是否直连：加 -Peer <被控端机器名> 再跑一次（例：-Peer vega-host）。')
    }

    if ($advice.Count -eq 0) {
        $advice.Add('整体状态良好：打开 Moonlight 添加被控端地址即可连接。')
    }

    $advice.Add('更多排查：docs/network.md；安装/卸载：README.md。')
    return $advice.ToArray()
}

# ---------------------------------------------------------------------------
# 入口编排：被控端安装 / 卸载
# ---------------------------------------------------------------------------

function Invoke-VegaHostInstall {
    <#
      被控端安装流程（脚本只是薄包装，逻辑在这里便于 mock 测试）：
      装组件 -> 隔离管理端口 -> 合并配置 -> 只放行串流端口 -> 关睡眠 -> 服务自启。
      返回 { ExitCode, Failures }；任何失败都让退出码非零。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$Force,
        [string]$StatePath = (Get-VegaStatePath),
        [string]$TemplatePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'sunshine.conf')
    )

    $failures = New-Object System.Collections.Generic.List[string]

    if (-not (Test-VegaWingetAvailable)) {
        throw '未找到 winget（App Installer）。请按官方文档安装「应用安装程序」后重试。'
    }

    $state = Read-VegaState -Path $StatePath

    # 已经装过 Sunshine 的机器：先隔离管理端口，再动配置
    $existingSunshine = Get-VegaSunshineInstall
    if ($null -ne $existingSunshine) {
        $existingPort = Get-VegaSunshineBasePort -ConfigPath $existingSunshine.Config
        $state = Protect-VegaSunshineManagementPort -State $state -SunshineExe $existingSunshine.Exe -ManagementPort (Get-VegaSunshinePorts -BasePort $existingPort).ManagementPort -Confirm:$false
        $null = Write-VegaState -State $state -Path $StatePath -Confirm:$false
    }

    $componentNames = New-Object System.Collections.Generic.List[string]
    $componentNames.Add('Sunshine')
    if (-not $SkipTailscale) { $componentNames.Add('Tailscale') }
    if ($WithRustDesk) { $componentNames.Add('RustDesk') }

    foreach ($name in $componentNames) {
        $component = Get-VegaComponent -Name $name
        Write-VegaStatus "安装 $($component.Name)"

        $installed = $false
        try {
            $installed = Install-VegaPackage -PackageId $component.PackageId -DisplayName $component.Name -Force:$Force -Confirm:$false
        }
        catch {
            $failures.Add("安装 $($component.Name) 失败：$($_.Exception.Message)")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            continue
        }

        if (Test-VegaStatePackage -State $state -PackageId $component.PackageId) { continue }

        if ($installed) {
            $state = Add-VegaStatePackage -State $state -PackageId $component.PackageId -Name $component.Name
        }
        else {
            $state = Add-VegaStatePackage -State $state -PackageId $component.PackageId -Name $component.Name -PreExisting
        }
        $null = Write-VegaState -State $state -Path $StatePath -Confirm:$false
    }

    $sunshine = Get-VegaSunshineInstall
    if ($null -eq $sunshine) {
        $failures.Add('未找到 Sunshine 安装目录，安装可能失败。可手动执行：winget install --id LizardByte.Sunshine -e --source winget')
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        return [pscustomobject]@{
            ExitCode = 1
            Failures = $failures.ToArray()
        }
    }

    $basePort = Get-VegaSunshineBasePort -ConfigPath $sunshine.Config
    $ports = Get-VegaSunshinePorts -BasePort $basePort
    $state = Protect-VegaSunshineManagementPort -State $state -SunshineExe $sunshine.Exe -ManagementPort $ports.ManagementPort -Confirm:$false
    $null = Write-VegaState -State $state -Path $StatePath -Confirm:$false

    Write-VegaStatus '检测显卡'
    $gpuNames = @()
    try {
        $gpuNames = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            ForEach-Object { [string]$_.Name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    catch {
        Write-VegaStatus "读取显卡列表失败：$($_.Exception.Message)" -Level Warn
    }
    foreach ($gpu in $gpuNames) { Write-VegaStatus "  - $gpu" }

    $preferred = Select-VegaAdapter -GpuNames $gpuNames -SkipVirtual
    if (-not $preferred) { $preferred = Select-VegaAdapter -GpuNames $gpuNames }
    if (-not $preferred) {
        Write-VegaStatus '没有检测到可用显卡，将使用 Sunshine 自动探测。' -Level Warn
        $preferred = ''
    }

    if ([string]::IsNullOrWhiteSpace($preferred)) {
        Write-VegaStatus '编码器：自动探测（sunshine.conf 不写 encoder）' -Level Warn
    }
    else {
        Write-VegaStatus "编码将使用: $preferred（$(Get-VegaEncoderName -AdapterName $preferred)，由 Sunshine 自动选择）" -Level Ok
    }

    Write-VegaStatus '写入 Sunshine 配置（只更新 Vega 管理的键）'
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "缺少配置模板：$TemplatePath"
    }

    $templateText = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    $defaults = ConvertFrom-VegaSunshineConfigText -Text $templateText

    $values = [ordered]@{}
    foreach ($key in $defaults.Keys) {
        $keyText = [string]$key
        $values[$keyText] = $defaults[$key]
    }
    if (-not $values.Contains('sunshine_name')) { $values['sunshine_name'] = 'Vega' }
    $values['adapter_name'] = $preferred

    $existingText = ''
    if (Test-Path -LiteralPath $sunshine.Config -PathType Leaf) {
        $existingText = Get-Content -LiteralPath $sunshine.Config -Raw -Encoding UTF8
    }

    $merged = Merge-VegaSunshineConfigText -ExistingText $existingText -Values $values
    $configResult = Set-VegaSunshineConfig -Path $sunshine.Config -Content $merged -Confirm:$false

    $state = Add-VegaStateBackup -State $state -Path $sunshine.Config `
        -BackupPath $configResult.BackupPath `
        -OriginalExisted $configResult.OriginalExisted `
        -WrittenSha256 $configResult.Sha256 `
        -BackupCreated $configResult.BackupCreated
    $null = Write-VegaState -State $state -Path $StatePath -Confirm:$false

    if ($configResult.BackupCreated) {
        Write-VegaStatus "已备份原配置到 $($configResult.BackupPath)" -Level Ok
    }
    Write-VegaStatus "配置已写入 $($configResult.Path)"

    Write-VegaStatus "放行串流端口（仅 sunshine.exe，不含管理端口 $($ports.ManagementPort)）"
    try {
        $createdRules = @(Set-VegaFirewallRule -Program $sunshine.Exe -BasePort $basePort -Confirm:$false)
        foreach ($ruleName in $createdRules) {
            $state = Add-VegaStateFirewallRule -State $state -Name $ruleName
        }
        $null = Write-VegaState -State $state -Path $StatePath -Confirm:$false
        Write-VegaStatus ("Vega 防火墙规则已就绪（TCP {0}；UDP {1}）" -f ($ports.TcpPorts -join '/'), ($ports.UdpPorts -join '/')) -Level Ok
    }
    catch {
        $failures.Add("防火墙规则创建失败：$($_.Exception.Message)")
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
    }

    Write-VegaStatus '关闭插电睡眠'
    $powercfg = Get-VegaPowerCfgPath
    if ($null -eq $powercfg) {
        Write-VegaStatus '未找到 System32\powercfg.exe，跳过睡眠设置。' -Level Warn
    }
    else {
        foreach ($argument in @(
                @('/change', 'standby-timeout-ac', '0'),
                @('/change', 'hibernate-timeout-ac', '0')
            )) {
            $powerResult = Invoke-VegaCommand -FilePath $powercfg -ArgumentList $argument -TimeoutSeconds 30
            if ($powerResult.ExitCode -ne 0) {
                Write-VegaStatus ("powercfg {0} 失败（退出码 {1}），可手动在电源选项里设置。" -f ($argument -join ' '), $powerResult.ExitCode) -Level Warn
            }
        }
    }

    Write-VegaStatus '设置 Sunshine 服务'
    $services = @(Get-VegaSunshineService)
    if ($services.Count -eq 0) {
        $failures.Add('未找到 SunshineService 服务（安装器可能没有注册服务），请手动启动 Sunshine。')
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
    }
    else {
        $service = $services[0]
        $recorded = Get-VegaStateServiceStartType -State $state -Name $service.Name
        if ($null -eq $recorded) {
            $state = Set-VegaStateServiceStartType -State $state -Name $service.Name -StartType ([string]$service.StartType)
            $null = Write-VegaState -State $state -Path $StatePath -Confirm:$false
        }

        $restart = Restart-VegaSunshineService -Name $service.Name -Confirm:$false
        if (-not $restart.Success) {
            $failures.Add("Sunshine 服务未能正常运行：$($restart.Error)")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        }
        else {
            Write-VegaStatus "服务 $($restart.Name) 已在运行" -Level Ok
        }
    }

    Write-VegaStatus '完成' -Level Ok
    Write-VegaStatus "首次设置管理密码：在本机浏览器打开 https://localhost:$($ports.ManagementPort) ，按页面提示设置账号密码。"
    Write-VegaStatus "管理页只允许本机访问（origin_web_ui_allowed = pc），$($ports.ManagementPort) 不放行到网络。"
    if (-not $SkipTailscale) {
        Write-VegaStatus '下一步：打开 Tailscale 登录，记下本机 100.x.x.x 地址'
    }

    $ipv6 = @(Get-VegaPublicIPv6)
    if ($ipv6.Count -gt 0) {
        Write-VegaStatus "检测到公网 IPv6: $($ipv6[0])（Sunshine 已设 address_family = both，可直连）" -Level Ok
    }
    else {
        Write-VegaStatus '未检测到公网 IPv6，将使用 Tailscale 组网'
    }
    Write-VegaStatus '诊断：.\tools\vega-doctor.ps1 -Peer <被控端机器名>'

    return [pscustomobject]@{
        ExitCode = $(if ($failures.Count -gt 0) { 1 } else { 0 })
        Failures = $failures.ToArray()
    }
}

function Invoke-VegaHostUninstall {
    <#
      被控端卸载：只按状态清单回滚。
      - 删除记录过的 Vega 防火墙规则
      - 恢复记录过的安装器防火墙规则
      - 配置被用户改过时报告冲突、不覆盖
      - 服务启动类型恢复为安装前的值
      - -RemoveApps 只卸载 Vega 装的组件
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$RemoveApps,
        [string]$StatePath = (Get-VegaStatePath)
    )

    $failures = New-Object System.Collections.Generic.List[string]
    $hasState = Test-Path -LiteralPath $StatePath -PathType Leaf
    $state = Read-VegaState -Path $StatePath

    if (-not $hasState) {
        Write-VegaStatus '没有找到状态清单（%ProgramData%\Vega\state.json）：按旧安装清理 Vega 自己的防火墙规则，其余保持现状。' -Level Warn
    }

    Write-VegaStatus '删除 Vega 防火墙规则'
    $ruleNames = @()
    foreach ($item in @($state.FirewallRules)) {
        if ($null -eq $item) { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$item.Name)) { $ruleNames += [string]$item.Name }
    }
    if ($ruleNames.Count -eq 0) {
        $ruleNames = @((Get-VegaFirewallRuleSpec) | ForEach-Object { $_.Name })
    }
    $removed = Remove-VegaFirewallRule -Name $ruleNames -Confirm:$false
    Write-VegaStatus "已删除 $removed 条 Vega 防火墙规则"

    $disabledNames = @()
    foreach ($item in @($state.DisabledFirewallRules)) {
        if ($null -eq $item) { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$item.Name)) { $disabledNames += [string]$item.Name }
    }
    if ($disabledNames.Count -gt 0) {
        $enabled = @(Enable-VegaSunshineInstallerFirewallRule -Name $disabledNames -Confirm:$false)
        foreach ($ruleName in $disabledNames) {
            if ($enabled -notcontains $ruleName) {
                $failures.Add("未能恢复安装器防火墙规则：$ruleName")
                Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            }
        }
    }

    Write-VegaStatus '恢复 Sunshine 配置'
    foreach ($backup in @($state.Backups)) {
        if ($null -eq $backup) { continue }
        $configPath = [string]$backup.Path
        if ([string]::IsNullOrWhiteSpace($configPath)) { continue }

        $restore = Restore-VegaSunshineConfig -Path $configPath `
            -BackupPath ([string]$backup.BackupPath) `
            -ExpectedSha256 ([string]$backup.WrittenSha256) `
            -DeleteIfCreated:(-not [bool]$backup.OriginalExisted) `
            -Confirm:$false

        Write-VegaStatus $restore.Message
        if ($restore.Conflict) {
            Write-VegaStatus "配置冲突：$configPath 在安装后被修改过，未覆盖（备份保留在 $($restore.BackupPath)）。" -Level Warn
        }
    }

    Write-VegaStatus '恢复 Sunshine 服务状态'
    foreach ($entry in @($state.Services)) {
        if ($null -eq $entry) { continue }
        $serviceName = [string]$entry.Name
        if ([string]::IsNullOrWhiteSpace($serviceName)) { continue }

        $startType = [string]$entry.OriginalStartType
        if ($startType -notin @('Automatic', 'Manual', 'Disabled')) { $startType = 'Manual' }

        try {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        }
        catch {
            $null = $_
        }

        if (-not (Set-VegaSunshineServiceStartType -Name $serviceName -StartupType $startType -Confirm:$false)) {
            $failures.Add("恢复服务启动类型失败：$serviceName → $startType")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        }
        else {
            Write-VegaStatus "服务 $serviceName 已恢复启动类型 $startType 并停止" -Level Ok
        }
    }

    if ($RemoveApps) {
        Write-VegaStatus '按清单卸载 Vega 安装的组件'
        $targets = @()
        foreach ($package in @($state.Packages)) {
            if ($null -eq $package) { continue }
            if (-not [bool]$package.InstalledByVega) { continue }
            $packageName = [string]$package.Name
            if ($SkipTailscale -and $packageName -eq 'Tailscale') { continue }
            if (-not $WithRustDesk -and $packageName -eq 'RustDesk') { continue }
            $targets += $package
        }

        if ($targets.Count -eq 0) {
            Write-VegaStatus '清单里没有需要卸载的 Vega 组件（用户原有的应用不动）。'
        }
        elseif (-not (Test-VegaWingetAvailable)) {
            $failures.Add('未找到 winget，无法卸载组件；请从「设置 → 应用」手动卸载。')
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        }
        else {
            foreach ($package in $targets) {
                $packageId = [string]$package.PackageId
                $packageName = [string]$package.Name
                try {
                    $done = Uninstall-VegaPackage -PackageId $packageId -DisplayName $packageName -Confirm:$false
                    if ($done) { Write-VegaStatus "已卸载 $packageName" -Level Ok }
                    else { Write-VegaStatus "$packageName 未安装，跳过" }

                    $state = Remove-VegaStatePackage -State $state -PackageId $packageId
                    $null = Write-VegaState -State $state -Path $StatePath -Confirm:$false
                }
                catch {
                    $failures.Add("卸载 $packageName 失败：$($_.Exception.Message)")
                    Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
                }
            }
        }
    }

    if ($hasState) {
        if ($failures.Count -eq 0) {
            Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-VegaStatus "仍有失败项，保留状态清单便于再次回滚：$StatePath" -Level Warn
        }
    }

    Write-VegaStatus '卸载完成' -Level Ok
    Write-VegaStatus '已保留：睡眠设置、Sunshine 安装目录（未加 -RemoveApps 时）。'

    return [pscustomobject]@{
        ExitCode = $(if ($failures.Count -gt 0) { 1 } else { 0 })
        Failures = $failures.ToArray()
    }
}

# ---------------------------------------------------------------------------
# 入口编排：主控端安装 / 卸载
# ---------------------------------------------------------------------------

function Invoke-VegaClientInstall {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$Force,
        [string]$StatePath = (Get-VegaStatePath)
    )

    $failures = New-Object System.Collections.Generic.List[string]

    if (-not (Test-VegaWingetAvailable)) {
        throw '未找到 winget（App Installer）。请按官方文档安装「应用安装程序」后重试。'
    }

    $state = Read-VegaState -Path $StatePath

    $componentNames = New-Object System.Collections.Generic.List[string]
    $componentNames.Add('Moonlight')
    if (-not $SkipTailscale) { $componentNames.Add('Tailscale') }
    if ($WithRustDesk) { $componentNames.Add('RustDesk') }

    foreach ($name in $componentNames) {
        $component = Get-VegaComponent -Name $name
        Write-VegaStatus "安装 $($component.Name)"

        $installed = $false
        try {
            $installed = Install-VegaPackage -PackageId $component.PackageId -DisplayName $component.Name -Force:$Force -Confirm:$false
        }
        catch {
            $failures.Add("安装 $($component.Name) 失败：$($_.Exception.Message)")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            continue
        }

        if (Test-VegaStatePackage -State $state -PackageId $component.PackageId) { continue }

        if ($installed) {
            $state = Add-VegaStatePackage -State $state -PackageId $component.PackageId -Name $component.Name
        }
        else {
            $state = Add-VegaStatePackage -State $state -PackageId $component.PackageId -Name $component.Name -PreExisting
        }
        $null = Write-VegaState -State $state -Path $StatePath -Confirm:$false
    }

    Write-VegaStatus '完成' -Level Ok
    Write-VegaStatus '接下来：'
    Write-VegaStatus '1. 登录 Tailscale（与被控端同一账号）'
    Write-VegaStatus '2. 打开 Moonlight → 右上角 + → 输入被控端 100.x.x.x 或 IPv6 地址'
    Write-VegaStatus '3. 在被控端本机浏览器打开 https://localhost:<管理端口，默认 47990> 完成首次设密，再在 PIN 页面输入 Moonlight 显示的 PIN'
    Write-VegaStatus '4. Moonlight 设置：分辨率选原生，帧率 60，码率默认，开启 HEVC'
    Write-VegaStatus '诊断：.\tools\vega-doctor.ps1 -Peer <被控端机器名>'

    return [pscustomobject]@{
        ExitCode = $(if ($failures.Count -gt 0) { 1 } else { 0 })
        Failures = $failures.ToArray()
    }
}

function Invoke-VegaClientUninstall {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$RemoveApps,
        [string]$StatePath = (Get-VegaStatePath)
    )

    $failures = New-Object System.Collections.Generic.List[string]

    if (-not $RemoveApps) {
        Write-VegaStatus '没有指定 -RemoveApps，卸载模式不会改动系统。'
        return [pscustomobject]@{ ExitCode = 0; Failures = @() }
    }

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        Write-VegaStatus '没有状态清单，不知道哪些组件是 Vega 装的，跳过 winget 卸载。' -Level Warn
        return [pscustomobject]@{ ExitCode = 0; Failures = @() }
    }

    $state = Read-VegaState -Path $StatePath

    $targets = @()
    foreach ($package in @($state.Packages)) {
        if ($null -eq $package) { continue }
        if (-not [bool]$package.InstalledByVega) { continue }
        $packageName = [string]$package.Name
        if ($SkipTailscale -and $packageName -eq 'Tailscale') { continue }
        if (-not $WithRustDesk -and $packageName -eq 'RustDesk') { continue }
        $targets += $package
    }

    if ($targets.Count -eq 0) {
        Write-VegaStatus '清单里没有需要卸载的 Vega 组件（用户原有的应用不动）。'
    }
    elseif (-not (Test-VegaWingetAvailable)) {
        $failures.Add('未找到 winget，无法卸载组件；请从「设置 → 应用」手动卸载。')
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
    }
    else {
        foreach ($package in $targets) {
            $packageId = [string]$package.PackageId
            $packageName = [string]$package.Name
            try {
                $done = Uninstall-VegaPackage -PackageId $packageId -DisplayName $packageName -Confirm:$false
                if ($done) { Write-VegaStatus "已卸载 $packageName" -Level Ok }
                else { Write-VegaStatus "$packageName 未安装，跳过" }

                $state = Remove-VegaStatePackage -State $state -PackageId $packageId
                $null = Write-VegaState -State $state -Path $StatePath -Confirm:$false
            }
            catch {
                $failures.Add("卸载 $packageName 失败：$($_.Exception.Message)")
                Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            }
        }
    }

    if ($failures.Count -eq 0 -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        if (@($state.Packages).Count -eq 0) {
            Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-VegaStatus '卸载完成' -Level Ok
    Write-VegaStatus '提示：Tailscale 卸载后需要重新登录才能恢复 100.x.x.x 地址。'

    return [pscustomobject]@{
        ExitCode = $(if ($failures.Count -gt 0) { 1 } else { 0 })
        Failures = $failures.ToArray()
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-VegaArgumentString',
    'Test-VegaAbsolutePath',
    'Invoke-VegaCommand',
    'Get-VegaPowerCfgPath',
    'Write-VegaStatus',
    'Write-VegaTextFileAtomic',
    'Get-VegaFileSha256',
    'Get-VegaComponent',
    'Resolve-VegaWingetPath',
    'Test-VegaWingetAvailable',
    'Invoke-VegaWinget',
    'Get-VegaWingetPackageStatus',
    'Install-VegaPackage',
    'Uninstall-VegaPackage',
    'Get-VegaStatePath',
    'Get-VegaEmptyState',
    'Read-VegaState',
    'Write-VegaState',
    'Test-VegaStatePackage',
    'Add-VegaStatePackage',
    'Remove-VegaStatePackage',
    'Add-VegaStateBackup',
    'Add-VegaStateDisabledFirewallRule',
    'Add-VegaStateFirewallRule',
    'Get-VegaStateServiceStartType',
    'Set-VegaStateServiceStartType',
    'Test-VegaVirtualAdapter',
    'Select-VegaAdapter',
    'Get-VegaEncoderName',
    'Get-VegaSunshineInstall',
    'ConvertFrom-VegaSunshineConfigText',
    'Merge-VegaSunshineConfigText',
    'Set-VegaSunshineConfig',
    'Restore-VegaSunshineConfig',
    'Get-VegaSunshineService',
    'Set-VegaSunshineServiceStartType',
    'Restart-VegaSunshineService',
    'Get-VegaSunshinePorts',
    'Get-VegaSunshineBasePort',
    'Get-VegaFirewallRuleSpec',
    'Test-VegaFirewallSpecSafe',
    'Test-VegaPortInRange',
    'Select-VegaSunshineInstallerFirewallRule',
    'Get-VegaSunshineInstallerFirewallRule',
    'Disable-VegaSunshineInstallerFirewallRule',
    'Enable-VegaSunshineInstallerFirewallRule',
    'Protect-VegaSunshineManagementPort',
    'Test-VegaFirewallRule',
    'Get-VegaFirewallRuleMissing',
    'Remove-VegaFirewallRule',
    'Set-VegaFirewallRule',
    'Get-VegaPublicIPv6',
    'ConvertFrom-VegaTailscalePing',
    'Get-VegaDoctorAdvice',
    'Invoke-VegaHostInstall',
    'Invoke-VegaHostUninstall',
    'Invoke-VegaClientInstall',
    'Invoke-VegaClientUninstall'
)
