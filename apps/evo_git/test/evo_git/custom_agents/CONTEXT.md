# custom_agents — Test Tree

## Intent

ExUnit suite for the custom-agents subsystem, mirroring
`apps/evo_git/lib/evo_git/custom_agents/`. One file: `model_selector_test.exs`
(`EvoGit.CustomAgents.ModelSelectorTest`, 20 tests).

## API Surface

- `model_selector_test.exs` → `EvoGit.CustomAgents.ModelSelector`:
  `compile_script/1` contract, `select_model/1` (script matching on
  `custom_agent_id`/`agent_type`/`depth`+`parent_id`, nil/""/false → default,
  `script_raised`/`invalid_result`/`compile_error` error shapes), `status/0`,
  `enabled?/0`, `invalidate/0` cache-busting, `describe_contract/0`.

## Constraints

- **`async: false` is REQUIRED** — the module mutates two pieces of BEAM-global
  state read by other concurrently running test modules: the
  `XDG_CONFIG_HOME` env var (`System.put_env`, consumed by
  `EvoGit.Config.config_dir/0` / `EvoGit.CustomAgents`) and the process-wide
  `:persistent_term` compile cache erased by
  `EvoGit.CustomAgents.ModelSelector.invalidate/0`. Do NOT flip to
  `async: true`.
- Per-test XDG isolation: `setup` points `XDG_CONFIG_HOME` at a fresh temp dir
  and restores the original (or deletes it) in `on_exit`, so tests never touch
  the real `~/.config/genesis/`.
