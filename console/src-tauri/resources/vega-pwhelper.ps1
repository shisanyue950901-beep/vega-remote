#Requires -Version 5.1
<#
  长期密码提权助手（T4-fix1b）。只由控制台经 ShellExecuteExW(runas) 拉起一次，不常驻、不接受环境覆盖。
  唯一参数 -InputFile 指向 create_payload_file 生成的载荷：文件名必须是 vega-pw-<32 hex>.json 且非重解析点。
  本脚本用单个 DeleteOnClose 句柄读出全部内容，同一句柄回写等长空格，关闭即删除；关闭后仍存在即退 10。
  载荷字段 {mode,password,verification,expires}：mode 为 set|clear，30 秒内有效，clear 不带 password。
  修改 RustDesk 之前先确认服务 RustDesk 存在且 Running，并在每次 CLI 修改前重新复核 expires。
  退出码 0 成功 / 10 载荷无效、过期或无法清理 / 11 找不到 RustDesk / 12 RustDesk 拒绝修改或服务未运行 /
  13 密码已改但验证方式未更新或回读不一致 / 14 调用 RustDesk 超时（结果未知）。
  stderr 只写固定短句，不输出异常原文，也不输出密码；--password 在提权进程中短暂可见（见 SECURITY.md）。
  点源只加载函数、不执行 Main，供 tests/vega-pwhelper.Tests.ps1 单测。
