# Vega 控制台（M2b：接入 RustDesk）

Tauri 2 + 原生 HTML/CSS/TypeScript（无前端框架）。窗口 960×640（最小 860×580），
自绘标题栏、左栏三页、浅色/深色主题、系统托盘。

设计稿：`../docs/ui/console-design.md`。M2a 静态界面 + **M2b RustDesk 接入**：设备码、
服务器配置读写出自 Rust，连接直接调 `rustdesk.exe`；控制台不发网络请求（测试连接只做
本地 TCP connect）、不采集遥测、零广告。临时密码不进前端、不进命令行、不进日志——
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
   ├─ capabilities/default.json  # 窗口控制 + RustDesk 命令，最小权限
   ├─ icons/             # 占位图标（见 icons/README.md；离线无法重生成 ICO）
   ├─ src/rustdesk.rs    # 设备码/TOML 读写/连接/状态/服务模式检测 + 单元测试
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

- M2c：Sunshine/Moonlight 对接、设置页 doctor 与脱敏日志导出、会话事件（被控弹窗/浮条）。
