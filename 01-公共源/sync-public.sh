#!/usr/bin/env bash
# 同步公共直播源 → 本地校验 → 只把「能播的」放进 web/playlists/
#
# 用法:
#   ./01-公共源/sync-public.sh              # 拉取 + 校验（默认）
#   VERIFY=0 ./01-公共源/sync-public.sh     # 只拉取，不校验（原样入库）
#   TIMEOUT=8 WORKERS=20 ./01-公共源/sync-public.sh
#
# 为什么要校验：公共源里有大量死链、反盗链错误页，以及 67 条 Safari 内核根本
# 播不了的 FLV 直连流。不做这一步，用户点十个台有四个打不开。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../web/playlists"
RAW="$HERE/raw"
VERIFY="${VERIFY:-1}"
WORKERS="${WORKERS:-20}"
TIMEOUT="${TIMEOUT:-8}"
mkdir -p "$OUT" "$RAW"

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
GH_PROXY="https://gh-proxy.com/raw.githubusercontent.com/vbskycn/iptv/refs/heads/master/tv"

# 拉一份到 $2，成功返回 0
fetch() {
  local dest="$1"; shift
  local url tmp
  tmp="$(mktemp)"
  for url in "$@"; do
    if curl -fsSL --max-time 60 -A "$UA" -o "$tmp" "$url" 2>/dev/null; then
      if head -1 "$tmp" | grep -q '^#EXTM3U'; then
        mv "$tmp" "$dest"
        printf 'OK   拉取 %-26s %s 条\n' "$(basename "$dest")" "$(grep -c '^#EXTINF' "$dest")"
        return 0
      fi
      echo "SKIP 内容不是 m3u: $url" >&2
    else
      echo "FAIL $url" >&2
    fi
  done
  rm -f "$tmp"
  printf 'KEEP %-26s 全部通道失败，保留旧文件\n' "$(basename "$dest")"
  return 1
}

sync_one() {
  local name="$1"; shift
  local raw="$RAW/$name.m3u"
  local dest="$OUT/$name.m3u"

  if ! fetch "$raw" "$@"; then
    return 1
  fi

  if [ "$VERIFY" != "1" ]; then
    cp "$raw" "$dest"
    echo "      VERIFY=0，原样入库 $(grep -c '^#EXTINF' "$dest") 条"
    return 0
  fi

  echo "      校验中（并发 $WORKERS，单条 ${TIMEOUT}s）…"
  if python3 "$HERE/verify.py" "$raw" --write "$dest" --app-safe \
       --workers "$WORKERS" --timeout "$TIMEOUT" 2>&1 \
       | grep -E '可用|失败归因|^  [^ ]' | head -20; then
    :
  fi
  if [ ! -s "$dest" ]; then
    echo "WARN 校验后为空，回退用原始列表" >&2
    cp "$raw" "$dest"
    return 1
  fi
  # 校验结果覆盖写入，头部留一行来源说明
  local tmpf; tmpf="$(mktemp)"
  { echo "#EXTM3U"; \
    echo "# verified $(date '+%F %T') by 01-公共源/verify.py --app-safe | 原始 $(grep -c '^#EXTINF' "$raw") 条 → 可播 $(grep -c '^#EXTINF' "$dest") 条"; \
    grep -v '^#EXTM3U' "$dest"; } > "$tmpf"
  mv "$tmpf" "$dest"
  printf 'DONE %-26s %s 条可播\n' "$name" "$(grep -c '^#EXTINF' "$dest")"
}

echo "[$(date '+%F %T')] 同步公共源  VERIFY=$VERIFY"

sync_one "public-zbds-ipv4" \
  "https://live.zbds.top/tv/iptv4.m3u" \
  "$GH_PROXY/iptv4.m3u"

sync_one "public-zbds-ipv6" \
  "https://live.zbds.top/tv/iptv6.m3u" \
  "$GH_PROXY/iptv6.m3u"


sync_one "public-suxuang" \
  "https://raw.githubusercontent.com/suxuang/myIPTV/main/ipv4.m3u"

sync_one "public-iptv-org-cn" \
  "https://iptv-org.github.io/iptv/countries/cn.m3u"

echo "[$(date '+%F %T')] 完成"
