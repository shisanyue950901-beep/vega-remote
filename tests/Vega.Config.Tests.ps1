#Requires -Version 5.1
<#
  sunshine.conf 解析 / 合并 / 落盘的单元测试（Pester 5）。
  文件操作只发生在 $TestDrive 里，不碰真实 Sunshine 安装目录。
#>

BeforeAll {
    $modulePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
    Import-Module $modulePath -Force
    $script:TemplatePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/sunshine.conf'
    $script:TemplateText = Get-Content -LiteralPath $script:TemplatePath -Raw -Encoding UTF8
}

Describe 'ConvertFrom-VegaSunshineConfigText' {
    It '解析键值、忽略注释与空行' {
        $text = @(
            '# 注释',
            'sunshine_name = Vega',
            '',
            'adapter_name = NVIDIA GeForce RTX 4070',
            '  port = 47989  '
        ) -join "`n"

        $values = ConvertFrom-VegaSunshineConfigText -Text $text

        $values['sunshine_name'] | Should -Be 'Vega'
        $values['adapter_name'] | Should -Be 'NVIDIA GeForce RTX 4070'
        $values['port'] | Should -Be '47989'
        $values.Contains('注释') | Should -BeFalse
    }

    It '同名键以第一次出现为准' {
        $values = ConvertFrom-VegaSunshineConfigText -Text "port = 1`nport = 2"
        $values['port'] | Should -Be '1'
    }

    It '空文本返回空字典' {
        $values = ConvertFrom-VegaSunshineConfigText -Text ''
        $values.Count | Should -Be 0
    }

    It '仓库模板里包含必须由 Vega 管理的键，且不写 encoder' {
        $values = ConvertFrom-VegaSunshineConfigText -Text $script:TemplateText

        $values['sunshine_name'] | Should -Be 'Vega'
        $values['origin_web_ui_allowed'] | Should -Be 'pc'
        $values['address_family'] | Should -Be 'both'
        $values.Contains('adapter_name') | Should -BeTrue
        $values.Contains('dd_configuration_option') | Should -BeTrue
        $values.Contains('dd_resolution_option') | Should -BeTrue
        $values.Contains('dd_refresh_rate_option') | Should -BeTrue
        $values.Contains('dd_config_revert_delay') | Should -BeTrue
        $values.Contains('encoder') | Should -BeFalse
    }
}

Describe 'Merge-VegaSunshineConfigText' {
    It '只替换受管键，保留用户自己加的键与注释' {
        $existing = @(
            '# 我的注释',
            'port = 48000',
            'pairing_file = D:\Sunshine\state\pairs.dat',
            'sunshine_name = OldName',
            'credentials_file = C:\secret\creds.json',
            'dd_resolution_option = manual'
        ) -join "`n"

        $values = [ordered]@{
            sunshine_name         = 'Vega'
            dd_resolution_option  = 'auto'
            address_family        = 'both'
        }

        $result = Merge-VegaSunshineConfigText -ExistingText $existing -Values $values
        $lines = $result -split "`n"

        $lines | Should -Contain 'sunshine_name = Vega'
        $lines | Should -Contain 'dd_resolution_option = auto'
        $lines | Should -Contain 'address_family = both'
        $lines | Should -Contain 'port = 48000'
        $lines | Should -Contain 'pairing_file = D:\Sunshine\state\pairs.dat'
        $lines | Should -Contain 'credentials_file = C:\secret\creds.json'
        $lines | Should -Contain '# 我的注释'
        $result | Should -Not -Match 'OldName'
        $result | Should -Match "`n$"
    }

    It '重复的受管键只保留第一条，不产生冲突值' {
        $existing = "port = 1`ndd_resolution_option = manual`ndd_resolution_option = 720p"
        $result = Merge-VegaSunshineConfigText -ExistingText $existing -Values ([ordered]@{ dd_resolution_option = 'auto' })

        $occurrences = ([regex]::Matches($result, 'dd_resolution_option')).Count
        $occurrences | Should -Be 1
        $result | Should -Match 'dd_resolution_option = auto'
        $result | Should -Not -Match '720p'
    }

    It '缺失的受管键追加到末尾' {
        $result = Merge-VegaSunshineConfigText -ExistingText 'port = 47989' -Values ([ordered]@{ address_family = 'both' })
        $result | Should -Match 'port = 47989'
        $result | Should -Match 'address_family = both'
    }

    It '空配置只写受管键' {
        $result = Merge-VegaSunshineConfigText -ExistingText '' -Values ([ordered]@{ sunshine_name = 'Vega' })
        # 受管键前面会有一行注释，^ 需要多行模式才匹配得到
        $result | Should -Match '(?m)^sunshine_name = Vega$'
        ([regex]::Matches($result, '(?m)^sunshine_name\s*=')).Count | Should -Be 1
    }
}

