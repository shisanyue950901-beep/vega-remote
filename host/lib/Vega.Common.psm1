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
  - 被控端状态清单落在 %ProgramData%\Vega\host-state.json（管理员专用 ACL），
    主控端落在 %LOCALAPPDATA%\Vega\client-state.json；卸载只按清单回滚，
    回滚前逐条过白名单。
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

    # 管理员进程不依赖 PATH/当前目录搜索：只接受绝对路径，避免同名程序劫持。
    if (-not (Test-VegaAbsolutePath -Path $FilePath)) {
        $message = "外部程序必须用绝对路径启动：$FilePath"
        $result.StdErr = @($message)
        $result.Output = @($message)
        return $result
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
        [ValidateSet('Sunshine', 'Tailscale', 'Moonlight')]
        [string]$Name
    )

    # RustDesk 不在这里：WinGet 社区源已下架 RustDesk，只能从官方发行页手动安装。
    $components = @{
        Sunshine  = [pscustomobject]@{ Name = 'Sunshine'; PackageId = 'LizardByte.Sunshine' }
        Tailscale = [pscustomobject]@{ Name = 'Tailscale'; PackageId = 'Tailscale.Tailscale' }
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

    $windowsApps = ''
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
    }

    foreach ($package in $packages) {
        if ($null -eq $package) { continue }

        # 只认微软签名的 App Installer：名称、包家族、发布者、安装位置都要对得上。
        if ([string]$package.Name -ne 'Microsoft.DesktopAppInstaller') { continue }
        if ([string]$package.PackageFamilyName -notlike 'Microsoft.DesktopAppInstaller_*') { continue }
        if ([string]$package.Publisher -notmatch '(?i)^CN=Microsoft Corporation') { continue }

        $location = [string]$package.InstallLocation
        if ([string]::IsNullOrWhiteSpace($location)) { continue }
        if (-not (Test-VegaAbsolutePath -Path $location)) { continue }
        if (Test-VegaReparsePoint -Path $location) { continue }

        if (-not [string]::IsNullOrWhiteSpace($windowsApps)) {
            try {
                $root = [System.IO.Path]::GetFullPath($windowsApps).TrimEnd('\') + '\'
                $actual = [System.IO.Path]::GetFullPath($location).TrimEnd('\') + '\'
                if (-not $actual.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            }
            catch {
                continue
            }
        }

        $candidate = Join-Path $location 'winget.exe'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        if (Test-VegaReparsePoint -Path $candidate) { continue }

        try {
            $resolved = (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
        catch {
            continue
        }
        if (-not (Test-VegaAbsolutePath -Path $resolved)) { continue }
        return $resolved
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
        # 退出码 0 却解析不到包 ID：不能当成“未安装”，否则查询输出变化会让
        # -RemoveApps 静默跳过、或者把已存在的包登记成 Vega 装的。
        $status.Error = "winget list 退出码 0，但输出里没有包 ID $PackageId（输出可能被截断或格式变化）"
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
      用 winget 安装组件；可重复执行。
      -Force 只是让 winget 重装，前置查询照做：安装前就存在的包一律算 PreExisting，
      永不被 -RemoveApps 卸载（用户原有的 Tailscale / Sunshine 不能算 Vega 的）。
      返回 { PackageId, Installed, PreExisting }；查询或安装失败抛异常。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [string]$DisplayName = '',

        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName)) { $DisplayName = $PackageId }

    $status = Get-VegaWingetPackageStatus -PackageId $PackageId
    if ($status.Status -eq 'Failed') {
        throw "查询 $DisplayName 安装状态失败：$($status.Error)"
    }

    $outcome = [pscustomobject]@{
        PackageId   = $PackageId
        Installed   = $false
        PreExisting = [bool]$status.Installed
    }

    if ($outcome.PreExisting -and -not $Force) {
        Write-Verbose "已安装（Vega 之外的实例），跳过：$PackageId"
        return $outcome
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'winget install')) { return $outcome }

    $arguments = @(
        'install', '--id', $PackageId, '-e', '--source', 'winget', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    )
    if ($Force) { $arguments += '--force' }

    $result = Invoke-VegaWinget -ArgumentList $arguments -TimeoutSeconds 1800
    if ($result.ExitCode -ne 0) {
        throw "安装 $DisplayName 失败（winget 退出码 $($result.ExitCode)）。可手动执行：winget install --id $PackageId -e --source winget"
    }

    $outcome.Installed = $true
    return $outcome
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
# 状态清单
# ---------------------------------------------------------------------------
# 两种清单，互不相通：
#   被控端（管理员）：%ProgramData%\Vega\host-state.json
#     目录创建时禁用继承，只给 Administrators + SYSTEM 完全控制；
#     读取前校验目录与文件所有者、拒绝重解析点，不满足直接拒绝。
#   主控端（非管理员）：%LOCALAPPDATA%\Vega\client-state.json（天然按用户隔离）。
# 清单里的每条记录在执行回滚前都要过白名单（Test-VegaStateRecordAllowed），
# 只认 Vega 自己创建的对象；每一步变更立即写回，回滚结果也写回。

function Test-VegaWindowsPlatform {
    <#
      当前宿主是不是 Windows。非 Windows 只用于本地跑 Pester，
      没有 ACL/防火墙/服务，因此所有权校验在此平台上不适用。
    #>
    [CmdletBinding()]
    param()

    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Get-VegaHostStatePath {
    <#
      被控端（管理员）状态清单：%ProgramData%\Vega\host-state.json
    #>
    [CmdletBinding()]
    param()

    $root = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $root 'Vega') 'host-state.json')
}

function Get-VegaClientStatePath {
    <#
      主控端（非管理员）状态清单：%LOCALAPPDATA%\Vega\client-state.json
    #>
    [CmdletBinding()]
    param()

    $root = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $root 'Vega') 'client-state.json')
}

function Get-VegaStatePath {
    <#
      兼容旧调用：等价于被控端清单路径。
    #>
    [CmdletBinding()]
    param()

    return (Get-VegaHostStatePath)
}

function Get-VegaLegacyStatePath {
    <#
      旧版（v0.1）清单路径：%ProgramData%\Vega\state.json。只用于检测，不读取内容。
    #>
    [CmdletBinding()]
    param()

    $root = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $root 'Vega') 'state.json')
}

function Write-VegaLegacyStateWarning {
    <#
      检测到旧清单时打印警告，返回 $true。
      不读取旧文件内容：旧版记录没有新的归属/白名单字段，不能拿来回滚。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path = (Get-VegaLegacyStatePath)
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    }
    catch {
        return $false
    }

    # 新版管理员清单也用 %ProgramData%\Vega\state.json 记录 LocalService 的 RustDesk
    # 受管键；带 SchemaVersion >= 2 的文件不是 v0.1 旧清单，不能误报。
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $data = $raw | ConvertFrom-Json
            if ($null -ne $data -and $null -ne $data.PSObject.Properties['SchemaVersion'] -and [int]$data.SchemaVersion -ge 2) {
                return $false
            }
        }
    }
    catch {
        # 解析失败按旧清单处理：只警告，不读取内容回滚。
        Write-Verbose "读取状态清单 $Path 失败，按旧版清单处理：$($_.Exception.Message)"
    }

    Write-VegaStatus ("检测到旧版状态清单：{0}。旧版记录不会自动迁移；卸载时请手动检查 Sunshine 配置。" -f $Path) -Level Warn
    return $true
}

function Test-VegaManagedHostStatePath {
    <#
      是否是被控端机器级清单（%ProgramData%\Vega\host-state.json）。
      只有机器级清单才强制所有权校验；测试/诊断用的临时路径不校验所有者。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $expected = Get-VegaHostStatePath
    try {
        return ([System.IO.Path]::GetFullPath($Path) -eq [System.IO.Path]::GetFullPath($expected))
    }
    catch {
        return ($Path -eq $expected)
    }
}

function Test-VegaManagedServiceStatePath {
    <#
      是否是服务模式记录专用的管理员清单（%ProgramData%\Vega\state.json）。
      用户可写的 client-state.json 永远不匹配这个路径。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $expected = Get-VegaRustDeskServiceStatePath
    try {
        return ([System.IO.Path]::GetFullPath($Path) -eq [System.IO.Path]::GetFullPath($expected))
    }
    catch {
        return ($Path -eq $expected)
    }
}

function Test-VegaManagedStatePath {
    <#
      是否需要按机器级清单对待：host-state.json 或服务模式 state.json。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    return ((Test-VegaManagedHostStatePath -Path $Path) -or (Test-VegaManagedServiceStatePath -Path $Path))
}

function Test-VegaReparsePoint {
    <#
      路径是否是重解析点/符号链接。读不到元数据时按“可疑”处理。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path
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

function Get-VegaPathOwnerSid {
    <#
      返回路径所有者的 SID 字符串；取不到返回空串。
      用 SID 而不是名字比较，避免本地化系统里 "Administrators" 名字不同。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-VegaWindowsPlatform)) { return '' }

    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        return ''
    }

    $owner = [string]$acl.Owner
    if ([string]::IsNullOrWhiteSpace($owner)) { return '' }
    if ($owner -match '^S-1-') { return $owner }

    try {
        $account = New-Object System.Security.Principal.NTAccount($owner)
        return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return ''
    }
}

function Test-VegaStatePathTrusted {
    <#
      目录与清单文件必须是 Administrators（S-1-5-32-544）或 SYSTEM（S-1-5-18）
      所有，且都不是重解析点，否则拒绝使用。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $allowedOwnerSids = @('S-1-5-32-544', 'S-1-5-18')

    if (Test-VegaReparsePoint -Path $Path) { return $false }

    $directory = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrWhiteSpace($directory)) { return $false }
    # 目录还不存在：由 Initialize-VegaStateDirectory 创建并设 ACL
    if (-not (Test-Path -LiteralPath $directory)) { return $true }
    if (Test-VegaReparsePoint -Path $directory) { return $false }

    if (-not (Test-VegaWindowsPlatform)) { return $true }

    foreach ($target in @($directory, $Path)) {
        if (-not (Test-Path -LiteralPath $target)) { continue }
        $sid = Get-VegaPathOwnerSid -Path $target
        if ($allowedOwnerSids -notcontains $sid) { return $false }
    }

    return $true
}

function Initialize-VegaStateDirectory {
    <#
      建立清单目录并收紧 ACL：禁用继承，只留 Administrators + SYSTEM 完全控制，
      所有者设为 Administrators。任何一步失败都抛异常（调用方据此中止）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $directory = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrWhiteSpace($directory)) { throw "状态清单路径无效：$Path" }

    if (Test-Path -LiteralPath $directory) {
        if (Test-VegaReparsePoint -Path $directory) { throw "状态目录是重解析点，拒绝使用：$directory" }
    }
    else {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }

    if (-not (Test-VegaWindowsPlatform)) { return $directory }

    try {
        $administrators = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')

        $acl = Get-Acl -LiteralPath $directory -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRule($rule) }
        foreach ($sid in @($system, $administrators)) {
            $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
            $null = $acl.AddAccessRule($accessRule)
        }
        $acl.SetOwner($administrators)
        Set-Acl -LiteralPath $directory -AclObject $acl -ErrorAction Stop
    }
    catch {
        throw "无法为状态目录设置 Administrators/SYSTEM 专用 ACL：$directory（$($_.Exception.Message)）"
    }

    return $directory
}

function Get-VegaEmptyState {
    <#
      空清单。所有集合都是数组，便于 JSON 往返。
    #>
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        SchemaVersion         = 2
        UpdatedAt             = ''
        Packages              = @()
        FirewallRules         = @()
        DisabledFirewallRules = @()
        Services              = @()
        ManagedConfigKeys     = @()
        RustDeskConfigKeys    = @()
        RustDeskInstalls      = @()
    }
}

function Read-VegaState {
    <#
      读取清单；文件不存在返回空清单。
      机器级清单（%ProgramData%\Vega\host-state.json）先校验目录/文件所有者与
      重解析点，不满足直接抛异常——管理员绝不信任低权限侧能写的路径。
      文件损坏按空清单处理（不回滚任何东西，比乱删安全）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $state = Get-VegaEmptyState

    $managedHost = Test-VegaManagedHostStatePath -Path $Path
    $managedService = Test-VegaManagedServiceStatePath -Path $Path
    if ($managedHost -or $managedService) {
        if (-not (Test-VegaStatePathTrusted -Path $Path)) {
            throw "状态清单不可信（目录/文件所有者不是 Administrators/SYSTEM 或是重解析点），拒绝读取：$Path"
        }
    }
    elseif (Test-VegaReparsePoint -Path $Path) {
        throw "状态清单是重解析点，拒绝读取：$Path"
    }

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
    $hasSchemaVersion = ($properties -contains 'SchemaVersion')
    if ($hasSchemaVersion) { $state.SchemaVersion = [int]$data.SchemaVersion }

    # %ProgramData%\Vega\state.json 在 v0.1 是旧版清单，没有 SchemaVersion。
    # 只有 SchemaVersion >= 2 的才是本版的服务模式记录；旧文件不读取、不回滚。
    if ($managedService -and (-not $hasSchemaVersion -or $state.SchemaVersion -lt 2)) {
        return (Get-VegaEmptyState)
    }
    foreach ($name in @('Packages', 'FirewallRules', 'DisabledFirewallRules', 'Services', 'ManagedConfigKeys', 'RustDeskConfigKeys', 'RustDeskInstalls')) {
        if ($properties -contains $name) { $state.$name = @($data.$name) }
    }

    return $state
}

function Test-VegaLegacyStateFile {
    <#
      文件是否是 v0.1 旧清单：存在、但不是 SchemaVersion >= 2 的新清单。
      空文件或解析失败也按旧清单处理（只归档，不读取内容回滚）。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    }
    catch {
        return $false
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $true }
        $data = $raw | ConvertFrom-Json
        if ($null -ne $data -and $null -ne $data.PSObject.Properties['SchemaVersion'] -and [int]$data.SchemaVersion -ge 2) {
            return $false
        }
        return $true
    }
    catch {
        return $true
    }
}

function Get-VegaLegacyStateBackupPath {
    <#
      v0.1 清单归档路径：同目录 state.v0.1.bak.json；已存在时加时间戳，不覆盖旧归档。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $directory = Split-Path -Path $Path -Parent
    $candidate = Join-Path $directory 'state.v0.1.bak.json'
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $timed = Join-Path $directory ("state.v0.1.bak.{0}.json" -f $stamp)
    $suffix = 1
    while (Test-Path -LiteralPath $timed) {
        $timed = Join-Path $directory ("state.v0.1.bak.{0}-{1}.json" -f $stamp, $suffix)
        $suffix++
    }
    return $timed
}

function Backup-VegaLegacyStateFile {
    <#
      写新清单前把旧 schema（v0.1）的服务清单原子复制成 state.v0.1.bak.json。
      不是旧清单返回空串；复制失败抛异常，绝不覆盖唯一的旧清单。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-VegaLegacyStateFile -Path $Path)) { return '' }

    $directory = Split-Path -Path $Path -Parent
    $destination = Get-VegaLegacyStateBackupPath -Path $Path
    $tempPath = Join-Path $directory ('.vega-legacy-' + [System.Guid]::NewGuid().ToString('N') + '.tmp')

    try {
        [System.IO.File]::Copy($Path, $tempPath, $true)
        try {
            [System.IO.File]::Move($tempPath, $destination)
        }
        catch {
            # 同一时间戳下并发创建：换一个带序号的名字再试一次。
            $destination = Get-VegaLegacyStateBackupPath -Path $Path
            [System.IO.File]::Move($tempPath, $destination)
        }
    }
    catch {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        throw "归档旧版状态清单失败，拒绝写入新清单：$Path（$($_.Exception.Message)）"
    }

    return $destination
}

function Write-VegaState {
    <#
      原子写出清单（UTF-8 无 BOM）。机器级清单先建受信目录。
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

    if (Test-VegaManagedStatePath -Path $Path) {
        $null = Initialize-VegaStateDirectory -Path $Path
    }

    # 服务模式清单路径在 v0.1 也叫 state.json：先原子归档旧清单，再写新 schema。
    if (Test-VegaManagedServiceStatePath -Path $Path) {
        $backupPath = Backup-VegaLegacyStateFile -Path $Path
        if (-not [string]::IsNullOrWhiteSpace($backupPath)) {
            Write-Warning "检测到旧版（v0.1）状态清单，已归档为：$backupPath"
        }
    }

    $null = Write-VegaTextFileAtomic -Path $Path -Text $json
    return $Path
}

function Save-VegaState {
    <#
      逐项持久化：每次改动清单后立刻调用，测试里只 mock 这一个点。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Write-VegaState -State $State -Path $Path -Confirm:$false)
}

# ---------------------------------------------------------------------------
# 白名单：清单记录只能指向 Vega 自己创建的对象
# ---------------------------------------------------------------------------

function Get-VegaAllowedFirewallRuleName {
    [CmdletBinding()]
    param()

    return @('Vega-Sunshine-TCP', 'Vega-Sunshine-UDP', 'Vega-Block-Admin')
}

function Get-VegaAllowedServiceName {
    [CmdletBinding()]
    param()

    return @('SunshineService', 'sunshinesvc')
}

function Get-VegaAllowedPackageId {
    [CmdletBinding()]
    param()

    return @(
        'LizardByte.Sunshine',
        'Tailscale.Tailscale',
        'MoonlightGameStreamingProject.Moonlight'
    )
}

function Test-VegaRetiredPackageId {
    <#
      已下线的 winget 包 ID：Legacy 清单里可能仍记录着 RustDesk.RustDesk。
      WinGet 社区源已移除 RustDesk，旧记录不能当成白名单外对象报错；
      调用方应提示用户手动卸载并把这笔记录销账（审计 r5 P2）。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$PackageId
    )

    return [string]::Equals($PackageId, 'RustDesk.RustDesk', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-VegaStateRecordAllowed {
    <#
      纯函数：回滚前逐条校验。
        FirewallRule - 只能是 Vega 建的那几条规则名
        Service      - 只能是 SunshineService / sunshinesvc
        ConfigPath   - 只能指向 Sunshine 安装目录下的 config\sunshine.conf
        Package      - 只能是已知 3 个包 ID
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('FirewallRule', 'Service', 'ConfigPath', 'Package')]
        [string]$Kind,

        [AllowEmptyString()]
        [string]$Value,

        [AllowEmptyString()]
        [string]$SunshineDirectory = ''
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }

    switch ($Kind) {
        'FirewallRule' { return ((Get-VegaAllowedFirewallRuleName) -contains $Value) }
        'Service' { return ((Get-VegaAllowedServiceName) -contains $Value) }
        'Package' { return ((Get-VegaAllowedPackageId) -contains $Value) }
        'ConfigPath' {
            try {
                $leaf = [System.IO.Path]::GetFileName($Value)
                $parent = [System.IO.Path]::GetDirectoryName($Value)
                if ($leaf -ne 'sunshine.conf') { return $false }
                if ([System.IO.Path]::GetFileName($parent) -ne 'config') { return $false }
                if ([string]::IsNullOrWhiteSpace($SunshineDirectory)) { return $true }
                $expected = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $SunshineDirectory 'config') 'sunshine.conf'))
                $actual = [System.IO.Path]::GetFullPath($Value)
                return ($expected -eq $actual)
            }
            catch {
                return $false
            }
        }
        default { return $false }
    }
}

# ---------------------------------------------------------------------------
# 清单编辑 + 互斥
# ---------------------------------------------------------------------------

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

function Remove-VegaStateFirewallRule {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $PSCmdlet.ShouldProcess($Name, '从状态清单移除防火墙规则')) { return $State }

    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($State.FirewallRules)) {
        if ($null -eq $item) { continue }
        if ([string]$item.Name -eq $Name) { continue }
        $kept.Add($item)
    }
    $State.FirewallRules = $kept.ToArray()
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

function Remove-VegaStateDisabledFirewallRule {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $PSCmdlet.ShouldProcess($Name, '从状态清单移除已禁用防火墙规则')) { return $State }

    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($State.DisabledFirewallRules)) {
        if ($null -eq $item) { continue }
        if ([string]$item.Name -eq $Name) { continue }
        $kept.Add($item)
    }
    $State.DisabledFirewallRules = $kept.ToArray()
    return $State
}

function Get-VegaStateService {
    <#
      返回记录的服务条目；没有记录返回 $null。
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
        if ([string]$entry.Name -eq $Name) { return $entry }
    }
    return $null
}

function Add-VegaStateService {
    <#
      只在第一次记录服务的原始启动类型与运行状态；重跑不覆盖基线。
      例外：条目已经被标记 Restored（卸载恢复过），说明旧基线已经消费掉，
      新一轮安装要重新采集基线并改回待恢复，否则这次安装的改动卸载时没人管。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$StartType,

        [string]$Status = ''
    )

    $existing = Get-VegaStateService -State $State -Name $Name
    if ($null -ne $existing) {
        if ($null -ne $existing.PSObject.Properties['Restored'] -and [bool]$existing.Restored) {
            $existing | Add-Member -NotePropertyName OriginalStartType -NotePropertyValue $StartType -Force
            $existing | Add-Member -NotePropertyName OriginalStatus -NotePropertyValue $Status -Force
            $existing | Add-Member -NotePropertyName Restored -NotePropertyValue $false -Force
        }
        return $State
    }

    $State.Services = @(@($State.Services) + [pscustomobject]@{
            Name              = $Name
            OriginalStartType = $StartType
            OriginalStatus    = $Status
            Restored          = $false
        })
    return $State
}

function Set-VegaStateServiceRestored {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Name,

        [bool]$Restored = $true
    )

    if (-not $PSCmdlet.ShouldProcess($Name, '标记服务已恢复')) { return $State }

    foreach ($entry in @($State.Services)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.Name -ne $Name) { continue }
        if ($null -eq $entry.PSObject.Properties['Restored']) {
            $entry | Add-Member -NotePropertyName Restored -NotePropertyValue $Restored -Force
        }
        else {
            $entry.Restored = $Restored
        }
        break
    }
    return $State
}

