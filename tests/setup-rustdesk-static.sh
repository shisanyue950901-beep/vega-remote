#!/usr/bin/env bash
# RustDesk 部署脚本 / compose 的轻量静态检查（CI 用，不实跑 docker）。
# 只读文件、不联网、不需要 root。
set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT="server/setup-rustdesk-server.sh"
COMPOSE="server/docker-compose.yml"
errors=0

fail() {
  echo "FAIL: $1" >&2
  errors=$((errors + 1))
}

require() {
  local pattern="$1" message="$2"
  if ! grep -qE -- "$pattern" "$SCRIPT"; then
    fail "$message（找不到 $pattern）"
  fi
}

forbid() {
  local pattern="$1" message="$2"
  if grep -qE -- "$pattern" "$SCRIPT"; then
    fail "$message（不该出现 $pattern）"
  fi
}

echo "==> bash -n $SCRIPT"
bash -n "$SCRIPT"

echo "==> 必需行为"
require -- '--reinstall' '必须支持 --reinstall'
require '检测到已有 RustDesk 部署' '已有容器时必须给出 --reinstall 提示'
require 'compose ps -a -q' '启动前必须检查项目已有容器'
require 'ss -lntup' '启动前必须检查端口占用'
require '21115 21116 21117 21118 21119' '端口占用检查必须覆盖 21115-21119'
require 'ATTEMPTED=true' 'compose up 之前必须置 ATTEMPTED=true'
require 'ufw deny 21118:21119/tcp' '未启用 WebSocket 且默认 deny 时必须阻断 21118/21119'
require '21118/21119（WebSocket）也会对外可达' '默认 allow / UFW 未启用时必须警告 WebSocket 暴露'
require '请用云厂商安全组只放行 TCP 21115-21117、UDP 21116' '警告必须给出安全组最小放行范围'

echo "==> 禁止的旧逻辑"
forbid 'HAS_PRE_EXISTING' '必须删除 HAS_PRE_EXISTING 分支'
forbid 'RESTART_BASELINE' '必须删除跨容器重启计数基线'
forbid 'record_container_baseline' '必须删除旧基线采集函数'

echo "==> 顺序：先 ATTEMPTED，再 compose up"
attempted_line=$(grep -n 'ATTEMPTED=true' "$SCRIPT" | head -1 | cut -d: -f1)
up_line=$(grep -n '^compose up -d$' "$SCRIPT" | head -1 | cut -d: -f1)
if [[ -z "$attempted_line" || -z "$up_line" ]]; then
  fail '找不到 ATTEMPTED=true 或 compose up -d'
elif (( attempted_line >= up_line )); then
  fail "ATTEMPTED=true（第 $attempted_line 行）必须在 compose up -d（第 $up_line 行）之前"
fi

echo "==> compose：hbbs / hbbr 都用 host 网络且不发布端口"
for service in hbbs hbbr; do
  block=$(awk -v svc="  $service:" '$0 == svc { inblock = 1; next } /^  [a-z]/ { inblock = 0 } inblock' "$COMPOSE")
  if [[ -z "$block" ]]; then
    fail "compose 里找不到服务 $service"
    continue
  fi
  if ! grep -qE '^[[:space:]]+network_mode:[[:space:]]+host[[:space:]]*$' <<<"$block"; then
    fail "服务 $service 必须是 network_mode: host"
  fi
  if grep -qE '^[[:space:]]+ports:' <<<"$block"; then
    fail "服务 $service 不应发布端口"
  fi
done

if (( errors > 0 )); then
  echo "共 $errors 项检查失败" >&2
  exit 1
fi
echo "全部通过"