Describe 'Set-VegaSunshineConfig' {
    It '首次写入不备份（原文件不存在），内容为 UTF-8 无 BOM' {
        $path = Join-Path $TestDrive 'sunshine.conf'
        $result = Set-VegaSunshineConfig -Path $path -Content 'adapter_name = test' -Confirm:$false

        $result.BackupCreated | Should -BeFalse
        $result.OriginalExisted | Should -BeFalse
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
        $first.OriginalExisted | Should -BeTrue
        (Get-Content -LiteralPath "$path.bak" -Raw) | Should -Be 'original'
        (Get-Content -LiteralPath $path -Raw) | Should -Be 'new'

        $second = Set-VegaSunshineConfig -Path $path -Content 'newer' -Confirm:$false
        $second.BackupCreated | Should -BeFalse
        (Get-Content -LiteralPath "$path.bak" -Raw) | Should -Be 'original'
        (Get-Content -LiteralPath $path -Raw) | Should -Be 'newer'
    }

    It '写入后不留临时文件' {
        $directory = Join-Path $TestDrive 'atomic'
        $null = New-Item -ItemType Directory -Path $directory
        $path = Join-Path $directory 'sunshine.conf'

        $null = Set-VegaSunshineConfig -Path $path -Content 'a = 1' -Confirm:$false
        $null = Set-VegaSunshineConfig -Path $path -Content 'a = 2' -Confirm:$false

        @(Get-ChildItem -LiteralPath $directory -Filter '.vega-tmp-*').Count | Should -Be 0
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
    It '哈希一致时从备份恢复原配置' {
        $path = Join-Path $TestDrive 'restore.conf'
        Set-Content -LiteralPath $path -Value 'original' -NoNewline
        $written = Set-VegaSunshineConfig -Path $path -Content 'modified' -Confirm:$false

        $result = Restore-VegaSunshineConfig -Path $path -ExpectedSha256 $written.Sha256 -Confirm:$false

        $result.Restored | Should -BeTrue
        $result.Conflict | Should -BeFalse
        (Get-Content -LiteralPath $path -Raw) | Should -Be 'original'
    }

    It '配置被用户改过时报告冲突且不覆盖' {
        $path = Join-Path $TestDrive 'conflict.conf'
        Set-Content -LiteralPath $path -Value 'original' -NoNewline
        $written = Set-VegaSunshineConfig -Path $path -Content 'managed' -Confirm:$false
        Set-Content -LiteralPath $path -Value 'user changed this' -NoNewline

        $result = Restore-VegaSunshineConfig -Path $path -ExpectedSha256 $written.Sha256 -Confirm:$false

        $result.Restored | Should -BeFalse
        $result.Conflict | Should -BeTrue
        (Get-Content -LiteralPath $path -Raw) | Should -Be 'user changed this'
        Test-Path -LiteralPath "$path.bak" | Should -BeTrue
    }

    It '原配置本来不存在时，删除 Vega 新建的配置文件' {
        $path = Join-Path $TestDrive 'created.conf'
        $written = Set-VegaSunshineConfig -Path $path -Content 'managed' -Confirm:$false

        $result = Restore-VegaSunshineConfig -Path $path -ExpectedSha256 $written.Sha256 -DeleteIfCreated -Confirm:$false

        $result.Restored | Should -BeTrue
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It '没有备份时返回未恢复且不冲突' {
        $path = Join-Path $TestDrive 'norestore.conf'
        Set-Content -LiteralPath $path -Value 'whatever' -NoNewline

        $result = Restore-VegaSunshineConfig -Path $path -Confirm:$false

        $result.Restored | Should -BeFalse
        $result.Conflict | Should -BeFalse
    }
}
