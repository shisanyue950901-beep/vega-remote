# Vega Remote 路线图

## M1 脚本加固（v0.2）
- T1 安装脚本可重复执行、支持 `-Uninstall`、兼容 Windows PowerShell 5.1 与 PowerShell 7
- T1 `vega-doctor.ps1` 一键诊断：显卡与编码器、Sunshine 服务、端口、公网 IPv6、Tailscale 直连/中继、带宽建议
- T1 测试与 CI：Pester 单测、PSScriptAnalyzer、shellcheck、`docker compose config`，GitHub Actions 自动跑
- T2 一行安装：`irm <raw-url> | iex` 引导脚本，GitHub Releases 发布 zip ✅
  - `bootstrap.ps1`：管理员检查、TLS 1.2、latest Release 下载、`SHA256SUMS.txt` 校验、解压并透传参数；`-Role` 交互选择，`-ZipUrl` 支持镜像
  - `.github/workflows/release.yml`：tag `v*` 打包（排除 `tests/`、`.github/`、`work/`）、生成校验文件、创建 Release
  - CI 覆盖 `bootstrap.ps1` 的 PSSA 与 Pester（mock 下载/校验/调用）
- T2 RustDesk 中继自动配置：`-RustDeskServer` / `-RustDeskKey` 或 `vega.config.json`，写 `RustDesk2.toml` 三个键并按键回滚，读设备码，`vega-doctor` 核对指向 ✅
- T2 开箱即用：MIT、零广告、零付费、无强制登录；README 顶部一行安装 ✅
- T2 贡献指南、Issue / PR 模板、SECURITY ✅
- T1-fix8：端口解析对齐上游（注释前空格、1019-65514）、EnforcementStatus 归一化、Profile 覆盖活动接口、旧规则迁移时序、接口排除提示 ✅
- T2-fix2（Codex 审计 r1）：bootstrap 受保护工作目录、设备码只启动已签名副本、服务模式记录进管理员清单、TOML 精确合并、回滚清单只记变化、release 工作流引用与注入、镜像信任边界、类型化参数、凭据脱敏、端口格式中止、串流规则回读执行状态与完整并集、doctor 双配置报告 ✅

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
- Authenticode 发布者绑定：当前只检查 Status=Valid，未绑定 RustDesk 官方发布者身份与证书轮换方式（T2-fix5 总控决定不实现）。
- TOML 完整解析：当前按键定位文本区间，引号键/引号表头/引号点分键直接中止；完整 TOML 解析器留待后续（T2-fix5 总控决定不实现）。
- 待写记录两阶段提交：配置写入与回滚清单之间仍有丢失基线的窗口，需持久化待写记录并在回读后提交（T2-fix5 总控决定不实现）。
- RustDesk 用户配置提权写入的检查-写入竞态：提权进程在“检查路径可信”与“写入文件”之间仍可能被替换；需改为以用户权限写入、或先拿句柄再按句柄写入（T2-fix7 总控决定不实现）。
- 5.1 下载逐跳 HTTPS 校验与 Release API 摘要附件可选：Windows PowerShell 5.1 下 `HttpWebRequest` 的逐跳重定向校验与 Release API 摘要附件仍为可选项，未强制（T2-fix7 总控决定不实现）。
