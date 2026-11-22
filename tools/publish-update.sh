#!/usr/bin/env bash
# 维护者本地发布一次控制台更新：签名 → 写清单 → 两个通道都上安装包 → 最后切清单。
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
# 重跑规则（t6-fix4 架构裁定）：
#   * 版本化安装包若已存在，远程 SHA256 与本地相同 → 跳过；不同 → 中止，绝不覆盖。
#   * 同一个 exe（SHA256 相同）永不重签：签名按 exe SHA256 缓存在仓库外的
#     VEGA_SIG_CACHE（默认 ~/.cache/vega-sig），重跑先查缓存；缓存未命中时若
#     GitHub/镜像已有字节相同的 exe，就下载它的 .sig 复用，只有全新 exe 才本地签名。
#     Tauri 会把签名时间写进 .sig，重签会改变 .sig 哈希，导致已发布版本无法重跑。
#   * GitHub 资产上传走 Release 的 upload_url（uploads.github.com），不接受
#     api.github.com 的 assets POST；改名才用 api.github.com 的 PATCH。
#   * GitHub 资产不用 --clobber 上传；上传中断留下的同名 0 字节资产会被清掉重传，
#     其他同名资产按 SHA256 校验拦下。
#   * 镜像先传 <file>.part，传完再远端 mv 成最终名；中断只会留下 .part。
#   * SSH 探测只认 0=存在、1=不存在；其他退出码（含连接失败的 255）一律中止，
#     绝不能把连接失败当成“文件不存在”而覆盖镜像上已发布的同版本包。
#   * Release 用 --latest=false 创建；已存在则 PATCH make_latest=false，避免顶掉
#     一键安装用的源码 Release。
#   * 清单最后换：先上传 latest.json.new → 删除旧 latest.json → PATCH 改名为 latest.json。
#     两个通道都先完成安装包校验/上传，再切各自的清单。
#
# 旧版本的版本目录一直保留，不清理；同一版本重复发布只允许字节完全相同的包。
#
# 可选环境变量：
#   VEGA_NOTES          latest.json 里的更新说明，默认 "Vega 控制台 <version>"
#   VEGA_REPO           默认 shisanyue950901-beep/vega-remote
#   VEGA_RELEASE_TAG    更新通道固定 tag，默认 vega-updates
#   VEGA_MIRROR_HOST    默认 60.205.95.98
#   VEGA_MIRROR_DIR     默认 /opt/vega-relay/updates（即 nginx 的 updates 根目录）
#   VEGA_MIRROR_URL     默认 http://<VEGA_MIRROR_HOST>/vega/updates
#   VEGA_SIG_CACHE      签名缓存目录（仓库外），默认 ~/.cache/vega-sig
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
# 必须是完整的 vX.Y.Z（客户端按 SemVer 解析清单，v0.6 这类会让清单无法解析）。
if ! [[ "$TAG" =~ ^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]; then
  echo "tag 必须形如 v0.6.0（完整三段、正式版）" >&2; exit 2
fi
[ -f "$SETUP" ] || { echo "找不到安装包: $SETUP" >&2; exit 1; }

VERSION="${TAG#v}"
# 架构裁定：更新通道只发正式版。两个端点的 latest.json 只有一份，发预览版会让
# 正式版客户端（过滤预览版）看不到已发布的正式更新。
case "$VERSION" in
  *-*) echo "更新通道只接受正式版本号（${VERSION} 含预发布后缀），拒绝发布。" >&2; exit 1 ;;
esac
REPO="${VEGA_REPO:-shisanyue950901-beep/vega-remote}"
RELEASE_TAG="${VEGA_RELEASE_TAG:-vega-updates}"
MIRROR_HOST="${VEGA_MIRROR_HOST:-60.205.95.98}"
MIRROR_DIR="${VEGA_MIRROR_DIR:-/opt/vega-relay/updates}"
MIRROR_URL="${VEGA_MIRROR_URL:-http://${MIRROR_HOST}/vega/updates}"
NOTES="${VEGA_NOTES:-Vega 控制台 ${VERSION}}"
ASSET="Vega-Setup-${VERSION}.exe"
ASSET_SIG="${ASSET}.sig"

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

