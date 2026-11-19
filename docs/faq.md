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
