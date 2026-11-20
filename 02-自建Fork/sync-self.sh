#!/usr/bin/env bash
# 同步自建 iptv-api 产物到 web/playlists/
# 用法: cp self.env.example self.env && 编辑 SELF_URL && ./02-自建Fork/sync-self.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../web/playlists"
DEST="$OUT/self-iptv-api.m3u"
mkdir -p "$OUT"

if [ -f "$HERE/self.env" ]; then
  # shellcheck disable=SC1091
  . "$HERE/self.env"
fi

SELF_URL="${SELF_URL:-}"
SELF_FILE="${SELF_FILE:-}"

# 模式一：本机跑 iptv-api 生成的本地文件（推荐，无网络依赖）
if [ -n "$SELF_FILE" ]; then
  if [ ! -f "$SELF_FILE" ]; then
    echo "SELF_FILE 指向的文件不存在: $SELF_FILE" >&2
    exit 1
  fi
  n="$(grep -c '^#EXTINF' "$SELF_FILE")"
  if [ "$n" -lt 1 ]; then
    echo "本地文件里解析到 0 个频道，放弃" >&2
    exit 1
  fi
  cp "$SELF_FILE" "$DEST"
  printf 'OK   self-iptv-api.m3u            %s 频道（来自本地 %s）\n' "$n" "$(basename "$SELF_FILE")"
  exit 0
fi

if [ -z "$SELF_URL" ] || printf '%s' "$SELF_URL" | grep -q '<'; then
  echo "未配置 SELF_URL 或 SELF_FILE：请先 cp self.env.example self.env 并填写" >&2
  exit 1
fi

echo "[$(date '+%F %T')] 同步自建源: $SELF_URL"

tmp="$(mktemp)"
curl_args=(-fsSL --max-time 90)
[ -n "${HTTP_PROXY_URL:-}" ] && curl_args+=(-x "$HTTP_PROXY_URL")

if ! curl "${curl_args[@]}" -o "$tmp" "$SELF_URL"; then
  rm -f "$tmp"
  echo "FAIL 拉取失败，保留旧文件" >&2
  exit 1
fi

if ! head -1 "$tmp" | grep -q '^#EXTM3U'; then
  rm -f "$tmp"
  echo "FAIL 内容不是 m3u（可能是 Pages 未启用或尚未跑过 workflow）" >&2
  exit 1
fi

n="$(grep -c '^#EXTINF' "$tmp")"
if [ "$n" -lt 1 ]; then
  rm -f "$tmp"
  echo "FAIL 解析到 0 个频道，保留旧文件" >&2
  exit 1
fi

mv "$tmp" "$DEST"
printf 'OK   self-iptv-api.m3u            %s 频道\n' "$n"
