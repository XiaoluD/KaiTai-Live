#!/bin/bash
# 聚合池更新：拉上游公共列表 → 轻清洗（去重、去广告位）→ 写入 web/playlists
#
# 用法：scripts/update-sources.sh          # 更新全部公共源
#       scripts/update-sources.sh --check  # 只检查上游有没有变化，不写文件
#
# 说明：只重新拉「公共」源；self-iptv-api（本机 iptv-api 产物）不在这里动，
#       它由本机跑 .runtime/iptv-api 生成（update_interval / launchd 自定）。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RAW="$ROOT/01-公共源/raw"
OUT="$ROOT/web/playlists"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

declare -a SOURCES=(
  "public-zbds|https://live.zbds.top/tv/iptv4.m3u|vbskycn/iptv"
  "public-suxuang|https://raw.githubusercontent.com/suxuang/myIPTV/main/ipv4.m3u|suxuang/myIPTV"
  "public-iptv-org-cn|https://iptv-org.github.io/iptv/countries/cn.m3u|iptv-org/cn"
)

changed=0
for spec in "${SOURCES[@]}"; do
  IFS='|' read -r name url repo <<< "$spec"
  tmp=$(mktemp)
  if ! curl -sSL --max-time 60 -A "$UA" -o "$tmp" "$url"; then
    echo "❌ $repo 拉取失败，跳过"
    rm -f "$tmp"; continue
  fi
  n=$(grep -c '^#EXTINF' "$tmp" 2>/dev/null || echo 0)
  if [ "$n" -lt 5 ]; then
    echo "❌ $repo 只有 $n 条，疑似异常，跳过"
    rm -f "$tmp"; continue
  fi

  # 轻清洗：CRLF 统一、去重 URL、剔掉「支持作者」这类推广条目
  clean=$(python3 - "$tmp" <<'PY'
import sys
def entries(path):
    out=[];meta=None
    for ln in open(path,encoding='utf-8',errors='replace'):
        ln=ln.strip()
        if ln.startswith('#EXTINF'): meta=ln
        elif ln and not ln.startswith('#') and meta:
            out.append((meta,ln)); meta=None
    return out
es=entries(sys.argv[1])
seen=set(); res=[]
for meta,u in es:
    if u in seen: continue
    name=meta.rsplit(',',1)[-1].strip()
    if '支持作者' in name or '推广' in name: continue
    seen.add(u); res.append((meta,u))
print("KEEP")
for meta,u in res:
    print(meta); print(u)
PY
)
  count=$(echo "$clean" | grep -c '^#EXTINF' || true)

  dst="$OUT/$name.m3u"
  new_body=$(echo "$clean" | sed '1d')
  new_file="#EXTM3U"$'\n'"$new_body"

  if [ "$CHECK_ONLY" = 1 ]; then
    old_count=$(grep -c '^#EXTINF' "$dst" 2>/dev/null || echo 0)
    echo "· $repo: 上游 $n 条 → 清洗后 $count 条（当前本地 $old_count 条）"
  else
    echo "$new_file" > "$dst"
    mkdir -p "$RAW"
    cp "$tmp" "$RAW/$name-raw-$(date +%Y%m%d).m3u"
    echo "✅ $repo: 上游 $n 条 → 清洗后 $count 条 → $dst"
  fi
  rm -f "$tmp"
done

if [ "$CHECK_ONLY" = 1 ]; then
  echo "（--check 模式，未写入任何文件）"
else
  echo "完成。self-iptv-api 不归本脚本管；App 内「更新源」按钮走 Updater，另有 GitHub Actions 每日自动跑本脚本。"
fi
