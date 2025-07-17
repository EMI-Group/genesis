import subprocess


def run_check(project_path: str):
    """Get ESLint feedback for the project.
    If async_run is True, run ESLint in the background and return the handler.
    Otherwise, run ESLint synchronously and return the output as string.
    """
    handler = subprocess.Popen(
        "npm install --silent && npx next lint -f codeframe && npx next build --no-lint --no-mangling",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=project_path,
        shell=True,
    )
    return handler
