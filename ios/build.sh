#!/bin/bash
# 一条命令出真机包：ios/build.sh [设备 UDID]  → ios/build/VoiceKey.ipa，给了 UDID 则顺带安装
# 不签名包：ios/build.sh --unsigned  → ios/build/VoiceKey-unsigned.ipa（供自行重签，不安装）
set -euo pipefail
cd "$(dirname "$0")"
VoiceKeyCore/build-xcframework.sh
Pinyin/build-xcframework.sh
Pinyin/build-data.sh
xcodegen generate --quiet
if [ "${1:-}" = "--unsigned" ]; then
    U=build/unsigned
    rm -rf $U/VoiceKey.xcarchive $U/Payload build/VoiceKey-unsigned.ipa
    xcodebuild -project VoiceKeyIOS.xcodeproj -scheme VoiceKey -configuration Release \
        -destination generic/platform=iOS -derivedDataPath $U/DerivedData \
        -archivePath $U/VoiceKey.xcarchive -quiet archive \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
    mkdir -p $U/Payload
    cp -R $U/VoiceKey.xcarchive/Products/Applications/VoiceKey.app $U/Payload/
    # 不签名时 entitlements 不会写进二进制，AltStore / Sideloadly 等重签工具读不到 App Group，
    # 键盘与主 App 拿不到共享容器（client is not entitled），键盘每次点麦克风都会跳回主 App。
    # 这里用 ad-hoc 签名把 entitlements 写进去，供重签工具读取并注册 App Group（先签扩展再签主 App）
    codesign -f -s - --entitlements Keyboard/Keyboard.entitlements $U/Payload/VoiceKey.app/PlugIns/Keyboard.appex
    codesign -f -s - --entitlements App/App.entitlements $U/Payload/VoiceKey.app
    (cd $U && zip -qry ../VoiceKey-unsigned.ipa Payload)
    echo "ios/build/VoiceKey-unsigned.ipa"
    exit 0
fi
rm -rf build/VoiceKey.xcarchive build/export
xcodebuild -project VoiceKeyIOS.xcodeproj -scheme VoiceKey -configuration Release \
    -destination generic/platform=iOS -derivedDataPath DerivedData \
    -archivePath build/VoiceKey.xcarchive -allowProvisioningUpdates -quiet archive
xcodebuild -exportArchive -archivePath build/VoiceKey.xcarchive -exportPath build/export \
    -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates -quiet
mv -f build/export/VoiceKey.ipa build/VoiceKey.ipa
echo "ios/build/VoiceKey.ipa"
if [ -n "${1:-}" ]; then
    xcrun devicectl device install app --device "$1" build/VoiceKey.ipa
fi
