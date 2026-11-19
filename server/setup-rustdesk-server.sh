#!/usr/bin/env bash
# Vega Remote - RustDesk 自建中继一键部署（Debian/Ubuntu）
set -euo pipefail
cd "$(dirname "$0")"

if [[ $EUID -ne 0 ]]; then echo "请用 sudo 运行"; exit 1; fi

if ! command -v docker >/dev/null; then
  echo "==> 安装 Docker"
  curl -fsSL https://get.docker.com | sh
fi

echo "==> 放行端口"
if command -v ufw >/dev/null && ufw status | grep -q active; then
  ufw allow 21115:21119/tcp
  ufw allow 21116/udp
fi

echo "==> 启动 hbbs / hbbr"
docker compose up -d

echo "==> 等待生成密钥"
for i in $(seq 1 20); do
  [[ -f data/id_ed25519.pub ]] && break
  sleep 1
done

IP=$(curl -fsS4 https://ifconfig.me || hostname -I | awk '{print $1}')
echo
echo "================ 完成 ================"
echo "ID 服务器 / 中继服务器: $IP"
echo "Key: $(cat data/id_ed25519.pub 2>/dev/null || echo '尚未生成，稍后查看 server/data/id_ed25519.pub')"
echo "提醒: 云厂商安全组也要放行 TCP 21115-21119、UDP 21116"
