import subprocess
import os


def run_check(project_path: str):
    """Run Ruff to get lint feedback for the python project.
    If async_run is True, run Ruff in the background and return the handler.
    Otherwise, run Ruff synchronously and return the output as string.
    """
    # Disable the current python virtual environment
    clean_env = os.environ.copy()
    clean_env.pop("VIRTUAL_ENV", None)
    clean_env["UV_CACHE_DIR"] = "/tmp/uv_cache"
    # sed "s|$(pwd)/||" is used to replace the absolute path with a relative one
    handler = subprocess.Popen(
        'uv run pyright . | sed "s|$(pwd)/||"',
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=project_path,
        shell=True,
        env=clean_env,
    )
    return handler
