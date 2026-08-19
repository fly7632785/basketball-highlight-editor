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

export ORT_IOS_XCFWK_PATH="$ORT_XCFRAMEWORK"

build_ios_target() {
  local target="$1"
  local minimum_flag="$2"
  RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=${minimum_flag} -C link-arg=-framework -C link-arg=UIKit -C link-arg=-framework -C link-arg=Network -C link-arg=-framework -C link-arg=Security -C link-arg=-framework -C link-arg=SystemConfiguration -C link-arg=-framework -C link-arg=CoreFoundation" \
    cargo build --manifest-path "$PACKAGE/Cargo.toml" --release --target "$target"
}

for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  target_libdir="$(rustc --print target-libdir --target "$target" 2>/dev/null || true)"
  [[ -d "$target_libdir" ]] || \
    die "未安装 Rust target ${target}。请执行：rustup target add ${target}"
done

rm -rf "$OUT"
mkdir -p "$OUT/device" "$OUT/simulator" "$OUT/include" "$OUT/onnxruntime"

build_ios_target aarch64-apple-ios -miphoneos-version-min=16.0
build_ios_target aarch64-apple-ios-sim -mios-simulator-version-min=16.0

cp "$PACKAGE/target/aarch64-apple-ios/release/libbhe_runtime.a" "$OUT/device/"
cp "$PACKAGE/target/aarch64-apple-ios-sim/release/libbhe_runtime.a" "$OUT/simulator/libbhe_runtime.a"
cp "$PACKAGE/include/bhe_runtime.h" "$OUT/include/"
cp -R "$ORT_XCFRAMEWORK" "$OUT/onnxruntime/"

echo "iOS Rust Runtime 已生成：$OUT"
echo "下一步：将 device/simulator 静态库、header 和 ONNX Runtime XCFramework 接入 Runner。"
