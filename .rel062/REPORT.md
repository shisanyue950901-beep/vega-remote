# rel062 发布报告：Vega 0.6.2 到阿里云更新镜像

任务性质：运维发布。**未修改仓库代码，未执行 git commit**（任务单禁止；`git status` 全程无已跟踪文件改动，HEAD 仍为 `3d49d4f`）。

> 环境偏差：本会话沙箱只允许在仓库目录树内写入，`/workspace/work/rel062` 与 `/tmp/opencode` 的写入均被权限规则拒绝（`mkdir`/`touch`/write 工具均 deny）。因此本轮产物落在
> `/workspace/projects/cf8180c5-da2f-457c-b8b7-3362aecba827/vega-remote/.rel062/`，内容与要求完全一致，可原样搬到 `/workspace/work/rel062`。

## 1. CI 工作流

- head_sha: `3d49d4f7a0f834e30479fa14980c72de6caa395a`
- Console run id: **45037630341**，name=Console，status=completed，conclusion=success
- 同 sha 的 CI run: 45037630355（completed/success，与本发布无关）
- 轮询：15:19Z 起每 30s 检查，第 16 次（约 15:27Z）拿到成功

## 2. 产物

| artifact | id | 大小 |
| --- | --- | --- |
| vega-setup-windows（NSIS 安装包，取用） | 14759614934 | 2106527（zip，内含 `Vega-Setup.exe`） |
| vega-console-windows（仅 console 二进制，未用） | 14759809544 | 2482308 |

artifact 下载用 `curl -sSL <archive_download_url>`（apicall 无 artifact 下载端点；注意 `apicall github --list actions` 只有 list/get/delete，没有 download）。zip 内文件已被工作流改名为 `Vega-Setup.exe`，解出即用。

本地文件（`.rel062/`）：

- `Vega-Setup-0.6.2.exe`：**2125063 字节**
- sha256：`7ff95b36c90db189fb9b89f24a2fc198a116fa40f5c6947588f076b684da5ad8`
- `Vega-Setup.exe`：同一文件（2125063 字节，同 sha256）
- `Vega-Setup-0.6.2.exe.sig`：408 字节，sha256 `178148d294b5b9e64dd16eb7026cc0f3a653be21ca6bd900a1a2ce15f2d6fcea`
- 文件类型：PE32 GUI，Nullsoft Installer self-extracting archive（NSIS）

## 3. 签名

```
TAURI_SIGNING_PRIVATE_KEY_PATH=/workspace/work/tools/updkey/vega.key \
TAURI_SIGNING_PRIVATE_KEY_PASSWORD=$(head -c 200 /workspace/work/tools/updkey/pw) \
/workspace/work/tools/tauricli/node_modules/.bin/tauri signer sign Vega-Setup-0.6.2.exe
```

rc=0，生成 `Vega-Setup-0.6.2.exe.sig`。CLI 提示 "Signing without an app version"（与 0.6.0/0.6.1 一致，未加 `--app-version`）。密码/私钥未回显、未复制。

## 4. 清单文件

`latest-mirror.json`（720 字节，sha256 `2b13285abd1e03dde1be357dd7c07383739741499072be6457165200b337c8a3`）：

- version: `0.6.2`
- notes: `Vega 控制台 0.6.2：修复 0.6.1 安装目录权限问题（文件无法运行）`
- pub_date: `2026-11-22T15:29:57Z`（RFC3339 UTC）
- url: `http://60.205.95.98/vega/updates/0.6.2/Vega-Setup-0.6.2.exe`
- signature: `.sig` 文件内容（408 字符，无尾换行）

`latest.json`（764 字节，sha256 `811697269123c2199292421ac38bf5f1896ddc4ae2cd5ffbb0c121f4279c4222`）：同上，url 为 `https://github.com/shisanyue950901-beep/vega-remote/releases/download/vega-updates/Vega-Setup-0.6.2.exe`。

两者均 `python3 json.load` 回读校验通过（version/signature/url 断言）。

## 5. 上传（60.205.95.98，rsh.py over paramiko）

- `mkdir -p /opt/vega-relay/updates/0.6.2` ok
- put `0.6.2/Vega-Setup-0.6.2.exe` → 2125063 字节，远端 sha256 `7ff95b36…5ad8`（与本地一致）
- put `0.6.2/Vega-Setup-0.6.2.exe.sig` → 408 字节，远端 sha256 `178148d2…fcea`（一致）
- put `latest.json.tmp`（720 字节）→ 远端 `mv -f latest.json.tmp latest.json` 原子替换；远端 `latest.json` sha256 `2b13285a…c8a3`（与本地 latest-mirror.json 一致）
- 远端 `cp -f 0.6.2/Vega-Setup-0.6.2.exe Vega-Setup.exe`；`/opt/vega-relay/updates/Vega-Setup.exe` 2125063 字节，sha256 `7ff95b36…5ad8`（一致）

## 6. HTTP 验证（全部通过）

- `GET http://60.205.95.98/vega/updates/latest.json` → `"version": "0.6.2"`，notes/pub_date/url 正确
- `HEAD http://60.205.95.98/vega/updates/0.6.2/Vega-Setup-0.6.2.exe` → `HTTP/1.1 200 OK`，`Content-Length: 2125063`（与本地字节数一致）
- `HEAD …/Vega-Setup-0.6.2.exe.sig` → 200，`Content-Length: 408`
- `GET http://60.205.95.98/healthz` → `ok`
- 回读校验：下载线上 exe/sig，sha256 分别为 `7ff95b36…5ad8` / `178148d2…fcea`，与本地一致

## 7. 结论

0.6.2 已发布到阿里云更新镜像，`latest.json` 版本号与签名均为 0.6.2；安装包、签名、镜像副本三处 sha256 一致，HTTP 头字节数与本地一致，healthz 正常。
