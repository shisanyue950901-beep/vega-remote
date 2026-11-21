# Windows 真机试跑清单（v0.1）

两台机器：A = 被控端（核显+独显），B = 主控端。每项记 ✅/❌，❌ 时截图并把 Vega「设置 → 诊断」导出的 JSON 一起发回。

## 0. 准备
- GitHub 仓库页 Code → Download ZIP，解压到两台机器。
- Actions → Console → 最新一次运行 → Artifacts 下载 `vega-console-windows`（解压得 vega-console.exe）。
- 先不跑一行安装（还没发 Release）。

## 0.5 安装包（Vega-Setup.exe）
- [ ] Actions → Console → Artifacts 下载 `vega-setup-windows`，解压得 `Vega-Setup.exe`。
- [ ] 双击后只弹一次 UAC；安装界面是简体中文且没有语言选择框。
- [ ] 装完 `C:\Program Files\Vega 控制台\resources\vega-defaults.json` 存在，且与仓库里的默认中继一致。
- [ ] `C:\Program Files\Vega 控制台\resources\host\install-rustdesk.ps1` 与 `...\host\lib\Vega.Common.psm1` 都存在。
- [ ] `%ProgramData%\Vega\logs\setup.log` 有本次安装记录和 `[nsis] install-rustdesk.ps1 exit code:` 一行。
- [ ] 已装 RustDesk 的机器上重跑安装包：日志显示「已安装 RustDesk，跳过安装」，配置仍被写入。
- [ ] 未装 RustDesk 的机器：安装包自动下载固定版本并 SHA256 校验通过后静默安装；RustDesk 服务出现在服务列表。
- [ ] 校验失败 / 下载失败的机器：Vega 安装照常完成，完成后提示「RustDesk 未装好，请打开 Vega 按提示手动安装」，安装没有整体失败。
  注意：在架构师填入真实 SHA256 前，所有机器都会走这条失败分支，这是占位常量的预期行为。
- [ ] 卸载 Vega 后，`RustDesk2.toml` 的三个受管键恢复为安装前的值（或整行删除），用户原有 RustDesk 保留。
- [ ] 设置页「默认中继」一行显示安装包默认值与 RustDesk 当前配置；手动改过 RustDesk 中继时会显示不一致提示。

## 1. 脚本安装
- [ ] A：管理员 PowerShell，`Set-ExecutionPolicy -Scope Process Bypass -Force`，`.\host\install-host.ps1`，无报错结束。
- [ ] A：浏览器开 https://localhost:47990，能首次设 Sunshine 账号密码。
- [ ] B：普通 PowerShell，`.\client\install-client.ps1`，无报错结束。
- [ ] 两台登录同一 Tailscale，`tailscale status` 互相可见。
- [ ] B：`powershell -File .\tools\vega-doctor.ps1 -Peer <A 的机器名>`，记下是「直连」还是「DERP 中继」。

## 2. 控制台基础（A、B 都测）
- [ ] 双击 vega-console.exe 能打开，无 SmartScreen 之外的报错。
- [ ] 左栏 远程协助 / 我的设备 / 设置 都能切换。
- [ ] 点关闭 → 缩到托盘；托盘右键能恢复、能退出。
- [ ] 托盘「复制设备码」后能粘贴出内容。

## 3. RustDesk（远程协助）
- [ ] 未装 RustDesk 时，「安装」按钮打开 GitHub releases 页面。
- [ ] 装好 RustDesk 后回到 Vega，页面自动刷新出设备码。
- [ ] 设置页显示的 ID 服务器/中继与 RustDesk 里一致（只读）。
- [ ] B 用 A 的设备码 + 密码连上 A。

## 4. 高性能串流
- [ ] A：串流页显示 Sunshine 服务「运行中」。
- [ ] A：显卡列表同时列出核显和独显。
- [ ] A：「打开配对」打开 https://localhost:47990/pin。
- [ ] B：「启动 Moonlight」能拉起 Moonlight；添加 A 的 100.x 地址，输入 PIN 配对成功。
- [ ] B：串流 1080p 和 2K 各 2 分钟，画面流畅，记下 Moonlight 统计里的延迟和帧率。
- [ ] A：在服务里手动停 Sunshine，Vega 串流页状态在切回窗口后变为「已停止」。

## 5. 诊断
- [ ] 设置 → 诊断 在 8 秒内出结果。
- [ ] 导出后自动打开 %LOCALAPPDATA%\Vega\logs，JSON 里没有用户名、完整用户路径或密码。

## 6. 卸载
- [ ] A：`.\host\install-host.ps1 -Uninstall`，防火墙规则和配置恢复。
- [ ] B：`.\client\install-client.ps1 -Uninstall`。
