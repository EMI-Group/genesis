# SettingsComponents — Sub-Components

## Intent

Sub-component modules extracted from `EvoDashWeb.SettingsComponents` to keep each component focused: `CategoryMetadata` (pure helpers for display names, icons, schema matching, API key hints), `SettingCard` (schema-driven form field component with type-dispatched input controls), `ModelProfilesEditor` (list editor for `[[llm.models]]` profiles with inline edit form), `CustomAgentsEditor` (list editor for `agents.toml` custom agents with inline edit form), `ModelSelectionEditor` (model-selection script editor with contract help + compile-error display), `Sidebar` (settings sidebar with search filter and category navigation), `SearchResults` (search results grouped by category).

## Routing Table

None — leaf directory (seven module files).

## API Surface

### Modules

| Module | Purpose |
|--------|---------|
| `CategoryMetadata` | Pure helper functions (display names, icons, schema matching, API key hints) |
| `SettingCard` | Schema-driven form field component with type-dispatched input controls |
| `ModelProfilesEditor` | List editor for `[[llm.models]]` profiles with inline edit form |
| `CustomAgentsEditor` | List editor for `agents.toml` custom agents (`custom_agents_editor/1`): rows with id/type/level/model badges + prompt preview, inline edit form (name, description, prompt, agent_type, delegation_level, model_id select, max_turns, tools/subagents checkboxes), delete with data-confirm |
| `ModelSelectionEditor` | Model-selection script editor (`model_selection_editor/1`): textarea form, collapsible contract help, copyable example, compile-error box, Test script results |
| `Sidebar` | Settings sidebar with search filter and category navigation |
| `SearchResults` | Search results grouped by category |

## Notes for Agents — Model Profiles Editor: Peak Hours (optional)

The profile edit form (`ModelProfilesEditor.model_profile_edit_form/1`, private) renders an optional **"Peak hours"** section directly under the concurrency field. Each `[[llm.models]]` profile may carry two OPTIONAL fields (absent/nil/empty = disabled; the parse side omits the keys from the profile map so TOML omits them):

- `peak_concurrency` — non-negative int, concurrency used during peak hours (`0` = hard pause — zero LLM slots during peak). `<input type="number" name="peak_concurrency" min="0">`; pre-filled via `profile_param/2` (atom-or-string key tolerant), blank (`""`) when absent.
- `peak_hours` — list of daily time-window maps `[%{start: "HH:MM", end: "HH:MM"}]`, 24h local time. Rendered as indexed rows of `<input type="time">` pairs named `peak_hours[<index>][start]` / `peak_hours[<index>][end]` (Phoenix parses these into the nested map the parse side consumes). Absent/`[]` → a single blank row so users can start adding.

Row events (both buttons `type="button"` so they never submit the form; handlers live in `live/settings_live/`, not in this module): `add_peak_hours_row` (`phx-click="add_peak_hours_row"`, no payload, appends an empty row server-side) and `remove_peak_hours_row` (`phx-click="remove_peak_hours_row"` + `phx-value-index={index}` on a per-row button). After add/remove the server re-renders the edit form pre-filled from file_config.

Pre-fill helpers (private, all nil-safe): `profile_peak_concurrency/1` (→ `""` when absent), `profile_peak_hours/1` (normalizes each window to `%{start: "", end: ""}` strings; single blank row fallback), `peak_window_value/2` (atom-or-string key tolerant), `normalize_peak_window/1`.

**Display gap**: the READ-ONLY profile row (`model_profile_row/1`) shows only the `concurrency` slots badge + generation-params summary (`profile_params_summary/1`) — peak fields (`peak_concurrency`, `peak_hours`, `timezone`) are NOT summarized, so a saved peak config is only visible by re-opening the Edit form. There is also NO dashboard surface anywhere showing the currently-effective concurrency or in/out-of-peak state (SystemLive charts only show the live aggregated `llm_capacity`); the Settings editor itself never misrepresents peak state because it never displays it.

**Display gap**: the READ-ONLY profile row (`model_profile_row/1`) shows only the `concurrency` slots badge + generation-params summary (`profile_params_summary/1`) — peak fields (`peak_concurrency`, `peak_hours`, `timezone`) are NOT summarized, so a saved peak config is only visible by re-opening the Edit form. There is also NO dashboard surface anywhere showing the currently-effective concurrency or in/out-of-peak state (SystemLive charts only show the live aggregated `llm_capacity`); the Settings editor itself never misrepresents peak state because it never displays it.