function Add-VegaStateManagedKey {
    <#
      首次安装时记录受管键的原值（不存在则记 Existed = $false）。
      同一个路径+键只记第一次，重跑不会覆盖基线。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Snapshot
    )

    $known = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($State.ManagedConfigKeys)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.Path -eq $Path) { $null = $known.Add([string]$entry.Key) }
    }

    foreach ($key in $Snapshot.Keys) {
        $keyText = [string]$key
        if ($known.Contains($keyText)) { continue }
        $item = $Snapshot[$key]
        # 快照可以来自 Get-VegaConfigKeySnapshot（带 OriginalValue）或旧调用方（只有 Value）
        $originalValue = [string]$item.Value
        if ($null -ne $item.PSObject.Properties['OriginalValue']) {
            $originalValue = [string]$item.OriginalValue
        }
        $State.ManagedConfigKeys = @(@($State.ManagedConfigKeys) + [pscustomobject]@{
                Path          = $Path
                Key           = $keyText
                Existed       = [bool]$item.Existed
                OriginalValue = $originalValue
                Restored      = $false
            })
    }

    return $State
}

function Get-VegaStateManagedKey {
    <#
      返回某个配置路径下的受管键记录（含尚未成功回滚的）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [AllowEmptyString()]
        [string]$Path = ''
    )

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($State.ManagedConfigKeys)) {
        if ($null -eq $entry) { continue }
        if (-not [string]::IsNullOrWhiteSpace($Path) -and [string]$entry.Path -ne $Path) { continue }
        $result.Add($entry)
    }
    return $result.ToArray()
}

function Set-VegaStateManagedKeyRestored {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Key,

        [bool]$Restored = $true
    )

    if (-not $PSCmdlet.ShouldProcess("$Path :: $Key", '标记受管配置键已回滚')) { return $State }

    foreach ($entry in @($State.ManagedConfigKeys)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.Path -ne $Path -or [string]$entry.Key -ne $Key) { continue }
        if ($null -eq $entry.PSObject.Properties['Restored']) {
            $entry | Add-Member -NotePropertyName Restored -NotePropertyValue $Restored -Force
        }
        else {
            $entry.Restored = $Restored
        }
        break
    }
    return $State
}

function Add-VegaStateRustDeskKey {
    <#
      首次写 RustDesk2.toml 前记录受管键的原值。
      与 Sunshine 的受管键分开放：两者的配置语法不同，回滚逻辑也不同。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Snapshot
    )

    $known = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($State.RustDeskConfigKeys)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.Path -eq $Path) { $null = $known.Add([string]$entry.Key) }
    }

    foreach ($key in $Snapshot.Keys) {
        $keyText = [string]$key
        $item = $Snapshot[$key]
        $originalValue = [string]$item.Value
        if ($null -ne $item.PSObject.Properties['OriginalValue']) {
            $originalValue = [string]$item.OriginalValue
        }

        if ($known.Contains($keyText)) {
            # 上一轮卸载已经恢复过的记录，旧基线已经消费掉：重新安装时
            # 重新采集基线并重置 Restored，否则这次改动卸载时没人回滚。
            foreach ($entry in @($State.RustDeskConfigKeys)) {
                if ($null -eq $entry) { continue }
                if ([string]$entry.Path -ne $Path) { continue }
                if (-not [string]::Equals([string]$entry.Key, $keyText, [StringComparison]::OrdinalIgnoreCase)) { continue }
                if ($null -eq $entry.PSObject.Properties['Restored'] -or -not [bool]$entry.Restored) { break }
                $entry | Add-Member -NotePropertyName Existed -NotePropertyValue ([bool]$item.Existed) -Force
                $entry | Add-Member -NotePropertyName OriginalValue -NotePropertyValue $originalValue -Force
                $entry | Add-Member -NotePropertyName Restored -NotePropertyValue $false -Force
                break
            }
            continue
        }

        $State.RustDeskConfigKeys = @(@($State.RustDeskConfigKeys) + [pscustomobject]@{
                Path          = $Path
                Key           = $keyText
                Existed       = [bool]$item.Existed
                OriginalValue = $originalValue
                Restored      = $false
            })
    }

    return $State
}

function Get-VegaStateRustDeskKey {
    <#
      返回某个 RustDesk2.toml 路径下的受管键记录。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [AllowEmptyString()]
        [string]$Path = ''
    )

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($State.RustDeskConfigKeys)) {
        if ($null -eq $entry) { continue }
        if (-not [string]::IsNullOrWhiteSpace($Path) -and [string]$entry.Path -ne $Path) { continue }
        $result.Add($entry)
    }
    return $result.ToArray()
}

function Set-VegaStateRustDeskKeyRestored {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Key,

        [bool]$Restored = $true
    )

    if (-not $PSCmdlet.ShouldProcess("$Path :: $Key", '标记 RustDesk 配置键已回滚')) { return $State }

    foreach ($entry in @($State.RustDeskConfigKeys)) {
        if ($null -eq $entry) { continue }
        if ([string]$entry.Path -ne $Path -or [string]$entry.Key -ne $Key) { continue }
        if ($null -eq $entry.PSObject.Properties['Restored']) {
            $entry | Add-Member -NotePropertyName Restored -NotePropertyValue $Restored -Force
        }
        else {
            $entry.Restored = $Restored
        }
        break
    }
    return $State
}

function Add-VegaStateRustDeskInstall {
    <#
      记录“这次 RustDesk 是 Vega 装的”：卸载时据此决定是否连同 RustDesk 一起卸载。
      用户自己先装好的 RustDesk 不登记，卸载只回滚配置。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Path,

        [AllowEmptyString()]
        [string]$Version = '',

        [bool]$InstalledByVega = $true
    )

    $State.RustDeskInstalls = @(@($State.RustDeskInstalls) + [pscustomobject]@{
            Path            = $Path
            Version         = $Version
            InstalledByVega = $InstalledByVega
            InstalledAt     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        })
    return $State
}

function Get-VegaStateRustDeskInstall {
    <#
      返回 RustDesk 安装记录（可按路径过滤）。没有记录返回空数组。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [AllowEmptyString()]
        [string]$Path = ''
    )

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($State.RustDeskInstalls)) {
        if ($null -eq $entry) { continue }
        if (-not [string]::IsNullOrWhiteSpace($Path) -and [string]$entry.Path -ne $Path) { continue }
        $result.Add($entry)
    }
    return $result.ToArray()
}

function Remove-VegaStateRustDeskInstall {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not $PSCmdlet.ShouldProcess($Path, '删除 RustDesk 安装记录')) { return $State }

    $State.RustDeskInstalls = @(@($State.RustDeskInstalls) | Where-Object {
            $null -ne $_ -and [string]($_.Path) -ne $Path
        })
    return $State
}

function Enter-VegaSetupLock {
    <#
      安装与卸载共用同一把命名互斥体，避免两个进程同时改系统。
      拿不到锁抛异常；当前平台不支持命名互斥体时返回 $null（不阻塞）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, $Name)
    }
    catch {
        Write-Verbose "无法创建命名互斥体 ${Name}：$($_.Exception.Message)"
        return $null
    }

    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }
    catch {
        $mutex.Dispose()
        return $null
    }

    if (-not $acquired) {
        $mutex.Dispose()
        throw "另一个 Vega 安装/卸载进程正在运行（互斥体 $Name）。等它结束后重试。"
    }

    return $mutex
}

function Exit-VegaSetupLock {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Lock
    )

    if ($null -eq $Lock) { return }
    try { $Lock.ReleaseMutex() }
    catch { $null = $_ }
    try { $Lock.Dispose() }
    catch { $null = $_ }
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
      只认小写键名：Sunshine 的配置键大小写敏感，PORT / Port 这类键
      对 Sunshine 无效，Vega 也就不能把它们当成 port 来读。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    # 显式用 Ordinal 比较器：PowerShell 的 [ordered]@{} 默认大小写不敏感，
    # 会让 PORT 被当成 port，和 Sunshine 的行为不一致。
    $values = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    if ([string]::IsNullOrEmpty($Text)) { return $values }

    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -match '^\s*#') { continue }
        if ($line -cmatch '^\s*(?<key>[a-z0-9_]+)\s*=\s*(?<value>.*)$') {
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
      键名大小写敏感，只匹配小写键（与 Sunshine 一致）。
      $RemoveKeys 里的键整行删除（按键回滚时“原文里本来没有”的键）。
      返回以单个换行结尾的文本。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExistingText,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Values,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$RemoveKeys = @()
    )

    $remove = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($removeKey in @($RemoveKeys)) {
        if ([string]::IsNullOrWhiteSpace($removeKey)) { continue }
        $null = $remove.Add([string]$removeKey)
    }

    $existingLines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($ExistingText)) {
        foreach ($line in ($ExistingText -split "\r?\n")) { $existingLines.Add($line) }
        while ($existingLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($existingLines[$existingLines.Count - 1])) {
            $existingLines.RemoveAt($existingLines.Count - 1)
        }
    }

    $written = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $output = New-Object System.Collections.Generic.List[string]

    foreach ($line in $existingLines) {
        $key = $null
        if ($line -cmatch '^\s*(?<key>[a-z0-9_]+)\s*=') { $key = $Matches['key'] }

        if ($null -ne $key -and $remove.Contains($key)) { continue }

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
      同目录临时文件 + 原子替换；不生成任何 .bak——回滚靠清单里按键记录的原值。
      返回写入路径。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    if ($PSCmdlet.ShouldProcess($Path, '写入 Sunshine 配置')) {
        $null = Write-VegaTextFileAtomic -Path $Path -Text $Content
    }

    return $Path
}

function Get-VegaConfigKeySnapshot {
    <#
      纯函数：从原始配置文本读出受管键的基线。
      键存在记 Existed = $true 与原值；不存在记 Existed = $false。
      卸载时按这份基线按键回滚，用户改过的其他键不会被牵连。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Keys
    )

    $values = ConvertFrom-VegaSunshineConfigText -Text $Text
    $snapshot = [ordered]@{}

    foreach ($key in @($Keys)) {
        $keyText = [string]$key
        if ([string]::IsNullOrWhiteSpace($keyText)) { continue }
        if ($values.Contains($keyText)) {
            $snapshot[$keyText] = [pscustomobject]@{
                Key           = $keyText
                Existed       = $true
                Value         = [string]$values[$keyText]
                OriginalValue = [string]$values[$keyText]
            }
        }
        else {
            $snapshot[$keyText] = [pscustomobject]@{
                Key           = $keyText
                Existed       = $false
                Value         = ''
                OriginalValue = ''
            }
        }
    }

    return $snapshot
}

function Restore-VegaManagedConfig {
    <#
      卸载用：只把清单记录的受管键恢复为首次安装前的原值；当时不存在的键整行删除。
      其他键、注释、用户后来加的内容原样保留，不再整文件替换、也不读任何 .bak。
      返回 { Restored, Changed, Message }。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Records
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Restored = $false; Changed = $false; Message = "配置不存在，跳过按键回滚：$Path" }
    }

    $values = [ordered]@{}
    $remove = New-Object System.Collections.Generic.List[string]
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $key = [string]$record.Key
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ([bool]$record.Existed) {
            # 清单记录用 OriginalValue；Get-VegaConfigKeySnapshot 的快照记录用 Value。
            # 只认 OriginalValue 会让快照回滚把键值写成空串。
            $originalValue = ''
            if ($null -ne $record.PSObject.Properties['OriginalValue']) {
                $originalValue = [string]$record.OriginalValue
            }
            elseif ($null -ne $record.PSObject.Properties['Value']) {
                $originalValue = [string]$record.Value
            }
            $values[$key] = $originalValue
        }
        else { $remove.Add($key) }
    }

    if ($values.Count -eq 0 -and $remove.Count -eq 0) {
        return [pscustomobject]@{ Restored = $true; Changed = $false; Message = "没有受管键需要回滚：$Path" }
    }

    $current = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $merged = Merge-VegaSunshineConfigText -ExistingText $current -Values $values -RemoveKeys $remove.ToArray()
    if ($merged -eq $current) {
        return [pscustomobject]@{ Restored = $true; Changed = $false; Message = "受管键已是原始值：$Path" }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, '按键回滚 Sunshine 配置')) {
        return [pscustomobject]@{ Restored = $false; Changed = $false; Message = "跳过按键回滚：$Path" }
    }

    $null = Write-VegaTextFileAtomic -Path $Path -Text $merged
    return [pscustomobject]@{ Restored = $true; Changed = $true; Message = "已把受管键恢复为原始值：$Path" }
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

function Get-VegaSunshineServiceSnapshot {
    <#
      安装/重装前采集 Sunshine 服务的启动类型与运行状态。
      服务不存在也记一条 StartType = 'NotPresent'：卸载时据此什么都不做，
      不会去恢复一个本来就不存在的服务。
    #>
    [CmdletBinding()]
    param()

    $snapshot = New-Object System.Collections.Generic.List[object]
    foreach ($name in (Get-VegaAllowedServiceName)) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            $snapshot.Add([pscustomobject]@{
                    Name      = $name
                    StartType = 'NotPresent'
                    Status    = 'NotPresent'
                })
            continue
        }

        $snapshot.Add([pscustomobject]@{
                Name      = $name
                StartType = [string]$service.StartType
                Status    = [string]$service.Status
            })
    }

    return $snapshot.ToArray()
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
        Write-Verbose "设置服务 $Name 启动类型失败：$($_.Exception.Message)"
        return $false
    }

    $actual = ''
    try { $actual = [string](Get-Service -Name $Name -ErrorAction Stop).StartType }
    catch { $actual = '' }

    return ($actual -eq $StartupType)
}

function Restore-VegaSunshineServiceState {
    <#
      卸载用：只恢复清单记录的启动类型与运行状态，不无条件 Stop。
      安装时记录的是 Running 就保证它 Running；记录的是 Stopped 才停。
      没记录运行状态时不碰运行状态。每一步都回读确认，失败返回 Success = $false。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$StartType,

        [AllowEmptyString()]
        [string]$OriginalStatus = ''
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return [pscustomobject]@{ Success = $true; Message = "服务已不存在，无需恢复：$Name" }
    }

    if (-not $PSCmdlet.ShouldProcess($Name, "恢复启动类型 $StartType 与运行状态 $OriginalStatus")) {
        return [pscustomobject]@{ Success = $false; Message = "已跳过（WhatIf）：$Name" }
    }

    if (-not (Set-VegaSunshineServiceStartType -Name $Name -StartupType $StartType -Confirm:$false)) {
        return [pscustomobject]@{ Success = $false; Message = "恢复服务启动类型失败：$Name → $StartType" }
    }

    $wanted = [string]$OriginalStatus
    if ($wanted -notin @('Running', 'Stopped')) {
        return [pscustomobject]@{
            Success = $true
            Message = "服务 $Name 已恢复启动类型 $StartType（未记录原运行状态，运行状态未改动）"
        }
    }

    try {
        $current = [string](Get-Service -Name $Name -ErrorAction Stop).Status
        if ($wanted -eq 'Running' -and $current -ne 'Running') {
            Start-Service -Name $Name -ErrorAction Stop
        }
        elseif ($wanted -eq 'Stopped' -and $current -ne 'Stopped') {
            Stop-Service -Name $Name -Force -ErrorAction Stop
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Message = "恢复服务运行状态失败：$Name → $wanted（$($_.Exception.Message)）" }
    }

    $actual = ''
    try { $actual = [string](Get-Service -Name $Name -ErrorAction Stop).Status }
    catch { $actual = '' }
    if ($actual -ne $wanted) {
        return [pscustomobject]@{ Success = $false; Message = "服务状态回读是 $actual，期望 $wanted：$Name" }
    }

    return [pscustomobject]@{ Success = $true; Message = "服务 $Name 已恢复启动类型 $StartType、运行状态 $wanted" }
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

function Get-VegaSunshinePortMap {
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

function Get-VegaSunshineRawValue {
    <#
      纯函数：按行读取指定键的原始值（不 Trim），同名键以第一次出现为准。
      端口预检必须看原始文本：裁剪后的值会掩盖“行尾空格 / 引号内空格”这类
      与上游解析不一致的格式，导致 Vega 阻断错误的管理端口。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Key
    )

    if ([string]::IsNullOrEmpty($Text)) { return $null }
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }

    $pattern = '^\s*(?<key>' + [regex]::Escape($Key) + ')\s*=(?<value>.*)$'
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -cmatch $pattern) { return [string]$Matches['value'] }
    }
    return $null
}

function ConvertFrom-VegaSunshinePortValue {
    <#
      纯函数：严格解析 sunshine.conf 的 port 原始值，只接受纯十进制。
      各步规则：
        - 行尾 # 注释先去掉；注释前若有空格（即去掉注释后残留行尾空格）中止；
        - 没有注释时，行尾空格同样中止（与上游的十进制转换结果不可靠一致）；
        - 行首空白可以忽略（十进制转换本身会跳过）；
        - 只剥离成对双引号，引号内有空白中止；单引号不剥离；
        - 十六进制（0x / 0X）、前导 +、其他格式一律中止，提示改成纯十进制；
        - 有效范围 1019-65514。
      返回 $null 表示无法可靠确定端口，由调用方中止并提示用户。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $text = [string]$Value
    $commentIndex = $text.IndexOf('#')
    $hasComment = ($commentIndex -ge 0)
    if ($hasComment) { $text = $text.Substring(0, $commentIndex) }

    # 行首空白：十进制转换会跳过，可以接受；行尾空白（含注释前的空格）不接受。
    $text = $text.TrimStart()
    if ($text.Length -eq 0) { return $null }
    if ([char]::IsWhiteSpace($text[$text.Length - 1])) { return $null }

    if ($text.Length -ge 2 -and $text[0] -eq '"' -and $text[$text.Length - 1] -eq '"') {
        $inner = $text.Substring(1, $text.Length - 2)
        if ($inner.Length -eq 0) { return $null }
        if ($inner -match '\s') { return $null }
        $text = $inner
    }

    if ($text -notmatch '^[0-9]+$') { return $null }

    $port = 0
    if (-not [int]::TryParse($text, [ref]$port)) { return $null }
    if ($port -lt 1019 -or $port -gt 65514) { return $null }
    return $port
}

function Get-VegaSunshineBasePort {
    <#
      从生效的 sunshine.conf 读 port 原始值；读不到文件或没有 port 键时用默认 47989。
      值存在但格式无法与上游一致确定时抛出异常中止，不再静默回退默认值——
      否则 Vega 会阻断错误的管理端口，把真实管理页暴露出去。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$ConfigPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { return 47989 }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return 47989 }

    $text = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    $raw = Get-VegaSunshineRawValue -Text $text -Key 'port'
    if ($null -eq $raw) { return 47989 }

    $port = ConvertFrom-VegaSunshinePortValue -Value $raw
    if ($null -eq $port) {
        throw 'sunshine.conf 里的 port 无效：无法与上游一致地确定端口。请把 port 改成 1019-65514 的纯十进制（不加引号、不加行尾注释、行尾不留空格）后重试。'
    }

    return [int]$port
}

function Get-VegaFirewallRuleSpec {
    <#
      只放行串流端口（按生效配置计算）；管理端口不在列表里（管理页只允许本机访问）。
    #>
    [CmdletBinding()]
    param(
        [int]$BasePort = 47989
    )

    $ports = Get-VegaSunshinePortMap -BasePort $BasePort
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
      不盲信清单里的名字：Vega-* 永不恢复，规则必须现在还存在，
      且（给了安装目录时）程序路径必须是 Sunshine 目录下的 sunshine.exe。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Name,

        [AllowEmptyString()]
        [string]$SunshineExe = ''
    )

    $enabled = New-Object System.Collections.Generic.List[string]
    foreach ($ruleName in @($Name)) {
        if ([string]::IsNullOrWhiteSpace($ruleName)) { continue }
        if ($ruleName -like 'Vega-*') {
            Write-Warning "拒绝恢复 Vega 自己的规则：$ruleName"
            continue
        }

        $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($null -eq $rule) {
            Write-Warning "规则不存在，跳过：$ruleName"
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($SunshineExe)) {
            $program = ''
            try {
                $application = $rule | Get-NetFirewallApplicationFilter -ErrorAction Stop
                if ($null -ne $application) { $program = [string]$application.Program }
            }
            catch {
                $program = ''
            }
            if ([string]::IsNullOrWhiteSpace($program) -or $program -notmatch '(?i)\\sunshine\.exe$') {
                Write-Warning "规则 $ruleName 的程序不是 sunshine.exe，跳过"
                continue
            }
        }

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

function Remove-VegaFirewallRuleByName {
    <#
      按内部 Name 删除单条规则并回读确认。
      返回 $true 表示规则已不存在（删除成功或本来就没有）；删不掉返回 $false 并写警告。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-VegaFirewallRule -Name $Name)) { return $true }
    if (-not $PSCmdlet.ShouldProcess($Name, '删除防火墙规则')) { return $false }

    try {
        Remove-NetFirewallRule -Name $Name -ErrorAction Stop
    }
    catch {
        Write-Warning "删除防火墙规则 $Name 失败：$($_.Exception.Message)"
        return $false
    }

    if (Test-VegaFirewallRule -Name $Name) {
        Write-Warning "删除后规则仍存在：$Name"
        return $false
    }

    return $true
}

function Remove-VegaFirewallRule {
    <#
      批量删除，返回确认删除的条数（诊断/兼容用）。
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
        if (Remove-VegaFirewallRuleByName -Name $ruleName -Confirm:$false) { $removed++ }
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

function Test-VegaManagementPortConflict {
    <#
      纯函数：返回与 TCP 串流放行端口相交的管理端口。
      只比较 TCP：管理端口阻断规则是 TCP，UDP 串流端口同号不会冲突。
      相交意味着同一 TCP 端口既放行又阻断，配置自相矛盾，调用方应中止并提示改 port。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [int[]]$ManagementPorts,

        [int]$BasePort = 47989
    )

    $conflicts = New-Object System.Collections.Generic.List[int]
    if ($null -eq $ManagementPorts -or $ManagementPorts.Count -eq 0) { return $conflicts.ToArray() }

    $specs = @(Get-VegaFirewallRuleSpec -BasePort $BasePort | Where-Object { $_.Protocol -eq 'TCP' })
    foreach ($port in $ManagementPorts) {
        foreach ($spec in $specs) {
            if (Test-VegaPortInRange -Ports @($spec.LocalPort) -Port $port) {
                $conflicts.Add([int]$port)
                break
            }
        }
    }

    return $conflicts.ToArray()
}

