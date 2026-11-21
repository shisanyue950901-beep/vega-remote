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

Describe 'Get-VegaRustDeskDefaults' {
    It '读取 idServer / relayServer / key' {
        $path = Join-Path $TestDrive 'defaults.json'
        $json = @{ rustdesk = @{ idServer = '60.205.95.98'; relayServer = 'relay.example.com'; key = $script:Key } } | ConvertTo-Json
        Set-Content -LiteralPath $path -Value $json -Encoding UTF8

        $defaults = Get-VegaRustDeskDefaults -Path $path
        $defaults.IdServer | Should -Be '60.205.95.98'
        $defaults.RelayServer | Should -Be 'relay.example.com'
        $defaults.Key | Should -Be $script:Key
    }

    It '缺文件、坏 JSON、缺 key 都抛错' {
        { Get-VegaRustDeskDefaults -Path (Join-Path $TestDrive 'missing.json') } | Should -Throw '*缺少默认配置*'

        $bad = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $bad -Value '{ not json' -Encoding UTF8
        { Get-VegaRustDeskDefaults -Path $bad } | Should -Throw '*不是合法 JSON*'

        $noKey = Join-Path $TestDrive 'nokey.json'
        Set-Content -LiteralPath $noKey -Value '{"rustdesk":{"idServer":"1.2.3.4","relayServer":"1.2.3.4"}}' -Encoding UTF8
        { Get-VegaRustDeskDefaults -Path $noKey } | Should -Throw '*key*'
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
    }

    It 'SHA256 不匹配立即中止并删除文件' {
        Mock -ModuleName $script:ModuleName Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec, $UseBasicParsing)
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
        Should -Invoke -ModuleName $script:ModuleName Get-FileHash -Times 1 -Exactly
    }

    It 'SHA256 仍是占位值时不发起下载' {
        Mock -ModuleName $script:ModuleName Invoke-WebRequest { throw '不应被调用' }
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
        Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 0 -Exactly
    }

    It '下载失败最多尝试 2 次并返回非零原因' {
        Mock -ModuleName $script:ModuleName Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec, $UseBasicParsing)
            throw '网络不可用'
        }

        $result = Get-VegaRustDeskInstaller -DestinationDirectory $script:downloadDir -Release $script:release
        $result.Success | Should -BeFalse
        $result.Error | Should -Match '已尝试 2 次'
        $result.Error | Should -Match 'rustdesk\.com/download'
        Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 2 -Exactly
    }

    It '校验通过返回安装包路径' {
        Mock -ModuleName $script:ModuleName Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec, $UseBasicParsing)
            Set-Content -LiteralPath $OutFile -Value 'installer' -Encoding UTF8
        }
        Mock -ModuleName $script:ModuleName Get-FileHash {
            [pscustomobject]@{ Hash = ('a' * 64) }
        }

        $result = Get-VegaRustDeskInstaller -DestinationDirectory $script:downloadDir -Release $script:release
        $result.Success | Should -BeTrue
        $result.Path | Should -Be (Join-Path $script:downloadDir $script:release.FileName)
        Test-Path -LiteralPath $result.Path | Should -BeTrue
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
        Should -Invoke -ModuleName $script:ModuleName Invoke-VegaCommand -Times 1 -Exactly -ParameterFilter {
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

        Mock -ModuleName $script:ModuleName Restart-VegaRustDeskService {
            [pscustomobject]@{ Found = $true; Restarted = $false; Status = 'Running'; Message = 'RustDesk 服务已重启' }
        }
        Mock -ModuleName $script:ModuleName Wait-VegaRustDeskService {
            [pscustomobject]@{ Found = $true; Status = 'Running' }
        }
    }

    It '已安装时跳过下载与安装，只写配置' {
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
        Should -Invoke -ModuleName $script:ModuleName Get-VegaRustDeskInstaller -Times 0 -Exactly
        Should -Invoke -ModuleName $script:ModuleName Install-VegaRustDeskSilently -Times 0 -Exactly

        (Get-Content -LiteralPath $script:userConfig -Raw -Encoding UTF8) | Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'
        (Get-Content -LiteralPath $script:serviceConfig -Raw -Encoding UTF8) | Should -Match 'relay-server = "60\.205\.95\.98:21117"'
        @((Read-VegaState -Path $script:statePath).RustDeskInstalls).Count | Should -Be 0
    }

    It '下载失败返回非零，不写配置' {
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { '' }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstaller {
            [pscustomobject]@{ Success = $false; Path = ''; Sha256 = ''; Error = '下载失败，请到 https://rustdesk.com/download' }
        }
        Mock -ModuleName $script:ModuleName Get-Service { $null }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $script:defaults -HostStatePath $script:statePath `
            -ServiceStatePath $script:serviceStatePath -UserConfigPath $script:userConfig `
            -ServiceConfigPath $script:serviceConfig -DownloadDirectory $script:downloadDir -Confirm:$false

        $result.Success | Should -BeFalse
        $result.ExitCode | Should -Be 1
        $result.Error | Should -Match 'rustdesk\.com/download'
        Test-Path -LiteralPath $script:userConfig | Should -BeFalse
        Test-Path -LiteralPath $script:statePath | Should -BeFalse
    }

    It '哈希不匹配中止安装，不启动安装程序' {
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall { '' }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstaller {
            [pscustomobject]@{ Success = $false; Path = ''; Sha256 = ('b' * 64); Error = '下载的 RustDesk 安装包 SHA256 不匹配，已删除并中止。' }
        }
        Mock -ModuleName $script:ModuleName Install-VegaRustDeskSilently { throw '哈希不匹配时不应安装' }
        Mock -ModuleName $script:ModuleName Get-Service { $null }

        $result = Invoke-VegaRustDeskBootstrap -DefaultsFile $script:defaults -HostStatePath $script:statePath `
            -ServiceStatePath $script:serviceStatePath -UserConfigPath $script:userConfig `
            -ServiceConfigPath $script:serviceConfig -DownloadDirectory $script:downloadDir -Confirm:$false

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'SHA256 不匹配'
        Should -Invoke -ModuleName $script:ModuleName Install-VegaRustDeskSilently -Times 0 -Exactly
    }

    It '未安装时下载、静默安装、写两处配置并记录到 state.json' {
        $global:VegaProbeCount = 0
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstall {
            $global:VegaProbeCount += 1
            if ($global:VegaProbeCount -le 1) { '' } else { 'C:\Program Files\RustDesk\rustdesk.exe' }
        }
        Mock -ModuleName $script:ModuleName Get-VegaRustDeskInstaller {
            [pscustomobject]@{ Success = $true; Path = 'C:\temp\rustdesk.exe'; Sha256 = ('a' * 64); Error = '' }
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
        Should -Invoke -ModuleName $script:ModuleName Install-VegaRustDeskSilently -Times 1 -Exactly

        (Get-Content -LiteralPath $script:userConfig -Raw -Encoding UTF8) | Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'
        (Get-Content -LiteralPath $script:serviceConfig -Raw -Encoding UTF8) | Should -Match 'custom-rendezvous-server = "60\.205\.95\.98"'

        $saved = Read-VegaState -Path $script:statePath
        @($saved.RustDeskInstalls).Count | Should -Be 1
        $saved.RustDeskInstalls[0].InstalledByVega | Should -BeTrue
        $saved.RustDeskInstalls[0].Path | Should -Be 'C:\Program Files\RustDesk\rustdesk.exe'
        @($saved.RustDeskConfigKeys).Count | Should -BeGreaterThan 0
    }
}

Describe 'Invoke-VegaRustDeskRollback' {
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
        Should -Invoke -ModuleName $script:ModuleName Uninstall-VegaRustDeskRecorded -Times 1 -Exactly

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
        Should -Invoke -ModuleName $script:ModuleName Uninstall-VegaRustDeskRecorded -Times 0 -Exactly
        @((Read-VegaState -Path $statePath).RustDeskInstalls).Count | Should -Be 1
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
