#Requires -Version 5.1
<#
  入口级 mock 测试（Pester 5）：
    - 被控端 / 主控端安装、卸载入口的退出码
    - 状态清单白名单拒绝（不碰清单以外的对象）
    - 受管键首次基线不被重跑覆盖，卸载按键回滚并保留用户键
    - -Force 重装前仍查询，已存在的包登记为 PreExisting
  所有系统命令都被 Mock，不会真的调用 winget / 防火墙 / 服务。
#>

BeforeAll {
    $modulePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
    Import-Module $modulePath -Force
    $script:ModuleName = 'Vega.Common'
    $script:TemplatePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/sunshine.conf'

    # Windows 专有 cmdlet 在 Linux 的 pwsh 上不存在，Pester 的 Mock -ModuleName
    # 会以找不到命令为由报错。先在模块作用域塞一个签名一致的空 stub，
    # 再由 Mock 接管；Windows 上这些命令本来就有，直接跳过。
    $module = Get-Module $script:ModuleName
    $stubs = @{
        'Get-CimInstance' = {
            [CmdletBinding()]
            param([Parameter(Position = 0)][string]$ClassName)
            $null = $ClassName
        }
        'Get-NetFirewallProfile' = {
            [CmdletBinding()]
            param([string]$PolicyStore)
            $null = $PolicyStore
        }
        'Get-NetConnectionProfile' = {
            [CmdletBinding()]
            param()
        }
        'Get-Service'     = {
            [CmdletBinding()]
            param([Parameter(Position = 0)][string[]]$Name)
            $null = $Name
        }
        'Set-Service'     = {
            [CmdletBinding()]
            param([string]$Name, [string]$StartupType)
            $null = $Name
            $null = $StartupType
        }
        'Start-Service'   = {
            [CmdletBinding()]
            param([string[]]$Name)
            $null = $Name
        }
        'Stop-Service'    = {
            [CmdletBinding()]
            param([string[]]$Name, [switch]$Force)
            $null = $Name
            $null = $Force
        }
        'Restart-Service' = {
            [CmdletBinding()]
            param([string[]]$Name, [switch]$Force)
            $null = $Name
            $null = $Force
        }
    }
    foreach ($stubName in $stubs.Keys) {
        if (Get-Command -Name $stubName -ErrorAction SilentlyContinue) { continue }
        $stubBody = $stubs[$stubName]
        & $module {
            param($name, $body)
            New-Item -Path ("function:script:{0}" -f $name) -Value $body -Force | Out-Null
        } $stubName $stubBody
    }
}

