"""Generic OpenAI-compatible STT provider.

Works with OpenRouter, Groq, or any service exposing an OpenAI-style
audio transcriptions endpoint.
"""

from pathlib import Path
from typing import Any

from openai import OpenAI

from .base import STTProvider


class OpenAICompatibleSTT(STTProvider):
    """OpenAI-compatible STT via configurable base URL."""

    name = "OpenAI-Compatible"

    def __init__(self, api_key: str, base_url: str, model: str):
        self.client = OpenAI(api_key=api_key, base_url=base_url)
        self.model = model

    def transcribe(self, audio_path: Path) -> str:
        with open(audio_path, "rb") as f:
            result = self.client.audio.transcriptions.create(
                model=self.model,
                file=f,
            )
        return result.text.strip()

    @classmethod
    def from_config(cls, config: dict[str, Any]) -> "OpenAICompatibleSTT":
        key = config.get("openai_compatible_api_key") or config.get("api_key")
        base = config.get("openai_compatible_base_url")
        model = config.get("openai_compatible_model", "whisper-1")
        if not key:
            raise ValueError("API key required")
        if not base:
            raise ValueError("Base URL required (e.g. https://api.openrouter.ai/v1)")
        return cls(api_key=key, base_url=base, model=model)
