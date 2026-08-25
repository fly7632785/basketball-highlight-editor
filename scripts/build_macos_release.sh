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
ARCH="${BHE_ARCH:-$(uname -m)}"
PACKAGE_OUT="${BHE_PACKAGE_OUT:-}"
DMG_OUT="${BHE_DMG_OUT:-}"

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
  --model "$APP_RUNTIME/models/bball_model.pt"

if [[ -n "${BHE_CODESIGN_IDENTITY:-}" ]]; then
  codesign --deep --force --options runtime \
    --sign "$BHE_CODESIGN_IDENTITY" "$APP"
else
  # Re-sign ad hoc after embedding the runtime so Flutter's original seal is
  # not invalidated by the copied Engine/Python/model/FFmpeg files. Do not
  # enable hardened runtime for an ad-hoc build: macOS rejects the embedded
  # media_kit frameworks without a real Developer ID Team ID.
  codesign --deep --force --sign - "$APP"
  echo "Warning: app uses an ad-hoc signature; this package is for local/testing use and is not notarized." >&2
fi

echo "Built macOS app: $APP"

write_sha256() {
  local artifact="$1"
  local artifact_dir
  local artifact_name
  artifact_dir="$(dirname "$artifact")"
  artifact_name="$(basename "$artifact")"
  (
    cd "$artifact_dir"
    shasum -a 256 "$artifact_name"
  ) | tee "${artifact}.sha256"
}

if [[ "${BHE_SKIP_PACKAGE:-0}" != "1" ]]; then
  package_version="${BUILD_NAME:-local}"
  package_kind="adhoc"
  if [[ -n "${BHE_CODESIGN_IDENTITY:-}" ]]; then
    package_kind="signed"
  fi
  if [[ -z "$PACKAGE_OUT" ]]; then
    PACKAGE_OUT="$ROOT/dist/BHE-macos-${ARCH}-v${package_version}-${package_kind}.zip"
  fi
  mkdir -p "$(dirname "$PACKAGE_OUT")"
  rm -f "$PACKAGE_OUT"
  ditto -c -k --norsrc --keepParent "$APP" "$PACKAGE_OUT"
  write_sha256 "$PACKAGE_OUT"
  echo "Packaged macOS app: $PACKAGE_OUT"

  if [[ "${BHE_SKIP_DMG:-0}" != "1" ]]; then
    if [[ -z "$DMG_OUT" ]]; then
      DMG_OUT="$ROOT/dist/BHE-macos-${ARCH}-v${package_version}-${package_kind}.dmg"
    fi
    dmg_staging="$(mktemp -d "${TMPDIR:-/tmp}/bhe-dmg.XXXXXX")"
    trap 'rm -rf "$dmg_staging"' EXIT
    ditto "$APP" "$dmg_staging/$APP_NAME.app"
    ln -s /Applications "$dmg_staging/Applications"
    rm -f "$DMG_OUT"
    hdiutil create -volname "BHE" -srcfolder "$dmg_staging" \
      -ov -format UDZO "$DMG_OUT"
    write_sha256 "$DMG_OUT"
    echo "Packaged macOS installer: $DMG_OUT"
  fi
fi