function Set-VegaFirewallRule {
    <#
      先删后建，规则限定 Program 为 sunshine.exe 绝对路径、只开按生效配置算出的串流端口。
      创建后逐条核对，失败抛异常。返回创建成功的规则名。
      OnRuleCreated 在每条规则确认存在后立即调用，供调用方逐项写入状态清单——
      第二条创建失败时，第一条也不会漏记。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Program,

        [int]$BasePort = 47989,

        [scriptblock]$OnRuleCreated = $null
    )

    if (-not (Test-VegaAbsolutePath -Path $Program)) {
        throw "防火墙规则需要 sunshine.exe 的绝对路径，收到：$Program"
    }

    $ports = Get-VegaSunshinePortMap -BasePort $BasePort
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

        # 回读确认：规则已生效（Allow）、端口覆盖完整。确认之前不往下走，
        # 调用方要等这一步成功才去禁用 Sunshine 安装器的放行规则。
        $check = Get-NetFirewallRule -Name $spec.Name -PolicyStore ActiveStore -ErrorAction SilentlyContinue
        if ($null -eq $check) {
            throw "创建后未找到防火墙规则 $($spec.Name)"
        }
        if ([string]$check.Enabled -ne 'True' -or [string]$check.Action -ne 'Allow') {
            throw "防火墙规则 $($spec.Name) 状态异常（Enabled=$($check.Enabled)，Action=$($check.Action)）。"
        }

        # Profile 必须覆盖所有活动接口的配置文件（Any 视为覆盖），否则补齐后回读。
        $requiredProfiles = @(Get-VegaActiveFirewallProfile)
        $check = Repair-VegaFirewallRuleProfile -Name $spec.Name -Rule $check -RequiredProfiles $requiredProfiles -Confirm:$false

        # 串流放行规则也必须真的处于执行状态：ActiveStore 里存在但未执行的规则不算成功。
        $enforcementProperty = $check.PSObject.Properties['EnforcementStatus']
        if ($null -ne $enforcementProperty) {
            $enforcementValues = @($enforcementProperty.Value)
            if (-not (Test-VegaEnforcementStatus -Value $enforcementValues)) {
                $enforcement = ($enforcementValues | ForEach-Object { [string]$_ }) -join ','
                throw "防火墙规则 $($spec.Name) 未被强制执行（EnforcementStatus=$enforcement），拒绝继续。"
            }
        }

        $filter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $check -ErrorAction SilentlyContinue
        if ($null -eq $filter) {
            throw "无法读取防火墙规则 $($spec.Name) 的端口过滤器。"
        }
        $actualPorts = @($filter.LocalPort | ForEach-Object { [string]$_ })
        foreach ($portSpec in @($spec.LocalPort)) {
            if ($portSpec -match '^(?<start>[0-9]+)-(?<end>[0-9]+)$') {
                if (-not (Test-VegaPortInRange -Ports $actualPorts -Port ([int]$Matches['start'])) -or
                    -not (Test-VegaPortInRange -Ports $actualPorts -Port ([int]$Matches['end']))) {
                    throw "防火墙规则 $($spec.Name) 未覆盖端口段 $portSpec（实际：$($actualPorts -join ',')）。"
                }
                continue
            }
            if (-not (Test-VegaPortInRange -Ports $actualPorts -Port ([int]$portSpec))) {
                throw "防火墙规则 $($spec.Name) 未覆盖端口 $portSpec（实际：$($actualPorts -join ',')）。"
            }
        }
        $created.Add($spec.Name)
        if ($null -ne $OnRuleCreated) { & $OnRuleCreated $spec.Name }
    }

    return $created.ToArray()
}

function Select-VegaLegacyFirewallRule {
    <#
      纯函数：挑出 v0.1 留下的旧规则。旧版只设了 DisplayName = Vega-Sunshine-TCP/UDP，
      Windows 自己生成了内部 Name，所以必须按 DisplayName 匹配、按内部 Name 删除。
      已经是对应内部名称的规则不算旧规则。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rules
    )

    $legacyNames = Get-VegaAllowedFirewallRuleName | Where-Object { $_ -like 'Vega-Sunshine-*' }
    $selected = New-Object System.Collections.Generic.List[object]

    foreach ($rule in @($Rules)) {
        if ($null -eq $rule) { continue }
        $name = ''
        if ($null -ne $rule.PSObject.Properties['Name']) { $name = [string]$rule.Name }
        $display = ''
        if ($null -ne $rule.PSObject.Properties['DisplayName']) { $display = [string]$rule.DisplayName }

        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($legacyNames -notcontains $display) { continue }
        if ($legacyNames -contains $name) { continue }

        $selected.Add($rule)
    }

    return $selected.ToArray()
}

function Remove-VegaLegacyFirewallRule {
    <#
      删除旧版只设了 DisplayName 的 Vega-Sunshine-TCP/UDP 规则，删后回读确认。
      返回确认删除的规则内部名。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $collected = New-Object System.Collections.Generic.List[object]
    foreach ($rule in @(Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
        if ($null -eq $rule) { continue }
        $collected.Add([pscustomobject]@{
                Name        = [string]$rule.Name
                DisplayName = [string]$rule.DisplayName
            })
    }

    $legacy = @(Select-VegaLegacyFirewallRule -Rules $collected.ToArray())
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($rule in $legacy) {
        $name = [string]$rule.Name
        if (-not $PSCmdlet.ShouldProcess($name, '删除旧版 Vega 防火墙规则')) { continue }
        if (Remove-VegaFirewallRuleByName -Name $name -Confirm:$false) {
            $removed.Add($name)
        }
        else {
            Write-Warning "旧版防火墙规则删除失败：$name"
        }
    }

    return $removed.ToArray()
}

function Get-VegaFirewallProfileName {
    <#
      纯函数：把 Get-NetConnectionProfile 的 NetworkCategory 映射到防火墙配置名。
      无法识别的分类返回 $null，调用方按“无法确认”中止。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$NetworkCategory
    )

    switch ($NetworkCategory) {
        'DomainAuthenticated' { return 'Domain' }
        'Domain' { return 'Domain' }
        'Private' { return 'Private' }
        'Public' { return 'Public' }
        default { return $null }
    }
}

function ConvertTo-VegaFirewallProfileName {
    <#
      纯函数：把规则/配置的 Profile 值归一化成名字列表。
      支持 "Any"、"Private, Public"、数组，以及数字位掩码（1=Domain 2=Private 4=Public，0=Any）。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        $FwProfile
    )

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($FwProfile)) {
        if ($null -eq $item) { continue }
        $text = ([string]$item).Trim()
        if ($text.Length -eq 0) { continue }

        if ($text -match '^[0-9]+$') {
            $mask = 0
            if (-not [int]::TryParse($text, [ref]$mask)) { continue }
            if ($mask -eq 0) { $names.Add('Any'); continue }
            if (($mask -band 1) -ne 0) { $names.Add('Domain') }
            if (($mask -band 2) -ne 0) { $names.Add('Private') }
            if (($mask -band 4) -ne 0) { $names.Add('Public') }
            continue
        }

        foreach ($part in ($text -split ',')) {
            $name = $part.Trim()
            if ($name.Length -gt 0) { $names.Add($name) }
        }
    }

    return $names.ToArray()
}

function Test-VegaFirewallProfileCovered {
    <#
      纯函数：规则 Profile 是否覆盖所有要求的配置（Any 视为覆盖全部）。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        $FwProfile,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$RequiredProfiles
    )

    $required = @($RequiredProfiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($required.Count -eq 0) { return $true }

    $covered = @(ConvertTo-VegaFirewallProfileName -FwProfile $FwProfile)
    if ($covered -contains 'Any') { return $true }

    foreach ($name in $required) {
        if ($covered -notcontains $name) { return $false }
    }
    return $true
}

function Get-VegaActiveFirewallProfile {
    <#
      返回所有活动网络接口对应的防火墙配置名（Domain / Private / Public），去重。
      用于回读时确认规则 Profile 覆盖了每个活动接口；无法映射的分类直接抛异常，
      宁可中止也不假装规则已覆盖。
    #>
    [CmdletBinding()]
    param()

    $required = New-Object System.Collections.Generic.List[string]
    foreach ($connection in @(Get-NetConnectionProfile -ErrorAction Stop)) {
        if ($null -eq $connection) { continue }
        $profileName = Get-VegaFirewallProfileName -NetworkCategory ([string]$connection.NetworkCategory)
        if ([string]::IsNullOrWhiteSpace($profileName)) {
            throw "接口 $([string]$connection.InterfaceAlias) 的网络类别 $([string]$connection.NetworkCategory) 无法映射到防火墙配置。"
        }
        if (-not $required.Contains($profileName)) { $required.Add($profileName) }
    }

    return $required.ToArray()
}

function Repair-VegaFirewallRuleProfile {
    <#
      回读规则 Profile 是否覆盖所有活动接口的配置（Any 视为覆盖）。
      不覆盖时用 Set-NetFirewallRule -Profile 补齐后重新回读；仍不覆盖就抛异常。
      返回补齐后的规则对象。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowNull()]
        $Rule,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$RequiredProfiles
    )

    if ($null -eq $Rule) { throw "防火墙规则 $Name 回读为空，无法核对 Profile。" }
    $required = @($RequiredProfiles | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($required.Count -eq 0) { return $Rule }

    $profileProperty = $Rule.PSObject.Properties['Profile']
    $current = $(if ($null -ne $profileProperty) { $profileProperty.Value } else { $null })
    $currentNames = @(ConvertTo-VegaFirewallProfileName -FwProfile $current)
    if (Test-VegaFirewallProfileCovered -FwProfile $current -RequiredProfiles $required) { return $Rule }

    # 补齐值是原 Profile 与所需配置文件的并集，不能把规则原有的覆盖范围缩小。
    # 固定按 Domain、Private、Public 排序，保证 Set 的值和回读比较稳定。
    $union = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @('Domain', 'Private', 'Public')) {
        if (($currentNames -contains $candidate) -or ($required -contains $candidate)) {
            $union.Add($candidate)
        }
    }
    foreach ($profileName in $currentNames) {
        if ($profileName -eq 'Any') { continue }
        if (-not $union.Contains($profileName)) { $union.Add($profileName) }
    }
    foreach ($profileName in $required) {
        if (-not $union.Contains($profileName)) { $union.Add($profileName) }
    }
    $targetProfiles = $union.ToArray()
    $target = $targetProfiles -join ','

    if (-not $PSCmdlet.ShouldProcess($Name, "补齐防火墙规则 Profile 为 $target")) { return $Rule }

    try {
        $null = Set-NetFirewallRule -Name $Name -Profile $targetProfiles -ErrorAction Stop
    }
    catch {
        throw "补齐防火墙规则 $Name 的 Profile（$target）失败：$($_.Exception.Message)"
    }

    $updated = Get-NetFirewallRule -Name $Name -PolicyStore ActiveStore -ErrorAction SilentlyContinue
    if ($null -eq $updated) { throw "补齐 Profile 后回读不到防火墙规则 $Name。" }

    $updatedProperty = $updated.PSObject.Properties['Profile']
    $updatedProfile = $(if ($null -ne $updatedProperty) { $updatedProperty.Value } else { $null })
    # 回读必须同时覆盖原范围与活动配置：只核对活动配置会把规则原有 Profile 弄丢。
    # 期望值直接复用补齐时写下去的并集：已去重、固定 Domain/Private/Public 顺序。
    # 用 @($currentNames) + @($required) 拼接会在两者重叠时产生 Private,Private,Public 这种重复项，
    # 报错信息和覆盖比较都跟着不稳定。
    $expectedProfiles = @($targetProfiles)
    if (-not (Test-VegaFirewallProfileCovered -FwProfile $updatedProfile -RequiredProfiles $expectedProfiles)) {
        $actual = @(ConvertTo-VegaFirewallProfileName -FwProfile $updatedProfile) -join ','
        throw "防火墙规则 $Name 的 Profile 未覆盖完整并集（实际：$actual，需要：$($expectedProfiles -join ',')）。"
    }

    return $updated
}

function Test-VegaEnforcementStatus {
    <#
      纯函数：归一化 EnforcementStatus。
      字符串或数字都接受；Enforced / Full / 1 视为成功，数组必须全部成功才通过。
      属性不存在或值为空时调用方跳过检查，这里空集合按通过处理。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        $Value
    )

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        $text = ([string]$item).Trim()
        if ($text.Length -eq 0) { continue }
        $values.Add($text)
    }

    if ($values.Count -eq 0) { return $true }

    foreach ($text in $values) {
        if ($text -notin @('Enforced', 'Full', '1')) { return $false }
    }
    return $true
}