#>
[CmdletBinding()]
param([string]$InputFile = '')
Set-StrictMode -Version Latest
$script:NamePattern = '^vega-pw-[0-9a-f]{32}\.json$'; $script:MinLen = 8; $script:MaxLen = 64
$script:Alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
$script:Verifications = @('use-temporary-password', 'use-permanent-password', 'use-both-passwords')
$script:ClearVerification = 'use-temporary-password'
$script:CallTimeoutSeconds = 20
$script:EmitError = { param([string]$Message) [Console]::Error.WriteLine("vega-pwhelper: $Message") }
function Write-VegaHelperError { param([string]$Message) & $script:EmitError $Message }
# 与 password.rs::validate_password 一致：8~64 位、只允许 ASCII 字母数字与指定符号、必须同时含字母和数字。
function Test-VegaPasswordRule {
    param([string]$Password)
    if ($Password.Length -lt $script:MinLen -or $Password.Length -gt $script:MaxLen) { return '长度' }
    if ($Password -cnotmatch '^[A-Za-z0-9!#$%&*+,\-./:;<=>?@^_~]+$') { return '字符' }
    if ($Password -cnotmatch '[A-Za-z]' -or $Password -cnotmatch '[0-9]') { return '组成' }
    return $null
}
# 文件名必须与 Rust 侧生成格式一致，且不能是重解析点；失败抛固定异常，由 Main 映射为 10。
function Assert-VegaPayloadPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'payload' }
    if ([System.IO.Path]::GetFileName($Path) -cnotmatch $script:NamePattern) { throw 'payload' }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw 'payload' }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'payload' }
}
# 单句柄读后覆盖：DeleteOnClose 负责删除；关闭后仍存在直接退 10，绝不按路径再删一次
# （路径可能已被替换，按路径删除会删掉别人的文件）。
function Read-VegaPayloadText {
    param([string]$Path)
    Assert-VegaPayloadPath -Path $Path
    $stream = $null; $text = ''
    try {
        $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::DeleteOnClose)
        $length = [int]$stream.Length
        if ($length -le 0) { throw 'payload' }
        $buffer = New-Object byte[] $length
        $offset = 0
        while ($offset -lt $length) {
            $read = $stream.Read($buffer, $offset, $length - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $offset)
        $blank = New-Object byte[] $length
        for ($i = 0; $i -lt $length; $i++) { $blank[$i] = 0x20 }
        $stream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        $stream.Write($blank, 0, $length)
        $stream.Flush($true)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    if (Test-Path -LiteralPath $Path) { throw 'payload' }
    return $text
}
# 当前 unix 秒；单独成函数，测试可以 Mock 它来模拟「解析时未过期、修改前已过期」。
function Get-VegaEpochSeconds {
    $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [System.DateTimeKind]::Utc)
    return [int64](([datetime]::UtcNow - $epoch).TotalSeconds)
}
# 修改前复核期限：每次 CLI 修改之前重新比对 expires，已过期返回 $false（Main → 10）。
function Test-VegaPayloadFresh {
    param([int64]$Expires)
    return ((Get-VegaEpochSeconds) -le $Expires)
}
# 解析并校验载荷；任何字段不合格都抛固定异常（Main → 10），绝不把内容写进错误文本。
function ConvertFrom-VegaPayload {
    param([string]$Text)
    $data = $null
    try { $data = $Text | ConvertFrom-Json } catch { throw 'payload' }
    if ($null -eq $data) { throw 'payload' }
    $get = {
        param([string]$Name)
        $item = $data.PSObject.Properties[$Name]
        if ($null -eq $item) { $null } else { $item.Value }
    }
    $mode = [string](& $get 'mode')
    $verification = [string](& $get 'verification')
    $expiresValue = & $get 'expires'
    if ([string]::IsNullOrEmpty($mode) -or [string]::IsNullOrEmpty($verification)) { throw 'payload' }
    if ($script:Verifications -cnotcontains $verification) { throw 'payload' }
    if ($null -eq $expiresValue) { throw 'payload' }
    try { $expires = [int64]$expiresValue } catch { throw 'payload' }
    if ((Get-VegaEpochSeconds) -gt $expires) { throw 'payload' }
    $passwordProp = $data.PSObject.Properties['password']
    if ($mode -eq 'set') {
        if ($null -eq $passwordProp) { throw 'payload' }
        $password = [string]$passwordProp.Value
        if ($null -ne (Test-VegaPasswordRule -Password $password)) { throw 'payload' }
    } elseif ($mode -eq 'clear') {
        if ($null -ne $passwordProp) { throw 'payload' }
        $password = $null
    } else {
        throw 'payload'
    }
    return [pscustomobject]@{ Mode = $mode; Password = $password; Verification = $verification; Expires = $expires }
}
# 32 位随机密码：拒绝阈值按实际字母表长度计算（256 - (256 % 长度)），避免取模偏置。
function New-VegaRandomPassword {
    param([int]$Length = 32)
    $size = $script:Alphabet.Length
    $limit = 256 - (256 % $size)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        for ($attempt = 0; $attempt -lt 8; $attempt++) {
            $builder = New-Object System.Text.StringBuilder
            $bytes = New-Object byte[] 1
            while ($builder.Length -lt $Length) {
                $rng.GetBytes($bytes)
                if ([int]$bytes[0] -lt $limit) { $builder.Append($script:Alphabet[[int]$bytes[0] % $size]) | Out-Null }
            }
            $candidate = $builder.ToString()
            if ($null -eq (Test-VegaPasswordRule -Password $candidate)) { return $candidate }
        }
        throw 'random'
    } finally { $rng.Dispose() }
}
# 只认系统 ProgramFiles 下的安装位置；不接受 VEGA_RUSTDESK_EXE 等环境覆盖，也没有源码目录回退。
function Get-VegaRustDeskPath {
    $root = [Environment]::GetFolderPath('ProgramFiles')
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    $candidate = Join-Path $root 'RustDesk\rustdesk.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}
# RustDesk 服务必须存在且 Running：服务 IPC 不在时 `--option` 可能只写进 CLI 账户本地配置，
# 回读也会降级读本地值，于是「命令成功」不代表服务端已生效。测试 Mock 它。
function Test-VegaRustDeskService {
    try {
        $service = Get-Service -Name 'RustDesk' -ErrorAction Stop
    } catch {
        return $false
    }
    return ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running)
}
# 唯一外部调用点，测试 Mock 它；stdout+stderr 合并成文本，便于确认 `Done!` 与回读值。
# 用 [Diagnostics.Process] 加 $script:CallTimeoutSeconds 超时：RustDesk 卡住时不能把提权助手一起挂死。
# 进程退出与两个读取任务共用一个截止时间：超时先 Kill（让管道关闭）再限时读输出，任何一步超时都抛
# 固定 'timeout'，由 Main 映射为 14（结果未知）。参数逐个别名加引号，密码字符集不含引号与空格。
function Invoke-VegaRustDesk {
    param([string[]]$Arguments = @())
    $exe = Get-VegaRustDeskPath
    if (-not $exe) { throw 'rustdesk' }
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $exe
    $start.Arguments = (@($Arguments) | ForEach-Object { '"' + [string]$_ + '"' }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'rustdesk' }
    try {
        $deadline = (Get-Date).AddSeconds($script:CallTimeoutSeconds)
        $out = $process.StandardOutput.ReadToEndAsync()
        $err = $process.StandardError.ReadToEndAsync()
        $remaining = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        $exited = $process.WaitForExit($remaining)
        if (-not $exited) {
            # 先杀进程：子进程不退时管道不会关闭，读取任务会一直挂住。
            try { $process.Kill() } catch { }
            try { $null = $process.WaitForExit(2000) } catch { }
        }
        $remaining = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
        # 读输出也必须限时：ReadToEndAsync().Result 在管道未关时会无限等。
        if (-not $out.Wait($remaining) -or -not $err.Wait($remaining)) { throw 'timeout' }
        if (-not $exited) { throw 'timeout' }
        return ([string]$out.Result + [string]$err.Result)
    } finally {
        $process.Dispose()
    }
}
# 返回退出码而不是 exit：点源后可直接断言。任何异常只写固定短句，绝不输出异常原文或密码。
function Main {
    param([string]$InputFile = '')
    $payload = $null
    try {
        $payload = ConvertFrom-VegaPayload -Text (Read-VegaPayloadText -Path $InputFile)
    } catch {
        Write-VegaHelperError '载荷无效或无法清理'
        return 10
    }
    if (-not (Get-VegaRustDeskPath)) { Write-VegaHelperError '找不到 RustDesk'; return 11 }
    if (-not (Test-VegaRustDeskService)) { Write-VegaHelperError 'RustDesk 服务未运行'; return 12 }
    $expires = [int64]$payload.Expires
    $password = $payload.Password; $verification = $payload.Verification
    if ($payload.Mode -eq 'clear') {
        try {
            $password = New-VegaRandomPassword
            $verification = $script:ClearVerification
        } catch {
            Write-VegaHelperError '生成随机密码失败'
            return 12
        }
    }
    if (-not (Test-VegaPayloadFresh -Expires $expires)) { Write-VegaHelperError '载荷已过期'; return 10 }
    try {
        $output = [string](Invoke-VegaRustDesk -Arguments @('--password', $password))
        if ($output -notmatch 'Done!') { Write-VegaHelperError 'RustDesk 拒绝修改密码'; return 12 }
        # 第二次 CLI 修改前再复核一次期限：等待 UAC 与首次调用都可能耗掉 30 秒。
        # 此时密码已经改成，不能再报「载荷无效或过期」；13 表示密码已改、验证方式未更新。
        if (-not (Test-VegaPayloadFresh -Expires $expires)) { Write-VegaHelperError '密码已修改，验证方式未更新'; return 13 }
        $null = Invoke-VegaRustDesk -Arguments @('--option', 'verification-method', $verification)
        $back = [string](Invoke-VegaRustDesk -Arguments @('--option', 'verification-method'))
    } catch {
        if ("$($_.Exception.Message)" -eq 'timeout') {
            Write-VegaHelperError 'RustDesk 无响应，结果未知'
            return 14
        }
        Write-VegaHelperError 'RustDesk 调用失败'
        return 12
    }
    if ($back.Trim() -ne $verification) { Write-VegaHelperError '验证方式回读不一致'; return 13 }
    return 0
}
if ($MyInvocation.InvocationName -ne '.') { exit (Main -InputFile $InputFile) }
