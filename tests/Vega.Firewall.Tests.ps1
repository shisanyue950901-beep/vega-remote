#Requires -Version 5.1
<#
  防火墙规则定义与安装器规则筛选的单元测试（Pester 5）。
  纯函数，不查询真实防火墙。
#>

BeforeAll {
    $modulePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
    Import-Module $modulePath -Force
}

Describe 'Get-VegaFirewallRuleSpec' {
    It '只放行串流端口，管理端口 47990 不在任何规则里' {
        $specs = @(Get-VegaFirewallRuleSpec)

        $specs.Count | Should -Be 2
        $allPorts = @($specs | ForEach-Object { $_.LocalPort })
        $allPorts | Should -Not -Contain '47990'

        $tcp = $specs | Where-Object { $_.Protocol -eq 'TCP' }
        $tcp.Name | Should -Be 'Vega-Sunshine-TCP'
        $tcp.LocalPort | Should -Contain '47984'
        $tcp.LocalPort | Should -Contain '47989'
        $tcp.LocalPort | Should -Contain '48010'

        $udp = $specs | Where-Object { $_.Protocol -eq 'UDP' }
        $udp.Name | Should -Be 'Vega-Sunshine-UDP'
        $udp.LocalPort | Should -Contain '47998-48000'
        $udp.LocalPort | Should -Contain '48002'
        $udp.LocalPort | Should -Contain '48010'
    }

    It '规则内部 Name 固定，便于按 Name 精确操作' {
        $names = @(Get-VegaFirewallRuleSpec | ForEach-Object { $_.Name })
        $names | Should -Be @('Vega-Sunshine-TCP', 'Vega-Sunshine-UDP')
    }
}

Describe 'Test-VegaPortInRange' {
    It '单端口精确匹配' {
        Test-VegaPortInRange -Ports @('47990') -Port 47990 | Should -BeTrue
        Test-VegaPortInRange -Ports @('47990') -Port 47984 | Should -BeFalse
    }

    It '端口区间匹配' {
        Test-VegaPortInRange -Ports @('47998-48000') -Port 47999 | Should -BeTrue
        Test-VegaPortInRange -Ports @('47998-48000') -Port 48001 | Should -BeFalse
    }

    It 'Any 与空集合视为覆盖所有端口' {
        Test-VegaPortInRange -Ports @('Any') -Port 47990 | Should -BeTrue
        Test-VegaPortInRange -Ports @() -Port 47990 | Should -BeTrue
    }
}

Describe 'Select-VegaSunshineInstallerFirewallRule' {
    It '选中安装器对 47990 放行的规则' {
        $rules = @(
            [pscustomobject]@{
                Name = 'Sunshine'; DisplayName = 'Sunshine'; Enabled = 'True'
                Program = 'C:\Program Files\Sunshine\sunshine.exe'; LocalPort = @('Any')
            }
        )

        $selected = @(Select-VegaSunshineInstallerFirewallRule -Rules $rules -SunshineExe 'C:\Program Files\Sunshine\sunshine.exe')
        $selected.Count | Should -Be 1
        $selected[0].Name | Should -Be 'Sunshine'
    }

    It '不选中 Vega 自己的规则、已禁用规则、只开串流端口的规则和不相关程序' {
        $rules = @(
            [pscustomobject]@{
                Name = 'Vega-Sunshine-TCP'; DisplayName = 'Vega-Sunshine-TCP'; Enabled = 'True'
                Program = 'C:\Program Files\Sunshine\sunshine.exe'; LocalPort = @('Any')
            },
            [pscustomobject]@{
                Name = 'Sunshine-Disabled'; DisplayName = 'Sunshine'; Enabled = 'False'
                Program = 'C:\Program Files\Sunshine\sunshine.exe'; LocalPort = @('Any')
            },
            [pscustomobject]@{
                Name = 'Sunshine-StreamOnly'; DisplayName = 'Sunshine'; Enabled = 'True'
                Program = 'C:\Program Files\Sunshine\sunshine.exe'; LocalPort = @('47984', '47989', '48010')
            },
            [pscustomobject]@{
                Name = 'Unrelated'; DisplayName = 'Unrelated'; Enabled = 'True'
                Program = 'C:\Other\other.exe'; LocalPort = @('Any')
            }
        )

        @(Select-VegaSunshineInstallerFirewallRule -Rules $rules -SunshineExe 'C:\Program Files\Sunshine\sunshine.exe').Count |
            Should -Be 0
    }

    It '没有程序路径时按显示名识别旧规则' {
        $rules = @(
            [pscustomobject]@{
                Name = 'Legacy-Sunshine'; DisplayName = 'Sunshine'; Enabled = 'True'
                Program = ''; LocalPort = @('47990')
            }
        )

        $selected = @(Select-VegaSunshineInstallerFirewallRule -Rules $rules)
        $selected.Count | Should -Be 1
        $selected[0].Name | Should -Be 'Legacy-Sunshine'
    }

    It '空输入返回空数组' {
        @(Select-VegaSunshineInstallerFirewallRule -Rules @()).Count | Should -Be 0
        @(Select-VegaSunshineInstallerFirewallRule -Rules $null).Count | Should -Be 0
    }
}

