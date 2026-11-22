# Vega Remote

> 免费、开源、无广告、无弹窗的远程办公方案。2K / 1080p 自适应，独显、集显通用。
>
> **零广告、零付费、无需登录**：脚本只下载官方发行版并写配置，不插入任何推广或付费墙，也不需要注册 Vega 账号。中继用你自己的 VPS，或直接走 Tailscale / IPv6 直连。

## 安装（Windows，双击 Vega-Setup.exe）

1. 从 GitHub Actions 的 `Console` 工作流下载 artifact **vega-setup-windows**，解压得到 `Vega-Setup.exe`（或从 Release 下载同名文件）。
2. 双击运行，UAC 提权一次。安装包是 perMachine 模式，只在这一步要管理员权限。安装路径固定为
   `C:\Program Files\Vega`（`$PROGRAMFILES64\Vega`），安装器不再显示「选择安装目录」页；长期密码助手
   `resources\vega-pwhelper.ps1` 必须落在系统 Program Files 下，默认 ACL 只允许管理员写。
3. 安装过程会自动装好 RustDesk 并写入自建中继配置（默认 `60.205.95.98`，见 `console/src-tauri/resources/vega-defaults.json`）。RustDesk 是 AGPL，安装包里**不含**它的二进制，安装时从官方 GitHub Release 下载固定版本并校验 SHA256。
4. 如果 RustDesk 没装好（下载失败/哈希不符），Vega 仍会正常安装完成，并提示「RustDesk 未装好，请打开 Vega 按提示手动安装」；也可以直接到 <https://rustdesk.com/download> 手动下载安装。
5. 卸载 Vega 时，安装包会按 `%ProgramData%\Vega\host-state.json` 里的记录回滚 RustDesk 中继配置；只有记录标明「由 Vega 安装」时才会连带卸载 RustDesk。

**换成你自己的中继**：fork 后改 `console/src-tauri/resources/vega-defaults.json` 的 `rustdesk.idServer` / `relayServer` / `key`，重新构建安装包即可。这个文件是公开信息，可以入库；构建清单里也把 `host/install-rustdesk.ps1` 与 `host/lib/Vega.Common.psm1` 一起打进 `resources\`。

## 一行安装（Windows，管理员 PowerShell，脚本方式）

```powershell
irm https://raw.githubusercontent.com/shisanyue950901-beep/vega-remote/main/bootstrap.ps1 | iex
```

按提示选 **1 = 被控主机** 或 **2 = 控制端**。带参数静默安装（例如同时配置 RustDesk 自建中继）：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/shisanyue950901-beep/vega-remote/main/bootstrap.ps1))) -Role host -RustDeskServer relay.example.com -RustDeskKey <公钥>
```

引导脚本会下载最新 Release 的 `vega-remote-<版本>.zip` 到内存，先对字节算 SHA256，校验通过后把同一份字节写进受保护的工作目录（`%ProgramData%\Vega\bootstrap\<新GUID>`，创建后立即设为仅 Administrators 与 SYSTEM 完全控制），再从该文件解压、从该目录执行安装脚本，结束后删除工作目录。

GitHub 直连受限时可用 `-ZipUrl` 指定镜像，但**只接受 https，且只使用可信镜像：镜像同时控制 zip 和校验文件**。想避免同源校验被一起替换，可从 GitHub Release 页面独立取得摘要后传 `-Sha256`（优先于同源 `SHA256SUMS.txt`）：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/shisanyue950901-beep/vega-remote/main/bootstrap.ps1))) -Role host -ZipUrl https://mirror.example.com/vega-remote-0.2.0.zip -Sha256 <64位十六进制摘要>
```

需要管理员 PowerShell；脚本不接收、不保存任何密码。

> 不想用一行安装也可以按下面的步骤手动下载仓库后运行脚本。

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
- **长期密码可控**：设置页可设置/清除 RustDesk 长期密码；只在保存时通过 UAC 提权一次，密码经收紧权限的临时文件交给助手，不进日志与命令行
- **手机控制电脑**：官方 RustDesk + 设置页扫码（二维码自动带好本机 ID 服务器、中继与公钥）
- **自动更新**：启动静默检查、设置页可手动检查与安装；优先阿里云镜像、回落 GitHub Release，安装包经 minisign 签名校验
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

脚本输出服务器地址和 Key。部署后有两种方式配置两端 RustDesk：

- 安装脚本参数：`-RustDeskServer relay.example.com -RustDeskKey <公钥>`（必须同时给）
- 仓库根目录可选文件 `vega.config.json`：

```json
{ "rustdesk": { "server": "relay.example.com", "key": "<公钥>" } }
```

安装脚本会写 `RustDesk2.toml` 的 `custom-rendezvous-server`、`relay-server`、`key`（只动这三个键，卸载按键回滚），并打印 3-3-3 分组后的本机设备码。固定密码请在 RustDesk 界面「设置 → 安全 → 密码」自行设置，脚本不接收、不保存任何密码。

脚本只支持全新部署：启动前发现项目里已有容器会直接拒绝，避免误删正在用的中继。需要重装时加 `--reinstall`，脚本会先 `compose down`（数据目录和密钥保留）再按全新流程部署。启动前还会用 `ss -lntup` 检查 TCP/UDP 21115-21119，被占用就停下。

镜像固定为 `rustdesk/rustdesk-server:1.1.16`，部署与 CI 使用同一份 `server/docker-compose.yml`。容器用 `network_mode: host`，不发布端口：Docker 的端口发布走 DNAT，不经过 UFW 的 INPUT 规则，等于绕过入站限制。脚本**不修改防火墙**，部署完成后只打印需要放行的端口清单、`ufw` 示例命令和云安全组建议：默认 TCP 21115-21117、UDP 21116；`--websocket` 只影响提示文字，额外列出 TCP 21118-21119。脚本不会用 `curl | sh` 安装 Docker：没装时会提示按官方文档用软件源安装后重新运行。

未安装或未启用 UFW 时，脚本会打印醒目警告：**「未检测到启用的 UFW，21115-21119 将直接对外暴露，其中 21118/21119（WebSocket）也会对外可达，请用云厂商安全组只放行 TCP 21115-21117、UDP 21116」**。UFW 已启用但默认入站是 allow 时同样会警告。脚本不会执行 `ufw allow`/`ufw deny`，放行需要你按完成提示里的示例命令自行配置。

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
被控端（管理员）用 `%ProgramData%\Vega\host-state.json`，RustDesk 服务模式（LocalService）的记录单独写管理员清单 `%ProgramData%\Vega\state.json`：目录只给 Administrators + SYSTEM 完全控制并禁用继承，读取前还会校验所有者不是低权限账号、不是重解析点；主控端（普通用户）用 `%LOCALAPPDATA%\Vega\client-state.json`。回滚前每条记录都会按白名单核对（规则名、服务名、配置路径、包 ID），每一步变更立即写回，全部回滚成功后才删除清单。卸载只按清单回滚：

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
