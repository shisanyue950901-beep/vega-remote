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
- UI 设计稿已完成：`docs/ui/console-design.md`（Tauri 2 + 原生 HTML/CSS/TS）✅
- M2a 控制台骨架（done-in-progress，待 Codex 审计）：
  - `console/` 前端 index.html / styles.css / main.ts，三页静态界面（远程协助 / 我的设备 / 设置）全部控件 + 占位数据
  - 窗口 960×640、最小 860×580、自绘标题栏、左栏 200px、主色 #2F6BFF、圆角 10px、浅色 + `prefers-color-scheme` 深色
  - `console/src-tauri/`：Tauri 2、系统托盘（显示主窗口 / 复制设备码 / 断开当前会话 / 退出，后两项为 M2b 桩）、最小权限 capability、占位图标
  - 零网络请求、零遥测；`.github/workflows/console.yml` 在 `console/**` 变更时跑 Windows `tauri build --no-bundle`
- M2b 控制台接入 RustDesk（done-in-progress，待 Codex 审计）：
  - Rust 侧拆出 `console/src-tauri/src/rustdesk.rs`：定位 `rustdesk.exe`（Program Files → PATH）、
    `--get-id`（总 deadline 5 秒、`CREATE_NO_WINDOW`、stderr 丢弃、stdout 重定向到本次独占的临时文件并轮询
    `try_wait`、超时 kill、只回读前 4 KB 后删文件、3-3-3 / 3-3-4 展示）、`RustDesk2.toml [options]`
    用 toml crate **只读**解析（公钥只露前 8 位指纹、不写日志、不回写文件）
  - `connect_peer` 校验 9-10 位数字后 `--connect` / `--file-transfer`，最近 10 条存 app config 目录 JSON；
    临时密码不读不传，「显示临时密码」只无参启动 RustDesk 主窗口，界面去掉假的掩码密码
  - RustDesk 进程/服务状态行；未安装时不再在应用内提权安装（无 runas、无捆绑脚本），
    WinGet 下架 RustDesk 后改为按钮「打开 RustDesk 官方下载页」（URL 写死在 Rust 侧，
    `explorer.exe <url>` 交给默认浏览器）；「允许远程协助」开关禁用并指向 RustDesk
  - Vega 对 RustDesk 网络配置改为**只读**：删除写入命令、配置合并、跨进程文件锁与服务模式判定，
    设置页只显示 `RustDesk2.toml` 当前 ID/中继与公钥指纹，保留 TCP `server:21116` 测试，
    并提示「服务器地址请在 RustDesk 的 设置 → 网络 中修改」，按钮「在 RustDesk 中修改」打开 RustDesk 主窗口
  - 两个页面的连通性探测都带「被测地址 + 单调代次」：地址变更或重读配置后，在途探测的回包直接丢弃；
    审计 r2/r3/r4 的 P2/P3（设备码分组与往返测试、托盘 worker、get-id 超时不再有读线程、
    服务查询与可移植版覆盖配置）随只读化一并消除
  - 前端 `main.ts` 全部占位换成 invoke：加载/错误状态、最近设备码下拉（3-3-3 / 3-3-4）、设置页网络读取/保存/测试
    （测试 = Rust 侧 TCP connect `server:21116` 超时 3 秒）
  - `build.rs` 用 `AppManifest::commands` 声明全部命令，`capabilities/default.json` 授权 `allow-*`
    （修复 M2a 审计 r2 P3，含 `set_close_to_tray`）；Rust 纯函数带 `#[cfg(test)]` 单测
- M2a 审计 r2 遗留修复：串流页配对输入框默认隐藏、打开配对后才显示且改 4 位 PIN；CI Node 24；
  `icon.ico` 离线无法重生成，保留占位并在 `icons/README.md` 记录待办
- M2c 高性能串流页与设置页诊断（已完成）：
  - `scm.rs`：`OpenSCManagerW`/`OpenServiceW`/`QueryServiceStatusEx` 四分类（运行中/已停止/未安装/无法查询），
    Sunshine 与 RustDesk 服务检测共用；只有 `ERROR_SERVICE_DOES_NOT_EXIST` 算未安装（审计 r5 P3）
  - `streaming.rs`：Sunshine 状态；DXGI `EnumAdapters1` 只读显卡列表（跳过软件适配器，按厂商/显存标核显独显与
    NVENC/AMF/QSV）；Moonlight 安装检测（canonicalize 后必须在系统盘 Program Files 下）与无参启动；
    「打开配对」/「打开 Sunshine 设置」用写死的 `https://localhost:47990`；安装按钮只复制 README 一行安装命令
  - `doctor.rs`：8 秒总预算的 `run_doctor`（RustDesk、ID 服务器 TCP、Sunshine 服务、47990、公网 IPv6、
    Tailscale、Moonlight），以及 `export_doctor_log`（app 版本 + Windows build，IPv4/IPv6/主机名/用户目录脱敏，
    写 `%LOCALAPPDATA%\Vega\logs` 并打开目录）；状态映射与脱敏有单测
  - 前端：串流页去掉假主机列表与内置 PIN 输入，改为真实状态/显卡/固定入口；设置页 doctor 与「诊断网络」跳转；
    Assist/Settings 共用一份配置快照并在 focus 时重查设备码与安装状态；设置页探测复位结果并恢复按钮
  - 旧清单 `RustDesk.RustDesk` 包按已下线处理：提示手动卸载、销账后继续回滚；host/client 各有 Pester 覆盖
- 安装包冒烟测试仍延后：CI 继续只跑 `tauri build --no-bundle`，待总控另行安排

## M3 进阶（v1.0）
- 虚拟显示器自动安装（无显示器被控端）
- 多设备管理面板、RustDesk 中继一键迁移国内 VPS
- 英文文档

## Backlog（M2b 审计 r3/r4 未做项）
- P3：CI 只跑 `tauri build --no-bundle`，没有安装包冒烟测试；需要 Windows bundle 冒烟并监听 `host/**`/`console/**` 资源变更。
  本轮 r3/r4 只记录待办、不新增安装包测试（按总控要求）。
- RustDesk 改为手动安装（2026-03 起 WinGet 社区源移除 RustDesk）：控制台与 host 脚本都不再调用 winget 安装，
  只给出官方下载页 `https://github.com/rustdesk/rustdesk/releases/latest`；已安装的 RustDesk 仍应用中继配置。
  是否要在安装包冒烟测试里一并验证「未安装 RustDesk 时只显示下载页按钮」留待 M2c。

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

### M2c r4 遗留（Codex m2c-r4 PASS，2026-11-20）
- P2 焦点刷新在配置读取中被丢弃 → 排队一次补读并同步两个视图（main.ts:104）
- P2 诊断入口竞态：串流页快捷入口可二次启动；过期导出回包覆盖新快照（main.ts:658/709）
- P2 超时后排队的 doctor 任务仍可能启动并占闸门（doctor.rs:297/321）
- P2 同卷 junction 可让 Program Files 根被重定向（winpaths.rs:44/149）
- P3 脱敏测试依赖运行者 USERNAME，改为显式身份夹具（doctor.rs:640/906）
