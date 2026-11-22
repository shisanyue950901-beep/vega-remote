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
本节假设安装目录的权限没有被管理员事后放宽（让普通用户可写）——见下面「安装目录权限」一条，
控制台对**任何**安装目录（包括默认的 `Program Files\Vega`）都会在每次提权前自己校验 ACL。

- **一次性 UAC**：控制台用 `ShellExecuteExW` 的 `runas` 直接拉起系统 PowerShell，参数只有
  `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "<安装目录>\resources\vega-pwhelper.ps1" -InputFile "<载荷>"`，
  PowerShell 与助手都用系统绝对路径。只有助手进程是管理员，它读完载荷、设好密码就退出；控制台始终以普通用户身份运行。
- **只认打包目录内的助手**：发行版只使用 Tauri 资源目录里的 `vega-pwhelper.ps1`，没有源码目录回退；助手定位
  RustDesk 时只读 `[Environment]::GetFolderPath('ProgramFiles')` 下的固定路径，不接受 `VEGA_RUSTDESK_EXE` 等环境覆盖。
- **安装目录权限（v0.6.1 / T6b）**：安装目录只允许两个位置——`C:\Program Files\Vega`（`$PROGRAMFILES64\Vega`，默认），
  或某个本地固定 NTFS 磁盘根目录下的 `Vega`（`X:\Vega`）。目录页/静默安装/`/D=` 的其它输入都会被规范化并提示：
  落在系统盘 `Program Files` 里的收成 `$PROGRAMFILES64\Vega`，其余按所选路径的盘符收成 `X:\Vega`；UNC、U 盘/光驱/网络盘/
  内存盘、非 NTFS、以及已存在且非空又不是 Vega 的目录会被拒绝（静默/被动安装直接中止，退出码 2）。
  为了让助手仍然只可能被管理员替换，做了两层约束：
  1. **安装器在解包前就锁死 ACL**：安装节校验目标通过后，先 `CreateDirectory $INSTDIR` 并调用
     `VegaLockInstallDir`，然后才 `SetOutPath` / `File` 解包——文件绝不会落进未锁定的目录。
     锁定按固定顺序执行三条 `icacls`，每条都检查退出码，任一失败立即 `SetErrorLevel 2` + `Abort`
     （静默安装靠 `/SD IDOK` 直接中止）：先 `/reset /T` 清掉所有显式 ACE（旧自定义目录残留的个人账户 /
     `Authenticated Users` 写权限就是这一步清掉的），再 `/setowner *S-1-5-32-544 /T` 把所有者改成
     Administrators，最后
     `/inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX /T`
     递归收紧成「SYSTEM、Administrators 完全控制，Users 只读执行」。安装完成后（POSTINSTALL）会用同一函数
     对解包出来的文件再锁一遍；这一次失败只写进完成页告警，不再中止（程序已经装好）。
  2. **控制台每次提权前都校验，没有 `Program Files` 快路径**：`ensure_helper_location` 对任何安装位置
     （包括默认的 `Program Files\Vega`）都跑同一套完整校验，不存在「前缀命中就跳过」的分支——`Program Files`
     下被手工建出来、带宽松 ACL 的目录同样危险。校验要求助手正好位于 `<控制台 exe 目录>\resources` 下，并依次检查：
     - **位置**：控制台 exe 目录只能是 `<X>:\Vega` 或 `<ProgramFiles>\Vega`（`Program Files` 根来自
       `winpaths::program_files_dirs()`，不读可被启动环境改写的环境变量）。
     - **重解析点（先用原始路径判完）**：控制台 exe、exe 目录、`resources` 目录、助手文件，以及 exe 目录直到
       盘根的每一级祖先，都不能是 junction/symlink。这一组检查全部基于 `current_exe` 给出的未规范化路径先跑完，
       之后才 `canonicalize` 并要求规范化结果与原始路径一致，避免链接在校验途中换走路径。
     - **祖先规则（直到盘根，含 `Program Files` 根）**：`exe` 目录的每一级父目录，所有者必须是
       SYSTEM / Administrators / TrustedInstaller，且 DACL 中不得把 `DELETE` / `FILE_DELETE_CHILD` /
       `WRITE_DAC` / `WRITE_OWNER` / `GENERIC_WRITE` / `GENERIC_ALL` 授予其他主体；建子目录/建文件
       （`FILE_ADD_SUBDIRECTORY` / `FILE_ADD_FILE`）允许，盘根上给 `Authenticated Users` 建目录是 Windows 默认 ACL。
     - **三层 DACL**：控制台 exe 目录、`resources` 目录、助手文件三者的所有者必须是
       SYSTEM / Administrators / TrustedInstaller，DACL 中所有带写权限（含 DELETE / WRITE_DAC / WRITE_OWNER /
       GENERIC_WRITE 等）的 allow ACE 只能授给这三个主体（CREATOR OWNER 仅允许出现在 `INHERIT_ONLY` 的继承 ACE 上）；
       只接受普通 `ACCESS_ALLOWED_ACE_TYPE`，复合/对象/回调类 allow ACE 与未知 ACE 类型一律判为不安全。
     任一条不满足就拒绝设置长期密码，并提示「Vega 安装目录权限不安全，无法设置长期密码。请重新运行安装包修复。」
  管理员事后手动放宽该目录权限（例如把 Users 加回写权限，或把某一级祖先的所有者改成普通用户）会命中第 2 层，
  长期密码直接不可用而不是被静默劫持。
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
2. GitHub 固定 tag `vega-updates` 的 `https://github.com/shisanyue950901-beep/vega-remote/releases/download/vega-updates/latest.json`

