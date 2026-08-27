#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/packages/bhe_runtime"
OUT="$ROOT/apps/mobile/android/app/src/main/jniLibs"
NDK="${BHE_ANDROID_NDK:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"
ORT_DIR="${BHE_ORT_ANDROID_DIR:-}"
TARGET="aarch64-linux-android"
ABI="arm64-v8a"

die() {
  echo "错误：$*" >&2
  exit 2
}

if [[ -z "$NDK" && -d "$HOME/Library/Android/sdk/ndk" ]]; then
  NDK="$(find "$HOME/Library/Android/sdk/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
fi

command -v cargo >/dev/null 2>&1 || die "未找到 cargo，请安装 Rust toolchain。"
if command -v rustup >/dev/null 2>&1; then
  CARGO_BIN="$(rustup which cargo)"
  RUSTC_BIN="$(rustup which rustc)"
else
  CARGO_BIN="$(command -v cargo)"
  RUSTC_BIN="$(command -v rustc)"
fi
[[ -n "$NDK" && -d "$NDK" ]] || die "未找到 Android NDK。设置 BHE_ANDROID_NDK，或设置 ANDROID_NDK_HOME/ANDROID_NDK_ROOT。"
[[ -n "$ORT_DIR" && -f "$ORT_DIR/$ABI/libonnxruntime.so" ]] || die "未找到 ONNX Runtime Android 库。设置 BHE_ORT_ANDROID_DIR，并放置 $ABI/libonnxruntime.so。"

if command -v rustup >/dev/null 2>&1; then
  rustup target list --installed 2>/dev/null | grep -qx "$TARGET" || die "Rust target ${TARGET} is not installed; run: rustup target add ${TARGET}"
else
  "$RUSTC_BIN" --print target-libdir --target "$TARGET" >/dev/null 2>&1 || die "Rust toolchain does not support ${TARGET}"
  TARGET_LIBDIR="$("$RUSTC_BIN" --print target-libdir --target "$TARGET")"
  [[ -d "$TARGET_LIBDIR" ]] || die "Rust target ${TARGET} is not installed; run: rustup target add ${TARGET}"
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) NDK_HOST_TAGS=(darwin-arm64 darwin-x86_64) ;;
  Darwin-x86_64) NDK_HOST_TAGS=(darwin-x86_64) ;;
  Linux-x86_64) NDK_HOST_TAGS=(linux-x86_64) ;;
  *) die "不支持当前主机上的 Android NDK：$(uname -s)-$(uname -m)" ;;
esac

CLANG=""
for host_tag in "${NDK_HOST_TAGS[@]}"; do
  candidate="$NDK/toolchains/llvm/prebuilt/$host_tag/bin/aarch64-linux-android21-clang"
  if [[ -x "$candidate" ]]; then
    CLANG="$candidate"
    break
  fi
done
[[ -n "$CLANG" ]] || die "NDK 中未找到可用的 aarch64-linux-android21-clang。"

echo "构建 Rust Android Runtime: $TARGET"
RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-soname,libbhe_runtime.so" \
CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG" \
RUSTC="$RUSTC_BIN" \
  "$CARGO_BIN" build --manifest-path "$PACKAGE/Cargo.toml" --release --target "$TARGET" --features dynamic-onnx

DEST="$OUT/$ABI"
mkdir -p "$DEST"
cp "$PACKAGE/target/$TARGET/release/libbhe_runtime.so" "$DEST/libbhe_runtime.so"
cp "$ORT_DIR/$ABI/libonnxruntime.so" "$DEST/libonnxruntime.so"

echo "Android Runtime 已生成：$DEST"
echo "下一步：cd apps/mobile && flutter build apk --release"
