"""
Utility functions for the controlling LLM models.
"""

from litellm import completion
from typing import Optional
import time
import logging


class LLMBackend:
    """Currently, it's only a single wrapper for litellm."""

    def __init__(
        self,
        model_name: str,
        system_prompt: Optional[str] = None,
        params: Optional[dict] = None,
        num_retries: int = 10,
    ):
        self.model_name = model_name
        self.system_prompt = system_prompt
        self.params = params if params else {}
        self.num_retries = num_retries
        self.initial_sleep = 20
        self.sleep_duration = self.initial_sleep
        self.logger = logging.getLogger("evogit")

    def completion(self, _seed: int, query: str):
        self.logger.info(f"LLM completion for query: {query}")
        if self.system_prompt:
            messages = [
                {"role": "system", "content": self.system_prompt},
                {"role": "user", "content": query},
            ]
        else:
            messages = [{"role": "user", "content": query}]

        for _ in range(self.num_retries):
            try:
                response = completion(
                    model=self.model_name,
                    messages=messages,
                    **self.params,
                )
                content = response.choices[0].message.content
                self.sleep_duration = self.initial_sleep  # Reset sleep duration after success
                self.logger.info(f"LLM response: {content}")
                return content
            except Exception as e:
                self.logger.error(f"LLM completion failed: {e}")
                time.sleep(self.sleep_duration)
                self.sleep_duration += self.sleep_duration // 2 # *= 1.5

    def batch_completion(self, seeds: list[int], queries: list[str]):
        # litellm has built-in support for batch completions
        # however, it doesn't handle rate limits well, so we handle it through retries in the completion method
        responses = []
        for seed, query in zip(seeds, queries):
            response = self.completion(seed, query)
            responses.append(response)

        return responses
