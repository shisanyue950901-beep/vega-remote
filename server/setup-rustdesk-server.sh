#!/usr/bin/env bash
# Vega Remote - RustDesk 自建中继一键部署（Debian/Ubuntu）
#
# 设计要点：
#   - 不从网络管道安装 Docker（不用 curl | sh）；未安装时提示按官方文档用软件源安装后退出。
#   - 镜像固定 rustdesk/rustdesk-server:1.1.16，部署与 CI 使用同一份 compose 文件。
#   - 用 host 网络，不发布端口：Docker 的端口发布经过 DNAT，不经过 UFW 的 INPUT 规则，
#     会绕过已有的入站限制；host 网络下 ufw 规则才真正生效。
#   - 只支持全新部署：启动前项目里已有容器时默认拒绝；--reinstall 先 compose down，
#     数据目录和密钥保留，再按全新流程部署。
#   - 启动前用 ss -lntup 检查 21115-21119 是否已被占用（只看本地地址列的端口），占用则拒绝。
#   - 本脚本不修改防火墙：不执行任何 ufw allow/deny，也不回滚规则。
#     部署完成后只打印需要放行的端口清单、ufw 示例命令和云安全组建议。
#     --websocket 只影响提示文字（是否列出 TCP 21118-21119）。
#   - UFW 未启用/未安装，或已启用但默认入站为 allow 时，打印醒目警告：
#     21118/21119（WebSocket）也会对外可达，请用云安全组只放行 TCP 21115-21117、UDP 21116。
#   - compose 一律 --env-file /dev/null，避免读取项目里的 .env 改变部署结果。
#   - 启动前完成数据目录检查（0700、属主 root、非符号链接、父目录非他人可写）
#     与已有私钥检查（普通文件、0600）；任何一项不满足立即退出。
#   - compose up 之前置 ATTEMPTED=true；失败时一定 compose down（容器都是本次新建的）。
#   - 就绪判定按 up 后采样的容器 ID：ID 必须不变、RestartCount 必须保持 0 持续 5 秒。
#   - 公钥是 44 字符 base64，私钥是普通文件且 0600。
set -euo pipefail
cd "$(dirname "$0")"

ALLOW_WEBSOCKET=false
REINSTALL=false
usage() {
  echo "用法: sudo bash setup-rustdesk-server.sh [--websocket] [--reinstall]" >&2
  echo "  --websocket  提示中额外列出 WebSocket 端口 TCP 21118-21119（脚本不改防火墙）" >&2
  echo "  --reinstall  已有部署时先 compose down（数据目录和密钥保留）再重新部署" >&2
}

for arg in "$@"; do
  case "$arg" in
    --websocket) ALLOW_WEBSOCKET=true ;;
    --reinstall) REINSTALL=true ;;
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
DATA_DIR="$PWD/data"
PUB_KEY="$DATA_DIR/id_ed25519.pub"
PRIV_KEY="$DATA_DIR/id_ed25519"

if [[ ! -f "$BASE_COMPOSE" ]]; then
  echo "缺少 compose 文件：$BASE_COMPOSE" >&2
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

compose() {
  # --env-file /dev/null：不读项目里的 .env，部署结果只由 compose 文件决定
  "${COMPOSE[@]}" --env-file /dev/null "${COMPOSE_FILES[@]}" "$@"
}

ATTEMPTED=false
CLEANED=false

# 退出路径统一走 EXIT trap：fail()/exit 1 这类“函数内 if 分支里的退出”
# 不会触发 ERR trap，只有 EXIT 能保证停掉本次启动的容器。
cleanup_on_error() {
  if [[ "$CLEANED" == true ]]; then
    return 0
  fi
  CLEANED=true
  if [[ "$ATTEMPTED" != true ]]; then
    return 0
  fi
  # 只支持全新部署（--reinstall 会先 down），所以这里的容器一定是本次新建的
  echo "==> 清理本次启动的容器" >&2
  compose down >/dev/null 2>&1 || true
  return 0
}
trap cleanup_on_error EXIT

fail() {
  echo "$1" >&2
  exit 1
}

check_parent_dir() {
  local parent
  parent=$(dirname "$DATA_DIR")
  [[ -L "$parent" ]] && fail "数据目录的父目录是符号链接，拒绝继续：$parent"
  local mode
  mode=$(stat -c '%a' "$parent")
  # 父目录其他人可写时，别人可以替换 data 目录；属主不强制为 root。
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

check_no_existing_deployment() {
  local ids
  if ! ids=$(compose ps -a -q 2>/dev/null); then
    fail "无法读取 compose 项目现有容器（compose ps 失败）。"
  fi
  if [[ -z "$ids" ]]; then
    return 0
  fi
  if [[ "$REINSTALL" != true ]]; then
    fail "检测到已有 RustDesk 部署。如需重装，请加 --reinstall（会先 compose down，数据目录和密钥保留）"
  fi
  echo "==> --reinstall：先 compose down 现有部署（数据目录和密钥保留）"
  compose down || fail "compose down 失败，中止。"
}

check_ports_free() {
  if ! command -v ss >/dev/null 2>&1; then
    fail "未找到 ss（iproute2），无法确认 21115-21119 是否被占用。"
  fi
  local listening port
  if ! listening=$(ss -lntup 2>/dev/null); then
    fail "ss -lntup 查询失败，无法确认端口占用。"
  fi
  for port in 21115 21116 21117 21118 21119; do
    # 只解析本地地址列（ss 的第 5 列，形如 0.0.0.0:21115 或 [::]:21115），
    # 取最后一个冒号后的端口；进程名里的 21115 之类不能算作监听端口。
    if awk -v p="$port" '
      NR > 1 {
        n = split($5, parts, ":")
        if (parts[n] == p) { found = 1 }
      }
      END { exit found ? 0 : 1 }
    ' <<<"$listening"; then
      fail "端口 $port 已被占用（ss -lntup），拒绝启动。请先释放端口后重试。"
    fi
  done
}

container_restarts() {
  local value
  value=$(docker inspect -f '{{.RestartCount}}' "$1" 2>/dev/null || true)
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf '-1'
    return 0
  fi
  printf '%s' "$value"
}

record_container_ids() {
  local name current_id
  for name in vega-hbbs vega-hbbr; do
    current_id=$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null || true)
    if [[ -z "$current_id" ]]; then
      fail "compose up 后找不到容器：$name"
    fi
    EXPECTED_ID[$name]="$current_id"
  done
}

