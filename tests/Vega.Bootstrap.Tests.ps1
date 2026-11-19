#Requires -Version 5.1
<#
  bootstrap.ps1 的静态单元测试（Pester 5）：
    Release 解析、SHA256 校验、解压后定位安装脚本、参数透传、管理员检查与下载失败提示。
  所有网络与解压命令都被 Mock，不会真的下载或安装任何东西。
#>

BeforeAll {
    $script:BootstrapPath = Join-Path (Join-Path $PSScriptRoot '..') 'bootstrap.ps1'
    . $script:BootstrapPath
}

Describe 'Resolve-VegaBootstrapRole' {
    It '显式角色直接返回' {
        Resolve-VegaBootstrapRole -Role 'host' | Should -Be 'host'
        Resolve-VegaBootstrapRole -Role 'client' | Should -Be 'client'
    }
}

Describe 'Get-VegaBootstrapRelease' {
    It '-ZipUrl 时从同目录推导 SHA256SUMS.txt，不查询 API' {
        Mock Invoke-RestMethod { }
        $release = Get-VegaBootstrapRelease -ZipUrl 'https://mirror.example.com/vega/vega-remote-0.2.0.zip'
        $release.Version | Should -Be '0.2.0'
        $release.AssetName | Should -Be 'vega-remote-0.2.0.zip'
        $release.ChecksumUrl | Should -Be 'https://mirror.example.com/vega/SHA256SUMS.txt'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It '从最新 Release 里挑选 zip 与 SHA256SUMS.txt' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                tag_name = 'v0.2.0'
                assets   = @(
                    [pscustomobject]@{ name = 'vega-remote-0.2.0.zip'; browser_download_url = 'https://example.com/vega-remote-0.2.0.zip' }
                    [pscustomobject]@{ name = 'SHA256SUMS.txt'; browser_download_url = 'https://example.com/SHA256SUMS.txt' }
                )
            }
        }

        $release = Get-VegaBootstrapRelease -ApiUrl 'https://api.example.com/latest'
        $release.Version | Should -Be '0.2.0'
        $release.ZipUrl | Should -Be 'https://example.com/vega-remote-0.2.0.zip'
        $release.ChecksumUrl | Should -Be 'https://example.com/SHA256SUMS.txt'
    }

    It 'Release 缺少 SHA256SUMS.txt 时拒绝继续' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                tag_name = 'v0.2.0'
                assets   = @([pscustomobject]@{ name = 'vega-remote-0.2.0.zip'; browser_download_url = 'https://example.com/x.zip' })
            }
        }
        { Get-VegaBootstrapRelease -ApiUrl 'https://api.example.com/latest' } | Should -Throw '*SHA256SUMS*'
    }
}

Describe 'Test-VegaBootstrapChecksum' {
    It '匹配 SHA256SUMS.txt 里的文件条目时通过' {
        $zip = Join-Path $TestDrive 'vega-remote-0.2.0.zip'
        Set-Content -LiteralPath $zip -Value 'payload' -Encoding UTF8 -NoNewline
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        $sums = Join-Path $TestDrive 'SHA256SUMS.txt'
        Set-Content -LiteralPath $sums -Value ("{0}  vega-remote-0.2.0.zip" -f $hash) -Encoding UTF8

        Test-VegaBootstrapChecksum -ArchivePath $zip -ChecksumPath $sums | Should -BeTrue
    }

    It '哈希不一致时抛异常' {
        $zip = Join-Path $TestDrive 'vega-remote-0.2.0.zip'
        Set-Content -LiteralPath $zip -Value 'payload' -Encoding UTF8 -NoNewline
        $sums = Join-Path $TestDrive 'bad-sums.txt'
        Set-Content -LiteralPath $sums -Value ('{0}  vega-remote-0.2.0.zip' -f ('0' * 64)) -Encoding UTF8

        { Test-VegaBootstrapChecksum -ArchivePath $zip -ChecksumPath $sums } | Should -Throw '*SHA256 校验失败*'
    }

    It '找不到对应条目时抛异常，不把缺失当通过' {
        $zip = Join-Path $TestDrive 'vega-remote-0.2.0.zip'
        Set-Content -LiteralPath $zip -Value 'payload' -Encoding UTF8 -NoNewline
        $sums = Join-Path $TestDrive 'other-sums.txt'
        Set-Content -LiteralPath $sums -Value ('{0}  other.zip' -f ('a' * 64)) -Encoding UTF8

        { Test-VegaBootstrapChecksum -ArchivePath $zip -ChecksumPath $sums } | Should -Throw '*没有*校验值*'
    }
}

