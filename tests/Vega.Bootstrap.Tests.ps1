#Requires -Version 5.1
<#
  bootstrap.ps1 的静态单元测试（Pester 5）：
    Release 解析、下载到内存后的 SHA256 校验（-Sha256 优先）、受保护工作目录、
    解压后定位安装脚本、类型化参数传递、管理员检查与下载失败提示。
  所有网络、ACL、解压命令都被 Mock，不会真的下载或安装任何东西。
#>

BeforeAll {
    $script:BootstrapPath = Join-Path (Join-Path $PSScriptRoot '..') 'bootstrap.ps1'
    . $script:BootstrapPath
    $script:ScriptText = Get-Content -LiteralPath $script:BootstrapPath -Raw -Encoding UTF8
}

Describe 'Test-VegaBootstrapSecureUrl' {
    It '只接受 https' {
        Test-VegaBootstrapSecureUrl -Uri 'https://mirror.example.com/vega-remote-0.2.0.zip' | Should -BeTrue
        Test-VegaBootstrapSecureUrl -Uri 'http://mirror.example.com/vega-remote-0.2.0.zip' | Should -BeFalse
        Test-VegaBootstrapSecureUrl -Uri 'ftp://mirror.example.com/x.zip' | Should -BeFalse
        Test-VegaBootstrapSecureUrl -Uri 'https://mirror.example.com/a b.zip' | Should -BeFalse
        Test-VegaBootstrapSecureUrl -Uri '' | Should -BeFalse
    }
}

Describe 'Hide-VegaBootstrapUri' {
    It '去掉 userinfo 与查询参数' {
        Hide-VegaBootstrapUri -Uri 'https://user:secret@example.com/a.zip?token=abc&x=1#frag' |
            Should -Be 'https://example.com/a.zip'
    }

    It '普通地址保持原样' {
        Hide-VegaBootstrapUri -Uri 'https://example.com/a.zip' | Should -Be 'https://example.com/a.zip'
    }
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

Describe 'P2-2 资产文件名取 AbsolutePath 末段' {
    It '镜像 URL 带查询串时资产名不含令牌，校验文件 URL 不带查询串' {
        $release = Get-VegaBootstrapRelease -ZipUrl 'https://mirror.example.com/vega/vega-remote-0.2.0.zip?token=SECRET'
        $release.AssetName | Should -Be 'vega-remote-0.2.0.zip'
        $release.ChecksumUrl | Should -Be 'https://mirror.example.com/vega/SHA256SUMS.txt'
        $release.ChecksumUrl | Should -Not -Match 'SECRET'
    }

    It 'URL 解码后只允许安全字符，错误信息只用脱敏 URL' {
        Get-VegaBootstrapAssetName -Uri 'https://example.com/a%20b.zip' | Should -Be 'a b.zip'

        $record = $null
        try { Get-VegaBootstrapAssetName -Uri 'https://example.com/..%2fevil.zip?token=SECRET' }
        catch { $record = $_ }
        $record | Should -Not -BeNullOrEmpty
        $record.Exception.Message | Should -Match '资产文件名无效'
        $record.Exception.Message | Should -Not -Match 'SECRET'
    }
}

Describe 'Get-VegaBootstrapSha256 / Test-VegaBootstrapChecksum' {
    It '对同一份字节算出稳定摘要' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('payload')
        $hash = Get-VegaBootstrapSha256 -Bytes $bytes
        $hash | Should -Match '^[0-9a-f]{64}$'
        $hash | Should -Be (Get-VegaBootstrapSha256 -Bytes $bytes)
    }

    It '使用校验文件里的同名条目' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('payload')
        $hash = Get-VegaBootstrapSha256 -Bytes $bytes
        $sums = "{0}  vega-remote-0.2.0.zip" -f $hash

        Test-VegaBootstrapChecksum -Bytes $bytes -ChecksumText $sums -AssetName 'vega-remote-0.2.0.zip' | Should -BeTrue
    }

    It '给出 -Sha256 时优先于校验文件（用户独立取得的摘要）' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('payload')
        $hash = Get-VegaBootstrapSha256 -Bytes $bytes
        $wrongSums = ('{0}  vega-remote-0.2.0.zip' -f ('0' * 64))

        Test-VegaBootstrapChecksum -Bytes $bytes -ChecksumText $wrongSums -ExpectedHash $hash -AssetName 'vega-remote-0.2.0.zip' | Should -BeTrue
    }

    It '摘要格式非法时抛异常' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('payload')
        { Test-VegaBootstrapChecksum -Bytes $bytes -ExpectedHash 'not-a-hash' } | Should -Throw '*摘要格式无效*'
    }

    It '哈希不一致时抛异常' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('payload')
        $sums = ('{0}  vega-remote-0.2.0.zip' -f ('0' * 64))
        { Test-VegaBootstrapChecksum -Bytes $bytes -ChecksumText $sums -AssetName 'vega-remote-0.2.0.zip' } |
            Should -Throw '*SHA256 校验失败*'
    }

    It '找不到对应条目时抛异常，不把缺失当通过' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('payload')
        $sums = ('{0}  other.zip' -f ('a' * 64))
        { Test-VegaBootstrapChecksum -Bytes $bytes -ChecksumText $sums -AssetName 'vega-remote-0.2.0.zip' } |
            Should -Throw '*没有*校验值*'
    }
}

