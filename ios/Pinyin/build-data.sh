#!/bin/bash
# 雾凇拼音 base+8105 → 全拼/九宫格方案，用与 librime 同版本的 rime_deployer 在 Mac 上预编译，产物打进键盘包
set -euo pipefail
cd "$(dirname "$0")"
source versions.env
CACHE=$PWD/.cache
OUT=Sources/Pinyin/RimeData
STAMP="librime $LIBRIME_VERSION ($LIBRIME_COMMIT) rime-ice $RIME_ICE_TAG $(cat rime/*.yaml | shasum -a 256 | cut -c1-16)"
[ "$(cat "$OUT/VERSION" 2>/dev/null)" = "$STAMP" ] && exit 0
mkdir -p "$CACHE"

fetch() { # fetch <url> <file> <sha256>
    [ -f "$2" ] || curl -fsSL -o "$2" "$1"
    echo "$3  $2" | shasum -a 256 -c - >/dev/null
}
fetch "$RIME_MAC_URL" "$CACHE/rime-mac.tar.bz2" "$RIME_MAC_SHA256"
fetch "https://github.com/iDvel/rime-ice/releases/download/$RIME_ICE_TAG/full.zip" "$CACHE/rime-ice-$RIME_ICE_TAG.zip" "$RIME_ICE_SHA256"

MAC=$CACHE/rime-mac
rm -rf "$MAC" && mkdir -p "$MAC" && tar -xjf "$CACHE/rime-mac.tar.bz2" -C "$MAC"
DEPLOYER=$(find "$MAC" -name rime_deployer -type f | head -1)

WORK=$CACHE/data
rm -rf "$WORK" && mkdir -p "$WORK"
cp rime/*.yaml "$WORK/"
unzip -q -o "$CACHE/rime-ice-$RIME_ICE_TAG.zip" cn_dicts/8105.dict.yaml cn_dicts/base.dict.yaml -d "$WORK"
DYLD_LIBRARY_PATH=$(dirname "$DEPLOYER")/../lib "$DEPLOYER" --build "$WORK" "$WORK" "$WORK/build" >/dev/null 2>&1

rm -rf "$OUT" && mkdir -p "$OUT/build"
for f in default.yaml vk_pinyin.schema.yaml vk_t9.schema.yaml vk.table.bin vk.reverse.bin vk.prism.bin vk_t9.prism.bin; do
    cp "$WORK/build/$f" "$OUT/build/"
done
# 九宫格左侧拼音：8105 字表全部音节，按字频合计降序
awk -F'\t' 'NF>=3 && $2 ~ /^[a-z]+$/ { w[$2] += $3 } END { for (s in w) print w[s] "\t" s }' "$WORK/cn_dicts/8105.dict.yaml" \
    | sort -k1,1nr -k2 | cut -f2 > "$OUT/syllables.txt"
echo "$STAMP" > "$OUT/VERSION"
du -sh "$OUT"
