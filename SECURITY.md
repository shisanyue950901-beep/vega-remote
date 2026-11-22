# 安全策略

## 报告漏洞

请**不要**在公开 Issue 里贴漏洞细节、利用代码、凭据或设备码。

使用 GitHub 的私下渠道：

1. 打开仓库的 **Security** 标签页
2. 选择 **Report a vulnerability**（GitHub Security Advisories）
3. 填写：受影响的版本/提交、复现步骤、影响范围、你建议的修复方向

维护者会在私下 Advisory 里跟进。修复发布后再公开细节，并在 Release 说明里致谢（如果你愿意）。

## 范围

- 安装 / 卸载脚本（`host/`、`client/`、`bootstrap.ps1`）
- 防火墙、状态清单与回滚逻辑
- 服务端部署脚本（`server/`）与镜像/端口默认值
- 文档中可能导致不安全配置的说明

## 不在范围

- Sunshine、Moonlight、Tailscale、RustDesk 上游自身的漏洞：请报告给对应项目
- 已经公开且上游已修复、但用户没有升级的版本
- 需要先拿到管理员权限才能利用的本地提权（除非脚本本身扩大了影响）

## 长期密码

控制台运行时不提权。只有在「设置 / 清除长期密码」时，才通过 UAC 拉起一次提权助手
（安装目录里的 `resources\vega-pwhelper.ps1`）；用户在 UAC 点「否」即视为取消，不重试。

**威胁模型**：本节防护的是「同一台机器上、只有普通用户权限、没有管理员批准」的对手。已经能以同一用户会话
替换自己 `%LOCALAPPDATA%` 下文件（或已拿到管理员）的本地攻击者**不在范围内**——那种对手本来就能读 RustDesk
配置、改 `recent-ids.json`、或在 UAC 之后动助手输入，任何进程内校验都挡不住。所有验证方式回读都依赖 RustDesk
服务处于运行状态：服务未运行时 `--option` 可能只写进 CLI 账户的本地配置，此时助手以 12 退出、不做「已生效」的结论。
本节还假设安装目录保持 Program Files 的默认权限；管理员若人为放宽该目录权限（让普通用户可写），
则长期密码助手可能被普通用户替换，这属于管理员误配置，不在本节防护范围内。

- **一次性 UAC**：控制台用 `ShellExecuteExW` 的 `runas` 直接拉起系统 PowerShell，参数只有
  `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<安装目录>\resources\vega-pwhelper.ps1" -InputFile "<载荷>"`，
  PowerShell 与助手都用系统绝对路径。只有助手进程是管理员，它读完载荷、设好密码就退出；控制台始终以普通用户身份运行。
- **只认打包目录内的助手**：发行版只使用 Tauri 资源目录里的 `vega-pwhelper.ps1`，没有源码目录回退；助手定位
  RustDesk 时只读 `[Environment]::GetFolderPath('ProgramFiles')` 下的固定路径，不接受 `VEGA_RUSTDESK_EXE` 等环境覆盖。
