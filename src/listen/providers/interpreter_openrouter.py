"""OpenRouter interpreter / cleanup provider."""

from typing import Any, Optional

import requests

from .base import Interpreter

DEFAULT_PROMPT = (
    "Clean up the following voice transcription. "
    "Fix grammar, punctuation, and capitalization. "
    "Preserve the original meaning and tone. "
    "Do not add any introductory text or explanations. "
    "Only return the cleaned text:\\n\\n{text}"
)


class OpenRouterInterpreter(Interpreter):
    """OpenRouter API for text cleanup and interpretation."""

    name = "OpenRouter"
    BASE_URL = "https://openrouter.ai/api/v1/chat/completions"

    def __init__(
        self,
        api_key: str,
        model: str = "openai/gpt-4o-mini",
        prompt_template: str = DEFAULT_PROMPT,
        site_url: str = "",
        site_name: str = "Listen",
    ):
        self.api_key = api_key
        self.model = model
        self.prompt_template = prompt_template
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        })
        if site_url:
            self.session.headers["HTTP-Referer"] = site_url
        if site_name:
            self.session.headers["X-Title"] = site_name

    def interpret(self, text: str, instruction: Optional[str] = None) -> str:
        prompt = instruction or self.prompt_template
        prompt = prompt.format(text=text)
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": "You are a helpful text editor."},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.1,
            "max_tokens": 2048,
        }
        resp = self.session.post(
            self.BASE_URL,
            json=payload,
            timeout=30,
        )
        resp.raise_for_status()
        data = resp.json()
        return data["choices"][0]["message"]["content"].strip()

    @classmethod
    def from_config(cls, config: dict[str, Any]) -> "OpenRouterInterpreter":
        key = config.get("openrouter_api_key")
        if not key:
            raise ValueError("OpenRouter API key required")
        return cls(
            api_key=key,
            model=config.get("openrouter_model", "openai/gpt-4o-mini"),
            prompt_template=config.get("cleanup_prompt", DEFAULT_PROMPT),
            site_url=config.get("openrouter_site_url", ""),
            site_name=config.get("openrouter_site_name", "Listen"),
        )
