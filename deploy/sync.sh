#!/usr/bin/env bash
# 开台 IPTV 网页部署到 ECS（标准入口）
# 用法: ./deploy/sync.sh
# 权限坑: Mac 上生成的文件常是 600，nginx(worker) 读不了 → 必须 --chmod=D755,F644 --no-owner --no-group
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rsync -av --delete --exclude '.DS_Store' \
  --chmod=D755,F644 --no-owner --no-group \
  "$ROOT/web/" "aliyun101-root:/var/www/iptv/"
echo "部署完成: https://iptv.wusi321.top"
