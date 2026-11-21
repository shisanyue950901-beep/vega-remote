#Requires -Version 5.1
<#
  T3 安装包脚本的单元测试（Pester 5）：
    默认中继配置解析、官方 Release 下载与 SHA256 校验、静默安装调用、
    已安装跳过、配置写两处路径、state.json 安装记录、回滚。
  所有下载/安装/服务/配置写入的外部动作都 Mock，文件只落在 $TestDrive。
#>

BeforeAll {
    $modulePath = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
    Import-Module $modulePath -Force
    $script:ModuleName = 'Vega.Common'
    $script:Key = ('C' * 43 + '=')

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

Describe 'Get-VegaRustDeskDefaultConfig' {
    It '读取 idServer / relayServer / key' {
        $path = Join-Path $TestDrive 'defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = 'relay.example.com'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $path -Value $json -Encoding UTF8

        $defaults = Get-VegaRustDeskDefaultConfig -Path $path
        $defaults.IdServer | Should -Be '60.205.95.98'
        $defaults.RelayServer | Should -Be 'relay.example.com'
        $defaults.Key | Should -Be $script:Key
    }

    It '缺文件、坏 JSON、缺 key 都抛错' {
        { Get-VegaRustDeskDefaultConfig -Path (Join-Path $TestDrive 'missing.json') } | Should -Throw '*缺少默认配置*'

        $bad = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $bad -Value '{ not json' -Encoding UTF8
        { Get-VegaRustDeskDefaultConfig -Path $bad } | Should -Throw '*不是合法 JSON*'

        $noKey = Join-Path $TestDrive 'nokey.json'
        Set-Content -LiteralPath $noKey -Value '{"rustdesk":{"idServer":"1.2.3.4","relayServer":"1.2.3.4"}}' -Encoding UTF8
        { Get-VegaRustDeskDefaultConfig -Path $noKey } | Should -Throw '*key*'
    }
}

Describe 'Get-VegaRustDeskRelease' {
    It '固定官方 GitHub Release，SHA256 是待填的 64 位常量' {
        $release = Get-VegaRustDeskRelease
        $release.Url | Should -Match '^https://github\.com/rustdesk/rustdesk/releases/download/'
        $release.Url | Should -Match ([regex]::Escape($release.Version))
        $release.FileName | Should -Match 'x86_64\.exe$'
        $release.Sha256 | Should -Match '^[0-9a-f]{64}$'
        $release.Page | Should -Be 'https://rustdesk.com/download'
    }
}

Describe 'Get-VegaRustDeskInstaller' {
    BeforeEach {
        $script:release = [pscustomobject]@{
            Version  = '1.3.9'
            FileName = 'rustdesk-1.3.9-x86_64.exe'
            Url      = 'https://example.invalid/rustdesk.exe'
            Sha256   = ('a' * 64)
            Page     = 'https://rustdesk.com/download'
        }
        $script:downloadDir = Join-Path $TestDrive ('download-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:downloadDir -Force
    }

    It 'SHA256 不匹配立即中止并删除文件' {
        Mock -ModuleName $script:ModuleName Invoke-VegaHttpsDownload {
            param($Uri, $OutFile, $TimeoutSeconds, $Deadline)
            Set-Content -LiteralPath $OutFile -Value 'not-the-real-installer' -Encoding UTF8
        }
        Mock -ModuleName $script:ModuleName Get-FileHash {
            [pscustomobject]@{ Hash = ('b' * 64).ToUpperInvariant() }
        }

        $result = Get-VegaRustDeskInstaller -DestinationDirectory $script:downloadDir -Release $script:release
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'SHA256 不匹配'
        $result.Error | Should -Match 'rustdesk\.com/download'
        Test-Path -LiteralPath (Join-Path $script:downloadDir $script:release.FileName) | Should -BeFalse
        Should -Invoke -CommandName Invoke-VegaHttpsDownload -ModuleName $script:ModuleName -Times 1 -Exactly
    }

    It 'SHA256 仍是占位值时不发起下载' {
        Mock -ModuleName $script:ModuleName Invoke-VegaHttpsDownload { throw '不应被调用' }
        $placeholder = [pscustomobject]@{
            Version  = $script:release.Version
            FileName = $script:release.FileName
            Url      = $script:release.Url
            Sha256   = ('0' * 64)
            Page     = $script:release.Page
        }

        $result = Get-VegaRustDeskInstaller -DestinationDirectory $script:downloadDir -Release $placeholder
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'SHA256 尚未填写'
        Should -Invoke -CommandName Invoke-VegaHttpsDownload -ModuleName $script:ModuleName -Times 0 -Exactly
    }

    It '下载失败最多尝试 2 次并返回非零原因' {
        Mock -ModuleName $script:ModuleName Invoke-VegaHttpsDownload { throw '网络不可用' }

        $result = Get-VegaRustDeskInstaller -DestinationDirectory $script:downloadDir -Release $script:release
        $result.Success | Should -BeFalse
        $result.Error | Should -Match '已尝试 2 次'
        $result.Error | Should -Match 'rustdesk\.com/download'
        Should -Invoke -CommandName Invoke-VegaHttpsDownload -ModuleName $script:ModuleName -Times 2 -Exactly
    }

    It '校验通过返回安装包路径，并保持独占读句柄到启动' {
        Mock -ModuleName $script:ModuleName Invoke-VegaHttpsDownload {
            param($Uri, $OutFile, $TimeoutSeconds, $Deadline)
            Set-Content -LiteralPath $OutFile -Value 'installer' -Encoding UTF8
        }
        Mock -ModuleName $script:ModuleName Get-FileHash {
            [pscustomobject]@{ Hash = ('a' * 64) }
        }

        $result = Get-VegaRustDeskInstaller -DestinationDirectory $script:downloadDir -Release $script:release
        $result.Success | Should -BeTrue
        $result.Path | Should -Be (Join-Path $script:downloadDir $script:release.FileName)
        Test-Path -LiteralPath $result.Path | Should -BeTrue
        $null -eq $result.Lock | Should -BeFalse

        # 句柄期间别人不能再拿写权限打开同一个文件：TOCTOU 的替换窗口被关掉。
        { [System.IO.File]::Open($result.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None) } | Should -Throw

        $result.Lock.Dispose()
        Remove-Item -LiteralPath $result.Path -Force -ErrorAction SilentlyContinue
    }

    It '用真实 SHA256 校验临时文件：匹配通过，不匹配中止' {
        # P2e：不 mock Get-FileHash，用真实临时文件算出摘要，验证校验链路本身。
        $payload = Join-Path $TestDrive ('payload-' + [guid]::NewGuid().ToString('N') + '.bin')
        Set-Content -LiteralPath $payload -Value 'real-installer-bytes' -Encoding UTF8
        $realHash = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
        # mock 体在模块作用域执行，用全局变量把真实临时文件路径带进去。
        $global:VegaTestPayload = $payload

        Mock -ModuleName $script:ModuleName Invoke-VegaHttpsDownload {
            param($Uri, $OutFile, $TimeoutSeconds, $Deadline)
            Copy-Item -LiteralPath $global:VegaTestPayload -Destination $OutFile -Force
        }

        $good = [pscustomobject]@{
            Version  = $script:release.Version
            FileName = 'good-' + $script:release.FileName
            Url      = $script:release.Url
            Sha256   = $realHash
            Page     = $script:release.Page
        }
        $ok = Get-VegaRustDeskInstaller -DestinationDirectory $script:downloadDir -Release $good
        $ok.Success | Should -BeTrue
        $ok.Sha256 | Should -Be $realHash
        $ok.Lock.Dispose()
        Remove-Item -LiteralPath $ok.Path -Force -ErrorAction SilentlyContinue

        $bad = [pscustomobject]@{
            Version  = $script:release.Version
            FileName = 'bad-' + $script:release.FileName
            Url      = $script:release.Url
            Sha256   = ('c' * 64)
            Page     = $script:release.Page
        }
        $mismatch = Get-VegaRustDeskInstaller -DestinationDirectory $script:downloadDir -Release $bad
        $mismatch.Success | Should -BeFalse
        $mismatch.Error | Should -Match 'SHA256 不匹配'
        Test-Path -LiteralPath (Join-Path $script:downloadDir $bad.FileName) | Should -BeFalse
        Remove-Variable -Name VegaTestPayload -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-VegaHttpsDownload' {
    It '只接受 HTTPS，明文重定向在发请求前就被拒绝' {
        $out = Join-Path $TestDrive 'plain.http'
        { Invoke-VegaHttpsDownload -Uri 'http://example.invalid/rustdesk.exe' -OutFile $out -TimeoutSeconds 5 } |
            Should -Throw '*HTTPS*'
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It 'P1-1 截止时间是 DateTime（不是 Nullable），过期后按剩余时间判超时' {
        # 不 mock 时间运算：真的传一个 [datetime] 过去，走剩余时间减法。
        (Get-Command -Name Invoke-VegaHttpsDownload).Parameters['Deadline'].ParameterType.FullName |
            Should -Be ([datetime]).FullName

        $out = Join-Path $TestDrive 'expired.bin'
        $deadline = [datetime]::UtcNow.AddSeconds(-5)
        { Invoke-VegaHttpsDownload -Uri 'https://example.invalid/rustdesk.exe' -OutFile $out -TimeoutSeconds 5 -Deadline $deadline } |
            Should -Throw '*下载超时*'
        Test-Path -LiteralPath $out | Should -BeFalse
    }

    It '下载前补齐 TLS 1.2，不拆掉已启用的其他协议' {
        $before = [System.Net.ServicePointManager]::SecurityProtocol
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::SystemDefault
            Enable-VegaTls12
            $after = [System.Net.ServicePointManager]::SecurityProtocol
            (($after -band [System.Net.SecurityProtocolType]::Tls12) -eq [System.Net.SecurityProtocolType]::Tls12) | Should -BeTrue
        }
        finally {
            [System.Net.ServicePointManager]::SecurityProtocol = $before
        }
    }
}

Describe 'Install-VegaRustDeskSilently' {
    It '调用官方 --silent-install 参数' {
        $installer = Join-Path $TestDrive 'rustdesk.exe'
        Set-Content -LiteralPath $installer -Value 'x' -Encoding UTF8
        Mock -ModuleName $script:ModuleName Invoke-VegaCommand {
            param($FilePath, $ArgumentList, $TimeoutSeconds)
            [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = @() }
        }

        $result = Install-VegaRustDeskSilently -InstallerPath $installer
        $result.Success | Should -BeTrue
        Should -Invoke -CommandName Invoke-VegaCommand -ModuleName $script:ModuleName -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -contains '--silent-install'
        }
    }

    It '非 0 退出码返回失败' {
        $installer = Join-Path $TestDrive 'rustdesk-fail.exe'
        Set-Content -LiteralPath $installer -Value 'x' -Encoding UTF8
        Mock -ModuleName $script:ModuleName Invoke-VegaCommand {
            param($FilePath, $ArgumentList, $TimeoutSeconds)
            [pscustomobject]@{ ExitCode = 5; TimedOut = $false; Output = @() }
        }

        $result = Install-VegaRustDeskSilently -InstallerPath $installer
        $result.Success | Should -BeFalse
        $result.Error | Should -Match '退出码 5'
    }
}

Describe 'Wait-VegaRustDeskService' {
    It 'P1-6 服务注册后仍是 Stopped：有界等待后返回 Running=false' {
        Mock -ModuleName $script:ModuleName Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Stopped' } }

        $result = Wait-VegaRustDeskService -TimeoutSeconds 1 -IntervalSeconds 1
        $result.Found | Should -BeTrue
        $result.Running | Should -BeFalse
        $result.Status | Should -Be 'Stopped'
    }

    It 'P1-6 StartPending 之后变成 Running 时等到 Running' {
        & (Get-Module $script:ModuleName) { $script:VegaWaitCalls = 0 }
        Mock -ModuleName $script:ModuleName Get-Service {
            $script:VegaWaitCalls += 1
            if ($script:VegaWaitCalls -le 1) { [pscustomobject]@{ Name = 'RustDesk'; Status = 'StartPending' } }
            else { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }
        }

        $result = Wait-VegaRustDeskService -TimeoutSeconds 10 -IntervalSeconds 1
        $result.Running | Should -BeTrue
        $result.Status | Should -Be 'Running'
        (& (Get-Module $script:ModuleName) { $script:VegaWaitCalls }) | Should -BeGreaterOrEqual 2
    }
}

Describe 'Invoke-VegaRustDeskBootstrap' {
    BeforeEach {
        $script:statePath = Join-Path $TestDrive ('host-state-' + [guid]::NewGuid().ToString('N') + '.json')
        $script:serviceStatePath = Join-Path $TestDrive ('service-state-' + [guid]::NewGuid().ToString('N') + '.json')
        $script:userConfig = Join-Path $TestDrive ('user-' + [guid]::NewGuid().ToString('N') + '/RustDesk/config/RustDesk2.toml')
        $script:serviceConfig = Join-Path $TestDrive ('service-' + [guid]::NewGuid().ToString('N') + '/RustDesk/config/RustDesk2.toml')
        $script:defaults = Join-Path $TestDrive 'vega-defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = '60.205.95.98'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $script:defaults -Value $json -Encoding UTF8
        $script:downloadDir = Join-Path $TestDrive 'downloads'
        $script:testSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'

        Mock -ModuleName $script:ModuleName Restart-VegaRustDeskService {
            [pscustomobject]@{ Found = $true; WasRunning = $true; Restarted = $true; Status = 'Running'; Message = 'RustDesk 服务已重启' }
        }
        Mock -ModuleName $script:ModuleName Wait-VegaRustDeskService {
            [pscustomobject]@{ Found = $true; Running = $true; Status = 'Running' }
        }
        # P1-3：下载目录的 ACL/所有权检查只在 Windows 真机上有效，这里换成 TestDrive 临时目录。
        Mock -ModuleName $script:ModuleName New-VegaSecureDirectory {
            $dir = Join-Path $TestDrive ('secure-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $dir -Force
            $dir
        }
        Mock -ModuleName $script:ModuleName Remove-VegaSecureDirectory { }
        Mock -ModuleName $script:ModuleName Get-VegaInteractiveUserContext {
            [pscustomobject]@{
                Name           = 'TEST\alice'
                Sid            = $script:testSid
                AppDataPath    = 'C:\Users\alice\AppData\Roaming'
                UserConfigPath = 'C:\Users\alice\AppData\Roaming\RustDesk\config\RustDesk2.toml'
            }
        }
    }

    It '已安装时跳过下载与安装，写用户级与服务级配置并记录 SID' {
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { 'C:\Program Files\RustDesk\rustdesk.exe' }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstaller { throw '已安装时不应下载' }
        Mock -ModuleName $script:ModuleName Install-VegaRustDeskSilently { throw '已安装时不应安装' }
        Mock -ModuleName $script:ModuleName Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $script:defaults -HostStatePath $script:statePath `
            -ServiceStatePath $script:serviceStatePath -UserConfigPath $script:userConfig `
            -ServiceConfigPath $script:serviceConfig -DownloadDirectory $script:downloadDir -Confirm:$false

        $result.Success | Should -BeTrue
        $result.Installed | Should -BeFalse
        $result.Configured | Should -BeTrue
        Should -Invoke -CommandName Get-VegaRustDeskInstaller -ModuleName $script:ModuleName -Times 0 -Exactly
        Should -Invoke -CommandName Install-VegaRustDeskSilently -ModuleName $script:ModuleName -Times 0 -Exactly

        # P1-5：用户级 + 服务级两处都写，且都以写入后的回读为准。
        Test-Path -LiteralPath $script:userConfig | Should -BeTrue
        (Get-Content -LiteralPath $script:userConfig -Raw -Encoding UTF8) | Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'
        (Get-Content -LiteralPath $script:serviceConfig -Raw -Encoding UTF8) | Should -Match 'relay-server = "60\.205\.95\.98:21117"'
        @((Read-VegaState -Path $script:statePath).RustDeskInstalls).Count | Should -Be 0

        $serviceState = Read-VegaState -Path $script:serviceStatePath
        $serviceState.RustDeskUserConfig.Sid | Should -Be $script:testSid
        $serviceState.RustDeskUserConfig.Written | Should -BeTrue
        $serviceState.RustDeskUserConfig.PromptPending | Should -BeFalse
        @($serviceState.RustDeskConfigKeys).Count | Should -Be 3
    }

    It '下载失败返回非零，不写配置' {
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { '' }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstaller {
            [pscustomobject]@{ Success = $false; Path = ''; Sha256 = ''; Lock = $null; Error = '下载失败，请到 https://rustdesk.com/download' }
        }
        Mock -ModuleName $script:ModuleName Get-Service { $null }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $script:defaults -HostStatePath $script:statePath `
            -ServiceStatePath $script:serviceStatePath -UserConfigPath $script:userConfig `
            -ServiceConfigPath $script:serviceConfig -DownloadDirectory $script:downloadDir -Confirm:$false

        $result.Success | Should -BeFalse
        $result.ExitCode | Should -Be 1
        $result.Error | Should -Match 'rustdesk\.com/download'
        Test-Path -LiteralPath $script:userConfig | Should -BeFalse
        Test-Path -LiteralPath $script:serviceConfig | Should -BeFalse
        Test-Path -LiteralPath $script:statePath | Should -BeFalse
        Should -Invoke -CommandName Remove-VegaSecureDirectory -ModuleName $script:ModuleName -Times 1 -Exactly
    }

    It '哈希不匹配中止安装，不启动安装程序' {
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { '' }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstaller {
            [pscustomobject]@{ Success = $false; Path = ''; Sha256 = ('b' * 64); Lock = $null; Error = '下载的 RustDesk 安装包 SHA256 不匹配，已删除并中止。' }
        }
        Mock -ModuleName $script:ModuleName Install-VegaRustDeskSilently { throw '哈希不匹配时不应安装' }
        Mock -ModuleName $script:ModuleName Get-Service { $null }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $script:defaults -HostStatePath $script:statePath `
            -ServiceStatePath $script:serviceStatePath -UserConfigPath $script:userConfig `
            -ServiceConfigPath $script:serviceConfig -DownloadDirectory $script:downloadDir -Confirm:$false

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'SHA256 不匹配'
        Should -Invoke -CommandName Install-VegaRustDeskSilently -ModuleName $script:ModuleName -Times 0 -Exactly
    }

    It '未安装时下载、静默安装、写用户级与服务级配置并记录到 state.json' {
        & (Get-Module $script:ModuleName) { $script:VegaProbeCount = 0 }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall {
            $script:VegaProbeCount += 1
            if ($script:VegaProbeCount -le 1) { '' } else { 'C:\Program Files\RustDesk\rustdesk.exe' }
        }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstaller {
            [pscustomobject]@{ Success = $true; Path = 'C:\temp\rustdesk.exe'; Sha256 = ('a' * 64); Lock = $null; Error = '' }
        }
        Mock -ModuleName $script:ModuleName Install-VegaRustDeskSilently {
            [pscustomobject]@{ Success = $true; ExitCode = 0; Error = '' }
        }
        Mock -ModuleName $script:ModuleName Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $script:defaults -HostStatePath $script:statePath `
            -ServiceStatePath $script:serviceStatePath -UserConfigPath $script:userConfig `
            -ServiceConfigPath $script:serviceConfig -DownloadDirectory $script:downloadDir -Confirm:$false

        $result.Success | Should -BeTrue
        $result.Installed | Should -BeTrue
        Should -Invoke -CommandName Install-VegaRustDeskSilently -ModuleName $script:ModuleName -Times 1 -Exactly

        # P1-5：用户级配置写到交互用户路径，服务级写到 LocalService 路径。
        Test-Path -LiteralPath $script:userConfig | Should -BeTrue
        (Get-Content -LiteralPath $script:userConfig -Raw -Encoding UTF8) | Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'
        (Get-Content -LiteralPath $script:serviceConfig -Raw -Encoding UTF8) | Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'

        $saved = Read-VegaState -Path $script:statePath
        @($saved.RustDeskInstalls).Count | Should -Be 1
        $saved.RustDeskInstalls[0].InstalledByVega | Should -BeTrue
        $saved.RustDeskInstalls[0].Path | Should -Be 'C:\Program Files\RustDesk\rustdesk.exe'

        # P2d：服务清单参数必须转发生效，记录落在传入的 state.json，而不是真实 %ProgramData%。
        $serviceState = Read-VegaState -Path $script:serviceStatePath
        @($serviceState.RustDeskConfigKeys).Count | Should -Be 3
        @($serviceState.RustDeskConfigKeys | ForEach-Object { [string]$_.Path } | Select-Object -Unique) | Should -Contain $script:serviceConfig
        $serviceState.RustDeskUserConfig.Written | Should -BeTrue

        # 用户级基线落在 host-state（与安装记录同一份清单），回滚按 SID 记录的路径校验。
        $hostState = Read-VegaState -Path $script:statePath
        @($hostState.RustDeskConfigKeys | ForEach-Object { [string]$_.Path } | Select-Object -Unique) | Should -Contain $script:userConfig
    }

    It 'P1-5 服务没出现时返回非零，不把失败当成功' {
        & (Get-Module $script:ModuleName) { $script:VegaProbeCount = 0 }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall {
            $script:VegaProbeCount += 1
            if ($script:VegaProbeCount -le 1) { '' } else { 'C:\Program Files\RustDesk\rustdesk.exe' }
        }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstaller {
            [pscustomobject]@{ Success = $true; Path = 'C:\temp\rustdesk.exe'; Sha256 = ('a' * 64); Lock = $null; Error = '' }
        }
        Mock -ModuleName $script:ModuleName Install-VegaRustDeskSilently {
            [pscustomobject]@{ Success = $true; ExitCode = 0; Error = '' }
        }
        Mock -ModuleName $script:ModuleName Wait-VegaRustDeskService { [pscustomobject]@{ Found = $true; Running = $false; Status = 'Stopped' } }
        Mock -ModuleName $script:ModuleName Get-Service { $null }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $script:defaults -HostStatePath $script:statePath `
            -ServiceStatePath $script:serviceStatePath -UserConfigPath $script:userConfig `
            -ServiceConfigPath $script:serviceConfig -DownloadDirectory $script:downloadDir -Confirm:$false

        $result.Success | Should -BeFalse
        $result.ExitCode | Should -Be 1
        $result.Error | Should -Match '服务'
        Test-Path -LiteralPath $script:serviceConfig | Should -BeFalse
    }
}

    It 'P1-5 钩子传来的交互用户 SID + AppData 决定用户级写入路径' {
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { 'C:\Program Files\RustDesk\rustdesk.exe' }
        Mock -ModuleName $script:ModuleName Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Get-VegaInteractiveUserContext { throw '钩子已给参数时不应再解析上下文' }

        $appData = Join-Path $TestDrive ('appdata-' + [guid]::NewGuid().ToString('N'))
        $hookUserConfig = Join-Path $appData 'RustDesk\config\RustDesk2.toml'

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $script:defaults -HostStatePath $script:statePath `
            -ServiceStatePath $script:serviceStatePath -ServiceConfigPath $script:serviceConfig `
            -DownloadDirectory $script:downloadDir -InteractiveUserSid $script:testSid `
            -InteractiveUserAppData $appData -Confirm:$false

        $result.Success | Should -BeTrue
        Test-Path -LiteralPath $hookUserConfig | Should -BeTrue
        (Get-Content -LiteralPath $hookUserConfig -Raw -Encoding UTF8) | Should -Match 'relay-server = "60\.205\.95\.98:21117"'

        $serviceState = Read-VegaState -Path $script:serviceStatePath
        $serviceState.RustDeskUserConfig.Sid | Should -Be $script:testSid
        $serviceState.RustDeskUserConfig.AppDataPath | Should -Be $appData
        $serviceState.RustDeskUserConfig.Path | Should -Be $hookUserConfig
        $serviceState.RustDeskUserConfig.Written | Should -BeTrue
        $serviceState.RustDeskUserConfig.PromptPending | Should -BeFalse
    }

    It 'P1-5 取不到交互用户时只写服务级，并标记完成页提示' {
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { 'C:\Program Files\RustDesk\rustdesk.exe' }
        Mock -ModuleName $script:ModuleName Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Get-VegaInteractiveUserContext {
            [pscustomobject]@{ Name = ''; Sid = ''; AppDataPath = ''; UserConfigPath = '' }
        }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $script:defaults -HostStatePath $script:statePath `
            -ServiceStatePath $script:serviceStatePath -ServiceConfigPath $script:serviceConfig `
            -DownloadDirectory $script:downloadDir -Confirm:$false

        $result.Success | Should -BeTrue
        Test-Path -LiteralPath $script:userConfig | Should -BeFalse
        (Get-Content -LiteralPath $script:serviceConfig -Raw -Encoding UTF8) | Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'

        $serviceState = Read-VegaState -Path $script:serviceStatePath
        $serviceState.RustDeskUserConfig.Written | Should -BeFalse
        $serviceState.RustDeskUserConfig.PromptPending | Should -BeTrue
        ($result.Messages -join "`n") | Should -Match '完成页'
    }

Describe 'Invoke-VegaRustDeskRollback' {
    BeforeEach {
        # 生产环境记录路径就是真实 %APPDATA% 路径，这里用 $TestDrive，跳过路径白名单校验。
        Mock -ModuleName $script:ModuleName Test-VegaRustDeskManagedConfigPath { $true }
    }

    It '按记录恢复配置，InstalledByVega 时卸载 RustDesk' {
        $statePath = Join-Path $TestDrive ('rollback-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('rollback-service-' + [guid]::NewGuid().ToString('N') + '.json')
        $configPath = Join-Path $TestDrive ('rollback-' + [guid]::NewGuid().ToString('N') + '/RustDesk/config/RustDesk2.toml')
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force
        Set-Content -LiteralPath $configPath -Encoding UTF8 -NoNewline -Value @"
[options]
custom-rendezvous-server = "60.205.95.98"
relay-server = "60.205.95.98:21117"
key = "$script:Key"
"@

        $state = Get-VegaEmptyState
        $state.RustDeskConfigKeys = @(
            [pscustomobject]@{ Path = $configPath; Key = 'custom-rendezvous-server'; Existed = $true; OriginalValue = 'old.example.com'; Restored = $false }
            [pscustomobject]@{ Path = $configPath; Key = 'relay-server'; Existed = $false; OriginalValue = ''; Restored = $false }
            [pscustomobject]@{ Path = $configPath; Key = 'key'; Existed = $false; OriginalValue = ''; Restored = $false }
        )
        $state = Add-VegaStateRustDeskInstall -State $state -Path 'C:\Program Files\RustDesk\rustdesk.exe' -Version '1.3.9'
        $null = Save-VegaState -State $state -Path $statePath

        Mock -ModuleName $script:ModuleName Uninstall-VegaRustDeskRecorded {
            [pscustomobject]@{ Success = $true; Message = '已卸载 RustDesk' }
        }

        $result = Invoke-VegaRustDeskRollback -HostStatePath $statePath -ServiceStatePath $serviceStatePath -Confirm:$false
        $result.Success | Should -BeTrue
        Should -Invoke -CommandName Uninstall-VegaRustDeskRecorded -ModuleName $script:ModuleName -Times 1 -Exactly

        $text = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $text | Should -Match 'custom-rendezvous-server = "old\.example\.com"'
        $text | Should -Not -Match 'relay-server'
        $text | Should -Not -Match ([regex]::Escape($script:Key))
        @((Read-VegaState -Path $statePath).RustDeskInstalls).Count | Should -Be 0
    }

    It 'KeepRustDesk 时只恢复配置，不卸载' {
        $statePath = Join-Path $TestDrive ('keep-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('keep-service-' + [guid]::NewGuid().ToString('N') + '.json')
        $state = Get-VegaEmptyState
        $state = Add-VegaStateRustDeskInstall -State $state -Path 'C:\Program Files\RustDesk\rustdesk.exe'
        $null = Save-VegaState -State $state -Path $statePath

        Mock -ModuleName $script:ModuleName Uninstall-VegaRustDeskRecorded { throw '不应卸载' }

        $result = Invoke-VegaRustDeskRollback -HostStatePath $statePath -ServiceStatePath $serviceStatePath -KeepRustDesk -Confirm:$false
        $result.Success | Should -BeTrue
        Should -Invoke -CommandName Uninstall-VegaRustDeskRecorded -ModuleName $script:ModuleName -Times 0 -Exactly
        @((Read-VegaState -Path $statePath).RustDeskInstalls).Count | Should -Be 1
    }

    It 'P2d：-ServiceStatePath 传到回滚，服务模式清单里的键也真的恢复' {
        $hostStatePath = Join-Path $TestDrive ('nosuch-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('svc-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceConfig = Join-Path $TestDrive ('svc-' + [guid]::NewGuid().ToString('N') + '/RustDesk/config/RustDesk2.toml')
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $serviceConfig) -Force
        Set-Content -LiteralPath $serviceConfig -Encoding UTF8 -NoNewline -Value @"
[options]
custom-rendezvous-server = "60.205.95.98"
relay-server = "relay.example.com:21117"
key = "$script:Key"
"@

        $state = Get-VegaEmptyState
        $state.RustDeskConfigKeys = @(
            [pscustomobject]@{ Path = $serviceConfig; Key = 'custom-rendezvous-server'; Existed = $true; OriginalValue = 'old.example.com'; Restored = $false }
            [pscustomobject]@{ Path = $serviceConfig; Key = 'relay-server'; Existed = $false; OriginalValue = ''; Restored = $false }
            [pscustomobject]@{ Path = $serviceConfig; Key = 'key'; Existed = $false; OriginalValue = ''; Restored = $false }
        )
        $null = Save-VegaState -State $state -Path $serviceStatePath

        $result = Invoke-VegaRustDeskRollback -HostStatePath $hostStatePath -ServiceStatePath $serviceStatePath -KeepRustDesk -Confirm:$false
        $result.Success | Should -BeTrue

        $text = Get-Content -LiteralPath $serviceConfig -Raw -Encoding UTF8
        $text | Should -Match 'custom-rendezvous-server = "old\.example\.com"'
        $text | Should -Not -Match 'relay-server'
        $text | Should -Not -Match ([regex]::Escape($script:Key))
    }
}

Describe 'install-rustdesk.ps1 入口（真实子进程）' {
    It '打包资源路径与 tauri.conf.json / hooks.nsh 一致' {
        $repo = Join-Path $PSScriptRoot '..'
        $conf = Get-Content -LiteralPath (Join-Path (Join-Path $repo 'console/src-tauri') 'tauri.conf.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $resources = $conf.bundle.resources
        $resources.'../../host/install-rustdesk.ps1' | Should -Be 'resources/host/install-rustdesk.ps1'
        $resources.'../../host/resolve-interactive-user.ps1' | Should -Be 'resources/host/resolve-interactive-user.ps1'
        $resources.'../../host/lib/Vega.Common.psm1' | Should -Be 'resources/host/lib/Vega.Common.psm1'
        $resources.'resources/vega-defaults.json' | Should -Be 'resources/vega-defaults.json'

        $hooks = Get-Content -LiteralPath (Join-Path (Join-Path $repo 'console/src-tauri/windows') 'hooks.nsh') -Raw -Encoding UTF8
        $hooks | Should -Match '\$INSTDIR\\resources\\host\\install-rustdesk\.ps1'
        $hooks | Should -Match '\$INSTDIR\\resources\\vega-defaults\.json'
        $hooks | Should -Not -Match '\$INSTDIR\\host\\'
    }

    It '入口脚本在子进程里以真实退出码报告失败' -Skip:($env:OS -ne 'Windows_NT') {
        if (-not (Test-VegaProcessElevated)) {
            Set-ItResult -Skipped -Because '入口脚本要求管理员权限，CI 需要提权运行'
            return
        }
        $package = Join-Path $TestDrive ('pkg-' + [guid]::NewGuid().ToString('N'))
        $libDir = Join-Path $package 'lib'
        $null = New-Item -ItemType Directory -Path $libDir -Force
        Copy-Item -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') 'host/install-rustdesk.ps1') -Destination $package
        Copy-Item -LiteralPath (Join-Path (Join-Path (PSScriptRoot) '..') 'host/lib/Vega.Common.psm1') -Destination $libDir

        $defaults = Join-Path $package 'bad-defaults.json'
        Set-Content -LiteralPath $defaults -Value '{ not json' -Encoding UTF8
        $log = Join-Path $package 'setup.log'
        $statePath = Join-Path $package 'host-state.json'
        $serviceStatePath = Join-Path $package 'state.json'

        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $package 'install-rustdesk.ps1'),
            '-DefaultsFile', $defaults, '-LogFile', $log,
            '-StatePath', $statePath, '-ServiceStatePath', $serviceStatePath
        )
        $output = & $ps @arguments 2>&1
        $code = $LASTEXITCODE
        Write-Host ($output | Out-String)

        $code | Should -Be 1
        (Get-Content -LiteralPath $log -Raw -Encoding UTF8) | Should -Match 'FAIL'
        Test-Path -LiteralPath $serviceStatePath | Should -BeFalse
    }
}

Describe 'install-rustdesk.ps1 静态约束' {
    BeforeAll {
        $script:ScriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'host/install-rustdesk.ps1'
        $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw -Encoding UTF8
    }

    It '不内嵌 RustDesk 二进制，只从官方 Release 下载并校验 SHA256' {
        $script:ScriptText | Should -Match 'Invoke-VegaRustDeskBootstrap'
        $script:ScriptText | Should -Match 'RustDesk 是 AGPL|不内嵌'
        (Get-ChildItem -LiteralPath (Split-Path -Parent $script:ScriptPath) -Filter '*.exe' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It '支持 -DefaultsFile 与 -Uninstall，且失败返回非零' {
        $script:ScriptText | Should -Match '\[string\]\$DefaultsFile'
        $script:ScriptText | Should -Match '\[switch\]\$Uninstall'
        $script:ScriptText | Should -Match 'exit 1'
    }
}

Describe 'P1-5 回滚按 SID 记录的用户配置路径校验' {
    It '把 state.json 里记录的用户级路径作为 -ExpectedPath 传给恢复逻辑' {
        $hostStatePath = Join-Path $TestDrive ('u-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('us-' + [guid]::NewGuid().ToString('N') + '.json')
        $userConfig = 'C:\Users\alice\AppData\Roaming\RustDesk\config\RustDesk2.toml'

        $hostState = Get-VegaEmptyState
        $hostState.RustDeskConfigKeys = @(
            [pscustomobject]@{ Path = $userConfig; Key = 'key'; Existed = $true; OriginalValue = 'old'; Restored = $false }
        )
        $null = Save-VegaState -State $hostState -Path $hostStatePath

        $serviceState = Get-VegaEmptyState
        $serviceState = Set-VegaStateRustDeskUserConfig -State $serviceState -Sid 'S-1-5-21-1-2-3-1001' `
            -Path $userConfig -AppDataPath 'C:\Users\alice\AppData\Roaming' -Written $true -PromptPending $false
        $null = Save-VegaState -State $serviceState -Path $serviceStatePath

        Mock -ModuleName $script:ModuleName Test-VegaRustDeskManagedConfigPath { $true }
        Mock -ModuleName $script:ModuleName Restore-VegaRustDeskState {
            param($State)
            [pscustomobject]@{ State = $State; Failures = @(); Messages = @('ok') }
        }

        $null = Invoke-VegaRustDeskRollback -HostStatePath $hostStatePath -ServiceStatePath $serviceStatePath -KeepRustDesk -Confirm:$false
        Should -Invoke -CommandName Restore-VegaRustDeskState -ModuleName $script:ModuleName -Times 1 -Exactly -ParameterFilter {
            $ExpectedPath -eq $userConfig
        }
    }
}

Describe 'P1-2 / P1-4 / P1-5 / P1-8 安装包钩子静态约束' {
    BeforeAll {
        $repoRoot = Join-Path $PSScriptRoot '..'
        $script:Hooks = Get-Content -LiteralPath (Join-Path (Join-Path $repoRoot 'console/src-tauri/windows') 'hooks.nsh') -Raw -Encoding UTF8
        $script:ModuleText = Get-Content -LiteralPath (Join-Path $repoRoot 'host/lib/Vega.Common.psm1') -Raw -Encoding UTF8
        $script:ResolverText = Get-Content -LiteralPath (Join-Path $repoRoot 'host/resolve-interactive-user.ps1') -Raw -Encoding UTF8
    }

    It 'P1-2 WOW64 下优先用 Sysnative 的 64 位 PowerShell' {
        $script:Hooks | Should -Match 'Sysnative\\WindowsPowerShell\\v1\.0\\powershell\.exe'
        $script:Hooks | Should -Match 'VegaSelectPowerShell'
        # Sysnative 不存在时才回落 $SYSDIR，顺序不能反。
        $native = $script:Hooks.IndexOf('Sysnative\WindowsPowerShell')
        $fallback = $script:Hooks.IndexOf('StrCpy $vegaPowerShell "$SYSDIR\WindowsPowerShell')
        $native | Should -BeGreaterThan -1
        $fallback | Should -BeGreaterThan $native
    }

    It 'P1-2 RustDesk 探测同时看 ProgramW6432 / ProgramFiles 与注册表两个视图' {
        $script:ModuleText | Should -Match 'ProgramW6432'
        $script:ModuleText | Should -Match 'WOW6432Node'
        $script:ModuleText | Should -Match 'ProgramFilesDir \(x86\)'
        $script:ModuleText | Should -Match 'Get-VegaProgramFilesRegistryRoot'
    }

    It 'P1-4 icacls 用绝对路径、检查退出码、失败跳过文件日志' {
        $script:Hooks | Should -Match '\$SYSDIR\\icacls\.exe'
        $script:Hooks | Should -Not -Match "nsExec::ExecToStack 'icacls"
        $script:Hooks | Should -Match 'StrCmp \$0 "0" vega_log_ok'
        $script:Hooks | Should -Match 'vegaLogUsable'
        $script:Hooks | Should -Match 'StrCmp \$vegaLogUsable "1"'
    }

    It 'P1-5 钩子把交互用户 SID 与 Roaming AppData 传给脚本' {
        $script:Hooks | Should -Match '-InteractiveUserSid "\$vegaUserSid"'
        $script:Hooks | Should -Match '-InteractiveUserAppData "\$vegaUserAppData"'
        # 用 -File 调独立解析脚本（避免 NSIS 单引号嵌套），字段分开取。
        $script:Hooks | Should -Match 'resolve-interactive-user\.ps1" -Field Sid'
        $script:Hooks | Should -Match 'resolve-interactive-user\.ps1" -Field AppDataPath'
        $script:ResolverText | Should -Match 'Get-VegaInteractiveUserContextValue -Field \$Field'
        # 解析只认交互用户，不能把提权账户当用户。
        $script:ModuleText | Should -Match 'SkipProcessFallback'
    }

    It 'P1-8 回滚失败保留重试脚本，成功后才删除' {
        $script:Hooks | Should -Match 'VegaPreserveRetryScript'
        $script:Hooks | Should -Match 'retry\\host\\install-rustdesk\.ps1'
        $preserve = $script:Hooks.IndexOf('!insertmacro VegaPreserveRetryScript')
        $uninstall = $script:Hooks.IndexOf('-File "$INSTDIR\resources\host\install-rustdesk.ps1" -Uninstall')
        $remove = $script:Hooks.IndexOf('StrCmp $0 "0" 0 vega_unsetup_failed')
        $preserve | Should -BeGreaterThan -1
        $uninstall | Should -BeGreaterThan $preserve
        $remove | Should -BeGreaterThan $uninstall
        $script:Hooks | Should -Match 'vega_unsetup_failed:[\s\S]*可重试'
    }
}
