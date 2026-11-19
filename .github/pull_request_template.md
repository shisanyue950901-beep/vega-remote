## 改了什么

<!-- 一两句话说明动机和结果 -->

## 影响范围

- [ ] 被控端安装 / 卸载
- [ ] 控制端安装 / 卸载
- [ ] 防火墙 / 状态清单 / 回滚
- [ ] RustDesk 配置
- [ ] 一行安装 / Release
- [ ] 诊断工具
- [ ] 文档 / CI

## 验证

贴实际跑过的命令和关键回显：

```powershell
Invoke-Pester -Path ./tests
Invoke-ScriptAnalyzer -Path ./bootstrap.ps1 -Settings ./PSScriptAnalyzerSettings.psd1
```

- [ ] Pester 通过（PS 5.1 与 PS 7）
- [ ] PSScriptAnalyzer 无 Error/Warning
- [ ] 新增/修改的 `.ps1` / `.psm1` 是 UTF-8 with BOM
- [ ] 没有提交密码、Key、令牌、真实设备码

## 备注

<!-- 破坏性变更、未覆盖的边界、后续任务 -->
