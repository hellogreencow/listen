# Real dictation benchmark

This suite measures the user-visible interval from hotkey release until text
appears in a focused native text field. It therefore includes recording
finalization, upload, transcription, optional cleanup, clipboard work, and
paste delivery.

The corpus contains fixed macOS Samantha speech at 185 words per minute:

- `short`: 2.24 seconds
- `medium`: 10.15 seconds
- `technical`: 14.83 seconds

Run `build-benchmark-tools.sh` to build the receiver app and key driver. Play
the same generated corpus through the built-in speaker into the built-in
microphone for every product. Run one uncounted warm-up and five counted trials
per product and clip. The driver refuses to proceed unless the receiver owns
focus, uses a unique clipboard sentinel, and records both clipboard and visible
paste timestamps. Analyze the captured JSONL with `analyze.py`.

Acoustic testing deliberately exercises each product's complete microphone
path. It is reproducible on one Mac, but environmental acoustics and provider
network variance mean results from different Macs should not be combined.