Describe 'Get-VegaBootstrapInstallerArguments' {
    It '只透传给出的参数，空字符串不传' {
        $installerArgs = Get-VegaBootstrapInstallerArguments -SkipTailscale -WithRustDesk `
            -RustDeskServer 'relay.example.com' -RustDeskKey ('A' * 43 + '=')
        $installerArgs['SkipTailscale'] | Should -BeTrue
        $installerArgs['WithRustDesk'] | Should -BeTrue
        $installerArgs['RustDeskServer'] | Should -Be 'relay.example.com'
        $installerArgs.ContainsKey('Force') | Should -BeFalse
    }

    It '没有任何密码参数' {
        $installerArgs = Get-VegaBootstrapInstallerArguments -RustDeskServer 'relay.example.com' -RustDeskKey ('A' * 43 + '=')
        @($installerArgs.Keys | Where-Object { $_ -match '(?i)password|passwd|pwd|secret' }).Count | Should -Be 0
    }
}

Describe 'Invoke-VegaBootstrap' {
    BeforeEach {
        Mock Test-VegaBootstrapAdmin { $true }
        Mock Get-VegaBootstrapRelease {
            [pscustomobject]@{
                Version     = '0.2.0'
                Tag         = 'v0.2.0'
                ZipUrl      = 'https://example.com/vega-remote-0.2.0.zip'
                ChecksumUrl = 'https://example.com/SHA256SUMS.txt'
                AssetName   = 'vega-remote-0.2.0.zip'
            }
        }
        Mock Save-VegaBootstrapFile { }
        Mock Test-VegaBootstrapChecksum { $true }
        Mock Expand-VegaBootstrapArchive {
            [pscustomobject]@{ ExtractRoot = (Join-Path $TestDrive 'extract'); Installer = 'C:\vega\host\install-host.ps1' }
        }
        Mock Invoke-VegaBootstrapInstaller { }
    }

    It '下载、校验、解压后调用 host 安装脚本并透传参数' {
        Invoke-VegaBootstrap -Role 'host' -DownloadDir $TestDrive -SkipTailscale -RustDeskServer 'relay.example.com' -RustDeskKey ('A' * 43 + '=') -Confirm:$false

        Should -Invoke Save-VegaBootstrapFile -Times 2 -Exactly
        Should -Invoke Test-VegaBootstrapChecksum -Times 1 -Exactly
        Should -Invoke Expand-VegaBootstrapArchive -Times 1 -Exactly
        Should -Invoke Invoke-VegaBootstrapInstaller -Times 1 -Exactly -ParameterFilter {
            $Installer -eq 'C:\vega\host\install-host.ps1' -and
            $Arguments['SkipTailscale'] -eq $true -and
            $Arguments['RustDeskServer'] -eq 'relay.example.com'
        }
    }

    It '校验失败时抛异常，不调用安装脚本' {
        Mock Test-VegaBootstrapChecksum { throw 'SHA256 校验失败' }

        { Invoke-VegaBootstrap -Role 'client' -DownloadDir $TestDrive -Confirm:$false } | Should -Throw '*SHA256*'
        Should -Invoke Invoke-VegaBootstrapInstaller -Times 0 -Exactly
    }

    It '非管理员且未跳过检查时拒绝运行' {
        Mock Test-VegaBootstrapAdmin { $false }

        { Invoke-VegaBootstrap -Role 'host' -DownloadDir $TestDrive -Confirm:$false } | Should -Throw '*管理员*'
        Should -Invoke Save-VegaBootstrapFile -Times 0 -Exactly
    }

    It '未给 Role 时走交互选择' {
        Mock Resolve-VegaBootstrapRole { 'client' }
        Invoke-VegaBootstrap -DownloadDir $TestDrive -Confirm:$false
        Should -Invoke Resolve-VegaBootstrapRole -Times 1 -Exactly
    }
}

Describe 'Save-VegaBootstrapFile' {
    It '下载失败时提示 -ZipUrl 镜像' {
        Mock Invoke-WebRequest { throw '连不上' }

        { Save-VegaBootstrapFile -Uri 'https://example.com/x.zip' -Path (Join-Path $TestDrive 'x.zip') } |
            Should -Throw '*-ZipUrl*'
    }
}
