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

脚本会：安装 Sunshine 和 Tailscale → 写入自适应配置 → 只放行串流端口 → 关闭睡眠。

管理密码不在脚本里设置，也不会作为命令行参数传给 Sunshine。装完后在**被控端本机**浏览器打开 <https://localhost:47990>，按页面提示首次设置账号密码。`sunshine.conf` 里的 `origin_web_ui_allowed = pc` 让管理页只接受本机访问，Vega 的防火墙规则也不放行 47990；如果 Sunshine 安装器自带了对 47990 的入站规则，脚本会禁用它并记进状态清单，卸载时恢复。

### 2. 主控端（你操作的电脑）

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\client\install-client.ps1
```

两台电脑登录同一个 Tailscale 账号，打开 Moonlight，添加被控端的 `100.x.x.x` 地址，输入 PIN 配对（PIN 在刚才设密的管理页里确认）。

### 3. 备用中继（可选，需要一台 Linux VPS）

```bash
cd server && sudo bash setup-rustdesk-server.sh
```

脚本输出服务器地址和 Key，填到两端 RustDesk 的「ID/中继服务器」里即可。

镜像固定为 `rustdesk/rustdesk-server:1.1.16`，部署与 CI 使用同一份 `server/docker-compose.yml`。默认只放行桌面客户端需要的 TCP 21115-21117 与 UDP 21116；需要 WebSocket 时用 `sudo bash setup-rustdesk-server.sh --websocket` 额外放行 21118/21119。脚本不会用 `curl | sh` 安装 Docker：没装时会提示按官方文档用软件源安装后重新运行。

## 诊断

连不上、卡顿、怀疑编码器选错时，先跑只读诊断（不安装、不修改任何系统设置，无需管理员）：

```powershell
powershell -File .\tools\vega-doctor.ps1
```

它会列出显卡与推荐编码器（NVENC / AMF / QSV）、Sunshine 安装与服务状态、Vega 防火墙规则、公网 IPv6、Tailscale 状态，并给中文结论。

检查到被控端是否直连（把 `vega-host` 换成被控端的 Tailscale 机器名）：

```powershell
powershell -File .\tools\vega-doctor.ps1 -Peer vega-host
```

`tailscale ping -c 3` 会打进诊断输出，脚本自动判断是 `via 1.2.3.4:41641`（直连）还是 `via DERP(xxx)`（中继）。

## 卸载

两个安装脚本都可以反复执行：已安装的组件跳过，防火墙规则先删后建，`sunshine.conf` 只更新 Vega 管理的键（`sunshine_name`、`adapter_name`、`dd_*`、`origin_web_ui_allowed`、`address_family`），你后来加的端口、凭据、配对路径等键原样保留。

安装时会写一份状态清单，记录 Vega 实际安装的包、Vega 防火墙规则、被禁用的安装器防火墙规则、服务原始的启动类型与运行状态，以及 `sunshine.conf` 里受管键的原始值。
被控端（管理员）用 `%ProgramData%\Vega\host-state.json`：目录只给 Administrators + SYSTEM 完全控制并禁用继承，读取前还会校验所有者不是低权限账号、不是重解析点；主控端（普通用户）用 `%LOCALAPPDATA%\Vega\client-state.json`。回滚前每条记录都会按白名单核对（规则名、服务名、配置路径、包 ID），每一步变更立即写回，全部回滚成功后才删除清单。卸载只按清单回滚：

```powershell
# 被控端：删除 Vega 防火墙规则、恢复安装器规则、恢复配置与服务启动类型
Set-ExecutionPolicy -Scope Process Bypass -Force
.\host\install-host.ps1 -Uninstall

# 被控端：连组件一起卸载（只卸清单里由 Vega 装的；你原来就有的应用不动）
.\host\install-host.ps1 -Uninstall -RemoveApps

# 主控端：卸载清单里由 Vega 安装的组件（加 -WithRustDesk 时也卸 RustDesk）
.\client\install-client.ps1 -Uninstall -RemoveApps
```

卸载只把受管键恢复为首次安装前的原值（原来没有的键就删掉），你后来加的键、注释、端口、凭据路径都不会被动。`-Uninstall` 不会改动睡眠/电源设置，也不会删除 Sunshine 安装目录。

旧版本装的机器没有状态清单：此时卸载只清理 Vega 自己命名的防火墙规则，其余保持现状，避免误伤。

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
