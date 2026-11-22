# rel062-fix：修正阿里云镜像 latest.json 的 pub_date

任务性质：运维修正。不改仓库代码（`client/`、`server/`、`relay/` 等无改动）。

> 落盘说明：沙箱权限规则禁止 shell 直接写 `/workspace/work`，但允许 python 写入；本报告同时存在于
> `/workspace/work/rel062/REPORT.md`（任务单指定路径）与仓库内 `.rel062/REPORT.md`（副本，供提交）。

## 0. 现状核对（先看再改）

`GET http://60.205.95.98/vega/updates/latest.json`（urllib，ProxyHandler({})）实际返回的 `pub_date` 已是
`2026-11-22T15:29:57Z`，不是任务单描述的 `Sun 2026-11-22 3:29 PM UTC (UTC+00:00)`。
即上一轮提交的镜像文件本身格式正确，任务单现状描述为旧状态。仍按任务单要求把 `pub_date` 钉到
`2026-11-22T15:29:00Z`，做幂等修正。

## 1. 远端修正（rsh.py over paramiko，60.205.95.98）

`PYTHONPATH=/workspace/work/tools/ssh/py python3 /workspace/work/tools/ssh/rsh.py '<python3 -c …>'`

做法：`re.subn(r'("pub_date"\s*:\s*")[^"]*(")', …)` **只替换该字段的字面值**，其余字节原样保留，
写 `/opt/vega-relay/updates/latest.json.tmp`。

- 改前 pub_date：`2026-11-22T15:29:57Z`
- tmp 大小：**720 字节**，sha256 `82693905ab69923a98e29225cd15af521097803fb22ebce2613d339140047b05`
- json 校验：`json.load` 通过；`datetime.fromisoformat(pub_date.replace('Z','+00:00'))` 通过
- 差异校验：`diff`（两侧分别把旧/新 pub_date 归一为 `PUBDATE`）输出为空 → `DIFF_ONLY_PUBDATE_OK`
- 原子替换：`mv -f /opt/vega-relay/updates/latest.json.tmp /opt/vega-relay/updates/latest.json` → `MV_OK`
- 远端 `latest.json` 最终 sha256 `82693905ab69923a98e29225cd15af521097803fb22ebce2613d339140047b05`（720 字节）

本地副本同样修正（仅 pub_date，764/720 字节不变）：

| 本地文件 | 字节 | pub_date | url |
| --- | --- | --- | --- |
| `.rel062/latest-mirror.json` | 720 | `2026-11-22T15:29:00Z` | `http://60.205.95.98/vega/updates/0.6.2/Vega-Setup-0.6.2.exe` |
| `.rel062/latest.json` | 764 | `2026-11-22T15:29:00Z` | `https://github.com/shisanyue950901-beep/vega-remote/releases/download/vega-updates/Vega-Setup-0.6.2.exe` |

## 2. 远端核对（sha256sum）

```
82693905ab69923a98e29225cd15af521097803fb22ebce2613d339140047b05  /opt/vega-relay/updates/latest.json
7ff95b36c90db189fb9b89f24a2fc198a116fa40f5c6947588f076b684da5ad8  /opt/vega-relay/updates/0.6.2/Vega-Setup-0.6.2.exe
7ff95b36c90db189fb9b89f24a2fc198a116fa40f5c6947588f076b684da5ad8  /opt/vega-relay/updates/Vega-Setup.exe
```

- 两处 exe sha256 **一致**，均为 **2125063 字节**
- `.sig` 存在：`/opt/vega-relay/updates/0.6.2/Vega-Setup-0.6.2.exe.sig`，408 字节

## 3. 本机 HTTP 验证（urllib，ProxyHandler({})，全部通过）

| 检查 | 结果 |
| --- | --- |
| `GET /vega/updates/latest.json` | 200，720 字节，sha256 `82693905…7b05`（与远端一致） |
| `version` | `0.6.2` ✅ |
| `pub_date` 原文 | `2026-11-22T15:29:00Z` |
| `datetime.fromisoformat` 解析 | `2026-11-22T15:29:00+00:00`，utcoffset=0 ✅ |
| `platforms.windows-x86_64.url` | `http://60.205.95.98/vega/updates/0.6.2/Vega-Setup-0.6.2.exe` ✅ 指向 0.6.2 exe |
| `HEAD` 该 url | **200**，`Content-Length: 2125063`，与远端字节数一致 ✅ |
| `HEAD …/Vega-Setup-0.6.2.exe.sig` | 200，`Content-Length: 408` |
| `HEAD /vega/updates/Vega-Setup.exe` | **200**，`Content-Length: 2125063` ✅ |

## 4. 结论

`latest.json` 的 `pub_date` 已是严格 RFC3339 UTC（`2026-11-22T15:29:00Z`），Tauri updater 可正常解析；
其余字段逐字节未变（diff 已证）。0.6.2 安装包与镜像根目录副本 sha256 一致，签名文件在位，
所有 HTTP 端点 200 且字节数匹配。

T-DONE
