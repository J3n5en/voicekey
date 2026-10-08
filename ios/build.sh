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
