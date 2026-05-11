"""Persistent config stored in ~/.listen/config.json"""

import json
from pathlib import Path

APP_DIR = Path.home() / ".listen"
APP_DIR.mkdir(exist_ok=True)
CONFIG_PATH = APP_DIR / "config.json"

DEFAULTS = {
    "openai_api_key": "",
    "elevenlabs_api_key": "",
    "openrouter_api_key": "",
    "openai_compatible_api_key": "",
    "groq_api_key": "",
    "stt_provider": "elevenlabs",
    "interpreter_provider": "openrouter",
    "hotkey": "ctrl_r",
    "cleanup_enabled": True,
    "use_paste": True,
    "sound_enabled": False,
    "overlay_enabled": True,
    "cleanup_prompt": (
        "Clean up the following voice transcription. "
        "Fix grammar, punctuation, and capitalization. "
        "Preserve the original meaning and tone. "
        "Do not add any introductory text or explanations. "
        "Only return the cleaned text:\n\n{text}"
    ),
    "openai_whisper_model": "whisper-1",
    "openai_cleanup_model": "gpt-4o-mini",
    "elevenlabs_model": "scribe_v1",
    "openrouter_model": "google/gemini-flash-1.5",
    "openrouter_site_url": "",
    "openrouter_site_name": "Listen",
    "openai_compatible_base_url": "",
    "openai_compatible_model": "whisper-1",
    "local_whisper_model": "base",
    "local_whisper_device": "auto",
    "local_whisper_compute": "int8",
    "groq_stt_model": "whisper-large-v3",
    "groq_model": "llama-3.1-8b-instant",
}


def load() -> dict:
    if CONFIG_PATH.exists():
        try:
            with open(CONFIG_PATH) as f:
                return {**DEFAULTS, **json.load(f)}
        except Exception:
            pass
    return dict(DEFAULTS)


def save(config: dict) -> None:
    with open(CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=2)
