#!/bin/bash
# crates/core → VoiceKeyCoreFFI.xcframework（真机 arm64 + 模拟器 arm64/x86_64）
set -euo pipefail
cd "$(dirname "$0")"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export RUSTFLAGS="--remap-path-prefix=$HOME=~ --remap-path-prefix=$(cd ../.. && pwd)=."
export CFLAGS="-ffile-prefix-map=$HOME=~"
LIB=libvoicekey_ffi.a
T=rust/target
for t in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    cargo build --manifest-path rust/Cargo.toml --release --target "$t"
done
mkdir -p "$T/universal-ios-sim"
lipo -create "$T/aarch64-apple-ios-sim/release/$LIB" "$T/x86_64-apple-ios/release/$LIB" -output "$T/universal-ios-sim/$LIB"
rm -rf VoiceKeyCoreFFI.xcframework
xcodebuild -create-xcframework \
    -library "$T/aarch64-apple-ios/release/$LIB" -headers include \
    -library "$T/universal-ios-sim/$LIB" -headers include \
    -output VoiceKeyCoreFFI.xcframework
