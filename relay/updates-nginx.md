# 更新镜像（阿里云 `60.205.95.98`）

控制台更新优先走这个镜像，失败再回落到 GitHub Release。镜像只托管三个静态文件：

```
/opt/vega-relay/updates/
├── latest.json          # 客户端检查入口（由 latest-mirror.json 原子改名而来，内容见 publish-update.sh）
├── Vega-Setup.exe       # NSIS 安装包
└── Vega-Setup.exe.sig   # minisign 签名
```

`latest.json` 里的 `url` 指向本目录下的 `Vega-Setup.exe`。传输是明文 HTTP，
信任来自安装包签名：客户端用编译进程序的公钥校验 `.sig`，篡改的包无法安装。

## nginx 容器

只开 80，只读挂载更新目录；`autoindex off`，不给目录列表。

```bash
mkdir -p /opt/vega-relay/updates /opt/vega-relay/nginx
cat >/opt/vega-relay/nginx/updates.conf <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    root /usr/share/nginx/html;
    autoindex off;

    location /vega/updates/ {
        autoindex off;
        add_header Cache-Control "no-cache" always;
        types { application/json json; }
        try_files $uri =404;
    }

    location = /healthz {
        access_log off;
        return 200 "ok\n";
    }
}
EOF

docker run -d --name vega-updates --restart unless-stopped \
  -p 80:80 \
  -v /opt/vega-relay/updates:/usr/share/nginx/html/vega/updates:ro \
  -v /opt/vega-relay/nginx/updates.conf:/etc/nginx/conf.d/default.conf:ro \
  nginx:alpine
```

验证：

```bash
curl -fsS http://60.205.95.98/healthz
curl -fsS http://60.205.95.98/vega/updates/latest.json
curl -fsSI http://60.205.95.98/vega/updates/Vega-Setup.exe
```

## 发布一次更新

签名只在维护者本机做：CI 构建出来的 `Vega-Setup.exe` 是未签名的普通安装包，公钥已提交在
`console/src-tauri/tauri.conf.json` 的 `plugins.updater.pubkey`，CI 不需要任何签名密钥。

1. 本机导出维护者私钥（只在 shell 环境变量里，不进仓库、不进 CI、不作为脚本参数）：

   ```bash
   export TAURI_SIGNING_PRIVATE_KEY="$(cat <私钥文件>)"
   export TAURI_SIGNING_PRIVATE_KEY_PASSWORD='…'
   ```

2. 用 CI 产出的安装包发布：

   ```bash
   tools/publish-update.sh v0.6.0 <path>/Vega-Setup.exe
   ```

   脚本用 `tauri signer sign` 生成 `Vega-Setup.exe.sig`，写出 `latest.json`（指向 GitHub tag 资产）
   与 `latest-mirror.json`（指向本镜像），打印 SHA256，然后上传到 GitHub Release 和
   `/opt/vega-relay/updates/`；镜像清单最后以 `.latest.json.tmp` 原子改名为 `latest.json`，
   客户端不会读到半个文件。只想发一边时用 `VEGA_SKIP_GITHUB=1` / `VEGA_SKIP_MIRROR=1`。
3. 用上面的 `curl` 复查 `latest.json` 的 `version` 与 `url`。

注意：漏签或改用手工 `scp` 时，务必连 `.sig` 一起传；`latest.json` 里的 `signature`
与安装包内容必须对应，否则客户端校验失败、不会安装。

## 回滚

把上一版 `latest.json`、`Vega-Setup.exe`、`.sig` 重新 `scp` 上去，同样先传临时名再
`mv`。签名版本号必须高于客户端当前版本，客户端才会提示更新。
