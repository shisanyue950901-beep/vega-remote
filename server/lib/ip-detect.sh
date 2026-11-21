#!/usr/bin/env bash
# 公网 IP 探测（被 setup-rustdesk-server.sh source，也被 tests/setup-rustdesk-static.sh 直接 source）。
#
# 设计要点：
#   - 阿里云 ECS 先查元数据 eipv4。没有绑定 EIP 时，公网访问会自动回落成 VPC 内网地址，
#     用户把它填进 RustDesk 就永远连不上，所以必须区分“公网 IPv4”和“内网 IPv4”。
#   - 元数据服务要求 IMDSv2：先 PUT /latest/api/token 拿令牌，再带令牌 GET。
#     拿不到令牌就不发无令牌请求（该实例要求令牌，无令牌请求只会失败/误导）。
#   - 元数据请求必须 --noproxy '*'：经过用户配置的代理会把 100.100.100.200 解析到别处。
#   - 只接受请求成功且通过 IPv4 正则的完整响应；失败时的部分输出/HTML 一律丢弃。
#   - 本文件只定义函数，不执行任何动作。

is_valid_ipv4() {
  local ip="$1"
  [[ -z "$ip" ]] && return 1
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local octet
  local IFS='.'
  # shellcheck disable=SC2206  # 已用正则保证四段数字
  local parts=($ip)
  [[ "${#parts[@]}" -ne 4 ]] && return 1
  for octet in "${parts[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
  return 0
}

is_private_ipv4() {
  local ip="$1"
  is_valid_ipv4 "$ip" || return 1
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
  # 169.254/16 是链路本地地址，同样不能当公网 IP 给用户填。
  [[ "$ip" =~ ^169\.254\. ]] && return 0
  return 1
}

is_public_ipv4() {
  local ip="$1"
  is_valid_ipv4 "$ip" || return 1
  is_private_ipv4 "$ip" && return 1
  return 0
}

# 阿里云元数据：IMDSv2。成功且是公网 IPv4 时打印地址并返回 0。
fetch_aliyun_eip() {
  local token=""
  local ip=""

  token=$(curl --noproxy '*' -fsS --max-time 2 -X PUT \
    -H 'X-aliyun-ecs-metadata-token-ttl-seconds: 60' \
    'http://100.100.100.200/latest/api/token' 2>/dev/null) || token=""
  if [[ -z "$token" ]]; then
    # 实例要求令牌但没拿到：跳过 eipv4，交给后面的公网探测。
    return 1
  fi
  [[ "$token" =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || return 1

  ip=$(curl --noproxy '*' -fsS --max-time 2 \
    -H "X-aliyun-ecs-metadata-token: $token" \
    'http://100.100.100.200/latest/meta-data/eipv4' 2>/dev/null) || ip=""
  # 只采用成功请求返回的合法公网 IPv4；HTML、内网地址、部分输出都丢弃。
  is_public_ipv4 "$ip" || return 1
  printf '%s' "$ip"
}

fetch_public_ip_http() {
  local ip=""
  ip=$(curl -fsS4 --max-time 5 'https://ifconfig.me' 2>/dev/null) || ip=""
  if ! is_public_ipv4 "$ip"; then
    ip=$(curl -fsS4 --max-time 5 'https://api.ipify.org' 2>/dev/null) || ip=""
  fi
  is_public_ipv4 "$ip" || return 1
  printf '%s' "$ip"
}

detect_public_ip() {
  local ip=""

  if command -v curl >/dev/null 2>&1; then
    ip=$(fetch_aliyun_eip 2>/dev/null || true)
    if [[ -z "$ip" ]]; then
      ip=$(fetch_public_ip_http 2>/dev/null || true)
    fi
  fi
  if [[ -z "$ip" ]]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}') || ip=""
  fi
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip=""
  fi

  # 走本地路由/hostname 拿到的是内网地址也原样返回，让调用方打印警告。
  is_valid_ipv4 "$ip" || ip=""
  printf '%s' "$ip"
}

# 打印 RFC1918/链路本地地址警告；是内网地址返回 0。
warn_if_private_ipv4() {
  local ip="$1"
  if is_private_ipv4 "$ip"; then
    echo "警告: 自动探测到的是内网地址 $ip（阿里云实例未绑定 EIP 时常见），不能直接给客户端使用。" >&2
    echo "      请在云控制台绑定弹性公网 IP，或手动填写服务器公网 IP/域名。" >&2
    return 0
  fi
  return 1
}
