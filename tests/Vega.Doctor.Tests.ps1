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

    It '服务没在运行时提示正确的服务名 SunshineService' {
        $advice = @(Get-VegaDoctorAdvice -Facts @{
                SunshineInstalled    = $true
                SunshineRunning      = $false
                Encoder              = 'NVENC'
                MissingFirewallRules = @()
                Ipv6                 = @('2001:db8::1')
                TailscaleInstalled   = $true
            })

        ($advice -join "`n") | Should -Match 'Restart-Service SunshineService'
        ($advice -join "`n") | Should -Not -Match 'Restart-Service sunshine\b'
    }

    It 'Peer Relay 给出非直连的结论' {
        $ping = ConvertFrom-VegaTailscalePing -Output @(
            'pong from vega-host (100.64.0.2) via peer-relay(100.64.0.9:41641) in 30ms'
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
        $text | Should -Match 'Peer Relay'
        $text | Should -Not -Match '已直连'
    }

    It '任何事实都没给时也能给出可执行建议且不抛异常' {
        $advice = @(Get-VegaDoctorAdvice -Facts @{})

        $advice.Count | Should -BeGreaterThan 0
        ($advice -join "`n") | Should -Match 'install-host\.ps1'
    }

    It 'RustDesk2.toml 与配置的服务器不一致时提示重跑安装' {
        $advice = @(Get-VegaDoctorAdvice -Facts @{
                SunshineInstalled    = $true
                SunshineRunning      = $true
                Encoder              = 'NVENC'
                MissingFirewallRules = @()
                Ipv6                 = @('2001:db8::1')
                TailscaleInstalled   = $true
                RustDeskExpectedServer = 'relay.example.com:21116'
                RustDeskTomlServer     = 'old.example.com'
                RustDeskDeviceId       = '123456789'
            })

        $text = $advice -join "`n"
        $text | Should -Match '不一致'
        $text | Should -Match 'old\.example\.com'
        $text | Should -Match 'relay\.example\.com:21116'
    }

    It 'RustDesk 指向正确且能读设备码时不做警告' {
        $advice = @(Get-VegaDoctorAdvice -Facts @{
                SunshineInstalled      = $true
                SunshineRunning        = $true
                Encoder                = 'NVENC'
                MissingFirewallRules   = @()
                Ipv6                   = @('2001:db8::1')
                TailscaleInstalled     = $true
                RustDeskExpectedServer = 'relay.example.com'
                RustDeskTomlServer     = 'relay.example.com'
                RustDeskDeviceId       = '123456789'
            })

        $text = $advice -join "`n"
        $text | Should -Match 'RustDesk 中继配置正确'
        $text | Should -Not -Match '读取不到 RustDesk 设备码'
    }

    It '配置了中继但读不到设备码时给出提示' {
        $advice = @(Get-VegaDoctorAdvice -Facts @{
                SunshineInstalled      = $true
                SunshineRunning        = $true
                Encoder                = 'NVENC'
                MissingFirewallRules   = @()
                Ipv6                   = @('2001:db8::1')
                TailscaleInstalled     = $true
                RustDeskExpectedServer = 'relay.example.com'
                RustDeskTomlServer     = 'relay.example.com'
                RustDeskDeviceId       = ''
            })

        ($advice -join "`n") | Should -Match '读取不到 RustDesk 设备码'
    }
}

Describe 'Get-VegaRustDeskConfigSummary' {
    It '服务存在时同时读取用户配置与 LocalService 配置' {
        $userPath = Join-Path $TestDrive 'user/RustDesk2.toml'
        $servicePath = Join-Path $TestDrive 'service/RustDesk2.toml'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $userPath) -Force
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $servicePath) -Force
        Set-Content -LiteralPath $userPath -Encoding UTF8 -Value "[options]`ncustom-rendezvous-server = `"user.example.com`""
        Set-Content -LiteralPath $servicePath -Encoding UTF8 -Value "[options]`ncustom-rendezvous-server = `"svc.example.com`""

        $summary = Get-VegaRustDeskConfigSummary -UserConfigPath $userPath -ServiceConfigPath $servicePath -ServicePresent

        $summary.UserExists | Should -BeTrue
        $summary.UserServer | Should -Be 'user.example.com'
        $summary.ServiceExists | Should -BeTrue
        $summary.ServiceServer | Should -Be 'svc.example.com'
    }

    It '服务不存在时不读取服务配置' {
        $userPath = Join-Path $TestDrive 'user-only/RustDesk2.toml'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $userPath) -Force
        Set-Content -LiteralPath $userPath -Encoding UTF8 -Value "[options]`ncustom-rendezvous-server = `"user.example.com`""

        $summary = Get-VegaRustDeskConfigSummary -UserConfigPath $userPath -ServiceConfigPath (Join-Path $TestDrive 'missing.toml')

        $summary.ServiceExists | Should -BeFalse
        $summary.ServiceServer | Should -Be ''
    }

    It 'vega-doctor 脚本在服务存在时报告两份配置' {
        $scriptText = Get-Content -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') 'tools/vega-doctor.ps1') -Raw -Encoding UTF8
        $scriptText | Should -Match 'Get-VegaRustDeskConfigSummary'
        $scriptText | Should -Match '用户配置'
        $scriptText | Should -Match '服务配置'
        $scriptText | Should -Match 'RustDeskServicePresent'
    }
}

Describe 'Get-VegaDoctorAdvice 服务模式优先' {
    It '用户配置正确但服务配置不一致时仍报不一致' {
        $advice = @(Get-VegaDoctorAdvice -Facts @{
                SunshineInstalled      = $true
                SunshineRunning        = $true
                Encoder                = 'NVENC'
                MissingFirewallRules   = @()
                Ipv6                   = @('2001:db8::1')
                TailscaleInstalled     = $true
                RustDeskExpectedServer = 'relay.example.com'
                RustDeskTomlServer     = 'relay.example.com'
                RustDeskServiceServer  = 'old.example.com'
                RustDeskServicePresent = $true
                RustDeskDeviceId       = '123456789'
            })

        $text = $advice -join "`n"
        $text | Should -Match '不一致'
        $text | Should -Match '服务配置'
        $text | Should -Not -Match 'RustDesk 中继配置正确'
    }

    It '服务配置与期望一致时判定正确，即使用户配置不同' {
        $advice = @(Get-VegaDoctorAdvice -Facts @{
                SunshineInstalled      = $true
                SunshineRunning        = $true
                Encoder                = 'NVENC'
                MissingFirewallRules   = @()
                Ipv6                   = @('2001:db8::1')
                TailscaleInstalled     = $true
                RustDeskExpectedServer = 'relay.example.com'
                RustDeskTomlServer     = 'user-only.example.com'
                RustDeskServiceServer  = 'relay.example.com'
                RustDeskServicePresent = $true
                RustDeskDeviceId       = '123456789'
            })

        $text = $advice -join "`n"
        $text | Should -Match 'RustDesk 中继配置正确'
    }
}
