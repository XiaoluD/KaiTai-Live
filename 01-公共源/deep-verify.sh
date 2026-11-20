#!/usr/bin/env bash
# 深度校验：在真实 WKWebView 里逐个试播，只留下「点了真能出画面」的频道。
#
# 跟 verify.py 的分工：
#   verify.py      只用 HTTP 探测，快（50 秒）、cron 友好，但挡不住 FLV 这类
#                  「请求通、解码不了」的源，实测两者差 19 个百分点。
#   deep-verify.sh 用真实播放器试播，慢（约 1 分钟）、需要 GUI 会话，
#                  结果是本 app 的地面真相。
#
# 用法:
#   ./01-公共源/deep-verify.sh                    # 处理 IPv4 公共源
#   ./01-公共源/deep-verify.sh 输入.m3u 输出.m3u   # 指定文件
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="${1:-$HERE/raw/public-zbds-ipv4.m3u}"
DST="${2:-$ROOT/web/playlists/public-zbds-ipv4.m3u}"
CONC="${CONC:-10}"
TMO="${TMO:-7}"
BIN="${TMPDIR:-/tmp}/iptv-verify/bin/probe-batch"
mkdir -p "$(dirname "$BIN")"
TSV="${TMPDIR:-/tmp}/iptv-wk-$(date +%s).tsv"
PORT="${PORT:-63311}"

[ -f "$SRC" ] || { echo "找不到输入：$SRC" >&2; exit 1; }

# 1) 编译试播探针（已存在就跳过）
if [ ! -x "$BIN" ] || [ "$ROOT/mac-app/probe-batch.swift" -nt "$BIN" ]; then
  echo "== 编译 probe-batch"
  swiftc -O "$ROOT/mac-app/probe-batch.swift" -o "$BIN" \
    -framework AppKit -framework WebKit || { echo "编译失败" >&2; exit 1; }
fi

# 2) 起一个本地静态服务当页面宿主（WKWebView 需要一个 http 源）
echo "== 启动临时静态服务 :$PORT"
( cd "$ROOT/web" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 1.2
curl -sf -o /dev/null "http://127.0.0.1:$PORT/index.html" || { echo "静态服务没起来" >&2; exit 1; }

# 3) 真实试播
echo "== 真实试播（并发 ${CONC}，单条 ${TMO}s）"
"$BIN" "http://127.0.0.1:$PORT/index.html" "$SRC" "$TSV" "$CONC" "$TMO"

# 4) 按结果重建列表
echo "== 重建播放列表"
python3 "$HERE/build-playlist.py" "$SRC" "$TSV" "$DST.tmp" || exit 1
{ echo "#EXTM3U"
  echo "# deep-verified $(date '+%F %T') by deep-verify.sh | $(grep -c '^#EXTINF' "$DST.tmp") 条实测可播"
  grep -v '^#EXTM3U' "$DST.tmp"; } > "$DST"
rm -f "$DST.tmp"

echo "== 完成：${DST}（$(grep -c '^#EXTINF' "$DST") 条）"
echo "   实测明细：${TSV}"
