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

## Known Issues

- **⚠️ `[:sandbox, :write_paths]` type machinery is INCOMPLETE (needs parent-node change).** The definition was added to `definitions.ex` (type `:list_of_strings`, `default: nil`, `sub_category: nil`) but `EvoGit.Config.Schema.type_errors/3` — which lives in the PARENT node file `../schema.ex` — has NO clause for `:list_of_strings` and no catch-all clause. Consequences: (1) any non-nil value for the key (including `[]`) raises `FunctionClauseError` inside `Schema.validate/1`, crashing `EvoGit.Config.resolve/0` — violating the crash-resilience constraint; (2) the `@type schema_type` union (`schema.ex:44`) doesn't list the new type. **Required fix (parent node's scope):** add `defp type_errors(key_path, :list_of_strings, value)` (list where every element `is_binary/1` → `[]`, else error "must be a list of strings") + extend the union. Unset (nil) path works today: `resolve([:sandbox, :write_paths])` → `nil`, and `Schema.defaults/0` contains the key as nil. `EvoGit.Config.defaults/0` delegates to `Schema.defaults/0` and `atomize_enum_values` in `../config.ex` does NOT touch the key — no registration needed anywhere else.
- **Schema-count tests pin the old numbers** (`apps/evo_git/test/evo_git/config/schema_test.exs`): `"all_schemas/0 has exactly 65 schemas"` (:108) and `"each category has expected count"` (:231, `grouped[:sandbox]` 17 → now 18). These need updating once the wave lands — they are test files (sibling node, edit only via the parent).

## Notes for Agents

`definitions.ex` is ~694 lines — this is legitimate because it's a comprehensive data table of all config keys. Do not attempt to split it.

`EvoGit.Config.Schema` (validate + defaults + typespecs) lives in the PARENT node file `../schema.ex` — schema definitions here and the type-checking machinery there must stay in sync. New types require both a definition here AND a `type_errors/3` clause + `@type schema_type` union entry in the parent file.
