#Requires -Version 5.1
<#
  RustDesk 部署脚本与 compose 的静态检查（Pester 5）。
  只读仓库里的文件，不执行 docker / ufw / ss。
#>

BeforeAll {
    $root = Join-Path (Join-Path $PSScriptRoot '..') 'server'
    $script:ServerScriptPath = Join-Path $root 'setup-rustdesk-server.sh'
    $script:ComposePath = Join-Path $root 'docker-compose.yml'
    $script:ServerScript = Get-Content -LiteralPath $script:ServerScriptPath -Raw
    $script:Compose = Get-Content -LiteralPath $script:ComposePath -Raw
}

Describe 'RustDesk 部署脚本：只支持全新部署' {
    It '支持 --reinstall，并说明会先 down、保留数据目录与密钥' {
        $script:ServerScript | Should -Match '--reinstall'
        $script:ServerScript | Should -Match '检测到已有 RustDesk 部署'
        $script:ServerScript | Should -Match '会先 compose down，数据目录和密钥保留'
    }

    It '启动前用 compose ps -a 检查项目已有容器' {
        $script:ServerScript | Should -Match 'compose ps -a -q'
        $script:ServerScript | Should -Match 'check_no_existing_deployment'
    }

    It '删除了跨容器重启计数基线与 HAS_PRE_EXISTING 分支' {
        $script:ServerScript | Should -Not -Match 'HAS_PRE_EXISTING'
        $script:ServerScript | Should -Not -Match 'RESTART_BASELINE'
        $script:ServerScript | Should -Not -Match 'record_container_baseline'
    }
}

Describe 'RustDesk 部署脚本：端口与失败清理' {
    It '启动前用 ss -lntup 检查 21115-21119' {
        $script:ServerScript | Should -Match 'ss -lntup'
        $script:ServerScript | Should -Match 'for port in 21115 21116 21117 21118 21119'
    }

    It 'ATTEMPTED 在 compose up 之前置为 true' {
        $attempted = $script:ServerScript.IndexOf('ATTEMPTED=true')
        $up = $script:ServerScript.IndexOf('compose up -d')
        $attempted | Should -BeGreaterThan -1
        $up | Should -BeGreaterThan -1
        $attempted | Should -BeLessThan $up
    }

    It '失败时 compose down 本次新建的容器' {
        $script:ServerScript | Should -Match '清理本次启动的容器'
        $script:ServerScript | Should -Match 'compose down'
    }

    It 'ss 预检只解析本地地址列（第 5 列）末尾的端口' {
        $script:ServerScript | Should -Match 'split\(\$5, parts, ":"\)'
        $script:ServerScript | Should -Not -Match '\$0 ~ \(":" p'
    }

    It '就绪检查按 up 后的容器 ID 采样，RestartCount 必须为 0' {
        $script:ServerScript | Should -Match 'EXPECTED_ID'
        $script:ServerScript | Should -Match 'RestartCount'
        $script:ServerScript | Should -Match '\$restarts" != "0"'
    }
}

Describe 'RustDesk 部署脚本：防火墙只提示不修改' {
    It '不执行任何 ufw allow/deny/delete，也不回滚规则' {
        $script:ServerScript | Should -Not -Match '(?m)^\s*ufw (allow|deny|delete)\b'
        $script:ServerScript | Should -Not -Match 'ADDED_RULES'
        $script:ServerScript | Should -Not -Match 'rollback_rules'
        $script:ServerScript | Should -Not -Match 'ufw_status_has_port_rules'
    }

    It '完成后打印端口清单、ufw 示例与云安全组建议' {
        $script:ServerScript | Should -Match 'print_port_guidance'
        $script:ServerScript | Should -Match 'sudo ufw allow 21115:21117/tcp'
        $script:ServerScript | Should -Match 'sudo ufw allow 21116/udp'
        $script:ServerScript | Should -Match '云安全组建议'
        $script:ServerScript | Should -Match '只放行 TCP \$tcp_list、UDP 21116'
    }

    It '--websocket 只影响提示文字，额外列出 TCP 21118-21119' {
        $script:ServerScript | Should -Match 'sudo ufw allow 21118:21119/tcp'
        $script:ServerScript | Should -Match 'tcp_list="21115-21119"'
        $script:ServerScript | Should -Match '已含 WebSocket'
    }

    It '默认 allow 或 UFW 未启用时警告 WebSocket 暴露并给出安全组最小放行范围' {
        $script:ServerScript | Should -Match '21118/21119（WebSocket）也会对外可达'
        $script:ServerScript | Should -Match '请用云厂商安全组只放行 TCP 21115-21117、UDP 21116'
        $script:ServerScript | Should -Match 'warn_ufw_not_enabled'
        $script:ServerScript | Should -Match 'warn_websocket_reachable'
    }

    It '完成提示直接列出可选 WebSocket 端口，不要求用 --websocket 重跑' {
        $script:ServerScript | Should -Match '可选放行 WebSocket 端口 TCP 21118-21119'
        $script:ServerScript | Should -Match '启用时核对旧拒绝规则和云安全组'
        $script:ServerScript | Should -Match '--reinstall --websocket'
        $script:ServerScript | Should -Not -Match '用 --websocket 重跑'
    }
}

Describe 'docker-compose.yml：host 网络且不发布端口' {
    It 'hbbs 与 hbbr 逐个都是 network_mode: host 且没有 ports' {
        foreach ($service in @('hbbs', 'hbbr')) {
            $match = [regex]::Match($script:Compose, "(?ms)^  $service`:\r?\n(?<block>.*?)(?=^  [a-z]|\z)")
            $match.Success | Should -BeTrue

            $block = $match.Groups['block'].Value
            $block | Should -Match '(?m)^\s+network_mode:\s+host\s*$'
            $block | Should -Not -Match '(?m)^\s+ports:'
            $block | Should -Not -Match '(?m)^\s+published:'
        }
    }
}