Describe 'Test-VegaManagementPortConflict' {
    It '默认端口算出的管理端口不与串流放行端口相交' {
        @(Test-VegaManagementPortConflict -ManagementPorts @(47990)).Count | Should -Be 0
    }

    It '管理端口落进串流放行端口时报告冲突' {
        # port = 47995 时 TCP 放行 47990（HTTPS），再阻断 47990 就自相矛盾
        @(Test-VegaManagementPortConflict -ManagementPorts @(47990) -BasePort 47995) | Should -Contain 47990
    }

    It '空输入返回空数组' {
        @(Test-VegaManagementPortConflict -ManagementPorts @()).Count | Should -Be 0
    }
}

Describe 'Set-VegaAdminBlockRule' {
    BeforeAll {
        $script:ModuleName = 'Vega.Common'
        $module = Get-Module $script:ModuleName
        # Windows 专有 cmdlet 在 Linux 上不存在，先塞同名 stub 再 Mock；
        # Windows 上本来就有，跳过。
        $stubs = @{
            'Get-NetFirewallRule'       = {
                [CmdletBinding()]
                param([string]$Name, [string]$Direction, [string]$Action)
                $null = $Name, $Direction, $Action
            }
            'New-NetFirewallRule'       = {
                [CmdletBinding()]
                param($Name, $DisplayName, $Direction, $Action, $Protocol, $LocalPort,
                    [Alias('Profile')]$FwProfile, $Program, $Enabled, $Description)
                $null = $Name, $DisplayName, $Direction, $Action, $Protocol, $LocalPort,
                $FwProfile, $Program, $Enabled, $Description
            }
            'Set-NetFirewallRule'       = {
                [CmdletBinding()]
                param([string]$Name, $Enabled, $Action)
                $null = $Name, $Enabled, $Action
            }
            'Set-NetFirewallPortFilter' = {
                [CmdletBinding()]
                param($AssociatedNetFirewallRule, [string]$Protocol, [string[]]$LocalPort)
                $null = $AssociatedNetFirewallRule, $Protocol, $LocalPort
            }
            'Get-NetFirewallPortFilter' = {
                [CmdletBinding()]
                param($AssociatedNetFirewallRule)
                $null = $AssociatedNetFirewallRule
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

    BeforeEach {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule { $null }
        Mock -ModuleName $script:ModuleName New-NetFirewallRule { }
        Mock -ModuleName $script:ModuleName Set-NetFirewallRule { }
        Mock -ModuleName $script:ModuleName Set-NetFirewallPortFilter { }
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter {
            [pscustomobject]@{ LocalPort = @('47990') }
        }
        Mock -ModuleName $script:ModuleName Remove-VegaFirewallRuleByName { $true }
    }

    It '规则已存在时原地更新端口，绝不删除也不重建' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name)
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block' }
        }
        # 更新生效后的端口过滤器
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter {
            [pscustomobject]@{ LocalPort = @('47991') }
        }

        $name = Set-VegaAdminBlockRule -ManagementPorts @(47991) -Confirm:$false

        $name | Should -Be 'Vega-Block-Admin'
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaFirewallRuleByName -Times 0 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName New-NetFirewallRule -Times 0 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Set-NetFirewallRule -Times 1 -Exactly `
            -ParameterFilter { $Action -eq 'Block' -and $Enabled -eq 'True' }
        Should -Invoke -ModuleName $script:ModuleName -CommandName Set-NetFirewallPortFilter -Times 1 -Exactly `
            -ParameterFilter { $LocalPort -contains '47991' -and $Protocol -eq 'TCP' }
    }

    It '规则不存在时才创建，并回读校验端口' {
        $script:BlockCreated = $false
        Mock -ModuleName $script:ModuleName New-NetFirewallRule { $script:BlockCreated = $true }
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name)
            if ($Name -ne 'Vega-Block-Admin' -or -not $script:BlockCreated) { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block' }
        }
        $name = Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false

        $name | Should -Be 'Vega-Block-Admin'
        Should -Invoke -ModuleName $script:ModuleName -CommandName New-NetFirewallRule -Times 1 -Exactly `
            -ParameterFilter { $Action -eq 'Block' -and $Protocol -eq 'TCP' -and $Enabled -eq 'True' }
        Should -Invoke -ModuleName $script:ModuleName -CommandName Set-NetFirewallRule -Times 0 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Set-NetFirewallPortFilter -Times 0 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaFirewallRuleByName -Times 0 -Exactly
    }

    It '回读发现 Enabled/Action 不对时抛异常，且不删除已有阻断' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name)
            if ($Name -ne 'Vega-Block-Admin') { return }
            # 回读到一个被停用的规则
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'False'; Action = 'Block' }
        }

        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*状态异常*'
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaFirewallRuleByName -Times 0 -Exactly
    }

    It '回读发现端口没覆盖时抛异常' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name)
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block' }
        }
        # 更新写成功了但过滤器没生效：回读必须发现端口缺失
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter {
            [pscustomobject]@{ LocalPort = @('47990') }
        }

        { Set-VegaAdminBlockRule -ManagementPorts @(47990, 47991) -Confirm:$false } | Should -Throw '*未覆盖端口 47991*'
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaFirewallRuleByName -Times 0 -Exactly
    }

    It '回读不到端口过滤器时抛异常' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name)
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter { $null }

        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*端口过滤器*'
    }

    It '更新失败时不删除已有阻断，直接抛异常中止安装' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name)
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block' }
        }
        Mock -ModuleName $script:ModuleName Set-NetFirewallRule { throw '拒绝访问' }

        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*更新管理端口阻断规则*'
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaFirewallRuleByName -Times 0 -Exactly
    }
}
