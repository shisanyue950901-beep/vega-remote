# 参与贡献

感谢你愿意改进 Vega Remote。这个项目只做一件事：把开源的远程桌面组件用脚本配好，免费、无广告、无强制登录。

## 开发环境

- Windows 10/11 或 Windows Server 2019+，用于实际运行安装脚本与防火墙逻辑
- Windows PowerShell 5.1 **和** PowerShell 7 都要能跑（脚本必须兼容 5.1）
- [Pester 5.5+](https://pester.dev/)：`Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0 -SkipPublisherCheck`
- [PSScriptAnalyzer 1.21+](https://github.com/PowerShell/PSScriptAnalyzer)：`Install-Module PSScriptAnalyzer -Scope CurrentUser`
- 改 Linux 侧脚本时另需 `shellcheck` 与 `docker compose`

所有 `.ps1` / `.psm1` 必须保存为 **UTF-8 with BOM**；测试里读写文件一律显式 `-Encoding UTF8`。

## 测试命令

```powershell
# 全部 Pester 用例（PowerShell 7 与 Windows PowerShell 5.1 各跑一遍）
$config = New-PesterConfiguration
$config.Run.Path = './tests'
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config

# 静态检查（仓库根与各目录）
Invoke-ScriptAnalyzer -Path ./bootstrap.ps1 -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path ./host -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path ./client -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path ./tools -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

# Linux 侧
shellcheck server/setup-rustdesk-server.sh
bash tests/setup-rustdesk-static.sh
```

CI 会在 Windows 上跑 PSSA、Pester（PS 5.1 + PS 7），在 Linux 上跑 shellcheck、静态断言和 `docker compose config`。提交前本地先跑一遍。

## 提交规范

- 提交信息用中文，前缀标明任务：`t2: 一行安装引导脚本`、`t1-fix8: 端口解析对齐上游`
- 小步提交，一个提交只做一件事；不要混入无关格式化
- 不提交密钥、密码、令牌、真实设备码、日志和个人路径
- 改行为必须同时补/改用例；修 bug 先写能复现的失败用例
- 不 push 到别人的分支，PR 描述里写清动机、改动和验证方式

## 行为准则

参与本项目即表示你同意保持友善、就事论事，不人身攻击、不歧视、不骚扰。
