# Task Card Components — card contract & helper submodules

## Intent

The task card's data contract plus the helper families extracted from `task_card_components.ex`.
`EvoDashWeb.TaskCardComponents.task_card/1` renders from a 16-key task SUMMARY map and an optional lazily-fetched `detail`, and delegates the result/option/repo/archive/error rendering to the modules here, re-exported through `defdelegate`s on the parent module — call sites always use `EvoDashWeb.TaskCardComponents.<fun>`.

## Routing Table

- `./result_render.ex` → `render_result/1,2`, `render_result_full/1`, `result_copy_text/1`, `branch_badge_class/0`.
- `./options.ex` → `objective_text/1`, `render_options/1,2`, `render_options_full/1`.
- `./repos.ex` → `result_repos/1`, `task_repos/2`, `result_repos_badges/1`.
- `./archive.ex` → the `detail.archive` envelope readers (`archive_state/1`, `archive_records/1`, `archive_total/1`, `archive_agent_results/1`, `archive_loading_more?/1`, `archive_more_error/1`) + `archive_opt?/1`.
- `./errors.ex` → the structured failure-record readers `task_error/1` / `error_field/2`.

## Task Cards & the Summary-Map Contract

The sidebar "Active Tasks" section in `Layouts.app` is fed by `@running_tasks` / `@pending_tasks` — lightweight **summary maps** from the statuses-filtered `EvoGit.TaskRegistry.list_tasks_summary([:running, :pending, :finalizing, :completed])`. `layouts.ex` declares only those two attrs (there is NO `@tasks` attr; the dashboard renders no main task list).
The Tasks page renders `task_card/1` from the same summary maps and fetches the heavy payload per expanded card into a separate `detail` entry; Review is the only page that still loads full `%TaskInfo{}` structs directly.

### The summary-map contract

Plain maps with `EvoGit.Store.Operations.Summaries`' 16 keys: `id, status, review_status, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at, error`. `opts` is a decoded keyword list; `error` is the lenient atom-keyed failure record (nil unless `:failed`); `updated_at` is a raw ISO string. EXCLUDED: `result`, `logs`, `usage`, `archive_metadata` (and other TaskInfo fields such as `ref`).

### The `detail` attr — lazily-fetched heavy payload

`task_card/1` declares `attr(:detail, :map, default: nil)` next to `task`/`show_details`/`current_node_id`:
`nil` (nothing requested yet) or `%{state: :loading | :ok | :error, task: %EvoGit.TaskInfo{} | nil, error: term() | nil, seq: pos_integer(), archive: nil | %{state: :loading | :ok | :error, entries: [map()], total: non_neg_integer(), next_offset: non_neg_integer(), loading_more?: boolean(), more_error: term() | nil, error: term() | nil, seq: pos_integer(), agent_results: %{agent_id => %{state: :loading | :ok | :error, entry: map() | nil, error: term() | nil}}}`.
`archive.entries` holds only the pages read so far (every entry OMITS its `"result"`), `total` is the true archive size, and `agent_results` carries the lazily fetched full entries per agent id.
`task` is only meaningful when `state == :ok`; `error` only when `state == :error`.
The template binds `lite = detail.task` when `state == :ok` (else nil) and `archive = detail.archive` (else nil) once at the top, so no template path ever dot-accesses a nil `detail`.
`state: :loading`/nil with no `lite` renders the loading placeholder; `state: :error` renders the retry-able error strip; neither can crash the card.

### Field-access rules for task-card components

- **Dot access (`task.field`) is safe ONLY for contract keys** — on a plain map a missing key raises `KeyError`, on a struct it returns nil.
- **`Map.get(task, field)` is safe for any key** (nil when absent).
- **Heavy fields live on `detail.task` only**: `Map.get(lite, :result)`, `Map.get(lite, :usage)`, `Map.get(lite, :logs)`; the summary map is never read for them.
- **The structured failure record `error` stays on the summary** (`task_error(@task)` + `error_field/2`), so both the collapsed strip and the expanded block work before any detail arrives.
- **Sidebar grouping is deliberately TOTAL against non-map entries** — `group_tasks_by_project/2` filters `running_tasks ++ pending_tasks` to `is_map/1` entries BEFORE `Enum.group_by/3`, so a stray non-map element (the assigns shade `EvoDash.ActiveTasks` ETS snapshots) is omitted instead of crashing the page with `BadMapError`. Do NOT remove this filter.

### Task detail view — Objective / Agent Message cards (expanded card + zoom modals)

The expanded card detail view (`@show_details`, TasksLive only) shows two direct cards in a 2-column grid (no nested card level), each with a copy button and a "Full" button:

