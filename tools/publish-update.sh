#!/usr/bin/env bash
# 维护者本地发布一次控制台更新：签名 → 写 latest.json → 传阿里云镜像 + GitHub Release。
#
# 用法：
#   export TAURI_SIGNING_PRIVATE_KEY="$(cat <私钥文件>)"        # 或私钥文件路径
#   export TAURI_SIGNING_PRIVATE_KEY_PASSWORD='...'
#   tools/publish-update.sh v0.6.0 console/src-tauri/target/release/bundle/nsis/Vega_0.6.0_x64-setup.exe
#
# 可选环境变量：
#   VEGA_NOTES        latest.json 里的更新说明，默认 "Vega 控制台 <version>"
#   VEGA_REPO         默认 shisanyue950901-beep/vega-remote
#   VEGA_MIRROR_HOST  默认 60.205.95.98
#   VEGA_MIRROR_DIR   默认 /opt/vega-relay/updates
#   VEGA_MIRROR_URL   默认 http://<VEGA_MIRROR_HOST>/vega/updates
#   VEGA_SKIP_GITHUB / VEGA_SKIP_MIRROR 置 1 可跳过对应通道
#
# 私钥只在本地环境变量里，绝不进仓库、CI 或脚本参数；脚本也不打印私钥内容。
# CI（.github/workflows/console.yml）只构建未签名的安装包，签名产物完全由本地生成。
set -euo pipefail

usage() {
  echo "用法: $0 <tag> <setup.exe>" >&2
  echo "  例: $0 v0.6.0 console/src-tauri/target/release/bundle/nsis/Vega_0.6.0_x64-setup.exe" >&2
  exit 2
}

TAG="${1:-}"
SETUP="${2:-}"
if [ -z "$TAG" ] || [ -z "$SETUP" ]; then
  usage
fi
case "$TAG" in
  v*) ;;
  *) echo "tag 必须形如 v0.6.0" >&2; exit 2 ;;
esac
[ -f "$SETUP" ] || { echo "找不到安装包: $SETUP" >&2; exit 1; }

VERSION="${TAG#v}"
REPO="${VEGA_REPO:-shisanyue950901-beep/vega-remote}"
MIRROR_HOST="${VEGA_MIRROR_HOST:-60.205.95.98}"
MIRROR_DIR="${VEGA_MIRROR_DIR:-/opt/vega-relay/updates}"
MIRROR_URL="${VEGA_MIRROR_URL:-http://${MIRROR_HOST}/vega/updates}"
NOTES="${VEGA_NOTES:-Vega 控制台 ${VERSION}}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSOLE="${ROOT}/console"

if [ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]; then
  echo "缺少 TAURI_SIGNING_PRIVATE_KEY：本机签名需要维护者私钥（不要提交到仓库）。" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$SETUP" "${work}/Vega-Setup.exe"
SETUP_ABS="${work}/Vega-Setup.exe"

# --- 1. 本地签名 -------------------------------------------------------------
# 用 console 里锁定的 tauri CLI 版本签名，参数为空则 CLI 自己读 TAURI_SIGNING_* 环境变量。
TAURI_BIN="${CONSOLE}/node_modules/.bin/tauri"
[ -x "$TAURI_BIN" ] || { echo "找不到 tauri CLI: $TAURI_BIN（先在 console 里 npm ci）" >&2; exit 1; }

echo "签名 ${TAG} …"
( cd "$CONSOLE" && "$TAURI_BIN" signer sign "$SETUP_ABS" )
SIG="${SETUP_ABS}.sig"
[ -s "$SIG" ] || { echo "签名失败：没有生成 ${SIG}" >&2; exit 1; }

# --- 2. 写清单 --------------------------------------------------------------
# 两个清单内容只差 url：GitHub 清单指向固定 tag 的 Release 资产，镜像清单指向镜像目录。
python3 - "$work" "$VERSION" "$NOTES" "$REPO" "$TAG" "$MIRROR_URL" <<'PY'
import json, sys, datetime, pathlib

work, version, notes, repo, tag, mirror = sys.argv[1:7]
sig = pathlib.Path(work, "Vega-Setup.exe.sig").read_text().strip()
pub_date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
gh_url = f"https://github.com/{repo}/releases/download/{tag}/Vega-Setup.exe"

def manifest(url):
    return {
        "version": version,
        "notes": notes,
        "pub_date": pub_date,
        "platforms": {"windows-x86_64": {"signature": sig, "url": url}},
    }

for name, url in (("latest.json", gh_url), ("latest-mirror.json", f"{mirror}/Vega-Setup.exe")):
    p = pathlib.Path(work, name)
    p.write_text(json.dumps(manifest(url), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{name}: {url}")
PY

echo "SHA256："
( cd "$work" && sha256sum Vega-Setup.exe Vega-Setup.exe.sig latest.json latest-mirror.json )

# --- 3. GitHub Release ------------------------------------------------------
if [ "${VEGA_SKIP_GITHUB:-0}" != "1" ]; then
  command -v gh >/dev/null || { echo "需要 gh CLI（或设置 VEGA_SKIP_GITHUB=1）" >&2; exit 1; }
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "${work}/Vega-Setup.exe" "$SIG" "${work}/latest.json" \
      --repo "$REPO" --clobber
  else
    gh release create "$TAG" "${work}/Vega-Setup.exe" "$SIG" "${work}/latest.json" \
      --repo "$REPO" --title "Vega 控制台 ${VERSION}" --notes "$NOTES"
  fi
  echo "已发布 GitHub Release ${REPO} ${TAG}"
fi

# --- 4. 阿里云镜像 ----------------------------------------------------------
# 先传安装包与签名，再传清单：清单是客户端判断更新的入口，必须最后、原子地换上去。
if [ "${VEGA_SKIP_MIRROR:-0}" != "1" ]; then
  ssh "$MIRROR_HOST" mkdir -p "$MIRROR_DIR"
  scp -q "${work}/Vega-Setup.exe" "$SIG" "${MIRROR_HOST}:${MIRROR_DIR}/"
  scp -q "${work}/latest-mirror.json" "${MIRROR_HOST}:${MIRROR_DIR}/.latest.json.tmp"
  ssh "$MIRROR_HOST" mv -f "${MIRROR_DIR}/.latest.json.tmp" "${MIRROR_DIR}/latest.json"
  echo "已发布 ${TAG} 到 ${MIRROR_HOST}:${MIRROR_DIR}/latest.json"
fi

echo "完成：${VERSION}（签名产物仅本地生成）"
