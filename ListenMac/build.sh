#!/usr/bin/env bash
# Build and bundle Listen.app. Local builds use the stable self-signed identity
# so TCC grants survive rebuilds. Public releases select Developer ID signing.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Listen"
BUNDLE_ID="com.listen.app"
CERT_NAME="Listen Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BUILD_DIR="$(pwd)/build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
SIGNING_MODE="${LISTEN_SIGNING_MODE:-local}"
SIGNING_IDENTITY="${LISTEN_SIGNING_IDENTITY:-}"
ENTITLEMENTS_PATH="${LISTEN_ENTITLEMENTS_PATH:-$(pwd)/Release.entitlements}"

# ─── 1. Self-signed code-signing cert (one-time) ────────────────────────────
if [[ "$SIGNING_MODE" == "local" ]] && ! security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "→ Creating self-signed cert '$CERT_NAME'…"
  TMP=$(mktemp -d)
  cat > "$TMP/cfg.cnf" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3
[dn]
CN = $CERT_NAME
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/k.pem" -out "$TMP/c.pem" -config "$TMP/cfg.cnf" 2>/dev/null
  # -legacy makes the PKCS12 readable by macOS Security framework
  openssl pkcs12 -export -legacy -inkey "$TMP/k.pem" -in "$TMP/c.pem" \
    -name "$CERT_NAME" -out "$TMP/c.p12" -passout pass:listen 2>/dev/null \
    || openssl pkcs12 -export -inkey "$TMP/k.pem" -in "$TMP/c.pem" \
       -name "$CERT_NAME" -out "$TMP/c.p12" -passout pass:listen \
       -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
  security import "$TMP/c.p12" -k "$KEYCHAIN" -P listen \
    -T /usr/bin/codesign -A
  # Make codesign allowed to use the key without prompting.
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  echo "  ✓ cert installed in login keychain"
fi

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "error: release entitlements not found: $ENTITLEMENTS_PATH" >&2
    exit 1
  fi
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$({ security find-identity -v -p codesigning 2>/dev/null || true; } \
      | sed -n 's/^.*"\(Developer ID Application: [^"]*\)".*$/\1/p')"
  fi
  if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == *$'\n'* ]]; then
    echo "error: exactly one Developer ID Application identity is required." >&2
    echo "Set LISTEN_SIGNING_IDENTITY when more than one identity is installed." >&2
    exit 1
  fi
  if [[ "$SIGNING_IDENTITY" != "Developer ID Application: "* ]]; then
    echo "error: public releases must use a Developer ID Application identity." >&2
    exit 1
  fi
elif [[ "$SIGNING_MODE" == "local" ]]; then
  SIGNING_IDENTITY="$CERT_NAME"
else
  echo "error: LISTEN_SIGNING_MODE must be 'local' or 'developer-id'." >&2
  exit 1
fi

# ─── 2. Compile ─────────────────────────────────────────────────────────────
echo "→ Compiling Universal 2 Swift sources…"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

SDK=$(xcrun --show-sdk-path --sdk macosx)
SLICE_DIR="$BUILD_DIR/slices"
mkdir -p "$SLICE_DIR"

for ARCH in arm64 x86_64; do
  echo "   • $ARCH"
  swiftc \
    -O \
    -swift-version 6 \
    -warnings-as-errors \
    -target "$ARCH-apple-macos13.0" \
    -sdk "$SDK" \
    -framework AppKit \
    -framework AVFoundation \
    -framework Speech \
    -framework CoreAudio \
    -framework SwiftUI \
    -framework Carbon \
    -framework IOKit \
    -o "$SLICE_DIR/$APP_NAME-$ARCH" \
    Sources/*.swift
done

xcrun lipo -create \
  "$SLICE_DIR/$APP_NAME-arm64" \
  "$SLICE_DIR/$APP_NAME-x86_64" \
  -output "$APP_PATH/Contents/MacOS/$APP_NAME"
xcrun lipo "$APP_PATH/Contents/MacOS/$APP_NAME" -verify_arch arm64 x86_64
echo "   ✓ $(xcrun lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME")"
rm -rf "$SLICE_DIR"

# ─── 3. Bundle resources ────────────────────────────────────────────────────
cp Info.plist "$APP_PATH/Contents/Info.plist"
ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' Info.plist)"
if [[ ! -f "Resources/$ICON_FILE" ]]; then
  echo "error: app icon not found: Resources/$ICON_FILE" >&2
  exit 1
fi
cp "Resources/$ICON_FILE" "$APP_PATH/Contents/Resources/$ICON_FILE"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_PATH/Contents/Info.plist" >/dev/null

# ─── 4. Sign with stable identity + cdhash-independent requirement ──────────
# Developer ID releases use Apple's standard team-and-identifier requirement,
# hardened runtime, a secure timestamp, and only the resource entitlements the
# app needs. Local builds keep the cert-pinned requirement that preserves TCC.
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  echo "→ Signing for distribution with '$SIGNING_IDENTITY'…"
  codesign --force \
    --sign "$SIGNING_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_PATH"
else
  REQ_FILE="$(mktemp)"
  cat > "$REQ_FILE" <<EOF
designated => identifier "$BUNDLE_ID" and certificate leaf[subject.CN] = "$CERT_NAME"
EOF

  echo "→ Signing with '$SIGNING_IDENTITY' (cert-pinned designated requirement)…"
  codesign --force \
    --sign "$SIGNING_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --requirements "$REQ_FILE" \
    --timestamp=none \
    "$APP_PATH"
  rm -f "$REQ_FILE"
fi

codesign --verify --deep --strict --verbose "$APP_PATH" 2>&1 | sed 's/^/   /'
codesign -d -r- "$APP_PATH" 2>&1 | grep "^designated" | sed 's/^/   DR: /'
echo ""
echo "✓ Built: $APP_PATH"
