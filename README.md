# Listen

Listen is the local-first voice surface for this Mac. A single native
`AVAudioEngine` owns the microphone and fans its tap out to four modes without
running competing recorders.

## Four modes

- **Dictation:** hold the configured key (Right Option by default), speak, and
  release. Listen transcribes, optionally cleans, and delivers text through the
  proven paste path. A new dictation always supersedes stale provider work.
- **Quick Thought:** hold **Left Command + Option**, speak, and release. Listen
  gives a short visible/spoken reflection in the migrated xAI custom voice and
  appends both sides to the notes ledger. Its compact, non-activating card can
  be dismissed with a trackpad swipe, click-drag swipe, or close button.
- **Wake word:** opt in from Preferences → Voice, then say the configured name.
  Apple streaming recognition handles wake and follow-up turns; recognition is
  rearmed before TTS so speech can interrupt the answer.
- **Conversation recording:** use the menubar or Preferences → Voice. Capture is
  unbounded and rolls AAC parts directly to disk. Stop produces diarized
  transcripts, chapter analyses, a mind map, actions/decisions, expandable
  source exchanges, and on-demand deep-analysis links.

The menubar title changes from **Listen** to a color-animated **listening** while
the microphone is active. It reserves that full width even while idle so the
app label does not disappear when macOS adds its separate privacy indicator.
On first launch it also anchors itself at the Control Center end of the bar,
where the system privacy module cannot push it beneath a MacBook notch; a later
Command-drag still sets and preserves the user's preferred position.
Preferences → Appearance provides live animated previews for Rainbow, Aurora,
Ocean, and Sunset, along with speed, intensity, and text-spacing controls.

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

## Build

The production app is native Swift and is built, bundled, and signed with the
stable local certificate requirement documented in [AGENTS.md](AGENTS.md):

```bash
cd ListenMac
./build.sh
```

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
writes, checks legacy config decoding, exercises wake-phrase and assistant-echo
boundaries, verifies reply continuity and local graph/RAG recovery across 1,200
notes, verifies rolling-file limits and week-scale frame progression,
simulates a 24-part long session, validates every report artifact, persists
on-demand analysis, rejects transcript HTML injection, and verifies the report
contains no remote asset URL.

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
