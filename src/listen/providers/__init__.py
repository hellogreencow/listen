"""Pluggable providers for STT and text interpretation."""

from .base import Interpreter, STTProvider, registry
from .stt_openai import OpenAIWhisperSTT
from .stt_elevenlabs import ElevenLabsSTT
from .stt_local import LocalWhisperSTT
from .stt_openai_compatible import OpenAICompatibleSTT
from .stt_groq import GroqSTT
from .interpreter_openai import OpenAIInterpreter
from .interpreter_openrouter import OpenRouterInterpreter
from .interpreter_groq import GroqInterpreter

# Auto-register built-in providers
registry.register_stt("openai", OpenAIWhisperSTT)
registry.register_stt("elevenlabs", ElevenLabsSTT)
registry.register_stt("local", LocalWhisperSTT)
registry.register_stt("openai-compatible", OpenAICompatibleSTT)
registry.register_stt("groq", GroqSTT)
registry.register_interpreter("openai", OpenAIInterpreter)
registry.register_interpreter("openrouter", OpenRouterInterpreter)
registry.register_interpreter("groq", GroqInterpreter)

__all__ = [
    "registry",
    "STTProvider",
    "Interpreter",
    "OpenAIWhisperSTT",
    "ElevenLabsSTT",
    "LocalWhisperSTT",
    "OpenAICompatibleSTT",
    "GroqSTT",
    "OpenAIInterpreter",
    "OpenRouterInterpreter",
    "GroqInterpreter",
]
