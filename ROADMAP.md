# Vega Remote 路线图

## M1 脚本加固（v0.2）
- T1 安装脚本可重复执行、支持 `-Uninstall`、兼容 Windows PowerShell 5.1 与 PowerShell 7
- T1 `vega-doctor.ps1` 一键诊断：显卡与编码器、Sunshine 服务、端口、公网 IPv6、Tailscale 直连/中继、带宽建议
- T1 测试与 CI：Pester 单测、PSScriptAnalyzer、shellcheck、`docker compose config`，GitHub Actions 自动跑
- T2 一行安装：`irm <raw-url> | iex` 引导脚本，GitHub Releases 发布 zip
- T2 贡献指南、Issue / PR 模板

## M2 Vega 控制台（v0.5，图形界面）
- 一个窗口完成：安装组件、检测显卡、显示连接地址、配对、诊断
- UI 设计先出稿，确认后再实现（Tauri，体积小）

## M3 进阶（v1.0）
- 虚拟显示器自动安装（无显示器被控端）
- 多设备管理面板、RustDesk 中继一键迁移国内 VPS
- 英文文档

## 团队分工
- 规划、任务单、UI 设计、验收：Hark
- 编码：DeepSeek 执行层
- 代码审计：Codex

## Backlog（T1-fix6 复审遗留，暂不实现）
- RustDesk 部署并发锁：从检查已有部署到失败清理全程串行化，并按本次创建的容器 ID 清理。
- 旧版状态清单的受管配置键大小写：新快照记录键名大小写，旧清单无法确定原始拼写时提示人工核对。
