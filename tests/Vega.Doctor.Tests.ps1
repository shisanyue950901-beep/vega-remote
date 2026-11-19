#Requires -Version 5.1
<#
  Get-VegaDoctorAdvice 的单元测试（Pester 5）。
  纯判断逻辑，不访问系统，不调用 tailscale。
#>

BeforeAll {
    $modulePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
    Import-Module $modulePath -Force
}

Describe 'Get-VegaDoctorAdvice' {
    It '显卡正常、规则齐全、有 IPv6 时给编码器建议' {
        $facts = @{
            AdapterName          = 'NVIDIA GeForce RTX 4070'
            Encoder              = 'NVENC'
            SunshineInstalled    = $true
            SunshineRunning      = $true
            MissingFirewallRules = @()
            Ipv6                 = @('2001:db8::1')
            TailscaleInstalled   = $true
            Peer                 = ''
        }
        $advice = @(Get-VegaDoctorAdvice -Facts $facts)

        ($advice -join "`n") | Should -Match 'NVENC'
        ($advice -join "`n") | Should -Not -Match '未检测到 Sunshine'
        ($advice -join "`n") | Should -Not -Match '缺少 .* 条 Vega 防火墙规则'
    }

    It '未安装 Sunshine 时提示运行安装脚本' {
        $advice = @(Get-VegaDoctorAdvice -Facts @{
                SunshineInstalled    = $false
                MissingFirewallRules = @()
                Ipv6                 = @('2001:db8::1')
            })

        ($advice -join "`n") | Should -Match 'install-host\.ps1'
    }

    It '缺少防火墙规则时列出规则名' {
        $advice = @(Get-VegaDoctorAdvice -Facts @{
                SunshineInstalled    = $true
                SunshineRunning      = $true
                Encoder              = 'QSV'
                MissingFirewallRules = @('Vega-Sunshine-TCP', 'Vega-Sunshine-UDP')
                Ipv6                 = @('2001:db8::1')
                TailscaleInstalled   = $true
            })

        $text = $advice -join "`n"
        $text | Should -Match '2 条 Vega 防火墙规则'
        $text | Should -Match 'Vega-Sunshine-TCP'
    }

    It '没有 IPv6 时提示走 Tailscale' {
        $advice = @(Get-VegaDoctorAdvice -Facts @{
                SunshineInstalled    = $true
                SunshineRunning      = $true
                Encoder              = 'NVENC'
                MissingFirewallRules = @()
                Ipv6                 = @()
                TailscaleInstalled   = $true
            })

        ($advice -join "`n") | Should -Match 'IPv6'
        ($advice -join "`n") | Should -Match 'Tailscale'
    }

    It '直连 ping 时给出直连结论与延迟' {
        $ping = ConvertFrom-VegaTailscalePing -Output @(
            'pong from vega-host (100.64.0.2) via 198.51.100.9:41641 in 12ms'
        )
        $advice = @(Get-VegaDoctorAdvice -Facts @{
                SunshineInstalled    = $true
                SunshineRunning      = $true
                Encoder              = 'NVENC'
                MissingFirewallRules = @()
                Ipv6                 = @('2001:db8::1')
                TailscaleInstalled   = $true
                Peer                 = 'vega-host'
                Ping                 = $ping
            })

        $text = $advice -join "`n"
        $text | Should -Match '已直连'
        $text | Should -Match '12ms'
    }

    It 'DERP 中继时给出降低延迟的建议' {
        $ping = ConvertFrom-VegaTailscalePing -Output @(
            'pong from vega-host (100.64.0.2) via DERP(tok) in 120ms'
        )
        $advice = @(Get-VegaDoctorAdvice -Facts @{
                SunshineInstalled    = $true
                SunshineRunning      = $true
                Encoder              = 'AMF'
                MissingFirewallRules = @()
                Ipv6                 = @('2001:db8::1')
                TailscaleInstalled   = $true
                Peer                 = 'vega-host'
                Ping                 = $ping
            })

        $text = $advice -join "`n"
        $text | Should -Match 'DERP'
        $text | Should -Match 'tok'
    }

    It 'ping 没有 pong 时提示检查对端' {
        $ping = ConvertFrom-VegaTailscalePing -Output @('timeout waiting for a relay connection')
        $advice = @(Get-VegaDoctorAdvice -Facts @{
                SunshineInstalled    = $true
                SunshineRunning      = $true
                Encoder              = 'NVENC'
                MissingFirewallRules = @()
                Ipv6                 = @('2001:db8::1')
                TailscaleInstalled   = $true
                Peer                 = 'vega-host'
                Ping                 = $ping
            })

        ($advice -join "`n") | Should -Match '没有收到 pong'
    }

    It '任何事实都没给时也能给出可执行建议且不抛异常' {
        $advice = @(Get-VegaDoctorAdvice -Facts @{})

        $advice.Count | Should -BeGreaterThan 0
        ($advice -join "`n") | Should -Match 'install-host\.ps1'
    }
}
