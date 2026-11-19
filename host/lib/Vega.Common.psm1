<#
  Vega Remote - 共享函数库（被控端脚本 / 主控端脚本 / vega-doctor 共用）

  设计约定：
  - 所有函数兼容 Windows PowerShell 5.1 与 PowerShell 7。
  - 纯判断逻辑（显卡选择、编码器映射、Tailscale ping 解析、配置模板替换、
    诊断结论）不访问系统，便于 Pester 直接测试。
  - 访问系统的函数（winget、防火墙、服务、进程）都通过薄封装
    Invoke-VegaCommand / Invoke-VegaWinget，测试里用 Mock 替换即可，
    不会真的调用 winget 或任何系统命令。
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
        if ($null -eq $argument) { continue }
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

function Invoke-VegaCommand {
    <#
      运行一个外部程序并收集输出（不经过 shell，不解析管道）。
      返回 { FilePath, ExitCode, Output, StdOut, StdErr, TimedOut }。
      超时会 Kill 进程并把 TimedOut 置为 $true，不会抛异常。
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
    if (-not $exited) {
        $result.TimedOut = $true
        try { $process.Kill() } catch { $null = $_ }
        $null = $process.WaitForExit(5000)
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
    $result.ExitCode = $process.ExitCode

    $process.Dispose()
    return $result
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

function Invoke-VegaWinget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [int]$TimeoutSeconds = 900
    )

    return Invoke-VegaCommand -FilePath 'winget.exe' -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds
}

function Test-VegaPackageInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId
    )

    $result = Invoke-VegaWinget -ArgumentList @('list', '--id', $PackageId, '-e', '--accept-source-agreements') -TimeoutSeconds 180
    if ($result.ExitCode -ne 0) { return $false }

    $pattern = [regex]::Escape($PackageId)
    foreach ($line in $result.Output) {
        if ($line -match $pattern) { return $true }
    }
    return $false
}

function Install-VegaPackage {
    <#
      用 winget 安装组件；已安装则跳过（可重复执行）。
      返回 $true 表示本次真的装了。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [string]$DisplayName = '',

        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName)) { $DisplayName = $PackageId }

    if (-not $Force -and (Test-VegaPackageInstalled -PackageId $PackageId)) {
        Write-Verbose "已安装，跳过：$PackageId"
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'winget install')) { return $false }

    $arguments = @(
        'install', '--id', $PackageId, '-e', '--silent',
        '--accept-package-agreements', '--accept-source-agreements'
    )
    if ($Force) { $arguments += '--force' }
    $result = Invoke-VegaWinget -ArgumentList $arguments -TimeoutSeconds 1800
    if ($result.ExitCode -ne 0) {
        throw "安装 $DisplayName 失败（winget 退出码 $($result.ExitCode)）。可手动执行：winget install --id $PackageId -e"
    }

    return $true
}

function Uninstall-VegaPackage {
    <#
      winget 卸载组件；未安装则跳过。返回 $true 表示本次真的卸了。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [string]$DisplayName = ''
    )

    if ([string]::IsNullOrWhiteSpace($DisplayName)) { $DisplayName = $PackageId }

    if (-not (Test-VegaPackageInstalled -PackageId $PackageId)) {
        Write-Verbose "未安装，跳过：$PackageId"
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'winget uninstall')) { return $false }

    $arguments = @('uninstall', '--id', $PackageId, '-e', '--silent', '--accept-source-agreements')
    $result = Invoke-VegaWinget -ArgumentList $arguments -TimeoutSeconds 900
    if ($result.ExitCode -ne 0) {
        throw "卸载 $DisplayName 失败（winget 退出码 $($result.ExitCode)）。可手动执行：winget uninstall --id $PackageId -e"
    }

    return $true
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

function Get-VegaEncoderId {
    <#
      把编码器显示名映射成 sunshine.conf 里的 encoder 取值。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$AdapterName
    )

    switch (Get-VegaEncoderName -AdapterName $AdapterName) {
        'NVENC' { return 'nvenc' }
        'AMF' { return 'amdvce' }
        'QSV' { return 'quicksync' }
        default { return 'software' }
    }
}

# ---------------------------------------------------------------------------
# Sunshine 配置（纯替换 + 落盘）
# ---------------------------------------------------------------------------

