#Requires -Version 5.1
<#
  长期密码提权助手（T4-fix1b）。只由控制台经 ShellExecuteExW(runas) 拉起一次，不常驻、不接受环境覆盖。
  唯一参数 -InputFile 指向 create_payload_file 生成的载荷：文件名必须是 vega-pw-<32 hex>.json 且非重解析点。
  本脚本用单个 DeleteOnClose 句柄读出全部内容，同一句柄回写等长空格，关闭即删除；清理不掉时退 10。
  载荷字段 {mode,password,verification,expires}：mode 为 set|clear，30 秒内有效，clear 不带 password。
  退出码 0 成功 / 10 载荷无效或无法清理 / 11 找不到 RustDesk / 12 RustDesk 拒绝修改 / 13 验证方式回读不一致。
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
# 单句柄读后覆盖：DeleteOnClose 负责删除；关闭后仍存在则再删一次，删不掉抛异常（Main 退 10）。
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
    if (Test-Path -LiteralPath $Path) {
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { }
        if (Test-Path -LiteralPath $Path) { throw 'payload' }
    }
    return $text
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
    $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [System.DateTimeKind]::Utc)
    $now = [int64](([datetime]::UtcNow - $epoch).TotalSeconds)
    if ($now -gt $expires) { throw 'payload' }
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
    return [pscustomobject]@{ Mode = $mode; Password = $password; Verification = $verification }
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
# 唯一外部调用点，测试 Mock 它；stdout+stderr 合并成文本，便于确认 `Done!` 与回读值。
function Invoke-VegaRustDesk {
    param([string[]]$Arguments = @())
    $exe = Get-VegaRustDeskPath
    if (-not $exe) { throw 'rustdesk' }
    return (& $exe @Arguments 2>&1 | Out-String)
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
    try {
        $output = [string](Invoke-VegaRustDesk -Arguments @('--password', $password))
        if ($output -notmatch 'Done!') { Write-VegaHelperError 'RustDesk 拒绝修改密码'; return 12 }
        $null = Invoke-VegaRustDesk -Arguments @('--option', 'verification-method', $verification)
        $back = [string](Invoke-VegaRustDesk -Arguments @('--option', 'verification-method'))
    } catch {
        Write-VegaHelperError 'RustDesk 调用失败'
        return 12
    }
    if ($back.Trim() -ne $verification) { Write-VegaHelperError '验证方式回读不一致'; return 13 }
    return 0
}
if ($MyInvocation.InvocationName -ne '.') { exit (Main -InputFile $InputFile) }
