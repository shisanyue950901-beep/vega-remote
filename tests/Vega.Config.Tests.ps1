#Requires -Version 5.1
<#
  sunshine.conf 模板替换与配置备份/恢复的单元测试（Pester 5）。
  文件操作只发生在 $TestDrive 里，不碰真实 Sunshine 安装目录。
#>

BeforeAll {
    $modulePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
    Import-Module $modulePath -Force
    $script:TemplatePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/sunshine.conf'
}

Describe 'Resolve-VegaSunshineConfig' {
    It '替换 __ADAPTER__ 与 __ENCODER__' {
        $template = "adapter_name = __ADAPTER__`nencoder = __ENCODER__"
        $result = Resolve-VegaSunshineConfig -Template $template -AdapterName 'NVIDIA GeForce RTX 4070' -Encoder 'nvenc'

        $result | Should -Be "adapter_name = NVIDIA GeForce RTX 4070`nencoder = nvenc"
    }

    It '替换所有出现的位置' {
        $template = '__ADAPTER__ / __ADAPTER__ / __ENCODER__'
        Resolve-VegaSunshineConfig -Template $template -AdapterName 'AMD Radeon RX 6800' -Encoder 'amdvce' |
            Should -Be 'AMD Radeon RX 6800 / AMD Radeon RX 6800 / amdvce'
    }

    It '按字面替换，显卡名里的 $ 与反斜杠原样保留' {
        $template = 'adapter_name = __ADAPTER__'
        Resolve-VegaSunshineConfig -Template $template -AdapterName 'NVIDIA $1 \ RTX $& 4070' -Encoder 'nvenc' |
            Should -BeExactly 'adapter_name = NVIDIA $1 \ RTX $& 4070'
    }

    It '模板里没有占位符时原样返回' {
        $template = "sunshine_name = Vega`nhevc_mode = 0"
        Resolve-VegaSunshineConfig -Template $template -AdapterName 'NVIDIA GeForce RTX 4070' -Encoder 'nvenc' |
            Should -BeExactly $template
    }

    It '空显卡名与空编码器把占位符替换成空串' {
        Resolve-VegaSunshineConfig -Template 'a=__ADAPTER__;e=__ENCODER__' -AdapterName '' -Encoder '' |
            Should -Be 'a=;e='
        Resolve-VegaSunshineConfig -Template 'a=__ADAPTER__;e=__ENCODER__' -AdapterName $null -Encoder $null |
            Should -Be 'a=;e='
    }

    It '仓库里的 sunshine.conf 模板能被完整替换' {
        $template = Get-Content -LiteralPath $script:TemplatePath -Raw
        $result = Resolve-VegaSunshineConfig -Template $template -AdapterName 'NVIDIA GeForce RTX 4070' -Encoder 'nvenc'

        $result | Should -Not -Match '__ADAPTER__'
        $result | Should -Not -Match '__ENCODER__'
        $result | Should -Match 'adapter_name = NVIDIA GeForce RTX 4070'
    }
}

Describe 'Set-VegaSunshineConfig' {
    It '首次写入时不备份（原文件不存在），内容为 UTF-8 无 BOM' {
        $path = Join-Path $TestDrive 'sunshine.conf'
        $result = Set-VegaSunshineConfig -Path $path -Content 'adapter_name = test' -Confirm:$false

        $result.BackupCreated | Should -BeFalse
        (Get-Content -LiteralPath $path -Raw) | Should -Be 'adapter_name = test'

        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes.Length | Should -BeGreaterThan 3
        # UTF-8 BOM 是 EF BB BF，Sunshine 不认 BOM
        $bytes[0] | Should -Not -Be 0xEF
    }

    It '原配置存在时备份一次，重复执行不覆盖最初的备份' {
        $path = Join-Path $TestDrive 'sunshine.conf'
        Set-Content -LiteralPath $path -Value 'original' -NoNewline

        $first = Set-VegaSunshineConfig -Path $path -Content 'new' -Confirm:$false
        $first.BackupCreated | Should -BeTrue
        (Get-Content -LiteralPath "$path.bak" -Raw) | Should -Be 'original'
        (Get-Content -LiteralPath $path -Raw) | Should -Be 'new'

        $second = Set-VegaSunshineConfig -Path $path -Content 'newer' -Confirm:$false
        $second.BackupCreated | Should -BeFalse
        (Get-Content -LiteralPath "$path.bak" -Raw) | Should -Be 'original'
        (Get-Content -LiteralPath $path -Raw) | Should -Be 'newer'
    }

    It '-NoBackup 时不生成备份' {
        $path = Join-Path $TestDrive 'nobackup.conf'
        Set-Content -LiteralPath $path -Value 'original' -NoNewline

        $result = Set-VegaSunshineConfig -Path $path -Content 'new' -NoBackup -Confirm:$false

        $result.BackupCreated | Should -BeFalse
        Test-Path -LiteralPath "$path.bak" | Should -BeFalse
    }

    It '配置目录不存在时自动创建' {
        $path = Join-Path (Join-Path $TestDrive 'config') 'sunshine.conf'
        $null = Set-VegaSunshineConfig -Path $path -Content 'x' -Confirm:$false

        Test-Path -LiteralPath $path | Should -BeTrue
    }
}

Describe 'Restore-VegaSunshineConfig' {
    It '从 sunshine.conf.bak 恢复原配置' {
        $path = Join-Path $TestDrive 'restore.conf'
        Set-Content -LiteralPath $path -Value 'original' -NoNewline
        $null = Set-VegaSunshineConfig -Path $path -Content 'modified' -Confirm:$false

        Restore-VegaSunshineConfig -Path $path -Confirm:$false | Should -BeTrue
        (Get-Content -LiteralPath $path -Raw) | Should -Be 'original'
    }

    It '没有备份时返回 $false' {
        $path = Join-Path $TestDrive 'norestore.conf'
        Set-Content -LiteralPath $path -Value 'whatever' -NoNewline

        Restore-VegaSunshineConfig -Path $path -Confirm:$false | Should -BeFalse
    }
}
