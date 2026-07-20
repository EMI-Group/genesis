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

## Constraints

- All component modules use `use EvoDashWeb, :html`.
- Styling is Tailwind CSS + DaisyUI.
- Components are pure functions — they receive assigns and return HEEx markup.
- Follows the project-wide `try/rescue` anti-pattern policy (no defensive rescuing of core runtime calls; whitelist `Map` lookups for atom conversion).
