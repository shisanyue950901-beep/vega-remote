#Requires -Version 5.1
<#
  vega-pwhelper.ps1 的单元测试（Pester 5）。见 docs/ui/console-design-v0.2.md 第 6 节「测试」。
  点源只加载函数、不执行 Main；rustdesk.exe 一律 Mock，载荷文件只落在 $TestDrive，文件名符合生产正则。
  断言重点：载荷名/重解析点/过期/字段校验全部退 10 且不碰 RustDesk、读取函数真正销毁文件、首次调用
  RustDesk 时文件已不存在、`Done!` 缺失与回读不一致分别退 12/13、服务未运行退 12、修改前过期退 10、
  调用超时退 14，以及 stderr 与输出都不含密码。
#>

BeforeAll {
    $helperPath = Join-Path (Join-Path $PSScriptRoot '..') 'console/src-tauri/resources/vega-pwhelper.ps1'
    . $helperPath

    # 接管 stderr：助手只经 $script:EmitError 写出，测试里收进内存再断言。
    $script:captured = New-Object System.Collections.Generic.List[string]
    $script:EmitError = { param([string]$Message) $script:captured.Add($Message) }

    $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [System.DateTimeKind]::Utc)
    $script:now = [int64](([datetime]::UtcNow - $epoch).TotalSeconds)
    $script:alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'

    # 生产文件名：vega-pw-<32 位小写十六进制>.json；写文件后返回路径。
    $script:newPayload = {
        param([hashtable]$Fields, [string]$Name = '')
        if ([string]::IsNullOrEmpty($Name)) { $Name = 'vega-pw-' + [guid]::NewGuid().ToString('n') + '.json' }
        $path = Join-Path $TestDrive $Name
        $json = $Fields | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
        return $path
    }
    $script:newRaw = {
        param([string]$Content, [string]$Name = '')
        if ([string]::IsNullOrEmpty($Name)) { $Name = 'vega-pw-' + [guid]::NewGuid().ToString('n') + '.json' }
        $path = Join-Path $TestDrive $Name
        [System.IO.File]::WriteAllText($path, $Content, [System.Text.UTF8Encoding]::new($false))
        return $path
    }
    $script:baseFields = {
        @{ mode = 'set'; password = 'Secret123'; verification = 'use-permanent-password'; expires = $script:now + 30 }
    }
}

Describe 'Test-VegaPasswordRule' {
    It '8 位含字母和数字通过，允许指定符号' {
        Test-VegaPasswordRule -Password 'abcd1234' | Should -BeNullOrEmpty
        Test-VegaPasswordRule -Password 'A1b2C3d4!#$%&*+,-./:;<=>?@^_~' | Should -BeNullOrEmpty
    }

    It '太短、太长、纯字母、纯数字都拒绝' {
        Test-VegaPasswordRule -Password 'abc1234' | Should -Not -BeNullOrEmpty
        Test-VegaPasswordRule -Password ('a1' * 33) | Should -Not -BeNullOrEmpty
        Test-VegaPasswordRule -Password 'abcdefgh' | Should -Not -BeNullOrEmpty
        Test-VegaPasswordRule -Password '12345678' | Should -Not -BeNullOrEmpty
    }

    It '空格、引号、反斜杠、非 ASCII 都拒绝' {
        foreach ($bad in @('abcd 1234', 'Abcd1234"', 'Abcd\1234', 'Abcd1234密码', "Abcd1234`t")) {
            Test-VegaPasswordRule -Password $bad | Should -Not -BeNullOrEmpty
        }
    }

    It '返回值不回显密码' {
        Test-VegaPasswordRule -Password 'short1' | Should -Not -Match 'short1'
    }
}

Describe 'New-VegaRandomPassword' {
    It '生成 32 位且字符都在字母表内' {
        $password = New-VegaRandomPassword
        $password.Length | Should -Be 32
        @($password.ToCharArray() | Where-Object { $script:alphabet.IndexOf($_) -lt 0 }) | Should -BeNullOrEmpty
        Test-VegaPasswordRule -Password $password | Should -BeNullOrEmpty
    }

    It '两次结果不同' {
        New-VegaRandomPassword | Should -Not -Be (New-VegaRandomPassword)
    }
}

