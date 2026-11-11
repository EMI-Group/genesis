# Controllers

## Intent
Classic Phoenix HTTP controllers and error handlers for the EvoDash web interface. These serve as fallback/classic HTTP endpoints — most of the application's interactive UI is handled by LiveViews in the sibling `live/` directory.

## Routing Table
- `page_html/` → Page HTML templates (home page welcome template)

## API Surface

### Routes Served Here
| Route | Handler | Purpose |
|-------|---------|---------|
| `GET /help` | `RedirectController :assistant` | 302 alias to the canonical `/assistant` page, raw query string preserved; a classic HTTP GET inside the `:browser` pipeline, not a LiveView. |
| `GET /tasks/:task_id/export` | `TaskExportController :export` | Streamed JSON download of a task's paged agent archive (`:browser` pipeline). |
| `GET /health` | `HealthController :index` | Unauthenticated liveness/readiness probe, mounted outside every pipeline. |
| `GET /server/status` | `ServerStatusController :index` | Unauthenticated operational probe, mounted outside every pipeline. |

The canonical Genesis Assistant page is the LiveView route `live("/assistant", HomeLive, :index)`; the controller layer owns only its legacy alias.

### Modules
- **`EvoDashWeb.PageController`** — Standard Phoenix controller with a single `home/2` action that renders the home page; it is NOT mounted (`router.ex` defines no route for it), so `page_html/home.html.heex` is unrouted scaffold markup.
- **`EvoDashWeb.ErrorHTML`** — HTML error handler invoked by the endpoint. Defaults to returning plain-text status messages derived from template names (e.g., `"404.html"` → `"Not Found"`). Custom error page templates can be enabled by uncommenting `embed_templates "error_html/*"` and adding `.heex` files to an `error_html/` subdirectory.
- **`EvoDashWeb.ErrorJSON`** — JSON error handler returning `%{errors: %{detail: message}}`. Individual status codes can be customized by adding pattern-matched `render/2` clauses.
- **`EvoDashWeb.PageHTML`** — HTML template module that embeds all templates from `page_html/*` via `use EvoDashWeb, :html`.
- **`EvoDashWeb.TaskExportController`** — JSON download endpoint for a task's agent archive (`GET /tasks/:task_id/export`); its read/stream/cleanup path is described in "Task Export Path" below.
- **`EvoDashWeb.RedirectController`** — legacy route aliases: its single `assistant/2` action 302-redirects `GET /help` to the canonical `/assistant` page while preserving the raw `conn.query_string`; described in "Legacy Alias Redirect Path" below.
- **`EvoDashWeb.HealthController`** — the unauthenticated `GET /health` liveness/readiness probe (mounted in the router OUTSIDE every pipeline: no session, no CSRF, no auth) answered by the headless server CLI (`genesis status`) and the desktop/remote shell; `index/2` renders `200` `application/json` `{"status":"ok","version":"<evo_dash vsn>","uptime_ms":<integer>}`. `uptime_ms` is the real elapsed VM time measured on the Erlang monotonic clock: `:erlang.system_info(:start_time)` is an INTEGER in the runtime's NATIVE time unit (not an epoch value, tuple or millisecond count), so it is subtracted from `:erlang.monotonic_time/0` and converted with `:erlang.convert_time_unit/3` — never mixed with a millisecond reading. Every value is read totally — an unreadable app version degrades to `"unknown"` and an unusable VM `start_time` to `0` — so the probe never raises.
- **`EvoDashWeb.ServerStatusController`** — the unauthenticated `GET /server/status` operational probe, mounted OUTSIDE every pipeline (no session, no CSRF, no auth) like `/health`; `index/2` renders `200` `application/json` `{"status":"ok","version":"<evo_git vsn>","active_tasks":<integer>}` where `active_tasks` is the number of `:running`/`:pending`/`:cancelling`/`:finalizing` task ids, and it exposes ONLY that COUNT (never task ids, titles or repo paths).
The BUSY set is exactly those four statuses, read from `@active_statuses = [:running, :pending, :cancelling, :finalizing]`: an idle `:awaiting_input` session holds no worker, no LLM/tool slot and no timer, so it is deliberately NOT busy (it is wind-down-able and the update gate may stop→swap→start over it), and its presence never turns the probe into an error.
- **Server-status degradation** — the task read resolves at CALL TIME from the `:evo_dash` app-env seam `:server_status_task_runner` (default `fn -> EvoGit.TaskRegistry.list_task_ids([:running, :pending, :cancelling, :finalizing]) end`) and runs inside `EvoDash.SafeCall.run/1`, so a raise, an exit/`GenServer.call` timeout, or a non-list answer becomes `active_tasks: -1` — never `0`, because the headless CLI's self-updater reads a negative count as "unknown" and only warns, whereas a wrong zero would let it stop→swap→start the server while tasks are still running; an unreadable version degrades to `"unknown"`.

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

### Legacy Alias Redirect Path (`EvoDashWeb.RedirectController`)
- **Route** — `get("/help", RedirectController, :assistant)` lives in the `:browser`-piped scope of `router.ex`, immediately after `live("/assistant", HomeLive, :index)`: it is an ordinary HTTP GET (session/flash/CSRF plugs, no LiveView mount, no socket).
- **Raw query preservation** — `assistant/2` reads `conn.query_string` verbatim (never decoded or re-encoded params), so `assistant_path("")` returns `"/assistant"` and any other value returns `"/assistant?" <> query_string`: `/help?session=7` → `/assistant?session=7` and `/help?node=abc` → `/assistant?node=abc`, keeping `?node=` targeting and `?session=` reattach working across the alias.
- **Status** — `redirect(conn, to: path)` answers `302` with a `location` header; no body is rendered, no flash is set and no page state is touched.

### Templates
- **`page_html/home.html.heex`** — The default Phoenix welcome/home page template with links to docs, source, changelog, and community resources.

## Constraints
- All modules use `EvoDashWeb` as the base web module (via `use EvoDashWeb, :controller` or `use EvoDashWeb, :html`).
- Controller modules follow the `{name}_controller.ex` naming convention; template modules follow `{name}_html.ex` with a matching `{name}_html/` template directory.
- Error handlers (`ErrorHTML`, `ErrorJSON`) are wired via the router/endpoint and must implement a `render/2` function keyed by template name.
- Keep this directory minimal — new interactive pages should generally be LiveViews in `../live/`, not controllers here.
