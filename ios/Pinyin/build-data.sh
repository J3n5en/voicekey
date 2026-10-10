#!/bin/bash
# 雾凇拼音全套词库 + 补充词（流行新词、人工智能）→ 全拼/九宫格方案，用与 librime 同版本的 rime_deployer 在 Mac 上预编译
set -euo pipefail
cd "$(dirname "$0")"
source versions.env
CACHE=$PWD/.cache
OUT=Sources/Pinyin/RimeData
STAMP="librime $LIBRIME_VERSION ($LIBRIME_COMMIT) rime-ice $RIME_ICE_TAG $(cat rime/* | shasum -a 256 | cut -c1-16)"
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
# 九宫格纠错方案：vk_t9 加上按错相邻键的拼写，残缺音节 ko 同样降权；只用来给九宫格补几个纠错候选（PinyinSession）
sed -e 's/^  schema_id: vk_t9$/  schema_id: vk_t9c/' -e 's/^  prism: vk_t9$/  prism: vk_t9c/' \
    -e 's|^    - derive/(\[dtngkhrzcs\])o(u\|ng)\$/\$1o/$|    - fuzz/([dtngkhrzcs])o(u\|ng)$/$1oQ/|' \
    -e '/^    - derive\/\[wxyz\]\/9\/$/r rime/vk_t9c.rules' rime/vk_t9.schema.yaml > "$WORK/vk_t9c.schema.yaml"
unzip -q -o "$CACHE/rime-ice-$RIME_ICE_TAG.zip" \
  cn_dicts/8105.dict.yaml cn_dicts/base.dict.yaml cn_dicts/ext.dict.yaml \
  cn_dicts/tencent.dict.yaml cn_dicts/others.dict.yaml -d "$WORK"
# 只补雾凇没有的词，权重对齐雾凇里手调热词（破防、社死为 9999）
{
  printf '%s\n' '---' 'name: extra' 'version: "2026.10.09"' 'sort: by_weight' '...' ''
  awk -F'\t' '
    FILENAME ~ /cn_dicts\// { if (index($0, "\t") && $0 !~ /^#/) have[$1] = 1; next }
    NF >= 2 && $0 !~ /^#/ && !($1 in have) { have[$1] = 1; print $1 "\t" $2 "\t9999" }
  ' "$WORK"/cn_dicts/*.dict.yaml rime/*.txt
} > "$WORK/extra.dict.yaml"
DYLD_LIBRARY_PATH=$(dirname "$DEPLOYER")/../lib "$DEPLOYER" --build "$WORK" "$WORK" "$WORK/build" >/dev/null 2>&1

rm -rf "$OUT" && mkdir -p "$OUT/build"
for f in default.yaml vk_pinyin.schema.yaml vk_t9.schema.yaml vk_t9c.schema.yaml vk.table.bin vk.reverse.bin vk.prism.bin vk_t9.prism.bin vk_t9c.prism.bin; do
    cp "$WORK/build/$f" "$OUT/build/"
done
# 九宫格左侧拼音：8105 字表全部音节，按字频合计降序
awk -F'\t' 'NF>=3 && $2 ~ /^[a-z]+$/ { w[$2] += $3 } END { for (s in w) print w[s] "\t" s }' "$WORK/cn_dicts/8105.dict.yaml" \
    | sort -k1,1nr -k2 | cut -f2 > "$OUT/syllables.txt"
echo "$STAMP" > "$OUT/VERSION"
du -sh "$OUT"
