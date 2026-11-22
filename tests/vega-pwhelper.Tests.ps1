#Requires -Version 5.1
<#
  vega-pwhelper.ps1 的单元测试（Pester 5）。见 docs/ui/console-design-v0.2.md 第 6 节「测试」。
  点源只加载函数、不执行 Main；rustdesk.exe 一律 Mock，载荷文件只落在 $TestDrive。
  断言重点：参数校验、读后删除、密码规则，以及失败摘要里绝不出现密码。
#>

BeforeAll {
    $helperPath = Join-Path (Join-Path $PSScriptRoot '..') 'console/src-tauri/resources/vega-pwhelper.ps1'
    . $helperPath

    # 接管错误输出：助手只经 $script:EmitError 写 stderr，测试里收进内存再断言。
    $script:captured = New-Object System.Collections.Generic.List[string]
    $script:EmitError = { param([string]$Message) $script:captured.Add($Message) }
    $script:newPayload = {
        param([string]$Content)
        $path = Join-Path $TestDrive ('payload-' + [guid]::NewGuid().ToString('n') + '.json')
        Set-Content -LiteralPath $path -Encoding UTF8 -Value $Content -NoNewline
        return $path
    }
}

Describe 'Get-VegaHelperArgError' {
    It '缺少模式时拒绝' {
        Get-VegaHelperArgError -Mode '' -Payload '' | Should -Match 'set 或 clear'
    }

    It '未知模式时拒绝' {
        Get-VegaHelperArgError -Mode 'reset' -Payload 'C:\x.json' | Should -Match 'set 或 clear'
    }

    It 'set 缺少密码文件路径时拒绝' {
        Get-VegaHelperArgError -Mode 'set' -Payload '' | Should -Match '-Payload'
    }

    It 'set 带路径时通过' {
        Get-VegaHelperArgError -Mode 'set' -Payload 'C:\Temp\vega-pw-1.json' | Should -BeNullOrEmpty
    }

    It 'clear 不需要文件路径' {
        Get-VegaHelperArgError -Mode 'clear' -Payload '' | Should -BeNullOrEmpty
    }
}

Describe 'Test-VegaPasswordRule' {
    It '8 位含字母和数字通过' {
        Test-VegaPasswordRule -Password 'abcd1234' | Should -BeNullOrEmpty
        Test-VegaPasswordRule -Password 'A1b2C3d4!@#$' | Should -BeNullOrEmpty
    }

    It '太短或太长都拒绝' {
        Test-VegaPasswordRule -Password 'abc1234' | Should -Match '8~64'
        Test-VegaPasswordRule -Password ('a1' * 33) | Should -Match '8~64'
    }

    It '纯字母或纯数字都拒绝' {
        Test-VegaPasswordRule -Password 'abcdefgh' | Should -Match '字母和数字'
        Test-VegaPasswordRule -Password '12345678' | Should -Match '字母和数字'
    }

    It '控制字符拒绝' {
        Test-VegaPasswordRule -Password "abcd`t1234" | Should -Match '控制字符'
        Test-VegaPasswordRule -Password "abcd1234`n" | Should -Match '控制字符'
    }

    It '错误信息不回显密码' {
        $message = Test-VegaPasswordRule -Password 'short1'
        $message | Should -Not -Match 'short1'
    }
}

