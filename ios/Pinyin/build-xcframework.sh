#!/bin/bash
# librime（含 leveldb/marisa/yaml-cpp/opencc）静态编译 → RimeFFI.xcframework（真机 arm64 + 模拟器 arm64/x86_64）
set -euo pipefail
cd "$(dirname "$0")"
source versions.env
ROOT=$PWD
CACHE=$ROOT/.cache
OUT=RimeFFI.xcframework
STAMP="$LIBRIME_COMMIT boost-$BOOST_VERSION $(shasum -a 256 build-xcframework.sh | cut -c1-16)"
[ "$(cat "$OUT/.stamp" 2>/dev/null)" = "$STAMP" ] && exit 0
mkdir -p "$CACHE"

BOOST=$CACHE/boost_${BOOST_VERSION//./_}
if [ ! -d "$BOOST/boost" ]; then
    tarball=$CACHE/boost_${BOOST_VERSION//./_}.tar.gz
    [ -f "$tarball" ] || curl -fsSL -o "$tarball" "https://archives.boost.io/release/$BOOST_VERSION/source/$(basename "$tarball")"
    echo "$BOOST_SHA256  $tarball" | shasum -a 256 -c -
    tar -xzf "$tarball" -C "$CACHE" "$(basename "$BOOST")/boost"
fi

SRC=$CACHE/librime
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$LIBRIME_COMMIT" ]; then
    rm -rf "$SRC"
    git init -q "$SRC"
    git -C "$SRC" fetch -q --depth 1 https://github.com/rime/librime.git "$LIBRIME_COMMIT"
    git -C "$SRC" checkout -q FETCH_HEAD
    git -C "$SRC" submodule update -q --init --depth 1 deps/leveldb deps/marisa-trie deps/yaml-cpp deps/opencc
fi

# build <slice> <sysroot> <archs>
build() {
    local prefix=$CACHE/out/$1 work=$CACHE/build/$1
    local common=(
        -G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$2" -DCMAKE_OSX_ARCHITECTURES="$3"
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS_RELEASE="-Os -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-Os -DNDEBUG" -DCMAKE_MACOSX_BUNDLE=OFF
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF
        -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH="$prefix"
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    )
    rm -rf "$prefix" "$work" && mkdir -p "$work"
    configure() { local log=$work/$(basename "$2").log; cmake -S "$1" -B "$2" "${@:3}" >"$log" 2>&1 || { cat "$log"; return 1; }; }
    dep() { local d=$1; shift; configure "$SRC/deps/$d" "$work/$d" "${common[@]}" "$@"; cmake --build "$work/$d" --target "${TARGET:-install}" >/dev/null; }
    dep leveldb -DLEVELDB_BUILD_BENCHMARKS=OFF -DLEVELDB_BUILD_TESTS=OFF -DLEVELDB_INSTALL=ON
    dep marisa-trie -DBUILD_TESTING=OFF -DENABLE_TOOLS=OFF
    dep yaml-cpp -DYAML_CPP_BUILD_CONTRIB=OFF -DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_TOOLS=OFF
    TARGET=libopencc dep opencc -DBUILD_DOCUMENTATION=OFF -DENABLE_GTEST=OFF -DBUILD_PYTHON=OFF -DUSE_SYSTEM_MARISA=ON -DCMAKE_CXX_FLAGS="-I$prefix/include"
    cmake --install "$work/opencc" --component Unspecified >/dev/null 2>&1 || true # 命令行工具装不上，库和头文件已装好
    [ -f "$prefix/lib/libopencc.a" ] && [ -f "$prefix/include/opencc/opencc.h" ]
    configure "$SRC" "$work/rime" "${common[@]}" -DBoost_INCLUDE_DIR="$BOOST" -DBoost_NO_SYSTEM_PATHS=ON -DMarisa_LIBRARY="$prefix/lib/libmarisa.a" \
        -DBUILD_STATIC=ON -DBUILD_TEST=OFF -DENABLE_LOGGING=OFF -DBUILD_MERGED_PLUGINS=ON -DENABLE_TIMESTAMP=OFF
    cmake --build "$work/rime" --target rime-static >/dev/null
    libtool -static -no_warning_for_no_symbols -o "$prefix/librime.a" "$work/rime/lib/librime.a" \
        "$prefix"/lib/lib{leveldb,marisa,yaml-cpp,opencc}.a
}
build ios iphoneos arm64
build sim iphonesimulator "arm64;x86_64"

# 头文件放进 RimeFFI/ 子目录，免得和 VoiceKeyCoreFFI 的 include/module.modulemap 撞名
HDR=$CACHE/include
rm -rf "$HDR" && mkdir -p "$HDR/RimeFFI"
cp "$SRC/src/rime_api.h" "$HDR/RimeFFI/"
printf 'module RimeFFI {\n    header "rime_api.h"\n    link "c++"\n    export *\n}\n' > "$HDR/RimeFFI/module.modulemap"
rm -rf "$OUT"
xcodebuild -create-xcframework \
    -library "$CACHE/out/ios/librime.a" -headers "$HDR" \
    -library "$CACHE/out/sim/librime.a" -headers "$HDR" \
    -output "$OUT" >/dev/null
echo "$STAMP" > "$OUT/.stamp"
echo "$OUT ($LIBRIME_VERSION)"
