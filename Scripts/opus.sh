#!/bin/bash
# 从源码编译 arm64 + x86_64 通用静态 libopus 到 build/opus/libopus.a（不依赖 Homebrew）
set -euo pipefail
cd "$(dirname "$0")/.."
VER=1.5.2
SHA=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
OUT=build/opus
[ -f "$OUT/libopus.a" ] && exit 0

WORK=build/opus-src
rm -rf "$WORK" && mkdir -p "$WORK" "$OUT"
curl -fsSL "https://downloads.xiph.org/releases/opus/opus-$VER.tar.gz" -o "$WORK/opus.tar.gz"
echo "$SHA  $WORK/opus.tar.gz" | shasum -a 256 -c - >/dev/null
tar xzf "$WORK/opus.tar.gz" -C "$WORK"

LIBS=()
for ARCH in arm64 x86_64; do
    SRC="$WORK/$ARCH"
    cp -R "$WORK/opus-$VER" "$SRC"
    (cd "$SRC" && CFLAGS="-O2 -arch $ARCH -mmacosx-version-min=15.0" ./configure -q \
        --host="${ARCH/arm64/aarch64}-apple-darwin" --enable-static --disable-shared \
        --disable-doc --disable-extra-programs && make -s -j"$(sysctl -n hw.ncpu)")
    LIBS+=("$SRC/.libs/libopus.a")
done
lipo -create "${LIBS[@]}" -output "$OUT/libopus.a"
rm -rf "$WORK"