检查与安装都会同时（并发）问两个端点，各 15 秒超时：任一端点报错或没有更新也看另一端，两边都有更新时按 semver 取较高者，同号取镜像；预发布版不推给正式版；只有一端答复时会明确提示另一端不可达，不会笼统说「已是最新」；
安装从报告该版本的一端下载，下载/验签失败再换另一端重试一次。检查超时 15 秒，下载单独限时 10 分钟。
镜像清单滞后不会隐藏 GitHub 上已发布的更高版本。

**镜像走明文 HTTP 是刻意的**：镜像只节省带宽和连接时间，不承担信任。更新包使用 minisign 签名，
公钥直接提交在 `console/src-tauri/tauri.conf.json` 的 `plugins.updater.pubkey` 里（源码可见，不靠 CI
注入，也不用仓库 secret）；客户端安装前会校验 `latest.json` 里每个平台的 `signature` 与安装包内容。
公钥不在更新通道上传输，因此能改 `latest.json` 或替换安装包的一方没有私钥，篡改后的包无法通过
校验，也就无法被安装。

**签名只在维护者本机做**：CI 只构建未签名的 NSIS 安装包（`createUpdaterArtifacts: false`，构建不读
任何签名密钥，`TAURI_SIGNING_*` / `VEGA_UPDATER_PUBKEY` 都不再使用）。发布时维护者在本机运行
`tools/publish-update.sh <tag> <setup.exe>`：脚本用 `tauri signer sign` 对安装包签名、写出 `latest.json`，
再把安装包、`.sig` 与清单上传到阿里云 `/opt/vega-relay/updates/`（安装包进不可覆盖的 `<版本>/` 目录，
清单最后原子替换）和 GitHub 固定 tag `vega-updates` 的 Release。私钥只存在于维护者本机的环境变量
（`TAURI_SIGNING_PRIVATE_KEY`）里，不进仓库、CI 或脚本参数，脚本也不打印私钥内容。

明文通道的残余风险：攻击者可以看到「谁在何时检查更新」以及版本号，也可以让更新检查失败（拒绝服务）。
若需要隐藏元数据，请改用 HTTPS 镜像；本项目的签名校验不依赖传输层。

**降级风险（已知，待加固，见 ROADMAP「T6 加固」）**：能改 `latest.json` 的一方虽然造不出新包，但可以
回放一个更早的、签名有效的 Vega 版本，客户端会把它当成可用更新装上去。后续用签名内绑定版本
（`requireSignedVersion`）或 HTTPS 镜像消除；当前签名只证明「这个包确实是 Vega 官方签的」，不证明
「它是最新版本」。
