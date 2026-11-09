#!/bin/bash
# Archive → Developer ID export → notarize → zip → Sparkle signature.
# CI (.github/workflows/release.yml) and the local rehearsal run this same script.
#
# Required: VERSION (1.2.3), OUT (output folder), P12_PASSWORD, ASC_KEY_ID, ASC_ISSUER_ID,
#           P12_PATH or P12_BASE64, ASC_KEY_PATH or ASC_KEY_P8, SPARKLE_ACCOUNT or SPARKLE_PRIVATE_KEY
# Optional: SKIP_NOTARIZE=1 for a quick local signing-only pass
# Writes:   $OUT/$APP_NAME-$VERSION.zip and $OUT/build.env
set -euo pipefail
umask 077
cd "$(git rev-parse --show-toplevel)"
source scripts/release.env

fail() { echo "error: $*" >&2; exit 1; }
: "${VERSION:?}" "${OUT:?}" "${P12_PASSWORD:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}"
# No leading zeros: v01.2.3 and v1.2.3 would get the same build number.
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "VERSION must look like 1.2.3: $VERSION"
MAJOR=${BASH_REMATCH[1]} MINOR=${BASH_REMATCH[2]} PATCH=${BASH_REMATCH[3]}
(( MINOR < 100 && PATCH < 100 )) || fail "minor and patch must be below 100"
# Sparkle compares CFBundleVersion, so it must grow with every version.
BUILD_NUMBER=$((MAJOR * 10000 + MINOR * 100 + PATCH))

WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release.XXXXXX")
KEYCHAIN="$WORK/signing.keychain-db"
ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do ORIGINAL_KEYCHAINS+=("$keychain"); done \
  < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/')
(( ${#ORIGINAL_KEYCHAINS[@]} )) || fail "the keychain search list is empty"
cleanup() {
  local status=$?
  # Each step runs even if another fails: the work folder holds the p12 and the API key.
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" \
    || echo "warning: restore the keychain search list by hand: ${ORIGINAL_KEYCHAINS[*]}" >&2
  security delete-keychain "$KEYCHAIN" 2> /dev/null || true
  rm -rf "$WORK" || echo "warning: delete $WORK by hand; it holds signing keys" >&2
  exit "$status"
}
trap cleanup EXIT

if [[ -n "${P12_PATH:-}" ]]; then cp "$P12_PATH" "$WORK/cert.p12"
else printf '%s' "${P12_BASE64:?set P12_PATH or P12_BASE64}" | base64 --decode > "$WORK/cert.p12"; fi
if [[ -n "${ASC_KEY_PATH:-}" ]]; then cp "$ASC_KEY_PATH" "$WORK/AuthKey.p8"
else printf '%s\n' "${ASC_KEY_P8:?set ASC_KEY_PATH or ASC_KEY_P8}" > "$WORK/AuthKey.p8"; fi

KEYCHAIN_PASSWORD=$(openssl rand -hex 32)
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security > /dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" > /dev/null
security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "Developer ID Application:" | grep -qF "($TEAM_ID)" \
  || fail "the p12 has no Developer ID Application identity for team $TEAM_ID"

DD="$WORK/dd"
echo "Archiving $APP_NAME $VERSION ($BUILD_NUMBER)…"
xcodebuild archive -quiet -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$WORK/$APP_NAME.xcarchive" -derivedDataPath "$DD" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN"

# Export re-signs Sparkle's XPC services and helpers correctly; never sign them with --deep.
cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -quiet -archivePath "$WORK/$APP_NAME.xcarchive" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$WORK/export"
APP="$WORK/export/$APP_NAME.app"
codesign --verify --deep --strict "$APP"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" && "$(plist CFBundleVersion)" == "$BUILD_NUMBER" ]] \
  || fail "the exported app has the wrong version"
PUBLIC_KEY=$(plist SUPublicEDKey) || fail "SUPublicEDKey is missing from Info.plist"
plist SUFeedURL > /dev/null || fail "SUFeedURL is missing from Info.plist"

if [[ "${SKIP_NOTARIZE:-}" != 1 ]]; then
  echo "Notarizing…"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/notarize.zip"
  NOTARY=(--key "$WORK/AuthKey.p8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  xcrun notarytool submit "$WORK/notarize.zip" "${NOTARY[@]}" --wait --timeout 30m \
    --output-format json > "$WORK/notary.json" || { cat "$WORK/notary.json" >&2; fail "notarization submit failed"; }
  STATUS=$(plutil -extract status raw "$WORK/notary.json")
  if [[ "$STATUS" != Accepted ]]; then
    xcrun notarytool log "$(plutil -extract id raw "$WORK/notary.json")" "${NOTARY[@]}" >&2 || true
    fail "notarization: $STATUS"
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

mkdir -p "$OUT"
ZIP_NAME="${APP_NAME// /-}-$VERSION.zip"   # GitHub rewrites spaces in asset names anyway
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP_NAME"
SIGN_UPDATE="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  SPARKLE_ATTRS=$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$OUT/$ZIP_NAME")
else
  SPARKLE_ATTRS=$("$SIGN_UPDATE" --account "${SPARKLE_ACCOUNT:?set SPARKLE_ACCOUNT or SPARKLE_PRIVATE_KEY}" "$OUT/$ZIP_NAME")
fi
# Check against the key inside the app, so a mismatched secret fails here instead of on users' Macs.
SIGNATURE=$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' <<< "$SPARKLE_ATTRS")
swift scripts/verify-update.swift "$PUBLIC_KEY" "$SIGNATURE" "$OUT/$ZIP_NAME"

{
  printf 'VERSION=%q\n' "$VERSION"
  printf 'BUILD_NUMBER=%q\n' "$BUILD_NUMBER"
  printf 'MIN_SYSTEM=%q\n' "$(plist LSMinimumSystemVersion)"
  printf 'ZIP_NAME=%q\n' "$ZIP_NAME"
  printf 'SPARKLE_ATTRS=%q\n' "$SPARKLE_ATTRS"
} > "$OUT/build.env"
echo "Built $OUT/$ZIP_NAME"