Describe 'Invoke-VegaHostInstall（mock）' {
    BeforeEach {
        $script:statePath = Join-Path $TestDrive 'host-state.json'
        $script:sunshineDir = Join-Path $TestDrive 'Sunshine'
        # Pester 的 TestDrive 按 Describe/Context 清理，不按 It 清理：
        # 上一个用例写下的清单和配置会留到下一个用例，这里显式清空，保证每个 It 从空状态开始。
        if (Test-Path -LiteralPath $script:statePath) { Remove-Item -LiteralPath $script:statePath -Force }
        if (Test-Path -LiteralPath $script:sunshineDir) { Remove-Item -LiteralPath $script:sunshineDir -Recurse -Force }
        $null = New-Item -ItemType Directory -Path (Join-Path $script:sunshineDir 'config') -Force
        $script:sunshineExe = Join-Path $script:sunshineDir 'sunshine.exe'
        $script:sunshineConfig = Join-Path (Join-Path $script:sunshineDir 'config') 'sunshine.conf'
        $null = New-Item -ItemType File -Path $script:sunshineExe -Force

        $script:sunshine = [pscustomobject]@{
            Directory = $script:sunshineDir
            Exe       = $script:sunshineExe
            Config    = $script:sunshineConfig
            Version   = '2026.1'
        }

        Mock -ModuleName $script:ModuleName Test-VegaWingetAvailable { $true }
        Mock -ModuleName $script:ModuleName Test-VegaHostFirewallEnabled { $true }
        Mock -ModuleName $script:ModuleName Remove-VegaLegacyFirewallRule { @() }
        Mock -ModuleName $script:ModuleName Set-VegaAdminBlockRule { 'Vega-Block-Admin' }
        Mock -ModuleName $script:ModuleName Protect-VegaSunshineManagementPort { param($State) $State }
        Mock -ModuleName $script:ModuleName Get-CimInstance { [pscustomobject]@{ Name = 'GPU' } }
        Mock -ModuleName $script:ModuleName Get-VegaPowerCfgPath { $null }
        Mock -ModuleName $script:ModuleName Get-VegaSunshineService {
            [pscustomobject]@{ Name = 'SunshineService'; Status = 'Running'; StartType = 'Automatic' }
        }
        # 安装前的服务基线（与安装后的状态不同，便于断言采集时机）
        Mock -ModuleName $script:ModuleName Get-VegaSunshineServiceSnapshot {
            @([pscustomobject]@{ Name = 'SunshineService'; StartType = 'Manual'; Status = 'Stopped' })
        }
        Mock -ModuleName $script:ModuleName Write-VegaLegacyStateWarning { $false }
        Mock -ModuleName $script:ModuleName Restart-VegaSunshineService {
            [pscustomobject]@{ Found = $true; Name = 'SunshineService'; Status = 'Running'; Success = $true; Error = '' }
        }
        Mock -ModuleName $script:ModuleName Get-VegaPublicIPv6 { @() }
        Mock -ModuleName $script:ModuleName Set-VegaFirewallRule {
            param($Program, $BasePort, $OnRuleCreated)
            $null = $Program
            $null = $BasePort
            if ($null -ne $OnRuleCreated) {
                & $OnRuleCreated 'Vega-Sunshine-TCP'
                & $OnRuleCreated 'Vega-Sunshine-UDP'
            }
            return @('Vega-Sunshine-TCP', 'Vega-Sunshine-UDP')
        }
    }

    It 'winget 安装失败时退出码为 1，并保留已记录的管理端口阻断规则' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $null }
        Mock -ModuleName $script:ModuleName Install-VegaPackage { throw '安装 Sunshine 失败（winget 退出码 1603）' }

        $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale

        $result.ExitCode | Should -Be 1
        ($result.Failures -join "`n") | Should -Match '1603'

        # 阻断规则是安装前建的，已经写进清单，必须留着供卸载清理
        $state = Read-VegaState -Path $script:statePath
        @($state.FirewallRules | ForEach-Object { $_.Name }) | Should -Contain 'Vega-Block-Admin'
    }

    It '安装成功后退出码为 0，防火墙规则逐条进清单' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Install-VegaPackage {
            param($PackageId, $DisplayName, [switch]$Force)
            $null = $DisplayName
            $null = $Force
            [pscustomobject]@{ PackageId = $PackageId; Installed = $true; PreExisting = $false }
        }

        $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale

        $result.ExitCode | Should -Be 0
        $state = Read-VegaState -Path $script:statePath
        $names = @($state.FirewallRules | ForEach-Object { $_.Name })
        $names | Should -Contain 'Vega-Sunshine-TCP'
        $names | Should -Contain 'Vega-Sunshine-UDP'
        $names | Should -Contain 'Vega-Block-Admin'
    }

    It '管理端口与串流放行端口相交时中止安装，不建阻断规则' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Test-VegaManagementPortConflict { @(47990) }
        Mock -ModuleName $script:ModuleName Install-VegaPackage { throw '不该被调用' }

        $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale

        $result.ExitCode | Should -Be 1
        ($result.Failures -join "`n") | Should -Match 'port'
        Should -Invoke -ModuleName $script:ModuleName -CommandName Set-VegaAdminBlockRule -Times 0 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Install-VegaPackage -Times 0 -Exactly
        # 端口预检失败时不能先动旧版规则
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaLegacyFirewallRule -Times 0 -Exactly
    }

    It '当前网络防火墙关闭时中止安装，不建阻断规则也不调用 winget' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Test-VegaHostFirewallEnabled { $false }
        Mock -ModuleName $script:ModuleName Install-VegaPackage { throw '不该被调用' }

        $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale

        $result.ExitCode | Should -Be 1
        ($result.Failures -join "`n") | Should -Match 'Windows 防火墙在当前网络已关闭'
        Should -Invoke -ModuleName $script:ModuleName -CommandName Set-VegaAdminBlockRule -Times 0 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Install-VegaPackage -Times 0 -Exactly
        # 防火墙预检在旧版规则清理之前：中止时旧规则原样保留
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaLegacyFirewallRule -Times 0 -Exactly
    }

    It 'port = 47981 时安装后的最终阻断规则仍含 47990' {
        # 47990 只是 UDP 视频端口，TCP 管理端口 47982 与串流放行端口不冲突
        Set-Content -LiteralPath $script:sunshineConfig -Value 'port = 47981' -Encoding UTF8
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Install-VegaPackage {
            param($PackageId, $DisplayName, [switch]$Force)
            $null = $DisplayName
            $null = $Force
            [pscustomobject]@{ PackageId = $PackageId; Installed = $true; PreExisting = $false }
        }
        $env:VEGA_TEST_BLOCK_PORTS = ''
        Mock -ModuleName $script:ModuleName Set-VegaAdminBlockRule {
            param($ManagementPorts)
            $env:VEGA_TEST_BLOCK_PORTS = ($ManagementPorts -join ',')
            'Vega-Block-Admin'
        }

        try {
            $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale
            $result.ExitCode | Should -Be 0

            # 最后一次调用是安装完成后的最终规则
            $finalPorts = @($env:VEGA_TEST_BLOCK_PORTS -split ',')
            $finalPorts | Should -Contain '47982'
            $finalPorts | Should -Contain '47990'
        }
        finally {
            Remove-Item Env:VEGA_TEST_BLOCK_PORTS -ErrorAction SilentlyContinue
        }
    }

    It '服务基线在 winget 安装之前采集' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        # Mock 体在模块作用域执行，看不到测试变量；用环境变量把清单路径传进去，
        # 安装那一刻回读清单：服务基线必须已经写好了。
        $env:VEGA_TEST_STATE_PATH = $script:statePath
        Mock -ModuleName $script:ModuleName Install-VegaPackage {
            param($PackageId, $DisplayName, [switch]$Force)
            $null = $DisplayName
            $null = $Force
            $duringInstall = Read-VegaState -Path $env:VEGA_TEST_STATE_PATH
            if (@($duringInstall.Services).Count -eq 0) { throw '安装时还没有服务基线' }
            [pscustomobject]@{ PackageId = $PackageId; Installed = $true; PreExisting = $false }
        }

        try {
            $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale
            $result.ExitCode | Should -Be 0
        }
        finally {
            Remove-Item Env:VEGA_TEST_STATE_PATH -ErrorAction SilentlyContinue
        }

        # 记录的是安装前的 Manual/Stopped，而不是安装后服务自己的 Automatic/Running
        $state = Read-VegaState -Path $script:statePath
        $entry = @($state.Services | Where-Object { $_.Name -eq 'SunshineService' })[0]
        $entry.OriginalStartType | Should -Be 'Manual'
        $entry.OriginalStatus | Should -Be 'Stopped'
    }

    It '-WithRustDesk 不再调用 winget 安装 RustDesk，只提示官方下载页' {
        # WinGet 社区源已下架 RustDesk：安装流程只能装 Sunshine/Tailscale/Moonlight，
        # RustDesk 变成「打印官方下载页 + 已安装则应用中继配置」。
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Write-VegaStatus { }
        Mock -ModuleName $script:ModuleName Install-VegaPackage {
            param($PackageId, $DisplayName, [switch]$Force)
            $null = $DisplayName
            $null = $Force
            [pscustomobject]@{ PackageId = $PackageId; Installed = $true; PreExisting = $false }
        }

        $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath `
            -SkipTailscale -WithRustDesk
        $result.ExitCode | Should -Be 0

        Should -Invoke -ModuleName $script:ModuleName -CommandName Install-VegaPackage -Times 1 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Install-VegaPackage -Times 0 -Exactly `
            -ParameterFilter { $PackageId -match 'RustDesk' }
        Should -Invoke -ModuleName $script:ModuleName -CommandName Write-VegaStatus -Times 1 -Exactly `
            -ParameterFilter { $Message -match 'rustdesk/releases/latest' }
    }

    It '检测到旧版清单时打印警告' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Install-VegaPackage {
            param($PackageId, $DisplayName, [switch]$Force)
            $null = $DisplayName
            $null = $Force
            [pscustomobject]@{ PackageId = $PackageId; Installed = $true; PreExisting = $false }
        }

        $null = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale

        Should -Invoke -ModuleName $script:ModuleName -CommandName Write-VegaLegacyStateWarning -Times 1 -Exactly
    }

    It '-Force 重装已存在的包时仍登记为 PreExisting，-RemoveApps 不会卸载它' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Install-VegaPackage {
            param($PackageId, $DisplayName, [switch]$Force)
            $null = $DisplayName
            $null = $Force
            [pscustomobject]@{ PackageId = $PackageId; Installed = $true; PreExisting = $true }
        }

        $installed = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale -Force
        $installed.ExitCode | Should -Be 0

        $state = Read-VegaState -Path $script:statePath
        $package = @($state.Packages | Where-Object { $_.PackageId -eq 'LizardByte.Sunshine' })[0]
        $package.InstalledByVega | Should -BeFalse

        Mock -ModuleName $script:ModuleName Remove-VegaFirewallRuleByName { $true }
        Mock -ModuleName $script:ModuleName Enable-VegaSunshineInstallerFirewallRule { @('Sunshine') }
        Mock -ModuleName $script:ModuleName Restore-VegaSunshineServiceState {
            [pscustomobject]@{ Success = $true; Message = 'ok' }
        }
        Mock -ModuleName $script:ModuleName Uninstall-VegaPackage { $true }

        $removed = Invoke-VegaHostUninstall -StatePath $script:statePath -RemoveApps -Confirm:$false
        $removed.ExitCode | Should -Be 0
        Should -Invoke -ModuleName $script:ModuleName -CommandName Uninstall-VegaPackage -Times 0 -Exactly
    }

    It '旧版清单里的 RustDesk.RustDesk 包按已下线处理，不阻断 -RemoveApps 回滚' {
        # WinGet 社区源已下架 RustDesk，旧清单仍可能记录着这个包 ID。
        # 它既不该被当成白名单违规，也不该让回滚失败；提示手动卸载并销账。
        $state = Get-VegaEmptyState
        $state = Add-VegaStatePackage -State $state -PackageId 'RustDesk.RustDesk' -Name 'RustDesk'
        $null = Write-VegaState -State $state -Path $script:statePath -Confirm:$false

        Mock -ModuleName $script:ModuleName Write-VegaStatus { }
        Mock -ModuleName $script:ModuleName Uninstall-VegaPackage { throw '不该被调用' }

        $result = Invoke-VegaHostUninstall -StatePath $script:statePath -RemoveApps -Confirm:$false

        $result.ExitCode | Should -Be 0
        @($result.Failures).Count | Should -Be 0
        Should -Invoke -ModuleName $script:ModuleName -CommandName Uninstall-VegaPackage -Times 0 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Write-VegaStatus -ParameterFilter {
            $Message -match '手动卸载'
        } -Times 1 -Exactly
        Test-Path -LiteralPath $script:statePath | Should -BeFalse
    }

    It '安装前阻断规则强制包含 47990，安装完成后再按实际端口计算' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Install-VegaPackage {
            param($PackageId, $DisplayName, [switch]$Force)
            $null = $PackageId
            $null = $DisplayName
            $null = $Force
            [pscustomobject]@{ PackageId = 'LizardByte.Sunshine'; Installed = $true; PreExisting = $false }
        }
        $env:VEGA_TEST_BLOCK_LOG = Join-Path $TestDrive 'block.log'
        Mock -ModuleName $script:ModuleName Get-VegaAdminBlockPortList {
            param($ManagementPorts, $BasePort, [switch]$IncludeDefaultManagementPort)
            $null = $ManagementPorts
            $null = $BasePort
            if ($IncludeDefaultManagementPort) { Add-Content -LiteralPath $env:VEGA_TEST_BLOCK_LOG -Encoding UTF8 -Value 'pre' }
            else { Add-Content -LiteralPath $env:VEGA_TEST_BLOCK_LOG -Encoding UTF8 -Value 'final' }
            @(47990)
        }

        try {
            $null = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale
            $log = @(Get-Content -LiteralPath $env:VEGA_TEST_BLOCK_LOG -Encoding UTF8)
            $log | Should -Be @('pre', 'final')
        }
        finally {
            Remove-Item Env:VEGA_TEST_BLOCK_LOG -ErrorAction SilentlyContinue
        }
    }

    It '串流放行规则创建失败时中止，不禁用安装器规则' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Install-VegaPackage {
            param($PackageId, $DisplayName, [switch]$Force)
            $null = $PackageId
            $null = $DisplayName
            $null = $Force
            [pscustomobject]@{ PackageId = 'LizardByte.Sunshine'; Installed = $true; PreExisting = $false }
        }
        Mock -ModuleName $script:ModuleName Set-VegaFirewallRule { throw '回读发现端口不全' }

        $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale

        $result.ExitCode | Should -Be 1
        ($result.Failures -join "`n") | Should -Match '回读发现端口不全'
        Should -Invoke -ModuleName $script:ModuleName -CommandName Protect-VegaSunshineManagementPort -Times 0 -Exactly
        # 新串流规则没确认成功，旧版规则必须留着守端口
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaLegacyFirewallRule -Times 0 -Exactly
    }

    It '阻断规则第二次回读失败时中止，旧版规则仍在' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Install-VegaPackage {
            param($PackageId, $DisplayName, [switch]$Force)
            $null = $PackageId
            $null = $DisplayName
            $null = $Force
            [pscustomobject]@{ PackageId = 'LizardByte.Sunshine'; Installed = $true; PreExisting = $false }
        }
        $env:VEGA_TEST_BLOCK_CALLS = '0'
        Mock -ModuleName $script:ModuleName Set-VegaAdminBlockRule {
            $calls = [int]$env:VEGA_TEST_BLOCK_CALLS + 1
            $env:VEGA_TEST_BLOCK_CALLS = [string]$calls
            if ($calls -ge 2) { throw '阻断规则回读失败' }
            'Vega-Block-Admin'
        }

        try {
            $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale
            $result.ExitCode | Should -Be 1
            ($result.Failures -join "`n") | Should -Match '阻断规则回读失败'
            Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaLegacyFirewallRule -Times 0 -Exactly
            Should -Invoke -ModuleName $script:ModuleName -CommandName Set-VegaFirewallRule -Times 0 -Exactly
        }
        finally {
            Remove-Item Env:VEGA_TEST_BLOCK_CALLS -ErrorAction SilentlyContinue
        }
    }

    It '先确认 Vega 放行规则，再禁用安装器规则' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Install-VegaPackage {
            param($PackageId, $DisplayName, [switch]$Force)
            $null = $PackageId
            $null = $DisplayName
            $null = $Force
            [pscustomobject]@{ PackageId = 'LizardByte.Sunshine'; Installed = $true; PreExisting = $false }
        }
        $env:VEGA_TEST_ORDER_LOG = Join-Path $TestDrive 'order.log'
        Mock -ModuleName $script:ModuleName Set-VegaFirewallRule {
            param($Program, $BasePort, $OnRuleCreated)
            $null = $Program
            $null = $BasePort
            Add-Content -LiteralPath $env:VEGA_TEST_ORDER_LOG -Encoding UTF8 -Value 'allow'
            if ($null -ne $OnRuleCreated) {
                & $OnRuleCreated 'Vega-Sunshine-TCP'
                & $OnRuleCreated 'Vega-Sunshine-UDP'
            }
            return @('Vega-Sunshine-TCP', 'Vega-Sunshine-UDP')
        }
        Mock -ModuleName $script:ModuleName Protect-VegaSunshineManagementPort {
            param($State)
            Add-Content -LiteralPath $env:VEGA_TEST_ORDER_LOG -Encoding UTF8 -Value 'protect'
            $State
        }
        Mock -ModuleName $script:ModuleName Remove-VegaLegacyFirewallRule {
            Add-Content -LiteralPath $env:VEGA_TEST_ORDER_LOG -Encoding UTF8 -Value 'legacy'
            @()
        }

        try {
            $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale
            $result.ExitCode | Should -Be 0
            $log = @(Get-Content -LiteralPath $env:VEGA_TEST_ORDER_LOG -Encoding UTF8)
            # 旧版规则必须在新串流规则确认后、禁用安装器规则之前删除
            $log | Should -Be @('allow', 'legacy', 'protect')
        }
        finally {
            Remove-Item Env:VEGA_TEST_ORDER_LOG -ErrorAction SilentlyContinue
        }
    }

    It '已标记 Restored 的服务条目在新一轮安装时重采基线并改回待恢复' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Install-VegaPackage {
            param($PackageId, $DisplayName, [switch]$Force)
            $null = $PackageId
            $null = $DisplayName
            $null = $Force
            [pscustomobject]@{ PackageId = 'LizardByte.Sunshine'; Installed = $true; PreExisting = $false }
        }

        $state = Get-VegaEmptyState
        $state = Add-VegaStateService -State $state -Name 'SunshineService' -StartType 'Disabled' -Status 'Stopped'
        $state = Set-VegaStateServiceRestored -State $state -Name 'SunshineService' -Confirm:$false
        $null = Write-VegaState -State $state -Path $script:statePath -Confirm:$false

        $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale
        $result.ExitCode | Should -Be 0

        $saved = Read-VegaState -Path $script:statePath
        $entry = @($saved.Services | Where-Object { $_.Name -eq 'SunshineService' })[0]
        $entry.OriginalStartType | Should -Be 'Manual'
        $entry.OriginalStatus | Should -Be 'Stopped'
        [bool]$entry.Restored | Should -BeFalse
    }
}

