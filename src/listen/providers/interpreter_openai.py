"""OpenAI GPT interpreter / cleanup provider."""

from typing import Any, Optional

from openai import OpenAI

from .base import Interpreter


DEFAULT_PROMPT = (
    "Clean up the following voice transcription. "
    "Fix grammar, punctuation, and capitalization. "
    "Preserve the original meaning and tone. "
    "Do not add any introductory text or explanations. "
    "Only return the cleaned text:\n\n{text}"
)


class OpenAIInterpreter(Interpreter):
    """OpenAI GPT-based text cleanup and interpretation."""

    name = "OpenAI GPT"

    def __init__(
        self,
        api_key: str,
        model: str = "gpt-4o-mini",
        prompt_template: str = DEFAULT_PROMPT,
    ):
        self.client = OpenAI(api_key=api_key)
        self.model = model
        self.prompt_template = prompt_template

    def interpret(self, text: str, instruction: Optional[str] = None) -> str:
        prompt = instruction or self.prompt_template
        prompt = prompt.format(text=text)
        response = self.client.chat.completions.create(
            model=self.model,
            messages=[
                {"role": "system", "content": "You are a helpful text editor."},
                {"role": "user", "content": prompt},
            ],
            temperature=0.2,
        )
        return response.choices[0].message.content.strip()

    @classmethod
    def from_config(cls, config: dict[str, Any]) -> "OpenAIInterpreter":
        key = config.get("openai_api_key") or config.get("api_key")
        if not key:
            raise ValueError("OpenAI API key required")
        return cls(
            api_key=key,
            model=config.get("openai_cleanup_model", "gpt-4o-mini"),
            prompt_template=config.get("cleanup_prompt", DEFAULT_PROMPT),
        )
