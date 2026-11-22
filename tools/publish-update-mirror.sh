#!/usr/bin/env bash
# 把 GitHub Release 里的更新产物同步到阿里云镜像。
# 用法：tools/publish-update-mirror.sh v0.6.0
# 环境变量：VEGA_REPO（默认本仓库）、VEGA_MIRROR_HOST、VEGA_MIRROR_DIR。
set -euo pipefail

TAG="${1:?用法: $0 <tag>，例如 v0.6.0}"
REPO="${VEGA_REPO:-shisanyue950901-beep/vega-remote}"
HOST="${VEGA_MIRROR_HOST:-60.205.95.98}"
DIR="${VEGA_MIRROR_DIR:-/opt/vega-relay/updates}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for name in Vega-Setup.exe Vega-Setup.exe.sig latest-mirror.json; do
  echo "下载 ${BASE}/${name}"
  curl -fsSL --retry 3 --retry-delay 2 -o "${work}/${name}" "${BASE}/${name}"
done

echo "SHA256："
( cd "$work" && sha256sum Vega-Setup.exe Vega-Setup.exe.sig latest-mirror.json )

# 先传安装包与签名，再传清单：清单是客户端判断更新的入口，必须最后、原子地换上去。
ssh "$HOST" mkdir -p "$DIR"
scp -q "${work}/Vega-Setup.exe" "${work}/Vega-Setup.exe.sig" "${HOST}:${DIR}/"
scp -q "${work}/latest-mirror.json" "${HOST}:${DIR}/.latest.json.tmp"
ssh "$HOST" mv -f "${DIR}/.latest.json.tmp" "${DIR}/latest.json"

echo "已发布 ${TAG} 到 ${HOST}:${DIR}/latest.json"