- **Objective card** (when an objective exists): header `gettext("Objective")` + copy (`id="task-<id>-objective-copy"`, `phx-hook="ClipboardCopy"`, `data-content={copy_payload(objective_text(@task.opts)).text}` + hint title) + "Full" (`view_full_options` → Full Objective modal). Body = `render_options(@task.opts)` — the CAPPED objective preview in a `max-h-48 overflow-y-auto` container (byte note when truncated) + mode/path badges. Reads the SUMMARY's `opts`, so it renders before any detail arrives.
- **Agent Message card** (only when `lite` is present and `Map.get(lite, :result)` is truthy — the grid cell is simply absent until then): header `gettext("Agent Message")` + copy (`id="task-<id>-result-copy"`) + "Full" (`view_full_result` → Full Result modal). Body = `render_result(Map.get(lite, :result))`, always a capped preview, preserving the commit_sha/branch_name/tag/pr_url badges, the No Changes notice and the Error/Crashed sub-headers.
- `render_options/2` takes `truncate:` (default `true` = in-card capped preview; `false` = the modal body, full text) — that keyword is the ONLY difference between the two render paths, so a new call site must choose deliberately. `render_options_full/1` and `render_result_full/1` are the `truncate: false` wrappers.
- Public helpers: `objective_text/1` (`(opts[:prompt] || opts[:objective] || "") |> String.trim()`, COMPLETE — shared with the collapsed preview, bounded only at render time) and `result_copy_text/1` (binary result → the string; `{:error, reason}`/`{:exit, reason}` → `inspect(reason, limit: :infinity)`; fallback → pretty inspect — COMPLETE, capped only by the caller's `copy_payload/1`). Both are reused by the zoom modals in `tasks_live.ex` (Full Result `id="full-result-copy"`, Full Objective `id="full-options-copy"`), whose bodies keep `max-h-[70vh] overflow-y-auto`. TasksLive owns the `"copied"` → "Copied to clipboard" flash handler.
- **Failed/error-result rendering**: `render_result({:error, reason}, …)` and `{:exit, reason}` inspect the reason (`limit: :infinity`) and preview the inspected STRING in a red "Error"/"Crashed" `<pre>` box (expanded card and Full Result modal alike); `result_copy_text/1` inspects the same way (test-pinned: `result_copy_text({:error, "boom"}) == ~s("boom")` — string reasons come out QUOTE-WRAPPED, atoms as `":killed"`). Any other term falls to the catch-all clauses, which pretty-inspect the whole term and then cap it.
- **Tuples never survive the Store Codec round trip**: `EvoGit.Store.Codec.encode_result({:error, reason})` stores `inspect(reason)` when `Jason.encode` fails on non-JSON-safe reasons, so `{:error, {128, "fatal: …"}}` arrives as `{:error, "{128, \"fatal: …\"}"}` and the render/copy inspect adds another quote layer — a machine-ish escaped dump. Consequence for core error-term design: persist a human-readable STRING as the reason.
- The structured failure record `error` (`%{kind:, source:, message:, stacktrace:}`, atom keys after `Codec.decode_error/1`, nil unless the task is `:failed`) is SEPARATE from the legacy `{:error,_}`/`{:exit,_}` result — both may coexist and both render: a compact strip on the COLLAPSED card (`truncate_string(error.message, 160)`, full message in `title`), and a full-detail block on the EXPANDED card (kind/source labels, full message, the LAST ≤8 frames). All reads go through `task_error/1` + `error_field/2` (atom/string-key tolerant, total for nil/non-map/legacy).

### Detail loading / error states (expanded card)

After the Objective/Agent Message grid the expanded card renders EXACTLY ONE of:

- `detail.state == :error` → an inline error-tinted strip `id="task-<id>-detail-error"` with `gettext("Could not load task details.")` and a Retry button (`phx-click="retry_task_detail"` + `phx-value-task_id`). Retry-able by construction — never an endless spinner.
- `lite == nil` (detail nil or `:loading`) → a compact placeholder `id="task-<id>-detail-loading"`: spinner + `gettext("Loading task details…")`.
- `lite` present → the heavy sections (Token & Cost Usage from `lite.usage`, Agents Spawned from the summary's `agent_count`/`model_id`, Execution Logs from `lite.logs`, lazy archive — next section).

### Lazy, paged archive disclosure (`load_task_archive` / `load_more_task_archive` / `load_task_archive_agent_result`)

The expanded card's archive section renders only when `lite` is present AND (`Keyword.get(@task.opts, :archive) in [true, "true"]` via `Archive.archive_opt?/1` (imported into the card module) OR the archive envelope has been fetched) — the summary map cannot tell whether records exist, so `opts[:archive]` is the opt-in signal.
Header row: `gettext("Archived Agent Details")` + a `phx-click="load_task_archive"` `phx-value-task_id` button (`gettext("Show archive")`) shown only while `archive == nil`.
Body states (`archive_state/1` + `archive_records/1` + `archive_total/1` + `archive_loading_more?/1` + `archive_more_error/1` + `archive_agent_results/1`, all TOTAL): `nil` → muted `gettext("The archive loads on demand.")` hint; `:loading` → spinner + `gettext("Loading archive…")`; `:error` → error-tinted strip `gettext("Could not load the task archive.")` + the same `load_task_archive` retry button; `:ok` with `entries == []` → `gettext("No archived agents for this task.")`; `:ok` with entries → `<EvoDashWeb.ArchiveComponents.archive_details archive_metadata={entries} total={archive_total(archive)} agent_results={archive_agent_results(archive)} loading_more?={archive_loading_more?(archive)} more_error={archive_more_error(archive)} task_id={@task.id} />`, which owns the count/range label, the "Load more" button (`load_more_task_archive`) and the per-agent "Show result" button (`load_task_archive_agent_result`).
The card never auto-fetches a page or a result: every fetch comes from one of those three clicks, and each agent's `result` is rendered capped once the LiveView folds it back into the envelope.

### Multi-repo `repos` result rendering (per-repo commit/branch)

Task results may carry a top-level `repos` map — STRING keys: `%{repo_id => %{"commit_sha" => sha, "branch_name" => branch | nil}}`; `"primary"` is ALWAYS present (nil branch = no primary changes), writable foreign repos with commits appear, read-only repos are ABSENT. The key stays STRING-keyed after the Codec round trip, so readers must handle atom and string keys.

- **`result_repos/1`** (public pure helper, in `task_card_components/repos.ex`) normalizes the result VALUE (accepts `{:ok, %{…}}` or the data map) into `[%{id:, commit_sha:, branch_name:}]` — `"primary"` first, foreign repos sorted by id. Returns `nil` for legacy / error / crash results and for maps without a usable `repos` map, so callers guard with `if repos = result_repos(...) do` and render NOTHING (legacy behavior byte-identical); non-map entries are dropped. It stays the source for the `render_result/2` paths.
- **`task_repos(task, detail)`** (public pure helper, TOTAL, in `task_card_components/repos.ex`) derives the COLLAPSED card's indicator from the SUMMARY: the primary entry comes from `task.commit_sha`/`task.branch_name`, foreign entries from `opts[:foreign_repos]` (structs or maps; `:id` string required, `"primary"` skipped, `:root`/`:path` + `:description` + `:writable` carried), and the detail result's `repos` map enriches them once loaded (a NON-nil detail `commit_sha`/`branch_name` overrides the summary value; detail-only repo ids are appended as badge-only entries). Returns `nil` unless the task is genuinely multi-repo (`foreign != []` or the detail carries more than the primary repo), so a single-repo card renders nothing. Ordered primary first, foreign sorted by id.
- **`result_repos_badges/1`** (component, `attr :repos` + `attr :size_class` default `"text-xs"`, in `task_card_components/repos.ex`, re-exported by `TaskCardComponents`) renders one compact badge row per repo: id + short sha (first 7 chars) + branch badge when present; a nil branch renders just the sha plus a muted `gettext("no changes")` hint for `"primary"` only (a foreign repo's nil branch means branch-creation failure, not no-changes).
- **Render sites**: the collapsed card's compact indicator row (hidden when `@show_details`) is fed by `task_repos(@task, @detail)`; a `gettext("Repositories")` section inside `render_result/2` (both the success-with-commit_sha and the `no_changes: true` clauses) and the Full Result modal keep using `result_repos/1` on the detail result value. TasksLive itself never reads `repos`.
- **Module layout note**: `task_card_components.ex` keeps the card TEMPLATE plus its bounded-preview helpers (`text_preview/2`, `log_preview/1`, `copy_payload/1`, `preview_limit_note/1`) — they exist because that template interpolates the payloads, so extend them in place. The result/option/repo/archive/error helper families live in the `task_card_components/` submodules (`ResultRender`, `Options`, `Repos`, `Archive`, `Errors`) and are re-exported through `defdelegate`s here.

### Task-card Review button candidacy

`show_review_button?/1` (private) decides whether the collapsed card's Review link renders. Candidacy is deliberately RESULT-AGNOSTIC: EVERY `:completed` or `:cancelled` task shows it, because a multi-repo task may have changed only writable FOREIGN repos — requiring a non-empty primary `branch_name` or a `no_changes: true` result would hide legitimate review candidates. The ONLY exclusion is `:reflect` (repo-less) tasks (their `type` is read defensively via `Map.get/2`); pending/running/finalizing/failed tasks never render it.

### Field-usage audit — conclusions

| Component / render path | Fields | Access |
|---|---|---|
| `Layouts.app` sidebar Active Tasks | `id`, `status`, `started_at`, `finished_at`, `opts`, `project_path` | dot on contract keys only (summary-safe) |
| `TaskCardComponents.task_card/1` | `type`, `opts`, `id`, `status`, `started_at`, `finished_at`, `agent_count`, `model_id`, `review_status`, `commit_sha`, `branch_name`; `error` | dot on contract keys; `error` only via `task_error/1` + `error_field/2` |
| `task_card/1` Agent Message / usage / logs / archive sections | `detail.task`'s `result`, `usage` (+ nested `usage.*`), `logs`; `detail.archive` via the `Archive` accessors (`entries`, `total`, `agent_results`, `loading_more?`, `more_error`) | `Map.get(lite, …)` + `not in [nil, []]` guards — hidden until the detail load lands |
| `render_result_full/1` | the result VALUE (`Map.get(lite, :result)`) from TasksLive's detail entry | TasksLive modal only |

- The ONLY dashboard-rendered task-list markup here is the sidebar Active Tasks section, which uses contract keys only — summary-safe.
- The card never fetches anything itself: `detail` (and its paged `archive`) is loaded by the owning LiveView, which also owns the `retry_task_detail` / `load_task_archive` / `load_more_task_archive` / `load_task_archive_agent_result` events.

## Render Cost — card-scoped

Every component here is a pure function component re-executed on EVERY LiveView render (nothing memoizes); the card's work is bounded by the caps below.

- `task_card/1` makes no `System.cmd`/`Port.open`/`File.*`/`GenServer.*`/`:erpc`/`EvoGit.*` calls at render time; the card is fed already-decoded maps/structs.
- COLLAPSED card: contract fields only, and it no longer receives any heavy field at all — its sole repo work is `task_repos(@task, @detail)` (a cheap walk of `opts[:foreign_repos]` plus, once loaded, the detail result's `repos` map). Per-card unconditional calls: `task_card_tint/1`, `task_accent_color/1`, `String.slice(id, 0, 8)`, `task_status_badge/1`, `objective_text/1` (interpolated TWICE — body + `title=` — so a long objective is HTML-escaped twice), `task_description/1` only when the objective is empty, `result_repos/1`, `task_error/1`, `relative_time/1`, and `show_review_button?/1` + `with_node_param/2` when reviewable.
- EXPANDED card: work is bounded by the caps (16 KiB text previews, 200 log rows, 1 MiB copy payloads, 300 archive records). Each preview is computed ONCE per render and reused — never recompute it per field or per branch (`agent_summary/1` feeds one preview to both the Markdown and Raw branches).
- `render_result_full/1` runs only in the TasksLive modal, never on the page render.
- A slow task-card page load is no longer explained by these components — the collapsed render is summary-only; the cost sits in the LiveView's paginated summary load and the per-card detail fetches (outside this node).

## Rendering Caps — task-card rows

`EvoDashWeb.Helpers.blob_preview/2` / `list_preview/2` are the single source of previews (see the parent `components/CONTEXT.md` → "Blob & Collection Rendering Caps").

| Site | Cap |
|---|---|
| `task_card_components.ex` in-card text (`@in_card_blob_limit`) | `16_384` bytes — the expanded Objective body and the Agent Message result, including the `{:error, _}` / `{:exit, _}` inspected reasons and the catch-all `inspect/2` path; note rendered by the shared `preview_limit_note/1` (defined in `task_card_components.ex`, called by the moved renderers) |
| `task_card_components.ex` logs (`@in_card_log_limit`) | the LAST `200` entries (`log_preview/1` = one reverse pass + `list_preview/2`, so no extra `length/1`); the summary badge comes from `log_summary_label/1` so it can never contradict the rendered rows ("last %{shown} of %{count}" above the cap, plain "%{count}" below it) |
| `task_card_components.ex` copy payloads (`@copy_payload_limit`) | `1_048_576` bytes — `data-content` IS materialized in the rendered HTML; `copy_payload_title/1` adds the hint title only when truncated |
| `archive_components.ex` archive tree (task-card path) | `300` records (`@max_agent_records`) per render; paging (100 per page) is the real archive bound, each record's `result` is `8_192` / `objective` `4_096` bytes |
