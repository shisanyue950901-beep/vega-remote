#!/usr/bin/env bash
# Vega Remote - RustDesk 自建中继一键部署（Debian/Ubuntu）
#
# 设计要点：
#   - 不从网络管道安装 Docker（不用 curl | sh）；未安装时提示按官方文档用软件源安装后退出。
#   - 镜像固定 rustdesk/rustdesk-server:1.1.16，部署与 CI 使用同一份 compose 文件。
#   - data 目录启动前建成 0700、拒绝符号链接与非 root 所有者；私钥落盘后收紧到 0600。
#   - 默认只放行桌面客户端需要的 TCP 21115-21117 / UDP 21116；--websocket 才放行 21118/21119。
#   - 就绪检查两个容器都 running、公钥是普通文件且非空；失败明确退出。
set -euo pipefail
cd "$(dirname "$0")"

ALLOW_WEBSOCKET=false
usage() {
  echo "用法: sudo bash setup-rustdesk-server.sh [--websocket]" >&2
  echo "  --websocket  额外放行 WebSocket 端口 TCP 21118-21119" >&2
}

for arg in "$@"; do
  case "$arg" in
    --websocket) ALLOW_WEBSOCKET=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $arg" >&2; usage; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "请用 sudo 运行" >&2
  exit 1
fi

IMAGE="rustdesk/rustdesk-server:1.1.16"
COMPOSE_FILE="$PWD/docker-compose.yml"
DATA_DIR="$PWD/data"
PUB_KEY="$DATA_DIR/id_ed25519.pub"
PRIV_KEY="$DATA_DIR/id_ed25519"

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "缺少 compose 文件：$COMPOSE_FILE" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  cat >&2 <<'EOF'
未安装 Docker。请先按官方文档用软件源安装（不要使用 curl | sh 这类管道安装）：
  https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
安装完成并启动 docker 服务后，重新运行本脚本。
EOF
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "未找到 docker compose 或 docker-compose，请先安装 Docker Compose 插件。" >&2
  exit 1
fi

compose() {
  "${COMPOSE[@]}" -f "$COMPOSE_FILE" "$@"
}

prepare_data_dir() {
  if [[ -L "$DATA_DIR" ]]; then
    echo "data 目录是符号链接，拒绝继续：$DATA_DIR" >&2
    exit 1
  fi
  if [[ -e "$DATA_DIR" && ! -d "$DATA_DIR" ]]; then
    echo "data 存在但不是目录：$DATA_DIR" >&2
    exit 1
  fi

  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"

  local owner
  owner=$(stat -c '%u' "$DATA_DIR")
  if [[ "$owner" != "0" ]]; then
    echo "data 目录所有者 uid=$owner，不是 root；请 sudo chown root:root \"$DATA_DIR\" 后重试。" >&2
    exit 1
  fi
}

echo "==> 准备数据目录（0700）"
prepare_data_dir

ADDED_RULES=()
rollback_rules() {
  if [[ ${#ADDED_RULES[@]} -eq 0 ]]; then
    return 0
  fi
  echo "==> 回滚本次新增的 ufw 规则" >&2
  local rule
  for rule in "${ADDED_RULES[@]}"; do
    ufw delete allow "$rule" >/dev/null 2>&1 || true
  done
  ADDED_RULES=()
}

on_error() {
  rollback_rules
}
trap on_error ERR

echo "==> 启动 hbbs / hbbr（$IMAGE）"
compose up -d

container_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q '^true$'
}

echo "==> 等待容器就绪"
ready=false
for _ in $(seq 1 30); do
  if container_running vega-hbbs && container_running vega-hbbr; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  echo "hbbs / hbbr 未在 30 秒内进入 running 状态。日志：" >&2
  compose logs --tail=50 hbbs hbbr >&2 || true
  exit 1
fi

echo "==> 等待生成密钥"
KEY=""
for _ in $(seq 1 20); do
  if [[ -L "$PUB_KEY" ]]; then
    echo "公钥是符号链接，拒绝读取：$PUB_KEY" >&2
    exit 1
  fi
  if [[ -f "$PUB_KEY" && -s "$PUB_KEY" ]]; then
    KEY=$(cat "$PUB_KEY")
    if [[ -n "$KEY" ]]; then
      break
    fi
  fi
  sleep 1
done
if [[ -z "$KEY" ]]; then
  echo "未在 20 秒内生成有效公钥：$PUB_KEY。日志：" >&2
  compose logs --tail=50 hbbs >&2 || true
  exit 1
fi

if [[ -L "$PRIV_KEY" ]]; then
  echo "私钥是符号链接，拒绝处理：$PRIV_KEY" >&2
  exit 1
fi
if [[ -f "$PRIV_KEY" ]]; then
  chmod 600 "$PRIV_KEY"
else
  echo "警告: 未找到私钥文件 $PRIV_KEY，请人工确认服务端密钥" >&2
fi

# 端口：默认只开桌面客户端需要的；WebSocket 需显式 --websocket
TCP_RANGES=("21115:21117")
if [[ "$ALLOW_WEBSOCKET" == true ]]; then
  TCP_RANGES+=("21118:21119")
fi

echo "==> 放行端口（启动成功后）"
if command -v ufw >/dev/null 2>&1; then
  if ! UFW_STATUS=$(ufw status 2>/dev/null); then
    echo "ufw status 查询失败：未自动修改防火墙，请手动放行 TCP 21115-21117、UDP 21116。" >&2
  elif [[ "$UFW_STATUS" == *"Status: active"* ]]; then
    for range in "${TCP_RANGES[@]}"; do
      if ufw allow "$range/tcp" >/dev/null 2>&1; then
        ADDED_RULES+=("$range/tcp")
      else
        echo "ufw allow $range/tcp 失败，请手动放行。" >&2
      fi
    done
    if ufw allow 21116/udp >/dev/null 2>&1; then
      ADDED_RULES+=("21116/udp")
    else
      echo "ufw allow 21116/udp 失败，请手动放行。" >&2
    fi
  else
    echo "ufw 已安装但未启用，跳过；如使用 firewalld 或云安全组请自行放行端口。"
  fi
else
  echo "未安装 ufw，跳过；如使用 firewalld 或云安全组请自行放行端口。"
fi

detect_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip=$(curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
      ip=$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || true)
    fi
  fi
  if [[ -z "$ip" ]]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)
  fi
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  printf '%s' "$ip"
}

IP=$(detect_public_ip | tr -d '[:space:]')

echo
echo "================ 完成 ================"
if [[ -n "$IP" ]]; then
  echo "ID 服务器 / 中继服务器: $IP"
else
  echo "ID 服务器 / 中继服务器: 未能自动探测，请用服务器公网 IP 或域名手动填写"
fi
echo "Key: $KEY"
if [[ "$ALLOW_WEBSOCKET" == true ]]; then
  echo "端口: TCP 21115-21119、UDP 21116（已启用 WebSocket）"
  echo "提醒: 云厂商安全组也要放行 TCP 21115-21119、UDP 21116"
else
  echo "端口: TCP 21115-21117、UDP 21116"
  echo "提醒: 云厂商安全组也要放行 TCP 21115-21117、UDP 21116；需要 WebSocket 时用 --websocket 重跑"
fi