function Resolve-VegaSunshineConfig {
    <#
      纯函数：把配置模板里的 __ADAPTER__ / __ENCODER__ 换成实际值。
      用字符串 Replace（不是正则替换），显卡名里的 $ 、\ 等字符原样保留；
      模板里没有占位符时原样返回。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Template,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$AdapterName = '',

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Encoder = ''
    )

    $result = $Template
    if ($null -eq $AdapterName) { $AdapterName = '' }
    if ($null -eq $Encoder) { $Encoder = '' }

    $result = $result.Replace('__ADAPTER__', $AdapterName)
    $result = $result.Replace('__ENCODER__', $Encoder)
    return $result
}

function Set-VegaSunshineConfig {
    <#
      写 sunshine.conf（UTF-8 无 BOM；Sunshine 不认 BOM）。
      只在备份不存在时创建一次 sunshine.conf.bak，重复执行不会覆盖最初的原配置。
      返回 { Path, BackupPath, BackupCreated }。
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

    $directory = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        if ($PSCmdlet.ShouldProcess($directory, '创建配置目录')) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
    }

    $backupPath = "$Path.bak"
    $backupCreated = $false
    $configExists = Test-Path -LiteralPath $Path
    if (-not $NoBackup -and $configExists -and -not (Test-Path -LiteralPath $backupPath)) {
        if ($PSCmdlet.ShouldProcess($backupPath, '备份原配置')) {
            Copy-Item -LiteralPath $Path -Destination $backupPath -Force
            $backupCreated = $true
        }
    }

    if ($PSCmdlet.ShouldProcess($Path, '写入 Sunshine 配置')) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
    }

    return [pscustomobject]@{
        Path          = $Path
        BackupPath    = $backupPath
        BackupCreated = $backupCreated
    }
}

function Restore-VegaSunshineConfig {
    <#
      卸载用：把 sunshine.conf.bak 恢复成 sunshine.conf。
      没有备份返回 $false。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $backupPath = "$Path.bak"
    if (-not (Test-Path -LiteralPath $backupPath)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Path, '从 sunshine.conf.bak 恢复')) { return $false }

    Copy-Item -LiteralPath $backupPath -Destination $Path -Force
    return $true
}

# ---------------------------------------------------------------------------
# Sunshine 服务与凭据
# ---------------------------------------------------------------------------

function Get-VegaSunshineService {
    [CmdletBinding()]
    param()

    return @(Get-Service -Name 'sunshine*' -ErrorAction SilentlyContinue)
}

function Restart-VegaSunshineService {
    <#
      设置为自动启动并重启；找不到服务返回 $false。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $services = @(Get-VegaSunshineService)
    if ($services.Count -eq 0) { return $false }

    foreach ($service in $services) {
        if (-not $PSCmdlet.ShouldProcess($service.Name, '设置自动启动并重启服务')) { continue }
        $null = Set-Service -Name $service.Name -StartupType Automatic -ErrorAction SilentlyContinue
        Restart-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
    }

    return $true
}

function Set-VegaSunshineCredential {
    <#
      设置 Sunshine 管理账号密码。
      SecureString 只在函数内部转成明文交给 sunshine.exe --creds，
      转换用的 BSTR 在 finally 里 ZeroFreeBSTR 清零，明文变量随即置空。
      密码不会写进任何日志、不会出现在 Write-Host / Write-Verbose 里。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string]$User,

        [Parameter(Mandatory)]
        [securestring]$SecurePassword
    )

    if (-not $PSCmdlet.ShouldProcess($User, '设置 Sunshine 管理密码')) { return $false }

    $bstr = [System.IntPtr]::Zero
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $result = Invoke-VegaCommand -FilePath $Executable -ArgumentList @('--creds', $User, $plain) -TimeoutSeconds 60
        if ($result.ExitCode -ne 0) {
            Write-Verbose ("sunshine --creds 退出码 $($result.ExitCode)：" + ($result.Output -join ' | '))
            return $false
        }
        return $true
    }
    finally {
        if ($bstr -ne [System.IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $plain = $null
        $bstr = [System.IntPtr]::Zero
    }
}

# ---------------------------------------------------------------------------
# 防火墙（Vega 自己创建的规则，统一 Vega- 前缀）
# ---------------------------------------------------------------------------

function Get-VegaFirewallRuleSpec {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{
            Name     = 'Vega-Sunshine-TCP'
            Protocol = 'TCP'
            LocalPort = @('47984', '47989', '47990', '48010')
        },
        [pscustomobject]@{
            Name     = 'Vega-Sunshine-UDP'
            Protocol = 'UDP'
            LocalPort = @('47998-48000', '48002', '48010')
        }
    )
}

function Test-VegaFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    $rule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
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
        if (-not (Test-VegaFirewallRule -DisplayName $spec.Name)) { $missing.Add($spec.Name) }
    }
    return $missing.ToArray()
}

