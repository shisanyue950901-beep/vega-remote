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

Describe 'Resolve-VegaRustDeskSetting 脱敏' {
    It '地址格式无效时不回显原值' {
        $secret = 'user:pass@bad host/?token=abc'
        $errorRecord = $null
        try { Resolve-VegaRustDeskSetting -Server $secret -Key ('A' * 43 + '=') }
        catch { $errorRecord = $_ }
        $errorRecord | Should -Not -BeNullOrEmpty
        $errorRecord.Exception.Message | Should -Be 'RustDesk 服务器地址格式无效（应为 主机名/IPv4/IPv6，可带 :端口）。'
        $errorRecord.Exception.Message | Should -Not -Match 'bad host'
        $errorRecord.Exception.Message | Should -Not -Match 'token'
    }
}

Describe 'Get-VegaRustDeskInstall -RequireSigned' {
    BeforeEach {
        $script:OriginalProgramFiles = $env:ProgramFiles
        $script:OriginalProgramFilesX86 = ${env:ProgramFiles(x86)}
        $script:OriginalLocalAppData = $env:LOCALAPPDATA

        $env:ProgramFiles = Join-Path $TestDrive 'PF'
        ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'PF86'
        $env:LOCALAPPDATA = Join-Path $TestDrive 'LAD'

        foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
            $dir = Join-Path $root 'RustDesk'
            $null = New-Item -ItemType Directory -Path $dir -Force
            Set-Content -LiteralPath (Join-Path $dir 'rustdesk.exe') -Value 'stub' -Encoding UTF8
        }
    }

    AfterEach {
        $env:ProgramFiles = $script:OriginalProgramFiles
        ${env:ProgramFiles(x86)} = $script:OriginalProgramFilesX86
        $env:LOCALAPPDATA = $script:OriginalLocalAppData
    }

    It '签名有效时返回 Program Files 下的副本' {
        Mock Test-VegaRustDeskSignatureValid { $true }
        $exe = Get-VegaRustDeskInstall -RequireSigned
        (Split-Path -Leaf (Split-Path -Parent $exe)) | Should -Be 'RustDesk'
        (Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $exe))) | Should -Be 'PF'
    }

    It '签名无效时返回 null，且不回退到 LOCALAPPDATA' {
        Mock Test-VegaRustDeskSignatureValid { $false }
        Get-VegaRustDeskInstall -RequireSigned | Should -BeNullOrEmpty
    }

    It '不提权时仍可使用 LOCALAPPDATA 下的副本' {
        Mock Test-VegaRustDeskSignatureValid { $false }
        Remove-Item -LiteralPath (Join-Path (Join-Path $env:ProgramFiles 'RustDesk') 'rustdesk.exe') -Force
        Remove-Item -LiteralPath (Join-Path (Join-Path ${env:ProgramFiles(x86)} 'RustDesk') 'rustdesk.exe') -Force

        $exe = Get-VegaRustDeskInstall
        $exe | Should -Match 'LAD'
    }
}

Describe 'Invoke-VegaRustDeskSetup 提权设备码' {
    BeforeEach {
        Mock Set-VegaRustDeskConfig {
            [pscustomobject]@{ Applied = @(); Warnings = @(); ServicePresent = $false; Values = @{}; State = $null }
        }
        Mock Restart-VegaRustDeskService {
            [pscustomobject]@{ Found = $false; Restarted = $false; Status = ''; Message = '未找到 RustDesk 服务，跳过重启' }
        }
        Mock Write-VegaStatus { }
    }

    It '提权时只启动签名有效的 Program Files 副本' {
        Mock Test-VegaProcessElevated { $true }
        Mock Get-VegaRustDeskInstall { 'C:\Program Files\RustDesk\rustdesk.exe' }
        Mock Get-VegaRustDeskDeviceId { [pscustomobject]@{ Success = $true; DeviceId = '123456789'; RawOutput = @(); Error = '' } }

        $result = Invoke-VegaRustDeskSetup -Settings ([pscustomobject]@{ Server = 'relay.example.com'; RelayServer = 'relay.example.com:21117'; Key = ('A' * 43 + '=') })

        Should -Invoke Get-VegaRustDeskInstall -Times 1 -Exactly -ParameterFilter { $RequireSigned -eq $true }
        Should -Invoke Get-VegaRustDeskDeviceId -Times 1 -Exactly -ParameterFilter {
            $Exe -eq 'C:\Program Files\RustDesk\rustdesk.exe'
        }
        $result.DeviceId | Should -Be '123456789'
    }

    It '提权但没有签名有效的副本时不启动，提示打开 RustDesk 查看设备码' {
        Mock Test-VegaProcessElevated { $true }
        Mock Get-VegaRustDeskInstall { $null }
        Mock Get-VegaRustDeskDeviceId { throw '不应调用' }

        $result = Invoke-VegaRustDeskSetup -Settings ([pscustomobject]@{ Server = 'relay.example.com'; RelayServer = 'relay.example.com:21117'; Key = ('A' * 43 + '=') })

        Should -Invoke Get-VegaRustDeskDeviceId -Times 0 -Exactly
        ($result.Warnings -join "`n") | Should -Match '打开 RustDesk 查看设备码'
    }

    It '未提权时仍按普通查找读取设备码' {
        Mock Test-VegaProcessElevated { $false }
        Mock Get-VegaRustDeskDeviceId { [pscustomobject]@{ Success = $true; DeviceId = '987654321'; RawOutput = @(); Error = '' } }

        $result = Invoke-VegaRustDeskSetup -Settings ([pscustomobject]@{ Server = 'relay.example.com'; RelayServer = 'relay.example.com:21117'; Key = ('A' * 43 + '=') })

        Should -Invoke Get-VegaRustDeskDeviceId -Times 1 -Exactly
        $result.DeviceId | Should -Be '987654321'
    }
}

