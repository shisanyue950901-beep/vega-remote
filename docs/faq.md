# 常见问题

**集显能用吗？**
能。Intel 用 QuickSync，AMD 用 AMF。八代以后的 Intel 跑 2K 60 帧很稳。

**笔记本有集显和独显，画面卡或黑屏？**
在 Sunshine 管理页「Audio/Video → Adapter Name」手动选独显；NVIDIA 控制面板里把 sunshine.exe 设为高性能处理器。

**被控端没接显示器，连上黑屏？**
插一个 HDMI 虚拟显示器（诱骗器），或安装虚拟显示驱动。

**分辨率没有自动切换？**
需要 Sunshine 2025 及以上版本；旧版本请升级，或在 Moonlight 里手动选分辨率。

**能传文件吗？**
Moonlight 不支持。用 RustDesk 或 Tailscale 的 Taildrop。

**怎么设置 Sunshine 管理密码？**
在**被控端本机**浏览器打开 <https://localhost:47990>，按页面提示首次设密。脚本不再用命令行参数传密码（那会进事件 4688 的命令行审计），也不会代替你设密。

**是否安全？**
Moonlight 首次连接要 PIN 配对；Tailscale 端到端加密。管理页用 `origin_web_ui_allowed = pc` 限制为本机访问，Vega 防火墙只放行串流端口，不放行 47990；如果 Sunshine 安装器自带对 47990 的入站规则，安装脚本会禁用它（卸载时恢复）。所以不要在路由器上把 47990 映射出去。

**安装脚本可以重复运行吗？**
可以。已安装的组件会跳过，Vega 防火墙规则先删后建。`sunshine.conf` 只更新 Vega 管理的键（`sunshine_name`、`adapter_name`、`dd_*`、`origin_web_ui_allowed`、`address_family`），其余内容原样保留，写入用临时文件 + 原子替换，不生成 `.bak`；首次安装只把受管键的原值记进状态清单，卸载按键回滚。想强制重装组件加 `-Force`（重装前仍会查询，已存在的组件登记为 PreExisting，不会被 `-RemoveApps` 卸载）。

**脚本支持 Windows PowerShell 5.1 吗？**
支持。Windows 10/11 自带的 Windows PowerShell 5.1 和 PowerShell 7 都能跑，文件是 UTF-8 with BOM。Win7 不在支持范围。

**怎么卸载？**
安装时会写状态清单：被控端在 `%ProgramData%\Vega\host-state.json`（Administrators + SYSTEM 专用 ACL），主控端在 `%LOCALAPPDATA%\Vega\client-state.json`。被控端运行 `.\host\install-host.ps1 -Uninstall`：按清单删除 Vega 防火墙规则、恢复安装器规则、把 `sunshine.conf` 的受管键恢复为原始值、把服务恢复为记录的启动类型与运行状态。再加 `-RemoveApps` 只卸载清单里由 Vega 安装的 Sunshine / Tailscale（加 `-WithRustDesk` 时也卸 RustDesk），你原本就有的应用不会被删。主控端用 `.\client\install-client.ps1 -Uninstall -RemoveApps`。卸载不恢复电源/睡眠设置。

**连不上或卡顿，先看哪里？**
先跑只读诊断：`powershell -File .\tools\vega-doctor.ps1`。怀疑线路问题时加 `-Peer <被控端机器名>`，脚本会执行 `tailscale ping -c 3`，直接告诉你走的是直连还是 DERP 中继，并给出中文建议。它不会修改任何系统设置。

**诊断显示“缺少 Vega 防火墙规则”？**
管理员 PowerShell 重新运行一次 `.\host\install-host.ps1` 即可，脚本会先删后建；也可以用 `.\host\install-host.ps1 -Uninstall` 后重装。

**诊断显示推荐编码器是 SOFTWARE？**
没有识别到可用的硬件编码器。先更新显卡驱动；NVIDIA 需要 470 以上、AMD 需要 22.3.1 以上驱动。仍不行就降分辨率，由 CPU 软编。

**winget 提示找不到包，或脚本说查询失败？**
安装只使用 `--source winget` 源，并关掉了交互提示。没有匹配（例如源里确实没有该包）和查询失败（源故障、超时）是两种情况：前者跳过安装，后者会让脚本以非零退出码结束，不会假装成功。先更新「应用安装程序」(App Installer)，再执行 `winget source update`；仍失败可手动安装官方发行版。

**服务器上 `docker compose` 不存在？**
`server/setup-rustdesk-server.sh` 会优先用 `docker compose`，回退到独立的 `docker-compose` 命令；两者都没有时会提示先安装 Docker Compose 插件。脚本不会用 `curl | sh` 安装 Docker，没装 Docker 时会提示按官方文档用软件源安装后重新运行。没有 ufw 的系统（如部分云镜像）会跳过防火墙步骤，并打印醒目警告：「未检测到启用的 UFW，21115-21119 将直接暴露，请在云厂商安全组只放行 TCP 21115-21117、UDP 21116」。此时安全组是唯一防线，务必按提示收紧。

**RustDesk 中继要开哪些端口？**
默认只放行桌面客户端需要的 TCP 21115-21117 与 UDP 21116。需要 WebSocket（`--websocket`）时才额外放行 TCP 21118-21119。私钥文件落盘后会被收紧到 0600，数据目录要求在 0700 且属于 root。
