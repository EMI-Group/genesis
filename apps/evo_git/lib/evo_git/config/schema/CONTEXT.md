# CONTEXT — Config Schema

## Intent

Configuration schema definitions — pure data describing every config key, its type, default, and validation rules. Also handles LLM parameter extraction from model profiles.

## Routing Table

None — leaf directory.

## API Surface

### `EvoGit.Config.Schema.Definitions`

Returns all config key schemas as a flat list of maps. Each schema has:

- `key_path` — dotted atom path (e.g. `:scheduler.agent_workers`)
- `type` — expected Elixir type
- `default` — default value
- `validation` — validation rules
- `category` — top-level grouping
- `sub_category` — optional sub-grouping
- `description` — human-readable documentation

Covers scheduler, sandbox, git, truncation, and more.

### `EvoGit.Config.Schema.LLM`

Extracts LLM generation parameters from config/model profiles. Accepts either a model profile map or a resolved config map and returns a keyword list suitable for `ReqLLM`.

## Constraints

- Schema modules must be pure functions with no side effects.
- Do not add I/O, GenServer, or process logic here.
- Schema definitions are the single source of truth for all config keys.

## Notes for Agents

`definitions.ex` is ~684 lines — this is legitimate because it's a comprehensive data table of all config keys. Do not attempt to split it.