function Get-VegaHostFirewallStatus {
    <#
      逐个核对活动接口，返回 { Enabled, Reason, InterfaceAlias, Profile, Message }。
      Reason 用于安装脚本区分“防火墙关闭”和“接口被排除”，提示不再混为一谈。
    #>
    [CmdletBinding()]
    param()

    try {
        $connections = @(Get-NetConnectionProfile -ErrorAction Stop)
    }
    catch {
        return [pscustomobject]@{
            Enabled = $false; Reason = 'Error'; InterfaceAlias = ''; Profile = ''
            Message = "无法读取网络连接配置：$($_.Exception.Message)"
        }
    }

    if ($connections.Count -eq 0) {
        return [pscustomobject]@{
            Enabled = $false; Reason = 'NoConnection'; InterfaceAlias = ''; Profile = ''
            Message = '没有检测到活动的网络连接，无法确认防火墙状态'
        }
    }

    try {
        $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
    }
    catch {
        return [pscustomobject]@{
            Enabled = $false; Reason = 'Error'; InterfaceAlias = ''; Profile = ''
            Message = "无法读取防火墙配置：$($_.Exception.Message)"
        }
    }

    foreach ($connection in $connections) {
        $profileName = Get-VegaFirewallProfileName -NetworkCategory ([string]$connection.NetworkCategory)
        $alias = [string]$connection.InterfaceAlias

        if ([string]::IsNullOrWhiteSpace($profileName)) {
            return [pscustomobject]@{
                Enabled = $false; Reason = 'UnknownCategory'; InterfaceAlias = $alias; Profile = [string]$connection.NetworkCategory
                Message = "接口 $alias 的网络类别 $($connection.NetworkCategory) 无法映射到防火墙配置，无法确认阻断规则是否生效"
            }
        }

        $active = @($profiles | Where-Object { [string]$_.Name -eq $profileName })
        if ($active.Count -eq 0) {
            return [pscustomobject]@{
                Enabled = $false; Reason = 'ProfileMissing'; InterfaceAlias = $alias; Profile = $profileName
                Message = "找不到防火墙配置 $profileName（接口 $alias），无法确认阻断规则是否生效"
            }
        }

        foreach ($firewallProfile in $active) {
            if ([string]$firewallProfile.Enabled -ne 'True') {
                return [pscustomobject]@{
                    Enabled = $false; Reason = 'Disabled'; InterfaceAlias = $alias; Profile = $profileName
                    Message = "Windows 防火墙在当前网络已关闭：接口 $alias（配置 $profileName），Vega 无法保护首次设密页面，请开启防火墙后重试"
                }
            }

            $disabledProperty = $firewallProfile.PSObject.Properties['DisabledInterfaceAliases']
            if ($null -eq $disabledProperty) { continue }
            if ([string]::IsNullOrWhiteSpace($alias)) { continue }
            foreach ($disabledAlias in @($disabledProperty.Value)) {
                if ([string]::IsNullOrWhiteSpace([string]$disabledAlias)) { continue }
                if ([string]::Equals([string]$disabledAlias, $alias, [StringComparison]::OrdinalIgnoreCase)) {
                    return [pscustomobject]@{
                        Enabled = $false; Reason = 'InterfaceExcluded'; InterfaceAlias = $alias; Profile = $profileName
                        Message = "接口 $alias 被防火墙配置 $profileName 的 DisabledInterfaceAliases 排除，Vega-Block-Admin 不会生效；请在该配置下取消排除该接口后重试"
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        Enabled = $true; Reason = 'Enabled'; InterfaceAlias = ''; Profile = ''
        Message = 'Windows 防火墙已在所有活动接口上启用'
    }
}

function Test-VegaHostFirewallEnabled {
    <#
      逐个核对活动接口：其网络类别对应的防火墙配置必须 Enabled=True，
      且接口不在该配置的 DisabledInterfaceAliases 里。
      WinGet 安装 Sunshine 后会立即启动服务；防火墙在该接口上关闭或接口被排除时，
      Vega-Block-Admin 不会生效，首次设密页面会暴露。任一接口不满足即返回 $false。
      需要具体原因时调用 Get-VegaHostFirewallStatus。
    #>
    [CmdletBinding()]
    param()

    return [bool](Get-VegaHostFirewallStatus).Enabled
}

function Get-VegaAdminBlockPortList {
    <#
      纯函数：算出 Vega-Block-Admin 要阻断的端口。
      - 始终包含按生效配置算出的管理端口。
      - -IncludeDefaultManagementPort：安装前使用，无条件再加 47990
        （安装器可能按默认端口启动，首次设密前必须挡住）。
      - 不带该开关：安装完成后使用，只有 47990 不在 TCP 串流放行端口里时才加，
        避免把串流端口一起阻断。只比较 TCP：阻断规则是 TCP，同号 UDP 端口不冲突。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [int[]]$ManagementPorts,

        [int]$BasePort = 47989,

        [switch]$IncludeDefaultManagementPort
    )

    $result = New-Object System.Collections.Generic.List[int]
    foreach ($port in @($ManagementPorts)) {
        if ($port -lt 1 -or $port -gt 65535) { continue }
        if (-not $result.Contains([int]$port)) { $result.Add([int]$port) }
    }

    $includeDefault = [bool]$IncludeDefaultManagementPort
    if (-not $includeDefault) {
        $tcpPorts = @(Get-VegaFirewallRuleSpec -BasePort $BasePort |
            Where-Object { $_.Protocol -eq 'TCP' } |
            ForEach-Object { $_.LocalPort })
        if (-not (Test-VegaPortInRange -Ports $tcpPorts -Port 47990)) {
            $includeDefault = $true
        }
    }

    if ($includeDefault -and -not $result.Contains(47990)) { $result.Add(47990) }

    return @($result | Sort-Object)
}

function Set-VegaAdminBlockRule {
    <#
      建立/刷新管理端口阻断规则（Vega-Block-Admin，入站 TCP，Action = Block）。
      必须在 winget 安装 Sunshine 之前调用：安装器会先放行并启动服务，
      先阻断才能保证首次设密前管理页不暴露在网络上。
      规则已存在时用一次 Set-NetFirewallRule 原地更新协议/端口/动作，
      绝不先删后建：删除到重建之间管理页会重新暴露，而且安装失败也不能撤掉已有阻断。
      创建或更新后从 ActiveStore 回读确认，失败抛异常（已有阻断保持原样）。规则保留到卸载。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [int[]]$ManagementPorts
    )

    $name = 'Vega-Block-Admin'
    $ports = @($ManagementPorts | Sort-Object -Unique | ForEach-Object { [string]$_ })
    if ($ports.Count -eq 0) { throw '管理端口阻断规则需要至少一个端口。' }

    $existing = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue

    if (-not $PSCmdlet.ShouldProcess($name, "阻断入站 TCP $($ports -join '/')")) { return $name }

    if ($null -eq $existing) {
        $params = @{
            Name        = $name
            DisplayName = $name
            Direction   = 'Inbound'
            Action      = 'Block'
            Protocol    = 'TCP'
            LocalPort   = $ports
            Profile     = 'Any'
            Enabled     = 'True'
            Description = 'Vega Remote：阻止入站访问 Sunshine 管理页（本机浏览器仍可访问）'
        }

        try {
            $null = New-NetFirewallRule @params -ErrorAction Stop
        }
        catch {
            throw "创建管理端口阻断规则 $name 失败：$($_.Exception.Message)"
        }
    }
    else {
        # 原地更新：协议、端口、动作一次 Set 完成，不删除已有规则
        try {
            $null = Set-NetFirewallRule -Name $name -Protocol TCP -LocalPort $ports -Action Block -Enabled True -ErrorAction Stop
        }
        catch {
            throw "更新管理端口阻断规则 $name 失败（已有阻断保持原样，未删除）：$($_.Exception.Message)"
        }
    }

    $check = Get-NetFirewallRule -Name $name -PolicyStore ActiveStore -ErrorAction SilentlyContinue
    if ($null -eq $check) { throw "管理端口阻断规则创建/更新后未找到：$name" }
    if ([string]$check.Enabled -ne 'True' -or [string]$check.Action -ne 'Block' -or
        [string]$check.Direction -ne 'Inbound') {
        throw "管理端口阻断规则状态异常（Enabled=$($check.Enabled)，Action=$($check.Action)，Direction=$($check.Direction)）。"
    }

    # 规则 Profile 必须覆盖所有活动接口的配置文件；Any 视为覆盖。
    # 不覆盖就用 Set-NetFirewallRule -Profile 补齐，再回读确认。
    $requiredProfiles = @(Get-VegaActiveFirewallProfile)
    $check = Repair-VegaFirewallRuleProfile -Name $name -Rule $check -RequiredProfiles $requiredProfiles -Confirm:$false

    # 组策略/特殊策略可能让本地规则不生效：核对生效存储里的执行状态。
    # 旧系统没有这些属性时跳过，保持兼容。
    $primaryProperty = $check.PSObject.Properties['PrimaryStatus']
    if ($null -ne $primaryProperty -and [string]$primaryProperty.Value -ne 'OK') {
        throw "管理端口阻断规则未生效（PrimaryStatus=$($primaryProperty.Value)），拒绝继续。"
    }
    $enforcementProperty = $check.PSObject.Properties['EnforcementStatus']
    if ($null -ne $enforcementProperty) {
        # 字符串或数字都接受：Full / 1 / Enforced 视为成功；数组必须全部成功。
        $enforcementValues = @($enforcementProperty.Value)
        if (-not (Test-VegaEnforcementStatus -Value $enforcementValues)) {
            $enforcement = ($enforcementValues | ForEach-Object { [string]$_ }) -join ','
            throw "管理端口阻断规则未被强制执行（EnforcementStatus=$enforcement），拒绝继续。"
        }
    }

    $filter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $check -ErrorAction SilentlyContinue
    if ($null -eq $filter) { throw "无法读取管理端口阻断规则 $name 的端口过滤器，拒绝继续。" }
    # Get-NetFirewallPortFilter 的 Protocol 可能是 "TCP" 或数字 6
    $actualProtocol = [string]$filter.Protocol
    if ($actualProtocol -ne 'TCP' -and $actualProtocol -ne '6') {
        throw "管理端口阻断规则协议不是 TCP（实际：$actualProtocol）。"
    }

    $actualPorts = @($filter.LocalPort | ForEach-Object { [string]$_ })
    foreach ($port in $ports) {
        if (-not (Test-VegaPortInRange -Ports $actualPorts -Port ([int]$port))) {
            throw "管理端口阻断规则未覆盖端口 $port（实际：$($actualPorts -join ',')）。"
        }
    }

    return $name
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

        [int]$ManagementPort = 47990,

        [AllowEmptyString()]
        [string]$StatePath = ''
    )

    if (-not (Test-Path -LiteralPath $SunshineExe -PathType Leaf)) { return $State }

    $rules = @(Get-VegaSunshineInstallerFirewallRule -SunshineExe $SunshineExe -ManagementPort $ManagementPort)
    if ($rules.Count -eq 0) { return $State }

    $disabled = @(Disable-VegaSunshineInstallerFirewallRule -Rules $rules -Confirm:$false)
    foreach ($ruleName in $disabled) {
        $State = Add-VegaStateDisabledFirewallRule -State $State -Name $ruleName
        # 逐项持久化：禁用到一条就记一条
        if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
            $null = Save-VegaState -State $State -Path $StatePath
        }
    }

    if ($disabled.Count -gt 0) {
        Write-VegaStatus ("已隔离管理端口 ${ManagementPort}：禁用安装器规则 {0}" -f ($disabled -join '、')) -Level Warn
    }

    # 串流放行规则已经确认，安装器规则却禁不掉：管理页仍然暴露，必须中止而不是继续
    $failed = @($rules | Where-Object { $disabled -notcontains [string]$_.Name })
    if ($failed.Count -gt 0) {
        throw ("未能禁用 Sunshine 安装器放行规则：{0}" -f (($failed | ForEach-Object { [string]$_.Name }) -join '、'))
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

    # RustDesk 中继配置（只有 doctor 采集到相关事实时才提示）
    $rustDeskExpected = ''
    if ($Facts.ContainsKey('RustDeskExpectedServer') -and $null -ne $Facts['RustDeskExpectedServer']) {
        $rustDeskExpected = [string]$Facts['RustDeskExpectedServer']
    }
    $rustDeskActual = ''
    if ($Facts.ContainsKey('RustDeskTomlServer') -and $null -ne $Facts['RustDeskTomlServer']) {
        $rustDeskActual = [string]$Facts['RustDeskTomlServer']
    }
    $rustDeskDevice = ''
    if ($Facts.ContainsKey('RustDeskDeviceId') -and $null -ne $Facts['RustDeskDeviceId']) {
        $rustDeskDevice = [string]$Facts['RustDeskDeviceId']
    }
    $rustDeskServiceServer = ''
    if ($Facts.ContainsKey('RustDeskServiceServer') -and $null -ne $Facts['RustDeskServiceServer']) {
        $rustDeskServiceServer = [string]$Facts['RustDeskServiceServer']
    }
    $rustDeskExpectedRelay = ''
    if ($Facts.ContainsKey('RustDeskExpectedRelay') -and $null -ne $Facts['RustDeskExpectedRelay']) {
        $rustDeskExpectedRelay = [string]$Facts['RustDeskExpectedRelay']
    }
    $rustDeskActualRelay = ''
    if ($Facts.ContainsKey('RustDeskTomlRelay') -and $null -ne $Facts['RustDeskTomlRelay']) {
        $rustDeskActualRelay = [string]$Facts['RustDeskTomlRelay']
    }
    $rustDeskServiceRelay = ''
    if ($Facts.ContainsKey('RustDeskServiceRelay') -and $null -ne $Facts['RustDeskServiceRelay']) {
        $rustDeskServiceRelay = [string]$Facts['RustDeskServiceRelay']
    }
    $rustDeskServicePresent = ($Facts.ContainsKey('RustDeskServicePresent') -and [bool]$Facts['RustDeskServicePresent'])

    $rustDeskUserError = ''
    if ($Facts.ContainsKey('RustDeskUserError') -and $null -ne $Facts['RustDeskUserError']) {
        $rustDeskUserError = [string]$Facts['RustDeskUserError']
    }
    $rustDeskServiceError = ''
    if ($Facts.ContainsKey('RustDeskServiceError') -and $null -ne $Facts['RustDeskServiceError']) {
        $rustDeskServiceError = [string]$Facts['RustDeskServiceError']
    }
    if (-not [string]::IsNullOrWhiteSpace($rustDeskUserError)) {
        $advice.Add(("读取用户 RustDesk2.toml 失败：{0}。请检查文件权限或 TOML 内容。" -f $rustDeskUserError))
    }
    if ($rustDeskServicePresent -and -not [string]::IsNullOrWhiteSpace($rustDeskServiceError)) {
        $advice.Add(("读取服务 RustDesk2.toml 失败：{0}。请检查文件权限或 TOML 内容。" -f $rustDeskServiceError))
    }

    # RustDesk 服务存在时实际生效的是 LocalService 配置：两份不一致要明确提示。
    $rustDeskConfigsDiffer = (
        ($rustDeskServicePresent) -and
        (
            (-not [string]::Equals($rustDeskServiceServer, $rustDeskActual, [StringComparison]::OrdinalIgnoreCase)) -or
            (-not [string]::Equals($rustDeskServiceRelay, $rustDeskActualRelay, [StringComparison]::OrdinalIgnoreCase))
        )
    )
    if ($rustDeskConfigsDiffer) {
        $advice.Add(("RustDesk 用户配置（ID {0} / relay {1}）与服务配置（ID {2} / relay {3}）不一致：服务模式实际使用后者，需重新运行安装脚本以管理员身份写入。" -f `
                $(if ($rustDeskActual) { $rustDeskActual } else { '未配置' }), $(if ($rustDeskActualRelay) { $rustDeskActualRelay } else { '未配置' }), `
                $(if ($rustDeskServiceServer) { $rustDeskServiceServer } else { '未配置' }), $(if ($rustDeskServiceRelay) { $rustDeskServiceRelay } else { '未配置' })))
    }

    # 服务存在时以服务配置为准；用户配置只作参考，不能因为用户配置对就判定“配置正确”。
    $rustDeskTarget = $rustDeskActual
    $rustDeskTargetRelay = $rustDeskActualRelay
    $rustDeskTargetName = 'RustDesk2.toml'
    if ($rustDeskServicePresent) {
        $rustDeskTarget = $rustDeskServiceServer
        $rustDeskTargetRelay = $rustDeskServiceRelay
        $rustDeskTargetName = 'RustDesk 服务配置'
    }

    if (-not [string]::IsNullOrWhiteSpace($rustDeskExpected)) {
        $relayMismatch = (-not [string]::IsNullOrWhiteSpace($rustDeskExpectedRelay)) -and
            (-not [string]::Equals($rustDeskTargetRelay, $rustDeskExpectedRelay, [StringComparison]::OrdinalIgnoreCase))

        if ([string]::IsNullOrWhiteSpace($rustDeskTarget)) {
            $advice.Add(("{0} 没有配置 custom-rendezvous-server（期望 {1}）：重新运行安装脚本并带 -RustDeskServer / -RustDeskKey。" -f $rustDeskTargetName, $rustDeskExpected))
        }
        elseif (-not [string]::Equals($rustDeskTarget, $rustDeskExpected, [StringComparison]::OrdinalIgnoreCase)) {
            $advice.Add(("{0} 指向 {1}，与配置的 {2} 不一致：重新运行安装脚本写入正确的中继地址。" -f $rustDeskTargetName, $rustDeskTarget, $rustDeskExpected))
        }
        elseif ($relayMismatch) {
            $advice.Add(("{0} 的 relay-server 是 {1}，与配置的 {2} 不一致：重新运行安装脚本写入正确的中继地址。" -f `
                    $rustDeskTargetName, $(if ($rustDeskTargetRelay) { $rustDeskTargetRelay } else { '未配置' }), $rustDeskExpectedRelay))
        }
        else {
            $advice.Add(("RustDesk 中继配置正确：{0}。" -f $rustDeskTarget))
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($rustDeskTarget)) {
        $advice.Add(("RustDesk 当前中继：{0}（没有在 vega.config.json 里配置期望值，跳过一致性检查）。" -f $rustDeskTarget))
    }

    if (-not [string]::IsNullOrWhiteSpace($rustDeskExpected) -and [string]::IsNullOrWhiteSpace($rustDeskDevice)) {
        $advice.Add('读取不到 RustDesk 设备码：确认 RustDesk 已安装并启动，或在 RustDesk 主界面查看设备码。')
    }

    if ($advice.Count -eq 0) {
        $advice.Add('整体状态良好：打开 Moonlight 添加被控端地址即可连接。')
    }

    $advice.Add('更多排查：docs/network.md；安装/卸载：README.md。')
    return $advice.ToArray()
}

# ---------------------------------------------------------------------------
# RustDesk：参数校验、RustDesk2.toml 配置、设备 ID
# ---------------------------------------------------------------------------
# 约定：
#   - 只写 [options] 下的 custom-rendezvous-server / relay-server / key，
#     文件其余内容（注释、其他键、其他段）原样保留。
#   - 首次写前把这三个键的原值记进状态清单，卸载按键回滚。
#   - 不接收、不记录任何密码：固定密码由用户在 RustDesk 界面自己设。

function Get-VegaRustDeskConfigPath {
    <#
      当前用户与服务模式（LocalService）的 RustDesk2.toml 路径。
    #>
    [CmdletBinding()]
    param(
        [switch]$ServiceMode
    )

    if ($ServiceMode) {
        $root = 'C:\Windows'
        if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) { $root = $env:SystemRoot }
        return (Join-Path $root 'ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml')
    }

    $appData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData) -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $appData = Join-Path $env:USERPROFILE 'AppData\Roaming'
    }
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $appData = [System.IO.Path]::GetTempPath()
    }
    return (Join-Path $appData 'RustDesk\config\RustDesk2.toml')
}

function Test-VegaRustDeskConfigPath {
    <#
      后缀白名单：只允许 ...\config\RustDesk2.toml。
      只用于快速排除明显错误的记录；卸载前还会用 Test-VegaRustDeskManagedConfigPath
      做规范化后的精确路径比较。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $leaf = [System.IO.Path]::GetFileName($Path)
        $parent = [System.IO.Path]::GetDirectoryName($Path)
        if ($leaf -ne 'RustDesk2.toml') { return $false }
        return ([System.IO.Path]::GetFileName($parent) -eq 'config')
    }
    catch {
        return $false
    }
}

function Get-VegaRustDeskManagedKeyName {
    <#
      纯函数：Vega 只管理 RustDesk2.toml 的三个键，回滚时其他键一律忽略。
    #>
    [CmdletBinding()]
    param()

    return @('custom-rendezvous-server', 'relay-server', 'key')
}

function Get-VegaRustDeskServiceStatePath {
    <#
      LocalService（服务模式）RustDesk 配置的清单只能写管理员专用清单：
      %ProgramData%\Vega\state.json。用户可写的 client-state.json 不允许记录服务路径。
    #>
    [CmdletBinding()]
    param()

    $root = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $root 'Vega') 'state.json')
}

function Test-VegaRustDeskManagedConfigPath {
    <#
      回滚与安装写入共用的路径校验：
        - 记录路径与预期路径规范化后必须完全相等（不是后缀匹配）；
        - 从 %APPDATA%（或 LocalService 的 Roaming）起逐级检查 RustDesk 目录、
          config 目录与文件本身都不是重解析点；任一是则拒绝。
      -ServiceMode 预期 LocalService 路径，否则预期当前用户 %AppData% 路径。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path,

        [switch]$ServiceMode,

        [AllowEmptyString()]
        [string]$ExpectedPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    if ([string]::IsNullOrWhiteSpace($ExpectedPath)) {
        $ExpectedPath = Get-VegaRustDeskConfigPath -ServiceMode:$ServiceMode
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedPath)) { return $false }

    try {
        $actualFull = [System.IO.Path]::GetFullPath($Path)
        $expectedFull = [System.IO.Path]::GetFullPath($ExpectedPath)
    }
    catch {
        return $false
    }

    if (-not [string]::Equals($actualFull, $expectedFull, [StringComparison]::OrdinalIgnoreCase)) { return $false }

    try {
        if ([System.IO.Path]::GetFileName($actualFull) -ne 'RustDesk2.toml') { return $false }
        $configDirectory = [System.IO.Path]::GetDirectoryName($actualFull)
        if ([System.IO.Path]::GetFileName($configDirectory) -ne 'config') { return $false }
        $rustDeskDirectory = [System.IO.Path]::GetDirectoryName($configDirectory)
        if ([System.IO.Path]::GetFileName($rustDeskDirectory) -ne 'RustDesk') { return $false }
        $roamingRoot = [System.IO.Path]::GetDirectoryName($rustDeskDirectory)
    }
    catch {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($roamingRoot)) { return $false }

    foreach ($component in @($roamingRoot, $rustDeskDirectory, $configDirectory, $actualFull)) {
        if (-not (Test-Path -LiteralPath $component)) { continue }
        if (Test-VegaReparsePoint -Path $component) { return $false }
    }

    return $true
}

function ConvertFrom-VegaRustDeskServerEndpoint {
    <#
      纯函数：解析 host[:port]，支持主机名、IPv4、IPv6（裸地址或 [addr]:port）。
      解析失败返回 $null，由调用方中止。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Server
    )

    if ([string]::IsNullOrWhiteSpace($Server)) { return $null }
    $text = $Server.Trim()

    $hostText = ''
    $port = 0

    if ($text -match '^\[(?<host>[0-9A-Fa-f:.]+)\](?::(?<port>[0-9]{1,5}))?$') {
        $hostText = $Matches['host']
        if (-not [string]::IsNullOrWhiteSpace($Matches['port'])) { $port = [int]$Matches['port'] }
    }
    elseif ($text -match '^(?<host>[^:]+):(?<port>[0-9]{1,5})$') {
        $hostText = $Matches['host']
        $port = [int]$Matches['port']
    }
    elseif ($text -match '^[0-9A-Fa-f:.]+$' -and $text.IndexOf(':') -ge 0) {
        # 裸 IPv6，不带端口
        $hostText = $text
    }
    elseif ($text -match '^(?<host>[^:]+)$') {
        $hostText = $Matches['host']
    }
    else {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($hostText)) { return $null }
    if ($port -lt 0 -or $port -gt 65535) { return $null }

    $isIpv6 = $hostText.IndexOf(':') -ge 0
    if ($isIpv6) {
        $parsedAddress = $null
        if (-not [System.Net.IPAddress]::TryParse($hostText, [ref]$parsedAddress)) { return $null }
        if ($parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return $null }
    }
    else {
        $isIpv4 = $hostText -match '^[0-9.]+$'
        if ($isIpv4) {
            $parsedAddress = $null
            if (-not [System.Net.IPAddress]::TryParse($hostText, [ref]$parsedAddress)) { return $null }
            if ($parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
        }
        elseif ($hostText -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$') {
            return $null
        }
        if ($hostText.Contains('..')) { return $null }
        if ($hostText.Length -gt 253) { return $null }
    }

    $serverText = $hostText
    if ($isIpv6) {
        if ($port -gt 0) { $serverText = ('[{0}]:{1}' -f $hostText, $port) }
    }
    elseif ($port -gt 0) {
        $serverText = ('{0}:{1}' -f $hostText, $port)
    }

    $relayText = $hostText
    if ($isIpv6) { $relayText = ('[{0}]:21117' -f $hostText) }
    else { $relayText = ('{0}:21117' -f $hostText) }

    return [pscustomobject]@{
        Host        = $hostText
        Port        = $port
        Server      = $serverText
        RelayServer = $relayText
        IsIpv6      = $isIpv6
    }
}

function Test-VegaRustDeskServer {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Server
    )

    return ($null -ne (ConvertFrom-VegaRustDeskServerEndpoint -Server $Server))
}

function Test-VegaRustDeskKey {
    <#
      纯函数：RustDesk 公钥是 base64 样式字符串（约 44 字符）。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) { return $false }
    $text = $Key.Trim()
    if ($text.Length -lt 40 -or $text.Length -gt 48) { return $false }
    return [bool]($text -match '^[A-Za-z0-9+/=]+$')
}

function Resolve-VegaRustDeskSetting {
    <#
      参数优先，其次仓库根目录的可选 vega.config.json：
        { "rustdesk": { "server": "", "key": "" } }
      两者必须同时给出。都没有返回 $null（跳过并提示）。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Server = '',

        [AllowEmptyString()]
        [string]$Key = '',

        [AllowEmptyString()]
        [string]$ConfigPath = ''
    )

    $hasServer = -not [string]::IsNullOrWhiteSpace($Server)
    $hasKey = -not [string]::IsNullOrWhiteSpace($Key)

    if ($hasServer -xor $hasKey) {
        throw 'RustDesk 配置必须同时提供 -RustDeskServer 与 -RustDeskKey（或两者都不提供）。'
    }

    $source = 'Parameter'
    if (-not $hasServer) {
        if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
            $ConfigPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'vega.config.json'
        }
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $null }

        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

        try {
            $data = $raw | ConvertFrom-Json
        }
        catch {
            throw "读取 $ConfigPath 失败（不是合法 JSON）：$($_.Exception.Message)"
        }

        if ($null -eq $data -or $null -eq $data.PSObject.Properties['rustdesk']) { return $null }
        $rustdesk = $data.rustdesk
        if ($null -eq $rustdesk) { return $null }

        if ($null -ne $rustdesk.PSObject.Properties['server']) { $Server = [string]$rustdesk.server }
        if ($null -ne $rustdesk.PSObject.Properties['key']) { $Key = [string]$rustdesk.key }

        $hasServer = -not [string]::IsNullOrWhiteSpace($Server)
        $hasKey = -not [string]::IsNullOrWhiteSpace($Key)
        if (-not $hasServer -and -not $hasKey) { return $null }
        if ($hasServer -xor $hasKey) {
            throw "$ConfigPath 里的 rustdesk.server 与 rustdesk.key 必须同时填写（或都不填）。"
        }
        $source = 'ConfigFile'
    }

    if (-not (Test-VegaRustDeskServer -Server $Server)) {
        throw 'RustDesk 服务器地址格式无效（应为 主机名/IPv4/IPv6，可带 :端口）。'
    }
    if (-not (Test-VegaRustDeskKey -Key $Key)) {
        throw 'RustDesk 公钥无效：应为 base64 样式字符串（约 44 字符，仅 A-Z a-z 0-9 + / =）。'
    }

    $endpoint = ConvertFrom-VegaRustDeskServerEndpoint -Server $Server
    return [pscustomobject]@{
        Server      = $endpoint.Server
        Host        = $endpoint.Host
        Port        = $endpoint.Port
        RelayServer = $endpoint.RelayServer
        Key         = $Key.Trim()
        Source      = $source
    }
}

function ConvertFrom-VegaTomlString {
    <#
      纯函数：去掉 TOML 字符串两侧的引号并还原转义；非字符串原样返回。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) { return '' }
    $text = $Value.Trim()
    if ($text.Length -ge 2) {
        $first = $text[0]
        $last = $text[$text.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $inner = $text.Substring(1, $text.Length - 2)
            if ($first -eq '"') {
                $inner = $inner.Replace('\\', '\').Replace('\"', '"')
            }
            return $inner
        }
    }
    return $text
}

function ConvertTo-VegaTomlString {
    <#
      纯函数：把值写成 TOML 双引号字符串。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) { $Value = '' }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return ('"{0}"' -f $escaped)
}

function Get-VegaTomlKeyValuePattern {
    <#
      内部辅助：匹配一行 [options] 键值，并把“行首缩进 + 值的文本区间”与行尾注释分开。
      缩进保留在 prefix 里，替换后不会丢行首空白。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Key
    )

    $escaped = [regex]::Escape($Key)
    return ('^(?<prefix>[ \t]*{0}[ \t]*=[ \t]*)(?<value>"(?:[^"\\]|\\.)*"|''[^'']*''|[^#]*?)(?<suffix>[ \t]*(?:#.*)?)$' -f $escaped)
}

function Split-VegaTomlLine {
    <#
      内部辅助：按 \n 切行，但每段保留自己的行尾（\r\n 或 \n）。
      没有行尾的最后一行原样保留，便于逐行拼回同一份文本。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    $lines = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Text)) { return $lines.ToArray() }

    $start = 0
    for ($index = 0; $index -lt $Text.Length; $index++) {
        if ($Text[$index] -eq "`n") {
            $lines.Add($Text.Substring($start, $index - $start + 1))
            $start = $index + 1
        }
    }
    if ($start -lt $Text.Length) { $lines.Add($Text.Substring($start)) }
    return $lines.ToArray()
}

function Get-VegaTomlLineContent {
    <#
      内部辅助：去掉一段的行尾（\r\n 或 \n），不改动正文。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ($null -eq $Line) { return '' }
    $content = $Line
    if ($content.EndsWith("`n")) { $content = $content.Substring(0, $content.Length - 1) }
    if ($content.EndsWith("`r")) { $content = $content.Substring(0, $content.Length - 1) }
    return $content
}

function Get-VegaTomlLineEnding {
    <#
      内部辅助：取一段自己的行尾；没有行尾返回空串。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ($null -eq $Line) { return '' }
    if ($Line.EndsWith("`r`n")) { return "`r`n" }
    if ($Line.EndsWith("`n")) { return "`n" }
    return ''
}

function Test-VegaTomlQuotedDottedKey {
    <#
      内部辅助：这一行是否是“带引号段的点分键”且涉及受管表 options。
      例子："options".key = 1、'options'.key = 1、options."key" = 1、options.'key' = 1。
      这类写法当前按键定位文本区间时无法安全定位（引号里的点、引号段的边界都会错位），
      写前必须中止。纯点分键（options.key）没有引号段，不在此列。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }

    # 键 = 一到多个“引号段或裸段”，段之间用点连接；段内部允许包含点（引号内）。
    $pattern = '^[ \t]*(?<key>(?:"(?:[^"\\]|\\.)*"|''[^'']*''|[A-Za-z0-9_-]+)(?:[ \t]*\.[ \t]*(?:"(?:[^"\\]|\\.)*"|''[^'']*''|[A-Za-z0-9_-]+))+)[ \t]*='
    if ($Line -cnotmatch $pattern) { return $false }

    $key = [string]$Matches['key']
    if ($key -cnotmatch '["'']') { return $false }

    foreach ($match in [regex]::Matches($key, '"(?:[^"\\]|\\.)*"|''[^'']*''|[A-Za-z0-9_-]+')) {
        $name = ConvertFrom-VegaTomlString -Value $match.Value
        if ($name -ceq 'options') { return $true }
    }

    return $false
}

function Test-VegaRustDeskConfigUnsupported {
    <#
      内部辅助：写前检测当前解析器不支持的 TOML 结构。
      引号键（"key" / 'key'）、引号表头（["options"]）、
      涉及 options 的引号点分键（"options".key / options."key"）返回原因文本，否则返回空串。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $section = ''
    foreach ($rawLine in @(Split-VegaTomlLine -Text $Text)) {
        $line = Get-VegaTomlLineContent -Line $rawLine
        if ($line -match '^[ \t]*\[[ \t]*["'']') { return '引号表头' }
        # 根级或任意段里出现带引号段的点分键：可能就是在改受管表 options，定位不可靠。
        if (Test-VegaTomlQuotedDottedKey -Line $line) { return '引号点分键' }
        if ($line -cmatch '^[ \t]*\[(?<name>[^\]]+)\][ \t]*(?:#.*)?$') {
            $section = ([string]$Matches['name']).Trim()
            continue
        }
        if ($section -cne 'options') { continue }
        if ($line -match '^[ \t]*(?<quote>["''])[^"'']+\k<quote>[ \t]*=') { return '引号键' }
    }

    return ''
}

function ConvertFrom-VegaRustDeskConfigText {
    <#
      纯函数：读取 [options] 段的键值，其余段忽略；同名键以第一次为准。
      表头与键名都按精确大小写匹配（TOML 区分大小写），表头允许行尾 # 注释。
      值只取引号内/注释前的文本，不会把行尾注释读进清单。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    $values = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    if ([string]::IsNullOrEmpty($Text)) { return $values }

    $section = ''
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -cmatch '^\s*\[(?<name>[^\]]+)\]\s*(?:#.*)?$') {
            $section = ([string]$Matches['name']).Trim()
            continue
        }
        if ($section -cne 'options') { continue }

        if ($line -match '^\s*(?<key>[A-Za-z0-9_-]+)\s*=\s*(?<value>"(?:[^"\\]|\\.)*"|''[^'']*''|[^#]*)(?<suffix>\s*(?:#.*)?)$') {
            $key = [string]$Matches['key']
            if (-not $values.Contains($key)) {
                $values[$key] = ConvertFrom-VegaTomlString -Value ([string]$Matches['value'])
            }
        }
    }

    return $values
}

