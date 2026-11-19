#Requires -Version 5.1
<#
  RustDesk 配置的单元测试（Pester 5）：
    参数/公钥校验、vega.config.json 读取、RustDesk2.toml 合并与按键回滚、
    设备码格式化与 --get-id 解析。
  文件操作只发生在 $TestDrive；外部命令全部 Mock。
#>

BeforeAll {
    $modulePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
    Import-Module $modulePath -Force
    $script:ModuleName = 'Vega.Common'

    $module = Get-Module $script:ModuleName
    $stubs = @{
        'Get-Service' = {
            [CmdletBinding()]
            param([Parameter(Position = 0)][string[]]$Name)
            $null = $Name
        }
    }
    foreach ($stubName in $stubs.Keys) {
        if (Get-Command -Name $stubName -ErrorAction SilentlyContinue) { continue }
        $stubBody = $stubs[$stubName]
        & $module {
            param($name, $body)
            New-Item -Path ("function:script:{0}" -f $name) -Value $body -Force | Out-Null
        } $stubName $stubBody
    }
}

Describe 'Test-VegaRustDeskKey' {
    It '接受 44 字符左右的 base64 样式公钥' {
        Test-VegaRustDeskKey -Key '3q2+7wAAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIII=' | Should -BeTrue
        Test-VegaRustDeskKey -Key ('A' * 43 + '=') | Should -BeTrue
    }

    It '拒绝空值、太短和非法字符' {
        Test-VegaRustDeskKey -Key '' | Should -BeFalse
        Test-VegaRustDeskKey -Key 'short' | Should -BeFalse
        Test-VegaRustDeskKey -Key ('A' * 44 + '-bad') | Should -BeFalse
    }
}

Describe 'ConvertFrom-VegaRustDeskServerEndpoint' {
    It '解析主机名与 IPv4，端口可选' {
        $endpoint = ConvertFrom-VegaRustDeskServerEndpoint -Server 'relay.example.com'
        $endpoint.Host | Should -Be 'relay.example.com'
        $endpoint.Port | Should -Be 0
        $endpoint.Server | Should -Be 'relay.example.com'
        $endpoint.RelayServer | Should -Be 'relay.example.com:21117'

        $endpoint = ConvertFrom-VegaRustDeskServerEndpoint -Server '203.0.113.10:21116'
        $endpoint.Host | Should -Be '203.0.113.10'
        $endpoint.Port | Should -Be 21116
        $endpoint.Server | Should -Be '203.0.113.10:21116'
    }

    It '解析 IPv6（裸地址与方括号加端口）' {
        $endpoint = ConvertFrom-VegaRustDeskServerEndpoint -Server '2001:db8::1'
        $endpoint.IsIpv6 | Should -BeTrue
        $endpoint.Server | Should -Be '2001:db8::1'
        $endpoint.RelayServer | Should -Be '[2001:db8::1]:21117'

        $endpoint = ConvertFrom-VegaRustDeskServerEndpoint -Server '[2001:db8::1]:21116'
        $endpoint.Port | Should -Be 21116
        $endpoint.Server | Should -Be '[2001:db8::1]:21116'
    }

    It '拒绝空值、非法主机名和越界端口' {
        ConvertFrom-VegaRustDeskServerEndpoint -Server '' | Should -BeNullOrEmpty
        ConvertFrom-VegaRustDeskServerEndpoint -Server 'bad host' | Should -BeNullOrEmpty
        ConvertFrom-VegaRustDeskServerEndpoint -Server 'host:70000' | Should -BeNullOrEmpty
        Test-VegaRustDeskServer -Server 'host:70000' | Should -BeFalse
    }
}

