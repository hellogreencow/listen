# 🎙️ Listen

![Build](https://img.shields.io/badge/build-passing-brightgreen)
![License](https://img.shields.io/badge/license-MIT-blue)
![Python](https://img.shields.io/badge/python-3.9%2B-blue)

> Hold a key. Speak. AI-transcribed text appears at your cursor.

**Listen** is a fast, lightweight macOS voice-to-text app that stays out of your way. No dock icon. No menubar clutter. Just a tiny floating pill in the corner and a hold-to-record workflow that feels like magic.

<!-- SCREENSHOT: A 120×32px translucent floating pill in the top-right corner of a macOS desktop, showing "Recording" in warm yellow while active. Replace this comment with an actual screenshot. -->

---

## ✨ How it works

1. **Hold** your hotkey (default: **Right Option**)
2. **Speak** — a translucent pill HUD appears while recording
3. **Release** — audio is transcribed by your chosen STT engine, optionally cleaned up by an LLM
4. **Text appears** — pasted directly into the focused text field via native Quartz events

End-to-end in **~650ms** with cloud STT, **~200ms** with local STT. RAM footprint: **~50MB**.

---

## 🚀 Installation

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

## 🆓 Free vs Paid

| Feature | Free (no API key) | Fast (BYOK) |
|---------|-------------------|-------------|
| **Local Whisper** (on-device) | ✅ | ✅ |
| **Groq Whisper** (free tier) | ✅ | ✅ |
| **ElevenLabs Scribe** | — | ✅ |
| **OpenAI Whisper** | — | ✅ |
| **OpenAI-Compatible** endpoints | — | ✅ |
| **LLM cleanup / interpretation** | ✅ Free models via OpenRouter | ✅ Paid models via OpenRouter, OpenAI, Groq |
| **Mode-aware formatting** (email, code, slack, etc.) | ✅ | ✅ |

---

## 📊 Provider Comparison

### Speech-to-Text

| Provider | Speed | Cost | Quality | Setup |
|----------|-------|------|---------|-------|
| **Local Whisper** (`faster-whisper`) | ⚡ ~200ms | Free | Good | None — runs on-device |
| **Groq Whisper** | ⚡⚡ ~300ms | Free tier available | Excellent | OpenAI-Compatible endpoint |
| **ElevenLabs Scribe** | ⚡ ~400ms | Paid | 🏆 Best-in-class | ElevenLabs API key |
| **OpenAI Whisper** | ~600ms | $0.006/min | Excellent | OpenAI API key |
| **OpenAI-Compatible** | Varies | Varies | Varies | Any compatible endpoint (Groq, OpenRouter, etc.) |

### Cleanup / Interpreter

| Provider | Speed | Cost | Best For |
|----------|-------|------|----------|
| **OpenRouter** | Fast | Free tiers available (gemini-flash:free, mistral-7b:free) | Flexibility — 100+ models |
| **Groq** | ⚡⚡ Fastest | Free tier available | Speed — Mixtral, Llama 3 on LPUs |
| **OpenAI** | Fast | $0.15–$5/M tokens | Quality — GPT-4o-mini, GPT-4o |

> 💡 **Pro tip:** Use *Local Whisper* + *OpenRouter free tier* for a completely free, zero-API-key setup.

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         macOS                                │
│  ┌─────────────┐   ┌──────────┐   ┌─────────────────────┐  │
│  │ Global      │   │ Floating │   │ AVAudioRecorder     │  │
│  │ Hotkey      │──►│ Pill HUD │   │ (AAC/M4A, native)   │  │
│  │ (PyObjC)    │   │ (top-right│   └──────────┬──────────┘  │
│  └─────────────┘   └──────────┘              │             │
│         │                                     │             │
│         └─────────────────────────────────────┘             │
│                        Audio file                           │
│                              │                              │
│                              ▼                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Pluggable STT Provider                  │   │
│  │  ┌──────────┐ ┌──────────┐ ┌────────┐ ┌──────────┐ │   │
│  │  │ OpenAI   │ │ ElevenLabs│ │ Local  │ │ OpenAI-  │ │   │
│  │  │ Whisper  │ │ Scribe    │ │Whisper │ │Compatible│ │   │
│  │  └──────────┘ └──────────┘ └────────┘ └──────────┘ │   │
│  └────────────────────────┬────────────────────────────┘   │
│                           │ Raw text                        │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Interpreter (optional)                  │   │
│  │  ┌──────────┐ ┌──────────┐ ┌────────┐              │   │
│  │  │ OpenRouter│ │ OpenAI   │ │ Groq*  │              │   │
│  │  │ (100+ models)│ GPT   │ │ (via    │              │   │
│  │  └──────────┘ └──────────┘ │ compat)│              │   │
│  └────────────────────────┬────────────────────────────┘   │
│                           │ Cleaned text                    │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  NSPasteboard + Quartz CGEvent (Cmd+V)              │   │
│  │  → Paste into focused text field, restore clipboard │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘

*Groq available via OpenAI-Compatible endpoint configuration
```

---

## 🛠️ Configuration

Settings are stored in `~/.listen/config.json` and editable via **Right-click → Preferences** on the floating pill.

```json
{
  "stt_provider": "elevenlabs",
  "interpreter_provider": "openrouter",
  "hotkey": "alt_r",
  "cleanup_enabled": true,
  "use_paste": true,
  "sound_enabled": false,
  "overlay_enabled": true
}
```

### Mode-aware cleanup

Listen detects the frontmost app and adapts its cleanup prompt automatically:

| App | Mode | Behavior |
|-----|------|----------|
| Mail, Outlook, Gmail | `email` | Professional greeting + sign-off |
| Slack, Discord, Messages | `slack` | Short, casual, friendly |
| Cursor, Xcode, Terminal | `code` | Code comments / docstrings |
| Notes, Notion, Obsidian | `notes` | Bullet-point formatting |
| Everything else | `default` | Clean grammar + punctuation |

Cycle modes manually via **Right-click → Mode**.

---

## 💡 Why Listen?

| | Listen | Superwhisper | Wispr Flow |
|---|---|---|---|
| **Price** | Free / BYOK | **$8.49/mo** | **$15/mo** |
| **Local STT** | ✅ Free | ✅ | ❌ |
| **Cloud STT choice** | ✅ 4+ providers | ✅ OpenAI only | ✅ Proprietary |
| **RAM** | **~50MB** | ~300MB | ~200MB |
| **Dock / Menubar** | ❌ None | ✅ Menubar | ✅ Menubar |
| **Open Source** | ✅ MIT | ❌ | ❌ |
| **macOS Native** | ✅ PyObjC + AVFoundation | ✅ | ✅ |

Listen is built for people who want **speed, privacy, and control** without a subscription. Use it completely free with local Whisper, or bring your own API keys and pay only for what you use.

---

## 📁 Project Structure

```
src/listen/
├── app_native.py          # Main app — floating pill, lifecycle, processing loop
├── recorder.py            # AVAudioRecorder wrapper (AAC/M4A, native macOS)
├── hotkey.py              # Global hotkey listener (PyObjC / pynput)
├── typer.py               # Clipboard + Quartz CGEvent paste injection
├── sounds.py              # Audio feedback on record/stop/error
├── settings.py            # Config persistence (~/.listen/config.json)
└── providers/
    ├── base.py            # Provider registry + abstract base classes
    ├── stt_openai.py      # OpenAI Whisper
    ├── stt_elevenlabs.py  # ElevenLabs Scribe
    ├── stt_local.py       # faster-whisper (on-device)
    ├── stt_openai_compatible.py  # Generic OpenAI-compatible (Groq, etc.)
    ├── interpreter_openai.py     # GPT-4o-mini cleanup
    └── interpreter_openrouter.py # 100+ models via OpenRouter
```

---

## 🔑 Permissions

Listen requires two macOS permissions to function:

- **Microphone** — to record your voice
- **Accessibility** — to register global hotkeys and paste text into other apps

Go to **System Settings → Privacy & Security** to enable both after first launch.

---

## 📝 License

MIT © [Oli](https://github.com/olivernn)
