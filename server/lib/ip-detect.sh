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
#   - 路由/hostname 回退可能拿到 100.64/10、回环、组播等不可路由地址：每个候选
#     来源单独分类（P2，t3-fix5），public / RFC1918 才采用，discard 就丢掉并继续
#     下一个来源。RFC1918 保留并由调用方打印警告；CGNAT/回环/链路本地/组播/保留段、
#     198.18/15 基准测试网段与 RFC 5737 文档网段（192.0.2/24、198.51.100/24、
#     203.0.113/24）直接丢弃。
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
    # 前导零写法（010.1.2.3）在 inet_aton 里是八进制，容易和十进制解析出不同地址：
    # 一律判为非法，避免歧义输入。
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
  return 0
}

is_rfc1918_ipv4() {
  local ip="$1"
  is_valid_ipv4 "$ip" || return 1
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
  return 1
}

is_private_ipv4() {
  local ip="$1"
  is_valid_ipv4 "$ip" || return 1
  is_rfc1918_ipv4 "$ip" && return 0
  # 169.254/16 是链路本地地址，同样不能当公网 IP 给用户填。
  [[ "$ip" =~ ^169\.254\. ]] && return 0
  return 1
}

is_documentation_ipv4() {
  local ip="$1"
  is_valid_ipv4 "$ip" || return 1
  # 198.18/15（RFC 2544）是基准测试网段：真实公网里不会出现，出现就是本机基准/隧道残留。
  [[ "$ip" =~ ^198\.(18|19)\. ]] && return 0
  # RFC 5737 文档网段，只用于示例与测试，不能当服务器公网地址给用户填。
  [[ "$ip" =~ ^192\.0\.2\. ]] && return 0
  [[ "$ip" =~ ^198\.51\.100\. ]] && return 0
  [[ "$ip" =~ ^203\.0\.113\. ]] && return 0
  return 1
}

is_public_ipv4() {
  local ip="$1"
  is_valid_ipv4 "$ip" || return 1
  is_private_ipv4 "$ip" && return 1
  is_documentation_ipv4 "$ip" && return 1

  local first second
  IFS='.' read -r first second _ _ <<<"$ip"
  # 0/8（本网络，0.0.0.0 之类）、127/8（回环）都不能给客户端填。
  ((10#$first == 0)) && return 1
  ((10#$first == 127)) && return 1
  # 100.64/10 是运营商级 NAT / 共享地址空间，公网客户端连不到。
  if ((10#$first == 100)) && ((10#$second >= 64 && 10#$second <= 127)); then
    return 1
  fi
  # 224/4 组播、240/4 保留（含 255.255.255.255 广播）都不是可路由的单播地址。
  ((10#$first >= 224)) && return 1
  return 0
}

# 把候选地址分类：
#   public  = 可路由公网单播；
#   private = RFC1918（调用方打印警告后仍可展示）；
#   discard = CGNAT / 回环 / 0/8 / 链路本地 / 组播 / 保留段 / 非法写法，必须丢弃。
classify_detected_ipv4() {
  local ip="$1"
  if ! is_valid_ipv4 "$ip"; then
    printf 'discard'
    return 0
  fi
  if is_public_ipv4 "$ip"; then
    printf 'public'
    return 0
  fi
  if is_rfc1918_ipv4 "$ip"; then
    printf 'private'
    return 0
  fi
  printf 'discard'
}

# 最终输出前的唯一过滤器：只放行 public / RFC1918，其余返回 1（调用方置空）。
sanitize_detected_ipv4() {
  local ip="$1"
  case "$(classify_detected_ipv4 "$ip")" in
    public)
      printf '%s' "$ip"
      return 0
      ;;
    private)
      printf '%s' "$ip"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
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
  local candidate=""

  # P2（t3-fix5）：逐来源分类。每个候选来源先过 sanitize，discard 就丢掉并继续
  # 探测下一个来源，而不是先挑一个来源再分类——否则路由拿到 CGNAT 时就直接空结果，
  # 后面可用的 hostname 回退永远没机会执行。
  if command -v curl >/dev/null 2>&1; then
    candidate=$(fetch_aliyun_eip 2>/dev/null || true)
    if candidate=$(sanitize_detected_ipv4 "$candidate"); then
      printf '%s' "$candidate"
      return 0
    fi
    candidate=$(fetch_public_ip_http 2>/dev/null || true)
    if candidate=$(sanitize_detected_ipv4 "$candidate"); then
      printf '%s' "$candidate"
      return 0
    fi
  fi

  candidate=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}') || candidate=""
  if candidate=$(sanitize_detected_ipv4 "$candidate"); then
    printf '%s' "$candidate"
    return 0
  fi

  # t3-fix6 P2：hostname -I 一次可能输出多个地址（容器/多网卡常见 100.64.x 在前，
  # 内网或公网地址在后）。只取第一个会漏掉可用地址，这里逐个分类，
  # 第一个通过 sanitize 的地址胜出，其余继续按顺序尝试。
  while IFS= read -r candidate; do
    if candidate=$(sanitize_detected_ipv4 "$candidate"); then
      printf '%s' "$candidate"
      return 0
    fi
  done < <(hostname -I 2>/dev/null | tr -s '[:space:]' '\n')

  printf '%s' ""
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
