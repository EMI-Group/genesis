# Config Schema

## Intent
Configuration schema definitions — pure data describing every config key, its type, default, and validation rules — plus the provider/model-aware extraction of LLM generation parameters from model profiles.

## Routing Table
None — leaf directory.

## API Surface

### `EvoGit.Config.Schema.Definitions`
Returns all config key schemas as a flat list of maps. Each schema: `key_path` (dotted atom path, e.g. `:scheduler.agent_workers`), `type`, `default`, `validation`, `category`, `sub_category`, `description`. Covers scheduler, sandbox, git, truncation, and more.

### `EvoGit.Config.Schema.LLM`
Extracts LLM generation parameters from config/model profiles. `llm_generation_params/1` accepts a model profile map or a resolved config map and returns a keyword list suitable for `ReqLLM`.

`profile_generation_params/1` is the **single choke point** for every parameter consumer (scheduler state, dispatch, agent state, and both the legacy-flat and explicit-profile path — the legacy path builds a profile via `build_legacy_default_profile/1` which is then read through this same function). It assembles `temperature, max_tokens, reasoning_effort, top_p, top_k, frequency_penalty, presence_penalty` plus `provider_options`, then pipes the result through `EvoGit.Config.Schema.LLMConstraints.filter/3` exactly once. Provider-aware filtering must NOT be duplicated at the other parameter-assembly sites.

`provider_from_model/1` derives the provider atom from the three supported spec shapes — string `"provider:id"`, map `%{provider: ..., id: ...}`, tuple `{provider, opts}` — and `nil` for anything unrecognized.

