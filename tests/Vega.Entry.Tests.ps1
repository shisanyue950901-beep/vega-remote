#Requires -Version 5.1
<#
  入口级 mock 测试（Pester 5）：
    - winget 安装失败反映到退出码、不写半截状态
    - 卸载只按状态清单回滚，配置被用户改过时报冲突
    - 安装时的配置合并保留用户自己加的键
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
            param(
                [Parameter(Position = 0)]
                [string]$ClassName
            )
            $null = $ClassName
        }
        'Stop-Service'    = {
            [CmdletBinding()]
            param(
                [Parameter(Position = 0)]
                [string[]]$Name,

                [switch]$Force
            )
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
        $script:statePath = Join-Path $TestDrive 'state.json'
        $script:sunshineDir = Join-Path $TestDrive 'Sunshine'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:sunshineDir 'config') -Force
        $null = New-Item -ItemType File -Path (Join-Path $script:sunshineDir 'sunshine.exe') -Force

        $script:sunshine = [pscustomobject]@{
            Directory = $script:sunshineDir
            Exe       = (Join-Path $script:sunshineDir 'sunshine.exe')
            Config    = (Join-Path (Join-Path $script:sunshineDir 'config') 'sunshine.conf')
            Version   = '2026.1'
        }
    }

    It 'winget 安装 Sunshine 失败时退出码为 1，且不留下状态清单' {
        Mock -ModuleName $script:ModuleName Test-VegaWingetAvailable { $true }
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $null }
        Mock -ModuleName $script:ModuleName Install-VegaPackage { throw '安装 Sunshine 失败（winget 退出码 1603）' }

        $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath -SkipTailscale

        $result.ExitCode | Should -Be 1
        ($result.Failures -join "`n") | Should -Match '1603'
        Test-Path -LiteralPath $script:statePath | Should -BeFalse
    }

    It 'Tailscale 安装失败时仍配置好 Sunshine，但退出码为 1' {
        Mock -ModuleName $script:ModuleName Test-VegaWingetAvailable { $true }
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstall { $script:sunshine }
        Mock -ModuleName $script:ModuleName Install-VegaPackage {
            param($PackageId, $DisplayName, [switch]$Force)
            # -Force 只是为了让 mock 的签名和真实命令对上
            $null = $Force
            if ($PackageId -eq 'Tailscale.Tailscale') { throw "安装 $DisplayName 失败（winget 退出码 1603）" }
            return $true
        }
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstallerFirewallRule { @() }
        Mock -ModuleName $script:ModuleName Get-CimInstance {
            [pscustomobject]@{ Name = 'NVIDIA GeForce RTX 4070' }
        }
        Mock -ModuleName $script:ModuleName Get-VegaPowerCfgPath { $null }
        Mock -ModuleName $script:ModuleName Set-VegaFirewallRule { 2 }
        Mock -ModuleName $script:ModuleName Get-VegaSunshineService {
            [pscustomobject]@{ Name = 'SunshineService'; Status = 'Running'; StartType = 'Automatic' }
        }
        Mock -ModuleName $script:ModuleName Restart-VegaSunshineService {
            [pscustomobject]@{ Found = $true; Name = 'SunshineService'; Status = 'Running'; Success = $true; Error = '' }
        }
        Mock -ModuleName $script:ModuleName Get-VegaPublicIPv6 { @() }

        # 用户原来的配置：自定义端口与凭据路径必须保留
        $existing = @(
            'port = 48000',
            'credentials_file = C:\secret\creds.json',
            'sunshine_name = MyMachine'
        ) -join "`n"
        Set-Content -LiteralPath $script:sunshine.Config -Value $existing -NoNewline

        $result = Invoke-VegaHostInstall -StatePath $script:statePath -TemplatePath $script:TemplatePath

        $result.ExitCode | Should -Be 1
        ($result.Failures -join "`n") | Should -Match 'Tailscale'

        $merged = Get-Content -LiteralPath $script:sunshine.Config -Raw
        $merged | Should -Match 'port = 48000'
        $merged | Should -Match 'credentials_file = C:\\secret\\creds\.json'
        $merged | Should -Match 'sunshine_name = Vega'
        $merged | Should -Match 'adapter_name = NVIDIA GeForce RTX 4070'
        $merged | Should -Match 'address_family = both'
        $merged | Should -Match 'origin_web_ui_allowed = pc'

        Test-Path -LiteralPath $script:statePath | Should -BeTrue
        $state = Read-VegaState -Path $script:statePath
        (Test-VegaStatePackage -State $state -PackageId 'LizardByte.Sunshine') | Should -BeTrue
    }
}

