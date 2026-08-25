#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER_BIN:-$ROOT/.tooling/flutter/bin/flutter}"
RUNTIME_OUT="${BHE_RUNTIME_OUT:-$ROOT/dist/macos-runtime}"
APP_DIR="$ROOT/apps/desktop/build/macos/Build/Products/Release"
APP_NAME="${BHE_APP_NAME:-BHE}"
APP="$APP_DIR/$APP_NAME.app"
BUILD_NAME="${BHE_BUILD_NAME:-}"
BUILD_NUMBER="${BHE_BUILD_NUMBER:-}"
PACKAGE_OUT="${BHE_PACKAGE_OUT:-}"

if [[ ! -x "$FLUTTER" ]]; then
  echo "Flutter SDK not found: $FLUTTER" >&2
  exit 2
fi

if [[ "${BHE_SKIP_RUNTIME_PREPARE:-0}" != "1" ]]; then
  "$ROOT/scripts/prepare_macos_runtime.sh" "$RUNTIME_OUT"
fi
(
  cd "$ROOT/apps/desktop"
  build_args=(build macos --release)
  if [[ -n "$BUILD_NAME" ]]; then
    build_args+=(--build-name "$BUILD_NAME")
  fi
  if [[ -n "$BUILD_NUMBER" ]]; then
    build_args+=(--build-number "$BUILD_NUMBER")
  fi
  "$FLUTTER" "${build_args[@]}"
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
  --model "$APP_RUNTIME/third_party/basketball-shot-detection/bball_model.pt"

if [[ -n "${BHE_CODESIGN_IDENTITY:-}" ]]; then
  codesign --deep --force --options runtime \
    --sign "$BHE_CODESIGN_IDENTITY" "$APP"
else
  # Re-sign ad hoc after embedding the runtime so Flutter's original seal is
  # not invalidated by the copied Engine/Python/model/FFmpeg files.
  codesign --deep --force --options runtime --sign - "$APP"
  echo "Warning: app uses an ad-hoc signature; this package is for local/testing use and is not notarized." >&2
fi

echo "Built macOS app: $APP"

if [[ "${BHE_SKIP_PACKAGE:-0}" != "1" ]]; then
  if [[ -z "$PACKAGE_OUT" ]]; then
    package_version="${BUILD_NAME:-local}"
    package_kind="adhoc"
    if [[ -n "${BHE_CODESIGN_IDENTITY:-}" ]]; then
      package_kind="signed"
    fi
    PACKAGE_OUT="$ROOT/dist/BHE-macos-arm64-v${package_version}-${package_kind}.zip"
  fi
  mkdir -p "$(dirname "$PACKAGE_OUT")"
  rm -f "$PACKAGE_OUT"
  ditto -c -k --norsrc --keepParent "$APP" "$PACKAGE_OUT"
  shasum -a 256 "$PACKAGE_OUT" | tee "${PACKAGE_OUT}.sha256"
  echo "Packaged macOS app: $PACKAGE_OUT"
fi