# --- 1. 签名（同一个 exe 永不重签） -----------------------------------------
# 签名缓存必须放在仓库之外：Tauri 会把签名时间写进 .sig，重签同一个 exe 会让
# 签名文件哈希变化，已发布的同版本包就无法重跑发布（远端会判成不同文件）。
SIG_CACHE="${VEGA_SIG_CACHE:-${HOME}/.cache/vega-sig}"
mkdir -p "$SIG_CACHE"

LOCAL_SHA="$(sha256sum "$SETUP_ABS" | awk '{print $1}')"
echo "本地 SHA256：${ASSET} ${LOCAL_SHA}"

# GitHub 资产辅助函数：按名字取 id / 下载后比对 SHA256。
gh_release_id() {
  gh api "repos/${REPO}/releases/tags/${RELEASE_TAG}" --jq .id
}
gh_asset_id() {
  local release_id="$1" name="$2"
  gh api "repos/${REPO}/releases/${release_id}/assets" --paginate \
    --jq ".[] | select(.name == \"${name}\") | .id"
}
gh_asset_size() {
  local release_id="$1" name="$2"
  gh api "repos/${REPO}/releases/${release_id}/assets" --paginate \
    --jq ".[] | select(.name == \"${name}\") | .size"
}
gh_delete_asset() {
  local id="$1"
  [ -n "$id" ] || return 0
  gh api -X DELETE "repos/${REPO}/releases/assets/${id}" >/dev/null
}
# 资产已存在时下载并比对 SHA256；相同返回 0，不同返回 1。不存在返回 2。
# 上传中断可能留下同名 0 字节资产（GitHub 的 "starter" 占位）：按不存在处理，
# 先删掉再让调用方重新上传，否则会被当成“内容不同”而永久卡住重跑。
gh_verify_asset() {
  local release_id="$1" name="$2" want="$3" dest="$4"
  local id size
  id="$(gh_asset_id "$release_id" "$name")"
  if [ -z "$id" ]; then
    return 2
  fi
  # 查询失败或返回空值不能当成 0 字节残留：直接报错（返回 3），绝不删除已发布资产。
  if ! size="$(gh_asset_size "$release_id" "$name")" || [ -z "$size" ]; then
    echo "查询 GitHub 资产 ${name} 的大小失败，中止（不删除任何资产）。" >&2
    return 3
  fi
  if [ "$size" = "0" ]; then
    echo "GitHub 上的 ${name} 是 0 字节残留资产（上次上传中断），删除后重传。" >&2
    gh_delete_asset "$id"
    return 2
  fi
  gh release download "$RELEASE_TAG" --repo "$REPO" --pattern "$name" --output "$dest" --clobber
  local got
  got="$(sha256sum "$dest" | awk '{print $1}')"
  if [ "$got" = "$want" ]; then
    return 0
  fi
  return 1
}
# 上传走 Release 的 upload_url（GitHub.com 上是 uploads.github.com）。相对路径的
# `gh api -X POST repos/.../assets` 会发到 api.github.com，上传端点不接受，必然失败。
# 这里用 gh 的 token 直接 POST 到 upload_url，并能指定资产名（gh release upload 只能
# 用文件基名）。资产改名仍走 api.github.com 的 PATCH。
gh_upload_asset() {
  local file="$1" name="$2"
  local upload_url hdr
  upload_url="$(gh api "repos/${REPO}/releases/${release_id}" --jq .upload_url)"
  upload_url="${upload_url%\{*}"  # 去掉 {?name,label} 模板
  # 令牌不进进程参数：写进 0600 头文件，curl 用 -H @file 读取，用完即删。
  hdr="$(mktemp "${work}/gh-hdr.XXXXXX")"
  chmod 600 "$hdr"
  printf 'Authorization: token %s\n' "$(gh auth token)" > "$hdr"
  curl -sS -f -X POST "${upload_url}?name=${name}" \
    -H "@${hdr}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${file}" >/dev/null || { rm -f "$hdr"; return 1; }
  rm -f "$hdr"
  echo "已上传 GitHub ${name}（经 upload_url ${upload_url}）。"
}

