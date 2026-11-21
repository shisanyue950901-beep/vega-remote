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
require '可选放行 WebSocket 端口 TCP 21118-21119' '完成提示必须直接列出可选 WebSocket 端口'
require '启用时核对旧拒绝规则和云安全组' '完成提示必须提醒核对旧拒绝规则与云安全组'
require '\-\-reinstall \-\-websocket' '完成提示必须说明重装时才用 --reinstall --websocket'

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
forbid '用 --websocket 重跑' '完成提示不能建议用 --websocket 重跑'

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


echo "==> 公网 IP 探测行为（隔离 curl mock）"
# shellcheck source=server/lib/ip-detect.sh
. server/lib/ip-detect.sh

mock_dir=$(mktemp -d)
trap 'rm -rf "$mock_dir"' EXIT
cat > "$mock_dir/curl" <<'MOCK'
#!/usr/bin/env bash
log="${FAKE_CURL_LOG:-/dev/null}"
printf '%s\n' "$*" >> "$log"
url=""
for arg in "$@"; do
  case "$arg" in
    http://*|https://*) url="$arg" ;;
  esac
done
case "$url" in
  *latest/api/token)
    [[ "${FAKE_CURL_MODE:-ok}" == "token-fail" ]] && exit 22
    printf 'FAKE-TOKEN=='
    ;;
  *meta-data/eipv4)
    [[ "${FAKE_CURL_MODE:-ok}" == "token-fail" ]] && exit 22
    printf '%s' "${FAKE_EIP:-}"
    ;;
  *ifconfig\.me*)
    printf '%s' "${FAKE_HTTP_IP:-}"
    ;;
  *api\.ipify\.org*)
    printf '%s' "${FAKE_IPIFY_IP:-}"
    ;;
esac
exit 0
MOCK
cat > "$mock_dir/ip" <<'MOCK'
#!/usr/bin/env bash
# 模拟 `ip -4 route get 1.1.1.1`：只输出带 src 的一行。
if [[ -n "${FAKE_ROUTE_IP:-}" ]]; then
  printf '1.1.1.1 via 10.0.0.1 dev eth0 src %s uid 0\n' "$FAKE_ROUTE_IP"
fi
MOCK
cat > "$mock_dir/hostname" <<'MOCK'
#!/usr/bin/env bash
if [[ -n "${FAKE_HOSTNAME_IP:-}" ]]; then
  printf '%s\n' "$FAKE_HOSTNAME_IP"
fi
MOCK
chmod +x "$mock_dir/curl" "$mock_dir/ip" "$mock_dir/hostname"
old_path="$PATH"
export PATH="$mock_dir:$PATH"

run_probe() {
  : > "$mock_dir/log"
  FAKE_CURL_LOG="$mock_dir/log" detect_public_ip
}

# 1) IMDSv2：先 PUT 取 token，再带 token GET eipv4；两个请求都绕过代理。
got=$(FAKE_EIP=93.184.216.34 run_probe)
log=$(cat "$mock_dir/log")
if [[ "$got" != "93.184.216.34" ]]; then
  fail "IMDSv2 成功路径返回值不对：$got"
fi
if ! grep -q 'latest/api/token' <<<"$log" || ! grep -q -- '-X PUT' <<<"$log"; then
  fail "必须先 PUT /latest/api/token（日志：$log）"
fi
if ! grep -q 'X-aliyun-ecs-metadata-token-ttl-seconds: 60' <<<"$log"; then
  fail "取 token 时必须带 TTL 头"
fi
if ! grep -q -- '--noproxy \*' <<<"$log"; then
  fail "元数据请求必须 --noproxy '*'"
fi
if ! grep -q 'X-aliyun-ecs-metadata-token: FAKE-TOKEN==' <<<"$log"; then
  fail "取 eipv4 时必须带 IMDSv2 token"
fi

# 2) 拿不到 token 时不发无令牌 eipv4 请求，直接回退到公网探测。
got=$(FAKE_CURL_MODE=token-fail FAKE_HTTP_IP=8.8.4.4 run_probe)
log=$(cat "$mock_dir/log")
if [[ "$got" != "8.8.4.4" ]]; then
  fail "token 失败时应回退到 ifconfig.me，实际：$got"
fi
if grep -q 'meta-data/eipv4' <<<"$log"; then
  fail "没拿到 IMDSv2 token 时不应请求 eipv4"
fi

