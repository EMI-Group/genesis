import argparse
import logging
import os
import sys
from datetime import datetime

import torch
from algorithm import EvoGitAlgo
from evox.workflows import StdWorkflow
from evox_extension import (
    EvoGitProblem,
    array_to_hex,
    git_update,
    hex_to_array,
    update_branches,
)
from agent import (
    read_plan,
    prompt_fn,
    response_fn,
    diff_prompt_fn,
)
from utils.git import evogit_worktree_init
from utils.llm import LLMBackend

from config import EvoGitConfig

torch.set_default_device("cpu")


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
    plan_dir = os.path.join(working_dir, "plan")
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
    plan = read_plan(plan_dir, args.init_stage)

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
            logger.warning(f"Iteration {i}    Stage {plan.index}")
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
                logger.warning(f"Human feedback phase, stage {plan.index}")
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

                plan = read_plan(plan_dir, plan.index + 1)

    except KeyboardInterrupt:
        pass
    finally:
        print("Exit")
