import sys
import logging
from datetime import datetime
import os
import torch
from evox.workflows import StdWorkflow
import argparse
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

torch.set_default_device("cpu")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run EvoGit with LLM")
    parser.add_argument(
        "path",
        type=str,
        help="Path to the git repository. Default to the current working directory.",
        default=".",
    )
    parser.add_argument("--host_id", type=int, help="Host ID for the run.", default="0")
    parser.add_argument("--endpoint", type=str, help="Endpoint for the LLM API.")
    parser.add_argument("--api_token", type=str, help="API token for the LLM API.")
    parser.add_argument("--model_name", type=str, help="Name of the LLM to use.")
    parser.add_argument("--remote_repo", type=str, help="Remote repository URL.")
    args = parser.parse_args()
    repo_dir = os.path.abspath(args.path)
    if not os.path.exists(repo_dir):
        raise ValueError(f"Working directory {repo_dir} does not exist")

    working_dir = os.path.join(repo_dir, ".evogit")
    log_dir = os.path.join(working_dir, "log")
    stages_dir = os.path.join(working_dir, "stages")

    host_id = args.host_id
    logger = logging.getLogger("evogit")
    logger.propagate = False  # Disable the default printing behavior
    timestamp = datetime.now().strftime("%Y-%m-%d-%H-%M-%S")
    f_handler = logging.FileHandler(
        os.path.join(log_dir, f"{timestamp}.log")
    )
    f_handler.setLevel("DEBUG")
    s_handler = logging.StreamHandler(sys.stdout)
    s_handler.setLevel("WARNING")
    logger.setLevel("DEBUG")
    logger.addHandler(f_handler)
    logger.addHandler(s_handler)

    llm_backend = LLMBackend(model_name=args.model_name)

    config = EvoGitConfig(
        num_objectives=0,
        git_user_name="Bill Huang",
        git_user_email="bill.huang2001@gmail.com",
        push_every=1,
        fetch_every=0,
        migrate_every=1,
        human_every=0,
        migrate_count=0,
        llm_name=args.model_name,
        llm_backend=llm_backend,
        device_map="auto",
        git_dir=f"/tmp/evogit/evogit_llm_{args.model_name}_{host_id}",
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
        prompt_constructor=prompt_constructor,
        respond_extractor=respond_extractor,
        diff_prompt_constructor=diff_prompt_constructor,
        fixup_prompt_constructor=None,
        max_merge_retry=512,
        clean_start=True,
        project_type="python",
        remote_repo=args.remote_repo,
        hostname="host" + host_id,
        merge_driver=None,
    )

    op.init_repo(config, "remote", force_create=True)
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

    STAGE = 0

    # check if the directory exists
    if not os.path.exists(stages_dir):
        raise ValueError(f"Directory {stages_dir} does not exist")

    try:
        for i in range(n_iter):
            logger.warning(f"Iteration {i}    Stage {STAGE}")
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
                STAGE += 1
                logger.warning(f"Human feedback phase, stage {STAGE}")
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
    except KeyboardInterrupt:
        pass
    finally:
        print("Exit")