# 3) HTML 响应不能被当成地址；成功请求返回合法 IPv4 才采用。
got=$(FAKE_EIP='<html>error</html>' FAKE_HTTP_IP=8.8.4.4 run_probe)
if [[ "$got" != "8.8.4.4" ]]; then
  fail "HTML 响应必须被丢弃，实际：$got"
fi

# 4) 内网 eipv4 必须丢弃并回退。
for private in 10.0.0.5 172.16.3.4 192.168.1.9 169.254.1.1; do
  got=$(FAKE_EIP="$private" FAKE_HTTP_IP=8.8.4.4 run_probe)
  if [[ "$got" != "8.8.4.4" ]]; then
    fail "内网地址 $private 必须被丢弃，实际：$got"
  fi
done

# 5) ifconfig.me 返回非法值（含部分输出/非 IPv4）时继续用 ipify。
got=$(FAKE_CURL_MODE=token-fail FAKE_HTTP_IP='198.51.100' FAKE_IPIFY_IP=93.184.216.34 run_probe)
if [[ "$got" != "93.184.216.34" ]]; then
  fail "ifconfig.me 非法响应时应回退到 ipify，实际：$got"
fi
got=$(FAKE_CURL_MODE=token-fail FAKE_HTTP_IP='999.1.1.1' FAKE_IPIFY_IP=93.184.216.34 run_probe)
if [[ "$got" != "93.184.216.34" ]]; then
  fail "越界 IPv4 必须被丢弃，实际：$got"
fi

# 6) 回环 / 本网络 / CGNAT / 组播 / 前导零写法一律不算公网地址。
for bogus in 127.0.0.1 127.10.20.30 0.0.0.0 0.1.2.3 100.64.0.1 100.127.255.254 \
  224.0.0.1 239.255.255.255 240.0.0.1 255.255.255.255 010.1.2.3 192.168.001.1 01.2.3.4; do
  got=$(FAKE_EIP="$bogus" FAKE_HTTP_IP=8.8.4.4 run_probe)
  if [[ "$got" != "8.8.4.4" ]]; then
    fail "不可公网路由的地址 $bogus 必须被丢弃，实际：$got"
  fi
done

# 100.63/100.128 与 223.x 仍是公网单播，不能被上面的网段规则误杀。
for good in 100.63.0.1 100.128.0.1 223.255.255.254; do
  got=$(FAKE_EIP="$good" run_probe)
  if [[ "$got" != "$good" ]]; then
    fail "公网地址 $good 不应被丢弃，实际：$got"
  fi
done

# 7) RFC1918 告警行为。
warn=$(warn_if_private_ipv4 172.20.0.1 2>&1) && warn_code=0 || warn_code=$?
if [[ "$warn_code" -ne 0 || "$warn" != *"自动探测到的是内网地址 172.20.0.1"* ]]; then
  fail "RFC1918 地址必须打印内网警告（退出码 $warn_code，输出：$warn）"
fi
if warn_if_private_ipv4 93.184.216.34 >/dev/null 2>&1; then
  fail "公网地址不应打印内网警告"
fi

# 8) 路由 / hostname 回退：CGNAT、回环、组播等必须丢弃；RFC1918 保留给调用方告警。
for bogus in 100.64.1.2 100.127.255.254 127.0.0.1 169.254.10.20 224.0.0.1 0.0.0.0 010.1.2.3; do
  got=$(FAKE_CURL_MODE=token-fail FAKE_ROUTE_IP="$bogus" FAKE_HOSTNAME_IP="$bogus" run_probe)
  if [[ -n "$got" ]]; then
    fail "回退地址 $bogus 必须被丢弃，实际输出：$got"
  fi
done

got=$(FAKE_CURL_MODE=token-fail FAKE_ROUTE_IP=172.20.5.6 run_probe)
if [[ "$got" != "172.20.5.6" ]]; then
  fail "路由回退的 RFC1918 地址应保留（由调用方告警），实际：$got"
fi
got=$(FAKE_CURL_MODE=token-fail FAKE_ROUTE_IP=93.184.216.34 run_probe)
if [[ "$got" != "93.184.216.34" ]]; then
  fail "路由回退的公网地址应保留，实际：$got"
fi
# hostname 回退同理。
got=$(FAKE_CURL_MODE=token-fail FAKE_HOSTNAME_IP=8.8.4.4 run_probe)
if [[ "$got" != "8.8.4.4" ]]; then
  fail "hostname 回退的公网地址应保留，实际：$got"
fi

