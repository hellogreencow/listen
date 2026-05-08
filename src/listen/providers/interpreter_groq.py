"""Groq interpreter / cleanup provider.

Free tier available. Extremely fast LLM inference.
Docs: https://console.groq.com/docs/openai
"""

from typing import Any, Optional

import requests

from .base import Interpreter

DEFAULT_PROMPT = (
    "Clean up the following voice transcription. "
    "Fix grammar, punctuation, and capitalization. "
    "Remove filler words like 'um', 'uh', 'like'. "
    "Preserve the original meaning and tone. "
    "Do not add any introductory text or explanations. "
    "Only return the cleaned text:\n\n{text}"
)


class GroqInterpreter(Interpreter):
    """Groq API for text cleanup."""

    name = "Groq"
    BASE_URL = "https://api.groq.com/openai/v1/chat/completions"

    def __init__(
        self,
        api_key: str,
        model: str = "llama-3.1-8b-instant",
        prompt_template: str = DEFAULT_PROMPT,
    ):
        self.api_key = api_key
        self.model = model
        self.prompt_template = prompt_template
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        })

    def interpret(self, text: str, instruction: Optional[str] = None) -> str:
        prompt = instruction or self.prompt_template
        prompt = prompt.format(text=text)
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": "You are a helpful text editor. Be concise."},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.1,
            "max_tokens": 2048,
        }
        resp = self.session.post(
            self.BASE_URL,
            json=payload,
            timeout=15,
        )
        resp.raise_for_status()
        data = resp.json()
        return data["choices"][0]["message"]["content"].strip()

    @classmethod
    def from_config(cls, config: dict[str, Any]) -> "GroqInterpreter":
        key = config.get("groq_api_key")
        if not key:
            raise ValueError("Groq API key required. Get one free at https://console.groq.com/keys")
        return cls(
            api_key=key,
            model=config.get("groq_model", "llama-3.1-8b-instant"),
            prompt_template=config.get("cleanup_prompt", DEFAULT_PROMPT),
        )
