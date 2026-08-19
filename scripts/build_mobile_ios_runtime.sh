#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/packages/bhe_runtime"
OUT="${BHE_IOS_RUNTIME_OUT:-$ROOT/dist/mobile-ios-runtime}"
ORT_XCFRAMEWORK="${BHE_ORT_IOS_XCFRAMEWORK:-}"

die() {
  echo "错误：$*" >&2
  exit 2
}

command -v cargo >/dev/null 2>&1 || die "未找到 cargo。"
command -v rustc >/dev/null 2>&1 || die "未找到 rustc。"
[[ -n "$ORT_XCFRAMEWORK" && -d "$ORT_XCFRAMEWORK" ]] || \
  die "未找到 ONNX Runtime XCFramework。设置 BHE_ORT_IOS_XCFRAMEWORK。"

for target in aarch64-apple-ios x86_64-apple-ios-sim arm64-apple-ios-sim; do
  target_libdir="$(rustc --print target-libdir --target "$target" 2>/dev/null || true)"
  [[ -d "$target_libdir" ]] || \
    die "未安装 Rust target $target。请执行：rustup target add $target"
done

rm -rf "$OUT"
mkdir -p "$OUT/device" "$OUT/simulator" "$OUT/include" "$OUT/onnxruntime"

cargo build --manifest-path "$PACKAGE/Cargo.toml" --release --target aarch64-apple-ios
cargo build --manifest-path "$PACKAGE/Cargo.toml" --release --target x86_64-apple-ios-sim
cargo build --manifest-path "$PACKAGE/Cargo.toml" --release --target arm64-apple-ios-sim

cp "$PACKAGE/target/aarch64-apple-ios/release/libbhe_runtime.a" "$OUT/device/"
lipo -create \
  "$PACKAGE/target/x86_64-apple-ios-sim/release/libbhe_runtime.a" \
  "$PACKAGE/target/arm64-apple-ios-sim/release/libbhe_runtime.a" \
  -output "$OUT/simulator/libbhe_runtime.a"
cp "$PACKAGE/include/bhe_runtime.h" "$OUT/include/"
cp -R "$ORT_XCFRAMEWORK" "$OUT/onnxruntime/"

echo "iOS Rust Runtime 已生成：$OUT"
echo "下一步：将 device/simulator 静态库、header 和 ONNX Runtime XCFramework 接入 Runner。"
