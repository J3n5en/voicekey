#!/bin/bash
# crates/core + wtlocal → app/src/main/jniLibs/arm64-v8a/libvoicekey.so
set -euo pipefail
cd "$(dirname "$0")"
SDK=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}
export ANDROID_NDK_HOME=${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/* | sort -V | tail -1)}
export CMAKE_TOOLCHAIN_FILE=$PWD/rust/android.cmake
ROOT=$(cd .. && pwd)
export RUSTFLAGS="--remap-path-prefix=$HOME=~ --remap-path-prefix=$ROOT=."
export CFLAGS_aarch64_linux_android="-ffile-prefix-map=$HOME=~ -ffile-prefix-map=$ROOT=."
cargo ndk -t arm64-v8a -P 26 -o app/src/main/jniLibs --manifest-path rust/Cargo.toml build --release
