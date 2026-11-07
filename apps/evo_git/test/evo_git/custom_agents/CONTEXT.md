# custom_agents — Test Tree

## Intent
Permanent ExUnit regressions for custom-agent model-selection scripts and their dispatch boundary, mirroring `apps/evo_git/lib/evo_git/custom_agents/`.
The node contains three async modules with 39 tests.

## API Surface
- `model_selector_test.exs` (`EvoGit.CustomAgents.ModelSelectorTest`, 20 tests) covers script compilation, agent attributes, legacy ids, default results, ordinary exception/error contracts, status, enabled state, cache invalidation and help text.
- `model_selector_selection_test.exs` (`EvoGit.CustomAgents.ModelSelectorSelectionTest`, 7 tests) covers canonical account/model/effort map normalization, atom/string/mixed keys, duplicate-key precedence, omitted/nil effort, extra-field removal, nested-model effort validation, malformed values and legacy/default/error compatibility.
- `model_selector_dispatch_test.exs` (`EvoGit.CustomAgents.ModelSelectorDispatchTest`, 12 tests) exercises actual `Dispatch.resolve_selection/5` against a local `State` and real per-process custom-agent/script files.
Dispatch coverage pins configured account/model defaults over enumeration order, script spawn attributes, script over definition over legacy defaults, locked legacy and explicit task selections bypassing scripts, shared account authentication/concurrency, nested generation/context/effort overrides and endpoint identifier preservation.
Invalid script result/compile/runtime failures fall back to definition defaults, unknown legacy ids warn and use configured defaults, and schema-invalid maps or invalid explicit/definition selections return precise errors without silent fallback.

## Constraints
All modules use `async: true` with `EvoGit.TestSupport.ConfigDir.isolate!/1` and never mutate process-wide environment variables or app-global scheduler state.
The compiled-script cache embeds the per-process `agents.toml` path, so invalidating a test's cache cannot affect another test's entry.
Helpers invalidate the script cache after writes because multiple same-size scripts can share a stat timestamp.
Dispatch tests resolve synchronously against a local `%State{model_selection_config: config}` and never register agents, acquire slots or run an LLM request.
Fixtures use `llm.default_provider_profile` and canonical provider accounts with nested model inventories, account-level auth/concurrency/generation defaults and model-level overrides.
`ProviderProfiles.resolve_model_spec/2` returns a ReqLLM-ready `resolved.model_spec` string or endpoint map, not the persisted task selection.
Persisted selections are constructed from `resolved.provider_profile_id`, `resolved.model` and `resolved.reasoning_effort`, and known effort strings become atoms only in ReqLLM generation parameters.
Generation parameters may contain credentials, so tests permit them and use the existing harmless `PATH` value as a fixture credential without any environment mutation.
Script-bypass assertions use same-process mailbox markers rather than globally quiet capture-log windows.
Source siblings are read-only for this node; genuine production defects must be reported rather than patched here.

## Routing Table
There are no child directories.
