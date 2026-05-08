"""ElevenLabs Speech-to-Text provider."""

from pathlib import Path
from typing import Any

import requests

from .base import STTProvider


class ElevenLabsSTT(STTProvider):
    """ElevenLabs Scribe STT API."""

    name = "ElevenLabs Scribe"
    BASE_URL = "https://api.elevenlabs.io/v1/speech-to-text"

    def __init__(self, api_key: str, model_id: str = "scribe_v1"):
        self.api_key = api_key
        self.model_id = model_id
        self.session = requests.Session()
        self.session.headers.update({"xi-api-key": api_key})

    def transcribe(self, audio_path: Path) -> str:
        data = {"model_id": self.model_id}
        with open(audio_path, "rb") as f:
            files = {"file": (audio_path.name, f, "audio/wav")}
            resp = self.session.post(
                self.BASE_URL,
                data=data,
                files=files,
                timeout=10,
            )
        resp.raise_for_status()
        result = resp.json()
        return result.get("text", "").strip()

    @classmethod
    def from_config(cls, config: dict[str, Any]) -> "ElevenLabsSTT":
        key = config.get("elevenlabs_api_key") or config.get("api_key")
        if not key:
            raise ValueError("ElevenLabs API key required")
        return cls(
            api_key=key,
            model_id=config.get("elevenlabs_model", "scribe_v1"),
        )
