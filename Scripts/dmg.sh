#!/bin/bash
# 打包 DMG：VoiceKey.app + 指向「应用程序」的快捷方式，用户拖拽安装。用法：Scripts/dmg.sh <out.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"
STAGE=build/dmg
rm -rf "$STAGE" "$OUT" && mkdir -p "$STAGE"
cp -R build/VoiceKey.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp build/AppIcon.icns "$STAGE/.VolumeIcon.icns"
# 窗口布局与背景（DS_Store 依赖卷名 VoiceKey 与 .background/background.png 路径）
mkdir "$STAGE/.background"
cp Scripts/dmg/background.png "$STAGE/.background/"
cp Scripts/dmg/DS_Store "$STAGE/.DS_Store"
TMP=build/tmp.dmg
rm -f "$TMP"
hdiutil create -quiet -volname VoiceKey -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$TMP"
MNT=$(hdiutil attach -nobrowse -noautoopen "$TMP" 2>/dev/null | awk -F'\t' '/Volumes/{print $NF}')
SetFile -a C "$MNT"
hdiutil detach -quiet "$MNT"
hdiutil convert -quiet "$TMP" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -rf "$STAGE" "$TMP"
