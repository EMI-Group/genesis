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
- **`EvoDashWeb.TaskExportController`** — JSON download endpoint for a task's agent archive (`GET /tasks/:task_id/export`); its read/stream/cleanup path is described in "Task Export Path" below.

### Task Export Path (`EvoDashWeb.TaskExportController`)
- **Node-aware** — a `?node=<id>` query param for a CONNECTED remote target resolves to that BEAM node (`resolve_remote_node/1` — mirrors `NodeAware.resolve_node_context/1`) and runs BOTH reads there; a missing param or `?node=local` reads the LOCAL runtime (the historical path).
- Unknown targets, non-connected targets, missing tasks and failed task reads all resolve to the same 404 `"Task not found"` path as before.
- **Lite task read** — the task is read through `NodeContext.get_task_lite/2`, so the archive column is never loaded; the archive itself is paged.
- **Paged archive** — `NodeContext.list_task_archives(node, task_id, offset: …, limit: 200, include_results: true, include_settings: true)` from `offset: 0`, repeated until one of THREE hard stops: the accumulated record count reaches the page-reported `total`, a page comes back EMPTY, or a page comes back SHORT (`length(entries) < 200` — reads are offset/limit based, so a short page is the archive's last page; it is written and the loop stops, avoiding a needless RPC and making an endless loop impossible without a total).
- **A page without a usable `total` is accepted, not an error** — `fetch_page/3` takes `total` only when it is a non-negative integer and otherwise `nil` (a lean read that drops its COUNT(\*) must not truncate the export); every record of such a page is still written in full, and `{:ok, other}` (non-map / entries not a list) plus `{:error, reason}` pass through as before.
- **Full-fidelity projection** — the export is the ONE consumer that opts into the whole per-agent record: `fetch_page/3` passes `include_settings: true` (the export-only JSON columns `llm_settings` / `agent_settings` / `foreign_repos`) together with `include_results: true`, while the UI surfaces read the lean roster projection; `include_total` keeps its default (the paging loop stops early on the count).
- **Streamed document** — each entry is normalized (`normalize_for_json/1`: structs→maps, `DateTime`/`NaiveDateTime`→ISO‑8601, atom keys→strings, tuples→lists, pid/ref/port/fun→`inspect/1`) and encoded ONE AT A TIME into a temp file in `System.tmp_dir!()` named `archive-<task_id>-<unique_integer>.json`, written as `<head fields>,"archive_records":[<record>,<record>,…]}` — the whole archive is never built in memory.
- **Envelope (unchanged, FLAT)** — `task_id, task_type, repo_path, status, started_at, finished_at, agent_count, usage, archive_records` (the head fields are the same set, minus the streamed `archive_records`); every head field is read TOTALLY from the LITE row (`Map.get/2`, plus `option/2` for `opts`, which a degraded row may hand over as nil), so a missing/nil field becomes JSON `null` instead of a raise.
- **Send + cleanup** — `send_download(conn, {:file, path}, filename: "archive-<task_id>.json", content_type: "application/json")`, with `File.rm(path)` in an `after` block: the adapter has already written the response body when `send_download/3` returns (`conn.state == :sent`), and `after` also covers raise paths, so no temp file is ever left behind.
- **Status codes** — missing task → 404 `"Task not found"`; empty archive (first page empty) → 404 `"No archive data available for this task"`; temp-file/encode failure → 500 `"Archive export failed"`.
- **Degradation** — every core read runs inside `EvoDash.SafeCall.run/1`, so a dead store/RPC cannot kill the controller: a failed task read becomes the 404 not-found path, and a failed PAGE stops the paging loop while keeping the records already written (a valid, truncated document); with nothing accumulated that becomes the empty-archive 404.
- **Test seams** — both reads resolve at call time from the `:evo_dash` app env: `:task_export_task_runner` (2-arity `fn node, task_id -> … end`, default `&EvoDash.NodeContext.get_task_lite/2`) and `:task_export_archive_runner` (3-arity `fn node, task_id, opts -> … end`, default `&EvoDash.NodeContext.list_task_archives/3`).

### Templates
- **`page_html/home.html.heex`** — The default Phoenix welcome/home page template with links to docs, source, changelog, and community resources.

## Constraints
- All modules use `EvoDashWeb` as the base web module (via `use EvoDashWeb, :controller` or `use EvoDashWeb, :html`).
- Controller modules follow the `{name}_controller.ex` naming convention; template modules follow `{name}_html.ex` with a matching `{name}_html/` template directory.
- Error handlers (`ErrorHTML`, `ErrorJSON`) are wired via the router/endpoint and must implement a `render/2` function keyed by template name.
- Keep this directory minimal — new interactive pages should generally be LiveViews in `../live/`, not controllers here.
