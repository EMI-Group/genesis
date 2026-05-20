# Controllers

## Intent
Classic Phoenix HTTP controllers and error handlers for the EvoDash web interface. These serve as fallback/classic HTTP endpoints — most of the application's interactive UI is handled by LiveViews in the sibling `live/` directory.

## API Surface

### Modules
- **`EvoDashWeb.PageController`** — Standard Phoenix controller with a single `home/2` action that renders the home page.
- **`EvoDashWeb.ErrorHTML`** — HTML error handler invoked by the endpoint. Defaults to returning plain-text status messages derived from template names (e.g., `"404.html"` → `"Not Found"`). Custom error page templates can be enabled by uncommenting `embed_templates "error_html/*"` and adding `.heex` files to an `error_html/` subdirectory.
- **`EvoDashWeb.ErrorJSON`** — JSON error handler returning `%{errors: %{detail: message}}`. Individual status codes can be customized by adding pattern-matched `render/2` clauses.
- **`EvoDashWeb.PageHTML`** — HTML template module that embeds all templates from `page_html/*` via `use EvoDashWeb, :html`.

### Templates
- **`page_html/home.html.heex`** — The default Phoenix welcome/home page template with links to docs, source, changelog, and community resources.

## Routing Table

This directory has no child subdirectories — all work is handled by the individual controller and error handler files within this directory (`page_controller.ex`, `error_html.ex`, `error_json.ex`, `page_html.ex`) and their template subdirectories. For any changes to HTTP controllers or error handlers, work directly on the relevant file in this node; no subagent delegation to child paths is needed.

## Constraints
- All modules use `EvoDashWeb` as the base web module (via `use EvoDashWeb, :controller` or `use EvoDashWeb, :html`).
- Controller modules follow the `{name}_controller.ex` naming convention; template modules follow `{name}_html.ex` with a matching `{name}_html/` template directory.
- Error handlers (`ErrorHTML`, `ErrorJSON`) are wired via the router/endpoint and must implement a `render/2` function keyed by template name.
- Keep this directory minimal — new interactive pages should generally be LiveViews in `../live/`, not controllers here.
