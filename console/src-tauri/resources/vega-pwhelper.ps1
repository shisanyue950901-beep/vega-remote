#Requires -Version 5.1
<#
  长期密码提权助手（T4d3）。只在设置/清除长期密码时由控制台 runas 拉起一次，绝不常驻。
  控制台把 {"password","verification"} 写进 DACL 收紧的临时文件并传路径；本脚本读后立刻用同长度空白
  覆盖并删除，再调官方接口 rustdesk.exe --password <pwd>，然后写 verification-method。
  -Mode set|clear；-Payload 是 set 必需的 JSON 路径（Rust 侧参数名，-InputFile 为等价别名）。
  退出码 0 成功 / 2 参数 / 3 未装 RustDesk / 4 密码规则 / 5 rustdesk.exe 失败 / 6 写验证方式失败 / 1 其他。
  stderr 只写脱敏原因，密码不进 stdout/stderr/日志；--password 在提权进程中短暂可见（见 SECURITY.md）。
  点源只加载函数、不执行 Main，供 tests/vega-pwhelper.Tests.ps1 单测。
#>
[CmdletBinding()]
param(
    [string]$Mode = '',
    [Alias('InputFile')][string]$Payload = ''
)
Set-StrictMode -Version Latest
$script:MinLen = 8
$script:MaxLen = 64
$script:Verifications = @('use-temporary-password', 'use-permanent-password', 'use-both-passwords')
$script:ClearVerification = 'use-temporary-password'
$script:EmitError = { param([string]$Message) [Console]::Error.WriteLine("vega-pwhelper: $Message") }
function Write-VegaHelperError { param([string]$Message) & $script:EmitError $Message }
# 参数校验：$null 表示通过。
function Get-VegaHelperArgError {
    param([string]$Mode, [string]$Payload)
    if ($Mode -eq 'clear') { return $null }
    if ($Mode -ne 'set') { return '模式只能是 set 或 clear' }
    if ([string]::IsNullOrWhiteSpace($Payload)) { return 'set 模式需要密码文件路径（-Payload）' }
    return $null
}
# 与 password.rs::validate_password 一致：8~64 位、含字母和数字、无控制字符。
function Test-VegaPasswordRule {
    param([string]$Password)
    if ($Password.Length -lt $script:MinLen -or $Password.Length -gt $script:MaxLen) {
        return "密码需为 $($script:MinLen)~$($script:MaxLen) 位"
    }
    foreach ($ch in $Password.ToCharArray()) { if ([char]::IsControl($ch)) { return '密码不能包含控制字符' } }
    $hasLetter = @($Password.ToCharArray() | Where-Object { [char]::IsLetter($_) }).Count -gt 0
    $hasDigit = $Password -match '[0-9]'
    if (-not ($hasLetter -and $hasDigit)) { return '密码需同时包含字母和数字' }
    return $null
}
# 同长度空白覆盖后删除；覆盖失败也继续删。全程不抛，免得把内容带进异常文本。
function Remove-VegaPayloadFile {
    param([string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $length = [int](Get-Item -LiteralPath $Path).Length
            if ($length -gt 0) {
                $blank = [System.Text.Encoding]::ASCII.GetBytes(' ' * $length)
                $stream = [System.IO.File]::Open($Path, 'Open', 'Write', 'None')
                try { $stream.Write($blank, 0, $length); $stream.Flush($true) } finally { $stream.Dispose() }
            }
        }
    } catch { }
    try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { }
}
# 读一次就删：finally 里删除，JSON 非法或字段缺失也留不下明文。
function Read-VegaPayloadFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw '找不到密码文件'
    }
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($Path) } finally { Remove-VegaPayloadFile -Path $Path }
    try { $data = $raw | ConvertFrom-Json } catch { throw '密码文件不是合法 JSON' }
    $read = { param([string]$Name) $item = $data.PSObject.Properties[$Name]; if ($null -eq $item) { $null } else { [string]$item.Value } }
    $password = & $read 'password'
    $verification = & $read 'verification'
    if ([string]::IsNullOrEmpty($password)) { throw '密码文件缺少 password' }
    if ($script:Verifications -notcontains $verification) { throw 'verification 值不受支持' }
    [pscustomobject]@{ Password = $password; Verification = $verification }
}
# 外部调用只此一处，测试 Mock 它即可；不回传输出，里面可能有 rustdesk 回显。
function Invoke-VegaProcess {
    param([string]$FilePath, [string[]]$ArgumentList)
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return [pscustomobject]@{ ExitCode = 127 } }
    try { $null = & $FilePath @ArgumentList 2>&1; [pscustomobject]@{ ExitCode = $LASTEXITCODE } }
    catch { [pscustomobject]@{ ExitCode = 1 } }
}
# 32 位随机密码；去掉易混字符，RNG 字节按 62*4=248 拒绝采样，无取模偏置。
function New-VegaRandomPassword {
    param([int]$Length = 32)
    $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        for ($attempt = 0; $attempt -lt 64; $attempt++) {
            $builder = New-Object System.Text.StringBuilder
            while ($builder.Length -lt $Length) {
                $bytes = New-Object byte[] 1
                $rng.GetBytes($bytes)
                if ($bytes[0] -lt 248) { $builder.Append($chars[[int]$bytes[0] % $chars.Length]) | Out-Null }
            }
            $candidate = $builder.ToString()
            if ($null -eq (Test-VegaPasswordRule -Password $candidate)) { return $candidate }
        }
        throw '生成随机密码失败'
    } finally { $rng.Dispose() }
}
# 只用官方 `--option verification-method <值>` 落 RustDesk2.toml；该版本不认时不手工改写配置
# （避免破坏 RustDesk 自己的状态），直接返回失败，由 Main 以退出码 6 报出。
function Set-VegaVerificationMethod {
    param([string]$Exe, [string]$Value)
    return ((Invoke-VegaProcess -FilePath $Exe -ArgumentList @('--option', 'verification-method', $Value)).ExitCode -eq 0)
}
function Find-VegaRustDeskExe {
    param([string]$ProgramFiles = $env:ProgramFiles)
    if (-not [string]::IsNullOrWhiteSpace($env:VEGA_RUSTDESK_EXE)) { return $env:VEGA_RUSTDESK_EXE }
    $roots = @($ProgramFiles, $env:ProgramW6432) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'RustDesk\rustdesk.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}
# 返回退出码而不是 exit：点源后可直接断言。finally 里再兜底删一次载荷文件。
function Main {
    $argumentError = Get-VegaHelperArgError -Mode $Mode -Payload $Payload
    if ($argumentError) { Write-VegaHelperError $argumentError; return 2 }
    try {
        $exe = Find-VegaRustDeskExe
        if (-not $exe) { Write-VegaHelperError '未找到 rustdesk.exe'; return 3 }
        if ($Mode -eq 'set') {
            $record = Read-VegaPayloadFile -Path $Payload
            $ruleError = Test-VegaPasswordRule -Password $record.Password
            if ($ruleError) { Write-VegaHelperError $ruleError; return 4 }
            $set = Invoke-VegaProcess -FilePath $exe -ArgumentList @('--password', $record.Password)
            $verification = $record.Verification
        } else {
            $set = Invoke-VegaProcess -FilePath $exe -ArgumentList @('--password', (New-VegaRandomPassword))
            $verification = $script:ClearVerification
        }
        if ($set.ExitCode -ne 0) { Write-VegaHelperError "rustdesk.exe 执行失败（退出码 $($set.ExitCode)）"; return 5 }
        if (-not (Set-VegaVerificationMethod -Exe $exe -Value $verification)) {
            Write-VegaHelperError 'verification-method 写入失败'; return 6
        }
        return 0
    } catch {
        Write-VegaHelperError $_.Exception.Message
        return 1
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($Payload)) { Remove-VegaPayloadFile -Path $Payload }
    }
}

if ($MyInvocation.InvocationName -ne '.') { exit (Main) }
