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

    It '只比较 TCP 放行端口：同号 UDP 端口不算冲突' {
        # 默认 port=47989 时 48002 只是 UDP 麦克风端口，TCP 管理端口可以安全阻断
        @(Test-VegaManagementPortConflict -ManagementPorts @(48002)).Count | Should -Be 0
        # 48010 同时是 TCP RTSP 和 UDP 端口，仍然冲突
        @(Test-VegaManagementPortConflict -ManagementPorts @(48010)) | Should -Contain 48010
    }
}

Describe 'Get-VegaSunshineBasePort' {
    It '只剥离成对双引号' {
        $path = Join-Path $TestDrive 'quoted.conf'
        Set-Content -LiteralPath $path -Value 'port = "50000"' -Encoding UTF8
        Get-VegaSunshineBasePort -ConfigPath $path | Should -Be 50000
    }

    It '单引号不剥离，按 Sunshine 的行为解析失败并中止' {
        $path = Join-Path $TestDrive 'single-quoted.conf'
        Set-Content -LiteralPath $path -Value "port = '50000'" -Encoding UTF8
        { Get-VegaSunshineBasePort -ConfigPath $path } | Should -Throw '*port 无效*'
    }

    It '接受 0x 十六进制端口值' {
        $path = Join-Path $TestDrive 'hex.conf'
        Set-Content -LiteralPath $path -Value 'port = 0xC350' -Encoding UTF8
        Get-VegaSunshineBasePort -ConfigPath $path | Should -Be 50000

        Set-Content -LiteralPath $path -Value 'port = 0xBB80' -Encoding UTF8
        Get-VegaSunshineBasePort -ConfigPath $path | Should -Be 48000
    }

    It '十进制允许前导零，与 Sunshine 的十进制转换一致' {
        $path = Join-Path $TestDrive 'leading-zero.conf'
        Set-Content -LiteralPath $path -Value 'port = 047989' -Encoding UTF8
        Get-VegaSunshineBasePort -ConfigPath $path | Should -Be 47989
    }

    It '去掉行尾 # 注释且注释前没有空格时按十进制解析' {
        $path = Join-Path $TestDrive 'comment.conf'
        Set-Content -LiteralPath $path -Value 'port = 50000# 自定义端口' -Encoding UTF8
        Get-VegaSunshineBasePort -ConfigPath $path | Should -Be 50000
    }

    It '注释前有空格时与上游一致：保留空格导致十进制转换失败，按无法确定端口中止' {
        # Sunshine 去注释后不 Trim，'50000 ' 的十进制转换失败；Vega 不替它修，直接中止
        $path = Join-Path $TestDrive 'comment-space.conf'
        Set-Content -LiteralPath $path -Value 'port = 50000 # 自定义端口' -Encoding UTF8
        { Get-VegaSunshineBasePort -ConfigPath $path } | Should -Throw '*无法可靠确定端口*'
    }

    It '有效范围是 1019-65514，越界中止' {
        $path = Join-Path $TestDrive 'range.conf'
        Set-Content -LiteralPath $path -Value 'port = 1018' -Encoding UTF8
        { Get-VegaSunshineBasePort -ConfigPath $path } | Should -Throw '*port 无效*'

        Set-Content -LiteralPath $path -Value 'port = 65515' -Encoding UTF8
        { Get-VegaSunshineBasePort -ConfigPath $path } | Should -Throw '*port 无效*'

        Set-Content -LiteralPath $path -Value 'port = 1019' -Encoding UTF8
        Get-VegaSunshineBasePort -ConfigPath $path | Should -Be 1019

        Set-Content -LiteralPath $path -Value 'port = 65514' -Encoding UTF8
        Get-VegaSunshineBasePort -ConfigPath $path | Should -Be 65514

        ConvertFrom-VegaSunshinePortValue -Value '1018' | Should -BeNullOrEmpty
        ConvertFrom-VegaSunshinePortValue -Value '65515' | Should -BeNullOrEmpty
        ConvertFrom-VegaSunshinePortValue -Value '1019' | Should -Be 1019
        ConvertFrom-VegaSunshinePortValue -Value '65514' | Should -Be 65514
    }

    It '端口值解析失败时中止，不再静默回退 47989' {
        $path = Join-Path $TestDrive 'bad.conf'
        Set-Content -LiteralPath $path -Value 'port = "50000x"' -Encoding UTF8
        { Get-VegaSunshineBasePort -ConfigPath $path } | Should -Throw '*port 无效*'
    }

    It '没有 port 键时仍用默认 47989' {
        $path = Join-Path $TestDrive 'noport.conf'
        Set-Content -LiteralPath $path -Value 'sunshine_name = Vega' -Encoding UTF8
        Get-VegaSunshineBasePort -ConfigPath $path | Should -Be 47989
    }
}