Describe 'Invoke-VegaHostUninstall（mock）' {
    BeforeEach {
        $script:statePath = Join-Path $TestDrive 'uninstall-state.json'
        $script:sunshineDir = Join-Path $TestDrive 'Sunshine'
        # 同上：TestDrive 只在 Describe 结束时清理，先手动清掉上个用例的清单与配置。
        if (Test-Path -LiteralPath $script:statePath) { Remove-Item -LiteralPath $script:statePath -Force }
        if (Test-Path -LiteralPath $script:sunshineDir) { Remove-Item -LiteralPath $script:sunshineDir -Recurse -Force }
        $script:configDir = Join-Path $script:sunshineDir 'config'
        $script:configPath = Join-Path $script:configDir 'sunshine.conf'
        $null = New-Item -ItemType Directory -Path $script:configDir -Force
        $script:sunshineExe = Join-Path $script:sunshineDir 'sunshine.exe'
        $null = New-Item -ItemType File -Path $script:sunshineExe -Force

        $script:sunshine = [pscustomobject]@{
            Directory = $script:sunshineDir
            Exe       = $script:sunshineExe
            Config    = $script:configPath
            Version   = '2026.1'
        }

        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Remove-VegaLegacyFirewallRule { @() }
        Mock -ModuleName $script:ModuleName Remove-VegaFirewallRuleByName { $true }
        Mock -ModuleName $script:ModuleName Enable-VegaSunshineInstallerFirewallRule { @('Sunshine') }
        Mock -ModuleName $script:ModuleName Restore-VegaSunshineServiceState {
            param($Name, $StartType, $OriginalStatus)
            $null = $Name
            $null = $StartType
            $null = $OriginalStatus
            [pscustomobject]@{ Success = $true; Message = 'ok' }
        }
        Mock -ModuleName $script:ModuleName Test-VegaWingetAvailable { $true }
        Mock -ModuleName $script:ModuleName Uninstall-VegaPackage { $true }
        Mock -ModuleName $script:ModuleName Write-VegaLegacyStateWarning { $false }
    }

    It '只按清单回滚：按键恢复配置、删 Vega 规则、恢复安装器规则与服务' {
        $original = "sunshine_name = OldName`nuser_key = keep"
        Set-Content -LiteralPath $script:configPath -Encoding UTF8 -Value $original -NoNewline
        $installed = Merge-VegaSunshineConfigText -ExistingText $original -Values ([ordered]@{
                sunshine_name  = 'Vega'
                address_family = 'both'
            })
        Set-Content -LiteralPath $script:configPath -Encoding UTF8 -Value $installed -NoNewline

        $state = Get-VegaEmptyState
        $state = Add-VegaStatePackage -State $state -PackageId 'LizardByte.Sunshine' -Name 'Sunshine'
        $state = Add-VegaStateFirewallRule -State $state -Name 'Vega-Sunshine-TCP'
        $state = Add-VegaStateFirewallRule -State $state -Name 'Vega-Sunshine-UDP'
        $state = Add-VegaStateDisabledFirewallRule -State $state -Name 'Sunshine'
        $state = Add-VegaStateService -State $state -Name 'SunshineService' -StartType 'Manual' -Status 'Running'
        $snapshot = Get-VegaConfigKeySnapshot -Text $original -Keys @('sunshine_name', 'address_family')
        $state = Add-VegaStateManagedKey -State $state -Path $script:configPath -Snapshot $snapshot
        $null = Write-VegaState -State $state -Path $script:statePath -Confirm:$false

        $result = Invoke-VegaHostUninstall -StatePath $script:statePath -RemoveApps -Confirm:$false

        $result.ExitCode | Should -Be 0
        $text = Get-Content -LiteralPath $script:configPath -Encoding UTF8 -Raw
        $text | Should -Match '(?m)^sunshine_name = OldName$'
        $text | Should -Not -Match 'address_family'
        $text | Should -Match '(?m)^user_key = keep$'
        Test-Path -LiteralPath "$($script:configPath).bak" | Should -BeFalse

        Should -Invoke -ModuleName $script:ModuleName -CommandName Enable-VegaSunshineInstallerFirewallRule -Times 1 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Restore-VegaSunshineServiceState -Times 1 -Exactly `
            -ParameterFilter { $StartType -eq 'Manual' -and $OriginalStatus -eq 'Running' }
        Should -Invoke -ModuleName $script:ModuleName -CommandName Uninstall-VegaPackage -Times 1 -Exactly
        Test-Path -LiteralPath $script:statePath | Should -BeFalse
    }

    It '没加 -RemoveApps 时保留组件待办清单，不删除整个清单' {
        Set-Content -LiteralPath $script:configPath -Encoding UTF8 -Value 'sunshine_name = Vega' -NoNewline

        $state = Get-VegaEmptyState
        $state = Add-VegaStatePackage -State $state -PackageId 'LizardByte.Sunshine' -Name 'Sunshine'
        $state = Add-VegaStateFirewallRule -State $state -Name 'Vega-Sunshine-TCP'
        $null = Write-VegaState -State $state -Path $script:statePath -Confirm:$false

        $result = Invoke-VegaHostUninstall -StatePath $script:statePath -Confirm:$false

        $result.ExitCode | Should -Be 0
        Should -Invoke -ModuleName $script:ModuleName -CommandName Uninstall-VegaPackage -Times 0 -Exactly
        Test-Path -LiteralPath $script:statePath | Should -BeTrue
    }

    It '清单记录不在白名单时拒绝执行，并保留清单' {
        $evilConfig = Join-Path (Join-Path $TestDrive 'evil') 'sunshine.conf'
        $state = Get-VegaEmptyState
        $state.FirewallRules = @([pscustomobject]@{ Name = 'Evil-Rule' })
        $state.Services = @([pscustomobject]@{
                Name = 'EvilService'; OriginalStartType = 'Automatic'; OriginalStatus = 'Running'; Restored = $false
            })
        $state.ManagedConfigKeys = @([pscustomobject]@{
                Path = $evilConfig; Key = 'sunshine_name'; Existed = $false; OriginalValue = ''; Restored = $false
            })
        $state.Packages = @([pscustomobject]@{
                PackageId = 'Evil.Package'; Name = 'Evil'; InstalledByVega = $true
            })
        $null = Write-VegaState -State $state -Path $script:statePath -Confirm:$false

        Mock -ModuleName $script:ModuleName Restore-VegaManagedConfig { throw '不该被调用' }
        Mock -ModuleName $script:ModuleName Restore-VegaSunshineServiceState { throw '不该被调用' }
        Mock -ModuleName $script:ModuleName Uninstall-VegaPackage { throw '不该被调用' }

        $result = Invoke-VegaHostUninstall -StatePath $script:statePath -RemoveApps -Confirm:$false

        $result.ExitCode | Should -Be 1
        ($result.Failures -join "`n") | Should -Match 'Evil-Rule'
        ($result.Failures -join "`n") | Should -Match 'EvilService'
        ($result.Failures -join "`n") | Should -Match 'Evil.Package'
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaFirewallRuleByName -Times 0 -Exactly `
            -ParameterFilter { $Name -eq 'Evil-Rule' }
        Test-Path -LiteralPath $script:statePath | Should -BeTrue
    }

    It '已标记 Restored 的服务卸载时跳过' {
        $state = Get-VegaEmptyState
        $state = Add-VegaStateService -State $state -Name 'SunshineService' -StartType 'Manual' -Status 'Running'
        $state = Set-VegaStateServiceRestored -State $state -Name 'SunshineService' -Confirm:$false
        $null = Write-VegaState -State $state -Path $script:statePath -Confirm:$false

        $result = Invoke-VegaHostUninstall -StatePath $script:statePath -Confirm:$false

        $result.ExitCode | Should -Be 0
        Should -Invoke -ModuleName $script:ModuleName -CommandName Restore-VegaSunshineServiceState -Times 0 -Exactly
    }

    It '安装前不存在的服务卸载时不恢复' {
        $state = Get-VegaEmptyState
        $state = Add-VegaStateService -State $state -Name 'SunshineService' -StartType 'NotPresent' -Status 'NotPresent'
        $null = Write-VegaState -State $state -Path $script:statePath -Confirm:$false

        $result = Invoke-VegaHostUninstall -StatePath $script:statePath -Confirm:$false

        $result.ExitCode | Should -Be 0
        Should -Invoke -ModuleName $script:ModuleName -CommandName Restore-VegaSunshineServiceState -Times 0 -Exactly
    }

    It '卸载时也检查旧版清单并警告' {
        $state = Get-VegaEmptyState
        $null = Write-VegaState -State $state -Path $script:statePath -Confirm:$false

        $null = Invoke-VegaHostUninstall -StatePath $script:statePath -Confirm:$false

        Should -Invoke -ModuleName $script:ModuleName -CommandName Write-VegaLegacyStateWarning -Times 1 -Exactly
    }
}

Describe 'Write-VegaLegacyStateWarning' {
    It '检测到旧清单时返回 true，且不读取内容' {
        $path = Join-Path $TestDrive 'legacy-state.json'
        Set-Content -LiteralPath $path -Encoding UTF8 -Value '{ 这不是合法 JSON' -NoNewline

        Write-VegaLegacyStateWarning -Path $path | Should -BeTrue

        # 只判断存在，不解析、不改写
        (Get-Content -LiteralPath $path -Encoding UTF8 -Raw) | Should -Be '{ 这不是合法 JSON'
    }

    It '没有旧清单时返回 false' {
        Write-VegaLegacyStateWarning -Path (Join-Path $TestDrive 'no-legacy.json') | Should -BeFalse
    }
}

Describe '受管键基线（重跑不覆盖，卸载按键回滚）' {
    It '重跑只保留第一次的值，回滚时只动受管键' {
        $path = Join-Path $TestDrive 'managed.conf'
        $original = "sunshine_name = OldName`nport = 48000"
        Set-Content -LiteralPath $path -Encoding UTF8 -Value $original -NoNewline

        $state = Get-VegaEmptyState
        $first = Get-VegaConfigKeySnapshot -Text $original -Keys @('sunshine_name', 'address_family')
        $state = Add-VegaStateManagedKey -State $state -Path $path -Snapshot $first

        # 模拟重跑：配置已经被 Vega 改过，重跑不能把基线刷新成 Vega 自己的值
        $changed = "sunshine_name = Vega`naddress_family = both"
        $second = Get-VegaConfigKeySnapshot -Text $changed -Keys @('sunshine_name', 'address_family')
        $state = Add-VegaStateManagedKey -State $state -Path $path -Snapshot $second

        $records = @(Get-VegaStateManagedKey -State $state -Path $path)
        $records.Count | Should -Be 2
        ($records | Where-Object { $_.Key -eq 'sunshine_name' }).OriginalValue | Should -Be 'OldName'
        ($records | Where-Object { $_.Key -eq 'address_family' }).Existed | Should -BeFalse

        $installed = "sunshine_name = Vega`naddress_family = both`nuser_key = keep"
        Set-Content -LiteralPath $path -Encoding UTF8 -Value $installed -NoNewline

        $restore = Restore-VegaManagedConfig -Path $path -Records $records -Confirm:$false
        $restore.Restored | Should -BeTrue

        $text = Get-Content -LiteralPath $path -Encoding UTF8 -Raw
        $text | Should -Match '(?m)^sunshine_name = OldName$'
        $text | Should -Not -Match 'address_family'
        $text | Should -Match '(?m)^user_key = keep$'
    }
}

