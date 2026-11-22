# Windows 真机试跑清单（v0.1）

两台机器：A = 被控端（核显+独显），B = 主控端。每项记 ✅/❌，❌ 时截图并把 Vega「设置 → 诊断」导出的 JSON 一起发回。

## 0. 准备
- GitHub 仓库页 Code → Download ZIP，解压到两台机器。
- Actions → Console → 最新一次运行 → Artifacts 下载 `vega-console-windows`（解压得 vega-console.exe）。
- 先不跑一行安装（还没发 Release）。

## 0.5 安装包（Vega-Setup.exe）
- [ ] Actions → Console → Artifacts 下载 `vega-setup-windows`，解压得 `Vega-Setup.exe`。
- [ ] 双击后只弹一次 UAC；安装界面是简体中文且没有语言选择框，**有「选择安装目录」页**，默认 `C:\Program Files\Vega`（T6b 恢复该页；允许的位置只有 `C:\Program Files\Vega` 或 `X:\Vega`）。
- [ ] 选 `D:\Vega` 安装：装完后 `icacls D:\Vega` 里所有者是 `BUILTIN\Administrators`，只有 SYSTEM/Administrators 完全控制、`BUILTIN\Users` 只有 `(OI)(CI)(RX)`，且没有继承来的 Users 写权限（`(I)` 拒绝项不该出现写权限）。
- [ ] 选 `C:\Program Files\Vega` 安装（默认位置）后 `icacls "C:\Program Files\Vega"`：发生的是 `/reset` + `/setowner` + `/inheritance:r /grant:r` 的最终结果，即没有额外的显式 ACE，只剩 SYSTEM/Administrators 完全控制与 Users 只读执行（ACL 对两种位置都执行，不再跳过 Program Files）。
- [ ] 在 D:\Vega 安装上设置长期密码成功（控制台通过自选目录的 ACL 校验）。
- [ ] 手动 `icacls D:\Vega /grant *S-1-5-32-545:(OI)(CI)M` 放开 Users 写权限后，再设置长期密码被拒绝，提示「Vega 安装目录权限不安全，无法设置长期密码。请重新运行安装包修复。」；恢复 ACL（重新运行安装包或按上面的 icacls 收紧）后又能设置。
- [ ] 目录页校验：填 `D:\tools\Vega` 或 `D:\任意目录` 会被自动改成 `D:\Vega` 并弹出「Vega 只能安装在 …已改为 D:\Vega」；填 `\\server\share\Vega`（UNC）、U 盘/光驱路径被拒绝；`D:\Vega` 本身已存在、非空、且没有 `vega-console.exe`（例如先建 `D:\Vega` 并放一个文件）时被拒绝并提示「已存在且不为空，但不是 Vega 安装目录」；`vega-console.exe` 是同名**目录**时同样按「不是 Vega 安装目录」拒绝。
- [ ] 已装在 `D:\Vega` 的机器上重装 / 在线更新（`/P` 被动模式）：目录页默认值、静默安装的 `$INSTDIR` 都仍是 `D:\Vega`，不会跳回 Program Files，且不触发旧目录迁移。
- [ ] 静默/被动安装的 `/D=` 必须是允许的位置（t6b-fix3 起 `D:\Test` 不再被静默改到 `D:\Vega`，而是按无效目标中止）：
      `Vega-Setup.exe /S /D=D:\Test`（`D:\Test` 已存在且非空、不是 Vega；`D:\Test` 不是 `X:\Vega` 形状）——安装中止，**退出码 2**，`D:\Test` 里的原有文件（尤其是 `uninstall.exe`）没有被覆盖、ACL 也没有被改，`D:\Vega` 里没有多出任何东西。
