# AgentsLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.AgentsLive` to keep the main LiveView module and its companion template focused on rendering and lifecycle callbacks.

## API Surface

| Module | Purpose |
|--------|---------|
| `ToolCallDisplay` | Pure rendering contract for tool-call messages in the chat history viewer (inline detail panel + full-message modal). `display/1` returns `%{label, kind: :structured, rows}` for subagent (`subagent_*` prefix) and shell (`run_bash`/`run_powershell`) calls — key/value rows (path + truncated objective / truncated command) — or `%{label, kind: :inline, summary}` for all other calls (compact one-line arguments summary, truncated to 160 chars). Both forms are height-constrained by the template: structured blocks render in a `max-h` + `overflow-y-auto` container, inline summaries are one line with CSS ellipsis. Raw arguments JSON is never dumped for subagent/shell calls. |

## Constraints

- Pure functions — no I/O, no socket, no process calls.
- No `try/rescue` — defensive extraction + pattern matching/`case` only (project-wide anti-pattern policy).
- Reuses `EvoDashWeb.Helpers` defensive extraction (`tool_call_name/1`, `tool_call_arguments/1`, `tool_call_is_shell?/1`) — do not reimplement; `EvoDashWeb.Helpers.tool_call_display/1` is no longer used by the Agents page but stays as a public, test-pinned helper (do not remove it).
- New user-facing strings use `gettext` (backend `EvoDashWeb.Gettext`); `Path`/`Objective`/`Command` entries appear in the POT/PO at release-time extraction only — do not run `mix gettext.extract`/`merge`/`translate` during development.
