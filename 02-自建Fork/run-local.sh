#!/usr/bin/env bash
# 本机重新生成自建源 → 同步到 web/ → 重建 app
# 用法: ./02-自建Fork/run-local.sh [--no-build]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRV="$ROOT/.runtime/iptv-api"

if [ ! -x "$SRV/.venv/bin/python" ]; then
  echo "缺少虚拟环境: $SRV/.venv" >&2
  echo "首次准备:" >&2
  echo "  1) 克隆源码到 $SRV（可用 gh-proxy 镜像）" >&2
  echo "  2) python3 -m venv .venv && .venv/bin/pip install -r <依赖>" >&2
  exit 1
fi

echo "[1/3] 生成播放列表（测速 + 过滤，约 1–2 分钟）"
cd "$SRV" || exit 1
./.venv/bin/python main.py || { echo "生成失败" >&2; exit 1; }

echo
echo "[2/3] 同步到 web/playlists/"
cd "$ROOT" || exit 1
./02-自建Fork/sync-self.sh || exit 1

if [ "${1:-}" = "--no-build" ]; then
  echo
  echo "[3/3] 跳过重建 app（--no-build）"
  exit 0
fi

echo
echo "[3/3] 重建 app"
pkill -f "MacOS/IPTV" 2>/dev/null || true
./mac-app/build.sh | tail -2
echo
echo "完成。重开 app 后点「我的 iptv-api」即可。"
