"""Groq STT provider — Whisper via Groq's LPU inference.

Free tier available. Extremely fast.
Docs: https://console.groq.com/docs/speech-text
"""

from pathlib import Path
from typing import Any

import requests

from .base import STTProvider


class GroqSTT(STTProvider):
    """Groq Whisper STT API."""

    name = "Groq Whisper"
    BASE_URL = "https://api.groq.com/openai/v1/audio/transcriptions"

    def __init__(self, api_key: str, model: str = "whisper-large-v3"):
        self.api_key = api_key
        self.model = model
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {api_key}",
        })

    def transcribe(self, audio_path: Path) -> str:
        with open(audio_path, "rb") as f:
            files = {"file": (audio_path.name, f, "audio/m4a")}
            data = {"model": self.model}
            resp = self.session.post(
                self.BASE_URL,
                files=files,
                data=data,
                timeout=15,
            )
        resp.raise_for_status()
        result = resp.json()
        return result.get("text", "").strip()

    @classmethod
    def from_config(cls, config: dict[str, Any]) -> "GroqSTT":
        key = config.get("groq_api_key")
        if not key:
            raise ValueError("Groq API key required. Get one free at https://console.groq.com/keys")
        return cls(
            api_key=key,
            model=config.get("groq_stt_model", "whisper-large-v3"),
        )
