"""This module manage project related operations."""

import subprocess
import logging


logger = logging.getLogger("evogit")


def run_checks(project_paths: list[str]):
    """Run checks for all project paths in the given list.

    Expect two callbacks:
    - `run_check`: a function that takes a project path and returns a subprocess handler.
    - `await_results`: a function that takes a list of handlers and returns their results.
    """
    handlers = []
    for project_path in project_paths:
        handler = run_check(project_path)
        handlers.append(handler)

    results = []
    # wait for these subprocess to end, and get the text output
    for handler in handlers:
        # wait for the process to finish
        try:
            stdout, stderr = handler.communicate(timeout=120)
            results.append(stdout)
        except subprocess.TimeoutExpired:
            handler.kill()
            stdout, stderr = handler.communicate()
            logger.warning(f"Linting timed out: {stderr}")
            results.append(stdout)
    return results
