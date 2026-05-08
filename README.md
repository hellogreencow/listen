# Listen

> Hold a key. Speak. Clean AI-transcribed text appears at your cursor.

A fast, lightweight macOS voice-to-text app. No dock icon. Just a simple menubar item. Hold your hotkey, speak, release — text is transcribed and pasted where you're typing.

## How it works

1. **Hold** your hotkey (default: **Right Option**)
2. **Speak** — the menubar item shows "Recording"
3. **Release** — audio is transcribed by your STT engine, optionally cleaned up by an LLM
4. **Text appears** — pasted directly into the focused text field

End-to-end in **~700ms** with cloud STT, **~200ms** with local STT. RAM footprint: **~50MB**.

---

## Installation

### Pre-built

1. Download **Listen.app** from [Releases](../../releases)
2. Drag to **Applications**
3. Grant permissions on first launch:
   - **Microphone** — System Settings → Privacy & Security → Microphone
   - **Accessibility** — System Settings → Privacy & Security → Accessibility
4. *(Optional)* Add API keys for cloud providers — works out of the box with **local Whisper**

### Build from source

```bash
pip install -r requirements.txt
python3 setup.py py2app
# Drag dist/Listen.app to Applications
```

---

## Free vs Paid

Listen works **completely free** with on-device models. Cloud providers are optional for faster speed.

| Feature | Free (no API key) | Fast (BYOK) |
|---------|-------------------|-------------|
| **Local Whisper** (on-device) | ✅ | ✅ |
| **Groq Whisper** (free tier) | ✅ | ✅ |
| **ElevenLabs Scribe** | — | ✅ Fastest |
| **OpenAI Whisper** | — | ✅ |
| **OpenAI-Compatible** endpoints | — | ✅ |
| **LLM cleanup** | ✅ OpenRouter free / Groq free | ✅ Paid models |
| **Mode-aware formatting** | ✅ | ✅ |

---

## Providers

### Speech-to-Text

| Provider | Key | Cost | Speed | Quality |
|----------|-----|------|-------|---------|
| **Local Whisper** | `local` | Free | ~1-3s | Good |
| **Groq Whisper** | `groq` | Free tier | ~200ms | Excellent |
| **ElevenLabs Scribe** | `elevenlabs` | Paid | ~600ms | Best |
| **OpenAI Whisper** | `openai` | Paid | ~1s | Excellent |
| **OpenAI-Compatible** | `openai-compatible` | Varies | Varies | Varies |

### Cleanup / Interpretation

| Provider | Key | Cost | Speed |
|----------|-----|------|-------|
| **Groq** | `groq` | Free tier | ~100ms |
| **OpenRouter** | `openrouter` | Free + Paid | ~300ms |
| **OpenAI** | `openai` | Paid | ~500ms |

Switch providers from the menubar menu.

---

## Free Tier Setup

### Option 1: Local Whisper (100% offline)

```bash
pip install faster-whisper
```

Then switch STT provider to `local` in the menu. First run downloads the model (~150MB for `tiny`, ~500MB for `base`).

### Option 2: Groq (free cloud API)

1. Get a free API key at [console.groq.com/keys](https://console.groq.com/keys)
2. Paste it in **Preferences → Groq Key**
3. Switch STT to `groq` and Interpreter to `groq`

Groq uses LPU (Language Processing Unit) chips — inference is extremely fast.

### Option 3: OpenRouter free models

1. Get a free API key at [openrouter.ai/keys](https://openrouter.ai/keys)
2. Paste it in **Preferences → OpenRouter Key**
3. Select a free model like `google/gemini-flash-1.5:free`

---

## Configuration

Stored in `~/.listen/config.json`:

```json
{
  "stt_provider": "elevenlabs",
  "interpreter_provider": "openrouter",
  "openrouter_api_key": "sk-or-...",
  "elevenlabs_api_key": "sk_...",
  "openai_api_key": "sk-...",
  "groq_api_key": "gsk_...",
  "hotkey": "alt_r",
  "cleanup_enabled": true,
  "use_paste": true
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `hotkey` | `alt_r` | Key to hold. pynput key names. |
| `cleanup_enabled` | `true` | LLM fixes grammar, removes filler words |
| `use_paste` | `true` | `Cmd+V` paste. `false` = keystroke typing. |
| `stt_provider` | `elevenlabs` | `local`, `groq`, `elevenlabs`, `openai`, `openai-compatible` |
| `interpreter_provider` | `openrouter` | `groq`, `openrouter`, `openai` |

### Mode-aware cleanup

The app detects the frontmost application and adapts the cleanup prompt:

| App | Mode | What it does |
|-----|------|-------------|
| Mail, Outlook | `email` | Adds greeting, sign-off, formatting |
| Slack, Discord, Messages | `slack` | Short, casual, friendly |
| Cursor, Xcode, Terminal | `code` | Code comments, docstrings |
| Notes, Notion, Obsidian | `notes` | Bullet points, removes filler |
| Default | `default` | Clean grammar and punctuation |

---

## Architecture

```
Global Hotkey (pynput)
       │
       ▼
┌─────────────┐     ┌──────────┐     ┌────────────────┐
│  Menubar    │◄────│  Audio   │────►│  STT Provider  │
│  Status     │     │ Recorder │     │  (pluggable)   │
└─────────────┘     └──────────┘     └────────────────┘
                                              │
                                              ▼
                                    ┌────────────────────┐
                                    │  Interpreter       │
                                    │  (cleanup/interpret)│
                                    └────────────────────┘
                                              │
                                              ▼
                                    ┌────────────────────┐
                                    │  NSPasteboard      │
                                    │  Quartz CGEvent    │
                                    │  → focused field   │
                                    └────────────────────┘
```

- **Audio**: AVAudioRecorder via PyObjC, AAC/M4A format (~20x smaller than WAV)
- **Paste**: Direct NSPasteboard + Quartz CGEvent (no subprocess overhead)
- **Connection pre-warming**: HTTP connection warmed at startup for zero-latency first request

---

## File Structure

```
src/listen/
  app_native.py          # Main app (menubar + hotkey lifecycle)
  recorder.py            # AVAudioRecorder (native macOS AAC)
  hotkey.py              # Global hotkey listener
  typer.py               # NSPasteboard + Quartz paste
  sounds.py              # Audio feedback (optional)
  settings.py            # Config persistence
  providers/             # Pluggable STT + interpreter providers
    base.py
    stt_elevenlabs.py
    stt_groq.py
    stt_local.py
    stt_openai.py
    stt_openai_compatible.py
    interpreter_openrouter.py
    interpreter_groq.py
    interpreter_openai.py
```

---

## License

MIT
