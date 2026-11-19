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
