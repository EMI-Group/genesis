# Config Schema

## Intent
Configuration schema definitions — pure data describing every config key, its type, default, and validation rules. Also handles LLM parameter extraction from model profiles.

## Routing Table
None — leaf directory.

## API Surface

### `EvoGit.Config.Schema.Definitions`
Returns all config key schemas as a flat list of maps. Each schema: `key_path` (dotted atom path, e.g. `:scheduler.agent_workers`), `type`, `default`, `validation`, `category`, `sub_category`, `description`. Covers scheduler, sandbox, git, truncation, and more.

### `EvoGit.Config.Schema.LLM`
Extracts LLM generation parameters from config/model profiles. Accepts a model profile map or a resolved config map; returns a keyword list suitable for `ReqLLM`.

## Constraints
- Schema modules must be pure functions with no side effects — no I/O, GenServer, or process logic.
- Schema definitions are the single source of truth for all config keys.

## Notes for Agents
- **`profile_generation_params/1` reads ATOM keys only** and emits a key ONLY when its value is non-nil. A minimal profile (`id`/`model`/`concurrency` — what the dashboard writes) therefore yields `[]`, and a STRING-keyed profile yields `[]` too (`llm_generation_params/1` also dispatches on the presence of the ATOM keys `:id`/`:llm`, so a string-keyed profile returns `[]`). Profiles reaching this code are atom-keyed because `EvoGit.Config` normalizes them (`normalize_profile_keys/1`); the dashboard writes no generation params unless the user typed them.
- **`provider_options_for_model/1` is OpenAI-only by design** (`[store: false]` for `:openai`, `[]` otherwise). Passing `provider_options: [store: false]` to ANY non-OpenAI provider raises at request time — req_llm validates `provider_options` against the provider schema (`zai`/`zai_coder`/`zai_coding_plan` accept `[:thinking]` only → `NimbleOptions.ValidationError: unknown options [:store]`). Verified empirically against `deps/req_llm` 1.24.0.
- **Not every extraction key reaches the wire.** `top_k` and `reasoning_effort` are accepted ReqLLM generation options but are not encoded by the Z.AI family (`ReqLLM.Providers.Zai.Shared.add_basic_options/2` emits only `temperature`, `top_p`, `frequency_penalty`, `presence_penalty`, `user`, `seed`, `stop`); `reasoning_effort` is telemetry-only. `temperature`/`top_p`/`frequency_penalty`/`presence_penalty` DO reach the body when non-nil. This module can therefore not "leak" provider-unsupported parameter names of its own — except via an explicit profile `provider_options` map, which is passed through verbatim (`maybe_provider_options/2`).
- `definitions.ex` is ~810 lines — legitimate (comprehensive data table of all config keys); do not split it.
- In `definitions.ex`, the search-provider schemas (`[:tools, :search, <provider>, ...]`) are NOT hand-written literals — they are generated from the data-driven `@search_provider_defs` list (one `%{name:, label:, credential_key:, base_url:, optional model:}` map per search provider: `:tavily`/`:perplexity`/`:exa`/`:bing`/`:brave`), each entry expanded by `search_provider_schema_maps/1` into the repeated per-key schema maps (33 search schema maps in `schemas/0` in total incl. the fixed `:enabled`/`:provider`). Adding or extending a search provider means editing that list, not hand-writing repeated provider maps. `@search_providers`/`search_providers/0` remains the source of truth for the provider-ID list used by the `:provider` schema `in:` validation.
- `EvoGit.Config.Schema` (validate + defaults + typespecs) lives in the PARENT node file `../schema.ex`; the validation ENGINE (former `type_errors/3`/`rule_errors/3` privates) now lives in the parent node's `../ecto_validation.ex` (`EctoValidation.errors_for/4`) with scalar type decisions routed through the strict custom Ecto types in `../ecto_types.ex` (`EctoTypes`). Definitions here, the engine there and the `@type schema_type` union in `schema.ex` must stay in sync. **Adding a new validation type requires three touch points** (see the "Validation Engine — Ecto-backed" section of the parent `../CONTEXT.md`): (1) a definition entry here, (2) a new nested strict `use Ecto.Type` module in `ecto_types.ex` + a `type_for/1` clause (returning the fully-qualified `__MODULE__.X` atom) + a `@type scalar_type` union entry, and (3) a `type_errors/2,3`-style clause in `ecto_validation.ex` plus the `@type schema_type` union entry in `schema.ex`. `min`/`max`/`in` rules need no type-module — they are pure predicates in `EctoValidation.rule_errors/3`.