# SSH 探测：0=存在，1=不存在，其他（含连接失败的 255）一律中止。
# 绝不能再把连接失败当成“文件不存在”，否则会覆盖镜像上已发布的同版本包。
ssh_exists() {
  local path="$1" rc=0
  set +e
  ssh "$MIRROR_HOST" "test -e '${path}'"
  rc=$?
  set -e
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      echo "SSH 连接 ${MIRROR_HOST} 失败（退出码 ${rc}）：中止，避免误判远端文件不存在。" >&2
      exit 1
      ;;
  esac
}

# GitHub 更新 Release 的准备要放在签名之前：远端已有同一个 exe 时要下载并复用
# 它的 .sig，而不是重新签名。--latest=false：这个 Release 没有源码 ZIP /
# SHA256SUMS.txt，不能顶掉 bootstrap.ps1 依赖的源码 Release。
release_id=""
if [ "${VEGA_SKIP_GITHUB:-0}" != "1" ]; then
  command -v gh >/dev/null || { echo "需要 gh CLI（或设置 VEGA_SKIP_GITHUB=1）" >&2; exit 1; }
  if ! gh release view "$RELEASE_TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "$RELEASE_TAG" --repo "$REPO" --latest=false \
      --title "Vega 更新通道" --notes "自动更新清单与安装包。由 tools/publish-update.sh 维护，请勿手工改动。"
  else
    # 老 Release 可能曾被标成 latest，显式降回去。Update release 只接受 release id。
    release_id="$(gh_release_id)"
    gh api -X PATCH "repos/${REPO}/releases/${release_id}" -f make_latest=false >/dev/null
  fi
  release_id="$(gh_release_id)"
fi

SIG="${SETUP_ABS}.sig"

# 1) 本地缓存命中：同一个 exe 的签名原样复用。
if [ -s "${SIG_CACHE}/${LOCAL_SHA}.sig" ]; then
  cp "${SIG_CACHE}/${LOCAL_SHA}.sig" "$SIG"
  echo "复用签名缓存 ${SIG_CACHE}/${LOCAL_SHA}.sig（exe 未变，不重签）。"
fi

# 2) 远端已经有字节相同的 exe：下载远端 .sig 复用，绝不重签已发布的 exe。
if [ ! -s "$SIG" ] && [ "${VEGA_SKIP_GITHUB:-0}" != "1" ]; then
  set +e
  gh_verify_asset "$release_id" "$ASSET" "$LOCAL_SHA" "${work}/remote-${ASSET}"
  rc=$?
  set -e
  case "$rc" in
    0)
      # 签名资产的状态：查询失败中止；0 字节 starter 删除后按缺失处理；有效则复用。
      if ! sig_id="$(gh_asset_id "$release_id" "$ASSET_SIG")"; then
        echo "查询 GitHub 资产 ${ASSET_SIG} 失败，中止。" >&2
        exit 1
      fi
      if [ -n "$sig_id" ]; then
        if ! sig_size="$(gh_asset_size "$release_id" "$ASSET_SIG")" || [ -z "$sig_size" ]; then
          echo "查询 GitHub 资产 ${ASSET_SIG} 的大小失败，中止。" >&2
          exit 1
        fi
        if [ "$sig_size" = "0" ]; then
          echo "GitHub 上的 ${ASSET_SIG} 是 0 字节残留，删除后稍后本地签名。"
          gh_delete_asset "$sig_id"
          sig_id=""
        fi
      fi
      if [ -n "$sig_id" ]; then
        echo "GitHub 已有相同的 ${ASSET}，复用远端签名（不重签）。"
        gh release download "$RELEASE_TAG" --repo "$REPO" --pattern "$ASSET_SIG" \
          --output "$SIG" --clobber
        cp "$SIG" "${SIG_CACHE}/${LOCAL_SHA}.sig"
      else
        # 上次在传完 exe、传 .sig 前中断：签名从未发布，后面可以安全地本地签名。
        echo "GitHub 有相同的 ${ASSET} 但没有 ${ASSET_SIG}（上次中断），稍后本地签名。"
      fi
      ;;
    1)
      echo "GitHub 上的 ${ASSET} 与本地 SHA256 不同，拒绝覆盖（换版本号后重发）。" >&2
      exit 1
      ;;
    2) ;;
    *)
      echo "校验 GitHub 资产 ${ASSET} 失败。" >&2
      exit 1
      ;;
  esac
