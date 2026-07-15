#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
SDK=$(xcrun --show-sdk-path --sdk macosx)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/listen-stress"
swiftc -O -swift-version 6 -warnings-as-errors -target arm64-apple-macos13.0 -sdk "$SDK" \
  -framework AppKit -framework AVFoundation -framework Speech -framework CoreAudio -framework Carbon \
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
  ListenMac/Tests/StressHarness.swift \
  -o "$OUT"
LISTEN_LOG_PATH="$TMP/listen-stress.log" "$OUT"
