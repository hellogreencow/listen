# Listen — Goal

Listen becomes the one voice surface on this Mac: every way I talk to a
computer goes through it. It absorbs the good organs of voice-daemon
(`~/openclaw/extensions/oli-autonomous/voice-daemon.swift` — always-on audio
engine, streaming wake word, TTS speaker, direct LLM fast path) and retires
that daemon. Listen keeps its own hard-won shell: pinned-cert code signing,
the paste path that actually delivers, the settings UI, the provider system.

## One engine, four modes

A single always-on `AVAudioEngine` owns the mic. Every mode is just a
different consumer of the same tap:

1. **Dictation — hold Option.** Speak, release, clean text appears at the
   cursor. Already works; gets faster because the audio already exists in the
   ring buffer when the key goes down. This must never regress: it is the
   feature I use hundreds of times a day.

2. **Quick thought — hold Left Cmd + Option.** Speak a thought, get a short
   spoken/visible answer back, and both the thought and the answer land in
   the notes store automatically. Zero friction between having a thought and
   having it captured + reflected back.

3. **Wake word — say the name.** Instant conversational loop: streaming
   recognition, LLM fast path, spoken reply, barge-in. Opt-in toggle; when
   off, no persistent listening.

4. **Conversation recorder — menubar toggle.** Record entire conversations,
   any length — hours. Rolling m4a chunks to disk, no caps. On stop, a
   pipeline produces everything Plaud does and more:
   - diarized transcript (who said what)
   - deep, detailed chapter-by-chapter summaries
   - a mind map of the conversation
   - action items and decisions
   - expandable sections — click any part of the summary to drill into the
     full underlying exchange
   - on-demand deep analysis: pick any section (or the whole thing) and get
     word-level / metaphysical analysis of what was actually said, the
     language used, what it reveals
   Each session is a self-contained HTML report + audio + transcript under
   `~/.listen/sessions/`, mine forever, local first.

## Notetaker

Everything captured through modes 2–4 accumulates in one local store. Listen
is where spoken thoughts go to become searchable, reviewable notes — not an
app I have to open, a habit that happens because capture costs one keypress.

## Non-negotiables

- Dictation latency and reliability never regress in service of new modes.
- No new permission prompts beyond the one Speech Recognition grant the wake
  word requires (off by default). Everything in AGENTS.md still applies.
- If wake word and conversation mode are off, the persistent mic tap is off —
  no orange dot when nothing is listening.
- Audio, transcripts, and analyses live locally. Cloud providers process;
  they don't own.
- voice-daemon's gateway/openclaw coupling stays out of v1. Agent mode can
  return later behind a local socket, as an option, not a dependency.
