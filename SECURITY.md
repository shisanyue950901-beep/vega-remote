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

- **一次性 UAC**：控制台用 `ShellExecuteExW` 的 `runas` 直接拉起系统 PowerShell，参数只有
  `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<安装目录>\resources\vega-pwhelper.ps1" -InputFile "<载荷>"`，
  PowerShell 与助手都用系统绝对路径。只有助手进程是管理员，它读完载荷、设好密码就退出；控制台始终以普通用户身份运行。
- **只认打包目录内的助手**：发行版只使用 Tauri 资源目录里的 `vega-pwhelper.ps1`，没有源码目录回退；助手定位
  RustDesk 时只读 `[Environment]::GetFolderPath('ProgramFiles')` 下的固定路径，不接受 `VEGA_RUSTDESK_EXE` 等环境覆盖。
- **载荷创建时即带 DACL**：载荷写在 `%LOCALAPPDATA%\Vega\pw\` 下的 `vega-pw-<32 位十六进制>.json`，由 Rust 侧用
  一次性 `CreateFileW` 以 SDDL `D:P(A;;FA;;;<当前用户>)(A;;FA;;;BA)(A;;FA;;;SY)` 创建——不继承父目录权限，只允许
  当前用户、Administrators、SYSTEM 完全控制，写完立即关闭句柄。控制台命令行里只有路径，没有密码；助手只接受
  文件名匹配该正则且不是重解析点的普通文件。
- **30 s 过期由助手校验**：载荷带 `expires = 创建时间 + 30 s`；助手在修改 RustDesk 之前用当前 unix 秒比对，过期即退出
  10。控制台同时启动 30 秒看门狗删除残留载荷，并最多等助手 60 秒。
- **读后即毁**：助手用单个 `DeleteOnClose` 句柄（`FileShare.None`）读出全部内容，同一句柄 `Seek(0)` 回写等长空格并
  Flush，关闭句柄即删除；关闭后若文件仍存在再删一次，仍失败退出 10。JSON 非法、字段不合格、`mode` 不是
  `set|clear`、`clear` 带 `password` 或验证方式不在白名单时同样退 10，且不会调用 RustDesk。密码字符串在进程内存里
  无法清零，属于 .NET/PowerShell 的固有限制。
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
- **输出**：助手退出码 0 成功 / 10 载荷无效或无法清理 / 11 找不到 RustDesk / 12 RustDesk 拒绝修改 /
  13 验证方式回读不一致；stderr 只写固定短句，不含异常原文和密码；密码不进 stdout、日志、`state.json` 或 doctor 导出。

## 已知设计取舍

- 安装/卸载脚本（`host/`、`client/`、`bootstrap.ps1`）不接收、不保存任何密码；Sunshine 管理密码由用户在本机界面设置；RustDesk 长期密码只经上面的提权助手一次性写入，控制台不读回内容
- Sunshine 管理页只允许本机访问，防火墙不放行管理端口
- 状态清单只按白名单回滚，读取前校验所有者与重解析点
