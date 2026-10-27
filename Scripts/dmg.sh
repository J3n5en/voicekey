#!/bin/bash
# 打包 DMG：VoiceKey.app + 指向「应用程序」的快捷方式，用户拖拽安装。用法：Scripts/dmg.sh <out.dmg> [VoiceKey.app] [icon.icns]
set -euo pipefail
trap 'echo "dmg.sh 失败：第 $LINENO 行，退出码 $?" >&2' ERR
cd "$(dirname "$0")/.."
OUT="$1"
APP="${2:-build/VoiceKey.app}"
ICNS="${3:-build/AppIcon.icns}"
STAGE=build/dmg
rm -rf "$STAGE" "$OUT" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/VoiceKey.app"
ln -s /Applications "$STAGE/Applications"
cp "$ICNS" "$STAGE/.VolumeIcon.icns"
# 窗口布局与背景（DS_Store 依赖卷名 VoiceKey 与 .background/background.png 路径）
mkdir "$STAGE/.background"
cp Scripts/dmg/background.png "$STAGE/.background/"
cp Scripts/dmg/DS_Store "$STAGE/.DS_Store"
TMP=build/tmp.dmg
rm -f "$TMP"
hdiutil create -quiet -volname VoiceKey -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$TMP"
MNT=$(hdiutil attach -nobrowse -noautoopen "$TMP" 2>/dev/null | awk -F'\t' '/Volumes/{print $NF}')
if [ -z "$MNT" ]; then
  echo "dmg.sh 失败：attach 后未取到挂载点" >&2
  exit 1
fi
SetFile -a C "$MNT"
# 卷可能被 Spotlight / Finder 短暂占用，卸载失败时重试，最后强制
if ! hdiutil detach -quiet "$MNT" 2>/dev/null; then
  for _ in 1 2 3 4 5; do
    sleep 2
    hdiutil detach -quiet "$MNT" 2>/dev/null && break
  done
  hdiutil detach -force "$MNT"
fi
hdiutil convert -quiet "$TMP" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -rf "$STAGE" "$TMP"