Describe 'Install-VegaPackage -Force' {
    It '安装前已存在时仍返回 PreExisting，并真的执行了重装' {
        Mock -ModuleName $script:ModuleName Get-VegaWingetPackageStatus {
            [pscustomobject]@{ PackageId = 'LizardByte.Sunshine'; Installed = $true; Status = 'Installed'; ExitCode = 0; Error = '' }
        }
        Mock -ModuleName $script:ModuleName Invoke-VegaWinget {
            [pscustomobject]@{ FilePath = 'winget.exe'; ExitCode = 0; Output = @(); StdOut = @(); StdErr = @(); TimedOut = $false }
        }

        $outcome = Install-VegaPackage -PackageId 'LizardByte.Sunshine' -DisplayName 'Sunshine' -Force -Confirm:$false

        $outcome.PreExisting | Should -BeTrue
        $outcome.Installed | Should -BeTrue
        Should -Invoke -ModuleName $script:ModuleName -CommandName Invoke-VegaWinget -Times 1 -Exactly
    }

    It '查询失败时抛异常，不把“查不到”当成“未安装”' {
        Mock -ModuleName $script:ModuleName Get-VegaWingetPackageStatus {
            [pscustomobject]@{ PackageId = 'LizardByte.Sunshine'; Installed = $false; Status = 'Failed'; ExitCode = 1; Error = 'boom' }
        }

        { Install-VegaPackage -PackageId 'LizardByte.Sunshine' -Confirm:$false } | Should -Throw
    }
}

