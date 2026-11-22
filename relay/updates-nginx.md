# 更新镜像（阿里云 `60.205.95.98`）

控制台更新优先走这个镜像，失败再回落到 GitHub Release。镜像只托管三个静态文件：

```
/opt/vega-relay/updates/
├── latest.json          # 客户端检查入口（由 latest-mirror.json 原子改名而来）
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

1. 在 GitHub 推送 tag `v0.6.0`，`Console` 工作流的 `release` job 上传
   `Vega-Setup.exe`、`.sig`、`latest.json`、`latest-mirror.json`。
2. 本机（有服务器 SSH 权限）运行：

   ```bash
   tools/publish-update-mirror.sh v0.6.0
   ```

   脚本下载 `latest-mirror.json` 与安装包、打印 SHA256，上传后把
   `.latest.json.tmp` 原子改名为 `latest.json`，客户端不会读到半个文件。
3. 用上面的 `curl` 复查 `latest.json` 的 `version` 与 `url`。

## 回滚

把上一版 `latest.json`、`Vega-Setup.exe`、`.sig` 重新 `scp` 上去，同样先传临时名再
`mv`。签名版本号必须高于客户端当前版本，客户端才会提示更新。