Describe 'Get-VegaBootstrapInstallerArgument' {
    It '只透传给出的参数，空字符串不传' {
        $installerArgs = Get-VegaBootstrapInstallerArgument -SkipTailscale -WithRustDesk `
            -RustDeskServer 'relay.example.com' -RustDeskKey ('A' * 43 + '=')
        $installerArgs['SkipTailscale'] | Should -BeTrue
        $installerArgs['WithRustDesk'] | Should -BeTrue
        $installerArgs['RustDeskServer'] | Should -Be 'relay.example.com'
        $installerArgs.ContainsKey('Force') | Should -BeFalse
    }

    It '没有任何密码参数' {
        $installerArgs = Get-VegaBootstrapInstallerArgument -RustDeskServer 'relay.example.com' -RustDeskKey ('A' * 43 + '=')
        @($installerArgs.Keys | Where-Object { $_ -match '(?i)password|passwd|pwd|secret' }).Count | Should -Be 0
    }

    It '不再接受 RemainingArguments 透传' {
        $command = Get-Command Invoke-VegaBootstrap
        $command.Parameters.ContainsKey('RemainingArguments') | Should -BeFalse
        (Get-Command Get-VegaBootstrapInstallerArgument).Parameters.ContainsKey('RemainingArguments') | Should -BeFalse
    }

    It '未知参数由 PowerShell 直接报错' {
        { Invoke-VegaBootstrap -Role 'host' -NotAVegaParameter 1 -SkipAdminCheck -Confirm:$false } |
            Should -Throw '*NotAVegaParameter*'
    }
}

Describe '受保护工作目录' {
    It '在给定根下创建新 GUID 子目录，结束后可删除' {
        $work = New-VegaBootstrapWorkDirectory -Root $TestDrive
        (Split-Path -Leaf $work) | Should -Match '^[0-9a-f]{32}$'
        (Split-Path -Parent $work) | Should -Be $TestDrive
        Test-Path -LiteralPath $work | Should -BeTrue

        Remove-VegaBootstrapWorkDirectory -Path $work
        Test-Path -LiteralPath $work | Should -BeFalse
    }

    It '父目录是重解析点时中止' {
        $parent = Join-Path $TestDrive 'link-parent'
        $null = New-Item -ItemType Directory -Path $parent -Force
        Mock Test-VegaBootstrapReparsePoint { $true }
        { Initialize-VegaBootstrapDirectory -Path (Join-Path $parent 'bootstrap') } | Should -Throw '*重解析点*'
    }

    It '不再使用 %TEMP% 作为工作目录' {
        $script:ScriptText | Should -Not -Match 'env:TEMP'
        $script:ScriptText | Should -Match 'ProgramData'
    }
}

Describe 'P1-1 工作根创建与 ACL 校验' {
    It '创建目录时用 DirectorySecurity 一次应用 ACL（禁用继承）' {
        $script:ScriptText | Should -Match '\[System\.IO\.Directory\]::CreateDirectory\(\$Path, \$security\)'
        $script:ScriptText | Should -Match '\$security\.SetAccessRuleProtection\(\$true, \$false\)'
    }

    It '写类权限掩码覆盖 Write/Delete/改权限/取得所有权' {
        Test-VegaBootstrapWriteRights -Rights ([System.Security.AccessControl.FileSystemRights]::FullControl) | Should -BeTrue
        Test-VegaBootstrapWriteRights -Rights ([System.Security.AccessControl.FileSystemRights]::Delete) | Should -BeTrue
        Test-VegaBootstrapWriteRights -Rights ([System.Security.AccessControl.FileSystemRights]::ChangePermissions) | Should -BeTrue
        Test-VegaBootstrapWriteRights -Rights ([System.Security.AccessControl.FileSystemRights]::TakeOwnership) | Should -BeTrue
        Test-VegaBootstrapWriteRights -Rights ([System.Security.AccessControl.FileSystemRights]::WriteAttributes) | Should -BeTrue
        Test-VegaBootstrapWriteRights -Rights ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute) | Should -BeFalse
    }

    It 'ACL 校验拒绝非管理员写权限与不可信所有者' {
        Mock Test-VegaBootstrapWindows { $true }
        Mock Test-VegaBootstrapReparsePoint { $false }
        Mock Get-Acl {
            [pscustomobject]@{
                Owner  = 'S-1-5-32-544'
                Access = @(
                    [pscustomobject]@{ AccessControlType = 'Allow'; IdentityReference = 'S-1-5-18'; FileSystemRights = [System.Security.AccessControl.FileSystemRights]::FullControl }
                    [pscustomobject]@{ AccessControlType = 'Allow'; IdentityReference = 'S-1-5-32-545'; FileSystemRights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute }
                )
            }
        }
        Test-VegaBootstrapDirectoryAclTrusted -Path $TestDrive | Should -BeTrue

        Mock Get-Acl {
            [pscustomobject]@{
                Owner  = 'S-1-5-32-544'
                Access = @(
                    [pscustomobject]@{ AccessControlType = 'Allow'; IdentityReference = 'S-1-5-32-545'; FileSystemRights = [System.Security.AccessControl.FileSystemRights]::Modify }
                )
            }
        }
        Test-VegaBootstrapDirectoryAclTrusted -Path $TestDrive | Should -BeFalse

        Mock Get-Acl {
            [pscustomobject]@{
                Owner  = 'S-1-5-21-1-2-3-1001'
                Access = @(
                    [pscustomobject]@{ AccessControlType = 'Allow'; IdentityReference = 'S-1-5-18'; FileSystemRights = [System.Security.AccessControl.FileSystemRights]::FullControl }
                )
            }
        }
        Test-VegaBootstrapDirectoryAclTrusted -Path $TestDrive | Should -BeFalse
    }

    It '已存在且 ACL 不可信的 %ProgramData%\Vega 中止并提示修复' {
        $programData = Join-Path $TestDrive 'pd'
        $vegaRoot = Join-Path $programData 'Vega'
        $null = New-Item -ItemType Directory -Path $vegaRoot -Force
        Mock Test-VegaBootstrapReparsePoint { $false }
        Mock Test-VegaBootstrapDirectoryAclTrusted { $false }

        { Initialize-VegaBootstrapProtectedRoot -Path $vegaRoot } | Should -Throw '*请以管理员身份删除或修复该目录后重试*'
    }

    It '%ProgramData% 本身是重解析点时中止' {
        $script:OriginalProgramData = $env:ProgramData
        $env:ProgramData = $TestDrive
        try {
            Mock Test-VegaBootstrapReparsePoint { $true }
            { Initialize-VegaBootstrapVegaRoot } | Should -Throw '*%ProgramData%*重解析点*'
        }
        finally {
            $env:ProgramData = $script:OriginalProgramData
        }
    }

    It '解压后子目录里出现重解析点时中止' {
        $archive = Join-Path $TestDrive 'pkg.zip'
        Set-Content -LiteralPath $archive -Value 'stub' -Encoding UTF8
        $destination = Join-Path $TestDrive 'extract-reparse'
        Mock Expand-Archive { }
        Mock Get-ChildItem {
            [pscustomobject]@{
                FullName   = (Join-Path $TestDrive 'extract-reparse/link')
                Attributes = [System.IO.FileAttributes]::ReparsePoint
            }
        }
        { Expand-VegaBootstrapArchive -ArchivePath $archive -DestinationPath $destination -Role 'host' } |
            Should -Throw '*重解析点*'
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
        Mock New-VegaBootstrapWorkDirectory { Join-Path $TestDrive 'work-1' }
        Mock Remove-VegaBootstrapWorkDirectory { }
        Mock Get-VegaBootstrapByteArray { , [System.Text.Encoding]::UTF8.GetBytes('zip-bytes') }
        Mock Get-VegaBootstrapText { 'unused' }
        Mock Write-VegaBootstrapFile { $Path }
        Mock Test-VegaBootstrapChecksum { $true }
        Mock Expand-VegaBootstrapArchive {
            [pscustomobject]@{ ExtractRoot = (Join-Path $TestDrive 'extract'); Installer = 'C:\vega\host\install-host.ps1' }
        }
        Mock Invoke-VegaBootstrapInstaller { }
    }

    It '下载到内存、校验、写入受保护目录、从受保护目录执行，最后删除工作目录' {
        Invoke-VegaBootstrap -Role 'host' -WorkRoot $TestDrive -SkipTailscale `
            -RustDeskServer 'relay.example.com' -RustDeskKey ('A' * 43 + '=') -Confirm:$false

        Should -Invoke Get-VegaBootstrapByteArray -Times 1 -Exactly
        Should -Invoke Test-VegaBootstrapChecksum -Times 1 -Exactly -ParameterFilter {
            $Bytes.Length -eq [System.Text.Encoding]::UTF8.GetByteCount('zip-bytes') -and $AssetName -eq 'vega-remote-0.2.0.zip'
        }
        Should -Invoke Write-VegaBootstrapFile -Times 1 -Exactly -ParameterFilter {
            $Path -like '*work-1*vega-remote-0.2.0.zip' -and $Bytes.Length -eq [System.Text.Encoding]::UTF8.GetByteCount('zip-bytes')
        }
        Should -Invoke Expand-VegaBootstrapArchive -Times 1 -Exactly -ParameterFilter {
            $ArchivePath -like '*work-1*vega-remote-0.2.0.zip'
        }
        Should -Invoke Invoke-VegaBootstrapInstaller -Times 1 -Exactly -ParameterFilter {
            $Installer -eq 'C:\vega\host\install-host.ps1' -and
            $Arguments['SkipTailscale'] -eq $true -and
            $Arguments['RustDeskServer'] -eq 'relay.example.com'
        }
        Should -Invoke Remove-VegaBootstrapWorkDirectory -Times 1 -Exactly
    }

    It '给出 -Sha256 时不下载同源校验文件' {
        Invoke-VegaBootstrap -Role 'host' -WorkRoot $TestDrive -Sha256 ('a' * 64) -Confirm:$false

        Should -Invoke Get-VegaBootstrapText -Times 0 -Exactly
        Should -Invoke Test-VegaBootstrapChecksum -Times 1 -Exactly -ParameterFilter {
            $ExpectedHash -eq ('a' * 64)
        }
    }

    It '校验失败时抛异常，不调用安装脚本，仍然清理工作目录' {
        Mock Test-VegaBootstrapChecksum { throw 'SHA256 校验失败' }

        { Invoke-VegaBootstrap -Role 'client' -WorkRoot $TestDrive -Confirm:$false } | Should -Throw '*SHA256*'
        Should -Invoke Invoke-VegaBootstrapInstaller -Times 0 -Exactly
        Should -Invoke Remove-VegaBootstrapWorkDirectory -Times 1 -Exactly
    }

    It '-ZipUrl 是 http 时直接拒绝' {
        { Invoke-VegaBootstrap -Role 'host' -ZipUrl 'http://mirror.example.com/x.zip' -WorkRoot $TestDrive -Confirm:$false } |
            Should -Throw '*只接受 https*'
        Should -Invoke Get-VegaBootstrapByteArray -Times 0 -Exactly
    }

    It '显式传入空白 -Sha256 在联网前报错' {
        { Invoke-VegaBootstrap -Role 'host' -Sha256 '   ' -WorkRoot $TestDrive -Confirm:$false } |
            Should -Throw '*不能为空*'
        Should -Invoke Get-VegaBootstrapRelease -Times 0 -Exactly
        Should -Invoke Get-VegaBootstrapByteArray -Times 0 -Exactly
    }

    It '-ApiUrl 不是 https 时在联网前报错' {
        { Invoke-VegaBootstrap -Role 'host' -ApiUrl 'http://api.example.com/latest' -WorkRoot $TestDrive -Confirm:$false } |
            Should -Throw '*ApiUrl 只接受 https*'
        Should -Invoke Get-VegaBootstrapRelease -Times 0 -Exactly
    }

    It '下载最终地址校验使用 RequestMessage.RequestUri' {
        $script:ScriptText | Should -Match 'RequestMessage\.RequestUri'
        $script:ScriptText | Should -Match '下载被重定向到非 https 地址'
    }

    It '非管理员且未跳过检查时拒绝运行' {
        Mock Test-VegaBootstrapAdmin { $false }

        { Invoke-VegaBootstrap -Role 'host' -WorkRoot $TestDrive -Confirm:$false } | Should -Throw '*管理员*'
        Should -Invoke New-VegaBootstrapWorkDirectory -Times 0 -Exactly
    }

    It '未给 Role 时走交互选择' {
        Mock Resolve-VegaBootstrapRole { 'client' }
        Invoke-VegaBootstrap -WorkRoot $TestDrive -Confirm:$false
        Should -Invoke Resolve-VegaBootstrapRole -Times 1 -Exactly
    }
}

