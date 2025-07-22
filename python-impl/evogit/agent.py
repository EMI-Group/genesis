"""This module defines the agent's behavior and interaction with the environment.
In EvoGit, agents run in a 'batched' mode, where all agents are executed in parallel lockstep.
"""

import logging
import os
import random
import re
import tomllib
from typing import NamedTuple


class Plan(NamedTuple):
    """A plan for the agent's behavior in a specific stage of the EvoGit workflow.
    Agents will work according to the plan defined in that stage.
    """

    index: int
    task: str
    agent_characteristics: str
    mutation_template: str
    diff_template: str


CURRENT_PLAN = Plan(
    index=0,
    task="",
    agent_characteristics="",
    mutation_template="",
    diff_template="",
)


def prompt_fn(file_list, filename, start_lineno, end_lineno, prompt_code, lint_output):
    global CURRENT_PLAN
    agent_characteristics = random.choice(CURRENT_PLAN.agent_characteristics)
    return CURRENT_PLAN.mutation_template.format(
        structure=file_list,
        filename=filename,
        start_lineno=start_lineno,
        end_lineno=end_lineno,
        code=prompt_code,
        lint=lint_output,
        current_task=CURRENT_PLAN.task,
        agent_characteristics=agent_characteristics,
    )


code_extract_pattern = re.compile(r"```.*?\n(.*?)```", re.DOTALL)
filename_pattern = re.compile(r"^`([^`]+)`", re.MULTILINE)


class ResponseContent(NamedTuple):
    code: str
    filename: str
    new_file_content: str
    commit_message: str


def response_fn(response: str) -> ResponseContent:
    try:
        if not response.strip().endswith("```"):
            # If the response does not end with a code block,
            # try to append a closing code block
            # This is a workaround for some LLMs that might not format the response correctly.
            response += "\n```"
        code_blocks = code_extract_pattern.findall(response)
        filename_match = filename_pattern.search(response)
        assert len(code_blocks) >= 2, (
            f"Expected at least 2 code blocks, got {len(code_blocks)}"
        )
        if len(code_blocks) > 3:
            logger = logging.getLogger("evogit")
            logger.warning("More than 3 code blocks found, using only the first 3.")

        # Extract fields with safe fallbacks
        code = code_blocks[0].strip() + "\n" if len(code_blocks) > 0 else ""
        if len(code_blocks) > 2:
            new_file_content = (
                code_blocks[1].strip() + "\n" if len(code_blocks) > 2 else ""
            )
            commit_message = (
                code_blocks[2].strip() if len(code_blocks) > 2 else "LLM code update"
            )
        else:
            new_file_content = ""
            commit_message = (
                code_blocks[1].strip() if len(code_blocks) > 1 else "LLM code update"
            )
        commit_message = commit_message[:256]  # Truncate to 256 characters

        filename = filename_match.group(1).strip() if filename_match else "None"
        return ResponseContent(
            code=code,
            filename=filename,
            new_file_content=new_file_content,
            commit_message=commit_message,
        )

    except Exception as e:
        logger = logging.getLogger("evogit")
        logger.warning(
            f"Error in response extraction, original response: {response}; error: {e}."
        )
        return ResponseContent(
            code="",
            filename="None",
            new_file_content="",
            commit_message="LLM code update",
        )


def diff_prompt_fn(file_list, diff, prev_note, new_note):
    global CURRENT_PLAN
    return CURRENT_PLAN.diff_template.format(
        structure=file_list,
        diff=diff,
        prev_lint=prev_note,
        new_lint=new_note,
        current_task=CURRENT_PLAN.task,
    )


def read_plan(plan_dir: str, index: str) -> Plan:
    """
    Read the plan (a TOML file) from the given path.
    """
    path = os.path.join(plan_dir, f"plan_{index}.toml")
    # check if the directory exists
    while not os.path.exists(path):
        user_input = input(
            (
                f"Plan {index} does not exist. Expecting a file at {path}. "
                "Type '(e)xit' to exit or '(s)kip' to skip this stage or (c)ontinue to continue after creating the file: "
            )
        )
        user_input = user_input.lower().strip()
        if user_input == "e" or user_input == "exit":
            raise FileNotFoundError(f"Plan {index} file not found at {path}.")
        elif user_input == "s" or user_input == "skip":
            print(f"Skipping stage {index}.")
            return read_plan(plan_dir, index - 1)
        elif user_input == "c" or user_input == "continue":
            print(f"Continuing with stage {index}.")

    with open(path, "rb") as f:
        plan = tomllib.load(f)

    return Plan(
        index=index,
        task=plan["task"],
        agent_characteristics=plan["agent_characteristics"],
        mutation_template=plan["mutation_template"],
        diff_template=plan["diff_template"],
    )
