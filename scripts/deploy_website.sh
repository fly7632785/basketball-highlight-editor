#!/usr/bin/env bash
# 部署 BHE 官网到 Oracle 服务器（bhe.jafir.top，nginx 静态托管）。
# 用法：scripts/deploy_website.sh
# 可用环境变量覆盖：BHE_SERVER / BHE_SSH_KEY
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE_DIR="$ROOT/website"
SERVER="${BHE_SERVER:-opc@161.153.44.64}"
KEY="${BHE_SSH_KEY:-$HOME/.ssh/ssh-key-2026-06-04.key}"

[[ -f "$SITE_DIR/index.html" ]] || { echo "错误：未找到 $SITE_DIR/index.html" >&2; exit 2; }

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -i "$KEY")

echo "==> 同步站点文件到 $SERVER:/data/web/bhe"
ssh "${SSH_OPTS[@]}" "$SERVER" "mkdir -p /data/web/bhe"
rsync -az --delete -e "ssh ${SSH_OPTS[*]}" \
  --exclude 'nginx/' \
  "$SITE_DIR/" "$SERVER:/data/web/bhe/"

echo "==> 安装 nginx 配置"
scp -p "${SSH_OPTS[@]}" "$SITE_DIR/nginx/bhe.jafir.top.conf" "$SERVER:/tmp/bhe.jafir.top.conf"
ssh "${SSH_OPTS[@]}" "$SERVER" \
  "sudo install -m 644 /tmp/bhe.jafir.top.conf /etc/nginx/conf.d/bhe.jafir.top.conf && sudo nginx -t && sudo systemctl reload nginx"

echo "==> 部署完成。DNS 解析生效后可访问：https://bhe.jafir.top"
echo "    （Cloudflare 需添加 A 记录：bhe -> $(ssh "${SSH_OPTS[@]}" "$SERVER" "curl -s --max-time 5 ifconfig.me || echo 服务器IP")，开启橙云代理）"
