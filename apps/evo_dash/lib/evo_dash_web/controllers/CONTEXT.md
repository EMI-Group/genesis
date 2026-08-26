# Controllers

## Intent
Classic Phoenix HTTP controllers and error handlers for the EvoDash web interface. These serve as fallback/classic HTTP endpoints — most of the application's interactive UI is handled by LiveViews in the sibling `live/` directory.

## Routing Table
- `page_html/` → Page HTML templates (home page welcome template)

## API Surface

### Modules
- **`EvoDashWeb.PageController`** — Standard Phoenix controller with a single `home/2` action that renders the home page.
- **`EvoDashWeb.ErrorHTML`** — HTML error handler invoked by the endpoint. Defaults to returning plain-text status messages derived from template names (e.g., `"404.html"` → `"Not Found"`). Custom error page templates can be enabled by uncommenting `embed_templates "error_html/*"` and adding `.heex` files to an `error_html/` subdirectory.
- **`EvoDashWeb.ErrorJSON`** — JSON error handler returning `%{errors: %{detail: message}}`. Individual status codes can be customized by adding pattern-matched `render/2` clauses.
- **`EvoDashWeb.PageHTML`** — HTML template module that embeds all templates from `page_html/*` via `use EvoDashWeb, :html`.
- **`EvoDashWeb.TaskExportController`** — JSON download endpoint for task archive metadata (`GET /tasks/:task_id/export`). **Node-aware**: a `?node=<id>` query param for a connected remote target resolves the task on the remote daemon via RPC (`resolve_remote_task/2` — mirrors `NodeAware.resolve_node_context/1`); missing/`"local"` params read the LOCAL store (historical behavior). Unknown targets, non-connected targets, missing tasks, and failed RPCs all resolve to nil → 404, exactly like the local not-found path. Envelope `%{task_id, task_type, repo_path, status, started_at, finished_at, agent_count, usage, archive_records}` normalized by `normalize_for_json/1` (structs→maps, DateTime→ISO8601, atoms→strings, tuples→lists, PID/ref/port/fun→`inspect/1` string) and sent as attachment `archive-<task_id>.json`; 404 when the task or archive data is missing.

### Templates
- **`page_html/home.html.heex`** — The default Phoenix welcome/home page template with links to docs, source, changelog, and community resources.

## Constraints
- All modules use `EvoDashWeb` as the base web module (via `use EvoDashWeb, :controller` or `use EvoDashWeb, :html`).
- Controller modules follow the `{name}_controller.ex` naming convention; template modules follow `{name}_html.ex` with a matching `{name}_html/` template directory.
- Error handlers (`ErrorHTML`, `ErrorJSON`) are wired via the router/endpoint and must implement a `render/2` function keyed by template name.
- Keep this directory minimal — new interactive pages should generally be LiveViews in `../live/`, not controllers here.
