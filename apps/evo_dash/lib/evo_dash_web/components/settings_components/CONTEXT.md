# SettingsComponents — Sub-Components

## Intent

Sub-component modules extracted from `EvoDashWeb.SettingsComponents` to keep each component focused: `CategoryMetadata` (pure helpers for display names, icons, schema matching, API key hints), `SettingCard` (schema-driven form field component with type-dispatched input controls), `ModelProfilesEditor` (list editor for `[[llm.models]]` profiles with inline edit form), `Sidebar` (settings sidebar with search filter and category navigation), `SearchResults` (search results grouped by category).

## Routing Table

None — leaf directory (five module files).

## API Surface

### Modules

| Module | Purpose |
|--------|---------|
| `CategoryMetadata` | Pure helper functions (display names, icons, schema matching, API key hints) |
| `SettingCard` | Schema-driven form field component with type-dispatched input controls |
| `ModelProfilesEditor` | List editor for `[[llm.models]]` profiles with inline edit form |
| `Sidebar` | Settings sidebar with search filter and category navigation |
| `SearchResults` | Search results grouped by category |

## Notes for Agents — `:list_of_strings` editor (SettingCard, commit `0ff33d39`)
- `setting_card/1` renders `:list_of_strings` schemas (e.g. `[:sandbox, :write_paths]`) as a list editor: editable text inputs ALL named with the dotted key path (`sandbox.write_paths`) so repeated names submit as a list under one param key, plus per-entry remove buttons (`remove_list_entry` with `phx-value-key_path` + `phx-value-index`) and an "Add path" button (`add_list_entry` with `phx-value-key_path`). All editor buttons are `type="button"` so they never submit the enclosing `save_category`/`save_search` form.
- **Hidden-sentinel semantics (subtle — preserve):** when the value is a SET list (incl. `[]`), a hidden `type="hidden" name={key} value=""` input renders alongside the entry inputs, so a set-but-empty list always submits at least `[""]` → parses to `[]` and is STORED as `[]` (meaningful: replaces built-in defaults with nothing). An ABSENT param (nil/unset value) is the ONLY delete signal. When the value is nil, no sentinel renders — just the "Not set" hint + Add button. Non-list non-nil values normalize to a one-entry list so an invalid config.toml can't crash the render.
- Blank entries are filtered server-side (`ConfigIO.list_of_strings_value/1`) — a trailing empty "add" row never persists as `""`.
- `default_label/1` joins list defaults with `", "` and renders "(none)" for `[]`; nil → "empty" (unchanged).

## Constraints

- All component modules use `use EvoDashWeb, :html`.
- Styling is Tailwind CSS + DaisyUI.
- Components are pure functions — they receive assigns and return HEEx markup.
- Follows the project-wide `try/rescue` anti-pattern policy (no defensive rescuing of core runtime calls; whitelist `Map` lookups for atom conversion).