Describe 'Read-VegaPayloadText' {
    It '读出内容并销毁文件' {
        $fields = & $script:baseFields
        $path = & $script:newPayload -Fields $fields

        $text = Read-VegaPayloadText -Path $path

        $text | Should -Match 'Secret123'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It '非法 JSON 也销毁文件' {
        $path = & $script:newRaw -Content 'not json at all'

        Read-VegaPayloadText -Path $path | Should -Be 'not json at all'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It '文件名不合正则时拒绝且不删除' {
        $fields = & $script:baseFields
        $path = & $script:newPayload -Fields $fields -Name ('vega-pw-' + [guid]::NewGuid().ToString('n').Substring(0, 31) + '.json')

        { Read-VegaPayloadText -Path $path } | Should -Throw
        Test-Path -LiteralPath $path | Should -BeTrue
    }

    It '重解析点拒绝打开' {
        $fields = & $script:baseFields
        $path = & $script:newPayload -Fields $fields
        $script:reparsePath = $path
        Mock Get-Item {
            [pscustomobject]@{ PSIsContainer = $false; Attributes = [System.IO.FileAttributes]::ReparsePoint }
        } -ParameterFilter { $LiteralPath -eq $script:reparsePath }

        { Read-VegaPayloadText -Path $path } | Should -Throw
        Test-Path -LiteralPath $path | Should -BeTrue
    }
}

Describe 'Main' {
    BeforeEach {
        $script:captured.Clear()
        $script:calls = New-Object System.Collections.Generic.List[object]
        $script:payloadPath = $null
        $script:firstCallExists = $null
        $script:effective = 'use-permanent-password'
        Mock Get-VegaRustDeskPath { 'C:\Fake\RustDesk\rustdesk.exe' }
        Mock Test-VegaRustDeskService { $true }
        Mock Invoke-VegaRustDesk {
            $script:calls.Add(@($Arguments))
            if ($null -ne $script:payloadPath -and $null -eq $script:firstCallExists) {
                $script:firstCallExists = Test-Path -LiteralPath $script:payloadPath
            }
            if ($Arguments[0] -eq '--password') { return "Done!`r`n" }
            if ($Arguments.Count -ge 3) { return '' }
            return "$($script:effective)`r`n"
        }
    }

    It 'set：设密码、写验证方式、回读一致后成功' {
        $fields = & $script:baseFields
        $script:payloadPath = & $script:newPayload -Fields $fields

        Main -InputFile $script:payloadPath | Should -Be 0

        $script:calls.Count | Should -Be 3
        $script:calls[0][0] | Should -Be '--password'
        $script:calls[0][1] | Should -Be 'Secret123'
        $script:calls[1][0] | Should -Be '--option'
        $script:calls[1][1] | Should -Be 'verification-method'
        $script:calls[1][2] | Should -Be 'use-permanent-password'
        $script:calls[2].Count | Should -Be 2
        Test-Path -LiteralPath $script:payloadPath | Should -BeFalse
        ($script:captured -join "`n") | Should -Not -Match 'Secret123'
    }

    It '首次调用 RustDesk 时载荷文件已不存在' {
        $fields = & $script:baseFields
        $script:payloadPath = & $script:newPayload -Fields $fields

        Main -InputFile $script:payloadPath | Should -Be 0

        $script:firstCallExists | Should -BeFalse
    }

    It 'Done! 缺失时退 12，摘要不含密码' {
        $fields = & $script:baseFields
        $fields.password = 'Sup3rSecret!x'
        $path = & $script:newPayload -Fields $fields
        Mock Invoke-VegaRustDesk { 'rustdesk: refused' }

        Main -InputFile $path | Should -Be 12

        $text = $script:captured -join "`n"
        $text | Should -Match '拒绝修改'
        $text | Should -Not -Match 'Sup3rSecret'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It '验证方式回读不一致时退 13' {
        $fields = & $script:baseFields
        $path = & $script:newPayload -Fields $fields
        Mock Invoke-VegaRustDesk {
            if ($Arguments[0] -eq '--password') { return "Done!`r`n" }
            if ($Arguments.Count -ge 3) { return '' }
            return "use-both-passwords`r`n"
        }

        Main -InputFile $path | Should -Be 13

        ($script:captured -join "`n") | Should -Match '回读不一致'
    }

    It 'clear：生成 32 位随机密码并把验证方式改回临时密码' {
        $fields = & $script:baseFields
        $fields.mode = 'clear'
        $fields.Remove('password')
        $fields.verification = 'use-temporary-password'
        $path = & $script:newPayload -Fields $fields
        $script:effective = 'use-temporary-password'

        Main -InputFile $path | Should -Be 0

        $script:calls.Count | Should -Be 3
        $script:calls[0][0] | Should -Be '--password'
        $script:calls[0][1].Length | Should -Be 32
        @($script:calls[0][1].ToCharArray() | Where-Object { $script:alphabet.IndexOf($_) -lt 0 }) | Should -BeNullOrEmpty
        $script:calls[1][2] | Should -Be 'use-temporary-password'
        ($script:captured -join "`n") | Should -Not -Match ([regex]::Escape($script:calls[0][1]))
    }

    It 'clear 带 password 字段时退 10 且不调用 RustDesk' {
        $fields = & $script:baseFields
        $fields.mode = 'clear'
        $path = & $script:newPayload -Fields $fields

        Main -InputFile $path | Should -Be 10

        Should -Invoke Invoke-VegaRustDesk -Times 0 -Exactly
    }

    It '过期载荷退 10 且不调用 RustDesk' {
        $fields = & $script:baseFields
        $fields.expires = $script:now - 1
        $path = & $script:newPayload -Fields $fields

        Main -InputFile $path | Should -Be 10

        Should -Invoke Invoke-VegaRustDesk -Times 0 -Exactly
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It '文件名不合正则（31 位、大写）退 10' {
        $fields = & $script:baseFields
        $short = & $script:newPayload -Fields $fields -Name ('vega-pw-' + [guid]::NewGuid().ToString('n').Substring(0, 31) + '.json')
        $upper = & $script:newPayload -Fields $fields -Name ('vega-pw-' + [guid]::NewGuid().ToString('n').ToUpper() + '.json')

        Main -InputFile $short | Should -Be 10
        Main -InputFile $upper | Should -Be 10
        Should -Invoke Invoke-VegaRustDesk -Times 0 -Exactly
    }

    It '重解析点退 10 且不调用 RustDesk' {
        $fields = & $script:baseFields
        $path = & $script:newPayload -Fields $fields
        $script:reparsePath = $path
        Mock Get-Item {
            [pscustomobject]@{ PSIsContainer = $false; Attributes = [System.IO.FileAttributes]::ReparsePoint }
        } -ParameterFilter { $LiteralPath -eq $script:reparsePath }

        Main -InputFile $path | Should -Be 10

        Should -Invoke Invoke-VegaRustDesk -Times 0 -Exactly
    }

    It '字段不合格一律退 10 且不调用 RustDesk' {
        $bad = @(
            @{ verification = 'use-permanent-password'; expires = $script:now + 30 },
            @{ mode = 'reset'; password = 'Secret123'; verification = 'use-permanent-password'; expires = $script:now + 30 },
            @{ mode = 'set'; password = 'Secret123'; verification = 'use-anything'; expires = $script:now + 30 },
            @{ mode = 'set'; verification = 'use-permanent-password'; expires = $script:now + 30 },
            @{ mode = 'set'; password = 'short1'; verification = 'use-permanent-password'; expires = $script:now + 30 },
            @{ mode = 'set'; password = 'Abcd1234"'; verification = 'use-permanent-password'; expires = $script:now + 30 }
        )
        foreach ($fields in $bad) {
            $path = & $script:newPayload -Fields $fields
            Main -InputFile $path | Should -Be 10
        }

        Should -Invoke Invoke-VegaRustDesk -Times 0 -Exactly
    }

    It '载荷缺失或无法读取时退 10' {
        Main -InputFile '' | Should -Be 10
        Main -InputFile (Join-Path $TestDrive 'vega-pw-00000000000000000000000000000000.json') | Should -Be 10
        Should -Invoke Invoke-VegaRustDesk -Times 0 -Exactly
    }

    It '找不到 rustdesk.exe 时退 11' {
        $fields = & $script:baseFields
        $path = & $script:newPayload -Fields $fields
        Mock Get-VegaRustDeskPath { $null }

        Main -InputFile $path | Should -Be 11

        Should -Invoke Invoke-VegaRustDesk -Times 0 -Exactly
    }

    It 'RustDesk 服务未运行时退 12 且不调用 RustDesk' {
        $fields = & $script:baseFields
        $path = & $script:newPayload -Fields $fields
        Mock Test-VegaRustDeskService { $false }

        Main -InputFile $path | Should -Be 12

        Should -Invoke Invoke-VegaRustDesk -Times 0 -Exactly
        ($script:captured -join "`n") | Should -Match '服务未运行'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It '解析后到期时，修改 RustDesk 之前退 10' {
        $fields = & $script:baseFields
        $path = & $script:newPayload -Fields $fields
        # 第一次取时间是解析载荷，第二次已是复查：模拟等待 UAC 耗掉 30 秒。
        $script:clockCalls = 0
        Mock Get-VegaEpochSeconds {
            $script:clockCalls++
            if ($script:clockCalls -le 1) { return $script:now }
            return $script:now + 120
        }

        Main -InputFile $path | Should -Be 10

        Should -Invoke Invoke-VegaRustDesk -Times 0 -Exactly
        ($script:captured -join "`n") | Should -Match '过期'
    }

    It '调用 RustDesk 超时退 14，摘要不含密码' {
        $fields = & $script:baseFields
        $fields.password = 'Sup3rSecret!x'
        $path = & $script:newPayload -Fields $fields
        Mock Invoke-VegaRustDesk { throw 'timeout' }

        Main -InputFile $path | Should -Be 14

        $text = $script:captured -join "`n"
        $text | Should -Match '结果未知'
        $text | Should -Not -Match 'Sup3rSecret'
    }
}
