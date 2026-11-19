#Requires -Version 5.1
<#
  ConvertTo-VegaArgumentString / Test-VegaAbsolutePath 的单元测试（Pester 5）。
  纯字符串处理，不启动任何进程。
#>

BeforeAll {
    $modulePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
    Import-Module $modulePath -Force
}

Describe 'ConvertTo-VegaArgumentString' {
    It '普通参数按空格拼接' {
        ConvertTo-VegaArgumentString -ArgumentList @('install', '--id', 'LizardByte.Sunshine', '-e') |
            Should -Be 'install --id LizardByte.Sunshine -e'
    }

    It '含空格的参数加双引号' {
        ConvertTo-VegaArgumentString -ArgumentList @('--path', 'C:\Program Files\Sunshine') |
            Should -Be '--path "C:\Program Files\Sunshine"'
    }

    It '空字符串参数保留为 ""，不会丢参数' {
        ConvertTo-VegaArgumentString -ArgumentList @('a', '', 'b') | Should -Be 'a "" b'
        ConvertTo-VegaArgumentString -ArgumentList @('') | Should -Be '""'
        ConvertTo-VegaArgumentString -ArgumentList @('a', $null, 'b') | Should -Be 'a "" b'
    }

    It '参数里的双引号按反斜杠规则转义' {
        ConvertTo-VegaArgumentString -ArgumentList @('say "hi"') |
            Should -Be '"say \"hi\""'
    }

    It '引号前的反斜杠按 2n+1 规则翻倍' {
        $argument = 'a\"b'
        ConvertTo-VegaArgumentString -ArgumentList @($argument) |
            Should -Be '"a\\\"b"'
    }

    It '结尾反斜杠在带引号参数里翻倍，避免吃掉右引号' {
        ConvertTo-VegaArgumentString -ArgumentList @('C:\my dir\') |
            Should -Be '"C:\my dir\\"'
    }

    It '空数组返回空字符串' {
        ConvertTo-VegaArgumentString -ArgumentList @() | Should -Be ''
        ConvertTo-VegaArgumentString -ArgumentList $null | Should -Be ''
    }
}

Describe 'Test-VegaAbsolutePath' {
    It '绝对路径返回 $true' {
        Test-VegaAbsolutePath -Path 'C:\Windows\System32\powercfg.exe' | Should -BeTrue
    }

    It '相对路径与空值返回 $false' {
        Test-VegaAbsolutePath -Path 'powercfg.exe' | Should -BeFalse
        Test-VegaAbsolutePath -Path '.\winget.exe' | Should -BeFalse
        Test-VegaAbsolutePath -Path '' | Should -BeFalse
        Test-VegaAbsolutePath -Path $null | Should -BeFalse
    }
}
