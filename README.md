# Listen

Listen is the local-first voice surface for this Mac. A single native
`AVAudioEngine` owns the microphone and fans its tap out to four modes without
running competing recorders.

## Four modes

- **Dictation:** hold the configured key (Right Option by default), speak, and
  release. Listen transcribes, optionally cleans, and delivers text through the
  proven paste path. A new dictation always supersedes stale provider work;
  hold capture hard-stops at 180 seconds if macOS loses the key-release event.
- **Quick Thought:** hold **Left Command + Option**, speak, and release. Listen
  gives a short visible/spoken reflection in the migrated xAI custom voice and
  appends both sides to the notes ledger. Its compact, non-activating card can
  be dismissed with a trackpad swipe, click-drag swipe, or close button. This
  hold capture has the same 180-second safety cap as Dictation.
- **Wake word:** opt in from Preferences → Voice, then say the configured name.
  Apple streaming recognition handles wake and follow-up turns; recognition is
  rearmed before TTS so speech can interrupt the answer.
- **Conversation recording:** use the menubar or Preferences → Voice. Rolling
  conversation capture is unbounded and writes AAC parts directly to disk;
  unlike the two hold modes, it has no 180-second cap. Stop produces diarized
  transcripts, chapter analyses, a mind map, actions/decisions, expandable
  source exchanges, and on-demand deep-analysis links.

The menubar title changes from **Listen** to a color-animated **listening** while
the microphone is active. It reserves that full width even while idle so the
app label does not disappear when macOS adds its separate privacy indicator.
On first launch it also anchors itself at the Control Center end of the bar,
where the system privacy module cannot push it beneath a MacBook notch; a later
Command-drag still sets and preserves the user's preferred position.
Preferences → Appearance provides live animated previews for Rainbow, Aurora,
Ocean, and Sunset, along with speed, intensity, idle text-size, and spacing
controls.

## Local data

Listen owns its artifacts:

```text
~/.listen/
├── config.json              # provider settings and keys (mode 0600)
├── notes/
│   ├── notes.jsonl          # append-only searchable voice notes
│   └── knowledge-graph.json # derived local concepts and relationships
└── sessions/<session-id>/
    ├── audio/audio-0001.m4a # rolling original audio parts
    ├── transcript.json      # timestamps and provider speaker labels
    ├── transcript.txt       # readable exchange
    ├── report.json          # durable report model + deep analyses
    ├── report.html          # self-contained, no remote assets
    └── manifest.json        # recording/processing completion state
```

The root, notes, and session directories are owner-only. Cloud providers may
process a request, but no remote library is authoritative. ElevenLabs Scribe
provides word-level speaker labels when configured. For rolled multi-part
sessions, speaker numbering is explicitly scoped to each part because Listen
does not pretend anonymous labels from separate API calls are the same person.

Quick Thought and wake replies retrieve recent conversational turns plus the
highest-scoring related notes before generating an answer. Concept extraction,
the bounded relationship graph, query expansion, and ranking all happen
locally; only the selected context snippets accompany the assistant request.
The graph is derived and can be rebuilt from the canonical JSONL ledger.

## Permissions

Listen does not add a new blanket permission surface:

- **Microphone** records audio.
- **Accessibility** observes the hold shortcut.
- **Automation → System Events** is the existing paste delivery path.
- **Speech Recognition** is requested only when wake word is explicitly
  enabled (Apple on-device dictation can also require it if selected as STT).

When wake word and conversation recording are off and no hold capture is in
flight, the engine releases the microphone after a two-second anti-churn grace
period. No always-on daemon is required.

## Reliability guarantees

Dictation remains the priority path. Every hold capture receives a unique
microphone lease, so rapidly pressing the hotkey again cannot be interrupted by
an older recording that is still finalizing. Each STT attempt has a 30-second
deadline and cleanup has a 10-second deadline. Cleanup failure or timeout pastes
the raw transcript rather than losing the dictation. Provider work is
session-scoped; superseded work cannot paste text or overwrite the menubar state.

The shared engine keeps at most 30 seconds of pre-roll in a fixed circular
buffer. Once full, new tap buffers overwrite the oldest samples without shifting
the whole allocation. Input-route sample-rate changes roll long recordings to a
new AAC part and resample short recordings into their existing file format.

Wake authorization and recognition tasks carry lifecycle generations. Turning
wake word off invalidates pending permission callbacks, prevents stale callbacks
from reopening the microphone, and defers recognition rotation while a spoken
turn is in progress. Quick Thought separately tracks the physical Left Command
bit, so holding or releasing Right Command cannot leave the chord armed.

Local persistence is acknowledged only after `notes.jsonl` has been written,
synchronized, and closed. Conversation report mutations reload and merge under
a per-process lock so simultaneous section analyses do not erase one another.
Quitting during a conversation delays AppKit termination until the active AAC
writer and manifest are finalized; unfinished report processing resumes on the
next launch and then appears in the native Conversations library.

