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

**是否安全？**
Moonlight 首次连接要 PIN 配对；Tailscale 端到端加密；不要把 47990 管理端口暴露到公网。

**安装脚本可以重复运行吗？**
可以。已安装的组件会跳过，Vega 防火墙规则先删后建，`sunshine.conf` 只在第一次修改前备份为 `sunshine.conf.bak`，之后不会覆盖最初的备份。想强制重装组件加 `-Force`。

**脚本支持 Windows PowerShell 5.1 吗？**
支持。Windows 10/11 自带的 Windows PowerShell 5.1 和 PowerShell 7 都能跑，文件是 UTF-8 with BOM。Win7 不在支持范围。

**怎么卸载？**
被控端运行 `.\host\install-host.ps1 -Uninstall`：删除 Vega 防火墙规则、恢复 `sunshine.conf.bak`、停止 Sunshine 服务。再加 `-RemoveApps` 会用 winget 卸载 Sunshine / Tailscale（加 `-WithRustDesk` 时也卸 RustDesk）。主控端用 `.\client\install-client.ps1 -Uninstall -RemoveApps`。卸载不恢复电源/睡眠设置。

**连不上或卡顿，先看哪里？**
先跑只读诊断：`powershell -File .\tools\vega-doctor.ps1`。怀疑线路问题时加 `-Peer <被控端机器名>`，脚本会执行 `tailscale ping -c 3`，直接告诉你走的是直连还是 DERP 中继，并给出中文建议。它不会修改任何系统设置。

**诊断显示“缺少 Vega 防火墙规则”？**
管理员 PowerShell 重新运行一次 `.\host\install-host.ps1` 即可，脚本会先删后建；也可以用 `.\host\install-host.ps1 -Uninstall` 后重装。

**诊断显示推荐编码器是 SOFTWARE？**
没有识别到可用的硬件编码器。先更新显卡驱动；NVIDIA 需要 470 以上、AMD 需要 22.3.1 以上驱动。仍不行就降分辨率，由 CPU 软编。

**winget 提示找不到包？**
先更新「应用安装程序」(App Installer)，再执行 `winget source update`。仍失败可手动安装对应官方发行版，脚本检测到已安装会跳过。

**服务器上 `docker compose` 不存在？**
`server/setup-rustdesk-server.sh` 会自动回退到独立的 `docker-compose` 命令；两者都没有时会提示先安装 Docker Compose。没有 ufw 的系统（如部分云镜像）会跳过防火墙步骤，请改用 firewalld 或云厂商安全组放行 TCP 21115-21119、UDP 21116。
