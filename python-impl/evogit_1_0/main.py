"""Main entry point for EvoGit."""

import argparse
import os
import sys

# Local imports assuming all files are in the same package/directory
from .hierarchy import Project
from .agent import Agent
from .executor import Executor


def load_guideline(source: str) -> str:
    """Loads the project guideline from a file path or returns the string directly."""
    if os.path.exists(source):
        with open(source, "r", encoding="utf-8") as f:
            return f.read()
    return source


def generate(args):
    """Runs the executor until done."""
    # 1. Setup Project
    try:
        guideline_content = load_guideline(args.guideline)
    except Exception as e:
        print(f"Error reading guideline: {e}")
        sys.exit(1)

    project = Project(
        max_depth=args.max_depth, path=args.path, name=args.name, email=args.email
    )

    # Inject guideline into project (required by Agent.init_step1)
    project.guideline = guideline_content

    # Current head commit
    commit_id = project.head
    # Start with an agent for the root node, which now exists after bootstrap
    root_node = project.get_node("")
    if not root_node:
        print("Error: Root node not found after bootstrap.")
        sys.exit(1)
    # Initialize root agent
    agents = [Agent(project, commit_id, root_node)]
    # Initialize Executor
    executor = Executor(
        project=project,
        agents=agents,
        model=args.model,
        poll_interval=args.poll_interval,
    )

    # ========= Generation Loop =========
    print(
        f"🚀 Starting generation loop (Max depth: {args.max_depth}, Max steps: {args.max_steps})..."
    )
    # initialize the repository
    executor.init()

    for i in range(args.max_depth):
        print(f"\n--- Depth Level {i} ---")
        print(f"Active Agents: {len(executor.agents)}")
        for ag in executor.agents:
            print(f" - Agent at: '{ag.path}' (Level {ag.node.level})")

        try:
            executor.step()
        except Exception as e:
            print(f"❌ Execution error: {e}")
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
        type=str,
        help="Local path where the repository will be generated.",
    )
    parser.add_argument(
        "--guideline",
        type=str,
        default="./guideline.md",
        required=True,
        help="Path to a text file containing the project guidelines/requirements, or the string itself.",
    )
    parser.add_argument(
        "--max-depth",
        type=int,
        default=2,
        help="Maximum nesting depth of the repository hierarchy (0=Root, 1=Dirs, 2=Files).",
    )

    # Git Configuration
    parser.add_argument(
        "--name", type=str, default="EvoGit Bot", help="Git author name."
    )
    parser.add_argument(
        "--email", type=str, default="bot@evogit.ai", help="Git author email."
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
