"""This module defines the Process class used in EvoGit."""

import time
from google import genai
from .agent import LLMRequest

completed_states = set(
    [
        "JOB_STATE_SUCCEEDED",
        "JOB_STATE_FAILED",
        "JOB_STATE_CANCELLED",
        "JOB_STATE_EXPIRED",
    ]
)

good_states = set(
    [
        "JOB_STATE_SUCCEEDED",
    ]
)


class Executor:
    """An executor executes agents steps.
    It drives the agents forward, sending LLM requests for them in batches and performing the actions returned.
    """

    def __init__(self):
        self.client = genai.Client()
        self.poll_interval = 30  # seconds
        self.model = "gemini-2.5-flash"

    def _to_request_params(self, llm_request: LLMRequest):
        """Convert an LLMRequest to genai request parameters."""
        return {
            "config": llm_request.config,
            "contents": [{"role": "user", "parts": [{"text": llm_request.content}]}],
        }

    def _batch_request(self, requests):
        """Sends a batch of LLM requests and returns the responses."""
        batch_job = self.client.batch_generate_content(
            [self._to_request_params(req) for req in requests]
        )
        job_name = batch_job.name
        while True:
            job = self.client.batches.get(name=job_name)
            if job.status.name in completed_states:
                break
            time.sleep(self.poll_interval)

        if job.status.name not in good_states:
            raise Exception(f"Batch job failed with status: {job.status.name}")

        responses = []
        for i, inline_response in enumerate(job.dest.inlined_responses, start=1):
            # Check for a successful response
            if inline_response.response:
                # The .text property is a shortcut to the generated text.
                responses.append(inline_response.response.text)
            else:
                # Handle error case
                error_message = (
                    inline_response.error.message
                    if inline_response.error
                    else "Unknown error"
                )
                raise Exception(f"Request {i} failed with error: {error_message}")

        return responses

    def step(self):
        pass