fi
if [ ! -s "$SIG" ] && [ "${VEGA_SKIP_MIRROR:-0}" != "1" ]; then
  remote_exe="${MIRROR_DIR}/${VERSION}/${ASSET}"
  if ssh_exists "$remote_exe"; then
    got="$(ssh "$MIRROR_HOST" "sha256sum '${remote_exe}'" | awk '{print $1}')"
    if [ "$got" = "$LOCAL_SHA" ]; then
      if ssh_exists "${remote_exe}.sig"; then
        echo "镜像已有相同的 ${ASSET}，复用远端签名（不重签）。"
        scp -q "${MIRROR_HOST}:${remote_exe}.sig" "$SIG"
        cp "$SIG" "${SIG_CACHE}/${LOCAL_SHA}.sig"
      else
        echo "镜像有相同的 ${ASSET} 但没有 .sig（上次中断），稍后本地签名。"
      fi
    else
      echo "镜像上的 ${remote_exe} 与本地 SHA256 不同，拒绝覆盖（换版本号后重发）。" >&2
      exit 1
    fi
  fi
fi

# 3) 缓存与两个通道都没有现成签名（从未发布过的新 exe）才本地签名。
if [ ! -s "$SIG" ]; then
  # 用 console 里锁定的 tauri CLI 版本签名，参数为空则 CLI 自己读 TAURI_SIGNING_* 环境变量。
  TAURI_BIN="${CONSOLE}/node_modules/.bin/tauri"
  [ -x "$TAURI_BIN" ] || { echo "找不到 tauri CLI: $TAURI_BIN（先在 console 里 npm ci）" >&2; exit 1; }
  echo "签名 ${TAG} …"
  ( cd "$CONSOLE" && "$TAURI_BIN" signer sign "$SETUP_ABS" )
  [ -s "$SIG" ] || { echo "签名失败：没有生成 ${SIG}" >&2; exit 1; }
  cp "$SIG" "${SIG_CACHE}/${LOCAL_SHA}.sig"
  echo "已签名并写入缓存 ${SIG_CACHE}/${LOCAL_SHA}.sig。"
else
  echo "使用已有签名 ${SIG}（exe 未变，不重签）。"
fi

LOCAL_SIG_SHA="$(sha256sum "$SIG" | awk '{print $1}')"
echo "本地 SHA256：${ASSET} ${LOCAL_SHA}"

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

# --- 3. 安装包先上两个通道（版本化、不可变、可安全重跑） ---------------------
# 顺序：GitHub 校验/上传 → 镜像校验/上传 → 再切清单。任何一步失败都不会换清单。
# Release 已在签名前准备好（release_id）。
if [ "${VEGA_SKIP_GITHUB:-0}" != "1" ]; then

  for pair in "${ASSET}:${LOCAL_SHA}" "${ASSET_SIG}:${LOCAL_SIG_SHA}"; do
    name="${pair%%:*}"
    want="${pair#*:}"
    set +e
    gh_verify_asset "$release_id" "$name" "$want" "${work}/remote-${name}"
    rc=$?
    set -e
    case "$rc" in
      0)
        echo "GitHub 已有相同 ${name}，跳过上传。"
        ;;
      1)
        echo "GitHub 上的 ${name} 与本地 SHA256 不同，拒绝覆盖（换版本号后重发）。" >&2
        exit 1
        ;;
      2)
        # 不用 --clobber：上传失败不会先删掉旧资产。
        gh_upload_asset "${work}/${name}" "$name"
        ;;
      *)
        echo "校验 GitHub 资产 ${name} 失败。" >&2
        exit 1
        ;;
    esac
  done
fi