Describe '主控端入口（mock）' {
    It '安装失败时退出码为 1' {
        Mock -ModuleName $script:ModuleName Test-VegaWingetAvailable { $true }
        Mock -ModuleName $script:ModuleName Install-VegaPackage { throw '安装 Moonlight 失败' }

        $statePath = Join-Path $TestDrive 'client-install-state.json'
        $result = Invoke-VegaClientInstall -StatePath $statePath -SkipTailscale -Confirm:$false

        $result.ExitCode | Should -Be 1
    }

    It '只卸载清单里由 Vega 安装的组件，用户原有的 Tailscale 不动' {
        $statePath = Join-Path $TestDrive 'client-state.json'
        $state = Get-VegaEmptyState
        $state = Add-VegaStatePackage -State $state -PackageId 'MoonlightGameStreamingProject.Moonlight' -Name 'Moonlight'
        $state = Add-VegaStatePackage -State $state -PackageId 'Tailscale.Tailscale' -Name 'Tailscale' -PreExisting
        $null = Write-VegaState -State $state -Path $statePath -Confirm:$false

        Mock -ModuleName $script:ModuleName Test-VegaWingetAvailable { $true }
        Mock -ModuleName $script:ModuleName Uninstall-VegaPackage { $true }

        $result = Invoke-VegaClientUninstall -StatePath $statePath -RemoveApps -Confirm:$false

        $result.ExitCode | Should -Be 0
        Should -Invoke -ModuleName $script:ModuleName -CommandName Uninstall-VegaPackage -Times 1 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Uninstall-VegaPackage -Times 1 -Exactly `
            -ParameterFilter { $PackageId -eq 'MoonlightGameStreamingProject.Moonlight' }
    }

    It '旧版清单里的 RustDesk.RustDesk 包按已下线处理，不阻断 -RemoveApps 回滚' {
        $statePath = Join-Path $TestDrive 'client-legacy-rustdesk.json'
        $state = Get-VegaEmptyState
        $state = Add-VegaStatePackage -State $state -PackageId 'RustDesk.RustDesk' -Name 'RustDesk'
        $null = Write-VegaState -State $state -Path $statePath -Confirm:$false

        Mock -ModuleName $script:ModuleName Test-VegaWingetAvailable { $true }
        Mock -ModuleName $script:ModuleName Write-VegaStatus { }
        Mock -ModuleName $script:ModuleName Uninstall-VegaPackage { throw '不该被调用' }

        $result = Invoke-VegaClientUninstall -StatePath $statePath -RemoveApps -Confirm:$false

        $result.ExitCode | Should -Be 0
        @($result.Failures).Count | Should -Be 0
        Should -Invoke -ModuleName $script:ModuleName -CommandName Uninstall-VegaPackage -Times 0 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Write-VegaStatus -ParameterFilter {
            $Message -match '手动卸载'
        } -Times 1 -Exactly
        Test-Path -LiteralPath $statePath | Should -BeFalse
    }

    It '没有状态清单时不动系统，退出码为 0' {
        $statePath = Join-Path $TestDrive 'missing-state.json'

        Mock -ModuleName $script:ModuleName Uninstall-VegaPackage { throw '不该被调用' }

        $result = Invoke-VegaClientUninstall -StatePath $statePath -RemoveApps -Confirm:$false
        $result.ExitCode | Should -Be 0
        Should -Invoke -ModuleName $script:ModuleName -CommandName Uninstall-VegaPackage -Times 0 -Exactly
    }
}

Describe '组件清单' {
    It '不再包含 RustDesk（WinGet 社区源已下架）' {
        # RustDesk 只能从官方发行页手动安装；清单里留着包 ID 会让安装步骤
        # 去 winget 找一个已下架的包。
        { Get-VegaComponent -Name 'RustDesk' } | Should -Throw
        (Get-VegaComponent -Name 'Sunshine').PackageId | Should -Be 'LizardByte.Sunshine'
        (Get-VegaComponent -Name 'Tailscale').PackageId | Should -Be 'Tailscale.Tailscale'
        (Get-VegaComponent -Name 'Moonlight').PackageId | Should -Be 'MoonlightGameStreamingProject.Moonlight'
    }
}
