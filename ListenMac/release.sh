#!/usr/bin/env bash
# Produce a Developer ID-signed, Apple-notarized, stapled drag-to-Applications
# disk image. This script deliberately has no self-signed or unnotarized mode.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Listen"
APP_PATH="$(pwd)/build/$APP_NAME.app"
RELEASE_DIR="$(pwd)/build/release"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
SIGNING_IDENTITY="${LISTEN_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${LISTEN_NOTARY_PROFILE:-${APPLE_NOTARY_PROFILE:-}}"
RELEASE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/listen-release.XXXXXX")"
MOUNT_POINT=""

cleanup() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  rm -rf "$RELEASE_TEMP"
}
trap cleanup EXIT

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$({ security find-identity -v -p codesigning 2>/dev/null || true; } \
    | sed -n 's/^.*"\(Developer ID Application: [^"]*\)".*$/\1/p')"
fi
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == *$'\n'* ]]; then
  echo "error: exactly one Developer ID Application identity is required." >&2
  echo "Install it in Keychain Access, or set LISTEN_SIGNING_IDENTITY." >&2
  exit 1
fi
if [[ "$SIGNING_IDENTITY" != "Developer ID Application: "* ]]; then
  echo "error: refusing to publish with a non-Developer-ID identity." >&2
  exit 1
fi

NOTARY_ARGS=()
if [[ -n "$NOTARY_PROFILE" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  NOTARY_ARGS=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
elif [[ -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
  NOTARY_ARGS=(--key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
else
  echo "error: notarization credentials are required." >&2
  echo "Set LISTEN_NOTARY_PROFILE, or the ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID variables." >&2
  exit 1
fi

notarize() {
  local artifact="$1"
  local label="$2"
  local result_plist="$RELEASE_TEMP/notary-$label.plist"
  local log_path="$RELEASE_DIR/notary-$label.json"
  local status
  local submission_id

  echo "→ Submitting $label to Apple notarization…"
  xcrun notarytool submit "${NOTARY_ARGS[@]}" "$artifact" \
    --wait --timeout 30m --output-format plist > "$result_plist"
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$result_plist")"
  submission_id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$result_plist")"
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "${NOTARY_ARGS[@]}" "$submission_id" "$log_path" || true
    echo "error: Apple notarization returned '$status'. See $log_path" >&2
    exit 1
  fi
  xcrun notarytool log "${NOTARY_ARGS[@]}" "$submission_id" "$log_path" >/dev/null
  if rg -q '"severity"[[:space:]]*:[[:space:]]*"(error|warning)"' "$log_path"; then
    echo "error: the accepted notarization contains warnings or errors. See $log_path" >&2
    exit 1
  fi
  echo "   ✓ Apple accepted $label"
}

echo "→ Running release gates…"
Tests/run-stress-tests.sh
git -C .. diff --check
plutil -lint Info.plist Release.entitlements

LISTEN_SIGNING_MODE=developer-id \
LISTEN_SIGNING_IDENTITY="$SIGNING_IDENTITY" \
./build.sh

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
xcrun lipo "$APP_PATH/Contents/MacOS/$APP_NAME" -verify_arch arm64 x86_64
codesign -dvvv "$APP_PATH" 2>&1 | rg 'Authority=Developer ID Application:' >/dev/null
codesign -dvvv "$APP_PATH" 2>&1 | rg 'flags=.*runtime' >/dev/null
codesign -d --entitlements - "$APP_PATH" 2>&1 \
  | rg 'com.apple.security.device.audio-input' >/dev/null
codesign -d --entitlements - "$APP_PATH" 2>&1 \
  | rg 'com.apple.security.automation.apple-events' >/dev/null

mkdir -p "$RELEASE_DIR"
APP_ZIP="$RELEASE_TEMP/$APP_NAME.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$APP_ZIP"
notarize "$APP_ZIP" app
xcrun stapler staple -v "$APP_PATH"
xcrun stapler validate -v "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

STAGING_DIR="$RELEASE_TEMP/dmg"
mkdir -p "$STAGING_DIR"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG_PATH"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
notarize "$DMG_PATH" dmg
xcrun stapler staple -v "$DMG_PATH"

echo "→ Verifying the install image…"
hdiutil verify "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
xcrun stapler validate -v "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

ATTACH_OUTPUT="$(hdiutil attach -nobrowse -readonly "$DMG_PATH")"
MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | sed -n $'s#^.*\\t\(/Volumes/.*\)$#\\1#p' | tail -n 1)"
if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT/$APP_NAME.app" || ! -L "$MOUNT_POINT/Applications" ]]; then
  echo "error: DMG does not contain Listen.app and the Applications shortcut." >&2
  exit 1
fi

INSTALLED_APP="$RELEASE_TEMP/installed/$APP_NAME.app"
mkdir -p "$(dirname "$INSTALLED_APP")"
/usr/bin/ditto "$MOUNT_POINT/$APP_NAME.app" "$INSTALLED_APP"
codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
spctl --assess --type execute --verbose=4 "$INSTALLED_APP"
xcrun stapler validate -v "$INSTALLED_APP"
hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

(
  cd "$RELEASE_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256"
)
echo ""
echo "✓ Trusted release ready: $DMG_PATH"
echo "✓ Checksum: $DMG_PATH.sha256"
