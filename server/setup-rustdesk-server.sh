#!/usr/bin/env bash
# Vega Remote - RustDesk 自建中继一键部署（Debian/Ubuntu）
#
# 设计要点：
#   - 不从网络管道安装 Docker（不用 curl | sh）；未安装时提示按官方文档用软件源安装后退出。
#   - 镜像固定 rustdesk/rustdesk-server:1.1.16，部署与 CI 使用同一份 compose 文件。
#   - 用 host 网络，不发布端口：Docker 的端口发布经过 DNAT，不经过 UFW 的 INPUT 规则，
#     会绕过已有的入站限制；host 网络下 ufw 规则才真正生效。
#   - --websocket 只决定是否额外 ufw allow 21118/21119（host 网络下服务本来就在这些端口监听）。
#   - 未检测到启用的 UFW 时打印醒目警告：21115-21119 将直接暴露，安全组只放行必要端口。
#   - compose 一律 --env-file /dev/null，避免读取项目里的 .env 改变部署结果。
#   - 启动前完成数据目录检查（0700、属主 root、非符号链接、父目录非他人可写）
#     与已有私钥检查（普通文件、0600）；任何一项不满足立即退出。
#   - 启动前记录项目已有容器及其 RestartCount；只有启动前项目没有任何容器时，
#     失败才 compose down。就绪判定用本次检查期间的 RestartCount 增量。
#   - 公钥是 44 字符 base64，私钥是普通文件且 0600；失败时回滚本次新增的 ufw 规则。
#   - ufw 每条 allow 前先查该规则是否已存在，已存在的不计入本次新增；只撤销本次新增的规则。
set -euo pipefail
cd "$(dirname "$0")"

ALLOW_WEBSOCKET=false
usage() {
  echo "用法: sudo bash setup-rustdesk-server.sh [--websocket]" >&2
  echo "  --websocket  额外放行 WebSocket 端口 TCP 21118-21119（host 网络下服务本来就监听）" >&2
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

ADDED_RULES=()
STARTED=false
CLEANED=false
# up 之前项目里是否已经有容器：有就绝不在失败时 compose down
HAS_PRE_EXISTING=false
declare -A RESTART_BASELINE=()

rollback_rules() {
  if [[ ${#ADDED_RULES[@]} -eq 0 ]]; then
    return 0
  fi
  echo "==> 回滚本次新增的 ufw 规则" >&2
  local rule
  for rule in "${ADDED_RULES[@]}"; do
    if ! ufw delete allow "$rule" >/dev/null 2>&1; then
      echo "回滚 ufw 规则失败，请手动执行：ufw delete allow $rule" >&2
    fi
  done
  ADDED_RULES=()
}

# 退出路径统一走 EXIT trap：fail()/exit 1 这类“函数内 if 分支里的退出”
# 不会触发 ERR trap，只有 EXIT 能保证撤销本次新增的 ufw 规则、停掉本次启动的容器。
cleanup_on_error() {
  if [[ "$CLEANED" == true ]]; then
    return 0
  fi
  CLEANED=true
  rollback_rules
  if [[ "$STARTED" != true ]]; then
    return 0
  fi
  if [[ "$HAS_PRE_EXISTING" == false ]]; then
    echo "==> 清理本次启动的容器" >&2
    compose down >/dev/null 2>&1 || true
  else
    # 启动前就有容器：不能 compose down，那会删掉正在用的部署
    echo "==> 启动前项目里已有容器，失败时不删除；请手动检查：docker compose ps" >&2
  fi
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

container_running() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q '^true$'
}

container_restarts() {
  # 容器不存在或 inspect 失败时按 0 计：基线只用来算“本次检查期间的增量”
  local value
  value=$(docker inspect -f '{{.RestartCount}}' "$1" 2>/dev/null || true)
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf '0'
    return 0
  fi
  printf '%s' "$value"
}

record_container_baseline() {
  # 启动前记录项目已有容器与各自 RestartCount；重跑时绝不能删别人的部署
  local ids
  if ! ids=$(compose ps -a -q 2>/dev/null); then
    fail "无法读取 compose 项目现有容器（compose ps 失败）。"
  fi
  if [[ -n "$ids" ]]; then
    HAS_PRE_EXISTING=true
    echo "==> 项目里已有容器，本次失败不会删除它们"
  fi
  local name
  for name in vega-hbbs vega-hbbr; do
    RESTART_BASELINE[$name]=$(container_restarts "$name")
  done
}

wait_containers_ready() {
  local stable=0
  # 默认最多等 60 秒；测试里用 VEGA_READY_ATTEMPTS 缩短，不能延长就绪判定本身
  local attempts="${VEGA_READY_ATTEMPTS:-60}"
  for _ in $(seq 1 "$attempts"); do
    local ok=1
    local name current baseline delta
    for name in vega-hbbs vega-hbbr; do
      current=$(container_restarts "$name")
      baseline=${RESTART_BASELINE[$name]:-0}
      delta=$((current - baseline))
      # 只看本次检查期间的增量：历史重启计数不能算本次不稳定
      if ! container_running "$name" || (( delta != 0 )); then
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

echo "==> 记录项目已有容器（host 网络，不发布端口）"
record_container_baseline

echo "==> 启动 hbbs / hbbr（$IMAGE）"
compose up -d
# 只有 up 成功才标记 STARTED：失败时是否清理还要看 up 前有没有容器
STARTED=true

echo "==> 等待容器就绪（running 且本次重启增量为 0，持续 5 秒）"
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

# 端口：host 网络下服务自己监听 21115-21119；这里只决定 ufw 放行哪些
TCP_RULES=("21115:21117/tcp")
UDP_RULES=("21116/udp")
if [[ "$ALLOW_WEBSOCKET" == true ]]; then
  TCP_RULES+=("21118:21119/tcp")
fi

# ufw 里已经有同一条规则时，ufw allow 也会成功，但那是别人的规则，不能算本次新增
ufw_rule_present() {
  local rule="$1" status
  if ! status=$(ufw status 2>/dev/null); then
    fail "ufw status 查询失败，无法确认端口放行状态；请修复 ufw 后重试。"
  fi
  awk -v rule="$rule" '$1 == rule && $2 == "ALLOW" { found = 1 } END { exit found ? 0 : 1 }' <<<"$status"
}

warn_ufw_not_enabled() {
  cat >&2 <<'EOF'
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
警告：未检测到启用的 UFW，21115-21119 将直接暴露，请在云厂商安全组只放行
      TCP 21115-21117、UDP 21116。
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
}

echo "==> 放行端口（容器就绪后，逐条检查失败即退出）"
if command -v ufw >/dev/null 2>&1; then
  if ! UFW_STATUS=$(ufw status 2>/dev/null); then
    fail "ufw status 查询失败，无法确认端口放行状态；请修复 ufw 后重试。"
  elif [[ "$UFW_STATUS" == *"Status: active"* ]]; then
    for rule in "${TCP_RULES[@]}" "${UDP_RULES[@]}"; do
      if ufw_rule_present "$rule"; then
        echo "    已存在，不计入本次新增：$rule"
        continue
      fi
      if ufw allow "$rule" >/dev/null 2>&1; then
        ADDED_RULES+=("$rule")
      else
        echo "ufw allow $rule 失败。" >&2
        exit 1
      fi
    done
  else
    warn_ufw_not_enabled
  fi
else
  warn_ufw_not_enabled
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
