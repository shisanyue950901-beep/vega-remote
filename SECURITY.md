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

## 访问码

控制台不再提权，也不再读取 RustDesk 的临时密码。访问码由 LocalSystem 的 `VegaAgent` 服务生成，经由命名管道
`\\.\pipe\VegaAgent` 提供给当前控制台会话；服务把同一个码写成 RustDesk 的永久密码，并把
`verification-method` 设为 `use-permanent-password`。全产品只剩「访问码」一个密码概念。

- **状态文件**：`%ProgramData%\Vega\agent\state.json` 只保存 `{code, mode, updated}`，目录 ACL 是受保护 DACL，
  只给 SYSTEM 与 Administrators；普通用户不能改访问码。
- **管道权限**：命名管道 DACL 只给 SYSTEM 全部、Interactive Users 读写，并带 `PIPE_REJECT_REMOTE_CLIENTS`；
  连接后比对客户端会话号与当前活动控制台会话号，同机其他登录用户不能借管道改码。单条消息上限 4 KiB，
  控制台侧整次调用 3 秒超时。
- **不回显密码**：管道错误信息只给固定中文原因，不回显请求里的访问码；控制台日志、服务日志都不记录访问码。
- **应用方式**：服务以 SYSTEM 执行 `rustdesk.exe --password <code>` 与
  `rustdesk.exe --option verification-method use-permanent-password`（无窗口、15 秒超时）。访问码会出现在该子进程的
  命令行里，本机管理员本来就能读取 RustDesk 配置与进程信息，接受这一已知风险。
- **轮换**：自动模式生成 6 位纯数字；发现被控会话（命令行含 `--cm` 的 rustdesk.exe）从有变无时换新码。
  固定模式由用户在控制台设置 6–32 位字母或数字，服务不再自动轮换。
- **控制台不可达时**：主页只显示「访问码服务未运行」和修复入口，不回退到 RustDesk 临时密码。

## 已知设计取舍

- 安装/卸载脚本（`host/`、`client/`、`bootstrap.ps1`）不接收、不保存任何密码；Sunshine 管理密码由用户在本机界面设置；RustDesk 永久密码由 `VegaAgent` 服务写入，访问码只经上述命名管道在服务与控制台之间传递
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
