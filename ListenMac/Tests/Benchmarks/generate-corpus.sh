#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-/tmp/listen-benchmark-corpus}"
mkdir -p "$OUT"
say -v Samantha -r 185 -o "$OUT/short.aiff" \
  'Send the revised launch plan before lunch.'
say -v Samantha -r 185 -o "$OUT/medium.aiff" \
  'Listen turns speech into text wherever you type. Hold the right option key, speak naturally, and release. Your words appear automatically without changing apps or breaking your focus.'
say -v Samantha -r 185 -o "$OUT/technical.aiff" \
  'The deployment uses a notarized universal binary, a stable bundle identifier, and explicit microphone permissions. Please compare release to paste latency, word error rate, memory use, and cold start behavior across five repeated trials.'
afinfo "$OUT/short.aiff" "$OUT/medium.aiff" "$OUT/technical.aiff" \
  | awk '/estimated duration/ { print }'
