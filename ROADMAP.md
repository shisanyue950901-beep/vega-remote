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
- T4d 长期密码（设置页）：
  - Rust 后端 `password.rs`：密码只经 DACL 收紧的临时文件交给一次性提权的助手；校验 8~64 位且含字母和数字，
    验证方式映射 temporary/permanent/both；状态只回答「是否已设置」与 `verification-method`，不读密码内容
  - 助手 `console/src-tauri/resources/vega-pwhelper.ps1`（随包 resources，`-Mode set|clear`）：点源可测，
    读后立即用同长度空白覆盖并删除载荷，用官方 `rustdesk.exe --password` 设密码、`--option verification-method`
    写验证方式；清除时设 32 位随机密码并把验证方式改回临时密码；退出码 0/非 0，stderr 只写脱敏原因
  - 测试：`password.rs` 单测覆盖密码规则/验证方式映射/icacls 参数；`tests/vega-pwhelper.Tests.ps1` 覆盖参数校验、
    读后删除、密码规则与「失败摘要不含密码」；风险与取舍见 `SECURITY.md`「长期密码」
- 安装包冒烟测试仍延后：M2c 阶段 CI 只跑 `tauri build --no-bundle`；T3 起改为产出 `Vega-Setup.exe`，真机检查项见 `docs/testing/windows-smoke.md`

## T3 一键安装包（v0.6，Vega-Setup.exe）
- 打包：`console/src-tauri/tauri.conf.json` 的 `bundle.targets` 改为 `["nsis"]`，`installMode = "perMachine"`（启动时 UAC 提权一次），
  `languages = ["SimpChinese"]`、`displayLanguageSelector = false`；CI 重命名为 `Vega-Setup.exe` 并上传 artifact `vega-setup-windows` ✅
