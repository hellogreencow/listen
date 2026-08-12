#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
OUTPUT_DIR="${TMPDIR:-/tmp}/listen-benchmark-tools"
RECEIVER="$OUTPUT_DIR/ListenBenchmarkReceiver.app"
mkdir -p "$RECEIVER/Contents/MacOS"

swiftc -O -swift-version 6 -warnings-as-errors \
  -framework AppKit BenchmarkReceiver.swift \
  -o "$RECEIVER/Contents/MacOS/ListenBenchmarkReceiver"

cp ReceiverInfo.plist "$RECEIVER/Contents/Info.plist"
codesign --force --sign - "$RECEIVER"

swiftc -O -swift-version 6 -warnings-as-errors \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics BenchmarkKeyDriver.swift \
  -o "$OUTPUT_DIR/listen-benchmark-key-driver"

printf '%s\n' "$RECEIVER" "$OUTPUT_DIR/listen-benchmark-key-driver"
