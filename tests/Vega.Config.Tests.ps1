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

    It '只认小写键：PORT / Port 不等同于 port' {
        $text = @(
            'PORT = 48000',
            'Port = 48001',
            'port = 48002'
        ) -join "`n"

        $values = ConvertFrom-VegaSunshineConfigText -Text $text

        $values.Count | Should -Be 1
        $values['port'] | Should -Be '48002'
        $values.Contains('PORT') | Should -BeFalse
        $values.Contains('Port') | Should -BeFalse
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

Describe 'Merge-VegaSunshineConfigText 大小写敏感' {
    It '大写键原样保留，另写一条小写受管键' {
        $existing = "PORT = 48000`nsunshine_name = Old" + "`n"
        $values = [ordered]@{ sunshine_name = 'Vega' }

        $result = Merge-VegaSunshineConfigText -ExistingText $existing -Values $values
        $lines = @($result -split "`n" | Where-Object { $_ -ne '' })

        $lines | Should -Contain 'PORT = 48000'
        $lines | Should -Contain 'sunshine_name = Vega'
    }

    It '只有小写键算作已存在，不会重复追加' {
        $existing = "port = 48000`n"
        $values = [ordered]@{ port = '48000' }

        $result = Merge-VegaSunshineConfigText -ExistingText $existing -Values $values
        @($result -split "`n" | Where-Object { $_ -match '^port\s*=' }).Count | Should -Be 1
    }

    It 'RemoveKeys 不删同名大写键' {
        $existing = "PORT = 48000`nport = 48000`n"
        $result = Merge-VegaSunshineConfigText -ExistingText $existing -Values ([ordered]@{}) -RemoveKeys @('port')
        $lines = @($result -split "`n" | Where-Object { $_ -ne '' })

        $lines | Should -Contain 'PORT = 48000'
        $lines | Should -Not -Contain 'port = 48000'
    }
}

Describe 'Merge-VegaSunshineConfigText -RemoveKeys' {
    It '把指定键整行删除，其他键与注释保留' {
        $existing = @(
            '# 注释',
            'sunshine_name = Vega',
            'address_family = both',
            'port = 48000'
        ) -join "`n"

        $result = Merge-VegaSunshineConfigText -ExistingText $existing -Values ([ordered]@{}) -RemoveKeys @('address_family')
        $lines = $result -split "`n"

        $lines | Should -Contain 'sunshine_name = Vega'
        $lines | Should -Contain 'port = 48000'
        $lines | Should -Contain '# 注释'
        $result | Should -Not -Match 'address_family'
    }

    It '重复出现的待删键全部删除' {
        $existing = "sunshine_name = Vega`naddress_family = both`naddress_family = ipv4"
        $result = Merge-VegaSunshineConfigText -ExistingText $existing -Values ([ordered]@{}) -RemoveKeys @('address_family')
        $result | Should -Not -Match 'address_family'
        $result | Should -Match 'sunshine_name = Vega'
    }
}

Describe 'Set-VegaSunshineConfig' {
    It '写入 UTF-8 无 BOM 内容，不生成 .bak' {
        $path = Join-Path $TestDrive 'sunshine.conf'
        $null = Set-VegaSunshineConfig -Path $path -Content 'adapter_name = test' -Confirm:$false

        (Get-Content -LiteralPath $path -Raw) | Should -Be 'adapter_name = test'
        Test-Path -LiteralPath "$path.bak" | Should -BeFalse

        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes.Length | Should -BeGreaterThan 3
        # UTF-8 BOM 是 EF BB BF，Sunshine 不认 BOM
        $bytes[0] | Should -Not -Be 0xEF
    }

    It '重复写入不覆盖，也不留临时文件' {
        $directory = Join-Path $TestDrive 'atomic'
        $null = New-Item -ItemType Directory -Path $directory
        $path = Join-Path $directory 'sunshine.conf'

        $null = Set-VegaSunshineConfig -Path $path -Content 'a = 1' -Confirm:$false
        $null = Set-VegaSunshineConfig -Path $path -Content 'a = 2' -Confirm:$false

        (Get-Content -LiteralPath $path -Raw) | Should -Be 'a = 2'
        @(Get-ChildItem -LiteralPath $directory -Filter '.vega-tmp-*').Count | Should -Be 0
    }

    It '配置目录不存在时自动创建' {
        $path = Join-Path (Join-Path $TestDrive 'config') 'sunshine.conf'
        $null = Set-VegaSunshineConfig -Path $path -Content 'x' -Confirm:$false

        Test-Path -LiteralPath $path | Should -BeTrue
    }
}

Describe 'Get-VegaConfigKeySnapshot' {
    It '记录受管键原值，缺失的键标记为不存在' {
        $snapshot = Get-VegaConfigKeySnapshot -Text "sunshine_name = OldName`nport = 48000" -Keys @('sunshine_name', 'port', 'address_family')

        $snapshot['sunshine_name'].Existed | Should -BeTrue
        $snapshot['sunshine_name'].Value | Should -Be 'OldName'
        $snapshot['port'].Value | Should -Be '48000'
        $snapshot['address_family'].Existed | Should -BeFalse
        $snapshot['address_family'].Value | Should -Be ''
    }

    It '空配置时所有键都不存在' {
        $snapshot = Get-VegaConfigKeySnapshot -Text '' -Keys @('sunshine_name')
        $snapshot['sunshine_name'].Existed | Should -BeFalse
    }
}

Describe 'Restore-VegaManagedConfig' {
    It '只把受管键恢复为原值，用户后来加的键保留' {
        $path = Join-Path $TestDrive 'keyrestore.conf'
        $original = @(
            '# 用户注释',
            'sunshine_name = OldName',
            'pairing_file = D:\Sunshine\pairs.dat'
        ) -join "`n"
        Set-Content -LiteralPath $path -Value $original -NoNewline

        $snapshot = Get-VegaConfigKeySnapshot -Text $original -Keys @('sunshine_name', 'address_family')
        $installed = Merge-VegaSunshineConfigText -ExistingText $original -Values ([ordered]@{
                sunshine_name  = 'Vega'
                address_family = 'both'
            })
        Set-Content -LiteralPath $path -Value $installed -NoNewline

        # 安装后用户又自己加了一个键
        $userText = $installed + "custom_key = 1`n"
        Set-Content -LiteralPath $path -Value $userText -NoNewline

        $result = Restore-VegaManagedConfig -Path $path -Records @($snapshot['sunshine_name'], $snapshot['address_family']) -Confirm:$false

        $result.Restored | Should -BeTrue
        $result.Changed | Should -BeTrue

        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match '(?m)^sunshine_name = OldName$'
        $text | Should -Not -Match 'address_family'
        $text | Should -Match '(?m)^pairing_file = D:\\Sunshine\\pairs\.dat$'
        $text | Should -Match '(?m)^custom_key = 1$'
        $text | Should -Match '(?m)^# 用户注释$'
        Test-Path -LiteralPath "$path.bak" | Should -BeFalse
    }

    It '受管键本来就是原值时报告未变更' {
        $path = Join-Path $TestDrive 'nochange.conf'
        Set-Content -LiteralPath $path -Value "sunshine_name = OldName`n" -NoNewline

        $snapshot = Get-VegaConfigKeySnapshot -Text "sunshine_name = OldName`n" -Keys @('sunshine_name')
        $result = Restore-VegaManagedConfig -Path $path -Records @($snapshot['sunshine_name']) -Confirm:$false

        $result.Restored | Should -BeTrue
        $result.Changed | Should -BeFalse
        (Get-Content -LiteralPath $path -Raw) | Should -Be "sunshine_name = OldName`n"
    }

    It '配置不存在时返回未回滚' {
        $path = Join-Path $TestDrive 'missing.conf'
        $result = Restore-VegaManagedConfig -Path $path -Records @() -Confirm:$false
        $result.Restored | Should -BeFalse
    }
}