Describe 'Invoke-VegaHostUninstall（mock）' {
    BeforeEach {
        $script:statePath = Join-Path $TestDrive 'uninstall-state.json'
        $script:configPath = Join-Path $TestDrive 'config/sunshine.conf'
        $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'config') -Force

        Set-Content -LiteralPath $script:configPath -Value 'original config' -NoNewline
        $written = Set-VegaSunshineConfig -Path $script:configPath -Content 'managed config' -Confirm:$false

        $state = Get-VegaEmptyState
        $state = Add-VegaStatePackage -State $state -PackageId 'LizardByte.Sunshine' -Name 'Sunshine'
        $state = Add-VegaStatePackage -State $state -PackageId 'Tailscale.Tailscale' -Name 'Tailscale' -PreExisting
        $state = Add-VegaStateFirewallRule -State $state -Name 'Vega-Sunshine-TCP'
        $state = Add-VegaStateFirewallRule -State $state -Name 'Vega-Sunshine-UDP'
        $state = Add-VegaStateDisabledFirewallRule -State $state -Name 'Sunshine'
        $state = Set-VegaStateServiceStartType -State $state -Name 'SunshineService' -StartType 'Manual'
        $state = Add-VegaStateBackup -State $state -Path $script:configPath `
            -BackupPath $written.BackupPath `
            -OriginalExisted $true `
            -WrittenSha256 $written.Sha256 `
            -BackupCreated $true
        $null = Write-VegaState -State $state -Path $script:statePath -Confirm:$false
    }

    It '只按清单回滚：恢复配置、Vega 规则、安装器规则、服务启动类型' {
        Mock -ModuleName $script:ModuleName Remove-VegaFirewallRule { 1 }
        Mock -ModuleName $script:ModuleName Enable-VegaSunshineInstallerFirewallRule { @('Sunshine') }
        Mock -ModuleName $script:ModuleName Set-VegaSunshineServiceStartType { $true }
        Mock -ModuleName $script:ModuleName Stop-Service { }
        Mock -ModuleName $script:ModuleName Test-VegaWingetAvailable { $true }
        Mock -ModuleName $script:ModuleName Uninstall-VegaPackage { $true }

        $result = Invoke-VegaHostUninstall -StatePath $script:statePath -RemoveApps -Confirm:$false

        $result.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $script:configPath -Raw) | Should -Be 'original config'

        Should -Invoke -ModuleName $script:ModuleName -CommandName Enable-VegaSunshineInstallerFirewallRule -Times 1 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Set-VegaSunshineServiceStartType -Times 1 -Exactly

        Should -Invoke -ModuleName $script:ModuleName -CommandName Uninstall-VegaPackage -Times 1 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Uninstall-VegaPackage -Times 1 -Exactly `
            -ParameterFilter { $PackageId -eq 'LizardByte.Sunshine' }
        Should -Invoke -ModuleName $script:ModuleName -CommandName Uninstall-VegaPackage -Times 0 -Exactly `
            -ParameterFilter { $PackageId -eq 'Tailscale.Tailscale' }

        Test-Path -LiteralPath $script:statePath | Should -BeFalse
    }

    It '配置被用户改过时报告冲突、不覆盖，并保留备份' {
        Set-Content -LiteralPath $script:configPath -Value 'user changed this' -NoNewline

        Mock -ModuleName $script:ModuleName Remove-VegaFirewallRule { 1 }
        Mock -ModuleName $script:ModuleName Enable-VegaSunshineInstallerFirewallRule { @('Sunshine') }
        Mock -ModuleName $script:ModuleName Set-VegaSunshineServiceStartType { $true }
        Mock -ModuleName $script:ModuleName Stop-Service { }

        $result = Invoke-VegaHostUninstall -StatePath $script:statePath -Confirm:$false

        $result.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $script:configPath -Raw) | Should -Be 'user changed this'
        Test-Path -LiteralPath "$($script:configPath).bak" | Should -BeTrue
    }
}

Describe 'Invoke-VegaClientUninstall（mock）' {
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

    It '没有状态清单时不动系统' {
        $statePath = Join-Path $TestDrive 'missing-state.json'

        Mock -ModuleName $script:ModuleName Uninstall-VegaPackage { throw '不该被调用' }

        $result = Invoke-VegaClientUninstall -StatePath $statePath -RemoveApps -Confirm:$false
        $result.ExitCode | Should -Be 0
        Should -Invoke -ModuleName $script:ModuleName -CommandName Uninstall-VegaPackage -Times 0 -Exactly
    }
}
