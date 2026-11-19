#!/usr/bin/env bash
# Vega Remote - RustDesk 自建中继一键部署（Debian/Ubuntu）
# 兼容：有/没有 ufw；有 docker compose 插件或独立 docker-compose 命令。
set -euo pipefail
cd "$(dirname "$0")"

if [[ $EUID -ne 0 ]]; then
  echo "请用 sudo 运行" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "==> 安装 Docker"
  curl -fsSL https://get.docker.com | sh
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "未找到 docker compose 或 docker-compose，请先安装 Docker Compose。" >&2
  exit 1
fi

echo "==> 放行端口"
if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 21115:21119/tcp
    ufw allow 21116/udp
  else
    echo "ufw 已安装但未启用，跳过；如使用 firewalld 或云安全组请自行放行端口。"
  fi
else
  echo "未安装 ufw，跳过；如使用 firewalld 或云安全组请自行放行端口。"
fi

echo "==> 启动 hbbs / hbbr"
"${COMPOSE[@]}" up -d

echo "==> 等待生成密钥"
found=false
for _ in $(seq 1 20); do
  if [[ -f data/id_ed25519.pub ]]; then
    found=true
    break
  fi
  sleep 1
done
if [[ "$found" != true ]]; then
  echo "警告: 20 秒内未生成 server/data/id_ed25519.pub，可稍后查看日志：${COMPOSE[*]} logs hbbs" >&2
fi

IP=$(curl -fsS4 https://ifconfig.me || hostname -I | awk '{print $1}')
KEY=$(cat data/id_ed25519.pub 2>/dev/null || echo '尚未生成，稍后查看 server/data/id_ed25519.pub')

echo
echo "================ 完成 ================"
echo "ID 服务器 / 中继服务器: $IP"
echo "Key: $KEY"
echo "提醒: 云厂商安全组也要放行 TCP 21115-21119、UDP 21116"
