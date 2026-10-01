#!/bin/bash
# 构建 VoiceKey.app（用固定证书签名，重建后辅助功能/麦克风授权不丢）
set -euo pipefail
cd "$(dirname "$0")"

xcrun swift build -c release
APP=build/VoiceKey.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/VoiceKey "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>do.j3.voicekey</string>
    <key>CFBundleName</key><string>VoiceKey</string>
    <key>CFBundleExecutable</key><string>VoiceKey</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>长按快捷键时录音并发送到所选渠道识别。</string>
</dict>
</plist>
EOF
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "built $APP (signed: ${IDENTITY:-adhoc})"
