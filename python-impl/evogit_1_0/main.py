"""Main entry point for EvoGit."""

import argparse
import os
import sys
import json

# Local imports assuming all files are in the same package/directory
from hierarchy import Project
from agent import Agent
from executor import Executor


def load_config(source: str) -> str:
    """Loads the project guideline from a file path or returns the string directly."""
    assert os.path.exists(source), f"Config file not found: {source}"
    # load the json file content
    with open(source, "r") as f:
        content = json.load(f)

    return content


def generate(args):
    """Runs the executor until done."""
    # 1. Setup Project
    config = load_config(args.config)

    project = Project(
        init_depth=args.init_depth,
        config=config,
        path=args.path,
        name=args.name,
        email=args.email,
    )

    # Current head commit
    commit_id = project.head
    # Start with an agent for the root node, which now exists after bootstrap
    root_node = project.get_node("")
    if not root_node:
        print("Error: Root node not found after bootstrap.")
        sys.exit(1)
    # Initialize root agent
    agents = [Agent(project, commit_id, root_node.path)]
    # Initialize Executor
    executor = Executor(
        project=project,
        agents=agents,
        model=args.model,
        poll_interval=args.poll_interval,
    )

    # ========= Generation Loop =========
    print(
        f"🚀 Starting generation loop (Max depth: {project.max_depth}, Max steps: {args.max_steps})..."
    )
    # initialize the repository

    for i in range(project.max_depth):
        print(f"\n--- Step {i + 1} ---")
        print(f"Active Agents: {len(executor.agents)}")
        for ag in executor.agents:
            print(f" - Agent at: '{ag.path}' (Level {ag.node.level})")

        try:
            executor.step()
        except Exception as e:
            print(f"❌ Execution error: {e}")
            # print traceback for debugging
            import traceback

            traceback.print_exc()
            break

        # Optional: heuristic to stop if we are only processing completed leaf nodes
        # (This depends on specific leaf node behavior in agent.py)

    print("✨ Process completed.")


def main():
    parser = argparse.ArgumentParser(
        description="EvoGit: A hierarchical AI coding agent.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    # Project Configuration
    parser.add_argument(
        "path",
        type=str,
        help="Local path where the repository will be generated.",
    )
    parser.add_argument(
        "--init-depth",
        type=int,
        help="The initial depth to bootstrap the project structure. If set to 0, it will expand the project fully, otherwise it will only create the structure up to the specified depth.",
    )
    parser.add_argument(
        "--config",
        type=str,
        default="./config.json",
        help="Path to a json file containing the project guidelines/requirements.",
    )

    # Git Configuration
    parser.add_argument(
        "--name", type=str, default="EvoGit Agent", help="Git author name."
    )
    parser.add_argument(
        "--email", type=str, default="agent@evogit.ai", help="Git author email."
    )

    # LLM & Execution Configuration
    parser.add_argument(
        "--model",
        type=str,
        default="gemini-2.5-flash",
        help="Google GenAI model to use.",
    )
    parser.add_argument(
        "--max-steps",
        type=int,
        default=50,
        help="Safety limit for the maximum number of execution steps to prevent infinite loops.",
    )
    parser.add_argument(
        "--poll-interval",
        type=int,
        default=30,
        help="Polling interval (seconds) for batch requests.",
    )

    args = parser.parse_args()
    generate(args)


if __name__ == "__main__":
    main()