Describe 'Get-VegaAdminBlockPortList' {
    It '安装前始终包含默认 47990，并与管理端口去重' {
        $ports = @(Get-VegaAdminBlockPortList -ManagementPorts @(47991) -BasePort 47990 -IncludeDefaultManagementPort)
        $ports | Should -Be @(47990, 47991)

        @(Get-VegaAdminBlockPortList -ManagementPorts @(47990) -BasePort 47989 -IncludeDefaultManagementPort) |
            Should -Be @(47990)
    }

    It '安装完成后只在 47990 不是串流端口时继续阻断它' {
        # 默认端口：管理端口 47990，47990 本身是管理端口，保留
        @(Get-VegaAdminBlockPortList -ManagementPorts @(47990) -BasePort 47989) | Should -Be @(47990)

        # 自定义端口：管理端口 48001，47990 不在串流放行列表里，也要阻断
        @(Get-VegaAdminBlockPortList -ManagementPorts @(48001) -BasePort 48000) | Should -Be @(47990, 48001)

        # port = 47990 时 47990 是 HTTP 串流端口，不能再阻断它
        @(Get-VegaAdminBlockPortList -ManagementPorts @(47991) -BasePort 47990) | Should -Be @(47991)
    }

    It '最终列表复用 TCP-only 冲突判定：port = 47981 时仍阻断 47990' {
        # 47981 + 9 = 47990 只是 UDP 视频端口，不占用 TCP 47990
        @(Get-VegaAdminBlockPortList -ManagementPorts @(47982) -BasePort 47981) |
            Should -Be @(47982, 47990)
    }
}

