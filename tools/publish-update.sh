#!/usr/bin/env bash
# 维护者本地发布一次控制台更新：签名 → 写清单 → 传阿里云镜像 + GitHub 固定 tag。
#
# 用法：
#   export TAURI_SIGNING_PRIVATE_KEY="$(cat <私钥文件>)"        # 或私钥文件路径
#   export TAURI_SIGNING_PRIVATE_KEY_PASSWORD='...'
#   tools/publish-update.sh v0.6.0 console/src-tauri/target/release/bundle/nsis/Vega_0.6.0_x64-setup.exe
#
# 产物与路径（两处都是「安装包不可变、清单最后换」）：
#   GitHub  固定 tag `vega-updates` 的 Release 资产：Vega-Setup-<ver>.exe / .sig / latest.json
#           客户端回退端点：https://github.com/<repo>/releases/download/vega-updates/latest.json
#   镜像    <MIRROR_DIR>/<ver>/Vega-Setup-<ver>.exe（版本目录只写一次，不覆盖），
#           再原子替换 <MIRROR_DIR>/latest.json；清单 url 指向 <MIRROR_URL>/<ver>/Vega-Setup-<ver>.exe
#
# 旧版本的版本目录一直保留，不清理；同一版本重复发布会被拒绝（换版本号再发）。
#
# 可选环境变量：
#   VEGA_NOTES          latest.json 里的更新说明，默认 "Vega 控制台 <version>"
#   VEGA_REPO           默认 shisanyue950901-beep/vega-remote
#   VEGA_RELEASE_TAG    更新通道固定 tag，默认 vega-updates
#   VEGA_MIRROR_HOST    默认 60.205.95.98
#   VEGA_MIRROR_DIR     默认 /opt/vega-relay/updates（即 nginx 的 updates 根目录）
#   VEGA_MIRROR_URL     默认 http://<VEGA_MIRROR_HOST>/vega/updates
#   VEGA_SKIP_GITHUB / VEGA_SKIP_MIRROR 置 1 可跳过对应通道
#
# 私钥只在本地环境变量里，绝不进仓库、CI 或脚本参数；脚本也不打印私钥内容。
# CI（.github/workflows/console.yml、release.yml）只构建未签名的包，不产出 latest.json。
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
RELEASE_TAG="${VEGA_RELEASE_TAG:-vega-updates}"
MIRROR_HOST="${VEGA_MIRROR_HOST:-60.205.95.98}"
MIRROR_DIR="${VEGA_MIRROR_DIR:-/opt/vega-relay/updates}"
MIRROR_URL="${VEGA_MIRROR_URL:-http://${MIRROR_HOST}/vega/updates}"
NOTES="${VEGA_NOTES:-Vega 控制台 ${VERSION}}"
ASSET="Vega-Setup-${VERSION}.exe"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSOLE="${ROOT}/console"

if [ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]; then
  echo "缺少 TAURI_SIGNING_PRIVATE_KEY：本机签名需要维护者私钥（不要提交到仓库）。" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
SETUP_ABS="${work}/${ASSET}"
cp "$SETUP" "$SETUP_ABS"

# --- 1. 本地签名 -------------------------------------------------------------
# 用 console 里锁定的 tauri CLI 版本签名，参数为空则 CLI 自己读 TAURI_SIGNING_* 环境变量。
TAURI_BIN="${CONSOLE}/node_modules/.bin/tauri"
[ -x "$TAURI_BIN" ] || { echo "找不到 tauri CLI: $TAURI_BIN（先在 console 里 npm ci）" >&2; exit 1; }

echo "签名 ${TAG} …"
( cd "$CONSOLE" && "$TAURI_BIN" signer sign "$SETUP_ABS" )
SIG="${SETUP_ABS}.sig"
[ -s "$SIG" ] || { echo "签名失败：没有生成 ${SIG}" >&2; exit 1; }

# --- 2. 写清单 --------------------------------------------------------------
# GitHub 清单指向固定 tag 下的版本化资产；镜像清单指向镜像的版本目录。
python3 - "$work" "$VERSION" "$NOTES" "$REPO" "$RELEASE_TAG" "$ASSET" "$MIRROR_URL" <<'PY'
import json, sys, datetime, pathlib

work, version, notes, repo, release_tag, asset, mirror = sys.argv[1:8]
sig = pathlib.Path(work, f"{asset}.sig").read_text().strip()
pub_date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
gh_url = f"https://github.com/{repo}/releases/download/{release_tag}/{asset}"
mirror_url = f"{mirror}/{version}/{asset}"

def manifest(url):
    return {
        "version": version,
        "notes": notes,
        "pub_date": pub_date,
        "platforms": {"windows-x86_64": {"signature": sig, "url": url}},
    }

for name, url in (("latest.json", gh_url), ("latest-mirror.json", mirror_url)):
    p = pathlib.Path(work, name)
    p.write_text(json.dumps(manifest(url), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{name}: {url}")
PY

echo "SHA256："
( cd "$work" && sha256sum "$ASSET" "${ASSET}.sig" latest.json latest-mirror.json )

# --- 3. GitHub Release（固定 tag，资产覆盖，保持唯一入口） ---------------------
if [ "${VEGA_SKIP_GITHUB:-0}" != "1" ]; then
  command -v gh >/dev/null || { echo "需要 gh CLI（或设置 VEGA_SKIP_GITHUB=1）" >&2; exit 1; }
  if ! gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "$RELEASE_TAG" --repo "$REPO" \
      --title "Vega 更新通道" --notes "自动更新清单与安装包。由 tools/publish-update.sh 维护，请勿手工改动。"
  fi
  # 只有 latest.json 会变；安装包按版本命名，旧版本资产保留。
  gh release upload "$RELEASE_TAG" "${work}/${ASSET}" "${work}/${ASSET}.sig" "${work}/latest.json" \
    --repo "$REPO" --clobber
  echo "已发布 GitHub Release ${REPO} ${RELEASE_TAG}（资产 ${ASSET}）"
fi

# --- 4. 阿里云镜像（版本目录不可变 + 清单原子替换） ---------------------------
# 顺序很重要：先落安装包，再换清单。清单是客户端判断更新的入口，必须最后一步。
if [ "${VEGA_SKIP_MIRROR:-0}" != "1" ]; then
  remote_dir="${MIRROR_DIR}/${VERSION}"
  ssh "$MIRROR_HOST" "mkdir -p '${remote_dir}'"
  if ssh "$MIRROR_HOST" "test -e '${remote_dir}/${ASSET}'"; then
    echo "镜像已有 ${VERSION} 的安装包：${remote_dir}/${ASSET}" >&2
    echo "版本目录不可覆盖，请改版本号后重发。" >&2
    exit 1
  fi
  scp -q "${work}/${ASSET}" "${work}/${ASSET}.sig" "${MIRROR_HOST}:${remote_dir}/"
  tmp_name=".latest.json.tmp.$$"
  scp -q "${work}/latest-mirror.json" "${MIRROR_HOST}:${MIRROR_DIR}/${tmp_name}"
  ssh "$MIRROR_HOST" "mv -f '${MIRROR_DIR}/${tmp_name}' '${MIRROR_DIR}/latest.json'"
  echo "已发布 ${TAG} 到 ${MIRROR_HOST}:${remote_dir}/，清单 ${MIRROR_URL}/${VERSION}/${ASSET}"
fi

echo "完成：${VERSION}（签名产物仅本地生成，旧版本目录保留）"