# 9) 198.18/15 基准测试网段与 RFC 5737 文档网段都必须是 discard，丢弃后继续下一个来源。
for doc in 198.18.0.1 198.19.255.254 192.0.2.10 198.51.100.7 203.0.113.9; do
  got=$(FAKE_EIP="$doc" FAKE_HTTP_IP=8.8.4.4 run_probe)
  if [[ "$got" != "8.8.4.4" ]]; then
    fail "文档/基准段 $doc 必须被丢弃并回退，实际：$got"
  fi
  got=$(FAKE_CURL_MODE=token-fail FAKE_ROUTE_IP="$doc" FAKE_HOSTNAME_IP=1.1.1.1 run_probe)
  if [[ "$got" != "1.1.1.1" ]]; then
    fail "路由返回 $doc 后必须继续用 hostname 回退，实际：$got"
  fi
done

# 10) 逐来源分类：路由回退拿到 CGNAT/文档段时不能直接空结果，要接着试 hostname。
got=$(FAKE_CURL_MODE=token-fail FAKE_ROUTE_IP=100.64.1.2 FAKE_HOSTNAME_IP=192.168.1.8 run_probe)
if [[ "$got" != "192.168.1.8" ]]; then
  fail "路由 CGNAT 丢弃后必须回退到 hostname，实际：$got"
fi
got=$(FAKE_CURL_MODE=token-fail FAKE_ROUTE_IP=203.0.113.9 FAKE_HOSTNAME_IP=192.168.1.8 run_probe)
if [[ "$got" != "192.168.1.8" ]]; then
  fail "路由文档段丢弃后必须回退到 hostname，实际：$got"
fi

# 11) hostname -I 一次输出多个地址时逐个分类（t3-fix6 P2）：
#     首个 CGNAT/文档段被丢弃后必须继续用后面的可用地址，而不是直接空结果。
got=$(FAKE_CURL_MODE=token-fail FAKE_ROUTE_IP= FAKE_HOSTNAME_IP='100.64.1.2 203.0.113.9 192.168.1.8' run_probe)
if [[ "$got" != "192.168.1.8" ]]; then
  fail "hostname 多地址必须逐个分类，实际：$got"
fi
got=$(FAKE_CURL_MODE=token-fail FAKE_ROUTE_IP= FAKE_HOSTNAME_IP='100.64.1.2 8.8.4.4 192.168.1.8' run_probe)
if [[ "$got" != "8.8.4.4" ]]; then
  fail "hostname 多地址应返回第一个可用地址，实际：$got"
fi
got=$(FAKE_CURL_MODE=token-fail FAKE_ROUTE_IP= FAKE_HOSTNAME_IP='100.64.1.2 203.0.113.9' run_probe)
if [[ -n "$got" ]]; then
  fail "hostname 全部不可用时必须为空，实际：$got"
fi

# 分类函数直接断言。
[[ "$(classify_detected_ipv4 192.168.1.10)" == "private" ]] || fail 'classify: RFC1918 应为 private'
[[ "$(classify_detected_ipv4 100.64.0.1)" == "discard" ]] || fail 'classify: CGNAT 应为 discard'
[[ "$(classify_detected_ipv4 127.0.0.1)" == "discard" ]] || fail 'classify: 回环应为 discard'
[[ "$(classify_detected_ipv4 239.1.2.3)" == "discard" ]] || fail 'classify: 组播应为 discard'
[[ "$(classify_detected_ipv4 198.18.0.1)" == "discard" ]] || fail 'classify: 198.18/15 应为 discard'
[[ "$(classify_detected_ipv4 198.19.255.254)" == "discard" ]] || fail 'classify: 198.19 应为 discard'
[[ "$(classify_detected_ipv4 192.0.2.1)" == "discard" ]] || fail 'classify: 192.0.2/24 应为 discard'
[[ "$(classify_detected_ipv4 198.51.100.1)" == "discard" ]] || fail 'classify: 198.51.100/24 应为 discard'
[[ "$(classify_detected_ipv4 203.0.113.1)" == "discard" ]] || fail 'classify: 203.0.113/24 应为 discard'
[[ "$(classify_detected_ipv4 8.8.8.8)" == "public" ]] || fail 'classify: 公网应为 public'
[[ "$(classify_detected_ipv4 93.184.216.34)" == "public" ]] || fail 'classify: 真实公网应为 public'

export PATH="$old_path"

if (( errors > 0 )); then
  echo "共 $errors 项检查失败" >&2
  exit 1
fi
echo "全部通过"
