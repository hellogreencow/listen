"""OpenAI Whisper STT provider."""

from pathlib import Path
from typing import Any

from openai import OpenAI

from .base import STTProvider


class OpenAIWhisperSTT(STTProvider):
    """OpenAI Whisper API."""

    name = "OpenAI Whisper"

    def __init__(self, api_key: str, model: str = "whisper-1"):
        self.client = OpenAI(api_key=api_key)
        self.model = model

    def transcribe(self, audio_path: Path) -> str:
        with open(audio_path, "rb") as f:
            result = self.client.audio.transcriptions.create(
                model=self.model,
                file=f,
            )
        return result.text.strip()

    @classmethod
    def from_config(cls, config: dict[str, Any]) -> "OpenAIWhisperSTT":
        key = config.get("openai_api_key") or config.get("api_key")
        if not key:
            raise ValueError("OpenAI API key required")
        return cls(api_key=key, model=config.get("openai_whisper_model", "whisper-1"))
