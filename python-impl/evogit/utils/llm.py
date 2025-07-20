"""
Utility functions for the controlling LLM models.
"""

from litellm import completion, batch_completion
from typing import Optional
import logging


class LLMBackend:
    """Currently, it's only a single wrapper for litellm."""

    def __init__(
        self,
        model_name: str,
        system_prompt: Optional[str] = None,
        params: Optional[dict] = None,
        num_retries: int = 3,
    ):
        self.model_name = model_name
        self.system_prompt = system_prompt
        self.params = params if params else {}
        self.num_retries = num_retries

    def completion(self, _seed: int, query: str):
        if self.system_prompt:
            messages = [
                {"role": "system", "content": self.system_prompt},
                {"role": "user", "content": query},
            ]
        else:
            messages = [{"role": "user", "content": query}]

        response = completion(
            model=self.model_name,
            messages=messages,
            num_retries=self.num_retries,
            **self.params,
        )
        content = response.choices[0].message.content
        return content

    def batch_completion(self, _seeds: list[int], queries: list[str]):
        if self.system_prompt:
            messages = [
                [
                    {"role": "system", "content": self.system_prompt},
                    {"role": "user", "content": query},
                ]
                for query in queries
            ]
        else:
            messages = [[{"role": "user", "content": query}] for query in queries]

        responses = batch_completion(
            model=self.model_name,
            messages=messages,
            num_retries=self.num_retries,
            **self.params,
        )
        return [response.choices[0].message.content for response in responses]