## Notes for Agents — `:list_of_strings` editor (SettingCard)
- `setting_card/1` renders `:list_of_strings` schemas (e.g. `[:sandbox, :write_paths]`) as a list editor: editable text inputs ALL named with the dotted key path (`sandbox.write_paths`) so repeated names submit as a list under one param key, plus per-entry remove buttons (`remove_list_entry` with `phx-value-key_path` + `phx-value-index`) and an "Add path" button (`add_list_entry` with `phx-value-key_path`). All editor buttons are `type="button"` so they never submit the enclosing `save_category`/`save_search` form.
- **Hidden-sentinel semantics (subtle — preserve):** when the value is a SET list (incl. `[]`), a hidden `type="hidden" name={key} value=""` input renders alongside the entry inputs, so a set-but-empty list always submits at least `[""]` → parses to `[]` and is STORED as `[]` (meaningful: replaces built-in defaults with nothing). An ABSENT param (nil/unset value) is the ONLY delete signal. When the value is nil, no sentinel renders — just the "Not set" hint + Add button. Non-list non-nil values normalize to a one-entry list so an invalid config.toml can't crash the render.
- Blank entries are filtered server-side (`ConfigIO.list_of_strings_value/1`) — a trailing empty "add" row never persists as `""`.
- `default_label/1` joins list defaults with `", "` and renders "(none)" for `[]`; nil → "empty".

## Notes for Agents — registering a NEW settings category
Adding a new top-level Settings sidebar category (e.g. a hypothetical "Appearance") requires touching BOTH sides:
- **Core schema map** (`:evo_git`): the category list shown in the sidebar is `EvoGit.Config.Schema.schemas_by_category/0` (all 93 schema maps in `apps/evo_git/lib/evo_git/config/schema/definitions.ex`, grouped by their `category:` key) PLUS the two dashboard-only pseudo-categories `:remote_connections`/`:agents` injected in `SettingsLive.mount/3` (settings_live.ex:677-678) with empty schema lists. A genuinely config-backed category is declared in `definitions.ex` with `category: :appearance` (additive-safe — category-count tests in `apps/evo_git/test/evo_git/config/schema_test.exs` pin counts PER CATEGORY, so adding a NEW category is safe; adding keys to an EXISTING category breaks the counts). A dashboard-only pseudo-category works too but must be special-cased in the `SettingsLive` render (settings_live.ex:162 `:remote_connections`, :580 `:agents`) and in `seed_category`/`category_str_to_atom` — NOT the generic `category_section` path.
- **Dashboard metadata** (`CategoryMetadata` in this directory): `category_display_name/1` (category_metadata.ex:19-33), `category_icon/1` (:35-48), and `category_description/1` (:52-92) have NO catch-all clause — a new category atom raises `FunctionClauseError` until a clause is added for each. `sort_categories/1` (category_metadata.ex:117-135) has an explicit `order` list (:118-132, missing categories sort last via `|| 99`); `category_match_count/3` (:137) is generic.
- **Enum/option rendering** (`SettingCard` in this directory): an enum schema (`type: :atom, validation: [in: [...]]`) renders as a plain `<select>` (setting_card.ex:121-136); `type: :string` + `validation: [in: [...]]` renders as a text input UNLESS special-cased (precedent: `[:llm, :reasoning_effort]` at setting_card.ex:50-69). A visual swatch picker therefore needs either a new key_path-based special case in `setting_card/1` or a `SettingCard` type branch. Form inputs are named `Enum.join(schema.key_path, ".")` (dotted, e.g. `appearance.accent`) — `ConfigIO.params_to_category_config/3` deep-walks exactly those dotted keys on save.
- **Save round-trip is fully generic** for a config-backed category: `save_category` (settings_live.ex:1004) → `ConfigIO.build_config_from_category_params/4` → `params_to_category_config/3` (config_io.ex:102; `:atom` values via `SettingsUtils.parse_atom/2` whitelisted to `validation[:in]`) → `EvoGit.Config.Schema.validate` → `EvoDash.NodeContext.save_user_config` → `EvoGit.Config.save_user_config/1`. Runtime push happens only for `category in [:scheduler, :llm]` (settings_live.ex:1065). ⚠️ Core gotcha for `:atom` enums: `EvoGit.Config.resolve/0` re-atomizes TOML-read string enums ONLY for hardcoded keys in `EvoGit.Config.atomize_enum_values/1` (config.ex:182-275) — a new `[:appearance, :accent]` :atom key would round-trip as a string with a warning unless a clause is added there; declaring the key `type: :string` + `validation: [in: [...]]` (the `[:llm, :reasoning_effort]` precedent) avoids the core change entirely.

## Constraints
- All component modules use `use EvoDashWeb, :html`.
- Styling is Tailwind CSS + DaisyUI.
- Components are pure functions — they receive assigns and return HEEx markup.
- Follows the project-wide `try/rescue` anti-pattern policy (no defensive rescuing of core runtime calls; whitelist `Map` lookups for atom conversion).
