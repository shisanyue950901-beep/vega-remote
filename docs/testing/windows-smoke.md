# Windows 真机试跑清单（v0.1）

两台机器：A = 被控端（核显+独显），B = 主控端。每项记 ✅/❌，❌ 时截图并把 Vega「设置 → 诊断」导出的 JSON 一起发回。

## 0. 准备
- GitHub 仓库页 Code → Download ZIP，解压到两台机器。
- Actions → Console → 最新一次运行 → Artifacts 下载 `vega-console-windows`（解压得 vega-console.exe）。
- 先不跑一行安装（还没发 Release）。

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
