#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
SDK=$(xcrun --show-sdk-path --sdk macosx)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ARM_OUT="$TMP/listen-stress-arm64"
INTEL_OUT="$TMP/listen-stress-x86_64"
SOURCES=(
  ListenMac/Sources/Diagnostics.swift \
  ListenMac/Sources/AudioEngine.swift \
  ListenMac/Sources/SpeechEchoGate.swift \
  ListenMac/Sources/XAITTS.swift \
  ListenMac/Sources/Memory.swift \
  ListenMac/Sources/WakeWord.swift \
  ListenMac/Sources/Hotkey.swift \
  ListenMac/Sources/Providers.swift \
  ListenMac/Sources/StatusAppearance.swift \
  ListenMac/Sources/Settings.swift \
  ListenMac/Sources/HermesAnalysis.swift \
  ListenMac/Sources/Conversation.swift \
  ListenMac/Tests/StressHarness.swift
)

compile_stress() {
  local arch="$1"
  local output="$2"
  swiftc -O -swift-version 6 -warnings-as-errors -target "$arch-apple-macos13.0" -sdk "$SDK" \
    -framework AppKit -framework AVFoundation -framework Speech -framework CoreAudio -framework Carbon \
    "${SOURCES[@]}" \
    -o "$output"
}

echo "→ Compiling arm64 stress harness…"
compile_stress arm64 "$ARM_OUT"
echo "→ Compiling x86_64 stress harness…"
compile_stress x86_64 "$INTEL_OUT"
xcrun lipo "$ARM_OUT" -verify_arch arm64
xcrun lipo "$INTEL_OUT" -verify_arch x86_64

case "$(uname -m)" in
  arm64)
    echo "→ Running native arm64 stress harness…"
    LISTEN_LOG_PATH="$TMP/listen-stress-arm64.log" "$ARM_OUT"
    if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
      echo "→ Running Intel stress harness under Rosetta…"
      arch -x86_64 env LISTEN_LOG_PATH="$TMP/listen-stress-x86_64.log" "$INTEL_OUT"
    else
      echo "ℹ Rosetta is unavailable; x86_64 compile and architecture checks passed."
    fi
    ;;
  x86_64)
    echo "→ Running native x86_64 stress harness…"
    LISTEN_LOG_PATH="$TMP/listen-stress-x86_64.log" "$INTEL_OUT"
    ;;
  *)
    echo "Unsupported build host architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
