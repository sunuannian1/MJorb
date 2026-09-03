#!/usr/bin/env bash
# 构建后签名脚本：用指定 P12 + 描述文件签名 Seal.app（含 SealTunnel 扩展）
# 用法: bash Scripts/sign-ipa.sh <unsigned.ipa> <p12> <main.mobileprovision> <output.ipa> [extension.mobileprovision]
set -euo pipefail

UNSIGNED_IPA="${1:?usage: sign-ipa.sh unsigned.ipa p12 main.mobileprovision output.ipa [ext.mobileprovision]}"
P12="${2:?p12 required}"
MOBILEPROVISION="${3:?main mobileprovision required}"
OUTPUT_IPA="${4:?output required}"
EXT_MOBILEPROVISION="${5:-}"

# 转绝对路径（脚本内会 cd 到临时目录，相对路径会失效）
UNSIGNED_IPA="$(cd "$(dirname "$UNSIGNED_IPA")" && pwd)/$(basename "$UNSIGNED_IPA")"
P12="$(cd "$(dirname "$P12")" && pwd)/$(basename "$P12")"
MOBILEPROVISION="$(cd "$(dirname "$MOBILEPROVISION")" && pwd)/$(basename "$MOBILEPROVISION")"
OUTPUT_IPA="$(cd "$(dirname "$OUTPUT_IPA")" && pwd)/$(basename "$OUTPUT_IPA")"
[ -n "$EXT_MOBILEPROVISION" ] && EXT_MOBILEPROVISION="$(cd "$(dirname "$EXT_MOBILEPROVISION")" && pwd)/$(basename "$EXT_MOBILEPROVISION")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

extract_plist() {
  local in="$1" out="$2"
  security cms -D -i "$in" > "$out" 2>/dev/null || python3 -c "
data = open('$in','rb').read()
s = data.find(b'<?xml'); e = data.find(b'</plist>')+len(b'</plist>')
open('$out','wb').write(data[s:e])
"
}

# 1. 解压未签名 IPA
echo "[sign] extracting unsigned IPA..."
mkdir -p "$WORK/extracted"
(cd "$WORK/extracted" && unzip -q "$UNSIGNED_IPA")
APP="$WORK/extracted/Payload/Seal.app"
test -d "$APP" || { echo "error: Seal.app not found"; exit 1; }

# 2. 解析主描述文件
echo "[sign] parsing main provisioning profile..."
MAIN_PLIST="$WORK/main.plist"
extract_plist "$MOBILEPROVISION" "$MAIN_PLIST"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$MAIN_PLIST" | cut -d. -f2-)
TEAM_ID=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$MAIN_PLIST")
EXT_BUNDLE_ID="${BUNDLE_ID}.TunnelProv"
echo "[sign] main bundle=$BUNDLE_ID ext bundle=$EXT_BUNDLE_ID team=$TEAM_ID"

# 3. 提取主 app entitlements
MAIN_ENT="$WORK/main-entitlements.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$MAIN_PLIST" > "$MAIN_ENT"

# 4. 修改主 app bundle ID
echo "[sign] setting main CFBundleIdentifier=$BUNDLE_ID..."
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
cp "$MOBILEPROVISION" "$APP/embedded.mobileprovision"

# 5. 处理 SealTunnel 扩展
EXT_APP="$APP/PlugIns/SealTunnel.appex"
if [ -d "$EXT_APP" ]; then
  echo "[sign] found SealTunnel extension"
  if [ -z "$EXT_MOBILEPROVISION" ]; then
    echo "error: SealTunnel extension found but no extension provisioning profile provided."
    echo "       Pass extension profile as 5th argument. Bundle ID must be $EXT_BUNDLE_ID"
    exit 1
  fi
  EXT_PLIST="$WORK/ext.plist"
  extract_plist "$EXT_MOBILEPROVISION" "$EXT_PLIST"
  EXT_PROFILE_BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$EXT_PLIST" | cut -d. -f2-)
  if [ "$EXT_PROFILE_BUNDLE" != "$EXT_BUNDLE_ID" ]; then
    echo "error: extension profile bundle ID mismatch: profile=$EXT_PROFILE_BUNDLE expected=$EXT_BUNDLE_ID"
    exit 1
  fi
  EXT_ENT="$WORK/ext-entitlements.plist"
  /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$EXT_PLIST" > "$EXT_ENT"
  echo "[sign] setting ext CFBundleIdentifier=$EXT_BUNDLE_ID..."
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $EXT_BUNDLE_ID" "$EXT_APP/Info.plist"
  cp "$EXT_MOBILEPROVISION" "$EXT_APP/embedded.mobileprovision"
else
  echo "[sign] no SealTunnel extension found, skipping"
fi

# 6. 创建临时钥匙串并导入证书
KEYCHAIN="$WORK/sign.keychain-db"
KEYCHAIN_PASS="seal-temp-$$"
echo "[sign] creating temporary keychain..."
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" "$(security list-keychains -d user | tr -d '"' | head -1)"

echo "[sign] importing P12 (no password)..."
security import "$P12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign 2>&1 || true

if ! security find-certificate -c "Apple Worldwide Developer Relations Certification Authority" "$KEYCHAIN" >/dev/null 2>&1; then
  curl -fsSL https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$WORK/wwdr.cer" 2>/dev/null && \
    security import "$WORK/wwdr.cer" -k "$KEYCHAIN" 2>&1 || true
fi

SIGN_IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | grep -o '"[^"]*"' | head -1 | tr -d '"')
echo "[sign] signing identity: $SIGN_IDENTITY"
test -n "$SIGN_IDENTITY" || { echo "error: no codesigning identity found"; exit 1; }

# 7. 签名顺序：框架 → 扩展 → 主 app
echo "[sign] signing frameworks..."
find "$APP/Frameworks" -name "*.framework" -type d 2>/dev/null | while read -r fw; do
  echo "  framework: $(basename "$fw")"
  codesign --force --sign "$SIGN_IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$fw"
done

if [ -d "$EXT_APP" ]; then
  echo "[sign] signing SealTunnel extension..."
  codesign --force --sign "$SIGN_IDENTITY" --keychain "$KEYCHAIN" \
    --entitlements "$EXT_ENT" --timestamp=none "$EXT_APP"
fi

echo "[sign] signing Seal.app..."
codesign --force --sign "$SIGN_IDENTITY" --keychain "$KEYCHAIN" \
  --entitlements "$MAIN_ENT" --timestamp=none "$APP"

# 8. 验证
echo "[sign] verifying..."
codesign --verify --deep --strict "$APP"
if [ -d "$EXT_APP" ]; then
  codesign --verify --deep --strict "$EXT_APP"
fi

# 9. 打包
echo "[sign] packaging $OUTPUT_IPA..."
rm -f "$OUTPUT_IPA"
(cd "$WORK/extracted" && zip -qry "$OUTPUT_IPA" Payload)
shasum -a 256 "$OUTPUT_IPA" > "$OUTPUT_IPA.sha256"
echo "[sign] done: $OUTPUT_IPA"