Describe 'Resolve-VegaRustDeskSetting' {
    It '参数优先，两个参数必须同时给出' {
        $settings = Resolve-VegaRustDeskSetting -Server 'relay.example.com:21116' -Key ('A' * 43 + '=')
        $settings.Server | Should -Be 'relay.example.com:21116'
        $settings.RelayServer | Should -Be 'relay.example.com:21117'
        $settings.Source | Should -Be 'Parameter'

        { Resolve-VegaRustDeskSetting -Server 'relay.example.com' } | Should -Throw '*同时提供*'
        { Resolve-VegaRustDeskSetting -Key ('A' * 43 + '=') } | Should -Throw '*同时提供*'
    }

    It '参数缺失时读取 vega.config.json' {
        $path = Join-Path $TestDrive 'vega.config.json'
        $json = @{
            rustdesk = @{
                server = 'relay.example.com'
                key    = ('B' * 43 + '=')
            }
        } | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath $path -Value $json -Encoding UTF8

        $settings = Resolve-VegaRustDeskSetting -Server '' -Key '' -ConfigPath $path
        $settings.Server | Should -Be 'relay.example.com'
        $settings.Source | Should -Be 'ConfigFile'
    }

    It '配置文件只有一半时抛异常，两者都没有时返回 null' {
        $path = Join-Path $TestDrive 'half.config.json'
        Set-Content -LiteralPath $path -Value '{"rustdesk":{"server":"relay.example.com"}}' -Encoding UTF8
        { Resolve-VegaRustDeskSetting -ConfigPath $path } | Should -Throw '*必须同时填写*'

        $empty = Join-Path $TestDrive 'empty.config.json'
        Set-Content -LiteralPath $empty -Value '{"rustdesk":{"server":"","key":""}}' -Encoding UTF8
        Resolve-VegaRustDeskSetting -ConfigPath $empty | Should -BeNullOrEmpty

        Resolve-VegaRustDeskSetting -ConfigPath (Join-Path $TestDrive 'missing.json') | Should -BeNullOrEmpty
    }
}

Describe 'Merge-VegaRustDeskConfigText' {
    It '只改 [options] 里的受管键，注释、其他键和其他段原样保留' {
        $existing = @(
            '# 我的注释',
            '[options]',
            'custom-rendezvous-server = "old.example.com"',
            'relay-server = "old.example.com:21117"',
            'key = "oldkey"',
            'allow-remote-config-modification = "Y"',
            '',
            '[other]',
            'key = "not-ours"'
        ) -join "`n"

        $values = [ordered]@{
            'custom-rendezvous-server' = 'new.example.com'
            'relay-server'             = 'new.example.com:21117'
            'key'                      = 'newkey'
        }
        $result = Merge-VegaRustDeskConfigText -ExistingText $existing -Values $values
        $lines = $result -split "`n"

        $lines | Should -Contain '# 我的注释'
        $lines | Should -Contain 'custom-rendezvous-server = "new.example.com"'
        $lines | Should -Contain 'relay-server = "new.example.com:21117"'
        $lines | Should -Contain 'key = "newkey"'
        $lines | Should -Contain 'allow-remote-config-modification = "Y"'
        $lines | Should -Contain '[other]'
        $lines | Should -Contain 'key = "not-ours"'
        ([regex]::Matches($result, '(?m)^key\s*=')).Count | Should -Be 2
    }

    It '没有 [options] 段时新建，缺失键追加到段内' {
        $result = Merge-VegaRustDeskConfigText -ExistingText "[other]`nx = 1" -Values ([ordered]@{ key = 'abc' })
        $lines = $result -split "`n"
        $lines | Should -Contain '[options]'
        $lines | Should -Contain 'key = "abc"'
        $lines | Should -Contain '[other]'
        $lines | Should -Contain 'x = 1'
    }

    It 'RemoveKeys 只删 [options] 里的同名键' {
        $existing = "[options]`nkey = `"abc`"`nother = 1`n[other]`nkey = `"keep`""
        $result = Merge-VegaRustDeskConfigText -ExistingText $existing -Values ([ordered]@{}) -RemoveKeys @('key')
        $lines = $result -split "`n"
        ($lines -ccontains 'key = "keep"') | Should -BeTrue
        ($lines -ccontains 'key = "abc"') | Should -BeFalse
        $lines | Should -Contain 'other = 1'
    }
}