## Providers

Transcription supports Apple on-device SpeechTranscriber (macOS 26+),
ElevenLabs Scribe, OpenAI Whisper, and Groq Whisper. The direct assistant path
supports OpenRouter, OpenAI, and Groq. Dictation cleanup is independently
optional; Quick Thought, wake replies, reports, and deep analysis can still use
the selected assistant when cleanup is off.

Configuration is field-by-field backward compatible with the original
`~/.listen/config.json`, so adding settings never discards existing keys.
Spoken replies use xAI TTS voice `o79hvd0m`, matching the retired voice daemon;
interruptible system speech remains the automatic offline/error fallback.

Conversation reports can optionally use Hermes for deeper analysis. Listen
invokes the documented `hermes --oneshot` CLI with an empty toolset; it does not
import Hermes's private Python packages or assume a checkout under `~/.hermes`.
Prompts above 64 KiB are never placed in process arguments: they require the
versioned `listen-hermes-adapter-v1` executable (or
`LISTEN_HERMES_ADAPTER_V1`). The adapter receives the prompt asynchronously on
stdin and returns only the analysis on stdout, so cancellation and the
four-minute deadline remain effective even if an adapter stops reading.

## Build

The production app is native Swift and is built, bundled, and signed with the
stable local certificate requirement documented in [AGENTS.md](AGENTS.md).
Release gates intentionally run against the candidate bundle before it can
replace the installed application:

```bash
ListenMac/build.sh
ListenMac/Tests/run-stress-tests.sh
git diff --check
plutil -lint ListenMac/Info.plist
codesign --verify --deep --strict ListenMac/build/Listen.app
codesign -d -r- ListenMac/build/Listen.app 2>&1 \
  | rg -F 'certificate leaf[subject.CN] = "Listen Local Signing"'

# Exercise the signed candidate and prove its microphone lease tears down.
osascript -e 'tell application "Listen" to quit' 2>/dev/null || true
before=$(wc -c < /tmp/listen.err.log 2>/dev/null || echo 0)
open ListenMac/build/Listen.app
sleep 1
open -a ListenMac/build/Listen.app -u 'https://listen.local/test/microphone'
sleep 8
runtime_log=$(tail -c "+$((before + 1))" /tmp/listen.err.log)
printf '%s\n' "$runtime_log" | rg 'mic opened'
printf '%s\n' "$runtime_log" | rg 'mic closed'
osascript -e 'tell application "Listen" to quit'

/usr/bin/ditto ListenMac/build/Listen.app /Applications/Listen.app
open /Applications/Listen.app
```

The first launch requests only the permissions required by enabled features.
Wake word stays off by default, so Speech Recognition and persistent microphone
use are not activated merely by installing the app.

The build uses Swift 6 with warnings as errors and preserves this designated
requirement across rebuilds:

```text
identifier "com.listen.app" and
certificate leaf[subject.CN] = "Listen Local Signing"
```

Do not replace this with ad-hoc signing or hardened runtime without a proper
Developer ID/notarization plan; either can break the existing TCC grants or
event delivery.

## Verification

The isolated stress suite never reads personal keys or notes and does not touch
the real microphone:

```bash
ListenMac/Tests/run-stress-tests.sh
```

It compiles under the production concurrency settings, hammers queued AAC
writes and route-rate changes, checks legacy config decoding, exercises
wake-phrase, side-specific hotkey, multilingual token-spacing, and
assistant-echo boundaries, verifies durable note-error propagation plus local
graph/RAG recovery across 1,200 notes, verifies circular pre-roll and week-scale
rolling progression, simulates a 24-part long session, races concurrent report
analyses, validates every report artifact, rejects transcript HTML injection,
and verifies the report contains no remote asset URL.

For a release, the complete order is build → isolated stress/whitespace/plist/
signature gates → signed-candidate microphone teardown → installation → launch.
Do not move `ditto` or the final launch ahead of those checks.

Runtime state transitions are written privately to `/tmp/listen.err.log`; paste
delivery diagnostics remain in `/tmp/listen-paste.log`.

## Architecture

```text
NSEvent hold monitors ─┐
Apple wake streaming ──┼──> AudioEngine (one AVAudioEngine + one input tap)
Conversation toggle ───┘        │ ring + fast fan-out
                                ├── short AAC writer → STT → cleanup/paste
                                ├── Quick Thought → direct LLM → TTS + notes
                                ├── wake turns → direct LLM → interruptible TTS
                                └── rolling AAC → transcript/report pipeline
```

The former OpenClaw `voice-daemon` gateway/identity/action stack is not a Listen
dependency. Agent behavior can return later through an explicit local socket;
it is intentionally outside v1.