if [ "${VEGA_SKIP_MIRROR:-0}" != "1" ]; then
  remote_dir="${MIRROR_DIR}/${VERSION}"
  ssh "$MIRROR_HOST" "mkdir -p '${remote_dir}'"
  # 先传 .part 再 mv：中断不会留下半个最终文件。
  for pair in "${ASSET}:${LOCAL_SHA}" "${ASSET_SIG}:${LOCAL_SIG_SHA}"; do
    name="${pair%%:*}"
    want="${pair#*:}"
    remote="${remote_dir}/${name}"
    if ssh_exists "$remote"; then
      got="$(ssh "$MIRROR_HOST" "sha256sum '${remote}'" | awk '{print $1}')"
      if [ "$got" = "$want" ]; then
        echo "镜像已有相同 ${name}，跳过上传。"
        continue
      fi
      echo "镜像上的 ${remote} 与本地 SHA256 不同，拒绝覆盖（换版本号后重发）。" >&2
      exit 1
    fi
    scp -q "${work}/${name}" "${MIRROR_HOST}:${remote}.part"
    ssh "$MIRROR_HOST" "mv -f '${remote}.part' '${remote}'"
    echo "已上传镜像 ${remote}。"
  done
fi

# --- 4. 两个通道都换清单（最后一步） ----------------------------------------
if [ "${VEGA_SKIP_GITHUB:-0}" != "1" ]; then
  new_name="latest.json.new"
  # 上次中断可能留下 latest.json.new（含 0 字节 starter）：先删掉同名临时资产。
  stale_id="$(gh_asset_id "$release_id" "$new_name")"
  gh_delete_asset "$stale_id"
  # 上传为临时名：gh_upload_asset 走 upload_url，文件基名即资产名。
  cp "${work}/latest.json" "${work}/${new_name}"
  gh_upload_asset "${work}/${new_name}" "$new_name"
  # 先确认新清单资产就位，再删旧清单：查询失败时旧 latest.json 仍在，更新入口不会消失。
  new_id="$(gh_asset_id "$release_id" "$new_name")" || new_id=""
  [ -n "$new_id" ] || { echo "查不到 latest.json.new（上传或查询失败），旧清单保持不变。" >&2; exit 1; }
  old_id="$(gh_asset_id "$release_id" "latest.json")" || { echo "查询旧 latest.json 失败，旧清单保持不变。" >&2; exit 1; }
  gh_delete_asset "$old_id"
  # 改名为最终资产名：客户端只会看到完整的新清单。
  # 旧清单已删：改名失败会让 GitHub 入口缺清单，所以重试 6 次（约 1 分钟），
  # 仍失败就打印一条可直接执行的恢复命令（镜像清单尚未切换，客户端仍走镜像）。
  renamed=0
  for attempt in 1 2 3 4 5 6; do
    if gh api -X PATCH "repos/${REPO}/releases/assets/${new_id}" -f name=latest.json >/dev/null; then
      renamed=1; break
    fi
    echo "改名 latest.json 失败（第 ${attempt} 次），稍后重试…" >&2
    sleep $((attempt * 3))
  done
  if [ "$renamed" != "1" ]; then
    echo "GitHub 清单改名失败。API 恢复后执行：gh api -X PATCH repos/${REPO}/releases/assets/${new_id} -f name=latest.json" >&2
    exit 1
  fi
  echo "已切换 GitHub 清单 ${REPO} ${RELEASE_TAG}/latest.json。"
fi

if [ "${VEGA_SKIP_MIRROR:-0}" != "1" ]; then
  tmp_name=".latest.json.tmp.$$"
  scp -q "${work}/latest-mirror.json" "${MIRROR_HOST}:${MIRROR_DIR}/${tmp_name}"
  ssh "$MIRROR_HOST" "mv -f '${MIRROR_DIR}/${tmp_name}' '${MIRROR_DIR}/latest.json'"
  echo "已切换镜像清单 ${MIRROR_URL}/latest.json（版本 ${VERSION}）。"
fi

echo "完成：${VERSION}（签名产物仅本地生成，旧版本目录保留）"
