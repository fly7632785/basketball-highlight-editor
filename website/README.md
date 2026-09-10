# BHE 官网

`bhe.jafir.top` 的静态官网。纯 HTML/CSS/JS，无构建步骤。

## 目录

```text
website/
  index.html          页面
  styles.css          样式（深色首尾 + 浅色中段）
  app.js              下载链接渲染 + 滚动进场
  favicon.svg
  robots.txt          搜索引擎抓取规则
  sitemap.xml         网站地图
  assets/             截图与演示封面（已压缩）
  nginx/              服务器 nginx 站点配置
```

## 本地预览

```bash
python3 -m http.server 8765 --directory website
# 打开 http://localhost:8765
```

## 部署（Oracle 服务器 / nginx）

```bash
scripts/deploy_website.sh
```

脚本做三件事：rsync `website/`（不含 nginx/）到服务器 `/data/web/bhe`、安装
`bhe.jafir.top.conf` 到 `/etc/nginx/conf.d/`、`nginx -t` 后 reload。
可用 `BHE_SERVER` / `BHE_SSH_KEY` 覆盖目标。

服务器侧一次性的前置（已配置，备查）：证书用现有 `/etc/nginx/ssl/cf.pem`
（Cloudflare origin 证书，域名需开启橙云代理）。

## DNS（Cloudflare，一次性）

`bhe` A 记录 → `161.153.44.64`，开启橙云代理。生效后
`https://bhe.jafir.top` 即可访问。

## 安装包分发（阿里云 OSS）

安装包不放在官网服务器（体积大），统一走 OSS，路径约定见
`scripts/upload_release_assets_oss.sh`：

```text
https://shengshengniannian.oss-cn-beijing.aliyuncs.com/shengshengniannian/basketball-highlight-editor/releases/<文件名>
```

发新版流程：

1. 推 `v*` tag，等 GitHub Actions 构建 GitHub Release；
2. 发布流程自动把版本文件和 `latest` 固定别名同步到 OSS；
3. 官网始终使用固定的 `latest` 地址，不需要修改 `website/app.js` 或重新部署官网。

Android APK 是例外：阿里云 OSS 公共 endpoint 会拒绝公开分发 APK，官网 Android 按钮使用
当前 GitHub Release 的版本固定地址。发布新的 Android 版本时，需要同步更新
`website/app.js` 中的 GitHub Release 地址；桌面端仍使用 OSS 的 `latest` 别名。

## SEO

`index.html` 已包含中文产品标题与描述、Canonical、Open Graph 分享信息、JSON-LD
结构化数据和中英文搜索关键词；`robots.txt` 与 `sitemap.xml` 用于帮助百度和 Google
发现官网。搜索引擎收录需要站点上线并由站长平台抓取，不能仅靠页面标签保证排名。

手动补传时可以运行 `scripts/upload_release_assets_oss.sh <tag>`，脚本也会同时更新固定下载别名。

## 设计说明

- 视觉语言与产品审核工作台同构：深色面板 + 琥珀橙，橙色在产品里
  表示"候选片段"，官网中沿用于候选时间轴（hero 签名元素）、kicker 和 CTA；
- `prefers-reduced-motion` 下动画全部静止；滚动进场不依赖
  IntersectionObserver（同步 scroll + clientHeight 兜底）；
- 中文为主，无外部字体/脚本依赖，总资源 < 1MB。
