#!/usr/bin/env bash
# Build, bundle, and sign Listen.app with a stable self-signed identity so
# macOS TCC (Microphone, Input Monitoring, Accessibility) keeps your grants
# across rebuilds. Re-run as often as you like; permissions persist.

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Listen"
BUNDLE_ID="com.listen.app"
CERT_NAME="Listen Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BUILD_DIR="$(pwd)/build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"

# ─── 1. Self-signed code-signing cert (one-time) ────────────────────────────
if ! security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
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

# ─── 2. Compile ─────────────────────────────────────────────────────────────
echo "→ Compiling Swift sources…"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

SDK=$(xcrun --show-sdk-path --sdk macosx)
swiftc \
  -O \
  -swift-version 6 \
  -warnings-as-errors \
  -target arm64-apple-macos13.0 \
  -sdk "$SDK" \
  -framework AppKit \
  -framework AVFoundation \
  -framework Speech \
  -framework CoreAudio \
  -framework SwiftUI \
  -framework Carbon \
  -framework IOKit \
  -o "$APP_PATH/Contents/MacOS/$APP_NAME" \
  Sources/*.swift

# ─── 3. Bundle resources ────────────────────────────────────────────────────
cp Info.plist "$APP_PATH/Contents/Info.plist"
if [[ -f Resources/Listen.icns ]]; then
  cp Resources/Listen.icns "$APP_PATH/Contents/Resources/Listen.icns"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_PATH/Contents/Info.plist" >/dev/null

# ─── 4. Sign with stable identity + cdhash-independent requirement ──────────
# The designated requirement below makes macOS match this app by certificate
# subject CN, NOT by cdhash. So TCC grants (Accessibility, Microphone, etc.)
# survive every rebuild instead of being silently revoked.
REQ_FILE="$(mktemp)"
cat > "$REQ_FILE" <<EOF
designated => identifier "$BUNDLE_ID" and certificate leaf[subject.CN] = "$CERT_NAME"
EOF

echo "→ Signing with '$CERT_NAME' (cert-pinned designated requirement)…"
codesign --force --deep \
  --sign "$CERT_NAME" \
  --identifier "$BUNDLE_ID" \
  --requirements "$REQ_FILE" \
  --timestamp=none \
  "$APP_PATH"
rm -f "$REQ_FILE"

codesign --verify --verbose "$APP_PATH" 2>&1 | sed 's/^/   /'
codesign -d -r- "$APP_PATH" 2>&1 | grep "^designated" | sed 's/^/   DR: /'
echo ""
echo "✓ Built: $APP_PATH"