`provider_options_for_model/1` returns the OpenAI-only default (`[store: false]`, from `default_provider_options/0`) **only for a genuine NATIVE OpenAI endpoint**: provider `:openai` AND no custom endpoint override. A model spec MAP carrying a non-nil `:base_url` or `:extra` is an OpenAI-**compatible** third-party endpoint (the dashboard's "OpenAI-Compatible API" catalog entry maps to provider `:openai` with a custom `base_url`) and gets `[]` — such endpoints do not implement the OpenAI Responses-API `store` option. The check is a presence check, so even an empty `extra` map counts as an override.

### `EvoGit.Config.Schema.LLMConstraints`
The declarative, pure, never-raising filter for the generation-parameter keyword list. Holds two constraint sources:

1. **`@constraint_tables`** — one map per provider/model family, each carrying its own `:provenance` code comment (the documented source every rule comes from). Seeded with `:zai_glm` (Z.AI GLM Chat-Completions API reference): `:unsupported_params` = `top_k`/`frequency_penalty`/`presence_penalty` (not documented by Z.AI); `:max_temperature` = `1.0` (Z.AI documents `[0.0, 1.0]` while Genesis allows up to 2.0); `:reasoning_effort` = full OpenAI set, with `by_model` overriding GLM-5.3 / GLM-5.3-FLASH to `low|high|max` only; `:thinking_disable_unsupported` records that GLM-5.3 rejects `thinking.type = "disabled"` (informational — Genesis never emits a `thinking` parameter, which is only reachable through the user `provider_options` override). Adding a provider = adding one table map.
2. **Model metadata** — `%{limits: map(), capabilities: map()}`: `limits.output` bounds `max_tokens`; `capabilities.reasoning.enabled` gates `reasoning_effort`; `capabilities.tools.enabled` gates `tools`/`tool_choice`.

Public API: `filter(params, model, metadata)` (guard-clause safe for non-list/non-keyword input, preserves keyword ORDER of survivors, never raises), `constraints_for(model)` (matching table entries), `normalize_metadata/1` (`@doc false`; collapses a metadata map or raw catalog-like struct to the documented contract, `nil` when unusable — shared with `LLM.model_metadata/1`).

**Model matching** is provider-atom based (`:zai`/`:zai_coder`/`:zai_coding_plan`) OR model-id based (case-insensitive `glm` substring, which also covers OpenRouter-style ids such as `z-ai/glm-5.3-flash` served under a non-Z.AI provider atom). The heuristic and its limits are documented in the table entry: GLM weights served under an id without `glm` are not matched, and an unrelated id containing `glm` is matched conservatively.

**Degradation contract**: a violation is always resolved by OMITTING the parameter (never clamped, never mapped — no documented value mapping exists for the affected families) plus a `Logger.warning` naming the parameter, the model and the reason. A `nil`/empty metadata map, an unknown or unparseable model spec, or a model the catalog does not know leaves the parameter list **byte-identical** — nothing is dropped merely because metadata is missing. Unknown providers/models are left completely untouched.

### Model metadata seam (`LLM.model_metadata/1`, app env `:llm_model_metadata_fun`)
`LLM.model_metadata/1` (`@doc false` public, returns `%{limits: map(), capabilities: map()} | nil`) reads the app-env seam `:llm_model_metadata_fun` — a 1-arity fun over the model spec, read AT CALL TIME — and falls back to a real ReqLLM model-catalog lookup (`ReqLLM.model/1`, already a declared dependency) when unset. The lookup is deliberately NON-raising (`rescue` + `catch` → `Logger.warning` + `nil`) and never forces a catalog load, so it degrades to "no metadata" (table rules still apply) rather than breaking a boot or a spawn. **Keep it cheap** — it runs per agent spawn (and per profile read).

Tests inject stub metadata through the seam, so no catalog is needed.

## Constraints
- Schema modules must be pure functions with no side effects — no I/O, GenServer, or process logic.
- Schema definitions are the single source of truth for all config keys.
- The parameter filter never raises on user config and never guesses: a constraint is only applied where there is documented provenance or actual model metadata.

## Notes for Agents
- `definitions.ex` is ~810 lines — legitimate (comprehensive data table of all config keys); do not split it.
- In `definitions.ex`, the search-provider schemas (`[:tools, :search, <provider>, ...]`) are NOT hand-written literals — they are generated from the data-driven `@search_provider_defs` list (one `%{name:, label:, credential_key:, base_url:, optional model:}` map per search provider: `:tavily`/`:perplexity`/`:exa`/`:bing`/`:brave`), each entry expanded by `search_provider_schema_maps/1` into the repeated per-key schema maps (33 search schema maps in `schemas/0` in total incl. the fixed `:enabled`/`:provider`). Adding or extending a search provider means editing that list, not hand-writing repeated provider maps. `@search_providers`/`search_providers/0` remains the source of truth for the provider-ID list used by the `:provider` schema `in:` validation.
- `EvoGit.Config.Schema` (validate + defaults + typespecs) lives in the PARENT node file `../schema.ex`; the validation ENGINE (former `type_errors/3`/`rule_errors/3` privates) now lives in the parent node's `../ecto_validation.ex` (`EctoValidation.errors_for/4`) with scalar type decisions routed through the strict custom Ecto types in `../ecto_types.ex` (`EctoTypes`). Definitions here, the engine there and the `@type schema_type` union in `schema.ex` must stay in sync. **Adding a new validation type requires three touch points** (see the "Validation Engine — Ecto-backed" section of the parent `../CONTEXT.md`): (1) a definition entry here, (2) a new nested strict `use Ecto.Type` module in `ecto_types.ex` + a `type_for/1` clause (returning the fully-qualified `__MODULE__.X` atom) + a `@type scalar_type` union entry, and (3) a `type_errors/2,3`-style clause in `ecto_validation.ex` plus the `@type schema_type` union entry in `schema.ex`. `min`/`max`/`in` rules need no type-module — they are pure predicates in `EctoValidation.rule_errors/3`.
- `llm_constraints.ex` deliberately does NOT depend on any catalog being loadable: the Z.AI/GLM table rules must stay effective with zero metadata. Do not move table rules behind a metadata check.
