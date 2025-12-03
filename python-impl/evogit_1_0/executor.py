"""This module defines the Process class used in EvoGit."""

import time
from typing import List
from google import genai
from .agent import Agent, LLMRequest
from .hierarchy import Project, Action

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

    def __init__(
        self,
        project: Project,
        agents: List[Agent],
        model: str = "gemini-2.5-flash",
        poll_interval: int = 30,
    ):
        self.client = genai.Client()
        self.poll_interval = poll_interval
        self.model = model
        self.project = project
        self.agents = agents
        self.batch_req_thres = 5  # Minimum number of requests to use batch API

    def _to_request_params(self, llm_request: LLMRequest):
        """Convert an LLMRequest to genai request parameters."""
        return {
            "config": llm_request.config,
            "contents": [{"role": "user", "parts": [{"text": llm_request.content}]}],
        }

    def _batch_request(self, requests: List[LLMRequest]) -> List[str]:
        """Sends a batch of LLM requests and returns the responses.
        Use the batch API to send multiple requests in parallel, then poll for completion.
        """
        begin_time = time.time()
        batch_job = self.client.batch_generate_content(
            model=self.model,
            src=[self._to_request_params(req) for req in requests],
        )
        job_name = batch_job.name
        while True:
            job = self.client.batches.get(name=job_name)
            if job.status.name in completed_states:
                break
            time.sleep(self.poll_interval)

        end_time = time.time()
        duration = end_time - begin_time
        avg_time = duration / len(requests) if requests else 0
        if job.status.name not in good_states:
            print(
                f"Batch job failed after {duration:.2f} seconds with status: {job.status.name}"
            )
            raise Exception(f"Batch job failed with status: {job.status.name}")
        else:
            print(
                f"Batch job succeeded in {duration:.2f} seconds, average {avg_time:.2f} seconds per request."
            )

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

    def _sequential_request(self, requests: List[LLMRequest]) -> List[str]:
        """Send a list of requests sequentially, this has less latency but costs more."""
        begin_time = time.time()
        responses = []
        for req in requests:
            response = self.client.generate_content(
                model=self.model,
                config=req.config,
                contents=req.content,
            )
            responses.append(response.text)
        end_time = time.time()
        duration = end_time - begin_time
        avg_time = duration / len(requests) if requests else 0
        print(
            f"Sequential request: {len(requests)} requests completed in {duration:.2f} seconds, average {avg_time:.2f} seconds per request."
        )
        return responses

    def step(self):
        requests = []
        for agent in self.agents:
            llm_request = agent.step1()
            requests.append(llm_request)

        if len(requests) >= self.batch_req_thres:
            responses = self._batch_request(requests)
        else:
            responses = self._sequential_request(requests)

        actions = []
        for agent, response in zip(self.agents, responses):
            action = agent.step2(response)
            actions.append(action)

        for action in actions:
            self.project.perform(action)
