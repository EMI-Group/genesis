import subprocess


def run_check(project_path: str):
    handler = subprocess.Popen(
        "npm install --silent && npx slidev build",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=project_path,
        shell=True,
    )
    return handler