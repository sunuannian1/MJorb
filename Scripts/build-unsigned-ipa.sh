#!/usr/bin/env bash
set -euo pipefail

configuration="${SEAL_IPA_CONFIGURATION:-Release}"
derived_data="$PWD/build/DerivedData"
product="$derived_data/Build/Products/${configuration}-iphoneos/Seal.app"
package_root="$PWD/build/package"
archive="$PWD/build/Seal.ipa"

if [[ "${SEAL_SKIP_XCODEGEN:-0}" != "1" ]]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is required to regenerate Seal.xcodeproj from project.yml" >&2
    exit 1
  fi
  xcodegen generate
fi

rm -rf "$derived_data" "$package_root" "$archive" "$archive.sha256"

xcodebuild build \
  -project Seal.xcodeproj \
  -scheme Seal \
  -configuration "$configuration" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=''

test -d "$product"
mkdir -p "$package_root/Payload"
ditto "$product" "$package_root/Payload/Seal.app"
(cd "$package_root" && /usr/bin/zip -qry "$archive" Payload)
shasum -a 256 "$archive" > "$archive.sha256"