Describe 'Set-VegaRustDeskConfig / Restore-VegaRustDeskConfig' {
    BeforeEach {
        Mock -ModuleName $script:ModuleName Get-Service { $null }
    }

    It '写入当前用户配置，并把三个键的基线记进清单' {
        $path = Join-Path $TestDrive 'user/RustDesk2.toml'
        $statePath = Join-Path $TestDrive 'rustdesk-state.json'
        $state = Get-VegaEmptyState

        $result = Set-VegaRustDeskConfig -Server 'relay.example.com:21116' -Key ('C' * 43 + '=') `
            -State $state -StatePath $statePath -UserConfigPath $path -Confirm:$false

        $result.Applied.Count | Should -Be 1
        $text = Get-Content -LiteralPath $path -Encoding UTF8 -Raw
        $text | Should -Match '(?m)^custom-rendezvous-server = "relay\.example\.com:21116"$'
        $text | Should -Match '(?m)^relay-server = "relay\.example\.com:21117"$'
        $text | Should -Match '(?m)^key = "C+=?"' # 公钥被写进 key，不写密码
        $text | Should -Not -Match 'password'

        $saved = Read-VegaState -Path $statePath
        @($saved.RustDeskConfigKeys).Count | Should -Be 3
        @($saved.RustDeskConfigKeys | ForEach-Object { $_.Key }) | Should -Contain 'custom-rendezvous-server'
        @($saved.RustDeskConfigKeys | ForEach-Object { [bool]$_.Existed }) | Should -Not -Contain $true
    }

    It '重跑不覆盖首次基线，卸载只恢复 Vega 改过的键' {
        $path = Join-Path $TestDrive 'restore/RustDesk2.toml'
        $statePath = Join-Path $TestDrive 'restore-state.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        $original = "[options]`ncustom-rendezvous-server = `"old.example.com`"`nother = `"keep`"`n"
        Set-Content -LiteralPath $path -Value $original -Encoding UTF8 -NoNewline

        $state = Get-VegaEmptyState
        $first = Set-VegaRustDeskConfig -Server 'new.example.com' -Key ('D' * 43 + '=') `
            -State $state -StatePath $statePath -UserConfigPath $path -Confirm:$false
        $state = $first.State

        # 模拟重跑：再次写同一个路径，基线仍应是 old.example.com
        $second = Set-VegaRustDeskConfig -Server 'newer.example.com' -Key ('E' * 43 + '=') `
            -State $state -StatePath $statePath -UserConfigPath $path -Confirm:$false
        $state = $second.State

        $record = @(Get-VegaStateRustDeskKey -State $state -Path $path | Where-Object { $_.Key -eq 'custom-rendezvous-server' })[0]
        $record.OriginalValue | Should -Be 'old.example.com'

        $restore = Restore-VegaRustDeskConfig -Path $path -Records @(Get-VegaStateRustDeskKey -State $state -Path $path) -Confirm:$false
        $restore.Restored | Should -BeTrue

        $text = Get-Content -LiteralPath $path -Encoding UTF8 -Raw
        $text | Should -Match '(?m)^custom-rendezvous-server = "old\.example\.com"$'
        $text | Should -Not -Match 'relay-server'
        $text | Should -Not -Match 'newer\.example\.com'
        $text | Should -Match '(?m)^other = "keep"$'
    }

    It '卸载白名单只认 config\RustDesk2.toml' {
        Test-VegaRustDeskConfigPath -Path (Join-Path $TestDrive 'RustDesk/config/RustDesk2.toml') | Should -BeTrue
        Test-VegaRustDeskConfigPath -Path (Join-Path $TestDrive 'RustDesk/config/other.toml') | Should -BeFalse
        Test-VegaRustDeskConfigPath -Path (Join-Path $TestDrive 'RustDesk2.toml') | Should -BeFalse
    }
}

Describe 'Format-VegaRustDeskId / Get-VegaRustDeskDeviceId' {
    It '9 位设备码按 3-3-3 分组，其他格式原样' {
        Format-VegaRustDeskId -DeviceId '123456789' | Should -Be '123-456-789'
        Format-VegaRustDeskId -DeviceId '123-456-789' | Should -Be '123-456-789'
        Format-VegaRustDeskId -DeviceId '' | Should -Be ''
    }

    It '解析 --get-id 输出' {
        $exe = Join-Path $TestDrive 'rustdesk.exe'
        $null = New-Item -ItemType File -Path $exe -Force

        Mock -ModuleName $script:ModuleName Invoke-VegaCommand {
            [pscustomobject]@{ FilePath = 'rustdesk.exe'; ExitCode = 0; Output = @('123 456 789'); StdOut = @('123 456 789'); StdErr = @(); TimedOut = $false }
        }
        $result = Get-VegaRustDeskDeviceId -Exe $exe
        $result.Success | Should -BeTrue
        $result.DeviceId | Should -Be '123456789'

        Mock -ModuleName $script:ModuleName Invoke-VegaCommand {
            [pscustomobject]@{ FilePath = 'rustdesk.exe'; ExitCode = 1; Output = @('error'); StdOut = @(); StdErr = @('error'); TimedOut = $false }
        }
        $result = Get-VegaRustDeskDeviceId -Exe $exe
        $result.Success | Should -BeFalse
        $result.Error | Should -Match '退出码 1'

        Mock -ModuleName $script:ModuleName Invoke-VegaCommand {
            [pscustomobject]@{ FilePath = 'rustdesk.exe'; ExitCode = -1; Output = @(); StdOut = @(); StdErr = @(); TimedOut = $true }
        }
        $result = Get-VegaRustDeskDeviceId -Exe $exe
        $result.Success | Should -BeFalse
        $result.Error | Should -Match '超时'
    }
}