Describe 'Remove-VegaPayloadFile' {
    It '覆盖后删除文件' {
        $path = & $script:newPayload -Content '{"password":"Secret123","verification":"use-permanent-password"}'
        Test-Path -LiteralPath $path | Should -BeTrue
        Remove-VegaPayloadFile -Path $path
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It '文件不存在时不抛异常' {
        { Remove-VegaPayloadFile -Path (Join-Path $TestDrive 'missing.json') } | Should -Not -Throw
    }
}

Describe 'Read-VegaPayloadFile' {
    It '读出密码与验证方式，并且文件已删除' {
        $path = & $script:newPayload -Content '{"password":"Secret123","verification":"use-both-passwords"}'

        $record = Read-VegaPayloadFile -Path $path

        $record.Password | Should -Be 'Secret123'
        $record.Verification | Should -Be 'use-both-passwords'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'JSON 非法也删掉文件' {
        $path = & $script:newPayload -Content 'not json at all'

        { Read-VegaPayloadFile -Path $path } | Should -Throw '*合法 JSON*'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It '缺少 password 时抛错且不回显内容' {
        $path = & $script:newPayload -Content '{"verification":"use-permanent-password"}'

        { Read-VegaPayloadFile -Path $path } | Should -Throw '*缺少 password*'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'verification 不在白名单时拒绝' {
        $path = & $script:newPayload -Content '{"password":"Secret123","verification":"use-anything"}'

        { Read-VegaPayloadFile -Path $path } | Should -Throw '*不受支持*'
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}

Describe 'New-VegaRandomPassword' {
    It '生成 32 位且符合密码规则' {
        $password = New-VegaRandomPassword
        $password.Length | Should -Be 32
        Test-VegaPasswordRule -Password $password | Should -BeNullOrEmpty
    }

    It '两次结果不同' {
        New-VegaRandomPassword | Should -Not -Be (New-VegaRandomPassword)
    }
}

Describe 'Main' {
    BeforeEach {
        $script:captured.Clear()
        $script:calls = New-Object System.Collections.Generic.List[object]
        Mock Find-VegaRustDeskExe { 'C:\Fake\RustDesk\rustdesk.exe' }
    }

    It 'set：先 --password 设密码，再 --option 写验证方式，然后删载荷' {
        Mock Invoke-VegaProcess {
            $script:calls.Add(@($FilePath) + $ArgumentList)
            [pscustomobject]@{ ExitCode = 0 }
        }
        $path = & $script:newPayload -Content '{"password":"Secret123","verification":"use-permanent-password"}'

        $code = Main -Mode 'set' -Payload $path

        $code | Should -Be 0
        $script:calls.Count | Should -Be 2
        $script:calls[0][1] | Should -Be '--password'
        $script:calls[0][2] | Should -Be 'Secret123'
        $script:calls[1][1] | Should -Be '--option'
        $script:calls[1][2] | Should -Be 'verification-method'
        $script:calls[1][3] | Should -Be 'use-permanent-password'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'set：密码不合规则不调用 rustdesk.exe' {
        Mock Invoke-VegaProcess { [pscustomobject]@{ ExitCode = 0 } }
        $path = & $script:newPayload -Content '{"password":"short1","verification":"use-permanent-password"}'

        Main -Mode 'set' -Payload $path | Should -Be 4

        Should -Invoke Invoke-VegaProcess -Times 0 -Exactly
        ($script:captured -join "`n") | Should -Match '8~64'
    }

    It 'set：rustdesk.exe 失败时退出码 5，摘要里没有密码' {
        Mock Invoke-VegaProcess { [pscustomobject]@{ ExitCode = 3 } }
        $path = & $script:newPayload -Content '{"password":"Secret123","verification":"use-permanent-password"}'

        Main -Mode 'set' -Payload $path | Should -Be 5

        $text = $script:captured -join "`n"
        $text | Should -Match '退出码 3'
        $text | Should -Not -Match 'Secret123'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'set：--option 被拒时退出码 6' {
        Mock Invoke-VegaProcess {
            if ($ArgumentList[0] -eq '--password') { return [pscustomobject]@{ ExitCode = 0 } }
            [pscustomobject]@{ ExitCode = 1 }
        }
        $path = & $script:newPayload -Content '{"password":"Secret123","verification":"use-permanent-password"}'

        Main -Mode 'set' -Payload $path | Should -Be 6
        ($script:captured -join "`n") | Should -Match 'verification-method'
    }

    It 'clear：设 32 位随机密码并把验证方式改回临时密码' {
        Mock Invoke-VegaProcess {
            $script:calls.Add(@($FilePath) + $ArgumentList)
            [pscustomobject]@{ ExitCode = 0 }
        }

        Main -Mode 'clear' -Payload '' | Should -Be 0

        $script:calls.Count | Should -Be 2
        $script:calls[0][1] | Should -Be '--password'
        $script:calls[0][2].Length | Should -Be 32
        Test-VegaPasswordRule -Password $script:calls[0][2] | Should -BeNullOrEmpty
        $script:calls[1][3] | Should -Be 'use-temporary-password'
    }

    It '找不到 rustdesk.exe 时退出码 3' {
        Mock Find-VegaRustDeskExe { $null }
        Mock Invoke-VegaProcess { [pscustomobject]@{ ExitCode = 0 } }

        Main -Mode 'clear' -Payload '' | Should -Be 3
        Should -Invoke Invoke-VegaProcess -Times 0 -Exactly
    }

    It '参数不合法时退出码 2 且不碰 rustdesk.exe' {
        Mock Invoke-VegaProcess { [pscustomobject]@{ ExitCode = 0 } }

        Main -Mode 'set' -Payload '' | Should -Be 2
        Main -Mode 'nope' -Payload '' | Should -Be 2
        Should -Invoke Invoke-VegaProcess -Times 0 -Exactly
    }
}