- **载荷创建时即带 DACL**：载荷写在 `%LOCALAPPDATA%\Vega\pw\` 下的 `vega-pw-<32 位十六进制>.json`，由 Rust 侧用
  一次性 `CreateFileW` 以 SDDL `D:P(A;;FA;;;<当前用户>)(A;;FA;;;BA)(A;;FA;;;SY)` 创建——不继承父目录权限，只允许
  当前用户、Administrators、SYSTEM 完全控制，写完立即关闭句柄。控制台命令行里只有路径，没有密码；助手只接受
  文件名匹配该正则且不是重解析点的普通文件。
- **30 s 过期由助手校验，且每次修改前复核**：载荷带 `expires = 创建时间 + 30 s`；助手在拿到载荷时比对一次，
  在每一次 CLI 修改（`--password`、`--option verification-method`）之前用当前 unix 秒再各比对一次，过期即退出
  10、不再写 RustDesk。控制台同时启动 30 秒看门狗删除残留载荷，并最多等助手 60 秒。
- **RustDesk 服务必须正在运行**：修改前先 `Get-Service -Name RustDesk`，不存在或状态不是 `Running` 即退出 12。
  没有服务 IPC 时 `--option` 只写 CLI 账户的本地配置，回读也会读到那份本地值，看起来「成功」而服务端没变。
- **调用有 20 s 时限**：每次 `rustdesk.exe` 调用都用 `[Diagnostics.Process]` 等待至多 20 秒；超时杀掉子进程并退出
  14（结果未知，界面提示人工确认）。卡住的 RustDesk 不会把提权助手一起挂死。
- **读后即毁，不按路径重删**：助手用单个 `DeleteOnClose` 句柄（`FileShare.None`）读出全部内容，同一句柄 `Seek(0)`
  回写等长空格并 Flush，关闭句柄即删除；关闭后若该路径仍存在（说明删除没生效）直接退出 10，**不再按路径
  `Remove-Item` 兜底**——路径在两次访问之间可能已被替换，按路径删除会删掉别人的文件。JSON 非法、字段不合格、
  `mode` 不是 `set|clear`、`clear` 带 `password` 或验证方式不在白名单时同样退 10，且不会调用 RustDesk。密码字符串
  在进程内存里无法清零，属于 .NET/PowerShell 的固有限制。
- **密码字符集限制**：只允许 8~64 位 ASCII 字母、数字与 `!#$%&*+,-./:;<=>?@^_~`，且必须同时含字母和数字。排除空格、
  引号、反斜杠和非 ASCII 是为了让 JSON、PowerShell 原生参数传递与 RustDesk CLI 三方都不发生转义或截断，避免
  「校验通过但实际写入另一个密码」。
- **结果回读**：设密码后要求 `rustdesk.exe --password` 输出包含 `Done!`，否则退 12；写验证方式后再执行
  `--option verification-method` 回读，Trim 后与期望值不一致退 13。`clear` 用 32 位随机密码替代原密码
  （拒绝采样阈值按字母表长度计算），验证方式固定改回 `use-temporary-password`。
- **已知风险：`--password` 参数在提权进程中短暂可见**。RustDesk 只提供 `rustdesk.exe --password <pwd>` 这一官方
  接口，因此密码会出现在该提权进程的命令行里，`Get-CimInstance Win32_Process`、ETW 进程审计或其他管理员级工具
  在那一瞬间可以读到它。本机管理员本来就能读取 RustDesk 配置与内存，接受该风险，换取不自行实现 RustDesk 的
  密码派生与配置格式。
- **输出**：助手退出码 0 成功 / 10 载荷无效、过期或无法清理 / 11 找不到 RustDesk / 12 RustDesk 拒绝修改或服务
  未运行 / 13 验证方式回读不一致 / 14 调用 RustDesk 超时（结果未知）；stderr 只写固定短句，不含异常原文和密码；
  密码不进 stdout、日志、`state.json` 或 doctor 导出。

## 已知设计取舍

- 安装/卸载脚本（`host/`、`client/`、`bootstrap.ps1`）不接收、不保存任何密码；Sunshine 管理密码由用户在本机界面设置；RustDesk 长期密码只经上面的提权助手一次性写入，控制台不读回内容
- Sunshine 管理页只允许本机访问，防火墙不放行管理端口
- 状态清单只按白名单回滚，读取前校验所有者与重解析点

## 自动更新

控制台内置 `tauri-plugin-updater`，启动后静默检查一次，设置页可手动检查与安装。更新源按顺序尝试：

1. 阿里云镜像 `http://60.205.95.98/vega/updates/latest.json`（国内优先，纯 HTTP）
2. GitHub Release `https://github.com/shisanyue950901-beep/vega-remote/releases/latest/download/latest.json`

**镜像走明文 HTTP 是刻意的**：镜像只节省带宽和连接时间，不承担信任。更新包使用 minisign 签名，
公钥在构建时由 CI 通过 `VEGA_UPDATER_PUBKEY` 注入配置（源码里是占位符）；客户端安装前会校验
`latest.json` 里每个平台的 `signature` 与安装包内容。公钥不在更新通道上传输，因此能改 `latest.json`
或替换安装包的一方没有私钥，篡改后的包无法通过校验，也就无法被安装。私钥只存在于 CI secrets，
不进入仓库与任何构建产物。

明文通道的残余风险：攻击者可以看到「谁在何时检查更新」以及版本号，也可以让更新检查失败（拒绝服务）。
若需要隐藏元数据，请改用 HTTPS 镜像；本项目的签名校验不依赖传输层。
