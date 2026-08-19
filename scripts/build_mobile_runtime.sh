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
[[ -n "$NDK" && -d "$NDK" ]] || die "未找到 Android NDK。设置 BHE_ANDROID_NDK，或设置 ANDROID_NDK_HOME/ANDROID_NDK_ROOT。"
[[ -n "$ORT_DIR" && -f "$ORT_DIR/$ABI/libonnxruntime.so" ]] || die "未找到 ONNX Runtime Android 库。设置 BHE_ORT_ANDROID_DIR，并放置 $ABI/libonnxruntime.so。"

if command -v rustup >/dev/null 2>&1; then
  rustup target list --installed 2>/dev/null | grep -qx "$TARGET" || die "未安装 Rust target $TARGET。请执行：rustup target add $TARGET"
else
  rustc --print target-libdir --target "$TARGET" >/dev/null 2>&1 || die "当前 Rust toolchain 不支持 $TARGET，请安装 rustup 或对应 target。"
  TARGET_LIBDIR="$(rustc --print target-libdir --target "$TARGET")"
  [[ -d "$TARGET_LIBDIR" ]] || die "当前 Rust toolchain 未安装 $TARGET，请安装 rustup 后执行：rustup target add $TARGET"
fi

CLANG="$NDK/toolchains/llvm/prebuilt/darwin-arm64/bin/aarch64-linux-android21-clang"
[[ -x "$CLANG" ]] || CLANG="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android21-clang"
[[ -x "$CLANG" ]] || die "NDK 中未找到 aarch64-linux-android21-clang。"

echo "构建 Rust Android Runtime: $TARGET"
CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG" \
  cargo build --manifest-path "$PACKAGE/Cargo.toml" --release --target "$TARGET"

DEST="$OUT/$ABI"
mkdir -p "$DEST"
cp "$PACKAGE/target/$TARGET/release/libbhe_runtime.so" "$DEST/libbhe_runtime.so"
cp "$ORT_DIR/$ABI/libonnxruntime.so" "$DEST/libonnxruntime.so"

echo "Android Runtime 已生成：$DEST"
echo "下一步：cd apps/mobile && flutter build apk --release"
