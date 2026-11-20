# Vega 控制台（M2a 骨架）

Tauri 2 + 原生 HTML/CSS/TypeScript（无前端框架）。窗口 960×640（最小 860×580），
自绘标题栏、左栏三页、浅色/深色主题、系统托盘。

设计稿：`../docs/ui/console-design.md`。当前是 **M2a 静态界面**：所有数据为占位数据，
不发网络请求、不采集遥测、无广告，Rust 侧只做窗口与托盘。

## 目录

```
console/
├─ package.json          # 前端构建脚本（tsc + 静态资源复制）
├─ tsconfig.json
├─ scripts/build-static.mjs
├─ src/                  # 前端源码（唯一手写源）
│  ├─ index.html         # 标题栏 / 左栏 / 三页 / 弹窗 / 浮条
│  ├─ styles.css         # 主题变量、浅色 + prefers-color-scheme 深色
│  └─ main.ts            # 导航、页签、复制、密码显示、窗口按钮
└─ src-tauri/
   ├─ Cargo.toml
   ├─ tauri.conf.json    # 窗口尺寸、CSP、withGlobalTauri
   ├─ build.rs
   ├─ capabilities/default.json  # 最小权限，仅窗口控制
   ├─ icons/             # 占位图标（见 icons/README.md）
   └─ src/main.rs        # 托盘菜单：显示主窗口/复制设备码/断开当前会话/退出
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

## 约束（沿用设计稿）

- 临时密码、固定密码不进命令行、日志、state.json；本地配置后续走 DPAPI（M2b）。
- 控制台不需要管理员常驻；装组件/改防火墙由现有 PowerShell 脚本单独 UAC 调起（M2c）。
- Rust 侧不启用 shell / fs / http 插件；新增能力必须同时改 `capabilities/default.json`。

## 后续

- M2b：读写 RustDesk 配置（设备码、临时密码、服务器）、发起连接、托盘「复制设备码/断开」接实。
- M2c：Sunshine/Moonlight 对接、设置页 doctor 与脱敏日志导出。