Describe '镜像信任边界说明' {
    It '脚本失败提示与 README 都写明只使用可信镜像' {
        $readmePath = Join-Path (Join-Path $PSScriptRoot '..') 'README.md'
        $readmeText = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8

        $script:ScriptText | Should -Match '只使用可信镜像，镜像同时控制 zip 和校验文件'
        $readmeText | Should -Match '只使用可信镜像：镜像同时控制 zip 和校验文件'
        $readmeText | Should -Match '-Sha256'
        $script:ScriptText | Should -Match '\[string\]\$Sha256'
    }
}

Describe 'release.yml 打包与发布引用' {
    BeforeAll {
        $script:ReleasePath = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '.github') 'workflows/release.yml'
        $script:ReleaseText = Get-Content -LiteralPath $script:ReleasePath -Raw -Encoding UTF8
    }

    It '打包步骤有 id，后续步骤引用 package 的输出' {
        $script:ReleaseText | Should -Match '(?m)^\s*id:\s*package\s*$'
        $script:ReleaseText | Should -Match 'steps\.package\.outputs\.archive\b'
        $script:ReleaseText | Should -Match 'steps\.package\.outputs\.archive_name\b'
        $script:ReleaseText | Should -Not -Match 'steps\.version\.outputs\.archive'
    }

    It 'github 上下文值通过 env 传入，脚本内先校验版本格式再使用' {
        $script:ReleaseText | Should -Match 'TAG:\s*\$\{\{\s*github\.ref_name\s*\}\}'
        $script:ReleaseText | Should -Match 'REPOSITORY:\s*\$\{\{\s*github\.repository\s*\}\}'
        $script:ReleaseText | Should -Match ([regex]::Escape('^v(?<ver>\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?)$'))
        $script:ReleaseText | Should -Match ([regex]::Escape('^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$'))

        $runBlocks = [regex]::Matches($script:ReleaseText, '(?ms)^\s*run:\s*\|.*?(?=^\s*-\s+name:|\z)')
        $runBlocks.Count | Should -BeGreaterThan 0
        foreach ($block in $runBlocks) {
            $block.Value | Should -Not -Match '\$\{\{\s*github\.'
        }
    }
}
