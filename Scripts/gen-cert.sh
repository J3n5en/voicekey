#!/bin/bash
# 生成长期有效的自签名代码签名证书（只需生成一次并妥善保存）。
# 固定证书签名后 macOS 的辅助功能/麦克风授权在版本更新后不会丢失。
# 用法：Scripts/gen-cert.sh <输出目录>，输出 voicekey.p12 及 GitHub Secrets 所需的值。
set -euo pipefail
OUT="${1:?usage: gen-cert.sh <dir>}"
NAME="VoiceKey Self-Signed"
mkdir -p "$OUT" && cd "$OUT"
[[ -e voicekey.p12 ]] && { echo "voicekey.p12 已存在，拒绝覆盖" >&2; exit 1; }
PASS=$(openssl rand -hex 16)
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" -keyout key.pem -out cert.pem 2>/dev/null
# -legacy：macOS security import 不支持 OpenSSL 3 默认的 PKCS#12 加密算法
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "$NAME" -passout "pass:$PASS" -out voicekey.p12
rm key.pem
echo "$PASS" > voicekey.p12.password
chmod 600 voicekey.p12 voicekey.p12.password
cat <<EOF
已生成 $OUT/voicekey.p12（密码在 voicekey.p12.password），请备份，丢失后用户需重新授权一次。
GitHub Secrets：
  MACOS_CERTIFICATE           = \$(base64 -i $OUT/voicekey.p12)
  MACOS_CERTIFICATE_PASSWORD  = $PASS
EOF
