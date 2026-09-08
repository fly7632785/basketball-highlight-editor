#!/usr/bin/env bash
# 把某个 GitHub Release 的安装包同步到阿里云 OSS，供国内直连下载。
# 前置：
#   1. ossutil 已安装且 ~/.ossutilconfig 配置了有写权限的 AK。
#      安装地址见阿里云官方文档：
#      https://help.aliyun.com/zh/oss/developer-reference/install-ossutil
#      配置：ossutil config -e oss-cn-beijing.aliyuncs.com
#   2. gh 已登录（gh auth status）
# 用法：scripts/upload_release_assets_oss.sh v0.1.0-alpha.5
# 说明：上传路径与官网 website/app.js 的 OSS_PREFIX 约定一致：
#   https://shengshengniannian.oss-cn-beijing.aliyuncs.com/shengshengniannian/basketball-highlight-editor/releases/<文件名>
set -euo pipefail

TAG="${1:?用法：$0 <tag>，例如 v0.1.0-alpha.5}"
REPO="fly7632785/basketball-highlight-editor"
BUCKET="oss://shengshengniannian"
PREFIX="shengshengniannian/basketball-highlight-editor/releases"
STAGE="${BHE_OSS_STAGE:-/tmp/bhe-oss/$TAG}"

command -v ossutil >/dev/null 2>&1 || {
  echo "错误：未安装 ossutil（go install github.com/aliyun/ossutil@v1.7.19）。" >&2
  exit 2
}
command -v gh >/dev/null 2>&1 || { echo "错误：未安装 gh 或未登录。" >&2; exit 2; }

echo "==> 下载 $TAG 的 release 资产到 $STAGE"
mkdir -p "$STAGE"
gh release download "$TAG" -R "$REPO" -D "$STAGE" --clobber

echo "==> 上传到 OSS（公开读路径，同名覆盖）"
ossutil cp -r -f --update "$STAGE"/ "$BUCKET/$PREFIX/"

echo "==> 更新官网使用的 latest 固定下载地址"
shopt -s nullglob
alias_dir="$STAGE/.latest-aliases"
mkdir -p "$alias_dir"

publish_alias() {
  local source="$1"
  local alias="$2"
  local digest
  local checksum="$alias_dir/$alias.sha256"

  ossutil cp -f --meta "Cache-Control:no-cache" "$source" "$BUCKET/$PREFIX/$alias"
  digest="$(shasum -a 256 "$source" | awk '{print $1}')"
  printf '%s  %s\n' "$digest" "$alias" > "$checksum"
  ossutil cp -f --meta "Cache-Control:no-cache" "$checksum" "$BUCKET/$PREFIX/$alias.sha256"
}

for source in "$STAGE"/BHE-macos-arm64-v*.dmg; do
  publish_alias "$source" "BHE-macos-arm64-latest.dmg"
done
for source in "$STAGE"/BHE-macos-x86_64-v*.dmg; do
  publish_alias "$source" "BHE-macos-x86_64-latest.dmg"
done
for source in "$STAGE"/BHE-windows-x64-v*.zip; do
  publish_alias "$source" "BHE-windows-x64-latest.zip"
done

echo "==> 完成。下载地址："
for f in "$STAGE"/*; do
  name="$(basename "$f")"
  echo "  https://shengshengniannian.oss-cn-beijing.aliyuncs.com/$PREFIX/$name"
done
echo "==> 官网固定下载地址已更新，无需修改 website/app.js。"