function Merge-VegaRustDeskConfigText {
    <#
      纯函数：只替换 [options] 段里给出键的“值文本区间”，其他行、行首缩进、
      行尾注释、每行自己的换行符（CRLF/LF，可混合）与尾部空行原样保留。
      表头与键名按精确大小写匹配；[options] 允许行尾 # 注释。
      $RemoveKeys 里的键整行删除（回滚时“原本没有”的键）。
      缺失的键追加到 [options] 段末尾；没有该段时在文件末尾追加。
      引号键或引号表头无法安全定位，写前直接中止。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExistingText,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Values,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$RemoveKeys = @()
    )

    $unsupported = Test-VegaRustDeskConfigUnsupported -Text $ExistingText
    if (-not [string]::IsNullOrWhiteSpace($unsupported)) {
        throw "RustDesk2.toml 含$unsupported，暂不支持自动修改，请手动处理后重试。"
    }

    # 统一用 Ordinal 字典：调用方给的 [ordered]@{} 默认大小写不敏感，会把 Key 当成 key。
    $wanted = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    foreach ($valueKey in $Values.Keys) {
        $wanted[[string]$valueKey] = [string]$Values[$valueKey]
    }

    $remove = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    foreach ($removeKey in @($RemoveKeys)) {
        if ([string]::IsNullOrWhiteSpace($removeKey)) { continue }
        $null = $remove.Add([string]$removeKey)
    }

    # 新增行使用文件里出现的换行风格；已有行各自保留自己的行尾。
    $newline = "`n"
    if (-not [string]::IsNullOrEmpty($ExistingText) -and $ExistingText.Contains("`r`n")) { $newline = "`r`n" }

    $result = New-Object System.Collections.Generic.List[string]
    $written = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    $section = ''

    foreach ($rawLine in @(Split-VegaTomlLine -Text $ExistingText)) {
        $line = Get-VegaTomlLineContent -Line $rawLine
        $ending = Get-VegaTomlLineEnding -Line $rawLine

        if ($line -cmatch '^[ \t]*\[(?<name>[^\]]+)\][ \t]*(?:#.*)?$') {
            $section = ([string]$Matches['name']).Trim()
            $result.Add($rawLine)
            continue
        }

        if ($section -cne 'options') {
            $result.Add($rawLine)
            continue
        }

        if ($line -match '^[ \t]*(?<key>[A-Za-z0-9_-]+)[ \t]*=') {
            $key = [string]$Matches['key']
            if ($remove.Contains($key)) {
                $null = $written.Add($key)
                continue
            }
            if ($wanted.Contains($key)) {
                if ($written.Contains($key)) {
                    # 重复键不删除，避免改动受管值以外的文本
                    $result.Add($rawLine)
                    continue
                }
                $pattern = Get-VegaTomlKeyValuePattern -Key $key
                if ($line -cmatch $pattern) {
                    $result.Add($Matches['prefix'] + (ConvertTo-VegaTomlString -Value ([string]$wanted[$key])) + $Matches['suffix'] + $ending)
                    $null = $written.Add($key)
                    continue
                }
            }
        }

        $result.Add($rawLine)
    }

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($key in $wanted.Keys) {
        if (-not $written.Contains([string]$key)) { $missing.Add([string]$key) }
    }

    if ($missing.Count -eq 0) {
        return ($result -join '')
    }

    $headerIndex = -1
    for ($index = 0; $index -lt $result.Count; $index++) {
        $content = Get-VegaTomlLineContent -Line $result[$index]
        if ($content -cmatch '^[ \t]*\[(?<name>[^\]]+)\][ \t]*(?:#.*)?$' -and ([string]$Matches['name']).Trim() -ceq 'options') {
            $headerIndex = $index
            break
        }
    }

    if ($headerIndex -lt 0) {
        # 文件末尾追加：先保证前一行有行尾，再按文件风格补段。
        if ($result.Count -gt 0 -and [string]::IsNullOrEmpty((Get-VegaTomlLineEnding -Line $result[$result.Count - 1]))) {
            $result[$result.Count - 1] = $result[$result.Count - 1] + $newline
        }
        if ($result.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace((Get-VegaTomlLineContent -Line $result[$result.Count - 1]))) {
            $result.Add($newline)
        }
        $result.Add('[options]' + $newline)
        for ($index = 0; $index -lt $missing.Count; $index++) {
            $lineText = "$($missing[$index]) = $(ConvertTo-VegaTomlString -Value ([string]$wanted[$missing[$index]]))"
            if ($index -lt $missing.Count - 1 -or (-not [string]::IsNullOrEmpty($ExistingText) -and $ExistingText.EndsWith("`n"))) {
                $lineText += $newline
            }
            $result.Add($lineText)
        }
        return ($result -join '')
    }

    $insertAt = $result.Count
    for ($index = $headerIndex + 1; $index -lt $result.Count; $index++) {
        $content = Get-VegaTomlLineContent -Line $result[$index]
        if ($content -cmatch '^[ \t]*\[[^\]]+\][ \t]*(?:#.*)?$') {
            $insertAt = $index
            break
        }
    }
    while ($insertAt -gt $headerIndex + 1 -and
        [string]::IsNullOrWhiteSpace((Get-VegaTomlLineContent -Line $result[$insertAt - 1]))) {
        $insertAt--
    }

    foreach ($key in $missing) {
        # 插入点前一行若没有行尾（文件正好在表头处结束），先补一个，避免键粘在表头上。
        if ($insertAt -gt 0 -and [string]::IsNullOrEmpty((Get-VegaTomlLineEnding -Line $result[$insertAt - 1]))) {
            $result[$insertAt - 1] = $result[$insertAt - 1] + $newline
        }
        $result.Insert($insertAt, "$key = $(ConvertTo-VegaTomlString -Value ([string]$wanted[$key]))" + $newline)
        $insertAt++
    }

    return ($result -join '')
}

function Get-VegaRustDeskConfigKeySnapshot {
    <#
      纯函数：记录 RustDesk2.toml [options] 下受管键的基线。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Keys
    )

    $values = ConvertFrom-VegaRustDeskConfigText -Text $Text
    $snapshot = [ordered]@{}
    foreach ($key in @($Keys)) {
        $keyText = [string]$key
        if ([string]::IsNullOrWhiteSpace($keyText)) { continue }
        if ($values.Contains($keyText)) {
            $snapshot[$keyText] = [pscustomobject]@{
                Key           = $keyText
                Existed       = $true
                Value         = [string]$values[$keyText]
                OriginalValue = [string]$values[$keyText]
            }
        }
        else {
            $snapshot[$keyText] = [pscustomobject]@{
                Key           = $keyText
                Existed       = $false
                Value         = ''
                OriginalValue = ''
            }
        }
    }
    return $snapshot
}

function Get-VegaRustDeskConfigSummary {
    <#
      诊断用：分别读取当前用户与 LocalService（服务模式）的 RustDesk2.toml。
      -ServicePresent 时才把服务模式配置算作“应检查”；只有明确的 ItemNotFound 才标记
      Exists=false（没装/没登录过），其他探测或读取错误标记 Exists=true 并把原因放进 Error，
      由 doctor 统一加“读取失败”前缀输出。
      返回 { UserPath, UserExists, UserServer, UserRelay, UserError,
             ServicePath, ServiceExists, ServiceServer, ServiceRelay, ServiceError }。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$UserConfigPath = '',

        [AllowEmptyString()]
        [string]$ServiceConfigPath = '',

        [switch]$ServicePresent
    )

    if ([string]::IsNullOrWhiteSpace($UserConfigPath)) { $UserConfigPath = Get-VegaRustDeskConfigPath }
    if ([string]::IsNullOrWhiteSpace($ServiceConfigPath)) { $ServiceConfigPath = Get-VegaRustDeskConfigPath -ServiceMode }

    $read = {
        param([string]$ConfigPath)
        $exists = $false
        $server = ''
        $relay = ''
        $errorText = ''

        # 探测本身也会失败（权限、路径不可达、句柄被占用）：用 -ErrorAction Stop 包住，
        # 只有明确的 ItemNotFound 才算“文件不存在”，其他错误一律按读取失败上报原因。
        try {
            $probe = Get-Item -LiteralPath $ConfigPath -Force -ErrorAction Stop
            if ($null -eq $probe) {
                $errorText = "探测结果为空：$ConfigPath"
            }
            elseif ([bool]$probe.PSIsContainer) {
                # 路径确实存在，只是不是配置文件：按“读取失败 + 原因”上报，
                # 不能当成“没装/没登录过”，也不能尝试把它当文件读。
                $exists = $true
                $errorText = "不是配置文件（是目录）：$ConfigPath"
            }
            else {
                $exists = $true
            }
        }
        catch {
            $notFound = ($_.Exception -is [System.Management.Automation.ItemNotFoundException]) -or
                ([string]$_.FullyQualifiedErrorId -match 'ItemNotFound') -or
                ($null -ne $_.CategoryInfo -and $_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound)
            if ($notFound) {
                $exists = $false
            }
            else {
                $exists = $true
                $errorText = $_.Exception.Message
            }
        }

        if ($exists -and [string]::IsNullOrEmpty($errorText)) {
            try {
                $text = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop
                $values = ConvertFrom-VegaRustDeskConfigText -Text $text
                if ($values.Contains('custom-rendezvous-server')) {
                    $server = [string]$values['custom-rendezvous-server']
                }
                if ($values.Contains('relay-server')) {
                    $relay = [string]$values['relay-server']
                }
            }
            catch {
                $errorText = $_.Exception.Message
            }
        }
        return [pscustomobject]@{ Exists = $exists; Server = $server; Relay = $relay; Error = $errorText }
    }

    $user = & $read $UserConfigPath
    $service = [pscustomobject]@{ Exists = $false; Server = ''; Relay = ''; Error = '' }
    if ($ServicePresent) { $service = & $read $ServiceConfigPath }

    return [pscustomobject]@{
        UserPath      = $UserConfigPath
        UserExists    = [bool]$user.Exists
        UserServer    = [string]$user.Server
        UserRelay     = [string]$user.Relay
        UserError     = [string]$user.Error
        ServicePath   = $ServiceConfigPath
        ServiceExists = [bool]$service.Exists
        ServiceServer = [string]$service.Server
        ServiceRelay  = [string]$service.Relay
        ServiceError  = [string]$service.Error
    }
}

function Set-VegaRustDeskConfig {
    <#
      写 RustDesk2.toml：当前用户路径总是写；RustDesk 服务存在时也写服务模式路径。
      当前用户路径的记录写调用方给的清单（host-state / client-state）；
      LocalService 路径的记录只写管理员清单 %ProgramData%\Vega\state.json。
      只为实际变化的键登记基线，写入并回读确认后才保存（标记为待回滚）。
      返回 { Applied, Warnings, ServicePresent, Values, State }。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Server,

        [Parameter(Mandatory)]
        [string]$Key,

        [AllowNull()]
        $State = $null,

        [AllowEmptyString()]
        [string]$StatePath = '',

        [AllowEmptyString()]
        [string]$UserConfigPath = '',

        [AllowEmptyString()]
        [string]$ServiceConfigPath = '',

        [AllowEmptyString()]
        [string]$ServiceStatePath = '',

        [AllowEmptyString()]
        [string]$RelayServer = '',

        [switch]$ForceService
    )

    $endpoint = ConvertFrom-VegaRustDeskServerEndpoint -Server $Server
    if ($null -eq $endpoint) { throw 'RustDesk 服务器地址格式无效（应为 主机名/IPv4/IPv6，可带 :端口）。' }

    # 默认由 ID 服务器推导中继（:21117）；安装包的默认配置允许单独指定中继服务器。
    $relayValue = $endpoint.RelayServer
    if (-not [string]::IsNullOrWhiteSpace($RelayServer)) {
        $relayEndpoint = ConvertFrom-VegaRustDeskServerEndpoint -Server $RelayServer
        if ($null -eq $relayEndpoint) { throw 'RustDesk 中继服务器地址格式无效（应为 主机名/IPv4/IPv6，可带 :端口）。' }
        $relayValue = $relayEndpoint.RelayServer
    }

    if ([string]::IsNullOrWhiteSpace($UserConfigPath)) { $UserConfigPath = Get-VegaRustDeskConfigPath }
    if ([string]::IsNullOrWhiteSpace($ServiceConfigPath)) { $ServiceConfigPath = Get-VegaRustDeskConfigPath -ServiceMode }
    if ([string]::IsNullOrWhiteSpace($ServiceStatePath)) { $ServiceStatePath = Get-VegaRustDeskServiceStatePath }

    $values = [ordered]@{
        'custom-rendezvous-server' = $endpoint.Server
        'relay-server'             = $relayValue
        'key'                      = $Key.Trim()
    }
    $managedKeys = @(Get-VegaRustDeskManagedKeyName)

    $service = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    $servicePresent = ($null -ne $service)

    $targets = New-Object System.Collections.Generic.List[string]
    $targets.Add($UserConfigPath)
    if ($servicePresent -or $ForceService) {
        if ($ServiceConfigPath -ne $UserConfigPath) { $targets.Add($ServiceConfigPath) }
    }

    $applied = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]

    foreach ($target in $targets) {
        # 安装写入与回滚共用同一校验：从 %APPDATA%（或 LocalService Roaming）起
        # 逐级拒绝重解析点，避免用户侧目录联接把提权写入重定向到服务配置。
        if (-not (Test-VegaRustDeskManagedConfigPath -Path $target -ExpectedPath $target)) {
            $message = "RustDesk 配置路径包含重解析点或位置异常，拒绝写入：$target"
            if ([string]::Equals($target, $UserConfigPath, [StringComparison]::OrdinalIgnoreCase)) { throw $message }
            $warnings.Add($message)
            Write-Warning $message
            continue
        }

        $existingText = ''
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $existingText = Get-Content -LiteralPath $target -Raw -Encoding UTF8
        }

        $isServiceTarget = [string]::Equals($target, $ServiceConfigPath, [StringComparison]::OrdinalIgnoreCase)
        $targetState = $State
        $targetStatePath = $StatePath
        if ($isServiceTarget) {
            $targetStatePath = $ServiceStatePath
            if (-not [string]::Equals($targetStatePath, $StatePath, [StringComparison]::OrdinalIgnoreCase)) {
                try {
                    $targetState = Read-VegaState -Path $targetStatePath
                }
                catch {
                    # 管理员清单不可信/读不了：不动服务配置，也不把它记进用户清单。
                    $message = "读取服务模式记录清单失败，跳过服务配置：$($_.Exception.Message)"
                    $warnings.Add($message)
                    Write-Warning $message
                    continue
                }
            }
        }

        $changed = $null
        if ($null -ne $targetState) {
            $snapshot = Get-VegaRustDeskConfigKeySnapshot -Text $existingText -Keys $managedKeys
            # 只登记实际变化的键：值相同、写入失败的键都不该留下待回滚记录。
            $changed = [ordered]@{}
            foreach ($managedKey in $managedKeys) {
                $item = $snapshot[$managedKey]
                if ($null -eq $item) { continue }
                if (-not [bool]$item.Existed -or -not [string]::Equals([string]$item.OriginalValue, [string]$values[$managedKey], [StringComparison]::Ordinal)) {
                    $changed[$managedKey] = $item
                }
            }
        }

        $merged = Merge-VegaRustDeskConfigText -ExistingText $existingText -Values $values

        if (-not $PSCmdlet.ShouldProcess($target, '写入 RustDesk 中继配置')) { continue }

        try {
            $null = Write-VegaTextFileAtomic -Path $target -Text $merged

            # 回读确认：三个键都真的落到文件里，才把记录标记为待回滚。
            $verifyText = Get-Content -LiteralPath $target -Raw -Encoding UTF8
            $verified = ConvertFrom-VegaRustDeskConfigText -Text $verifyText
            foreach ($managedKey in $managedKeys) {
                if (-not $verified.Contains($managedKey) -or -not [string]::Equals([string]$verified[$managedKey], [string]$values[$managedKey], [StringComparison]::Ordinal)) {
                    throw "回读 $target 时 $managedKey 与写入值不一致"
                }
            }

            # 回读通过后才登记并保存待回滚记录。
            if ($null -ne $targetState -and $null -ne $changed -and $changed.Count -gt 0) {
                $targetState = Add-VegaStateRustDeskKey -State $targetState -Path $target -Snapshot $changed
            }
            if ($null -ne $targetState -and -not [string]::IsNullOrWhiteSpace($targetStatePath)) {
                $null = Save-VegaState -State $targetState -Path $targetStatePath
                # 服务模式记录写的是独立管理员清单，不要把调用方的 State 换成它。
                if (-not $isServiceTarget -or [string]::Equals($targetStatePath, $StatePath, [StringComparison]::OrdinalIgnoreCase)) {
                    $State = $targetState
                }
            }

            $applied.Add([pscustomobject]@{ Path = $target; Changed = (-not [string]::Equals($merged, $existingText, [StringComparison]::Ordinal)) })
        }
        catch {
            # 主控端通常不是管理员：服务模式路径写不了只警告，不影响当前用户配置。
            $message = "写入 $target 失败：$($_.Exception.Message)"
            if ($target -eq $UserConfigPath) { throw $message }
            $warnings.Add($message)
            Write-Warning $message
        }
    }

    return [pscustomobject]@{
        Applied        = $applied.ToArray()
        Warnings       = $warnings.ToArray()
        ServicePresent = $servicePresent
        Values         = $values
        State          = $State
    }
}

function Restore-VegaRustDeskConfig {
    <#
      卸载用：只把清单记录的受管键恢复为首次写入前的原值；原本没有的键整行删除。
      其他段与其他键原样保留。只处理三个受管键，其他键忽略。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Records
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Restored = $false; Changed = $false; Message = "配置不存在，跳过按键回滚：$Path" }
    }

    $managedKeys = @(Get-VegaRustDeskManagedKeyName)
    $values = [ordered]@{}
    $remove = New-Object System.Collections.Generic.List[string]
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $key = [string]$record.Key
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($managedKeys -cnotcontains $key) { continue }
        if ([bool]$record.Existed) {
            $originalValue = ''
            if ($null -ne $record.PSObject.Properties['OriginalValue']) {
                $originalValue = [string]$record.OriginalValue
            }
            elseif ($null -ne $record.PSObject.Properties['Value']) {
                $originalValue = [string]$record.Value
            }
            $values[$key] = $originalValue
        }
        else {
            $remove.Add($key)
        }
    }

    if ($values.Count -eq 0 -and $remove.Count -eq 0) {
        return [pscustomobject]@{ Restored = $true; Changed = $false; Message = "没有受管键需要回滚：$Path" }
    }

    $current = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $merged = Merge-VegaRustDeskConfigText -ExistingText $current -Values $values -RemoveKeys $remove.ToArray()
    if ([string]::Equals($merged, $current, [StringComparison]::Ordinal)) {
        return [pscustomobject]@{ Restored = $true; Changed = $false; Message = "受管键已是原始值：$Path" }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, '按键回滚 RustDesk 配置')) {
        return [pscustomobject]@{ Restored = $false; Changed = $false; Message = "跳过按键回滚：$Path" }
    }

    $null = Write-VegaTextFileAtomic -Path $Path -Text $merged
    return [pscustomobject]@{ Restored = $true; Changed = $true; Message = "已把受管键恢复为原始值：$Path" }
}

