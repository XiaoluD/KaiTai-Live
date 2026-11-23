#!/usr/bin/env bash
# 开台 IPTV 网页部署到 ECS（标准入口）
# 用法: ./deploy/sync.sh
# 权限坑: Mac 生成的文件常是 600，经 rsync -a 带过去后 nginx(worker) 读不了 → 部署后远端统一 chmod
# （Mac 自带 rsync 是 openrsync，不支持 --chmod=D755,F644 语法，所以用远端 chmod 方案）
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rsync -av --delete --exclude '.DS_Store' --no-owner --no-group \
  "$ROOT/web/" "aliyun101-root:/var/www/iptv/"
ssh aliyun101-root 'chmod -R u+rwX,go+rX /var/www/iptv'
echo "部署完成: https://iptv.wusi321.top"