- 默认中继：`console/src-tauri/resources/vega-defaults.json`（公开信息，可入库）随安装包作为 resources 打入；
  host 脚本与 `Vega.Common.psm1` 也随包打成 `resources\host\`。fork 者改这个 JSON 即可换成自己的服务器 ✅
- NSIS 钩子：`console/src-tauri/windows/hooks.nsh` 的 `NSIS_HOOK_POSTINSTALL` 隐藏窗口跑 `install-rustdesk.ps1`，
  退出码写 `%ProgramData%\Vega\logs\setup.log`；脚本失败不阻断安装，只在完成时提示到 Vega 手动安装；
  `NSIS_HOOK_PREUNINSTALL` 调 `-Uninstall` 按 state.json 回滚 ✅
- `host/install-rustdesk.ps1`：AGPL 约束下不打包 RustDesk 二进制，固定官方 GitHub Release 版本下载并校验 SHA256
  （1.5.3 的官方摘要已固定为 `523ba0ef…ed249`），整个下载共用一个 120 秒截止时间、最多 2 次尝试，只接受 HTTPS；
  已装跳过、`--silent-install`、有界 60 秒等服务达到 Running；复用 T2 的 `RustDesk2.toml` ACL/原子写入逻辑，
  由 NSIS 钩子解析当前登录交互用户（explorer.exe 所有者 / 活动会话用户）的 SID 与 Roaming AppData，
  以 ASCII Base64(UTF-8) 传入脚本（t3-fix4，避免中文路径经 nsExec ANSI 解码损坏），解码后校验目录存在，
  同时写用户级与服务级配置；用户级写失败时继续写服务级并以退出码 2 标记降级，完成页提示手动处理。
  已有安装的识别同时看默认 Program Files 布局、Registry64/Registry32 卸载项的 InstallLocation /
  DisplayIcon 与服务 ImagePath（t3-fix4），自定义目录命中只配置、不重装。
  该用户的 SID / AppData / 路径与是否已写入记进 `state.json`，回滚按记录路径校验；
  新装时才在 host-state.json 记录安装归属并只卸载本次安装的 RustDesk ✅
- 架构决策更新：旧「不做应用内提权」改为「安装包启动时 UAC 提权一次」；Vega 控制台运行时仍不提权，
  对 RustDesk 网络配置仍只读，设置页新增只读的「默认中继」比对提示 ✅
- 测试：`tests/Vega.InstallRustDesk.Tests.ps1` 覆盖真实 SHA256 校验、哈希不匹配中止、已安装跳过、下载失败非零、
  TLS 1.2 与仅 HTTPS、非 Nullable 的下载截止时间、用户级+服务级双写与取不到交互用户时的降级、
  有界 60 秒服务就绪、state.json 记录与按记录路径回滚，以及安装包钩子的静态约束
  （Sysnative PowerShell、icacls 绝对路径、回滚重试脚本保留）✅
- t3-fix3（Codex 审计 t3-r2，架构师裁剪范围）：下载截止时间改 `[datetime]`；WOW64 下钩子用
  `Sysnative\WindowsPowerShell` 并双看 ProgramW6432/ProgramFiles 与注册表 64/32 视图；icacls 绝对路径并检查
  退出码；交互用户 SID/Roaming AppData 传入脚本并双写用户级/服务级；有界 60 秒等 Running；
  卸载 30 秒确认 EXE 与服务消失；回滚失败保留重试脚本；`.logs-link` 移出版本控制；
  公网探测拒绝 127/8、0/8、100.64/10、224/4 及以上与前导零 ✅
- t3-fix4（Codex 审计 t3-r3）：交互用户 SID/AppData 改用 ASCII Base64 在 NSIS 与脚本间传递，脚本解码后
  校验路径存在；用户级写失败继续写服务级并在结果/退出码标记降级；已有 RustDesk 显式读 Registry64/32
  Uninstall 的 InstallLocation / DisplayIcon 与服务 ImagePath，命中即只配置不重装；icacls 失败时钩子传
  `-NoFileLog` 且脚本支持；ip-detect 路由回退结果分类（CGNAT/回环/链路本地/组播丢弃，RFC1918 保留带警告）；
  共享写配置函数注释更新为当前流程 ✅
- t3-fix5（Codex 审计 t3-r4）：注册表 InstallLocation / DisplayIcon / 服务 ImagePath 按字段分别解析，
  含空格的安装目录（如 `C:\Program Files\RustDesk`、`D:\Remote Tools\RustDesk`）完整保留，不再按空白截断；
  `Set-VegaRustDeskConfig` 的路径校验/读取/合并/写入/回读全部进入每个目标的 try，用户级读取或写入失败只降级
  并继续写服务级；`install-rustdesk.ps1` 用 `PSBoundParameters` 区分钩子显式传空上下文与省略参数；
  `detect_public_ip` 逐来源分类，discard 后继续下一个来源，并丢弃 198.18/15 与本机文档网段
  192.0.2/24、198.51.100/24、203.0.113/24；降级退出码在模块与入口统一为 2 ✅
- t3-fix6（Codex 审计 t3-r5）：RustDesk 配置的读取/回读/回滚全部显式 `-ErrorAction Stop`，读失败（拒绝访问/
  共享冲突）直接终止该目标，不再把读不到的文件当空配置，也不写用户回滚基线；已有安装区分服务状态：
  已注册但停止用 `Start-Service` 启动并在 60s 内等 Running，未注册则不注册服务、只写用户级配置并回读，
  服务级跳过、结果降级（退出码 2）并提示在 RustDesk 里启用服务；`DisplayIcon` 兼容引号内外的 `,N` 图标索引，
  注册表探测支持注入原始字段值供测试；`hostname -I` 逐个地址分类；测试恢复 UTF-8 BOM，含空格路径改用
  `$TestDrive`，修正 `$PSScriptRoot` 引用并补入口子进程与真实文件锁测试 ✅

## Backlog（T3 记录）
- `server/setup-rustdesk-server.sh` 的 `detect_public_ip` 在阿里云回落成 VPC 内网 IP：探测逻辑移到
  `server/lib/ip-detect.sh`，按 IMDSv2（先 `PUT /latest/api/token`）查 `eipv4`，元数据请求 `--noproxy '*'`，
  只采用成功且通过 IPv4 正则的公网地址，RFC1918 结果打印警告 ✅ 已修（T3）
- `Get-VegaRustDeskRelease` 的 SHA256 已固定为 RustDesk 1.5.3 官方资产摘要；升级版本时必须同步更新
  版本号、文件名与摘要，否则安装包会走「RustDesk 未装好」提示分支（这是有意的安全默认值）。

## Backlog「T3 加固」（t3-fix3 架构师裁剪、t3-fix4 审计后仍未做项，按原审计编号保留）
- P2（t3-r3）服务就绪尾段缺口：新装/已装分支都等待 Running，但写配置期间服务若停止或消失，重启函数会跳过，
  安装仍返回成功。应让重启与最终状态检查共享同一个有界等待，返回成功前再次确认 Running。
- P2（t3-r3）用户回滚基线仍按路径存储：`state.json` 只有一个可覆盖的 SID/路径对象，真正的键基线没有 SID；
  换账户卸载会用新账户路径校验旧账户记录并拒绝恢复。应按安装时的 SID 持久化各自基线并按该记录恢复；
  解析时按安装器会话筛选 Explorer，缺失可靠 SID/AppData 时走服务级降级。
- P2（t3-r3）卸载 30 秒确认仍可能被提前跳过：官方 `--uninstall` 会先结束自身，Vega 遇到非 0/3010 立即返回，
  未进入轮询；重试时卸载项已消失也无法凭 EXE 与服务均已消失销账。应对已启动的官方卸载按最终状态判定，
  并识别已经清理完毕的重试。
- P2（t3-r3）重试副本命令在原生 64 位终端不可直接运行：提示复用 32 位安装器选择的 `Sysnative`，且未检查
  复制是否成功。应验证脚本与依赖都已保留，并给出管理员 64 位终端可用的 `System32` 命令。
- P1-3 下载目录信任：只检查直接父目录的所有者/重解析属性，没有校验整条目录链 DACL 与祖先路径；
  随机子目录创建后才收紧 ACL，SHA256 校验完成后才拿禁止写入/删除的句柄。应验证整条链、创建目录时
  即指定安全描述符，并在同一个受保护句柄上算 SHA256、持有到进程启动。
- P1-7 安装归属与清单并发：首次读写归属清单仍发生在 RustDesk 已安装之后；清单不可读或保存失败时
  重跑会走「已安装」分支而补不回归属。安装前应持久化可恢复的待办记录，安装后按已验证的产品身份提交，
  所有机器级清单写入方共用同一把锁（T3 与提权 client 入口当前用不同互斥体）。
- P2 下载总时限与 TLS：`ReadWriteTimeout` 只在发请求前设一次，最后一次阻塞读可能越过 120 秒截止时间；
  钩子本身没有独立总时限。应改用单调时钟 + 可取消的请求与响应体读取。TLS 测试还需覆盖保留
  `SystemDefault` 的情况（当前按位加入 TLS 1.2 会把系统协商收窄为仅 TLS 1.2）。
- P2（t3-fix6 审计 t3-r6）子进程测试绕过真实入口：`install-rustdesk.ps1` 的两条成功路径由测试脚本自行选
  `-ServiceOnly` 并直接调模块，捕获不到入口对显式空值、参数省略、退出码透传的回归。应让 Windows 子进程执行
  实际入口，分别断言退出码与两处配置文件的状态。
- P2（t3-fix6 审计 t3-r6）真实文件锁用例缺少卸载断言：测试把旧中继键放在 TOML 顶层，RustDesk 的受管键位于
  `[options]`。应使用实际配置结构，在解锁后执行回滚并确认旧值仍在。
- P2 服务回滚后重载：保留已有 RustDesk 时，回滚只改文件，未让运行中的服务加载恢复值；应重载或受控重启
  原服务并确认恢复生效后才销账。
- P2 设置页地址与公钥比较：同一 IPv6 地址的裸地址与方括号形式会生成不同字符串，公钥摘要只取前八个字符；
  应统一解析 IP+端口，并用完整公钥摘要参与比较，同时对无效公钥显示配置错误。
- P2 CI 安装包实测：仍未在 Windows CI 对产出的 `Vega-Setup.exe` 验证钩子位数、静默退出码、两处配置写入
  与卸载回滚；`server/lib/ip-detect.sh` 也尚未纳入 shellcheck 步骤。

## Backlog「T4 加固」（t4-fix1 / t4-fix2 记录）
- P2 设备记录的跨实例一致性：`peers.rs` 的连接/改名/删除仍是「读-改-写」两步文件操作，
  单文件原子替换保护不了两个 Vega 实例同时更新的场景。本轮已让删除与改名/清除别名都先严格读取
  （任一读取/解析失败即报错、不写盘、不做任何删除），但「别名 + recent」两文件仍缺失败恢复与跨实例锁：
  应让三条路径共用一把跨进程文件锁，并让 recent 写失败时能回滚已提交的别名。
- P2 载荷文件的身份校验：助手打开前只校验文件名与末级路径属性，约束不了父目录重解析点、硬链接
  和「检查后替换」。应在同一受限句柄上核验最终目录、文件标识（FileId）、链接数与所有者，
  不符即退 10 且不写 RustDesk。
- P2 验证方式的服务侧确认：CLI 回读读到的可能是 CLI 账户本地配置而非服务实际值。应补一次服务侧
  确认（IPC/受管配置），无法确认时返回「部分成功 / 结果未知」而不是 0；本轮只加了「服务必须
  Running」的前置检查（未运行退 12），仍不能证明服务端已生效。
- P2 长期密码状态：已改为读助手成功后写的 `pw-state.json`（`has_permanent`）并区分清除时写入的
  随机替代值；验证方式仍读当前用户侧 `RustDesk2.toml`，因此可能与服务实际生效值不一致——等
  「服务侧确认」落地后一并改为读实际生效值。
- P2 集成测试缺口：真实 Windows DACL 生效验证、跨账户 UAC（标准用户 → 管理员）、助手 20 s 调用
  超时清理、PS 5.1 原生参数传递目前都靠 Mock 覆盖，需要在集成环境里跑一次真机用例。
- P1 安装目录 ACL：安装器应对安装目录强制设置标准 ACL（或控制台发行版校验助手及其父目录不向
  Users / Authenticated Users / Everyone 授予写权限），否则装进被放宽权限的已有目录时助手可被替换。
  来源：Codex t4-r4 P1。

## M3 进阶（v1.0）
- 虚拟显示器自动安装（无显示器被控端）
- 多设备管理面板、RustDesk 中继一键迁移国内 VPS
- 英文文档

## Backlog（M2b 审计 r3/r4 未做项）
- P3：CI 只跑 `tauri build --no-bundle`，没有安装包冒烟测试；需要 Windows bundle 冒烟并监听 `host/**`/`console/**` 资源变更。
  本轮 r3/r4 只记录待办、不新增安装包测试（按总控要求）。
  T3 已完成构建 `Vega-Setup.exe` 并监听 `host/**`，自动化安装冒烟仍未做。
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

### M2c r4 遗留（Codex m2c-r4 PASS，2026-11-20；m2c-fix4 已修）
- P2 焦点刷新在配置读取中被丢弃 → 排队一次补读并同步两个视图 ✅ 已修（main.ts:104）：
  读取中的焦点事件记「待补读」标志，本轮结束后再读一次并把最新快照应用到远程协助页与设置页
- P2 诊断入口竞态：串流页快捷入口可二次启动；过期导出回包覆盖新快照 ✅ 已修（main.ts:658/709）：
  两个入口共用 running 标志，运行中再次触发直接忽略；导出携带发起时 snapshot_id，回包时快照已变则整包丢弃
- P2 超时后排队的 doctor 任务仍可能启动并占闸门 ✅ 已修（doctor.rs:297/321）：
  deadline 为绝对 Instant，超时对 spawn_blocking 任务置 Arc<AtomicBool> 取消标志，worker 开始前与每个探测前检查
- P2 同卷 junction 可让 Program Files 根被重定向 ✅ 已修（winpaths.rs:44/149）：
  根必须等于 `<系统盘根>\Program Files[(x86)]`（GetSystemDirectoryW 卷根、大小写不敏感）、根自身非重解析点、
  最终 exe 规范化后仍在根内且 GetVolumePathNameW 卷根与系统卷一致，并补纯函数单测
- P3 脱敏测试依赖运行者 USERNAME，改为显式身份夹具 ✅ 已修（doctor.rs:640/906）：
  脱敏接收 RedactionIdentity（用户名/计算机名/域/主目录），环境变量只在生产入口 export_blocking 读一次

### M2c r6 遗留（Codex m2c-r6 PASS，2026-11-20）
- P2 DNS 探测用相对预算重建 deadline，零剩余仍会起解析线程（rustdesk.rs:1037）→ 透传原 deadline 与取消标志
- P2 超时的导出仍可能写文件并打开目录（doctor.rs:837/908）→ timeout_at + 写前查过期
- P2 同一秒导出互相覆盖（doctor.rs:880）→ 唯一后缀 + create_new
- P3 已知文件夹失败时回落到 temp（doctor.rs:823）→ 返回通用错误
- P3 ShellExecuteW 在未初始化 COM 的 worker 上（winpaths.rs:162）→ STA 线程 + CoInitializeEx

## M2c r7 遗留（Codex m2c-r7 PASS）
- **P2 — Doctor lost the three-second RustDesk probe limit.** DNS and TCP can consume the full eight-second doctor budget, preventing later checks from running and leaving no exportable snapshot. Use the earlier of the original doctor deadline and a three-second probe deadline. 
- **P2 — DNS can still start after expiry.** The resolver thread can be scheduled after the caller’s check, and the receive timeout uses a duration captured before spawning. Check the deadline and cancellation inside the resolver thread before lookup, and compute the remaining wait immediately before receiving. 
- **P2 — Export can still write or open Explorer after timing out.** Folder resolution and creation can run past the last pre-write check. The STA thread can also start late. Recheck before publishing the report and inside the STA thread immediately before `ShellExecuteW`. Stage the JSON and publish it with a no-overwrite move so failed writes leave no partial report. 
- **P2 — The new snapshot tests can fail in parallel CI.** Both mutate `LAST_SNAPSHOT`, so either can replace or clear the fixture before the other asserts it exists. Give each test its own cache. 
- **P3 — Folder opening proceeds if COM initialization fails.** Return the existing generic folder-open error on a failed `CoInitializeEx` before calling `ShellExecuteW`. 

## M2c r8 遗留（Codex m2c-r8 PASS）
- **P2 — Export can start disk writes after timeout.** Slow folder resolution can still be followed by directory creation, and a slow staging-file open can still be followed by a write. Check expiry after folder resolution, before each staging attempt, and after opening the staging file. 
- **P2 — Export requires hard-link support.** A log volume that supports renames but lacks hard links cannot export. Publish the staged report with a same-directory `MoveFileExW` call with flags `0` and retry name collisions. 
- **P2 — The manual TCP test excludes worker queue time.** Start its three-second deadline at IPC entry, enforce it with `timeout_at`, and reject a TCP success returned after expiry. 
- **P2 — A queued focus refresh briefly re-enables the old server.** A Node check reproduced Settings probing the previous address while the follow-up read was pending. Invalidate both views’ probes when refresh starts and apply only the last queued snapshot. 
- **P3 — The GPU list displays VRAM capacity.** Keep capacity internal to the classifier and display the adapter name, class, and likely encoder. 
- **P3 — Documentation is stale.** Correct the README’s PATH fallback and TOML write claims. Update the r7 checklist and remove the trailing spaces flagged by `git diff --check`. 

- t3-r9 P2/P3（测试）：标签唯一性按 Tauri Section 合并检查；宏解析兼容 CRLF；Status getter 推进时钟的超时用例。

## T5 手机扫码配置
- 设置页「手机扫码配置」行 + 弹层：`get_mobile_config_qr` 读当前 `RustDesk2.toml`，用 `qrcode`（`EcLevel::M`，仅矩阵）生成二维码；
  内容为官方格式 `config={"host":…,"relay":…,"key":…}`（serde_json 生成，relay 为空省略）。完整公钥只进二维码，视图只回公钥指纹；
  canvas 白底黑块、4 模块静区、整数像素缩放居中；Esc 与关闭按钮关闭并归还焦点，浏览器预览显示不可用。
- 单测覆盖 payload（含/不含 relay、空 server、无效 key、JSON 转义）；命令已登记 `build.rs` AppManifest 与 `capabilities/default.json`。