Describe 'Test-VegaHostFirewallEnabled' {
    BeforeAll {
        $script:ModuleName = 'Vega.Common'
        $module = Get-Module $script:ModuleName
        # Linux 上没有这些 Windows cmdlet，先塞同名 stub 再 Mock。
        $stubs = @{
            'Get-NetConnectionProfile' = {
                [CmdletBinding()]
                param()
            }
            'Get-NetFirewallProfile'   = {
                [CmdletBinding()]
                param([string]$PolicyStore)
                $null = $PolicyStore
            }
        }
        foreach ($stubName in $stubs.Keys) {
            # 过滤器 cmdlet 在 Windows PowerShell 5.1 的动态参数会强转 CimInstance，始终用 stub 覆盖。
            if ($stubName -notlike "*Filter" -and (Get-Command -Name $stubName -ErrorAction SilentlyContinue)) { continue }
            $stubBody = $stubs[$stubName]
            & $module {
                param($name, $body)
                New-Item -Path ("function:script:{0}" -f $name) -Value $body -Force | Out-Null
            } $stubName $stubBody
        }
    }

    It '所有活动接口对应的配置开启且未排除接口时通过' {
        Mock -ModuleName $script:ModuleName Get-NetConnectionProfile {
            [pscustomobject]@{ InterfaceAlias = 'Ethernet'; NetworkCategory = 'Private' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallProfile {
            [pscustomobject]@{ Name = 'Private'; Enabled = 'True'; DisabledInterfaceAliases = @() }
        }

        Test-VegaHostFirewallEnabled | Should -BeTrue
    }

    It '活动接口被 DisabledInterfaceAliases 排除时返回 false' {
        Mock -ModuleName $script:ModuleName Get-NetConnectionProfile {
            [pscustomobject]@{ InterfaceAlias = 'Ethernet'; NetworkCategory = 'Private' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallProfile {
            [pscustomobject]@{ Name = 'Private'; Enabled = 'True'; DisabledInterfaceAliases = @('Ethernet') }
        }

        Test-VegaHostFirewallEnabled | Should -BeFalse
    }

    It '接口被 DisabledInterfaceAliases 排除时提示写出接口别名与配置文件，不说防火墙已关闭' {
        Mock -ModuleName $script:ModuleName Get-NetConnectionProfile {
            [pscustomobject]@{ InterfaceAlias = 'Ethernet 2'; NetworkCategory = 'Private' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallProfile {
            [pscustomobject]@{ Name = 'Private'; Enabled = 'True'; DisabledInterfaceAliases = @('Ethernet 2') }
        }

        $status = Get-VegaHostFirewallStatus
        $status.Enabled | Should -BeFalse
        $status.Reason | Should -Be 'InterfaceExcluded'
        $status.Message | Should -Match 'Ethernet 2'
        $status.Message | Should -Match 'Private'
        $status.Message | Should -Not -Match '已关闭'
    }

    It '逐个接口核对：任一接口的配置关闭就返回 false' {
        Mock -ModuleName $script:ModuleName Get-NetConnectionProfile {
            @(
                [pscustomobject]@{ InterfaceAlias = 'Ethernet'; NetworkCategory = 'Private' }
                [pscustomobject]@{ InterfaceAlias = 'Wi-Fi'; NetworkCategory = 'Public' }
            )
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallProfile {
            @(
                [pscustomobject]@{ Name = 'Private'; Enabled = 'True'; DisabledInterfaceAliases = @() }
                [pscustomobject]@{ Name = 'Public'; Enabled = 'False'; DisabledInterfaceAliases = @() }
            )
        }

        Test-VegaHostFirewallEnabled | Should -BeFalse
    }

    It '旧系统没有 DisabledInterfaceAliases 属性时跳过接口排除检查' {
        Mock -ModuleName $script:ModuleName Get-NetConnectionProfile {
            [pscustomobject]@{ InterfaceAlias = 'Ethernet'; NetworkCategory = 'Private' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallProfile {
            [pscustomobject]@{ Name = 'Private'; Enabled = 'True' }
        }

        Test-VegaHostFirewallEnabled | Should -BeTrue
    }
}

Describe 'Set-VegaAdminBlockRule' {
    BeforeAll {
        $script:ModuleName = 'Vega.Common'
        $module = Get-Module $script:ModuleName
        # Windows 专有 cmdlet 在 Linux 上不存在，先塞同名 stub 再 Mock；
        # Windows 上本来就有，跳过。参数签名与真实 cmdlet 保持一致。
        $stubs = @{
            'Get-NetConnectionProfile'  = {
                [CmdletBinding()]
                param()
            }
            'Get-NetFirewallRule'       = {
                [CmdletBinding()]
                param([string]$Name, [string]$Direction, [string]$Action, [string]$PolicyStore)
                $null = $Name, $Direction, $Action, $PolicyStore
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
                param([string]$Name, $Enabled, $Action, [string]$Protocol, [string[]]$LocalPort, [Alias('Profile')][string]$FwProfile)
                $null = $Name, $Enabled, $Action, $Protocol, $LocalPort, $FwProfile
            }
            'Get-NetFirewallPortFilter' = {
                [CmdletBinding()]
                param($AssociatedNetFirewallRule)
                $null = $AssociatedNetFirewallRule
            }
        }
        foreach ($stubName in $stubs.Keys) {
            # 过滤器 cmdlet 在 Windows PowerShell 5.1 的动态参数会强转 CimInstance，始终用 stub 覆盖。
            if ($stubName -notlike "*Filter" -and (Get-Command -Name $stubName -ErrorAction SilentlyContinue)) { continue }
            $stubBody = $stubs[$stubName]
            & $module {
                param($name, $body)
                New-Item -Path ("function:script:{0}" -f $name) -Value $body -Force | Out-Null
            } $stubName $stubBody
        }
    }

    BeforeEach {
        Mock -ModuleName $script:ModuleName Get-NetConnectionProfile {
            [pscustomobject]@{ InterfaceAlias = 'Ethernet'; NetworkCategory = 'Private' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule { $null }
        Mock -ModuleName $script:ModuleName New-NetFirewallRule { }
        Mock -ModuleName $script:ModuleName Set-NetFirewallRule { }
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter -RemoveParameterType AssociatedNetFirewallRule {
            [pscustomobject]@{ LocalPort = @('47990'); Protocol = 'TCP' }
        }
        Mock -ModuleName $script:ModuleName Remove-VegaFirewallRuleByName { $true }
    }

    It '规则已存在时用一次 Set-NetFirewallRule 原地更新协议/端口/动作，绝不删除重建' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter -RemoveParameterType AssociatedNetFirewallRule {
            [pscustomobject]@{ LocalPort = @('47991'); Protocol = 'TCP' }
        }

        $name = Set-VegaAdminBlockRule -ManagementPorts @(47991) -Confirm:$false

        $name | Should -Be 'Vega-Block-Admin'
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaFirewallRuleByName -Times 0 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName New-NetFirewallRule -Times 0 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Set-NetFirewallRule -Times 1 -Exactly `
            -ParameterFilter { $Action -eq 'Block' -and $Enabled -eq 'True' -and $Protocol -eq 'TCP' -and $LocalPort -contains '47991' }
    }

    It '回读通过 PolicyStore ActiveStore' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            if ($Name -ne 'Vega-Block-Admin') { return }
            # 只有 ActiveStore 回读才返回规则：确认实现真的读的是生效存储
            if ($PolicyStore -ne 'ActiveStore') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any' }
        }

        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Not -Throw
        Should -Invoke -ModuleName $script:ModuleName -CommandName Get-NetFirewallRule -Times 1 -Exactly `
            -ParameterFilter { $PolicyStore -eq 'ActiveStore' }
    }

    It '规则不存在时才创建，并回读校验端口' {
        $script:BlockCreated = $false
        Mock -ModuleName $script:ModuleName New-NetFirewallRule { $script:BlockCreated = $true }
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin' -or -not $script:BlockCreated) { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any' }
        }
        $name = Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false

        $name | Should -Be 'Vega-Block-Admin'
        Should -Invoke -ModuleName $script:ModuleName -CommandName New-NetFirewallRule -Times 1 -Exactly `
            -ParameterFilter { $Action -eq 'Block' -and $Protocol -eq 'TCP' -and $Enabled -eq 'True' }
        Should -Invoke -ModuleName $script:ModuleName -CommandName Set-NetFirewallRule -Times 0 -Exactly
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaFirewallRuleByName -Times 0 -Exactly
    }

    It '回读发现 Enabled/Action 不对时抛异常，且不删除已有阻断' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'False'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any' }
        }

        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*状态异常*'
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaFirewallRuleByName -Times 0 -Exactly
    }

    It '回读额外核对 Direction 与协议' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Outbound'; Profile = 'Any' }
        }
        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*状态异常*'

        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter -RemoveParameterType AssociatedNetFirewallRule {
            [pscustomobject]@{ LocalPort = @('47990'); Protocol = 'UDP' }
        }
        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*协议不是 TCP*'
    }

    It '回读核对 PrimaryStatus 与 EnforcementStatus' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{
                Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any'
                PrimaryStatus = 'Error'; EnforcementStatus = 'Enforced'
            }
        }
        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*PrimaryStatus*'

        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{
                Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any'
                PrimaryStatus = 'OK'; EnforcementStatus = 'NotEnforced'
            }
        }
        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*未被强制执行*'
    }

    It 'EnforcementStatus 接受数字与 Full，数组必须全部成功' {
        $env:VEGA_TEST_ENFORCEMENT = '1'
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            $value = $env:VEGA_TEST_ENFORCEMENT
            if ($value -like '*,*') { $value = @($value -split ',') }
            [pscustomobject]@{
                Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any'
                PrimaryStatus = 'OK'; EnforcementStatus = $value
            }
        }

        try {
            { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Not -Throw

            $env:VEGA_TEST_ENFORCEMENT = 'Full'
            { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Not -Throw

            $env:VEGA_TEST_ENFORCEMENT = '1,Enforced,Full'
            { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Not -Throw

            $env:VEGA_TEST_ENFORCEMENT = 'Enforced,NotEnforced'
            { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*未被强制执行*'

            $env:VEGA_TEST_ENFORCEMENT = '2'
            { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*未被强制执行*'
        }
        finally {
            Remove-Item Env:VEGA_TEST_ENFORCEMENT -ErrorAction SilentlyContinue
        }
    }

    It '规则 Profile 不覆盖活动接口时用 Set-NetFirewallRule -Profile 补齐并回读' {
        $env:VEGA_TEST_RULE_PROFILE = 'Public'
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{
                Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'
                Profile = $env:VEGA_TEST_RULE_PROFILE
            }
        }
        Mock -ModuleName $script:ModuleName Set-NetFirewallRule {
            param($Name, $Enabled, $Action, $Protocol, $LocalPort, [Alias('Profile')][string]$FwProfile)
            $null = $Name, $Enabled, $Action, $Protocol, $LocalPort
            if ($PesterBoundParameters['Profile'] -eq 'Private') { $env:VEGA_TEST_RULE_PROFILE = 'Private' }
        }

        try {
            { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Not -Throw
            $env:VEGA_TEST_RULE_PROFILE | Should -Be 'Private'
            Should -Invoke -ModuleName $script:ModuleName -CommandName Set-NetFirewallRule -Times 1 -Exactly `
                -ParameterFilter { $PesterBoundParameters['Profile'] -eq 'Private' }
        }
        finally {
            Remove-Item Env:VEGA_TEST_RULE_PROFILE -ErrorAction SilentlyContinue
        }
    }

    It '多个活动接口时补齐 Profile 必须覆盖全部配置' {
        Mock -ModuleName $script:ModuleName Get-NetConnectionProfile {
            @(
                [pscustomobject]@{ InterfaceAlias = 'Ethernet'; NetworkCategory = 'Private' }
                [pscustomobject]@{ InterfaceAlias = 'Wi-Fi'; NetworkCategory = 'Public' }
            )
        }
        $env:VEGA_TEST_RULE_PROFILE = 'Private'
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{
                Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'
                Profile = $env:VEGA_TEST_RULE_PROFILE
            }
        }
        Mock -ModuleName $script:ModuleName Set-NetFirewallRule {
            param($Name, $Enabled, $Action, $Protocol, $LocalPort, [Alias('Profile')][string]$FwProfile)
            $null = $Name, $Enabled, $Action, $Protocol, $LocalPort
            if ($PesterBoundParameters['Profile'] -eq 'Private,Public') { $env:VEGA_TEST_RULE_PROFILE = 'Private,Public' }
        }

        try {
            { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Not -Throw
            Should -Invoke -ModuleName $script:ModuleName -CommandName Set-NetFirewallRule -Times 1 -Exactly `
                -ParameterFilter { $PesterBoundParameters['Profile'] -eq 'Private,Public' }
        }
        finally {
            Remove-Item Env:VEGA_TEST_RULE_PROFILE -ErrorAction SilentlyContinue
        }
    }

    It '补齐后回读仍不覆盖活动接口时抛异常' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{
                Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'
                Profile = 'Public'
            }
        }

        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*未覆盖活动接口*'
    }

    It '规则 Profile 为 Any 时视为覆盖，不再调用 Set 补齐' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{
                Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any'
            }
        }

        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Not -Throw
        Should -Invoke -ModuleName $script:ModuleName -CommandName Set-NetFirewallRule -Times 0 -Exactly `
            -ParameterFilter { -not [string]::IsNullOrWhiteSpace([string]$PesterBoundParameters['Profile']) }
    }

    It '旧系统没有 PrimaryStatus/EnforcementStatus 属性时视为通过' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any' }
        }

        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Not -Throw
    }

    It '回读发现端口没覆盖时抛异常' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter -RemoveParameterType AssociatedNetFirewallRule {
            [pscustomobject]@{ LocalPort = @('47990'); Protocol = 'TCP' }
        }

        { Set-VegaAdminBlockRule -ManagementPorts @(47990, 47991) -Confirm:$false } | Should -Throw '*未覆盖端口 47991*'
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaFirewallRuleByName -Times 0 -Exactly
    }

    It '回读不到端口过滤器时抛异常' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter -RemoveParameterType AssociatedNetFirewallRule { $null }

        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*端口过滤器*'
    }

    It '更新失败时不删除已有阻断，直接抛异常中止安装' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            if ($Name -ne 'Vega-Block-Admin') { return }
            [pscustomobject]@{ Name = 'Vega-Block-Admin'; Enabled = 'True'; Action = 'Block'; Direction = 'Inbound'; Profile = 'Any' }
        }
        Mock -ModuleName $script:ModuleName Set-NetFirewallRule { throw '拒绝访问' }

        { Set-VegaAdminBlockRule -ManagementPorts @(47990) -Confirm:$false } | Should -Throw '*更新管理端口阻断规则*'
        Should -Invoke -ModuleName $script:ModuleName -CommandName Remove-VegaFirewallRuleByName -Times 0 -Exactly
    }
}

Describe 'Set-VegaFirewallRule 回读' {
    BeforeAll {
        $script:ModuleName = 'Vega.Common'
        $module = Get-Module $script:ModuleName
        $stubs = @{
            'Get-NetConnectionProfile'  = {
                [CmdletBinding()]
                param()
            }
            'New-NetFirewallRule'       = {
                [CmdletBinding()]
                param($Name, $DisplayName, $Direction, $Action, $Protocol, $LocalPort,
                    [Alias('Profile')]$FwProfile, $Program, $Enabled, $Description)
                $null = $Name, $DisplayName, $Direction, $Action, $Protocol, $LocalPort,
                $FwProfile, $Program, $Enabled, $Description
            }
            'Get-NetFirewallRule'       = {
                [CmdletBinding()]
                param([string]$Name, [string]$PolicyStore)
                $null = $Name, $PolicyStore
            }
            'Set-NetFirewallRule'       = {
                [CmdletBinding()]
                param([string]$Name, [Alias('Profile')][string]$FwProfile)
                $null = $Name, $FwProfile
            }
            'Get-NetFirewallPortFilter' = {
                [CmdletBinding()]
                param($AssociatedNetFirewallRule)
                $null = $AssociatedNetFirewallRule
            }
        }
        foreach ($stubName in $stubs.Keys) {
            # 过滤器 cmdlet 在 Windows PowerShell 5.1 的动态参数会强转 CimInstance，始终用 stub 覆盖。
            if ($stubName -notlike "*Filter" -and (Get-Command -Name $stubName -ErrorAction SilentlyContinue)) { continue }
            $stubBody = $stubs[$stubName]
            & $module {
                param($name, $body)
                New-Item -Path ("function:script:{0}" -f $name) -Value $body -Force | Out-Null
            } $stubName $stubBody
        }
    }

    BeforeEach {
        Mock -ModuleName $script:ModuleName Get-NetConnectionProfile {
            [pscustomobject]@{ InterfaceAlias = 'Ethernet'; NetworkCategory = 'Private' }
        }
        Mock -ModuleName $script:ModuleName Remove-VegaFirewallRule { 0 }
        Mock -ModuleName $script:ModuleName New-NetFirewallRule { }
    }

    It '创建后回读 ActiveStore，端口覆盖完整才返回' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            [pscustomobject]@{ Name = $Name; Enabled = 'True'; Action = 'Allow'; Profile = 'Any' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter -RemoveParameterType AssociatedNetFirewallRule {
            param($AssociatedNetFirewallRule)
            if ($AssociatedNetFirewallRule.Name -eq 'Vega-Sunshine-TCP') {
                [pscustomobject]@{ LocalPort = @('47984', '47989', '48010') }
            }
            else {
                [pscustomobject]@{ LocalPort = @('47998-48000', '48002', '48010') }
            }
        }

        $created = @(Set-VegaFirewallRule -Program 'C:\Sunshine\sunshine.exe' -Confirm:$false)
        $created | Should -Be @('Vega-Sunshine-TCP', 'Vega-Sunshine-UDP')
        Should -Invoke -ModuleName $script:ModuleName -CommandName Get-NetFirewallRule -Times 2 -Exactly `
            -ParameterFilter { $PolicyStore -eq 'ActiveStore' }
    }

    It '回读端口不全时抛异常，不让调用方继续禁用安装器规则' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            [pscustomobject]@{ Name = $Name; Enabled = 'True'; Action = 'Allow'; Profile = 'Any' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter -RemoveParameterType AssociatedNetFirewallRule {
            [pscustomobject]@{ LocalPort = @('47984') }
        }

        { Set-VegaFirewallRule -Program 'C:\Sunshine\sunshine.exe' -Confirm:$false } | Should -Throw '*未覆盖端口*'
    }

    It '串流规则 Profile 不覆盖活动接口时补齐后回读' {
        $env:VEGA_TEST_RULE_PROFILE = 'Public'
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            [pscustomobject]@{ Name = $Name; Enabled = 'True'; Action = 'Allow'; Profile = $env:VEGA_TEST_RULE_PROFILE }
        }
        Mock -ModuleName $script:ModuleName Set-NetFirewallRule {
            param($Name, [Alias('Profile')][string]$FwProfile)
            $null = $Name
            if ($PesterBoundParameters['Profile'] -eq 'Private') { $env:VEGA_TEST_RULE_PROFILE = 'Private' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter -RemoveParameterType AssociatedNetFirewallRule {
            param($AssociatedNetFirewallRule)
            if ($AssociatedNetFirewallRule.Name -eq 'Vega-Sunshine-TCP') {
                [pscustomobject]@{ LocalPort = @('47984', '47989', '48010') }
            }
            else {
                [pscustomobject]@{ LocalPort = @('47998-48000', '48002', '48010') }
            }
        }

        try {
            $created = @(Set-VegaFirewallRule -Program 'C:\Sunshine\sunshine.exe' -Confirm:$false)
            $created | Should -Be @('Vega-Sunshine-TCP', 'Vega-Sunshine-UDP')
            Should -Invoke -ModuleName $script:ModuleName -CommandName Set-NetFirewallRule -Times 1 -Exactly `
                -ParameterFilter { $PesterBoundParameters['Profile'] -eq 'Private' }
        }
        finally {
            Remove-Item Env:VEGA_TEST_RULE_PROFILE -ErrorAction SilentlyContinue
        }
    }

    It '回读 Enabled 不是 True 时抛异常' {
        Mock -ModuleName $script:ModuleName Get-NetFirewallRule {
            param($Name, $PolicyStore)
            $null = $PolicyStore
            [pscustomobject]@{ Name = $Name; Enabled = 'False'; Action = 'Allow'; Profile = 'Any' }
        }
        Mock -ModuleName $script:ModuleName Get-NetFirewallPortFilter -RemoveParameterType AssociatedNetFirewallRule {
            [pscustomobject]@{ LocalPort = @('Any') }
        }

        { Set-VegaFirewallRule -Program 'C:\Sunshine\sunshine.exe' -Confirm:$false } | Should -Throw '*状态异常*'
    }
}

Describe 'Protect-VegaSunshineManagementPort' {
    BeforeAll {
        $script:ModuleName = 'Vega.Common'
        $script:sunshineExe = Join-Path $TestDrive 'sunshine.exe'
        $null = New-Item -ItemType File -Path $script:sunshineExe -Force
    }

    It '禁用成功时把规则记进清单' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstallerFirewallRule {
            @([pscustomobject]@{ Name = 'Sunshine'; DisplayName = 'Sunshine'; Enabled = 'True'; Program = 'sunshine.exe'; LocalPort = @('Any') })
        }
        Mock -ModuleName $script:ModuleName Disable-VegaSunshineInstallerFirewallRule { @('Sunshine') }

        $state = Get-VegaEmptyState
        $result = Protect-VegaSunshineManagementPort -State $state -SunshineExe $script:sunshineExe -Confirm:$false

        @($result.DisabledFirewallRules | ForEach-Object { $_.Name }) | Should -Contain 'Sunshine'
    }

    It '禁用失败时抛异常，让安装中止' {
        Mock -ModuleName $script:ModuleName Get-VegaSunshineInstallerFirewallRule {
            @([pscustomobject]@{ Name = 'Sunshine'; DisplayName = 'Sunshine'; Enabled = 'True'; Program = 'sunshine.exe'; LocalPort = @('Any') })
        }
        Mock -ModuleName $script:ModuleName Disable-VegaSunshineInstallerFirewallRule { @() }

        $state = Get-VegaEmptyState
        { Protect-VegaSunshineManagementPort -State $state -SunshineExe $script:sunshineExe -Confirm:$false } |
            Should -Throw '*未能禁用*'
    }
}
