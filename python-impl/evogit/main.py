import argparse
import logging
import sys
import os
import re
import random
import torch
import tomllib
from datetime import datetime
from typing import NamedTuple, Callable
from evox.workflows import StdWorkflow
from algorithm import EvoGitAlgo
from config import EvoGitConfig
from evox_extension import (
    EvoGitProblem,
    op,
    update_branches,
    array_to_hex,
    hex_to_array,
    git_update,
)
from utils.llm import LLMBackend
from utils.git import evogit_worktree_init

torch.set_default_device("cpu")


class Stage(NamedTuple):
    stage_num: int
    task: str
    agent_characteristics: str
    mutation_template: str
    diff_template: str


STAGE = Stage(
    stage_num=0,
    task="",
    agent_characteristics="",
    mutation_template="",
    diff_template="",
)


def prompt_fn(file_list, filename, start_lineno, end_lineno, prompt_code, lint_output):
    global STAGE
    return STAGE.mutation_template.format(
        structure=file_list,
        filename=filename,
        start_lineno=start_lineno,
        end_lineno=end_lineno,
        code=prompt_code,
        lint=lint_output,
        current_task=STAGE.task,
        agent_characteristics=random.choice(STAGE.agent_characteristics),
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
        assert len(code_blocks) >= 2, f"Expected at least 2 code blocks, got {len(code_blocks)}"
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
    global STAGE
    return STAGE.diff_template.format(
        structure=file_list,
        diff=diff,
        prev_lint=prev_note,
        new_lint=new_note,
        current_task=STAGE.task,
    )


def read_stage(stage_dir: str, stage_num: int) -> Stage:
    """
    Read the stage (a TOML file) from the given path.
    """
    path = os.path.join(stage_dir, f"stage_{stage_num}.toml")
    # check if the directory exists
    while not os.path.exists(path):
        user_input = input(
            (
                f"Stage {stage_num} does not exist. Expecting a file at {path}. "
                "Type '(e)xit' to exit or '(s)kip' to skip this stage or (c)ontinue to continue after creating the file: "
            )
        )
        user_input = user_input.lower().strip()
        if user_input == "e" or user_input == "exit":
            raise FileNotFoundError(f"Stage {stage_num} file not found at {path}.")
        elif user_input == "s" or user_input == "skip":
            print(f"Skipping stage {stage_num}.")
            return read_stage(stage_dir, stage_num - 1)
        elif user_input == "c" or user_input == "continue":
            print(f"Continuing with stage {stage_num}.")

    with open(path, "rb") as f:
        stage_data = tomllib.load(f)

    return Stage(
        stage_num=stage_num,
        task=stage_data["task"],
        agent_characteristics=stage_data["agent_characteristics"],
        mutation_template=stage_data["mutation_template"],
        diff_template=stage_data["diff_template"],
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run EvoGit with LLM")
    parser.add_argument(
        "path",
        type=str,
        help="Path to the git repository. Default to the current working directory.",
        default=".",
    )
    parser.add_argument("--model-name", type=str, help="Name of the LLM to use.")
    parser.add_argument(
        "--n-context-lines",
        type=int,
        help="Number of context lines to use.",
        default=100,
    )
    parser.add_argument("--host-id", type=int, help="Host ID for the run.", default="0")
    parser.add_argument("--remote-repo", type=str, help="Remote repository URL.")
    parser.add_argument(
        "--project-type", type=str, help="Project type (e.g., python, slidev, nextjs)."
    )
    parser.add_argument(
        "--init-stage", type=int, help="Initial stage to start from.", default=0
    )
    args = parser.parse_args()
    evogit_worktree_init(args.path, clean_start=True)

    working_dir = os.path.join(args.path, ".evogit")
    log_dir = os.path.join(working_dir, "log")
    stage_dir = os.path.join(working_dir, "stages")
    if not os.path.exists(working_dir):
        raise ValueError(f"Working directory {working_dir} does not exist")

    host_id = args.host_id
    logger = logging.getLogger("evogit")
    logger.propagate = False  # Disable the default printing behavior
    timestamp = datetime.now().strftime("%Y-%m-%d-%H-%M-%S")
    f_handler = logging.FileHandler(os.path.join(log_dir, f"{timestamp}.log"))
    f_handler.setLevel("DEBUG")
    s_handler = logging.StreamHandler(sys.stdout)
    s_handler.setLevel("WARNING")
    logger.setLevel("DEBUG")
    logger.addHandler(f_handler)
    logger.addHandler(s_handler)

    llm_backend = LLMBackend(
        model_name=args.model_name,
        params={
            "temperature": 0.5,
            "top_p": 0.7,
            "reasoning_effort": "disable",
            "thinking": {"type": "disabled", "budget_tokens": 0},
        },
    )
    STAGE = read_stage(stage_dir, args.init_stage)

    if args.project_type == "nextjs":
        from presets.npm_nextjs import run_check

        check_fn = run_check
    elif args.project_type == "python":
        from presets.uv_pyright import run_check

        check_fn = run_check
    elif args.project_type == "slidev":
        from presets.npm_slidev import run_check

        check_fn = run_check
    elif args.project_type == "html":
        from presets.npm_html import run_check

        check_fn = run_check
    else:
        raise ValueError(f"Unsupported project type: {args.project_type}")

    config = EvoGitConfig(
        num_objectives=0,
        git_user_name="Bill Huang",
        git_user_email="bill.huang2001@gmail.com",
        push_every=1,
        fetch_every=0,
        llm_name=args.model_name,
        llm_backend=llm_backend,
        device_map="auto",
        git_dir=working_dir,
        eval_command=None,
        seed_file=None,
        filename=None,
        merge_prob=1,
        accept_ours_prob=0.5,
        git_hash="sha1",
        evaluate_workers=120,
        reevaluate=False,
        enable_sandbox=False,
        timeout=10,
        n_context_lines=args.n_context_lines,
        prompt_fn=prompt_fn,
        response_fn=response_fn,
        diff_prompt_fn=diff_prompt_fn,
        check_fn=check_fn,
        max_merge_retry=512,
        clean_start=True,
        project_type="python",
        remote_repo=args.remote_repo,
        hostname="host" + str(host_id),
        merge_driver=None,
    )

    n_iter = 120
    human_feedback_every = 20

    algorithm = EvoGitAlgo(
        config,
        pop_size=16,
        crossover_every=3,
    )
    problem = EvoGitProblem(config)
    workflow = StdWorkflow(algorithm, problem)
    population_history = []

    try:
        for i in range(n_iter):
            logger.warning(f"Iteration {i}    Stage {STAGE.stage_num}")
            if i == 0:
                workflow.init_step()
            else:
                workflow.step()
            population = workflow.algorithm.pop
            update_branches(config, population)
            git_update(config, i)
            population = [array_to_hex(individual) for individual in population]
            population_history.append(population)
            # save the data every 10 iterations

            if (i + 1) % human_feedback_every == 0:
                logger.warning(f"Human feedback phase, stage {STAGE.stage_num}")
                # pause the program and wait for human feedback
                # print the current population
                print("Current population:")
                print(population)
                # pause, and ask "y/n"
                manual_selection = input("Do you wish to select a commit id? (y/n): ")
                while manual_selection not in ["y", "n"]:
                    manual_selection = input(
                        "Do you wish to select a commit id? (y/n): "
                    )
                if manual_selection == "y":
                    # ask for the commit id
                    commit_id = input("Please enter the commit id: ")
                    # check if the commit id is in the population
                    while commit_id not in population:
                        print("Commit id not in the population, please try again.")
                        commit_id = input("Please enter the commit id: ")

                    commit_id_arr = hex_to_array(commit_id)
                    # set the selected commit id
                    workflow.algorithm.pop = torch.broadcast_to(
                        commit_id_arr, workflow.algorithm.pop.shape
                    )

                feedback = input("Do you want to continue? (y/n): ")
                while feedback not in ["y", "n"]:
                    feedback = input("Do you want to continue? (y/n): ")
                if feedback == "n":
                    logger.warning("Stop")
                    break
                elif feedback == "y":
                    logger.warning("Continue")

                STAGE = read_stage(stage_dir, STAGE.stage_num + 1)

    except KeyboardInterrupt:
        pass
    finally:
        print("Exit")