Describe 'Merge-VegaRustDeskConfigText 大小写、注释与换行保真' {
    It '表头带行尾注释仍识别，CRLF 与行尾注释、尾部空行原样保留' {
        $existing = "[options]  # 默认段`r`ncustom-rendezvous-server = `"old.example.com`"  # 中继地址`r`nkey = `"oldkey`"`r`n`r`n"
        $result = Merge-VegaRustDeskConfigText -ExistingText $existing -Values ([ordered]@{
                'custom-rendezvous-server' = 'new.example.com'
            })

        $result | Should -Match '(?m)^\[options\]  # 默认段$'
        $result | Should -Match '(?m)^custom-rendezvous-server = "new\.example\.com"  # 中继地址$'
        $result | Should -Match '(?m)^key = "oldkey"$'
        $result | Should -Match "`r`n`r`n$"
        $result.Contains("`n`n") | Should -BeTrue
        $result.Contains("`r`n") | Should -BeTrue
    }

    It '表头与键名按精确大小写匹配：[Options]/Key 不受管' {
        $existing = "[Options]`nKey = `"keep`"`n[options]`nkey = `"old`"`n"
        # PowerShell 的哈希字面量键不分大小写，'Key' 与 'key' 放进同一个 @{} 会解析报错；
        # 这里用 Ordinal 比较器的字典，才能同时表达只有大小写不同的两个键。
        $values = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        $values.Add('Key', 'NEW')
        $values.Add('key', 'new')
        $result = Merge-VegaRustDeskConfigText -ExistingText $existing -Values $values

        $result | Should -Match '(?m)^\[Options\]$'
        $result | Should -Match '(?m)^Key = "keep"$'
        $result | Should -Match '(?m)^key = "new"$'
        # 找不到精确的 [options] 时不会把 [Options] 当受管段，但仍会识别真正的 [options]
        ([regex]::Matches($result, '(?m)^\[options\]$')).Count | Should -Be 1
    }

    It '没有 [options] 段时在文件末尾追加' {
        $existing = "[other]`nx = 1"
        $result = Merge-VegaRustDeskConfigText -ExistingText $existing -Values ([ordered]@{ key = 'abc' })
        $result | Should -Match '(?m)^\[other\]\r?\nx = 1\r?\n\r?\n\[options\]\r?\nkey = "abc"$'
    }

    It '读取键值时不把行尾注释读进值' {
        $values = ConvertFrom-VegaRustDeskConfigText -Text "[options]`nkey = `"abc`"  # 注释`ncustom-rendezvous-server = 'host:21116' # 另一个注释`n"
        $values['key'] | Should -Be 'abc'
        $values['custom-rendezvous-server'] | Should -Be 'host:21116'
    }
}