function Restore-VegaRustDeskState {
    <#
      按清单回滚 RustDesk 配置：
        - 记录路径规范化后必须与预期路径完全一致，且父目录不是重解析点；
        - 只恢复 custom-rendezvous-server / relay-server / key，其他键忽略并警告；
        - 每个成功回滚的键立即写回清单。
      返回 { State, Failures, Messages }。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        $State,

        [AllowEmptyString()]
        [string]$StatePath = '',

        [switch]$ServiceMode,

        [AllowEmptyString()]
        [string]$ExpectedPath = ''
    )

    $failures = New-Object System.Collections.Generic.List[string]
    $messages = New-Object System.Collections.Generic.List[string]
    if ($null -eq $State) {
        return [pscustomobject]@{ State = $State; Failures = $failures.ToArray(); Messages = $messages.ToArray() }
    }

    $managedKeys = @(Get-VegaRustDeskManagedKeyName)
    $paths = @($State.RustDeskConfigKeys | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Path } | Select-Object -Unique)
    foreach ($configPath in $paths) {
        if (-not (Test-VegaRustDeskManagedConfigPath -Path $configPath -ServiceMode:$ServiceMode -ExpectedPath $ExpectedPath)) {
            $failures.Add("清单里的 RustDesk 配置路径与预期路径不一致，拒绝回滚：$configPath")
            $messages.Add($failures[$failures.Count - 1])
            continue
        }

        $records = New-Object System.Collections.Generic.List[object]
        foreach ($record in @(Get-VegaStateRustDeskKey -State $State -Path $configPath)) {
            if ($null -eq $record) { continue }
            if ($managedKeys -cnotcontains [string]$record.Key) {
                $message = "忽略清单里的非受管 RustDesk 键：$([string]$record.Key)"
                $messages.Add($message)
                Write-Warning $message
                continue
            }
            if ([bool]$record.Restored) { continue }
            $records.Add($record)
        }

        if ($records.Count -eq 0) { continue }

        try {
            $restore = Restore-VegaRustDeskConfig -Path $configPath -Records $records.ToArray() -Confirm:$false
        }
        catch {
            $failures.Add("RustDesk 配置回滚中止：$($_.Exception.Message)")
            $messages.Add($failures[$failures.Count - 1])
            Write-Warning $failures[$failures.Count - 1]
            continue
        }
        $messages.Add($restore.Message)
        if ($restore.Restored) {
            foreach ($record in $records) {
                $State = Set-VegaStateRustDeskKeyRestored -State $State -Path $configPath -Key ([string]$record.Key)
            }
            if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
                $null = Save-VegaState -State $State -Path $StatePath
            }
        }
        else {
            $failures.Add("RustDesk 配置回滚未完成：$configPath")
        }
    }

    return [pscustomobject]@{ State = $State; Failures = $failures.ToArray(); Messages = $messages.ToArray() }
}

function Test-VegaProcessElevated {
    <#
      当前进程是否提权（管理员）。非 Windows 返回 $false。
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-VegaWindowsPlatform)) { return $false }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Test-VegaRustDeskSignatureValid {
    <#
      rustdesk.exe 的 Authenticode 签名是否 Valid。取不到签名按无效处理。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        return ([string]$signature.Status -eq 'Valid')
    }
    catch {
        return $false
    }
}

function Get-VegaRustDeskInstall {
    <#
      找 rustdesk.exe；找不到返回 $null。
      -RequireSigned：只返回 Program Files / Program Files (x86) 下且 Authenticode 状态为
      Valid 的副本，并完全不考虑 %LOCALAPPDATA%——提权运行时不能启动低权限目录里的可执行文件。
      -SearchRoot：可注入的安装根目录列表（测试用）；不传时取两个 Program Files
      环境变量中非空的值。Windows 上其中一项为空、或非 Windows 上两者都为空时安全跳过。
    #>
    [CmdletBinding()]
    param(
        [switch]$RequireSigned,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$SearchRoot = @()
    )

    $explicitRoots = $false
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($SearchRoot)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $roots.Add([string]$root)
        $explicitRoots = $true
    }
    if (-not $explicitRoots) {
        foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ([string]::IsNullOrWhiteSpace($root)) { continue }
            $roots.Add([string]$root)
        }
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        $candidates.Add((Join-Path (Join-Path $root 'RustDesk') 'rustdesk.exe'))
    }
    if (-not $RequireSigned -and -not $explicitRoots -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates.Add((Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'Programs') 'RustDesk') 'rustdesk.exe'))
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        if (-not $RequireSigned) { return $candidate }
        if (Test-VegaRustDeskSignatureValid -Path $candidate) { return $candidate }
    }
    return $null
}

function Restart-VegaRustDeskService {
    <#
      只在 RustDesk 服务正在运行时重启，并回读确认。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $service = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return [pscustomobject]@{ Found = $false; Restarted = $false; Status = ''; Message = '未找到 RustDesk 服务，跳过重启' }
    }

    if ([string]$service.Status -ne 'Running') {
        return [pscustomobject]@{ Found = $true; Restarted = $false; Status = [string]$service.Status; Message = "RustDesk 服务未运行（$($service.Status)），跳过重启" }
    }

    if (-not $PSCmdlet.ShouldProcess('RustDesk', '重启 RustDesk 服务')) {
        return [pscustomobject]@{ Found = $true; Restarted = $false; Status = 'Running'; Message = '已跳过（WhatIf）' }
    }

    try {
        Restart-Service -Name 'RustDesk' -Force -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Found = $true; Restarted = $false; Status = [string]$service.Status; Message = "重启 RustDesk 服务失败：$($_.Exception.Message)" }
    }

    $current = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    $status = ''
    if ($null -ne $current) { $status = [string]$current.Status }
    return [pscustomobject]@{
        Found     = $true
        Restarted = ($status -eq 'Running')
        Status    = $status
        Message   = $(if ($status -eq 'Running') { 'RustDesk 服务已重启' } else { "RustDesk 服务状态是 $status，不是 Running" })
    }
}

function Format-VegaRustDeskId {
    <#
      纯函数：把 9 位设备码按 3-3-3 分组；其他格式原样返回。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$DeviceId
    )

    if ([string]::IsNullOrWhiteSpace($DeviceId)) { return '' }
    $text = $DeviceId.Trim()
    if ($text -match '^\d{9}$') {
        return ('{0}-{1}-{2}' -f $text.Substring(0, 3), $text.Substring(3, 3), $text.Substring(6, 3))
    }
    return $text
}

function Test-VegaRustDeskProgramFilesPath {
    <#
      rustdesk.exe 是否位于 Program Files / Program Files (x86) 之下（按规范化路径前缀比较）。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return $false
    }

    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        try {
            $rootFull = [System.IO.Path]::GetFullPath([string]$root)
        }
        catch {
            continue
        }
        $rootFull = $rootFull.TrimEnd([char[]]@('\', '/'))
        if ([string]::IsNullOrWhiteSpace($rootFull)) { continue }
        $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }

    return $false
}

function Get-VegaRustDeskDeviceId {
    <#
      调 rustdesk.exe --get-id，超时 15 秒。失败只返回错误，不抛异常。
      提权进程里统一在这里拦截：只允许位于 Program Files 下、Authenticode 状态为 Valid
      的副本；用户目录、显式传入的其他路径与签名无效的副本一律拒绝并给出原因。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Exe = ''
    )

    $elevated = Test-VegaProcessElevated

    if ([string]::IsNullOrWhiteSpace($Exe)) {
        $Exe = $(if ($elevated) { Get-VegaRustDeskInstall -RequireSigned } else { Get-VegaRustDeskInstall })
    }
    if ([string]::IsNullOrWhiteSpace($Exe) -or -not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
        $reason = $(if ($elevated) {
                '未找到 Program Files 下签名有效的 rustdesk.exe；提权进程不执行其他位置的副本'
            }
            else {
                '未找到 rustdesk.exe'
            })
        return [pscustomobject]@{ Success = $false; DeviceId = ''; RawOutput = @(); Error = $reason }
    }

    if ($elevated) {
        if (-not (Test-VegaRustDeskProgramFilesPath -Path $Exe)) {
            return [pscustomobject]@{
                Success   = $false
                DeviceId  = ''
                RawOutput = @()
                Error     = "拒绝在提权进程中执行 Program Files 之外的 RustDesk：$Exe。请打开 RustDesk 查看设备码。"
            }
        }
        if (-not (Test-VegaRustDeskSignatureValid -Path $Exe)) {
            return [pscustomobject]@{
                Success   = $false
                DeviceId  = ''
                RawOutput = @()
                Error     = "拒绝在提权进程中执行签名无效的 RustDesk：$Exe。请从 RustDesk 官网重新安装后重试。"
            }
        }
    }

    $result = Invoke-VegaCommand -FilePath $Exe -ArgumentList @('--get-id') -TimeoutSeconds 15
    if ($result.TimedOut) {
        return [pscustomobject]@{ Success = $false; DeviceId = ''; RawOutput = @($result.Output); Error = 'rustdesk --get-id 超时（15 秒）' }
    }
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; DeviceId = ''; RawOutput = @($result.Output); Error = "rustdesk --get-id 退出码 $($result.ExitCode)" }
    }

    foreach ($line in @($result.Output)) {
        $text = ([string]$line).Trim()
        if ($text -match '(?<!\d)(\d{3})\s*[-\s]?\s*(\d{3})\s*[-\s]?\s*(\d{3})(?!\d)') {
            $deviceId = $Matches[1] + $Matches[2] + $Matches[3]
            return [pscustomobject]@{ Success = $true; DeviceId = $deviceId; RawOutput = @($result.Output); Error = '' }
        }
        if ($text -match '^\d{6,12}$') {
            return [pscustomobject]@{ Success = $true; DeviceId = $text; RawOutput = @($result.Output); Error = '' }
        }
    }

    return [pscustomobject]@{ Success = $false; DeviceId = ''; RawOutput = @($result.Output); Error = 'rustdesk --get-id 没有输出可用设备码' }
}

