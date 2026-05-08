"""Base classes and registry for pluggable providers."""

from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any, Optional


class STTProvider(ABC):
    """Speech-to-text provider."""

    name: str = ""

    @abstractmethod
    def transcribe(self, audio_path: Path) -> str:
        """Transcribe audio file to text."""
        ...

    @classmethod
    @abstractmethod
    def from_config(cls, config: dict[str, Any]) -> "STTProvider":
        """Create instance from configuration dict."""
        ...


class Interpreter(ABC):
    """Text interpretation / cleanup provider."""

    name: str = ""

    @abstractmethod
    def interpret(self, text: str, instruction: Optional[str] = None) -> str:
        """Interpret or clean up transcribed text."""
        ...

    @classmethod
    @abstractmethod
    def from_config(cls, config: dict[str, Any]) -> "Interpreter":
        """Create instance from configuration dict."""
        ...


class ProviderRegistry:
    """Registry for STT and Interpreter providers."""

    def __init__(self):
        self._stt: dict[str, type[STTProvider]] = {}
        self._interpreters: dict[str, type[Interpreter]] = {}

    def register_stt(self, key: str, cls: type[STTProvider]) -> None:
        self._stt[key] = cls

    def register_interpreter(self, key: str, cls: type[Interpreter]) -> None:
        self._interpreters[key] = cls

    def list_stt(self) -> list[str]:
        return list(self._stt.keys())

    def list_interpreters(self) -> list[str]:
        return list(self._interpreters.keys())

    def get_stt(self, key: str, config: dict[str, Any]) -> STTProvider:
        if key not in self._stt:
            raise KeyError(f"Unknown STT provider '{key}'. Available: {self.list_stt()}")
        return self._stt[key].from_config(config)

    def get_interpreter(self, key: str, config: dict[str, Any]) -> Interpreter:
        if key not in self._interpreters:
            raise KeyError(
                f"Unknown interpreter '{key}'. Available: {self.list_interpreters()}"
            )
        return self._interpreters[key].from_config(config)


registry = ProviderRegistry()