- [ ] `Vega-Setup.exe /S /D=Q:\Vega`（Q: 盘不存在 / 未格式化）——安装中止，**退出码 2**，没有任何文件被写入。
- [ ] `Vega-Setup.exe /S /D=`（空值，或 `/D="D:\Vega"` 带引号这种非法写法）——安装中止，**退出码 2**，不静默回落到 `C:\Program Files\Vega`。
- [ ] 对照：`Vega-Setup.exe /S /D=D:\Vega` 与 `/S /D=C:\Program Files\Vega`（这两个就是允许的位置）正常装完，退出码 0。
- [ ] 装完 `<安装目录>\resources\vega-defaults.json`（默认位置是 `C:\Program Files\Vega\resources\`）存在，且与仓库里的默认中继一致。
- [ ] `<安装目录>\resources\host\install-rustdesk.ps1` 与 `...\host\lib\Vega.Common.psm1` 都存在。
- [ ] `%ProgramData%\Vega\logs\setup.log` 有本次安装记录和 `[nsis] install-rustdesk.ps1 exit code:` 一行。
- [ ] 全新安装（之前没有 Vega）但已装 RustDesk 的机器：日志显示「已安装 RustDesk，跳过安装」，中继配置仍被写入。覆盖重装 Vega 的情形见下方「跳过 RustDesk 脚本」一项。
- [ ] 未装 RustDesk 的机器：安装包自动下载固定版本并 SHA256 校验通过后静默安装；RustDesk 服务出现在服务列表。
- [ ] 校验失败场景：把下载到的安装包副本改一个字节（或临时把 `Get-VegaRustDeskRelease` 的摘要改错）后重跑，
      Vega 安装照常完成，完成页提示「RustDesk 未装好，请打开 Vega 按提示手动安装」，安装没有整体失败。
- [ ] 下载失败场景（断网或代理拦截）：同样只提示，不阻断 Vega 安装；`%ProgramData%\Vega\logs\setup.log` 有失败原因。
- [ ] 卸载 Vega 后，`RustDesk2.toml` 的三个受管键恢复为安装前的值（或整行删除），用户原有 RustDesk 保留。
- [ ] 设置页「默认中继」一行显示安装包默认值与 RustDesk 当前配置；手动改过 RustDesk 中继时会显示不一致提示。
- [ ] 旧版装在 D 盘 → 安装新版后 D 盘旧目录里的 Vega 文件（`vega-console.exe`、`uninstall.exe`、`resources\`）被清除，旧目录本身非递归删除；安装过程**没有运行旧卸载器**，RustDesk 与配置不受影响（`%ProgramData%\Vega`、RustDesk 配置与用户 AppData 都还在）。旧目录里若有非 Vega 文件，目录保留且完成页有提示。旧目录或 `old\resources` 是 junction/symlink 时，整个清理跳过，不删链接目标。
- [ ] 在线更新（安装器 `/UPDATE` 模式）后，Vega 程序文件被替换，但 RustDesk 没有被重新下载/安装，中继配置不被改写（`%ProgramData%\Vega\logs\setup.log` 本次运行没有 RustDesk 安装记录）。若旧版曾装在 D 盘，这次 `/UPDATE` 也会清掉 D 盘旧目录；若删除 `C:\Program Files\RustDesk\rustdesk.exe` 后再 `/UPDATE`，安装器会补装并配置 RustDesk。
- [ ] 覆盖重装同版本：安装器不再出现「重新安装 / 已安装」页，不运行旧卸载器，也不重跑 RustDesk 脚本；删除 RustDesk 后重装同一版本则应补装。

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

## 3.5 手机扫码配置（T5）
- [ ] 设置页「手机扫码配置」一行的说明写的是「底部『设置』→ 右上角扫码图标」，
      不是首页右上角。
- [ ] 点「显示二维码」，弹层在 1 秒内出码，状态行显示「当前 ID 服务器：<地址>」。
- [ ] **手机实扫**：iPhone 和安卓各一台，官方 RustDesk 进底部「设置」→ 右上角扫码图标，
      扫出来的码后 ID 服务器/中继/公钥与 A 的 RustDesk2.toml 完全一致；点「确定」保存后
      重开 App 配置仍在，能连上 A。
- [ ] 公钥配成 44 字符正常值时手机端不报「密钥不匹配」（含把公钥手动折行的场景：
      折行值写进 toml 后仍应扫出规范值）。
- [ ] **键盘焦点**：只用键盘打开弹层，Tab / Shift+Tab 循环不跑出弹层，
      焦点到不了遮罩下的「测试连接」「在 RustDesk 中修改」等按钮；
      Esc 关闭后焦点回到「显示二维码」，「关闭」按钮点击后同样回到「显示二维码」。
- [ ] **绘制失败**：把 `RustDesk2.toml` 的 `custom-rendezvous-server` 改成 256 个字符
      后点「显示二维码」，状态行必须显示错误（过长），不能出现白板 + 成功文案；
      把整个 toml 撑到 65 KiB 以上再试，状态行显示「配置文件过大」且控制台界面不卡死
      （弹层打开期间仍能响应 Esc）。
- [ ] 服务里停掉/改坏 `RustDesk2.toml`（或删掉）后开弹层，显示「未安装 RustDesk」
      或读取失败提示，不显示上一次的服务器地址。

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