function Remove-VegaFirewallRule {
    <#
      删除指定显示名的防火墙规则（支持通配符），返回删除条数。
      规则不存在时安静跳过，便于重复执行。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$DisplayName = @('Vega-Sunshine-TCP', 'Vega-Sunshine-UDP')
    )

    if ($null -eq $DisplayName) { return 0 }

    $removed = 0
    foreach ($name in $DisplayName) {
        $rules = @(Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)
        if ($rules.Count -eq 0) { continue }
        if ($PSCmdlet.ShouldProcess($name, '删除防火墙规则')) {
            $rules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
            $removed += $rules.Count
        }
    }
    return $removed
}

function Set-VegaFirewallRule {
    <#
      先删后建，保证端口集合与脚本一致，重复执行不会堆叠重复规则。
      返回新建条数。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $created = 0
    foreach ($spec in (Get-VegaFirewallRuleSpec)) {
        if (-not $PSCmdlet.ShouldProcess($spec.Name, '重建防火墙规则')) { continue }
        $null = Remove-VegaFirewallRule -DisplayName $spec.Name
        $params = @{
            DisplayName = $spec.Name
            Direction   = 'Inbound'
            Action      = 'Allow'
            Protocol    = $spec.Protocol
            LocalPort   = $spec.LocalPort
            Profile     = 'Any'
            Program     = 'Any'
            Enabled     = 'True'
        }
        $null = New-NetFirewallRule @params
        $created++
    }
    return $created
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
      解析 `tailscale ping` 输出，判断直连还是 DERP 中继。
      - 直连行形如：pong from host (100.x) via 1.2.3.4:41641 in 12ms
      - 中继行形如：pong from host (100.x) via DERP(tok) in 40ms
      - 以最后一条 pong 作为结论（Tailscale 打洞成功后会从 DERP 切到直连），
        同时给出直连/中继次数，方便判断是否“先中继后直连”。
      返回 { Mode, Succeeded, PongCount, DirectCount, DerpCount, Endpoint, Region, LatencyMs, LastLine }。
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

        if ($line -match 'via DERP\((?<region>[^)]+)\)') {
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
        Mode        = 'Unknown'
        Succeeded   = $false
        PongCount   = $pongs.Count
        DirectCount = 0
        DerpCount   = 0
        Endpoint    = ''
        Region      = ''
        LatencyMs   = $null
        LastLine    = ''
    }

    if ($pongs.Count -eq 0) {
        if ($lines.Count -gt 0) { $result.LastLine = $lines[$lines.Count - 1].Trim() }
        return $result
    }

    $direct = @($pongs | Where-Object { $_.Mode -eq 'Direct' })
    $derp = @($pongs | Where-Object { $_.Mode -eq 'Derp' })
    $last = $pongs[$pongs.Count - 1]

    $result.DirectCount = $direct.Count
    $result.DerpCount = $derp.Count
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

    $adapter = ''
    if ($Facts.ContainsKey('AdapterName') -and $null -ne $Facts['AdapterName']) { $adapter = [string]$Facts['AdapterName'] }
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
        $advice.Add('Sunshine 已安装但服务没在运行：管理员 PowerShell 执行 Restart-Service sunshine，或重新跑一次 install-host.ps1。')
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
            $advice.Add('推荐编码器 AMF（sunshine.conf 里是 amdvce）：请装 22.3.1 以上驱动；老 A 卡不支持 HEVC 时退回 H.264。')
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

Export-ModuleMember -Function @(
    'ConvertTo-VegaArgumentString',
    'Invoke-VegaCommand',
    'Get-VegaComponent',
    'Invoke-VegaWinget',
    'Test-VegaPackageInstalled',
    'Install-VegaPackage',
    'Uninstall-VegaPackage',
    'Test-VegaVirtualAdapter',
    'Select-VegaAdapter',
    'Get-VegaEncoderName',
    'Get-VegaEncoderId',
    'Resolve-VegaSunshineConfig',
    'Set-VegaSunshineConfig',
    'Restore-VegaSunshineConfig',
    'Get-VegaSunshineService',
    'Restart-VegaSunshineService',
    'Set-VegaSunshineCredential',
    'Get-VegaFirewallRuleSpec',
    'Test-VegaFirewallRule',
    'Get-VegaFirewallRuleMissing',
    'Remove-VegaFirewallRule',
    'Set-VegaFirewallRule',
    'Get-VegaPublicIPv6',
    'ConvertFrom-VegaTailscalePing',
    'Get-VegaDoctorAdvice'
)
