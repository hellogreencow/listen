"""Local Whisper STT provider using faster-whisper."""

from pathlib import Path
from typing import Any

from .base import STTProvider


class LocalWhisperSTT(STTProvider):
    """Local Whisper via faster-whisper (CTranslate2).

    Requires: pip install faster-whisper
    First run downloads the model (~150MB for tiny, ~500MB for base).
    """

    name = "Local Whisper"

    def __init__(self, model_size: str = "base", device: str = "auto", compute_type: str = "int8"):
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self._model = None

    def _load(self):
        if self._model is None:
            try:
                from faster_whisper import WhisperModel
            except ImportError:
                raise ImportError(
                    "Local STT requires 'faster-whisper'. Run: pip install faster-whisper"
                )
            print(f"[stt:local] loading model '{self.model_size}'...")
            self._model = WhisperModel(
                self.model_size,
                device=self.device,
                compute_type=self.compute_type,
            )
        return self._model

    def transcribe(self, audio_path: Path) -> str:
        model = self._load()
        segments, info = model.transcribe(str(audio_path), beam_size=5)
        text = "".join(s.text for s in segments).strip()
        print(f"[stt:local] detected language: {info.language} (prob {info.language_probability:.2f})")
        return text

    @classmethod
    def from_config(cls, config: dict[str, Any]) -> "LocalWhisperSTT":
        return cls(
            model_size=config.get("local_whisper_model", "base"),
            device=config.get("local_whisper_device", "auto"),
            compute_type=config.get("local_whisper_compute", "int8"),
        )
