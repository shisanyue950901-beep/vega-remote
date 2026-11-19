# Vega Remote

> 免费、开源、无广告、无弹窗的远程办公方案。2K / 1080p 自适应，独显、集显通用。

国内常用的远程软件越来越多地限速、收费、弹窗。Vega Remote 不重新造轮子，而是把最好的开源组件组合起来，用一键脚本帮你配好：

| 组件 | 作用 | 许可证 |
|---|---|---|
| [Sunshine](https://github.com/LizardByte/Sunshine) | 被控端串流服务，GPU 硬件编码 | GPL-3.0 |
| [Moonlight](https://github.com/moonlight-stream) | 主控端客户端，低延迟高帧率 | GPL-3.0 |
| [Tailscale](https://tailscale.com) | 免公网 IP 组网，P2P 直连 | 客户端 BSD-3 |
| [RustDesk](https://github.com/rustdesk/rustdesk) | 备用远控 + 文件传输，自建中继 | AGPL-3.0 |

Vega Remote 只下载官方发行版并写入配置，不修改、不打包上述软件。

## 特性

- **硬件通用**：编码器自动选择 NVIDIA NVENC / AMD AMF / Intel QuickSync，独显集显都能用
- **分辨率自适应**：被控端自动切换到主控端的分辨率和刷新率，断开后恢复
- **两条线路**：主线 IPv6 / Tailscale 直连（低延迟），备线 RustDesk 自建中继（兜底）
- **零费用**：全部组件免费，中继服务器用你自己的 VPS

## 快速开始

### 1. 被控端（要被远程的电脑）

以管理员身份打开 PowerShell：

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\host\install-host.ps1
```

脚本会：安装 Sunshine 和 Tailscale → 写入自适应配置 → 设置 Web 管理账号 → 放行防火墙 → 关闭睡眠。

### 2. 主控端（你操作的电脑）

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\client\install-client.ps1
```

两台电脑登录同一个 Tailscale 账号，打开 Moonlight，添加被控端的 `100.x.x.x` 地址，输入 PIN 配对。

### 3. 备用中继（可选，需要一台 Linux VPS）

```bash
cd server && sudo bash setup-rustdesk-server.sh
```

脚本输出服务器地址和 Key，填到两端 RustDesk 的「ID/中继服务器」里即可。

## 诊断

连不上、卡顿、怀疑编码器选错时，先跑只读诊断（不安装、不修改任何系统设置，无需管理员）：

```powershell
pwsh -File .\tools\vega-doctor.ps1
```

它会列出显卡与推荐编码器（NVENC / AMF / QSV）、Sunshine 安装与服务状态、Vega 防火墙规则、公网 IPv6、Tailscale 状态，并给中文结论。

检查到被控端是否直连（把 `vega-host` 换成被控端的 Tailscale 机器名）：

```powershell
pwsh -File .\tools\vega-doctor.ps1 -Peer vega-host
```

`tailscale ping -c 3` 会打进诊断输出，脚本自动判断是 `via 1.2.3.4:41641`（直连）还是 `via DERP(xxx)`（中继）。

## 卸载

两个安装脚本都可以反复执行：已安装的组件跳过，防火墙规则先删后建，配置只在第一次修改前备份一次。
只想恢复原状时用 `-Uninstall`：

```powershell
# 被控端：删除 Vega 防火墙规则，恢复 sunshine.conf.bak（若存在），停止 Sunshine 服务
Set-ExecutionPolicy -Scope Process Bypass -Force
.\host\install-host.ps1 -Uninstall

# 被控端：连组件一起卸载（winget 卸载 Sunshine / Tailscale，加 -WithRustDesk 时也卸 RustDesk）
.\host\install-host.ps1 -Uninstall -RemoveApps

# 主控端：卸载 Moonlight / Tailscale（加 -WithRustDesk 时也卸 RustDesk）
.\client\install-client.ps1 -Uninstall -RemoveApps
```

`-Uninstall` 不会改动睡眠/电源设置，也不会删除 Sunshine 安装目录里未备份的文件；`-RemoveApps` 才会调用 winget 卸载组件。

## 推荐设置

| 项目 | 建议 |
|---|---|
| Moonlight 分辨率 | 本机原生 |
| 帧率 | 60（上行带宽 ≥ 30 Mbps 可试 120） |
| 码率 | 默认（随分辨率帧率自动变化） |
| 视频编码 | HEVC，硬件解码 |

## 文档

- [网络与直连排查](docs/network.md)
- [常见问题](docs/faq.md)

## 许可证

本仓库的脚本与文档使用 MIT 许可证。所调用的第三方软件遵循各自许可证。
