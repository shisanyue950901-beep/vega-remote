#Requires -Version 5.1
<#
  NSIS hook helper: print one field of the current interactive user context.
  The hook calls this with -File and captures stdout via nsExec, so the value can be
  passed to install-rustdesk.ps1 as -InteractiveUserSid / -InteractiveUserAppData.

  Only explorer.exe owner / active session user count as interactive; the elevated
  installer account is never returned. Empty output means "not found".
#>
[CmdletBinding()]
param(
    [ValidateSet('Sid', 'AppDataPath', 'UserConfigPath')]
    [string]$Field = 'Sid'
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Join-Path $PSScriptRoot 'lib') 'Vega.Common.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { exit 1 }

Import-Module $modulePath -Force
[Console]::Out.Write((Get-VegaInteractiveUserContextValue -Field $Field))
exit 0