function Invoke-VegaRustDeskSetup {
    <#
      配置中继 -> 重启服务（如果在运行）-> 读设备码 -> 打印完成提示。
      返回 { State, DeviceId, Warnings, Success }；设备码失败只警告。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $Settings,

        [AllowNull()]
        $State = $null,

        [AllowEmptyString()]
        [string]$StatePath = '',

        [AllowEmptyString()]
        [string]$UserConfigPath = '',

        [AllowEmptyString()]
        [string]$ServiceConfigPath = ''
    )

    $warnings = New-Object System.Collections.Generic.List[string]

    Write-VegaStatus ("配置 RustDesk 中继：{0}（relay {1}）" -f $Settings.Server, $Settings.RelayServer)
    $config = Set-VegaRustDeskConfig -Server $Settings.Server -Key $Settings.Key -State $State -StatePath $StatePath `
        -UserConfigPath $UserConfigPath -ServiceConfigPath $ServiceConfigPath -Confirm:$false
    foreach ($warning in @($config.Warnings)) { $warnings.Add([string]$warning) }

    $restart = Restart-VegaRustDeskService -Confirm:$false
    Write-VegaStatus $restart.Message -Level $(if ($restart.Restarted -or -not $restart.Found) { 'Info' } else { 'Warn' })

    # 提权运行时只启动 Program Files 下已签名（Valid）的 rustdesk.exe；
    # 不启动 %LOCALAPPDATA% 等其他位置的副本，否则等于用管理员权限运行用户可写的程序。
    $elevated = Test-VegaProcessElevated
    $deviceExeMissing = $false
    if ($elevated) {
        $deviceExe = Get-VegaRustDeskInstall -RequireSigned
        if ([string]::IsNullOrWhiteSpace($deviceExe)) {
            $deviceExeMissing = $true
            $message = '未找到 Program Files 下签名有效的 rustdesk.exe，不启动任何其他位置的副本；请打开 RustDesk 查看设备码。'
            $warnings.Add($message)
            Write-VegaStatus $message -Level Warn
            $device = [pscustomobject]@{ Success = $false; DeviceId = ''; RawOutput = @(); Error = $message }
        }
        else {
            $device = Get-VegaRustDeskDeviceId -Exe $deviceExe
        }
    }
    else {
        $device = Get-VegaRustDeskDeviceId
    }

    if ($device.Success) {
        Write-VegaStatus ("本机设备码：{0}" -f (Format-VegaRustDeskId -DeviceId $device.DeviceId)) -Level Ok
    }
    elseif ($deviceExeMissing) {
        # 上面已经写过具体原因，这里不再重复
    }
    else {
        $message = "读取 RustDesk 设备码失败：$($device.Error)。装好后可打开 RustDesk 查看设备码。"
        $warnings.Add($message)
        Write-VegaStatus $message -Level Warn
    }

    Write-VegaStatus 'RustDesk 固定密码请自行设置：打开 RustDesk → 设置 → 安全 → 密码；也可使用一次性密码。脚本不接收、不保存任何密码。' -Level Warn

    return [pscustomobject]@{
        State    = $config.State
        DeviceId = $device.DeviceId
        Warnings = $warnings.ToArray()
        Success  = $true
    }
}

# ---------------------------------------------------------------------------
# T3：安装包内的 RustDesk 一键安装（Vega-Setup.exe -> install-rustdesk.ps1）
# ---------------------------------------------------------------------------

function Write-VegaSetupLog {
    <#
      追加一行安装日志。日志写失败绝不影响安装流程，只静默跳过。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path = '',

        [AllowEmptyString()]
        [string]$Message = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    try {
        $directory = Split-Path -Path $Path -Parent
        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
        $line = '{0} {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    }
    catch {
        $null = $_
    }
}

function Get-VegaRustDeskDefaults {
    <#
      读取随安装包发布的 vega-defaults.json（idServer / relayServer / key）。
      fork 者改这个文件即可换成自己的中继；这里只校验，不猜默认值。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "缺少默认配置：$Path"
    }

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($text)) { throw "默认配置是空文件：$Path" }

    try {
        $data = $text | ConvertFrom-Json
    }
    catch {
        throw "默认配置不是合法 JSON：$Path（$($_.Exception.Message)）"
    }

    if ($null -eq $data -or $null -eq $data.PSObject.Properties['rustdesk']) {
        throw "默认配置缺少 rustdesk 段：$Path"
    }
    $rustdesk = $data.rustdesk

    $idServer = [string]$rustdesk.idServer
    $relayServer = [string]$rustdesk.relayServer
    $key = [string]$rustdesk.key

    if ([string]::IsNullOrWhiteSpace($idServer)) { throw "默认配置缺少 rustdesk.idServer：$Path" }
    if ([string]::IsNullOrWhiteSpace($relayServer)) { throw "默认配置缺少 rustdesk.relayServer：$Path" }
    if ($null -eq (ConvertFrom-VegaRustDeskServerEndpoint -Server $idServer)) {
        throw "默认配置 rustdesk.idServer 格式无效：$idServer"
    }
    if ($null -eq (ConvertFrom-VegaRustDeskServerEndpoint -Server $relayServer)) {
        throw "默认配置 rustdesk.relayServer 格式无效：$relayServer"
    }
    if (-not (Test-VegaRustDeskKey -Key $key)) {
        throw "默认配置 rustdesk.key 格式无效（应为 base64 样式公钥）：$Path"
    }

    return [pscustomobject]@{
        Path        = $Path
        IdServer    = $idServer.Trim()
        RelayServer = $relayServer.Trim()
        Key         = $key.Trim()
    }
}

function Get-VegaRustDeskRelease {
    <#
      固定版本 + 官方 Release URL + SHA256。
      RustDesk 是 AGPL：安装包不内嵌二进制，只允许从官方 GitHub Release 下载这一份。
      SHA256 是占位常量，发布前必须由架构师填真实值；占位值永远校验失败，即“必须填”。
    #>
    [CmdletBinding()]
    param()

    # TODO(架构师): 填 RustDesk 官方 Release 资产的真实 SHA256（64 位小写十六进制）。
    # 下面这串全 0 是占位值：校验会失败并中止安装，提醒发布流程确实填过。
    $sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
    $version = '1.3.9'

    return [pscustomobject]@{
        Version  = $version
        FileName = ("rustdesk-{0}-x86_64.exe" -f $version)
        Url      = ("https://github.com/rustdesk/rustdesk/releases/download/{0}/rustdesk-{0}-x86_64.exe" -f $version)
        Sha256   = $sha256
        Page     = 'https://rustdesk.com/download'
    }
}

function Get-VegaRustDeskInstaller {
    <#
      下载固定版本的 Windows x64 安装包并校验 SHA256。
      - 超时 120 秒，下载失败最多 2 次尝试（不无限重试）。
      - 哈希不匹配立即中止，不重试：内容被替换时重试没有意义。
      返回 { Success, Path, Sha256, Error }。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DestinationDirectory,

        [AllowNull()]
        $Release = $null,

        [int]$TimeoutSeconds = 120,

        [int]$MaxAttempts = 2
    )

    if ($null -eq $Release) { $Release = Get-VegaRustDeskRelease }
    $expected = [string]$Release.Sha256
    if ($expected -notmatch '^[0-9a-f]{64}$' -or $expected -eq ('0' * 64)) {
        return [pscustomobject]@{
            Success = $false
            Path    = ''
            Sha256  = ''
            Error   = ("RustDesk {0} 安装包的 SHA256 尚未填写（发布前必须由维护者填入真实值）。请到 {1} 手动下载安装。" -f $Release.Version, $Release.Page)
        }
    }

    try {
        if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
            $null = New-Item -ItemType Directory -Path $DestinationDirectory -Force
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Path = ''; Sha256 = ''; Error = "无法创建下载目录：$($_.Exception.Message)" }
    }

    $target = Join-Path $DestinationDirectory ([string]$Release.FileName)
    $lastError = ''
    $attempts = [Math]::Max(1, $MaxAttempts)

    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        }
        try {
            Invoke-WebRequest -Uri ([string]$Release.Url) -OutFile $target -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
        }
        catch {
            $lastError = $_.Exception.Message
            continue
        }

        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $lastError = '下载命令结束但文件不存在'
            continue
        }

        $actual = ''
        try {
            $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        }
        catch {
            $lastError = "计算 SHA256 失败：$($_.Exception.Message)"
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Success = $false; Path = ''; Sha256 = ''; Error = $lastError }
        }

        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{
                Success = $false
                Path    = ''
                Sha256  = $actual
                Error   = ("下载的 RustDesk 安装包 SHA256 不匹配（期望 {0}，实际 {1}），已删除并中止。请到 {2} 手动下载安装。" -f $expected, $actual, $Release.Page)
            }
        }

        return [pscustomobject]@{ Success = $true; Path = $target; Sha256 = $actual; Error = '' }
    }

    return [pscustomobject]@{
        Success = $false
        Path    = ''
        Sha256  = ''
        Error   = ("下载 RustDesk 安装包失败（已尝试 {0} 次）：{1}。请到 {2} 手动下载安装。" -f $attempts, $lastError, $Release.Page)
    }
}

function Wait-VegaRustDeskService {
    <#
      安装完成后等 RustDesk 服务出现（最多 TimeoutSeconds 秒）。服务可能稍晚注册。
    #>
    [CmdletBinding()]
    param(
        [int]$TimeoutSeconds = 120,

        [int]$IntervalSeconds = 2
    )

    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    $last = $null
    while ($true) {
        $last = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
        if ($null -ne $last) {
            return [pscustomobject]@{ Found = $true; Status = [string]$last.Status }
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds ([Math]::Max(1, $IntervalSeconds))
    }

    return [pscustomobject]@{ Found = $false; Status = '' }
}

function Install-VegaRustDeskSilently {
    <#
      运行官方安装包：--silent-install。超时或非 0 退出码都返回失败原因。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InstallerPath,

        [int]$TimeoutSeconds = 300
    )

    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        return [pscustomobject]@{ Success = $false; ExitCode = -1; Error = "安装包不存在：$InstallerPath" }
    }

    $result = Invoke-VegaCommand -FilePath $InstallerPath -ArgumentList @('--silent-install') -TimeoutSeconds $TimeoutSeconds
    if ($result.TimedOut) {
        return [pscustomobject]@{ Success = $false; ExitCode = $result.ExitCode; Error = "RustDesk 静默安装超时（$TimeoutSeconds 秒）" }
    }
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; ExitCode = $result.ExitCode; Error = "RustDesk 静默安装失败，退出码 $($result.ExitCode)" }
    }

    return [pscustomobject]@{ Success = $true; ExitCode = 0; Error = '' }
}

function Uninstall-VegaRustDeskRecorded {
    <#
      只卸载 state.json 里标明“由 Vega 安装”的 RustDesk。
      优先用注册表里的卸载命令（官方安装包自己登记的），找不到就报告需手动卸载。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        $Record
    )

    $displayName = 'RustDesk'
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $item = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $item) { continue }
            if ([string]$item.DisplayName -notmatch $displayName) { continue }

            $command = [string]$item.QuietUninstallString
            if ([string]::IsNullOrWhiteSpace($command)) { $command = [string]$item.UninstallString }
            if ([string]::IsNullOrWhiteSpace($command)) { continue }
            if (-not $PSCmdlet.ShouldProcess([string]$item.DisplayName, '卸载 RustDesk')) {
                return [pscustomobject]@{ Success = $true; Message = '已跳过（WhatIf）' }
            }

            try {
                $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                $startInfo.FileName = $env:ComSpec
                $startInfo.Arguments = '/c ' + $command
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $process = [System.Diagnostics.Process]::Start($startInfo)
                $null = $process.WaitForExit(120000)
            }
            catch {
                return [pscustomobject]@{ Success = $false; Message = "运行 RustDesk 卸载命令失败：$($_.Exception.Message)" }
            }
            return [pscustomobject]@{ Success = $true; Message = '已按注册表卸载命令卸载 RustDesk' }
        }
    }

    return [pscustomobject]@{
        Success = $false
        Message = ("未找到 RustDesk 的卸载命令（记录：{0}），请在「设置 → 应用」中手动卸载。" -f [string]$Record.Path)
    }
}

function Invoke-VegaRustDeskRollback {
    <#
      安装包卸载时的回滚：只动 Vega 记录过的内容。
      - 用户与服务两处 RustDesk2.toml 的受管键按基线恢复；
      - 若清单标明 RustDesk 是 Vega 装的，连带卸载 RustDesk（-KeepRustDesk 可保留）。
      返回 { Success, ExitCode, Messages, Failures }。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$HostStatePath = (Get-VegaHostStatePath),
        [string]$ServiceStatePath = (Get-VegaRustDeskServiceStatePath),
        [switch]$KeepRustDesk
    )

    $messages = New-Object System.Collections.Generic.List[string]
    $failures = New-Object System.Collections.Generic.List[string]

    if (Test-Path -LiteralPath $HostStatePath -PathType Leaf) {
        try {
            $state = Read-VegaState -Path $HostStatePath
            $restore = Restore-VegaRustDeskState -State $state -StatePath $HostStatePath -Confirm:$false
            foreach ($message in @($restore.Messages)) { $messages.Add([string]$message) }
            foreach ($failure in @($restore.Failures)) { $failures.Add([string]$failure) }
            $state = $restore.State

            if (-not $KeepRustDesk) {
                foreach ($record in @(Get-VegaStateRustDeskInstall -State $state)) {
                    if (-not [bool]$record.InstalledByVega) { continue }
                    $removed = Uninstall-VegaRustDeskRecorded -Record $record -Confirm:$false
                    $messages.Add([string]$removed.Message)
                    if (-not $removed.Success) { $failures.Add([string]$removed.Message) }
                    else { $state = Remove-VegaStateRustDeskInstall -State $state -Path ([string]$record.Path) -Confirm:$false }
                }
                $null = Save-VegaState -State $state -Path $HostStatePath
            }
        }
        catch {
            $failures.Add("回滚用户 RustDesk 配置失败：$($_.Exception.Message)")
        }
    }
    else {
        $messages.Add("没有用户清单，跳过：$HostStatePath")
    }

    if (Test-Path -LiteralPath $ServiceStatePath -PathType Leaf) {
        try {
            $serviceState = Read-VegaState -Path $ServiceStatePath
            $serviceRestore = Restore-VegaRustDeskState -State $serviceState -StatePath $ServiceStatePath -ServiceMode -Confirm:$false
            foreach ($message in @($serviceRestore.Messages)) { $messages.Add([string]$message) }
            foreach ($failure in @($serviceRestore.Failures)) { $failures.Add([string]$failure) }
        }
        catch {
            $failures.Add("回滚服务模式 RustDesk 配置失败：$($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{
        Success  = ($failures.Count -eq 0)
        ExitCode = $(if ($failures.Count -gt 0) { 1 } else { 0 })
        Messages = $messages.ToArray()
        Failures = $failures.ToArray()
    }
}

function Invoke-VegaRustDeskBootstrap {
    <#
      安装包的一键安装/配置流程：
        1. 读 vega-defaults.json；
        2. 没装 RustDesk 才下载（校验 SHA256）+ 静默安装 + 等服务出现；
        3. 写用户与服务两处 RustDesk2.toml（复用 Set-VegaRustDeskConfig 的 ACL/原子写入/回滚记录）；
        4. 若这次是 Vega 装的，把安装记录写进 host-state.json。
      任何一步失败都返回 Success=$false，由调用方决定不阻断安装。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$DefaultsFile,

        [string]$HostStatePath = (Get-VegaHostStatePath),

        [string]$ServiceStatePath = (Get-VegaRustDeskServiceStatePath),

        [AllowEmptyString()]
        [string]$UserConfigPath = '',

        [AllowEmptyString()]
        [string]$ServiceConfigPath = '',

        [AllowEmptyString()]
        [string]$DownloadDirectory = '',

        [AllowEmptyString()]
        [string]$LogFile = ''
    )

    $messages = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($DownloadDirectory)) {
        $DownloadDirectory = Join-Path (Join-Path $env:TEMP 'Vega') 'setup'
    }

    try {
        $defaults = Get-VegaRustDeskDefaults -Path $DefaultsFile
    }
    catch {
        Write-VegaSetupLog -Path $LogFile -Message "FAIL 读取默认配置：$($_.Exception.Message)"
        return [pscustomobject]@{
            Success    = $false
            ExitCode   = 1
            Installed  = $false
            Configured = $false
            Messages   = $messages.ToArray()
            Error      = $_.Exception.Message
        }
    }

    $installedByVega = $false
    $releaseVersion = ''

    $existing = Get-VegaRustDeskInstall
    if ([string]::IsNullOrWhiteSpace($existing)) {
        $release = Get-VegaRustDeskRelease
        $releaseVersion = [string]$release.Version
        Write-VegaSetupLog -Path $LogFile -Message "下载 RustDesk $releaseVersion：$($release.Url)"

        $download = Get-VegaRustDeskInstaller -DestinationDirectory $DownloadDirectory -Release $release
        if (-not $download.Success) {
            Write-VegaSetupLog -Path $LogFile -Message "FAIL 下载：$($download.Error)"
            return [pscustomobject]@{
                Success    = $false
                ExitCode   = 1
                Installed  = $false
                Configured = $false
                Messages   = $messages.ToArray()
                Error      = $download.Error
            }
        }

        Write-VegaSetupLog -Path $LogFile -Message "校验通过：$($download.Sha256)"
        if (-not $PSCmdlet.ShouldProcess('RustDesk', '静默安装 RustDesk')) {
            return [pscustomobject]@{
                Success    = $true
                ExitCode   = 0
                Installed  = $false
                Configured = $false
                Messages   = @('已跳过（WhatIf）')
                Error      = ''
            }
        }

        $install = Install-VegaRustDeskSilently -InstallerPath $download.Path
        if (-not $install.Success) {
            Write-VegaSetupLog -Path $LogFile -Message "FAIL 安装：$($install.Error)"
            return [pscustomobject]@{
                Success    = $false
                ExitCode   = 1
                Installed  = $false
                Configured = $false
                Messages   = $messages.ToArray()
                Error      = $install.Error
            }
        }
        $installedByVega = $true
        $messages.Add("已静默安装 RustDesk $releaseVersion")

        $wait = Wait-VegaRustDeskService
        if ($wait.Found) {
            $messages.Add("RustDesk 服务已出现（$($wait.Status)）")
        }
        else {
            $messages.Add('RustDesk 服务尚未出现；配置已写入，首次启动 RustDesk 后生效。')
        }
    }
    else {
        $messages.Add("已安装 RustDesk，跳过安装：$existing")
    }

    try {
        $state = Read-VegaState -Path $HostStatePath
        # 安装阶段两处配置都要覆盖：服务还没注册时也先写 LocalService 路径，
        # 避免首次以服务模式启动时又用回官方默认服务器。
        $config = Set-VegaRustDeskConfig -Server $defaults.IdServer -Key $defaults.Key -RelayServer $defaults.RelayServer `
            -State $state -StatePath $HostStatePath -UserConfigPath $UserConfigPath -ServiceConfigPath $ServiceConfigPath `
            -ForceService -Confirm:$false
        $state = $config.State
        foreach ($warning in @($config.Warnings)) { $messages.Add([string]$warning) }

        if ($installedByVega) {
            $exePath = Get-VegaRustDeskInstall
            if (-not [string]::IsNullOrWhiteSpace($exePath)) {
                $state = Add-VegaStateRustDeskInstall -State $state -Path $exePath -Version $releaseVersion -InstalledByVega $true
            }
        }
        $null = Save-VegaState -State $state -Path $HostStatePath

        $restart = Restart-VegaRustDeskService -Confirm:$false
        $messages.Add([string]$restart.Message)

        Write-VegaSetupLog -Path $LogFile -Message ("OK 中继 {0}，relay {1}，已配置 {2} 个路径" -f $defaults.IdServer, $defaults.RelayServer, @($config.Applied).Count)
    }
    catch {
        Write-VegaSetupLog -Path $LogFile -Message "FAIL 写配置：$($_.Exception.Message)"
        return [pscustomobject]@{
            Success    = $false
            ExitCode   = 1
            Installed  = $installedByVega
            Configured = $false
            Messages   = $messages.ToArray()
            Error      = "写入 RustDesk 中继配置失败：$($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        Success    = $true
        ExitCode   = 0
        Installed  = $installedByVega
        Configured = $true
        Messages   = $messages.ToArray()
        Error      = ''
    }
}

# ---------------------------------------------------------------------------
# 入口编排：被控端安装 / 卸载
# ---------------------------------------------------------------------------

function Invoke-VegaHostInstall {
    <#
      被控端安装/卸载的公共外壳：装与卸争同一把命名互斥体。
      真正的流程在 *Core 函数里，便于 mock 测试。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$Force,
        [string]$StatePath = (Get-VegaHostStatePath),
        [string]$TemplatePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'sunshine.conf'),
        [string]$RustDeskServer = '',
        [string]$RustDeskKey = ''
    )

    $lock = Enter-VegaSetupLock -Name 'Global\Vega-Host-Setup'
    try {
        return (Invoke-VegaHostInstallCore -SkipTailscale:$SkipTailscale -WithRustDesk:$WithRustDesk `
                -Force:$Force -StatePath $StatePath -TemplatePath $TemplatePath `
                -RustDeskServer $RustDeskServer -RustDeskKey $RustDeskKey -Confirm:$false)
    }
    finally {
        Exit-VegaSetupLock -Lock $lock
    }
}

function Invoke-VegaHostInstallCore {
    <#
      被控端安装流程：
      清单 -> 隔离管理端口 -> 装组件 -> 按键记录配置基线并写入 -> 只放行串流端口
      -> 确认放行后再禁用安装器规则 -> 关睡眠 -> 服务自启。每一步变更立即写清单。
      返回 { ExitCode, Failures }；任何失败都让退出码非零。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$Force,
        [string]$StatePath = (Get-VegaHostStatePath),
        [string]$TemplatePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'sunshine.conf'),
        [string]$RustDeskServer = '',
        [string]$RustDeskKey = ''
    )

    $failures = New-Object System.Collections.Generic.List[string]

    $rustDeskSettings = Resolve-VegaRustDeskSetting -Server $RustDeskServer -Key $RustDeskKey
    if ($null -eq $rustDeskSettings) {
        Write-VegaStatus '未配置 RustDesk 中继（可选）：加 -RustDeskServer <host[:port]> -RustDeskKey <公钥>，或在仓库根目录放 vega.config.json。' -Level Warn
    }

    if (-not (Test-VegaWingetAvailable)) {
        throw '未找到 winget（App Installer）。请按官方文档安装「应用安装程序」后重试。'
    }

    # 读清单：机器级清单会先校验所有者/重解析点，不可信直接抛异常
    $state = Read-VegaState -Path $StatePath

    # 旧版清单只警告、不读取：旧记录没有白名单字段，不能拿来回滚
    $null = Write-VegaLegacyStateWarning

    $existingSunshine = Get-VegaSunshineInstall
    $basePort = 47989
    if ($null -ne $existingSunshine) {
        try {
            $basePort = Get-VegaSunshineBasePort -ConfigPath $existingSunshine.Config
        }
        catch {
            $failures.Add("读取 sunshine.conf 的 port 失败，中止安装：$($_.Exception.Message)")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            return [pscustomobject]@{
                ExitCode = 1
                Failures = $failures.ToArray()
            }
        }
    }
    # 安装前的阻断规则：计算出的管理端口 + 默认 47990，去重。
    # 安装器启动那一刻可能还按默认端口监听，不能漏掉 47990。
    $managementPorts = @(Get-VegaAdminBlockPortList -ManagementPorts @((Get-VegaSunshinePortMap -BasePort $basePort).ManagementPort) `
            -BasePort $basePort -IncludeDefaultManagementPort)

    # 管理端口落进串流放行端口时同端口既放行又阻断：让用户改 port，不要猜
    $portConflicts = @(Test-VegaManagementPortConflict -ManagementPorts $managementPorts -BasePort $basePort)
    if ($portConflicts.Count -gt 0) {
        $failures.Add("管理端口 $($portConflicts -join '/') 与串流放行端口重叠，请先修改 sunshine.conf 里的 port 再重试。")
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        return [pscustomobject]@{
            ExitCode = 1
            Failures = $failures.ToArray()
        }
    }

    # 当前活动网络的防火墙关闭时，阻断规则不会执行；WinGet 一装完 Sunshine 就会启动，
    # 首次设密页面会暴露。必须在调用 WinGet 之前确认，不能只信规则 Enabled=True。
    try {
        if (-not (Test-VegaHostFirewallEnabled)) {
            $status = Get-VegaHostFirewallStatus
            if ([string]$status.Reason -eq 'InterfaceExcluded') {
                # 接口被排除不是“防火墙关闭”，提示必须写出接口别名与配置文件
                $message = [string]$status.Message
            }
            else {
                $message = 'Windows 防火墙在当前网络已关闭，Vega 无法保护首次设密页面，请开启防火墙后重试'
                if (-not [string]::IsNullOrWhiteSpace([string]$status.Message)) {
                    $message = "$message（$($status.Message)）"
                }
            }
            $failures.Add($message)
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            return [pscustomobject]@{
                ExitCode = 1
                Failures = $failures.ToArray()
            }
        }
    }
    catch {
        $failures.Add("无法确认 Windows 防火墙状态，中止安装：$($_.Exception.Message)")
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        return [pscustomobject]@{
            ExitCode = 1
            Failures = $failures.ToArray()
        }
    }

    # 管理端口隔离必须早于 winget 安装：安装器会先放行并启动服务。
    # 隔离失败直接中止，退出码非零。
    try {
        $null = Set-VegaAdminBlockRule -ManagementPorts $managementPorts -Confirm:$false
        $state = Add-VegaStateFirewallRule -State $state -Name 'Vega-Block-Admin'
        $null = Save-VegaState -State $state -Path $StatePath
        Write-VegaStatus ("已先阻断管理端口入站：{0}" -f ($managementPorts -join '/')) -Level Ok
    }
    catch {
        $failures.Add("管理端口隔离失败，中止安装：$($_.Exception.Message)")
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        return [pscustomobject]@{
            ExitCode = 1
            Failures = $failures.ToArray()
        }
    }

    # 服务基线必须在 winget 安装/重装之前采集：重装会把服务重置成安装器的默认值，
    # 装完再采集就把安装器的状态当成了用户原来的状态。
    Write-VegaStatus '记录 Sunshine 服务基线（安装/重装前）'
    foreach ($snapshot in @(Get-VegaSunshineServiceSnapshot)) {
        $state = Add-VegaStateService -State $state -Name $snapshot.Name `
            -StartType $snapshot.StartType -Status $snapshot.Status
    }
    $null = Save-VegaState -State $state -Path $StatePath

    # RustDesk 不再走 winget：WinGet 社区源已下架 RustDesk，改成提示用户从官方页手动安装。
    if ($WithRustDesk) {
        Write-VegaStatus 'RustDesk 已从 WinGet 源下架，无法自动安装。请打开 https://github.com/rustdesk/rustdesk/releases/latest 下载并手动安装；已安装的 RustDesk 仍会应用中继配置。' -Level Warn
    }

    $componentNames = New-Object System.Collections.Generic.List[string]
    $componentNames.Add('Sunshine')
    if (-not $SkipTailscale) { $componentNames.Add('Tailscale') }

    foreach ($name in $componentNames) {
        $component = Get-VegaComponent -Name $name
        Write-VegaStatus "安装 $($component.Name)"

        $outcome = $null
        try {
            $outcome = Install-VegaPackage -PackageId $component.PackageId -DisplayName $component.Name -Force:$Force -Confirm:$false
        }
        catch {
            $failures.Add("安装 $($component.Name) 失败：$($_.Exception.Message)")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            continue
        }

        if (Test-VegaStatePackage -State $state -PackageId $component.PackageId) { continue }
        if ($null -eq $outcome) { continue }

        # 安装前就存在的实例永远算 PreExisting，-Force 重装也不改归属
        if ($outcome.PreExisting) {
            $state = Add-VegaStatePackage -State $state -PackageId $component.PackageId -Name $component.Name -PreExisting
            $null = Save-VegaState -State $state -Path $StatePath
            Write-VegaStatus "$($component.Name) 安装前已存在，登记为 PreExisting（不会被 -RemoveApps 卸载）"
            continue
        }

        if ($outcome.Installed) {
            $state = Add-VegaStatePackage -State $state -PackageId $component.PackageId -Name $component.Name
            $null = Save-VegaState -State $state -Path $StatePath
        }
    }

    if ($null -ne $rustDeskSettings) {
        try {
            $rustDeskResult = Invoke-VegaRustDeskSetup -Settings $rustDeskSettings -State $state -StatePath $StatePath -Confirm:$false
            $state = $rustDeskResult.State
            $null = Save-VegaState -State $state -Path $StatePath
        }
        catch {
            $failures.Add("配置 RustDesk 中继失败：$($_.Exception.Message)")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        }
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

    try {
        $basePort = Get-VegaSunshineBasePort -ConfigPath $sunshine.Config
    }
    catch {
        $failures.Add("读取 sunshine.conf 的 port 失败，中止安装：$($_.Exception.Message)")
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        return [pscustomobject]@{
            ExitCode = 1
            Failures = $failures.ToArray()
        }
    }
    $ports = Get-VegaSunshinePortMap -BasePort $basePort

    # 安装器可能改过配置端口：按生效配置原地更新阻断规则的端口（规则保留，不删）。
    # 安装完成后的最终规则：只有 47990 不是串流端口时才继续阻断它。
    $actualManagementPorts = @(Get-VegaAdminBlockPortList -ManagementPorts @($ports.ManagementPort) -BasePort $basePort)
    $portConflicts = @(Test-VegaManagementPortConflict -ManagementPorts $actualManagementPorts -BasePort $basePort)
    if ($portConflicts.Count -gt 0) {
        $failures.Add("管理端口 $($portConflicts -join '/') 与串流放行端口重叠，请先修改 sunshine.conf 里的 port 再重试。")
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        return [pscustomobject]@{
            ExitCode = 1
            Failures = $failures.ToArray()
        }
    }

    try {
        $null = Set-VegaAdminBlockRule -ManagementPorts $actualManagementPorts -Confirm:$false
        $state = Add-VegaStateFirewallRule -State $state -Name 'Vega-Block-Admin'
        $null = Save-VegaState -State $state -Path $StatePath
    }
    catch {
        $failures.Add("管理端口隔离失败，中止安装：$($_.Exception.Message)")
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        return [pscustomobject]@{
            ExitCode = 1
            Failures = $failures.ToArray()
        }
    }

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

    # 首次安装只记录受管键的原值；重跑不覆盖已有基线
    $snapshot = Get-VegaConfigKeySnapshot -Text $existingText -Keys @($values.Keys | ForEach-Object { [string]$_ })
    $state = Add-VegaStateManagedKey -State $state -Path $sunshine.Config -Snapshot $snapshot
    $null = Save-VegaState -State $state -Path $StatePath

    $merged = Merge-VegaSunshineConfigText -ExistingText $existingText -Values $values
    $null = Set-VegaSunshineConfig -Path $sunshine.Config -Content $merged -Confirm:$false
    Write-VegaStatus "配置已写入 $($sunshine.Config)"

    Write-VegaStatus "放行串流端口（仅 sunshine.exe，不含管理端口 $($ports.ManagementPort)）"
    try {
        # 每建成一条就写回清单：第二条失败时第一条仍然可回滚。
        $persistRule = {
            param([string]$RuleName)
            $state = Add-VegaStateFirewallRule -State $state -Name $RuleName
            $null = Save-VegaState -State $state -Path $StatePath
        }.GetNewClosure()

        $null = @(Set-VegaFirewallRule -Program $sunshine.Exe -BasePort $basePort -OnRuleCreated $persistRule -Confirm:$false)
        Write-VegaStatus ("Vega 防火墙规则已就绪（TCP {0}；UDP {1}）" -f ($ports.TcpPorts -join '/'), ($ports.UdpPorts -join '/')) -Level Ok
    }
    catch {
        # 放行规则没确认成功就不禁用安装器规则：否则两条都没了
        $failures.Add("防火墙规则创建失败，中止安装（未禁用安装器规则）：$($_.Exception.Message)")
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        return [pscustomobject]@{
            ExitCode = 1
            Failures = $failures.ToArray()
        }
    }

    # v0.1 旧规则只在新串流放行规则与阻断规则都回读成功之后才删除：
    # 前面任何一步中止时，旧规则仍然守着端口。旧版只设了 DisplayName，
    # 内部 Name 是 Windows 生成的，所以按 DisplayName 选、按 Name 删。
    try {
        $legacyRules = @(Remove-VegaLegacyFirewallRule -Confirm:$false)
        if ($legacyRules.Count -gt 0) {
            Write-VegaStatus ("已清理旧版 Vega 防火墙规则：{0}" -f ($legacyRules -join '、')) -Level Ok
        }
    }
    catch {
        $failures.Add("清理旧版防火墙规则失败：$($_.Exception.Message)")
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
    }

    # 串流放行规则已回读确认，再隔离 Sunshine 安装器自带的对管理端口放行规则
    try {
        $state = Protect-VegaSunshineManagementPort -State $state -SunshineExe $sunshine.Exe `
            -ManagementPort $ports.ManagementPort -StatePath $StatePath -Confirm:$false
    }
    catch {
        $failures.Add("隔离 Sunshine 安装器放行规则失败，中止安装：$($_.Exception.Message)")
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        return [pscustomobject]@{
            ExitCode = 1
            Failures = $failures.ToArray()
        }
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
        # 基线已在 winget 之前记过，这里不再采集（否则记的是安装器写的状态）
        $service = $services[0]

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
      被控端卸载外壳：与安装共用同一把互斥体。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$RemoveApps,
        [string]$StatePath = (Get-VegaHostStatePath)
    )

    $lock = Enter-VegaSetupLock -Name 'Global\Vega-Host-Setup'
    try {
        return (Invoke-VegaHostUninstallCore -SkipTailscale:$SkipTailscale -WithRustDesk:$WithRustDesk `
                -RemoveApps:$RemoveApps -StatePath $StatePath -Confirm:$false)
    }
    finally {
        Exit-VegaSetupLock -Lock $lock
    }
}

function Invoke-VegaHostUninstallCore {
    <#
      被控端卸载：只按状态清单回滚，且每条记录先过白名单。
      - 删除清单记录的 Vega 防火墙规则（逐项写回）
      - 恢复记录过的安装器防火墙规则
      - 受管配置键恢复为首次安装前的原值（其他键原样保留）
      - 服务只恢复清单记录的值
      - -RemoveApps 只卸载 Vega 新装的组件
      所有记录都成功回滚后才删除清单。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$RemoveApps,
        [string]$StatePath = (Get-VegaHostStatePath)
    )

    $failures = New-Object System.Collections.Generic.List[string]
    $hasState = Test-Path -LiteralPath $StatePath -PathType Leaf
    $state = Read-VegaState -Path $StatePath

    if (-not $hasState) {
        Write-VegaStatus '没有找到状态清单：只清理 Vega 固定名称的防火墙规则，其余保持现状。' -Level Warn
    }

    # 旧版清单只警告、不读取：旧记录没有白名单字段，不能拿来回滚
    $null = Write-VegaLegacyStateWarning

    $sunshine = Get-VegaSunshineInstall
    $sunshineDirectory = ''
    if ($null -ne $sunshine) { $sunshineDirectory = [string]$sunshine.Directory }

    Write-VegaStatus '清理旧版 Vega 防火墙规则'
    try {
        $legacyRules = @(Remove-VegaLegacyFirewallRule -Confirm:$false)
        if ($legacyRules.Count -gt 0) {
            Write-VegaStatus ("已删除旧版规则：{0}" -f ($legacyRules -join '、')) -Level Ok
        }
    }
    catch {
        $failures.Add("清理旧版防火墙规则失败：$($_.Exception.Message)")
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
    }

    Write-VegaStatus '删除 Vega 防火墙规则'
    foreach ($item in @($state.FirewallRules)) {
        if ($null -eq $item) { continue }
        $ruleName = [string]$item.Name
        if (-not (Test-VegaStateRecordAllowed -Kind 'FirewallRule' -Value $ruleName)) {
            $failures.Add("清单里的防火墙规则名不在白名单，拒绝删除：$ruleName")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            continue
        }

        if (Remove-VegaFirewallRuleByName -Name $ruleName -Confirm:$false) {
            $state = Remove-VegaStateFirewallRule -State $state -Name $ruleName
            $null = Save-VegaState -State $state -Path $StatePath
            Write-VegaStatus "已删除防火墙规则 $ruleName"
        }
        else {
            $failures.Add("未能删除防火墙规则：$ruleName")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        }
    }

    # 清单里没有的固定名称规则（旧安装、无清单卸载）也一并清理，含 Vega-Block-Admin
    foreach ($fixedName in (Get-VegaAllowedFirewallRuleName)) {
        if (-not (Remove-VegaFirewallRuleByName -Name $fixedName -Confirm:$false)) {
            $failures.Add("未能删除防火墙规则：$fixedName")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        }
    }

    $disabledNames = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($state.DisabledFirewallRules)) {
        if ($null -eq $item) { continue }
        $ruleName = [string]$item.Name
        if (-not [string]::IsNullOrWhiteSpace($ruleName)) { $disabledNames.Add($ruleName) }
    }
    if ($disabledNames.Count -gt 0) {
        $enabled = @(Enable-VegaSunshineInstallerFirewallRule -Name $disabledNames.ToArray() -SunshineExe $sunshineDirectory -Confirm:$false)
        foreach ($ruleName in $disabledNames) {
            if ($enabled -notcontains $ruleName) {
                $failures.Add("未能恢复安装器防火墙规则：$ruleName")
                Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
                continue
            }
            $state = Remove-VegaStateDisabledFirewallRule -State $state -Name $ruleName
            $null = Save-VegaState -State $state -Path $StatePath
        }
    }

    Write-VegaStatus '按原始值回滚 Sunshine 配置（只动受管键）'
    $configPaths = @($state.ManagedConfigKeys | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Path } | Select-Object -Unique)
    foreach ($configPath in $configPaths) {
        if (-not (Test-VegaStateRecordAllowed -Kind 'ConfigPath' -Value $configPath -SunshineDirectory $sunshineDirectory)) {
            $failures.Add("清单里的配置路径不在白名单，拒绝回滚：$configPath")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            continue
        }

        $records = @(Get-VegaStateManagedKey -State $state -Path $configPath | Where-Object { -not [bool]$_.Restored })
        $restore = Restore-VegaManagedConfig -Path $configPath -Records $records -Confirm:$false
        Write-VegaStatus $restore.Message
        if ($restore.Restored) {
            foreach ($record in $records) {
                $state = Set-VegaStateManagedKeyRestored -State $state -Path $configPath -Key ([string]$record.Key)
            }
            $null = Save-VegaState -State $state -Path $StatePath
        }
        else {
            $failures.Add("配置回滚未完成：$configPath")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        }
    }

    Write-VegaStatus '回滚 RustDesk 配置（用户配置；只动三个受管键）'
    $userRestore = Restore-VegaRustDeskState -State $state -StatePath $StatePath -Confirm:$false
    $state = $userRestore.State
    foreach ($message in @($userRestore.Messages)) { Write-VegaStatus $message }
    foreach ($failure in @($userRestore.Failures)) {
        $failures.Add([string]$failure)
        Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
    }

    # LocalService（服务模式）记录只能在管理员清单 state.json 里，并且只按精确路径回滚。
    Write-VegaStatus '回滚 RustDesk 服务模式配置（管理员清单）'
    $serviceStatePath = Get-VegaRustDeskServiceStatePath
    if (Test-Path -LiteralPath $serviceStatePath -PathType Leaf) {
        try {
            $serviceState = Read-VegaState -Path $serviceStatePath
            $serviceRestore = Restore-VegaRustDeskState -State $serviceState -StatePath $serviceStatePath -ServiceMode -Confirm:$false
            foreach ($message in @($serviceRestore.Messages)) { Write-VegaStatus $message }
            foreach ($failure in @($serviceRestore.Failures)) {
                $failures.Add([string]$failure)
                Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            }
        }
        catch {
            $failures.Add("服务模式记录清单不可用，跳过回滚：$($_.Exception.Message)")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        }
    }
    else {
        Write-VegaStatus "没有服务模式 RustDesk 记录：$serviceStatePath"
    }

    Write-VegaStatus '恢复 Sunshine 服务状态'
    foreach ($entry in @($state.Services)) {
        if ($null -eq $entry) { continue }
        $serviceName = [string]$entry.Name
        if (-not (Test-VegaStateRecordAllowed -Kind 'Service' -Value $serviceName)) {
            $failures.Add("清单里的服务名不在白名单，拒绝操作：$serviceName")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            continue
        }

        # 已经恢复过的服务不再重复恢复：重跑卸载不能把用户后来改的设置改回去
        if ($null -ne $entry.PSObject.Properties['Restored'] -and [bool]$entry.Restored) {
            Write-VegaStatus "服务已恢复过，跳过：$serviceName"
            continue
        }

        $startType = [string]$entry.OriginalStartType
        if ($startType -eq 'NotPresent') {
            # 安装前就没有这个服务：什么都不做，只标记已处理
            $state = Set-VegaStateServiceRestored -State $state -Name $serviceName
            $null = Save-VegaState -State $state -Path $StatePath
            Write-VegaStatus "安装前没有服务 $serviceName，跳过恢复"
            continue
        }
        if ($startType -notin @('Automatic', 'Manual', 'Disabled')) {
            $failures.Add("服务启动类型记录无效：$serviceName → $startType")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            continue
        }

        $restore = Restore-VegaSunshineServiceState -Name $serviceName -StartType $startType `
            -OriginalStatus ([string]$entry.OriginalStatus) -Confirm:$false
        if (-not $restore.Success) {
            $failures.Add($restore.Message)
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            continue
        }

        $state = Set-VegaStateServiceRestored -State $state -Name $serviceName
        $null = Save-VegaState -State $state -Path $StatePath
        Write-VegaStatus $restore.Message
    }

    if ($RemoveApps) {
        Write-VegaStatus '按清单卸载 Vega 安装的组件'
        $targets = @()
        foreach ($package in @($state.Packages)) {
            if ($null -eq $package) { continue }
            if (-not [bool]$package.InstalledByVega) { continue }
            $packageId = [string]$package.PackageId
            # 旧清单里的 RustDesk.RustDesk 已随 WinGet 下架：先销账并提示手动卸载，
            # 不当作白名单违规，也不让回滚因此失败。
            if (Test-VegaRetiredPackageId -PackageId $packageId) {
                Write-VegaStatus "旧清单里的 RustDesk winget 包已下架，请从「设置 → 应用」手动卸载 RustDesk；该记录已标记为已处理。" -Level Warn
                $state = Remove-VegaStatePackage -State $state -PackageId $packageId
                $null = Save-VegaState -State $state -Path $StatePath
                continue
            }
            if (-not (Test-VegaStateRecordAllowed -Kind 'Package' -Value $packageId)) {
                $failures.Add("清单里的包 ID 不在白名单，拒绝卸载：$packageId")
                Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
                continue
            }
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
                    $null = Save-VegaState -State $state -Path $StatePath
                }
                catch {
                    $failures.Add("卸载 $packageName 失败：$($_.Exception.Message)")
                    Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
                }
            }
        }
    }

    # 所有记录都成功回滚后才删清单；未指定 -RemoveApps、或按参数跳过 Tailscale/RustDesk 时，
    # 仍有 InstalledByVega 的包没回滚，必须保留清单，不能把待办一起删掉。
    $pendingPackages = @($state.Packages | Where-Object { $null -ne $_ -and [bool]$_.InstalledByVega })
    if ($hasState) {
        if ($failures.Count -eq 0 -and $pendingPackages.Count -eq 0) {
            Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
            Write-VegaStatus '清单里的事项已全部回滚，删除状态清单。'
        }
        elseif ($pendingPackages.Count -gt 0) {
            Write-VegaStatus "仍有未卸载的 Vega 组件，保留状态清单：$StatePath（需要卸载时加 -RemoveApps）" -Level Warn
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
    <#
      主控端安装。状态清单落在 %LOCALAPPDATA%\Vega\client-state.json。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$Force,
        [string]$StatePath = (Get-VegaClientStatePath),
        [string]$RustDeskServer = '',
        [string]$RustDeskKey = ''
    )

    $lock = Enter-VegaSetupLock -Name 'Local\Vega-Client-Setup'
    try {
        return (Invoke-VegaClientInstallCore -SkipTailscale:$SkipTailscale -WithRustDesk:$WithRustDesk `
                -Force:$Force -StatePath $StatePath `
                -RustDeskServer $RustDeskServer -RustDeskKey $RustDeskKey -Confirm:$false)
    }
    finally {
        Exit-VegaSetupLock -Lock $lock
    }
}

