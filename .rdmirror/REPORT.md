# ops-rdmirror2：RustDesk 1.5.3 镜像收尾（.tmp 校验、转正、来源说明、HTTP 验证）

任务性质：运维操作。不改仓库代码；本报告是唯一产物（仓库内 `.rdmirror/REPORT.md` 为提交副本）。

## 0. 本地原件核对（先看再传）

| 文件 | 字节 | sha256 |
| --- | --- | --- |
| `/workspace/work/rdmirror/rustdesk-1.5.3-x86_64.exe` | 26233712 | `523ba0efbf62a21739961b62c7daaffb44d3da86139c546b364fd4e1333ed249` |

与任务单期望 sha256 一致（本地原件无需再传）。

## 1. 远端 `.tmp` 校验与转正（rsh.py over paramiko，60.205.95.98）

`PYTHONPATH=/workspace/work/tools/ssh/py python3 /workspace/work/tools/ssh/rsh.py '<cmd>'`

转正前：

```
523ba0efbf62a21739961b62c7daaffb44d3da86139c546b364fd4e1333ed249  /opt/vega-relay/updates/rustdesk/1.5.3/rustdesk-1.5.3-x86_64.exe.tmp
26233712 字节
```

- 与期望 sha256 **完全一致** → 执行 `mv -f rustdesk-1.5.3-x86_64.exe.tmp rustdesk-1.5.3-x86_64.exe`（`MV_OK`）
- 未重传，未删除 `.tmp`（已改名为正式文件）

转正后目录：

```
/opt/vega-relay/updates/rustdesk/1.5.3/
  rustdesk-1.5.3-x86_64.exe   26233712 字节  sha256 523ba0efbf62a21739961b62c7daaffb44d3da86139c546b364fd4e1333ed249
  SOURCE.txt                  180 字节      sha256 486ea06b84688f5b108bc4005f30a1159b431f3d96702fba96e4bba39508a228
```

## 2. 远端 SOURCE.txt

写入 `/opt/vega-relay/updates/rustdesk/1.5.3/SOURCE.txt`（base64 解码写入，避免引号/编码损耗），180 字节，内容：

```
RustDesk 1.5.3 官方未修改二进制，AGPL-3.0，源码 https://github.com/rustdesk/rustdesk/tree/1.5.3 ，原始下载 https://github.com/rustdesk/rustdesk/releases/tag/1.5.3
```

## 3. HTTP 验证（python urllib，`ProxyHandler({})`，直连，未整包下载）

| 检查 | 结果 |
| --- | --- |
| `HEAD http://60.205.95.98/vega/updates/rustdesk/1.5.3/rustdesk-1.5.3-x86_64.exe` | **200**，`Content-Length: 26233712` ✅ |
| `GET http://60.205.95.98/vega/updates/rustdesk/1.5.3/SOURCE.txt` | **200**，180 字节，sha256 `486ea06b84688f5b108bc4005f30a1159b431f3d96702fba96e4bba39508a228`（与远端一致）✅ |

`Content-Length` 与本地原件字节数、sha256 校验共同确认远端二进制即官方原版，未被替换。

## 4. 结论

- `.tmp` 校验一致，已原子转正为 `rustdesk-1.5.3-x86_64.exe`，未重传。
- `SOURCE.txt` 已落盘，注明官方未修改、AGPL-3.0、源码与原始下载地址。
- 两个 URL 均 200，exe `Content-Length` 26233712 与期望一致；SOURCE.txt 内容与远端 sha256 一致。

T-DONE