wait_containers_ready() {
  local stable=0
  # 默认最多等 60 秒；测试里用 VEGA_READY_ATTEMPTS 缩短，不能延长就绪判定本身
  local attempts="${VEGA_READY_ATTEMPTS:-60}"
  local name current_id restarts running
  for _ in $(seq 1 "$attempts"); do
    local ok=1
    for name in vega-hbbs vega-hbbr; do
      current_id=$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null || true)
      restarts=$(container_restarts "$name")
      running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)
      # 容器 ID 必须还是 up 后采样的那个，RestartCount 必须一直是 0
      if [[ "$current_id" != "${EXPECTED_ID[$name]:-}" || "$restarts" != "0" || "$running" != "true" ]]; then
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

echo "==> 检查现有部署"
check_no_existing_deployment

echo "==> 检查数据目录与已有密钥"
prepare_data_dir
check_existing_keys

echo "==> 检查端口占用（21115-21119）"
check_ports_free

echo "==> 启动 hbbs / hbbr（$IMAGE）"
ATTEMPTED=true
compose up -d
declare -A EXPECTED_ID=()
record_container_ids

echo "==> 等待容器就绪（ID 不变且 RestartCount 为 0，持续 5 秒）"
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

# 端口：host 网络下服务自己监听 21115-21119；本脚本不修改防火墙，只打印放行清单。
ufw_default_incoming() {
  local verbose="$1"
  if [[ "$verbose" =~ Default:\ (deny|reject|allow)\ \(incoming\) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf 'unknown'
  fi
}

warn_ufw_not_enabled() {
  cat >&2 <<'EOF'
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
警告：未检测到启用的 UFW，21115-21119 将直接对外暴露，其中
      21118/21119（WebSocket）也会对外可达。
      请用云厂商安全组只放行 TCP 21115-21117、UDP 21116。
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
}

warn_websocket_reachable() {
  cat >&2 <<'EOF'
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
警告：UFW 默认入站为 allow，21118/21119（WebSocket）也会对外可达。
      请用云厂商安全组只放行 TCP 21115-21117、UDP 21116。
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
}

warn_ufw_unknown() {
  cat >&2 <<'EOF'
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
警告：无法确认 UFW 状态，21115-21119 的入站范围需要你自行核对。
      脚本不会修改防火墙规则；请按完成提示里的端口清单检查 ufw 与云安全组。
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
}

# 只读检查：脚本不执行任何 ufw allow/deny，也不回滚规则。
echo "==> 检查防火墙状态（只提示，不修改规则）"
if command -v ufw >/dev/null 2>&1; then
  if ! UFW_STATUS=$(ufw status 2>/dev/null); then
    warn_ufw_unknown
  elif [[ "$UFW_STATUS" == *"Status: active"* ]]; then
    if ! UFW_VERBOSE=$(ufw status verbose 2>/dev/null); then
      warn_ufw_unknown
    else
      DEFAULT_IN=$(ufw_default_incoming "$UFW_VERBOSE")
      if [[ "$DEFAULT_IN" == "allow" ]]; then
        warn_websocket_reachable
      else
        echo "UFW 已启用，默认入站为 $DEFAULT_IN。脚本不会修改规则，请按完成提示核对放行端口。"
      fi
    fi
  else
    warn_ufw_not_enabled
  fi
else
  warn_ufw_not_enabled
fi

print_port_guidance() {
  local tcp_list="21115-21117"
  if [[ "$ALLOW_WEBSOCKET" == true ]]; then
    tcp_list="21115-21119"
  fi
  echo "需要放行的端口（脚本不会代跑 ufw，请自行确认）："
  echo "  TCP: $tcp_list"
  echo "  UDP: 21116"
  if [[ "$ALLOW_WEBSOCKET" == true ]]; then
    echo "  已含 WebSocket：TCP 21118-21119"
  fi
  cat <<EOF
ufw 示例：
  sudo ufw allow 21115:21117/tcp
  sudo ufw allow 21116/udp
EOF
  if [[ "$ALLOW_WEBSOCKET" == true ]]; then
    echo "  sudo ufw allow 21118:21119/tcp"
  fi
  cat <<EOF
云安全组建议：只放行 TCP $tcp_list、UDP 21116。
未启用 UFW 或默认入站为 allow 时，安全组是唯一防线。
EOF
}

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
if [[ "$ALLOW_WEBSOCKET" != true ]]; then
  echo "提示: 需要 WebSocket 时用 --websocket 重跑，提示会额外列出 TCP 21118-21119。"
fi
print_port_guidance
