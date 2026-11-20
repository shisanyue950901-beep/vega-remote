# Vega 控制台（M2c：RustDesk + 高性能串流 + doctor）

Tauri 2 + 原生 HTML/CSS/TypeScript（无前端框架）。窗口 960×640（最小 860×580），
自绘标题栏、左栏三页、浅色/深色主题、系统托盘。

设计稿：`../docs/ui/console-design.md`。M2a 静态界面 + **M2b RustDesk 接入** +
**M2c 高性能串流与诊断**：设备码、服务器配置读写出自 Rust，连接直接调 `rustdesk.exe`；
Sunshine/Moonlight 只做状态检测与固定入口（不写配置、不接管管理密码）；设置页 doctor
只做本地检查并可导出脱敏日志。控制台不发网络请求（连通性测试只做本地 TCP connect /
UDP 路由选择）、不采集遥测、零广告。临时密码不进前端、不进命令行、不进日志——
「显示临时密码」只打开 RustDesk 主窗口。

窗口行为：点关闭按钮按「关闭窗口时最小化到托盘」设置隐藏窗口（Rust
`on_window_event` 拦 `CloseRequested`，默认开启，前端经 `set_close_to_tray` 命令同步勾选），
真正退出只走托盘菜单「退出」。标题栏双击最大化交给 Tauri 的 drag region 处理，不再自绘。

## 目录

```
console/
├─ package.json          # 前端构建脚本（tsc + 静态资源复制）
├─ tsconfig.json
├─ scripts/build-static.mjs
├─ src/                  # 前端源码（唯一手写源）
│  ├─ index.html         # 标题栏 / 左栏 / 三页 / 弹窗 / 浮条
│  ├─ styles.css         # 主题变量、浅色 + prefers-color-scheme 深色
│  └─ main.ts            # 导航、页签、invoke 封装、加载/错误状态、最近设备码
└─ src-tauri/
   ├─ Cargo.toml
   ├─ tauri.conf.json    # 窗口尺寸、CSP、withGlobalTauri
   ├─ build.rs           # AppManifest::commands 声明全部命令（生成 allow-*）
   ├─ capabilities/default.json  # 窗口控制 + RustDesk/串流/诊断命令，最小权限
   ├─ icons/             # 占位图标（见 icons/README.md；离线无法重生成 ICO）
   ├─ src/rustdesk.rs    # 设备码/TOML 只读/连接/状态/服务检测 + 单元测试
   ├─ src/scm.rs         # SCM 服务状态四分类（Sunshine / RustDesk 共用）
   ├─ src/streaming.rs   # 串流页：Sunshine 状态、DXGI 显卡、Moonlight 启动
   ├─ src/doctor.rs      # doctor 检查、脱敏与日志导出 + 单元测试
   └─ src/main.rs        # 托盘菜单：显示主窗口/复制设备码/断开/退出
```

`dist/` 是 `npm run build` 生成的产物（`tsc` 输出 `main.js`，脚本复制 `index.html`/`styles.css`），
已加入 `.gitignore`，`tauri.conf.json` 的 `frontendDist` 指向它。

## 构建

```bash
cd console
npm i && npm run tauri build
```

产物在 `src-tauri/target/release/`。只想验证前端类型与静态资源：

```bash
npm run build
```

CI：`.github/workflows/console.yml` 在 `console/**` 变更时于 `windows-latest` 跑
`npm install`（有 lock 文件时 `npm ci`）+ Rust stable，执行
`npm run tauri build -- --no-bundle`。

MSRV：`Cargo.toml` 声明 `rust-version = "1.90"`（Tauri 2.12 起要求）。仓库尚未提交
`package-lock.json` / `Cargo.lock`（离线环境无法生成），所以 CI 不加 `--locked`；
TODO 见工作流注释，联网生成后改为 `npm ci` + `--locked`。

## RustDesk 集成（M2b）