function Invoke-VegaClientInstallCore {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$Force,
        [string]$StatePath = (Get-VegaClientStatePath),
        [string]$RustDeskServer = '',
        [string]$RustDeskKey = ''
    )

    $failures = New-Object System.Collections.Generic.List[string]

    $rustDeskSettings = Resolve-VegaRustDeskSetting -Server $RustDeskServer -Key $RustDeskKey
    if ($null -eq $rustDeskSettings) {
        Write-VegaStatus '未配置 RustDesk 中继（可选）：加 -RustDeskServer <host[:port]> -RustDeskKey <公钥>，或在仓库根目录放 vega.config.json。' -Level Warn
    }

    if (-not (Test-VegaWingetAvailable)) {
        throw '未找到 winget（App Installer）。请按官方文档安装「应用安装程序」后重试。'
    }

    $state = Read-VegaState -Path $StatePath

    # RustDesk 不再走 winget：WinGet 社区源已下架 RustDesk，改成提示用户从官方页手动安装。
    if ($WithRustDesk) {
        Write-VegaStatus 'RustDesk 已从 WinGet 源下架，无法自动安装。请打开 https://github.com/rustdesk/rustdesk/releases/latest 下载并手动安装；已安装的 RustDesk 仍会应用中继配置。' -Level Warn
    }

    $componentNames = New-Object System.Collections.Generic.List[string]
    $componentNames.Add('Moonlight')
    if (-not $SkipTailscale) { $componentNames.Add('Tailscale') }

    foreach ($name in $componentNames) {
        $component = Get-VegaComponent -Name $name
        Write-VegaStatus "安装 $($component.Name)"

        $outcome = $null
        try {
            $outcome = Install-VegaPackage -PackageId $component.PackageId -DisplayName $component.Name -Force:$Force -Confirm:$false
        }
        catch {
            $failures.Add("安装 $($component.Name) 失败：$($_.Exception.Message)")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            continue
        }

        if (Test-VegaStatePackage -State $state -PackageId $component.PackageId) { continue }
        if ($null -eq $outcome) { continue }

        # 安装前就存在的实例永远算 PreExisting，-Force 重装也不改归属
        if ($outcome.PreExisting) {
            $state = Add-VegaStatePackage -State $state -PackageId $component.PackageId -Name $component.Name -PreExisting
            $null = Save-VegaState -State $state -Path $StatePath
            Write-VegaStatus "$($component.Name) 安装前已存在，登记为 PreExisting（不会被 -RemoveApps 卸载）"
            continue
        }

        if ($outcome.Installed) {
            $state = Add-VegaStatePackage -State $state -PackageId $component.PackageId -Name $component.Name
            $null = Save-VegaState -State $state -Path $StatePath
        }
    }

    if ($null -ne $rustDeskSettings) {
        try {
            $rustDeskResult = Invoke-VegaRustDeskSetup -Settings $rustDeskSettings -State $state -StatePath $StatePath -Confirm:$false
            $state = $rustDeskResult.State
            $null = Save-VegaState -State $state -Path $StatePath
        }
        catch {
            $failures.Add("配置 RustDesk 中继失败：$($_.Exception.Message)")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        }
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
        [string]$StatePath = (Get-VegaClientStatePath)
    )

    $lock = Enter-VegaSetupLock -Name 'Local\Vega-Client-Setup'
    try {
        return (Invoke-VegaClientUninstallCore -SkipTailscale:$SkipTailscale -WithRustDesk:$WithRustDesk `
                -RemoveApps:$RemoveApps -StatePath $StatePath -Confirm:$false)
    }
    finally {
        Exit-VegaSetupLock -Lock $lock
    }
}

function Invoke-VegaClientUninstallCore {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$SkipTailscale,
        [switch]$WithRustDesk,
        [switch]$RemoveApps,
        [string]$StatePath = (Get-VegaClientStatePath)
    )

    $failures = New-Object System.Collections.Generic.List[string]

    $hasState = Test-Path -LiteralPath $StatePath -PathType Leaf
    $state = $null
    if ($hasState) { $state = Read-VegaState -Path $StatePath }

    # RustDesk 配置键即使不加 -RemoveApps 也要回滚：配置文件是 Vega 改的。
    if ($null -ne $state) {
        # 用户清单只能回滚当前用户 %AppData% 路径，其他路径（尤其是 LocalService）一律拒绝。
        $userRestore = Restore-VegaRustDeskState -State $state -StatePath $StatePath -Confirm:$false
        $state = $userRestore.State
        foreach ($message in @($userRestore.Messages)) { Write-VegaStatus $message }
        foreach ($failure in @($userRestore.Failures)) {
            $failures.Add([string]$failure)
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
        }
    }

    # 服务模式记录只从管理员清单读取；非管理员不改机器级配置。
    $serviceStatePath = Get-VegaRustDeskServiceStatePath
    if (Test-VegaProcessElevated) {
        if (Test-Path -LiteralPath $serviceStatePath -PathType Leaf) {
            try {
                $serviceState = Read-VegaState -Path $serviceStatePath
                $serviceRestore = Restore-VegaRustDeskState -State $serviceState -StatePath $serviceStatePath -ServiceMode -Confirm:$false
                foreach ($message in @($serviceRestore.Messages)) { Write-VegaStatus $message }
                foreach ($failure in @($serviceRestore.Failures)) {
                    $failures.Add([string]$failure)
                    Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
                }
            }
            catch {
                $failures.Add("服务模式记录清单不可用，跳过回滚：$($_.Exception.Message)")
                Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            }
        }
    }
    elseif (Test-Path -LiteralPath $serviceStatePath -PathType Leaf) {
        Write-VegaStatus '检测到服务模式 RustDesk 记录；非管理员不回滚机器级配置，请以管理员身份卸载。' -Level Warn
    }

    if (-not $RemoveApps) {
        Write-VegaStatus '没有指定 -RemoveApps：跳过组件卸载，只回滚 Vega 改过的 RustDesk 配置键。'
        return [pscustomobject]@{ ExitCode = $(if ($failures.Count -gt 0) { 1 } else { 0 }); Failures = $failures.ToArray() }
    }

    if (-not $hasState) {
        Write-VegaStatus '没有状态清单，不知道哪些组件是 Vega 装的，跳过 winget 卸载。' -Level Warn
        return [pscustomobject]@{ ExitCode = 0; Failures = @() }
    }

    $targets = @()
    foreach ($package in @($state.Packages)) {
        if ($null -eq $package) { continue }
        if (-not [bool]$package.InstalledByVega) { continue }
        $packageId = [string]$package.PackageId
        # 旧清单里的 RustDesk.RustDesk 已随 WinGet 下架：先销账并提示手动卸载，
        # 不当作白名单违规，也不让回滚因此失败。
        if (Test-VegaRetiredPackageId -PackageId $packageId) {
            Write-VegaStatus "旧清单里的 RustDesk winget 包已下架，请从「设置 → 应用」手动卸载 RustDesk；该记录已标记为已处理。" -Level Warn
            $state = Remove-VegaStatePackage -State $state -PackageId $packageId
            $null = Save-VegaState -State $state -Path $StatePath
            continue
        }
        if (-not (Test-VegaStateRecordAllowed -Kind 'Package' -Value $packageId)) {
            $failures.Add("清单里的包 ID 不在白名单，拒绝卸载：$packageId")
            Write-VegaStatus $failures[$failures.Count - 1] -Level Warn
            continue
        }
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
                $null = Save-VegaState -State $state -Path $StatePath
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
    'Get-VegaComponent',
    'Resolve-VegaWingetPath',
    'Test-VegaWingetAvailable',
    'Invoke-VegaWinget',
    'Get-VegaWingetPackageStatus',
    'Install-VegaPackage',
    'Uninstall-VegaPackage',
    'Test-VegaWindowsPlatform',
    'Get-VegaHostStatePath',
    'Get-VegaClientStatePath',
    'Get-VegaStatePath',
    'Get-VegaLegacyStatePath',
    'Write-VegaLegacyStateWarning',
    'Test-VegaManagedHostStatePath',
    'Test-VegaManagedServiceStatePath',
    'Test-VegaManagedStatePath',
    'Test-VegaReparsePoint',
    'Get-VegaPathOwnerSid',
    'Test-VegaStatePathTrusted',
    'Initialize-VegaStateDirectory',
    'Get-VegaEmptyState',
    'Read-VegaState',
    'Write-VegaState',
    'Save-VegaState',
    'Test-VegaLegacyStateFile',
    'Backup-VegaLegacyStateFile',
    'Get-VegaAllowedFirewallRuleName',
    'Get-VegaAllowedServiceName',
    'Get-VegaAllowedPackageId',
    'Test-VegaRetiredPackageId',
    'Test-VegaStateRecordAllowed',
    'Test-VegaStatePackage',
    'Add-VegaStatePackage',
    'Remove-VegaStatePackage',
    'Add-VegaStateFirewallRule',
    'Remove-VegaStateFirewallRule',
    'Add-VegaStateDisabledFirewallRule',
    'Remove-VegaStateDisabledFirewallRule',
    'Get-VegaStateService',
    'Add-VegaStateService',
    'Set-VegaStateServiceRestored',
    'Add-VegaStateManagedKey',
    'Get-VegaStateManagedKey',
    'Set-VegaStateManagedKeyRestored',
    'Add-VegaStateRustDeskKey',
    'Get-VegaStateRustDeskKey',
    'Set-VegaStateRustDeskKeyRestored',
    'Get-VegaRustDeskConfigPath',
    'Test-VegaRustDeskConfigPath',
    'Get-VegaRustDeskManagedKeyName',
    'Get-VegaRustDeskServiceStatePath',
    'Test-VegaRustDeskManagedConfigPath',
    'ConvertFrom-VegaRustDeskServerEndpoint',
    'Test-VegaRustDeskServer',
    'Test-VegaRustDeskKey',
    'Resolve-VegaRustDeskSetting',
    'ConvertFrom-VegaTomlString',
    'ConvertTo-VegaTomlString',
    'ConvertFrom-VegaRustDeskConfigText',
    'Merge-VegaRustDeskConfigText',
    'Get-VegaRustDeskConfigKeySnapshot',
    'Get-VegaRustDeskConfigSummary',
    'Set-VegaRustDeskConfig',
    'Restore-VegaRustDeskConfig',
    'Restore-VegaRustDeskState',
    'Get-VegaRustDeskInstall',
    'Test-VegaRustDeskSignatureValid',
    'Test-VegaRustDeskProgramFilesPath',
    'Test-VegaProcessElevated',
    'Restart-VegaRustDeskService',
    'Format-VegaRustDeskId',
    'Get-VegaRustDeskDeviceId',
    'Invoke-VegaRustDeskSetup',
    'Write-VegaSetupLog',
    'Get-VegaRustDeskDefaults',
    'Get-VegaRustDeskRelease',
    'Get-VegaRustDeskInstaller',
    'Install-VegaRustDeskSilently',
    'Wait-VegaRustDeskService',
    'Uninstall-VegaRustDeskRecorded',
    'Invoke-VegaRustDeskRollback',
    'Invoke-VegaRustDeskBootstrap',
    'Add-VegaStateRustDeskInstall',
    'Get-VegaStateRustDeskInstall',
    'Remove-VegaStateRustDeskInstall',
    'Enter-VegaSetupLock',
    'Exit-VegaSetupLock',
    'Test-VegaVirtualAdapter',
    'Select-VegaAdapter',
    'Get-VegaEncoderName',
    'Get-VegaSunshineInstall',
    'ConvertFrom-VegaSunshineConfigText',
    'Merge-VegaSunshineConfigText',
    'Set-VegaSunshineConfig',
    'Get-VegaConfigKeySnapshot',
    'Restore-VegaManagedConfig',
    'Get-VegaSunshineService',
    'Get-VegaSunshineServiceSnapshot',
    'Set-VegaSunshineServiceStartType',
    'Restore-VegaSunshineServiceState',
    'Restart-VegaSunshineService',
    'Get-VegaSunshinePortMap',
    'Get-VegaSunshineRawValue',
    'ConvertFrom-VegaSunshinePortValue',
    'Get-VegaSunshineBasePort',
    'Get-VegaFirewallProfileName',
    'ConvertTo-VegaFirewallProfileName',
    'Test-VegaFirewallProfileCovered',
    'Get-VegaActiveFirewallProfile',
    'Repair-VegaFirewallRuleProfile',
    'Test-VegaEnforcementStatus',
    'Get-VegaFirewallRuleSpec',
    'Get-VegaAdminBlockPortList',
    'Test-VegaFirewallSpecSafe',
    'Test-VegaManagementPortConflict',
    'Get-VegaHostFirewallStatus',
    'Test-VegaHostFirewallEnabled',
    'Test-VegaPortInRange',
    'Select-VegaSunshineInstallerFirewallRule',
    'Get-VegaSunshineInstallerFirewallRule',
    'Disable-VegaSunshineInstallerFirewallRule',
    'Enable-VegaSunshineInstallerFirewallRule',
    'Select-VegaLegacyFirewallRule',
    'Remove-VegaLegacyFirewallRule',
    'Set-VegaAdminBlockRule',
    'Protect-VegaSunshineManagementPort',
    'Test-VegaFirewallRule',
    'Get-VegaFirewallRuleMissing',
    'Remove-VegaFirewallRule',
    'Remove-VegaFirewallRuleByName',
    'Set-VegaFirewallRule',
    'Get-VegaPublicIPv6',
    'ConvertFrom-VegaTailscalePing',
    'Get-VegaDoctorAdvice',
    'Invoke-VegaHostInstall',
    'Invoke-VegaHostUninstall',
    'Invoke-VegaClientInstall',
    'Invoke-VegaClientUninstall'
)
