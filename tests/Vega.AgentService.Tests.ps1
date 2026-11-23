#Requires -Version 5.1
<#
  t8b 安装器 / CI 接入 vega-agent 的静态测试（Pester 5）。
  只读仓库文件，不运行安装器、不启停服务、不写 ProgramData。
#>

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..'
    $script:HooksText = Get-Content -LiteralPath (Join-Path $repoRoot 'console/src-tauri/windows/hooks.nsh') -Raw -Encoding UTF8
    $script:Conf = Get-Content -LiteralPath (Join-Path $repoRoot 'console/src-tauri/tauri.conf.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:GitignoreText = Get-Content -LiteralPath (Join-Path $repoRoot '.gitignore') -Raw -Encoding UTF8
    $script:ConsoleWorkflowText = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/console.yml') -Raw -Encoding UTF8
}

Describe 't8b 安装器注册 VegaAgent 服务' {
    It '服务名固定为 VegaAgent，显示名为「Vega 访问码服务」' {
        $script:HooksText | Should -Match '!define VEGA_AGENT_SERVICE "VegaAgent"'
        $script:HooksText | Should -Match '!define VEGA_AGENT_DISPLAY "Vega 访问码服务"'
    }

    It '安装时创建或修复服务并设置自动启动 / LocalSystem / 失败重启' {
        $script:HooksText | Should -Match 'sc\.exe" create \$\{VEGA_AGENT_SERVICE\} binPath='
        $script:HooksText | Should -Match 'sc\.exe" config \$\{VEGA_AGENT_SERVICE\} binPath='
        $script:HooksText | Should -Match 'start= auto obj= LocalSystem DisplayName= "\$\{VEGA_AGENT_DISPLAY\}"'
        $script:HooksText | Should -Match 'sc\.exe" failure \$\{VEGA_AGENT_SERVICE\} reset= 86400 actions= restart/5000/restart/5000//'
        $script:HooksText | Should -Match 'sc\.exe" description \$\{VEGA_AGENT_SERVICE\}'
        $script:HooksText | Should -Match 'sc\.exe" start \$\{VEGA_AGENT_SERVICE\}'
    }

    It 'binPath 指向 $INSTDIR\resources\vega-agent.exe' {
        $script:HooksText | Should -Match ([regex]::Escape('binPath= "\"$INSTDIR\resources\vega-agent.exe\""'))
    }

    It '升级前先停服务，安装服务在 RustDesk 安装/回填之后' {
        $preinstall = $script:HooksText.Substring($script:HooksText.IndexOf('!macro NSIS_HOOK_PREINSTALL'))
        $preinstall.IndexOf('!insertmacro VegaStopAgentService') | Should -BeGreaterThan -1

        $postinstall = $script:HooksText.Substring($script:HooksText.IndexOf('!macro NSIS_HOOK_POSTINSTALL'))
        $rustdesk = $postinstall.IndexOf('!insertmacro VegaRunInstallRustDesk')
        $agent = $postinstall.IndexOf('!insertmacro VegaInstallAgentService')
        $rustdesk | Should -BeGreaterThan -1
        $agent | Should -BeGreaterThan $rustdesk
    }

    It 'sc 失败只写 setup.log，不中断安装' {
        $script:HooksText | Should -Match 'sc create \$\{VEGA_AGENT_SERVICE\} exit code: \$0'
        $script:HooksText | Should -Match 'sc config \$\{VEGA_AGENT_SERVICE\} exit code: \$0'
        $script:HooksText | Should -Match 'sc failure \$\{VEGA_AGENT_SERVICE\} exit code: \$0'
        $script:HooksText | Should -Match 'sc start \$\{VEGA_AGENT_SERVICE\} exit code: \$0'
        $script:HooksText | Should -Match 'VegaAppendSetupLog agent_start_fail_'
        # 安装/升级路径上不得因为 sc 失败 Abort。
        $installMacro = $script:HooksText.Substring($script:HooksText.IndexOf('!macro VegaInstallAgentService'))
        $installMacro.Substring(0, $installMacro.IndexOf('!macroend')) | Should -Not -Match '(?m)^\s*Abort\b'
    }
}

Describe 't8b 卸载器移除 VegaAgent 服务' {
    It '卸载时 stop + delete 服务并删除 ProgramData\Vega\agent' {
        $script:HooksText | Should -Match 'sc\.exe" stop \$\{VEGA_AGENT_SERVICE\}'
        $script:HooksText | Should -Match 'sc\.exe" delete \$\{VEGA_AGENT_SERVICE\}'
        $script:HooksText | Should -Match ([regex]::Escape('RMDir /r "$COMMONPROGRAMDATA\Vega\agent"'))
    }

    It '卸载时把 RustDesk 验证方式恢复为 use-both-passwords，失败忽略' {
        $script:HooksText | Should -Match ([regex]::Escape('--option verification-method use-both-passwords'))
        $script:HooksText | Should -Match 'rustdesk restore verification-method exit code:'
    }

    It '/UPDATE 只换程序文件，不停删服务' {
        $script:HooksText | Should -Match 'StrCmp \$UpdateMode "1" vega_agent_remove_done_'
    }
}

Describe 't8b Tauri 资源与 CI 打包' {
    It 'tauri.conf.json 打包 vega-agent.exe 且不再打包 vega-pwhelper.ps1' {
        $resources = $script:Conf.bundle.resources
        $resources.'resources/vega-agent.exe' | Should -Be 'resources/vega-agent.exe'
        @($resources.PSObject.Properties.Name) | Should -Not -Contain 'resources/vega-pwhelper.ps1'
    }

    It '.gitignore 忽略 CI 复制到 resources 的 vega-agent.exe' {
        $script:GitignoreText | Should -Match ([regex]::Escape('console/src-tauri/resources/vega-agent.exe'))
    }

    It 'console.yml 在 tauri build 前编译并复制 vega-agent.exe，并运行其测试' {
        $script:ConsoleWorkflowText | Should -Match ([regex]::Escape('"agent/**"'))
        $script:ConsoleWorkflowText | Should -Match 'cargo build --release'
        $script:ConsoleWorkflowText | Should -Match ([regex]::Escape('../agent/Cargo.toml'))
        $script:ConsoleWorkflowText | Should -Match ([regex]::Escape('cp ../agent/target/release/vega-agent.exe src-tauri/resources/vega-agent.exe'))
        $script:ConsoleWorkflowText | Should -Match ([regex]::Escape('cargo test --manifest-path ../agent/Cargo.toml'))
    }
}