| 命令 | 作用 |
|---|---|
| `get_device_id` | 定位 `Program Files\RustDesk\rustdesk.exe`（再找 PATH），`--get-id` 总 deadline 5 秒、`CREATE_NO_WINDOW`；stdout 直接重定向到本次调用独占的临时文件、stderr 丢弃，轮询 `try_wait`，超时 kill + wait 并只回固定文本，成功时回读前 4 KB 后删文件，返回 9/10 位设备码 |
| `get_server_config` | <b>只读</b>：读 `%APPDATA%\RustDesk\config\RustDesk2.toml` 的 `[options]`，公钥只回前 8 位指纹；不写文件 |
| `connect_peer` / `get_recent_peers` | 设备码只接受 9-10 位数字或 3-3-3 / 3-3-4 分组（`123456789`、`123 456 789`、`123-456-789`、`123-456-7890`），整串匹配、分隔符一致，IPC 只发数字；最近列表按 3-3-3 / 3-3-4 展示，格式化与解析有往返单测；模式限 `control`/`file`；`--connect` / `--file-transfer`，最近 10 条存 app config 目录 JSON，无密钥 |
| `open_rustdesk_window` | 不带参数启动 RustDesk，用户自己看临时密码；设置页「在 RustDesk 中修改」也走这里 |
| `open_rustdesk_download_page` | 用默认浏览器打开写死在 Rust 侧的官方发行页 `https://github.com/rustdesk/rustdesk/releases/latest`（`explorer.exe <url>`，前端不能传地址） |
| `get_rustdesk_status` | 进程与服务状态。控制台<b>不再在应用内提权安装</b>：没有 `ShellExecuteExW`/`runas`，安装包不携带 host 脚本，也不发布到 `%ProgramData%`。WinGet 社区源已下架 RustDesk，界面只在未安装时提供「打开 RustDesk 官方下载页」按钮；「允许远程协助」开关禁用，指向 RustDesk 自己的控制项 |
| `test_server_connection` | Rust 侧 TCP connect `server:21116`；解析与所有连接尝试共用 3 秒 deadline，`spawn_blocking` 离开 UI 线程 |

非 Windows 平台全部返回「未安装 RustDesk」，不 spawn 进程。纯函数（设备码、
服务器/公钥校验、`RustDesk2.toml` 解析）带 `#[cfg(test)]` 单测：`cargo test`。

## 高性能串流与诊断（M2c）

| 命令 | 作用 |
|---|---|
| `get_streaming_status` | Sunshine 服务经 SCM（`OpenSCManagerW`/`OpenServiceW`/`QueryServiceStatusEx`）查 `SunshineService`，区分运行中 / 已停止 / 未安装 / 无法查询；DXGI `EnumAdapters1` 只读枚举显卡（跳过软件适配器），按厂商与显存标核显/独显和 NVENC/AMF/QSV；检查 `%ProgramFiles%\Moonlight Game Streaming\Moonlight.exe`；返回 README 里逐字的一行安装命令 |
| `open_sunshine_pairing` / `open_sunshine_settings` | 用默认浏览器打开写死的 `https://localhost:47990/pin` / `https://localhost:47990`；PIN 由 Sunshine 页面接收，控制台不读不存 |
| `start_moonlight_stream` | 无参数启动已校验（系统盘 Program Files 下、canonicalize 后）的 `Moonlight.exe` |
| `run_doctor` | 8 秒总预算：RustDesk 安装、RustDesk ID 服务器 TCP（3 秒）、Sunshine 服务、本机 47990（1 秒）、公网 IPv6（UDP connect 只看本地源地址，不发包）、Tailscale、Moonlight；每项返回 `{item,status,advice}` |
| `export_doctor_log` | 重新跑 doctor，写 `%LOCALAPPDATA%\Vega\logs\doctor-<时间戳>.json`（app 版本 + Windows build + 结果），IPv4/IPv6/主机名/用户目录统一脱敏后打开目录 |

串流页只显示，不保存选择：编码器、分辨率、帧率请在 Sunshine 网页中设置。安装/修复按钮只
复制 README 的一行安装命令，并提示「请在管理员 PowerShell 中运行（会同时配置防火墙）」；
Vega 不常驻管理员、不提权、不写 Sunshine/Moonlight 配置、不处理 Sunshine 管理密码。

设置页的「诊断网络」会跳到设置 → 诊断并立即运行 doctor；「导出脱敏日志」的脱敏与状态
映射有单元测试。`focus` 时 Assist 与 Settings 共用一份 `RustDesk2.toml` 快照，并重查设备码
与 RustDesk 安装状态；设置页的连通性测试在每次重读配置时复位结果并恢复按钮。

网络配置是只读的：设置页显示 `RustDesk2.toml` 里的当前 ID/中继服务器与公钥指纹，
保留 `server:21116` 的 TCP 测试，并提示「服务器地址请在 RustDesk 的 设置 → 网络 中修改」，
按钮「在 RustDesk 中修改」直接打开 RustDesk 主窗口。两个页面的探测都带地址 + 代次，
地址变了或重读过配置就丢弃在途结果，旧地址的绿点不会贴到新服务器上。

## 约束（沿用设计稿）

- 临时密码、固定密码不进命令行、日志、state.json；「显示临时密码」只开 RustDesk 主窗口。
- 服务器公钥不写日志，界面只显示前 8 位指纹。
- 控制台不需要管理员常驻，也不提权：RustDesk 由用户从官方发行页手动安装（WinGet 已下架）；
  应用只负责打开下载页。
- Rust 侧不启用 shell / fs / http 插件；新增命令必须同时改 `build.rs` 的 `AppManifest::commands`
  与 `capabilities/default.json`。

## 后续

- 会话事件（被控弹窗/浮条）仍待接入；M2c 已完成串流页与 doctor/脱敏日志。
- 安装包冒烟测试仍按总控要求延后（CI 只跑 `tauri build --no-bundle`）。
