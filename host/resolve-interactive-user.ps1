#Requires -Version 5.1
<#
  NSIS hook helper: print one field of the current interactive user context.
  The hook calls this with -Field and captures stdout via nsExec.

  -Field Context（默认，t3-fix4）：一次解析并输出 ASCII Base64(UTF-8("SID\nAppData")),
  由 install-rustdesk.ps1 用 -InteractiveUserContextB64 解码。nsExec 默认按 ANSI 代码页
  解码输出，含中文的用户目录走明文会被替换成 '?'，所以跨进程只传 Base64。
  -Field Sid / AppDataPath / UserConfigPath：明文输出，仅作调试/兼容用途。

  Only explorer.exe owner / active session user count as interactive; the elevated
  installer account is never returned. Empty output means "not found".
#>
[CmdletBinding()]
param(
    [ValidateSet('Context', 'Sid', 'AppDataPath', 'UserConfigPath')]
    [string]$Field = 'Context'
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Join-Path $PSScriptRoot 'lib') 'Vega.Common.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { exit 1 }

Import-Module $modulePath -Force

if ($Field -eq 'Context') {
    [Console]::Out.Write((Get-VegaInteractiveUserContextPayload))
    exit 0
}

[Console]::Out.Write((Get-VegaInteractiveUserContextValue -Field $Field))
exit 0
