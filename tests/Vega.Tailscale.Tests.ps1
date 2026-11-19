#Requires -Version 5.1
<#
  ConvertFrom-VegaTailscalePing 的单元测试（Pester 5）。
  只解析文本，不调用 tailscale。
#>

BeforeAll {
    $modulePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
    Import-Module $modulePath -Force
}

Describe 'ConvertFrom-VegaTailscalePing' {
    It '直连输出识别为 Direct，并带回端点与延迟' {
        $output = @(
            'pong from vega-host (100.64.0.2) via 203.0.113.7:41641 in 12ms'
        )
        $result = ConvertFrom-VegaTailscalePing -Output $output

        $result.Succeeded | Should -BeTrue
        $result.Mode | Should -Be 'Direct'
        $result.Endpoint | Should -Be '203.0.113.7:41641'
        $result.LatencyMs | Should -Be 12
        $result.PongCount | Should -Be 1
        $result.DirectCount | Should -Be 1
        $result.DerpCount | Should -Be 0
    }

    It 'DERP 中继识别为 Derp，并带出区域' {
        $output = @(
            'pong from vega-host (100.64.0.2) via DERP(hkg) in 40ms'
        )
        $result = ConvertFrom-VegaTailscalePing -Output $output

        $result.Succeeded | Should -BeTrue
        $result.Mode | Should -Be 'Derp'
        $result.Region | Should -Be 'hkg'
        $result.Endpoint | Should -Be 'DERP(hkg)'
        $result.LatencyMs | Should -Be 40
        $result.DerpCount | Should -Be 1
        $result.DirectCount | Should -Be 0
    }

    It '先中继后直连时，以最后一条 pong 为准' {
        $output = @(
            'pong from vega-host (100.64.0.2) via DERP(tok) in 120ms',
            'pong from vega-host (100.64.0.2) via DERP(tok) in 100ms',
            'pong from vega-host (100.64.0.2) via 198.51.100.9:41641 in 28ms'
        )
        $result = ConvertFrom-VegaTailscalePing -Output $output

        $result.Mode | Should -Be 'Direct'
        $result.Endpoint | Should -Be '198.51.100.9:41641'
        $result.PongCount | Should -Be 3
        $result.DirectCount | Should -Be 1
        $result.DerpCount | Should -Be 2
    }

    It '支持小数延迟' {
        $result = ConvertFrom-VegaTailscalePing -Output @(
            'pong from vega-host (100.64.0.2) via 198.51.100.9:41641 in 7.5ms'
        )
        $result.LatencyMs | Should -Be 7.5
    }

    It '没有 pong 时 Succeded 为假，并保留最后一行' {
        $output = @(
            'magicsock: disco: timeout waiting for a relay connection',
            'timeout waiting for a relay connection'
        )
        $result = ConvertFrom-VegaTailscalePing -Output $output

        $result.Succeeded | Should -BeFalse
        $result.Mode | Should -Be 'Unknown'
        $result.PongCount | Should -Be 0
        $result.LastLine | Should -Be 'timeout waiting for a relay connection'
    }

    It '空输入返回未成功的空结果' {
        $result = ConvertFrom-VegaTailscalePing -Output @()

        $result.Succeeded | Should -BeFalse
        $result.PongCount | Should -Be 0
        $result.LastLine | Should -Be ''
    }

    It '忽略空白行与 $null' {
        $output = @('', '   ', $null, 'pong from vega-host (100.64.0.2) via 198.51.100.9:41641 in 9ms')
        $result = ConvertFrom-VegaTailscalePing -Output $output

        $result.PongCount | Should -Be 1
        $result.Mode | Should -Be 'Direct'
    }
}
