#!/usr/bin/env bash
# Vega Remote - RustDesk 自建中继一键部署（Debian/Ubuntu）
#
# 设计要点：
#   - 不从网络管道安装 Docker（不用 curl | sh）；未安装时提示按官方文档用软件源安装后退出。
#   - 镜像固定 rustdesk/rustdesk-server:1.1.16，部署与 CI 使用同一份 compose 文件。
#   - 不用 host 网络：只发布 21115-21117/tcp、21116/udp；
#     WebSocket 的 21118/21119 在 docker-compose.websocket.yml 覆盖文件里，只有 --websocket 才叠加。
#   - compose 一律 --env-file /dev/null，避免读取项目里的 .env 改变部署结果。
#   - 启动前完成数据目录检查（0700、属主 root、非符号链接、父目录非他人可写）
#     与已有私钥检查（普通文件、0600）；任何一项不满足立即退出。
#   - 启动后要求两个容器持续 5 秒 running 且 restart 计数为 0，公钥是 44 字符 base64，
#     私钥是普通文件且 0600；失败时只清理本次启动的容器并回滚本次新增的 ufw 规则。
#   - ufw 每条 allow 失败都返回非零，只撤销本次新增的规则。
set -euo pipefail
cd "$(dirname "$0")"

ALLOW_WEBSOCKET=false
usage() {
  echo "用法: sudo bash setup-rustdesk-server.sh [--websocket]" >&2
  echo "  --websocket  额外发布并放行 WebSocket 端口 TCP 21118-21119" >&2
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
BASE_COMPOSE="$PWD/docker-compose.yml"
WS_COMPOSE="$PWD/docker-compose.websocket.yml"
DATA_DIR="$PWD/data"
PUB_KEY="$DATA_DIR/id_ed25519.pub"
PRIV_KEY="$DATA_DIR/id_ed25519"

if [[ ! -f "$BASE_COMPOSE" ]]; then
  echo "缺少 compose 文件：$BASE_COMPOSE" >&2
  exit 1
fi
if [[ "$ALLOW_WEBSOCKET" == true && ! -f "$WS_COMPOSE" ]]; then
  echo "缺少 WebSocket 覆盖文件：$WS_COMPOSE" >&2
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

COMPOSE_FILES=(-f "$BASE_COMPOSE")
if [[ "$ALLOW_WEBSOCKET" == true ]]; then
  COMPOSE_FILES+=(-f "$WS_COMPOSE")
fi

compose() {
  # --env-file /dev/null：不读项目里的 .env，部署结果只由这两份 compose 文件决定
  "${COMPOSE[@]}" --env-file /dev/null "${COMPOSE_FILES[@]}" "$@"
}

ADDED_RULES=()
STARTED=false
CLEANED=false

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

cleanup_on_error() {
  local code=$?
  if [[ "$CLEANED" == true ]]; then
    exit "$code"
  fi
  CLEANED=true
  rollback_rules
  if [[ "$STARTED" == true ]]; then
    echo "==> 清理本次启动的容器" >&2
    compose down >/dev/null 2>&1 || true
  fi
  exit "$code"
}
trap cleanup_on_error ERR

fail() {
  echo "$1" >&2
  exit 1
}

check_parent_dir() {
  local parent
  parent=$(dirname "$DATA_DIR")
  [[ -L "$parent" ]] && fail "数据目录的父目录是符号链接，拒绝继续：$parent"
  local owner_sid mode
  owner_sid=$(stat -c '%u' "$parent")
  if [[ "$owner_sid" != "0" ]]; then
    fail "数据目录的父目录所有者 uid=$owner_sid，不是 root；请 sudo chown root:root \"$parent\" 后重试。"
  fi
  mode=$(stat -c '%a' "$parent")
  # 其他用户可写（o+w）时不安全，父目录可被别人换掉
  if (( 8#$mode & 8#002 )); then
    fail "数据目录的父目录 $parent 其他人可写（$mode），请先 chmod o-w 后重试。"
  fi
}

prepare_data_dir() {
  if [[ -L "$DATA_DIR" ]]; then
    fail "data 目录是符号链接，拒绝继续：$DATA_DIR"
  fi
  if [[ -e "$DATA_DIR" && ! -d "$DATA_DIR" ]]; then
    fail "data 存在但不是目录：$DATA_DIR"
  fi

  check_parent_dir

  if [[ ! -d "$DATA_DIR" ]]; then
    # 先建目录再收权限：umask 077 保证创建瞬间就不是 0755
    (umask 077 && mkdir -p "$DATA_DIR") || fail "无法创建数据目录：$DATA_DIR"
  fi

  local owner
  owner=$(stat -c '%u' "$DATA_DIR")
  if [[ "$owner" != "0" ]]; then
    fail "data 目录所有者 uid=$owner，不是 root；请 sudo chown -R root:root \"$DATA_DIR\" 后重试。"
  fi
  if [[ -L "$DATA_DIR" ]]; then
    fail "data 目录变成了符号链接，拒绝继续：$DATA_DIR"
  fi

  chmod 700 "$DATA_DIR"
  local mode
  mode=$(stat -c '%a' "$DATA_DIR")
  if [[ "$mode" != "700" ]]; then
    fail "data 目录权限是 $mode，不是 700。"
  fi
}

check_existing_keys() {
  if [[ -e "$PRIV_KEY" || -L "$PRIV_KEY" ]]; then
    if [[ -L "$PRIV_KEY" ]]; then
      fail "私钥是符号链接，拒绝启动：$PRIV_KEY"
    fi
    if [[ ! -f "$PRIV_KEY" ]]; then
      fail "私钥不是普通文件，拒绝启动：$PRIV_KEY"
    fi
    chmod 600 "$PRIV_KEY"
    local mode
    mode=$(stat -c '%a' "$PRIV_KEY")
    if [[ "$mode" != "600" ]]; then
      fail "私钥权限是 $mode，无法收紧到 600：$PRIV_KEY"
    fi
  fi
  if [[ -e "$PUB_KEY" || -L "$PUB_KEY" ]]; then
    if [[ -L "$PUB_KEY" ]]; then
      fail "公钥是符号链接，拒绝读取：$PUB_KEY"
    fi
    if [[ ! -f "$PUB_KEY" ]]; then
      fail "公钥不是普通文件，拒绝读取：$PUB_KEY"
    fi
  fi
}

container_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q '^true$'
}

container_restarts() {
  docker inspect -f '{{.RestartCount}}' "$1" 2>/dev/null || echo "unknown"
}

wait_containers_ready() {
  local stable=0
  for _ in $(seq 1 60); do
    local ok=1
    local name
    for name in vega-hbbs vega-hbbr; do
      local restarts
      restarts=$(container_restarts "$name")
      if ! container_running "$name" || [[ "$restarts" != "0" ]]; then
        ok=0
      fi
    done
    if [[ $ok -eq 1 ]]; then
      stable=$((stable + 1))
      if [[ $stable -ge 5 ]]; then
        return 0
      fi
    else
      stable=0
    fi
    sleep 1
  done
  return 1
}

echo "==> 检查数据目录与已有密钥"
prepare_data_dir
check_existing_keys

echo "==> 启动 hbbs / hbbr（$IMAGE，端口发布，无 host 网络）"
STARTED=true
compose up -d

echo "==> 等待容器就绪（running 且 restart 计数为 0，持续 5 秒）"
if ! wait_containers_ready; then
  echo "hbbs / hbbr 未在 60 秒内稳定运行。日志：" >&2
  compose logs --tail=50 hbbs hbbr >&2 || true
  exit 1
fi

echo "==> 等待并校验密钥对"
KEY=""
for _ in $(seq 1 20); do
  if [[ -L "$PUB_KEY" ]]; then
    fail "公钥是符号链接，拒绝读取：$PUB_KEY"
  fi
  if [[ -f "$PUB_KEY" ]]; then
    candidate=$(tr -d '[:space:]' <"$PUB_KEY" 2>/dev/null || true)
    if [[ "$candidate" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
      KEY="$candidate"
      break
    fi
  fi
  sleep 1
done
if [[ -z "$KEY" ]]; then
  echo "未在 20 秒内生成有效的 44 字符 base64 公钥：$PUB_KEY。日志：" >&2
  compose logs --tail=50 hbbs >&2 || true
  exit 1
fi

if [[ -L "$PRIV_KEY" ]]; then
  fail "私钥是符号链接，拒绝处理：$PRIV_KEY"
fi
if [[ ! -f "$PRIV_KEY" ]]; then
  fail "未找到私钥文件 $PRIV_KEY，服务端密钥不完整。"
fi
chmod 600 "$PRIV_KEY"
PRIV_MODE=$(stat -c '%a' "$PRIV_KEY")
if [[ "$PRIV_MODE" != "600" ]]; then
  fail "私钥权限是 $PRIV_MODE，不是 600：$PRIV_KEY"
fi

# 端口：默认只开桌面客户端需要的；WebSocket 需显式 --websocket
TCP_RULES=("21115:21117/tcp")
UDP_RULES=("21116/udp")
if [[ "$ALLOW_WEBSOCKET" == true ]]; then
  TCP_RULES+=("21118:21119/tcp")
fi

echo "==> 放行端口（容器就绪后，逐条检查失败即退出）"
if command -v ufw >/dev/null 2>&1; then
  if ! UFW_STATUS=$(ufw status 2>/dev/null); then
    echo "ufw status 查询失败：未自动修改防火墙，请手动放行 TCP 21115-21117、UDP 21116。" >&2
  elif [[ "$UFW_STATUS" == *"Status: active"* ]]; then
    for rule in "${TCP_RULES[@]}" "${UDP_RULES[@]}"; do
      if ufw allow "$rule" >/dev/null 2>&1; then
        ADDED_RULES+=("$rule")
      else
        echo "ufw allow $rule 失败。" >&2
        exit 1
      fi
    done
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

CLEANED=true

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
