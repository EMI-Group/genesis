# `.github` — CI/CD Definitions & Shared Actions

## Intent

Everything GitHub needs to run this repository: workflow definitions for the CI gate and the release build, plus the composite actions those workflows share.
No application code lives here — a change in this tree alters how code is built, tested or released, never what it does.

## Routing Table

- `./workflows/` → workflow definitions (`ci.yml`, `build-desktop.yml`, `readme-evidence.yml`) — see its CONTEXT.md.
- `./actions/` → reusable composite actions (`setup-mix`, `install-tauri-cli`, `retry`) — see its CONTEXT.md.

## Constraints

- Workflow files are the single source of truth for the build/release process; there is no parallel script that reproduces them.
- Network access on GitHub-hosted runners is unreliable (transient 5xx, connection resets), so every network-prone step goes through the `./actions/retry` helper.
- GitHub Actions cannot be executed locally — validate changes by YAML parse plus review.
- Pinned action SHAs are never bumped as a side effect of an unrelated change.
