#!/usr/bin/env bash
# 打 GitHub Release 用的分发包
#   ./scripts/release.sh            # 出精简版 zip
#   ./scripts/release.sh both       # 精简版 + 内嵌版
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist"
VER="$(date +%Y.%m.%d)"
mkdir -p "$OUT"
rm -f "$OUT"/*.zip "$OUT"/SHA256SUMS.txt 2>/dev/null || true

pack() {
  local variant="$1"
  echo "== 构建 $variant"
  VARIANT="$variant" "$ROOT/mac-app/build.sh" >/dev/null

  local name
  if [ "$variant" = "lite" ]; then name="开台"; else name="开台 Full"; fi
  local app="$ROOT/mac-app/build/$name.app"
  local slug
  if [ "$variant" = "lite" ]; then slug="KaiTai-lite"; else slug="KaiTai-embedded"; fi

  [ -d "$app" ] || { echo "没找到 $app" >&2; return 1; }

  # 打 zip 时保留符号链接和权限，解压即可用（zip -y 保住签名）
  local zip="$OUT/${slug}-${VER}-arm64.zip"
  ( cd "$ROOT/mac-app/build" && zip -qry "$zip" "$name.app" )
  echo "   $zip  ($(du -h "$zip" | cut -f1))"
}

if [ "${1:-lite}" = "both" ]; then
  pack lite
  pack embedded
else
  pack lite
fi

( cd "$OUT" && shasum -a 256 *.zip > SHA256SUMS.txt )
echo
echo "== 产出 $OUT"
ls -1 "$OUT"
echo
echo "上传前记得在 Release 说明里写清：未签名未公证，首次打开需右键 →「打开」，"
echo "或执行 xattr -dr com.apple.quarantine /Applications/开台.app"
