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
require 'print_port_guidance' '部署完成后必须打印端口放行清单与 ufw 示例'
require 'sudo ufw allow 21115:21117/tcp' 'ufw 示例必须包含 TCP 21115-21117'
require 'sudo ufw allow 21116/udp' 'ufw 示例必须包含 UDP 21116'
require '云安全组建议' '必须给出云安全组建议'
require '21118/21119（WebSocket）也会对外可达' '默认 allow / UFW 未启用时必须警告 WebSocket 暴露'
require '请用云厂商安全组只放行 TCP 21115-21117、UDP 21116' '警告必须给出安全组最小放行范围'

echo "==> ss 端口预检只解析本地地址列"
# shellcheck disable=SC2016  # 正则里的 $ 是 awk 字段
require 'split\(\$5, parts, ":"\)' 'ss 预检必须只解析第 5 列（本地地址）'
# shellcheck disable=SC2016  # 正则里的 $ 是 awk 行
forbid '\$0 ~ \(":" p' 'ss 预检不能匹配整行（会把进程名里的端口算进来）'
ss_sample='Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
udp   UNCONN 0      0      0.0.0.0:5353       0.0.0.0:*    users:(("worker:21119",pid=1,fd=3))
tcp   LISTEN 0      0      0.0.0.0:21115      0.0.0.0:*    users:(("hbbs",pid=2,fd=4))'
ss_ports=$(awk 'NR > 1 { n = split($5, parts, ":"); print parts[n] }' <<<"$ss_sample" | sort -u | tr '\n' ' ')
if [[ "$ss_ports" != "21115 5353 " ]]; then
  fail "ss 第 5 列解析结果不对：$ss_ports"
fi

echo "==> 禁止的旧逻辑"
forbid 'HAS_PRE_EXISTING' '必须删除 HAS_PRE_EXISTING 分支'
forbid 'RESTART_BASELINE' '必须删除跨容器重启计数基线'
forbid 'record_container_baseline' '必须删除旧基线采集函数'
forbid '^[[:space:]]*ufw (allow|deny|delete)' '脚本不得修改 UFW 规则'
forbid 'ADDED_RULES' '必须删除 UFW 规则记账'
forbid 'rollback_rules' '必须删除 UFW 回滚逻辑'
forbid 'ufw_status_has_port_rules' '必须删除 UFW 规则识别逻辑'

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
