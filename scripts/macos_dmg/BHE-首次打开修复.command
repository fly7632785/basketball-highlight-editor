#!/bin/bash
set -u

APP_NAME="BHE.app"

pause_and_exit() {
  local code="$1"
  printf '\n按回车关闭此窗口...'
  read -r _ || true
  exit "$code"
}

show_error() {
  local message="$1"
  printf '\n错误：%s\n' "$message" >&2
  osascript -e "display dialog \"BHE 修复失败：$message\" buttons {\"知道了\"} default button \"知道了\" with icon stop" >/dev/null 2>&1 || true
  pause_and_exit 1
}

find_installed_app() {
  local candidate
  for candidate in \
    "/Applications/$APP_NAME" \
    "$HOME/Applications/$APP_NAME"; do
    if [[ -d "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

clear
echo "BHE macOS 首次启动修复与验证"
echo "================================"
echo
echo "请先把 BHE.app 拖到‘应用程序’文件夹。"
echo "这个工具只处理 BHE.app，不会修改其他文件。"
echo

APP_PATH="$(find_installed_app || true)"
if [[ -z "$APP_PATH" ]]; then
  echo "没有在‘应用程序’中找到 BHE.app，正在打开选择窗口..."
  APP_PATH="$(osascript -e 'POSIX path of (choose file with prompt "请选择已经安装的 BHE.app" without invisibles)' 2>/dev/null || true)"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" || "$(basename "$APP_PATH")" != "$APP_NAME" ]]; then
  show_error "没有找到有效的 BHE.app。请先将应用拖到‘应用程序’后再运行。"
fi

echo "目标应用：$APP_PATH"
echo
echo "[1/3] 检查下载隔离属性..."
if xattr -p com.apple.quarantine "$APP_PATH" >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$APP_PATH" || show_error "无法清除 macOS 下载隔离属性。"
  echo "已清除 com.apple.quarantine。"
else
  echo "未发现下载隔离属性。"
fi

echo
echo "[2/3] 验证应用签名完整性..."
if ! codesign --verify --deep --strict --verbose=2 "$APP_PATH"; then
  show_error "应用签名验证失败，应用文件可能不完整。请重新下载 DMG。"
fi
echo "签名完整性验证通过。"

echo
echo "[3/3] 启动 BHE..."
open "$APP_PATH" || show_error "应用验证通过，但启动失败。"

echo
echo "完成：BHE 已通过本机签名完整性验证并尝试启动。"
echo "说明：Ad Hoc 签名不等于 Apple Developer ID 签名，也不代表已完成公证。"
osascript -e 'display dialog "BHE 修复与验证完成，现在可以使用了。" buttons {"打开的应用"} default button "打开的应用" with icon note' >/dev/null 2>&1 || true
pause_and_exit 0
