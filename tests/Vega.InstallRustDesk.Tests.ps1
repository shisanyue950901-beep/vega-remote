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
        # 计数器放全局：Mock 的脚本块在不同作用域求值，用 $script: 会写到另一个变量上，
        # 回读永远是 0。全局变量在两边看到的是同一个。
        $global:VegaWaitCalls = 0
        Mock -ModuleName $script:ModuleName Get-Service {
            $global:VegaWaitCalls += 1
            if ($global:VegaWaitCalls -le 1) { [pscustomobject]@{ Name = 'RustDesk'; Status = 'StartPending' } }
            else { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }
        }

        $result = Wait-VegaRustDeskService -TimeoutSeconds 10 -IntervalSeconds 1
        $result.Running | Should -BeTrue
        $result.Status | Should -Be 'Running'
        $global:VegaWaitCalls | Should -BeGreaterOrEqual 2
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
        # t3-fix5 P3：完整成功（用户级 + 服务级）退出码 0。
        $result.ExitCode | Should -Be 0
        $result.Degraded | Should -BeFalse
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
        Copy-Item -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1') -Destination $libDir

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

Describe 't3-fix6 已有安装的服务状态分支' {
    It '服务已注册但停止：Start-Service 启动并等到 Running 后写两处配置' {
        $statePath = Join-Path $TestDrive ('h-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('s-' + [guid]::NewGuid().ToString('N') + '.json')
        $defaults = Join-Path $TestDrive 'vega-defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = '60.205.95.98'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $defaults -Value $json -Encoding UTF8

        $sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        $appData = Join-Path $TestDrive 'Users/张三/AppData/Roaming'
        $null = New-Item -ItemType Directory -Path $appData -Force
        $serviceConfig = Join-Path $TestDrive 'ProgramData/RustDesk/config/RustDesk2.toml'

        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { 'C:\Program Files\RustDesk\rustdesk.exe' }
        Mock -ModuleName $script:ModuleName Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Stopped' } }
        Mock -ModuleName $script:ModuleName Start-Service { }
        Mock -ModuleName $script:ModuleName Wait-VegaRustDeskService { [pscustomobject]@{ Found = $true; Running = $true; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Restart-VegaRustDeskService { [pscustomobject]@{ Found = $true; WasRunning = $true; Restarted = $true; Status = 'Running'; Message = 'ok' } }
        Mock -ModuleName $script:ModuleName Set-VegaRustDeskConfig {
            param($Server, $Key, $RelayServer, $State, $StatePath, $UserConfigPath, $ServiceConfigPath, $ServiceStatePath, $ForceService, $ServiceOnly, $ContinueOnUserFailure, $Confirm)
            [pscustomobject]@{
                Applied = @(
                    [pscustomobject]@{ Path = $UserConfigPath; Changed = $true }
                    [pscustomobject]@{ Path = $ServiceConfigPath; Changed = $true }
                )
                Warnings       = @()
                ServicePresent = $true
                Values         = @{}
                State          = $State
            }
        }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $defaults -HostStatePath $statePath `
            -ServiceStatePath $serviceStatePath -ServiceConfigPath $serviceConfig `
            -InteractiveUserSid $sid -InteractiveUserAppData $appData -Confirm:$false

        $result.Success | Should -BeTrue
        $result.Degraded | Should -BeFalse
        $result.ExitCode | Should -Be 0
        # t3-fix6 P1-2：已注册但停止时必须主动启动，而不是等 60 秒后直接失败。
        Should -Invoke -CommandName Start-Service -ModuleName $script:ModuleName -Times 1 -Exactly
        Should -Invoke -CommandName Wait-VegaRustDeskService -ModuleName $script:ModuleName -Times 1 -Exactly
    }

    It '服务未注册：不注册服务，只写用户级配置并回读，降级退出码 2 并提示启用服务' {
        $statePath = Join-Path $TestDrive ('h-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('s-' + [guid]::NewGuid().ToString('N') + '.json')
        $defaults = Join-Path $TestDrive 'vega-defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = '60.205.95.98'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $defaults -Value $json -Encoding UTF8

        $sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        $appData = Join-Path $TestDrive 'Users/张三/AppData/Roaming'
        $null = New-Item -ItemType Directory -Path (Join-Path $appData 'RustDesk/config') -Force
        $userConfig = Join-Path $appData 'RustDesk/config/RustDesk2.toml'
        $serviceConfig = Join-Path $TestDrive 'ProgramData/RustDesk/config/RustDesk2.toml'

        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { 'C:\Program Files\RustDesk\rustdesk.exe' }
        Mock -ModuleName $script:ModuleName Get-Service { $null }
        Mock -ModuleName $script:ModuleName Start-Service { throw '服务未注册时不应启动服务' }
        Mock -ModuleName $script:ModuleName Wait-VegaRustDeskService { throw '服务未注册时不应等待服务' }
        Mock -ModuleName $script:ModuleName Restart-VegaRustDeskService { [pscustomobject]@{ Found = $false; WasRunning = $false; Restarted = $false; Status = ''; Message = '未找到 RustDesk 服务，跳过重启。' } }

        # Set-VegaRustDeskConfig 走真实代码：用户级配置必须真的写入并回读一致。
        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $defaults -HostStatePath $statePath `
            -ServiceStatePath $serviceStatePath -ServiceConfigPath $serviceConfig `
            -InteractiveUserSid $sid -InteractiveUserAppData $appData -Confirm:$false

        $result.Success | Should -BeTrue
        $result.Degraded | Should -BeTrue
        $result.ExitCode | Should -Be 2
        $result.UserConfigWritten | Should -BeTrue
        ($result.Messages -join "`n") | Should -Match '启用服务'

        # 用户级落盘并回读；服务级跳过（不替用户注册/写服务）。
        (Microsoft.PowerShell.Management\Get-Content -LiteralPath $userConfig -Raw -Encoding UTF8) |
            Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'
        Test-Path -LiteralPath $serviceConfig | Should -BeFalse
        Should -Invoke -CommandName Start-Service -ModuleName $script:ModuleName -Times 0 -Exactly

        $serviceState = Read-VegaState -Path $serviceStatePath
        $serviceState.RustDeskUserConfig.Written | Should -BeTrue
        $serviceState.RustDeskUserConfig.PromptPending | Should -BeFalse
    }
}

Describe 't3-fix6 用户配置读取失败时不写基线' {
    It '真实文件锁导致读取失败：服务级仍落盘、降级退出码 2、用户基线不新增' -Skip:($env:OS -ne 'Windows_NT') {
        $statePath = Join-Path $TestDrive ('h-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('s-' + [guid]::NewGuid().ToString('N') + '.json')
        $defaults = Join-Path $TestDrive 'vega-defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = '60.205.95.98'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $defaults -Value $json -Encoding UTF8

        $sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        $appData = Join-Path $TestDrive 'Users/张三/AppData/Roaming'
        $userConfig = Join-Path $appData 'RustDesk/config/RustDesk2.toml'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $userConfig) -Force
        Set-Content -LiteralPath $userConfig -Value 'relay-server = "old.example.com:21117"' -Encoding UTF8
        $serviceConfig = Join-Path $TestDrive 'ProgramData/RustDesk/config/RustDesk2.toml'

        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { 'C:\Program Files\RustDesk\rustdesk.exe' }
        Mock -ModuleName $script:ModuleName Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Wait-VegaRustDeskService { [pscustomobject]@{ Found = $true; Running = $true; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Restart-VegaRustDeskService { [pscustomobject]@{ Found = $true; WasRunning = $true; Restarted = $true; Status = 'Running'; Message = 'ok' } }

        # 真实共享冲突：独占打开用户文件，Get-Content 会抛非终止错误（这正是 P1-1 的场景，
        # 用 throw 模拟不出来）。没有 -ErrorAction Stop 时读失败会被当成空配置。
        $lock = [System.IO.File]::Open($userConfig, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $defaults -HostStatePath $statePath `
                -ServiceStatePath $serviceStatePath -ServiceConfigPath $serviceConfig `
                -InteractiveUserSid $sid -InteractiveUserAppData $appData -Confirm:$false
        }
        finally {
            $lock.Dispose()
        }

        $result.Success | Should -BeTrue
        $result.Degraded | Should -BeTrue
        $result.ExitCode | Should -Be 2

        # 用户文件原值保留，且 host-state.json 里没有它的回滚基线（读失败不写基线）。
        (Microsoft.PowerShell.Management\Get-Content -LiteralPath $userConfig -Raw -Encoding UTF8) |
            Should -Match 'old\.example\.com:21117'
        $saved = Read-VegaState -Path $statePath
        $userRecords = @($saved.RustDeskConfigKeys | Where-Object { $null -ne $_ -and [string]::Equals([string]$_.Path, $userConfig, [StringComparison]::OrdinalIgnoreCase) })
        $userRecords.Count | Should -Be 0

        # 服务级配置照常写入并回读。
        (Microsoft.PowerShell.Management\Get-Content -LiteralPath $serviceConfig -Raw -Encoding UTF8) |
            Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'
    }
}

Describe 't3-fix6 入口语义子进程（显式空 / 省略交互用户上下文）' {
    BeforeAll {
        $script:EntryHarness = @'
param(
    [string]$ModulePath,
    [string]$DefaultsFile,
    [string]$HostStatePath,
    [string]$ServiceStatePath,
    [string]$ServiceConfigPath,
    [string]$UserConfigPath,
    [string]$Sid,
    [string]$AppData,
    [switch]$ServiceOnly
)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
# 在模块作用域替换外部动作：真实进程 + 真实配置写入，只有服务/安装探测是桩。
$module = Get-Module 'Vega.Common'
& $module {
    param($sid, $appData, $userConfig)
    function Get-VegaRustDeskInstall { 'C:\Program Files\RustDesk\rustdesk.exe' }
    function Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }
    function Wait-VegaRustDeskService { [pscustomobject]@{ Found = $true; Running = $true; Status = 'Running' } }
    function Restart-VegaRustDeskService { [pscustomobject]@{ Found = $true; WasRunning = $true; Restarted = $true; Status = 'Running'; Message = 'ok' } }
    function Resolve-VegaSetupInteractiveUser {
        param([AllowEmptyString()][string]$Sid = '', [AllowEmptyString()][string]$AppDataPath = '', [AllowEmptyString()][string]$ConfigPath = '')
        [pscustomobject]@{ Sid = $sid; AppDataPath = $appData; UserConfigPath = $userConfig }
    }
} $Sid $AppData $UserConfigPath

$arguments = @{
    DefaultsFile      = $DefaultsFile
    HostStatePath     = $HostStatePath
    ServiceStatePath  = $ServiceStatePath
    ServiceConfigPath = $ServiceConfigPath
    Confirm           = $false
}
if ($ServiceOnly) { $arguments['ServiceOnly'] = $true }
elseif (-not [string]::IsNullOrWhiteSpace($UserConfigPath)) { $arguments['UserConfigPath'] = $UserConfigPath }

$result = Invoke-VegaRustDeskBootstrap @arguments
exit [int]$result.ExitCode
'@
        $script:HarnessPath = Join-Path $TestDrive 'entry-harness.ps1'
        Set-Content -LiteralPath $script:HarnessPath -Value $script:EntryHarness -Encoding UTF8
        $script:HarnessModule = Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1'
        $script:HarnessPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    It '显式传空上下文（入口置 -ServiceOnly）：子进程退出码 2 且只落服务级配置' -Skip:($env:OS -ne 'Windows_NT') {
        $statePath = Join-Path $TestDrive ('h-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('s-' + [guid]::NewGuid().ToString('N') + '.json')
        $defaults = Join-Path $TestDrive 'vega-defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = '60.205.95.98'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $defaults -Value $json -Encoding UTF8
        $serviceConfig = Join-Path $TestDrive 'ProgramData/RustDesk/config/RustDesk2.toml'

        $arguments = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $script:HarnessPath,
            '-ModulePath', $script:HarnessModule,
            '-DefaultsFile', $defaults,
            '-HostStatePath', $statePath,
            '-ServiceStatePath', $serviceStatePath,
            '-ServiceConfigPath', $serviceConfig,
            '-Sid', 'S-1-5-21-1111111111-2222222222-3333333333-1001',
            '-AppData', (Join-Path $TestDrive 'Users/张三/AppData/Roaming'),
            '-UserConfigPath', '',
            '-ServiceOnly'
        )
        $output = & $script:HarnessPowerShell @arguments 2>&1
        $code = $LASTEXITCODE
        Write-Host ($output | Out-String)

        $code | Should -Be 2
        (Microsoft.PowerShell.Management\Get-Content -LiteralPath $serviceConfig -Raw -Encoding UTF8) |
            Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'
    }

    It '省略上下文参数：子进程退出码 0 且用户级与服务级都落盘' -Skip:($env:OS -ne 'Windows_NT') {
        $statePath = Join-Path $TestDrive ('h-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('s-' + [guid]::NewGuid().ToString('N') + '.json')
        $defaults = Join-Path $TestDrive 'vega-defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = '60.205.95.98'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $defaults -Value $json -Encoding UTF8
        $appData = Join-Path $TestDrive 'Users/张三/AppData/Roaming'
        $userConfig = Join-Path $appData 'RustDesk/config/RustDesk2.toml'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $userConfig) -Force
        $serviceConfig = Join-Path $TestDrive 'ProgramData/RustDesk/config/RustDesk2.toml'

        $arguments = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $script:HarnessPath,
            '-ModulePath', $script:HarnessModule,
            '-DefaultsFile', $defaults,
            '-HostStatePath', $statePath,
            '-ServiceStatePath', $serviceStatePath,
            '-ServiceConfigPath', $serviceConfig,
            '-Sid', 'S-1-5-21-1111111111-2222222222-3333333333-1001',
            '-AppData', $appData,
            '-UserConfigPath', $userConfig
        )
        $output = & $script:HarnessPowerShell @arguments 2>&1
        $code = $LASTEXITCODE
        Write-Host ($output | Out-String)

        $code | Should -Be 0
        (Microsoft.PowerShell.Management\Get-Content -LiteralPath $userConfig -Raw -Encoding UTF8) |
            Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'
        (Microsoft.PowerShell.Management\Get-Content -LiteralPath $serviceConfig -Raw -Encoding UTF8) |
            Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'
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

    It 't3-fix5 支持 -NoFileLog 与 Base64 上下文，降级退出码由模块统一给出' {
        $script:ScriptText | Should -Match '\[switch\]\$NoFileLog'
        $script:ScriptText | Should -Match 'if \(\$NoFileLog\)'
        $script:ScriptText | Should -Match '\[string\]\$InteractiveUserContextB64'
        $script:ScriptText | Should -Match 'ConvertFrom-VegaInteractiveUserContextPayload'
        # t3-fix5 P3：模块返回 2，入口透传，不再各写各的退出码。
        $script:ScriptText | Should -Match 'exit \$result\.ExitCode'
        $script:ScriptText | Should -Not -Match 'exit 2'
        # t3-fix5 P2：钩子显式传空上下文与省略参数必须区分。
        $script:ScriptText | Should -Match ([regex]::Escape("`$PSBoundParameters.ContainsKey('InteractiveUserContextB64')"))
        # -NoFileLog 时不能再补默认日志路径。
        $script:ScriptText | Should -Match 'if \(\$NoFileLog\)[\s\S]*?\$LogFile = \x27\x27'
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

    It 'P1-5/t3-fix4 钩子一次解析并以 ASCII Base64 传交互用户上下文' {
        $script:Hooks | Should -Match '-InteractiveUserContextB64 "\$vegaUserContextB64"'
        $script:Hooks | Should -Not -Match '-InteractiveUserSid "\$vegaUserSid"'
        $script:Hooks | Should -Not -Match '-InteractiveUserAppData "\$vegaUserAppData"'
        # 用 -File 调独立解析脚本（避免 NSIS 单引号嵌套），只取一次 Context。
        $script:Hooks | Should -Match 'resolve-interactive-user\.ps1" -Field Context'
        $script:Hooks | Should -Match 'StrCpy \$vegaUserContextB64 \$1'
        $script:ResolverText | Should -Match 'Get-VegaInteractiveUserContextPayload'
        $script:ModuleText | Should -Match 'ConvertTo-VegaAsciiBase64'
        # 解析只认交互用户，不能把提权账户当用户。
        $script:ModuleText | Should -Match 'SkipProcessFallback'
    }

    It 'P2/t3-fix4 icacls 失败时钩子传 -NoFileLog' {
        $script:Hooks | Should -Match 'VegaSelectLogArgument'
        $script:Hooks | Should -Match 'StrCpy \$vegaLogArgument .-NoFileLog.'
        $script:Hooks | Should -Match '\$vegaLogArgument -InteractiveUserContextB64'
        # 安装与卸载两处都必须用条件参数，而不是写死 -LogFile。
        ([regex]::Matches($script:Hooks, '\$vegaLogArgument -')).Count | Should -BeGreaterThan 1
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


Describe 't3-fix4 ASCII Base64 交互用户上下文' {
    BeforeEach {
        $script:CtxSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        # 中文用户名/目录：nsExec 用 ANSI 解码会变成 '?'，Base64 必须原样往返。
        $script:CtxAppData = Join-Path $TestDrive ('用户 张三/AppData/Roaming')
        $null = New-Item -ItemType Directory -Path $script:CtxAppData -Force
    }

    It '中文路径编码后是纯 ASCII，解码校验通过' {
        $payload = ConvertTo-VegaAsciiBase64 -Text ("{0}`n{1}" -f $script:CtxSid, $script:CtxAppData)
        $payload | Should -Match '^[A-Za-z0-9+/]+={0,2}$'
        $payload | Should -Not -Match '[^\x20-\x7E]'

        $decoded = ConvertFrom-VegaInteractiveUserContextPayload -Payload ($payload + "`r`n")
        $decoded.Valid | Should -BeTrue
        $decoded.Sid | Should -Be $script:CtxSid
        $decoded.AppDataPath | Should -Be $script:CtxAppData.TrimEnd([char[]]@('\', '/'))
        $decoded.UserConfigPath | Should -Match 'RustDesk'
    }

    It 'AppData 目录不存在时判为无效（脚本据此降级）' {
        $missing = Join-Path $TestDrive ('不存在 ' + [guid]::NewGuid().ToString('N'))
        $payload = ConvertTo-VegaAsciiBase64 -Text ("{0}`n{1}" -f $script:CtxSid, $missing)
        $decoded = ConvertFrom-VegaInteractiveUserContextPayload -Payload $payload
        $decoded.Valid | Should -BeFalse
        $decoded.Error | Should -Match '不存在'
    }

    It '非法 Base64 / 非法 SID 一律拒绝' {
        (ConvertFrom-VegaInteractiveUserContextPayload -Payload '!!!not-base64!!!').Valid | Should -BeFalse
        $badSid = ConvertTo-VegaAsciiBase64 -Text ("not-a-sid`n{0}" -f $script:CtxAppData)
        (ConvertFrom-VegaInteractiveUserContextPayload -Payload $badSid).Valid | Should -BeFalse
        # 裸明文（含中文）不是合法 Base64，也不能被误当上下文。
        (ConvertFrom-VegaInteractiveUserContextPayload -Payload ('S-1-5-21`n' + $script:CtxAppData)).Valid | Should -BeFalse
    }
}

Describe 't3-fix4 已有 RustDesk 装在自定义目录时不重装' {
    BeforeEach {
        # 隔离真实机器上的 Program Files / LOCALAPPDATA / 注册表，确保命中的是测试候选。
        $script:EnvBackup = @{
            ProgramW6432 = $env:ProgramW6432
            ProgramFiles = $env:ProgramFiles
            ProgramFilesX86 = ${env:ProgramFiles(x86)}
            LocalAppData = $env:LOCALAPPDATA
        }
        $env:ProgramW6432 = Join-Path $TestDrive 'no-pf-64'
        $env:ProgramFiles = Join-Path $TestDrive 'no-pf'
        ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'no-pf-x86'
        $env:LOCALAPPDATA = Join-Path $TestDrive 'no-localappdata'
        Mock -ModuleName $script:ModuleName Get-VegaProgramFilesRegistryRoot { @() }
    }

    AfterEach {
        $env:ProgramW6432 = $script:EnvBackup.ProgramW6432
        $env:ProgramFiles = $script:EnvBackup.ProgramFiles
        ${env:ProgramFiles(x86)} = $script:EnvBackup.ProgramFilesX86
        $env:LOCALAPPDATA = $script:EnvBackup.LocalAppData
    }

    It 'Registry64/32 候选命中 ASCII 自定义目录即视为已安装' {
        $dir = Join-Path $TestDrive 'CustomApps/RustDesk'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $exe = Join-Path $dir 'rustdesk.exe'
        Set-Content -LiteralPath $exe -Value 'stub' -Encoding UTF8

        $script:CustomExe = $exe
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskRegistryInstallCandidates { @($script:CustomExe) }
        (Get-VegaRustDeskInstall) | Should -Be $exe
    }

    It '中文自定义目录同样命中，不再走静默安装' {
        $dir = Join-Path $TestDrive '自定义 软件/远程控制 RustDesk'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $exe = Join-Path $dir 'rustdesk.exe'
        Set-Content -LiteralPath $exe -Value 'stub' -Encoding UTF8

        $script:ChineseExe = $exe
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskRegistryInstallCandidates { @($script:ChineseExe) }
        (Get-VegaRustDeskInstall) | Should -Be $exe
    }

    It '注册表 InstallLocation / DisplayIcon / 服务 ImagePath 规整成 rustdesk.exe' -Skip:($env:OS -ne 'Windows_NT') {
        (ConvertTo-VegaRustDeskExeCandidate -Value 'C:\Tools\RustDesk') | Should -Be 'C:\Tools\RustDesk\rustdesk.exe'
        (ConvertTo-VegaRustDeskExeCandidate -Value 'C:\Tools\RustDesk\rustdesk.exe,0') | Should -Be 'C:\Tools\RustDesk\rustdesk.exe'
        (ConvertTo-VegaRustDeskExeCandidate -Value '"C:\Tools\RustDesk\rustdesk.exe" --service') | Should -Be 'C:\Tools\RustDesk\rustdesk.exe'
    }
}

Describe 't3-fix4 用户级配置写失败时降级而不是整单失败' {
    It '服务级写成功后返回 Success + Degraded，并保留 PromptPending' {
        $statePath = Join-Path $TestDrive ('host-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('svc-' + [guid]::NewGuid().ToString('N') + '.json')
        $defaults = Join-Path $TestDrive 'vega-defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = '60.205.95.98'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $defaults -Value $json -Encoding UTF8

        $sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        # 用 Windows 形态的交互用户路径（bootstrap 只接受 Windows 绝对路径），配置写入被 Mock。
        $appData = 'C:\Users\张三\AppData\Roaming'
        $serviceConfig = Join-Path $TestDrive ('svc-' + [guid]::NewGuid().ToString('N') + '/RustDesk/config/RustDesk2.toml')

        Mock -ModuleName $script:ModuleName Get-VegaInteractiveUserContext { throw '显式给了交互用户参数，不应再解析' }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { 'C:\Program Files\RustDesk\rustdesk.exe' }
        Mock -ModuleName $script:ModuleName Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Wait-VegaRustDeskService { [pscustomobject]@{ Found = $true; Running = $true; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Restart-VegaRustDeskService { [pscustomobject]@{ Found = $true; WasRunning = $true; Restarted = $true; Status = 'Running'; Message = 'ok' } }
        Mock -ModuleName $script:ModuleName Set-VegaRustDeskConfig {
            param($Server, $Key, $RelayServer, $State, $StatePath, $UserConfigPath, $ServiceConfigPath, $ServiceStatePath, $ForceService, $ContinueOnUserFailure, $Confirm)
            $ContinueOnUserFailure | Should -BeTrue
            [pscustomobject]@{
                Applied        = @([pscustomobject]@{ Path = $ServiceConfigPath; Changed = $true })
                Warnings       = @("用户级配置路径写入失败：$UserConfigPath")
                ServicePresent = $true
                Values         = @{}
                State          = $State
            }
        }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $defaults -HostStatePath $statePath `
            -ServiceStatePath $serviceStatePath -ServiceConfigPath $serviceConfig `
            -InteractiveUserSid $sid -InteractiveUserAppData $appData -Confirm:$false

        $result.Success | Should -BeTrue
        $result.Configured | Should -BeTrue
        $result.Degraded | Should -BeTrue
        $result.UserConfigWritten | Should -BeFalse
        # t3-fix5 P3：降级统一退出码 2，与入口脚本透传值一致。
        $result.ExitCode | Should -Be 2
        ($result.Messages -join "`n") | Should -Match '降级'

        $serviceState = Read-VegaState -Path $serviceStatePath
        $serviceState.RustDeskUserConfig.Written | Should -BeFalse
        $serviceState.RustDeskUserConfig.PromptPending | Should -BeTrue
    }
}

Describe 't3-fix6 注册表原始值按字段解析（含空格安装目录）' {
    It 'InstallLocation 完整保留空格目录，DisplayIcon 兼容引号内外的图标索引，ImagePath 单独剥启动参数' -Skip:($env:OS -ne 'Windows_NT') {
        # t3-fix6 P2：含空格的安装目录路径一律从 $TestDrive 生成，不再依赖本机有 D: 盘。
        # RustDesk 官方 EXE 写的是未加引号的 InstallLocation / DisplayIcon，路径里可以有空格；
        # 旧实现按第一个空白截断，'.../Remote Tools/RustDesk' 会变成 '.../Remote'。
        $spaceDir = Join-Path $TestDrive 'Remote Tools/RustDesk'
        $spaceExe = Join-Path $spaceDir 'rustdesk.exe'

        (ConvertTo-VegaRustDeskInstallLocationPath -Value $spaceDir) | Should -Be $spaceExe
        (ConvertTo-VegaRustDeskInstallLocationPath -Value $spaceExe) | Should -Be $spaceExe
        (ConvertTo-VegaRustDeskInstallLocationPath -Value 'C:\Program Files\RustDesk') |
            Should -Be 'C:\Program Files\RustDesk\rustdesk.exe'

        # DisplayIcon 的四种形态：未加引号、"路径",0、"路径,0"、",-1"。
        # 引号内的索引（"path,0"）曾经漏掉，整串被当成目录并追加 rustdesk.exe。
        (ConvertTo-VegaRustDeskDisplayIconPath -Value ('{0},0' -f $spaceExe)) | Should -Be $spaceExe
        (ConvertTo-VegaRustDeskDisplayIconPath -Value ('"{0}",0' -f $spaceExe)) | Should -Be $spaceExe
        (ConvertTo-VegaRustDeskDisplayIconPath -Value ('"{0},0"' -f $spaceExe)) | Should -Be $spaceExe
        (ConvertTo-VegaRustDeskDisplayIconPath -Value ('"{0},-1"' -f $spaceExe)) | Should -Be $spaceExe
        (ConvertTo-VegaRustDeskDisplayIconPath -Value ('{0},-1' -f $spaceExe)) | Should -Be $spaceExe

        (ConvertTo-VegaRustDeskServiceImagePath -Value ('"{0}" --service' -f $spaceExe)) | Should -Be $spaceExe
        (ConvertTo-VegaRustDeskServiceImagePath -Value ('{0} --service' -f $spaceExe)) | Should -Be $spaceExe
        (ConvertTo-VegaRustDeskServiceImagePath -Value '"C:\Program Files\RustDesk\rustdesk.exe" --service') |
            Should -Be 'C:\Program Files\RustDesk\rustdesk.exe'
    }

    It '探测器按字段调用各自的解析器（不再把 InstallLocation 当通用候选）' {
        $moduleText = Get-Content -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..') 'host/lib/Vega.Common.psm1') -Raw -Encoding UTF8
        $moduleText | Should -Match 'ConvertTo-VegaRustDeskInstallLocationPath -Value \$installLocation'
        $moduleText | Should -Match 'ConvertTo-VegaRustDeskDisplayIconPath -Value \$displayIcon'
        $moduleText | Should -Match 'ConvertTo-VegaRustDeskServiceImagePath -Value \$imagePath'
    }
}

Describe 't3-fix5 命中已有安装后不下载、不静默安装' {
    It '注册表命中带空格的自定义目录时只写配置' {
        $statePath = Join-Path $TestDrive ('h-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('s-' + [guid]::NewGuid().ToString('N') + '.json')
        $defaults = Join-Path $TestDrive 'vega-defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = '60.205.95.98'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $defaults -Value $json -Encoding UTF8

        # t3-fix6 P2：含空格的自定义目录用 $TestDrive 生成，不依赖本机有 D: 盘。
        $existingDir = Join-Path $TestDrive 'Remote Tools/RustDesk'
        $null = New-Item -ItemType Directory -Path $existingDir -Force
        $existing = Join-Path $existingDir 'rustdesk.exe'
        Set-Content -LiteralPath $existing -Value 'stub' -Encoding UTF8
        $appData = Join-Path $TestDrive 'Users/张三/AppData/Roaming'
        $null = New-Item -ItemType Directory -Path $appData -Force
        $serviceConfig = Join-Path $TestDrive 'ProgramData/RustDesk/config/RustDesk2.toml'
        $sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'

        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { $existing }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskRelease { throw '已安装时不应查询/下载 Release' }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstaller { throw '已安装时不应下载安装包' }
        Mock -ModuleName $script:ModuleName Install-VegaRustDeskSilently { throw '已安装时不应静默安装' }
        Mock -ModuleName $script:ModuleName Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Wait-VegaRustDeskService { [pscustomobject]@{ Found = $true; Running = $true; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Restart-VegaRustDeskService { [pscustomobject]@{ Found = $true; WasRunning = $true; Restarted = $true; Status = 'Running'; Message = 'ok' } }
        Mock -ModuleName $script:ModuleName Set-VegaRustDeskConfig {
            param($Server, $Key, $RelayServer, $State, $StatePath, $UserConfigPath, $ServiceConfigPath, $ServiceStatePath, $ForceService, $ContinueOnUserFailure, $Confirm)
            [pscustomobject]@{
                Applied        = @([pscustomobject]@{ Path = $ServiceConfigPath; Changed = $true })
                Warnings       = @()
                ServicePresent = $true
                Values         = @{}
                State          = $State
            }
        }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $defaults -HostStatePath $statePath `
            -ServiceStatePath $serviceStatePath -ServiceConfigPath $serviceConfig `
            -InteractiveUserSid $sid -InteractiveUserAppData $appData -Confirm:$false

        $result.Success | Should -BeTrue
        $result.Installed | Should -BeFalse
        ($result.Messages -join "`n") | Should -Match ([regex]::Escape($existing))
        Should -Invoke -CommandName Get-VegaRustDeskRelease -ModuleName $script:ModuleName -Times 0 -Exactly
        Should -Invoke -CommandName Get-VegaRustDeskInstaller -ModuleName $script:ModuleName -Times 0 -Exactly
        Should -Invoke -CommandName Install-VegaRustDeskSilently -ModuleName $script:ModuleName -Times 0 -Exactly
    }
}

Describe 't3-fix5 用户级配置读取失败时降级到服务级并返回退出码 2' {
    It '真实 Set-VegaRustDeskConfig 读取用户文件抛错后，服务配置仍落盘' {
        $statePath = Join-Path $TestDrive ('h-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('s-' + [guid]::NewGuid().ToString('N') + '.json')
        $defaults = Join-Path $TestDrive 'vega-defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = '60.205.95.98'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $defaults -Value $json -Encoding UTF8

        $sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        $script:UserCfgPath = Join-Path $TestDrive 'users/张三/AppData/Roaming/RustDesk/config/RustDesk2.toml'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:UserCfgPath) -Force
        Set-Content -LiteralPath $script:UserCfgPath -Value 'relay-server = "old"' -Encoding UTF8
        $serviceConfig = Join-Path $TestDrive 'ProgramData/RustDesk/config/RustDesk2.toml'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $serviceConfig) -Force

        Mock -ModuleName $script:ModuleName Resolve-VegaSetupInteractiveUser {
            param($Sid, $AppDataPath, $ConfigPath)
            [pscustomobject]@{
                Sid            = [string]$Sid
                AppDataPath    = [string]$AppDataPath
                UserConfigPath = [string]$ConfigPath
            }
        }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { 'C:\Program Files\RustDesk\rustdesk.exe' }
        Mock -ModuleName $script:ModuleName Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Wait-VegaRustDeskService { [pscustomobject]@{ Found = $true; Running = $true; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Restart-VegaRustDeskService { [pscustomobject]@{ Found = $true; WasRunning = $true; Restarted = $true; Status = 'Running'; Message = 'ok' } }
        # 只让用户级文件的读取失败（拒绝访问/共享冲突）；服务级写入与回读走真实代码。
        Mock -ModuleName $script:ModuleName Get-Content {
            param($LiteralPath, $Path, $Raw, $Encoding)
            # 用户级配置在 ...\AppData\Roaming\RustDesk\...，服务级在 ProgramData 下：
            # 只让用户级那一份读取失败，服务级的写入与回读仍然走真实文件。
            if ([string]$LiteralPath -like '*AppData*Roaming*RustDesk2.toml') { throw '拒绝访问：模拟共享冲突' }
            if ($Raw) {
                Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw -Encoding $Encoding
            }
            else {
                Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath
            }
        }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $defaults -HostStatePath $statePath `
            -ServiceStatePath $serviceStatePath -ServiceConfigPath $serviceConfig -UserConfigPath $script:UserCfgPath `
            -InteractiveUserSid $sid -Confirm:$false

        $result.Success | Should -BeTrue
        $result.Configured | Should -BeTrue
        $result.Degraded | Should -BeTrue
        $result.UserConfigWritten | Should -BeFalse
        $result.ExitCode | Should -Be 2
        ($result.Messages -join "`n") | Should -Match '降级'

        Test-Path -LiteralPath $serviceConfig -PathType Leaf | Should -BeTrue
        (Microsoft.PowerShell.Management\Get-Content -LiteralPath $serviceConfig -Raw -Encoding UTF8) |
            Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'
        # 用户文件没被改写，失败只降级。
        (Microsoft.PowerShell.Management\Get-Content -LiteralPath $script:UserCfgPath -Raw -Encoding UTF8) |
            Should -Not -Match '60\.205\.95\.98'

        # 服务级记录仍然写入（回滚基线按服务清单走）。
        $serviceState = Read-VegaState -Path $serviceStatePath
        $serviceState.RustDeskUserConfig.Written | Should -BeFalse
        $serviceState.RustDeskUserConfig.PromptPending | Should -BeTrue
    }
}

Describe 't3-fix5 显式空上下文走 -ServiceOnly 时不再解析交互用户' {
    It '钩子显式传空（入口置 -ServiceOnly）时不调用 Get-VegaInteractiveUserContext' {
        $statePath = Join-Path $TestDrive ('h-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('s-' + [guid]::NewGuid().ToString('N') + '.json')
        $defaults = Join-Path $TestDrive 'vega-defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = '60.205.95.98'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $defaults -Value $json -Encoding UTF8

        $serviceConfig = Join-Path $TestDrive 'ProgramData/RustDesk/config/RustDesk2.toml'
        $script:CapturedServiceOnly = $false

        Mock -ModuleName $script:ModuleName Get-VegaInteractiveUserContext { throw '显式空上下文时不应再解析交互用户' }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { 'C:\Program Files\RustDesk\rustdesk.exe' }
        Mock -ModuleName $script:ModuleName Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Wait-VegaRustDeskService { [pscustomobject]@{ Found = $true; Running = $true; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Restart-VegaRustDeskService { [pscustomobject]@{ Found = $true; WasRunning = $true; Restarted = $true; Status = 'Running'; Message = 'ok' } }
        Mock -ModuleName $script:ModuleName Set-VegaRustDeskConfig {
            param($Server, $Key, $RelayServer, $State, $StatePath, $UserConfigPath, $ServiceConfigPath, $ServiceStatePath, $ForceService, $ServiceOnly, $ContinueOnUserFailure, $Confirm)
            if ($ServiceOnly) { $script:CapturedServiceOnly = $true }
            [pscustomobject]@{
                Applied        = @([pscustomobject]@{ Path = $ServiceConfigPath; Changed = $true })
                Warnings       = @()
                ServicePresent = $true
                Values         = @{}
                State          = $State
            }
        }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $defaults -HostStatePath $statePath `
            -ServiceStatePath $serviceStatePath -ServiceConfigPath $serviceConfig -ServiceOnly -Confirm:$false

        $result.Success | Should -BeTrue
        $result.Degraded | Should -BeTrue
        $result.ExitCode | Should -Be 2
        $script:CapturedServiceOnly | Should -BeTrue
        Should -Invoke -CommandName Get-VegaInteractiveUserContext -ModuleName $script:ModuleName -Times 0 -Exactly
    }
}

Describe 't3-fix5 原始带空格的注册表值能被探测命中' {
    BeforeEach {
        # 隔离真实 Program Files / LOCALAPPDATA / 注册表，确保命中的只能是解析后的候选。
        $script:EnvBackup = @{
            ProgramW6432 = $env:ProgramW6432
            ProgramFiles = $env:ProgramFiles
            ProgramFilesX86 = ${env:ProgramFiles(x86)}
            LocalAppData = $env:LOCALAPPDATA
        }
        $env:ProgramW6432 = Join-Path $TestDrive 'no-pf-64'
        $env:ProgramFiles = Join-Path $TestDrive 'no-pf'
        ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'no-pf-x86'
        $env:LOCALAPPDATA = Join-Path $TestDrive 'no-localappdata'
        Mock -ModuleName $script:ModuleName Get-VegaProgramFilesRegistryRoot { @() }
    }

    AfterEach {
        $env:ProgramW6432 = $script:EnvBackup.ProgramW6432
        $env:ProgramFiles = $script:EnvBackup.ProgramFiles
        ${env:ProgramFiles(x86)} = $script:EnvBackup.ProgramFilesX86
        $env:LOCALAPPDATA = $script:EnvBackup.LocalAppData
    }

    It 'InstallLocation / DisplayIcon 的原始值（含空格）解析后命中真实 EXE' -Skip:($env:OS -ne 'Windows_NT') {
        $dir = Join-Path $TestDrive 'Remote Tools/RustDesk'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $exe = Join-Path $dir 'rustdesk.exe'
        Set-Content -LiteralPath $exe -Value 'stub' -Encoding UTF8

        # 与 RustDesk 官方写入注册表的形态一致：目录未加引号、路径含空格、DisplayIcon 带 ,0。
        # t3-fix6 P2：注入的是注册表**原始**字段值（含引号内索引），解析由被测函数自己做，
        # 不再先解析再塞候选——否则解析回归会被测试自己掩盖。
        $rawEntry = @{
            InstallLocation = $dir
            DisplayIcon     = ('"{0},0"' -f $exe)
        }
        $script:RawCandidates = @(Get-VegaRustDeskRegistryInstallCandidates -RawEntry @($rawEntry))
        $script:RawCandidates | Should -Contain $exe

        Mock -ModuleName $script:ModuleName Get-VegaRustDeskRegistryInstallCandidates { @($script:RawCandidates) }
        (Get-VegaRustDeskInstall) | Should -Be $exe
    }

    It '探测命中后不下载、不静默安装（复用上面的候选）' -Skip:($env:OS -ne 'Windows_NT') {
        $dir = Join-Path $TestDrive 'Remote Tools/RustDesk'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $exe = Join-Path $dir 'rustdesk.exe'
        Set-Content -LiteralPath $exe -Value 'stub' -Encoding UTF8

        # t3-fix6 P2：同样注入原始注册表值（引号外索引），候选由真实解析器生成。
        $script:RawCandidates = @(Get-VegaRustDeskRegistryInstallCandidates -RawEntry @(@{
                    InstallLocation = $dir
                    DisplayIcon     = ('"{0}",0' -f $exe)
                }))
        $script:RawCandidates | Should -Contain $exe
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskRegistryInstallCandidates { @($script:RawCandidates) }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskRelease { throw '命中后不应查询 Release' }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstaller { throw '命中后不应下载' }
        Mock -ModuleName $script:ModuleName Install-VegaRustDeskSilently { throw '命中后不应静默安装' }

        $statePath = Join-Path $TestDrive ('h-' + [guid]::NewGuid().ToString('N') + '.json')
        $serviceStatePath = Join-Path $TestDrive ('s-' + [guid]::NewGuid().ToString('N') + '.json')
        $defaults = Join-Path $TestDrive 'vega-defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = '60.205.95.98'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $defaults -Value $json -Encoding UTF8
        $serviceConfig = Join-Path $TestDrive 'ProgramData/RustDesk/config/RustDesk2.toml'

        Mock -ModuleName $script:ModuleName Get-Service { [pscustomobject]@{ Name = 'RustDesk'; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Wait-VegaRustDeskService { [pscustomobject]@{ Found = $true; Running = $true; Status = 'Running' } }
        Mock -ModuleName $script:ModuleName Restart-VegaRustDeskService { [pscustomobject]@{ Found = $true; WasRunning = $true; Restarted = $true; Status = 'Running'; Message = 'ok' } }
        Mock -ModuleName $script:ModuleName Set-VegaRustDeskConfig {
            param($Server, $Key, $RelayServer, $State, $StatePath, $UserConfigPath, $ServiceConfigPath, $ServiceStatePath, $ForceService, $ServiceOnly, $ContinueOnUserFailure, $Confirm)
            [pscustomobject]@{
                Applied        = @([pscustomobject]@{ Path = $ServiceConfigPath; Changed = $true })
                Warnings       = @()
                ServicePresent = $true
                Values         = @{}
                State          = $State
            }
        }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $defaults -HostStatePath $statePath `
            -ServiceStatePath $serviceStatePath -ServiceConfigPath $serviceConfig -ServiceOnly -Confirm:$false

        $result.Success | Should -BeTrue
        $result.Installed | Should -BeFalse
        ($result.Messages -join "`n") | Should -Match ([regex]::Escape($exe))
        Should -Invoke -CommandName Get-VegaRustDeskRelease -ModuleName $script:ModuleName -Times 0 -Exactly
        Should -Invoke -CommandName Get-VegaRustDeskInstaller -ModuleName $script:ModuleName -Times 0 -Exactly
        Should -Invoke -CommandName Install-VegaRustDeskSilently -ModuleName $script:ModuleName -Times 0 -Exactly
    }
}