Describe 'RustDesk 配置路径与服务模式清单' {
    It '记录路径必须与预期路径规范化后完全相等，后缀相同不算' {
        $expected = Join-Path $TestDrive 'AppData/RustDesk/config/RustDesk2.toml'
        $lookalike = Join-Path $TestDrive 'evil/RustDesk/config/RustDesk2.toml'

        Test-VegaRustDeskManagedConfigPath -Path $expected -ExpectedPath $expected | Should -BeTrue
        Test-VegaRustDeskManagedConfigPath -Path $lookalike -ExpectedPath $expected | Should -BeFalse
    }

    It '父目录是重解析点时拒绝回滚' {
        $expected = Join-Path $TestDrive 'link/RustDesk/config/RustDesk2.toml'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $expected) -Force
        Mock -ModuleName $script:ModuleName Test-VegaReparsePoint { $true }

        Test-VegaRustDeskManagedConfigPath -Path $expected -ExpectedPath $expected | Should -BeFalse
    }

    It '回滚只恢复三个受管键，其他键忽略并警告' {
        $path = Join-Path $TestDrive 'restore-managed/RustDesk/config/RustDesk2.toml'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        Set-Content -LiteralPath $path -Encoding UTF8 -NoNewline -Value @"
[options]
custom-rendezvous-server = "new.example.com"
password = "should-not-touch"
"@

        $state = Get-VegaEmptyState
        $state.RustDeskConfigKeys = @(
            [pscustomobject]@{ Path = $path; Key = 'custom-rendezvous-server'; Existed = $true; OriginalValue = 'old.example.com'; Restored = $false }
            [pscustomobject]@{ Path = $path; Key = 'password'; Existed = $true; OriginalValue = 'attacker-value'; Restored = $false }
        )
        $statePath = Join-Path $TestDrive 'restore-managed-state.json'

        $result = Restore-VegaRustDeskState -State $state -StatePath $statePath -ExpectedPath $path -Confirm:$false
        $result.Failures.Count | Should -Be 0
        ($result.Messages -join "`n") | Should -Match '忽略清单里的非受管 RustDesk 键：password'

        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $text | Should -Match '(?m)^custom-rendezvous-server = "old\.example\.com"$'
        $text | Should -Match '(?m)^password = "should-not-touch"$'
        $text | Should -Not -Match 'attacker-value'
    }

    It '服务模式记录只写管理员清单，用户清单只保留当前用户路径' {
        $userPath = Join-Path $TestDrive 'svc/user/RustDesk/config/RustDesk2.toml'
        $servicePath = Join-Path $TestDrive 'svc/service/RustDesk2.toml'
        $clientStatePath = Join-Path $TestDrive 'svc/client-state.json'
        $serviceStatePath = Join-Path $TestDrive 'svc/admin/state.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $userPath) -Force

        Mock -ModuleName $script:ModuleName Get-Service {
            [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' }
        }

        $clientState = Get-VegaEmptyState
        $null = Set-VegaRustDeskConfig -Server 'relay.example.com' -Key ('C' * 43 + '=') `
            -State $clientState -StatePath $clientStatePath `
            -UserConfigPath $userPath -ServiceConfigPath $servicePath -ServiceStatePath $serviceStatePath -Confirm:$false

        $savedClient = Read-VegaState -Path $clientStatePath
        $clientPaths = @($savedClient.RustDeskConfigKeys | ForEach-Object { [string]$_.Path } | Select-Object -Unique)
        $clientPaths | Should -Be @($userPath)
        ($clientPaths -contains $servicePath) | Should -BeFalse

        $savedService = Read-VegaState -Path $serviceStatePath
        $servicePaths = @($savedService.RustDeskConfigKeys | ForEach-Object { [string]$_.Path } | Select-Object -Unique)
        $servicePaths | Should -Be @($servicePath)
        $savedService.SchemaVersion | Should -Be 2
    }
}

Describe 'RustDesk 回滚清单只登记实际变化' {
    BeforeEach {
        Mock -ModuleName $script:ModuleName Get-Service { $null }
    }

    It '三个键都已是目标值时不留待回滚记录' {
        $path = Join-Path $TestDrive 'unchanged/RustDesk/config/RustDesk2.toml'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        $key = ('D' * 43 + '=')
        $original = "[options]`ncustom-rendezvous-server = `"relay.example.com:21116`"`nrelay-server = `"relay.example.com:21117`"`nkey = `"$key`"`n"
        Set-Content -LiteralPath $path -Value $original -Encoding UTF8 -NoNewline

        $statePath = Join-Path $TestDrive 'unchanged-state.json'
        $state = Get-VegaEmptyState
        $result = Set-VegaRustDeskConfig -Server 'relay.example.com:21116' -Key $key `
            -State $state -StatePath $statePath -UserConfigPath $path -Confirm:$false

        $result.Applied.Count | Should -Be 1
        @((Read-VegaState -Path $statePath).RustDeskConfigKeys).Count | Should -Be 0
    }

    It '写入失败时不登记任何待回滚记录' {
        $path = Join-Path $TestDrive 'failed/RustDesk/config/RustDesk2.toml'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        $statePath = Join-Path $TestDrive 'failed-state.json'
        Mock -ModuleName $script:ModuleName Write-VegaTextFileAtomic { throw '磁盘已满' }

        $state = Get-VegaEmptyState
        { Set-VegaRustDeskConfig -Server 'relay.example.com' -Key ('E' * 43 + '=') `
                -State $state -StatePath $statePath -UserConfigPath $path -Confirm:$false } |
            Should -Throw '*写入*'
        Test-Path -LiteralPath $statePath | Should -BeFalse
    }

    It '重新安装时 Restored=true 的记录重新采集基线并重置' {
        $path = Join-Path $TestDrive 'reinstall/RustDesk/config/RustDesk2.toml'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        Set-Content -LiteralPath $path -Encoding UTF8 -NoNewline -Value @"
[options]
custom-rendezvous-server = "current.example.com"
"@

        $state = Get-VegaEmptyState
        $state.RustDeskConfigKeys = @(
            [pscustomobject]@{ Path = $path; Key = 'custom-rendezvous-server'; Existed = $true; OriginalValue = 'stale.example.com'; Restored = $true }
        )
        $statePath = Join-Path $TestDrive 'reinstall-state.json'

        $result = Set-VegaRustDeskConfig -Server 'next.example.com' -Key ('F' * 43 + '=') `
            -State $state -StatePath $statePath -UserConfigPath $path -Confirm:$false

        $record = @($result.State.RustDeskConfigKeys | Where-Object { $_.Key -eq 'custom-rendezvous-server' })[0]
        $record.OriginalValue | Should -Be 'current.example.com'
        [bool]$record.Restored | Should -BeFalse
    }
}
