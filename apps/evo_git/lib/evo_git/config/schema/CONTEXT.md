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
- `definitions.ex` is ~810 lines — legitimate (comprehensive data table of all config keys); do not split it.
- In `definitions.ex`, the search-provider schemas (`[:tools, :search, <provider>, ...]`) are NOT hand-written literals — they are generated from the data-driven `@search_provider_defs` list (one `%{name:, label:, credential_key:, base_url:, optional model:}` map per search provider: `:tavily`/`:perplexity`/`:exa`/`:bing`/`:brave`), each entry expanded by `search_provider_schema_maps/1` into the repeated per-key schema maps (33 search schema maps in `schemas/0` in total incl. the fixed `:enabled`/`:provider`). Adding or extending a search provider means editing that list, not hand-writing repeated provider maps. `@search_providers`/`search_providers/0` remains the source of truth for the provider-ID list used by the `:provider` schema `in:` validation.
- `EvoGit.Config.Schema` (validate + defaults + typespecs) lives in the PARENT node file `../schema.ex` — definitions here and the type-checking machinery there must stay in sync. New types require both a definition here AND a `type_errors/3` clause + `@type schema_type` union entry in the parent file.
