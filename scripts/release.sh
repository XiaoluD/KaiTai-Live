#!/usr/bin/env bash
# 本地打分发包（离线备用）
#
# 正常发版不需要这个脚本：push 一个 v* tag，GitHub Actions 会自动构建并发 Release（见
# .github/workflows/release.yml）。这里只在没网/CI 不可用时手工出包。
#
# 两个硬约束（改之前先看）：
#   1. 资产名固定 kaitai-full-arm64.zip —— App 自更新按 variant 拼这个名字，
#      换成带版本号的名字会让所有人的更新 404；
#   2. 版本号必须与 Info.plist / tag 一致 —— App 用 CFBundleShortVersionString
#      与 releases/latest 的 tag 比对，不一致会反复提示更新。
#
# 用法:
#   ./scripts/release.sh            # 版本号取最近 v* tag（v1.0.9 → 1.0.9）
#   ./scripts/release.sh 1.0.10     # 显式指定
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/dist"
APP_NAME="开台直播"            # 必须与 mac-app/build.sh 的 APP_NAME 一致
ASSET="kaitai-full-arm64"     # 资产名，勿改（Updater 按 variant 拼名）

VER="${1:-}"
if [ -z "${VER}" ]; then
  VER="$(git -C "${ROOT}" describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)"
fi
if [ -z "${VER}" ]; then
  echo "拿不到版本号：显式传入（./scripts/release.sh 1.0.10），或先 git tag v1.0.10" >&2
  exit 2
fi

echo "== 开台直播 v${VER}（内嵌 libmpv，arm64）"
mkdir -p "${OUT}"
rm -f "${OUT}"/*.zip "${OUT}"/SHA256SUMS.txt 2>/dev/null || true

APP_VERSION="${VER}" "${ROOT}/mac-app/build.sh"

APP="${ROOT}/mac-app/build/${APP_NAME}.app"
[ -d "${APP}" ] || { echo "没找到 ${APP}" >&2; exit 1; }

ZIP="${OUT}/${ASSET}.zip"
# 与 release.yml 同一打包方式：ditto 保留符号链接、权限与签名
ditto -c -k --keepParent "${APP}" "${ZIP}"
( cd "${OUT}" && shasum -a 256 "${ASSET}.zip" > SHA256SUMS.txt )

echo
echo "== 产出"
ls -lh "${OUT}"
cat "${OUT}/SHA256SUMS.txt"
echo
echo "== 上传（gh 已登录）"
echo "  首次发布:  gh release create v${VER} \"${ZIP}\" --title \"开台直播 v${VER}\" --notes-file <说明.md>"
echo "  补传资产:  gh release upload v${VER} \"${ZIP}\" --clobber"
echo
echo "== 安装提醒"
echo "  未签名未公证，首次打开需右键 →「打开」，或："
echo "  xattr -dr com.apple.quarantine \"/Applications/${APP_NAME}.app\""
