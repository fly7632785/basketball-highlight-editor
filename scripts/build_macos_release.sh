#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER_BIN:-$ROOT/.tooling/flutter/bin/flutter}"
RUNTIME_OUT="${BHE_RUNTIME_OUT:-$ROOT/dist/macos-runtime}"
APP="$ROOT/apps/desktop/build/macos/Build/Products/Release/desktop.app"

if [[ ! -x "$FLUTTER" ]]; then
  echo "Flutter SDK not found: $FLUTTER" >&2
  exit 2
fi

"$ROOT/scripts/prepare_macos_runtime.sh" "$RUNTIME_OUT"
(
  cd "$ROOT/apps/desktop"
  "$FLUTTER" build macos --release
)

APP_RUNTIME="$APP/Contents/Resources/runtime"
rm -rf "$APP_RUNTIME"
mkdir -p "$APP_RUNTIME"
cp -R "$RUNTIME_OUT"/. "$APP_RUNTIME/"

"$RUNTIME_OUT/python/bin/python3" "$APP_RUNTIME/scripts/check_runtime.py" \
  --root "$APP_RUNTIME" \
  --python "$APP_RUNTIME/python/bin/python3" \
  --ffmpeg "$APP_RUNTIME/bin/ffmpeg" \
  --ffprobe "$APP_RUNTIME/bin/ffprobe" \
  --model "$APP_RUNTIME/models/bball_model.pt"

if [[ -n "${BHE_CODESIGN_IDENTITY:-}" ]]; then
  codesign --deep --force --options runtime \
    --sign "$BHE_CODESIGN_IDENTITY" "$APP"
else
  echo "Warning: app was not codesigned; set BHE_CODESIGN_IDENTITY for distribution." >&2
fi

echo "Built macOS app: $APP"
