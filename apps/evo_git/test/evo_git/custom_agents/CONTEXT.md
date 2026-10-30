# custom_agents — Test Tree
## Intent
ExUnit suite for the custom-agents subsystem, mirroring
`apps/evo_git/lib/evo_git/custom_agents/`.
One file: `model_selector_test.exs` (`EvoGit.CustomAgents.ModelSelectorTest`, 20 tests).
## API Surface
- `model_selector_test.exs` → `EvoGit.CustomAgents.ModelSelector`:
  `compile_script/1` contract, `select_model/1` (script matching on
  `custom_agent_id`/`agent_type`/`depth`+`parent_id`, nil/""/false → default,
  `script_raised`/`invalid_result`/`compile_error` error shapes), `status/0`,
  `enabled?/0`, `invalidate/0` cache-busting, `describe_contract/0`.
## Constraints
- **`async: true`** — each test gets its own PER-PROCESS config directory via
  `EvoGit.TestSupport.ConfigDir.isolate!/1` in `setup` (never a process-wide
  `XDG_CONFIG_HOME` write), and the process-wide `:persistent_term` compile
  cache key EMBEDS the `agents.toml` path (`{EvoGit.CustomAgents.ModelSelector,
  :cache, path}`), so a test-local directory can neither observe nor overwrite
  another test's entry.
- The cache is still erased in `setup` (and by `write_script/1` after each
  write) as a pristine-start guarantee; that is not a serialization reason.
