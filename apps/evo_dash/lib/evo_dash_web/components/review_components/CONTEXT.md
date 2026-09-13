# ReviewComponents — Sub-Components

## Intent

Sub-component modules of the code review page (GitHub-PR-inspired, Adwaita-styled design): `DiffViewer` (split diff rendering with client-side syntax highlighting, file-tree sidebar, split/commit two-pane layouts), `Header` (compact page header, agent report card, objective card, task-details disclosure), `RepoCards` (one card per repository — per-repo merge/reject controls, per-repo merge-check strip, per-repo resolution state — plus the optional review-completion banner), `Actions` (primary-scoped task-level actions row — Continue task + overflow menu — plus the skills-extraction modal), `Stats` (diff stat row, commits list). The parent facade `EvoDashWeb.ReviewComponents` (`../review_components.ex`) delegates to these five and locally owns the page-level tab bar (`page_tabs/1`) and the archive tree (`archive_review_section/1`).

## Routing Table

None — leaf directory (five module files: `diff_viewer.ex`, `header.ex`, `repo_cards.ex`, `actions.ex`, `stats.ex`).

## API Surface

All components are function components (`use EvoDashWeb, :html`) invoked through the facade `EvoDashWeb.ReviewComponents.<name>`. They are purely presentational: the hosting LiveView (`ReviewLive`) owns the state assigns and handles every event they fire, doing the actual data fetches.

### Facade-owned components (`../review_components.ex`)

#### `page_tabs/1` — GitHub-style underline tab bar

Attrs: `active_tab` (`:atom`, **required**), `files_count` (`:integer`, default `0`), `commits_count` (`:integer`, default `0`), `show_archive` (`:boolean`, default `false`), `agents_count` (`:integer`, default `0`).

Renders up to five tabs — Conversation (`hero-chat-bubble-left-right`), Objective (`hero-chat-bubble-bottom-center-text`, **no count badge**, always rendered), Files changed (`hero-code-bracket`, count badge), Commits (`hero-clock`, count badge), Archive (`hero-archive-box-arrow-down`, gated on `show_archive`, agents-count badge) — in a horizontally scrollable `border-b-2` underline bar (active tab = `border-primary-standalone` + semibold; inactive = transparent border, `/70` text with hover). Events: **`switch_tab`** with `phx-value-tab` ∈ `"conversation" | "objective" | "files_changed" | "commits" | "archive"` (one `<button>` per tab). The Objective tab hosts `objective_section/1` (own readability column on the page); placement is owned by ReviewLive.

#### `archive_review_section/1` + `archive_tree_node/1` — archived agent tree

`archive_review_section/1`: `archive_metadata` (`:list`, **required**), `task_id` (`:string`, default `nil`). Builds the tree via `EvoDash.ArchiveHelpers.build_archive_tree_for_review/1`; header carries an "Export JSON" download link to `/tasks/<task_id>/export` (only when `task_id` present). `archive_tree_node/1` (public, recursive): `agent` (`:map`, **required**), `children` (`:list`, default `[]`). Per-agent keys read with `@agent[:key]` access: `agent_id`, `depth`, `started_at`, `objective`, `result`, `base_commit`, `final_commit` (both sliced `0..7`), `archive_ref_start`, `archive_ref_final`, `usage[:input_tokens|:output_tokens|:total_tokens|:total_cost]`, `completed_at` — records arrive atom-keyed because `ArchiveHelpers.build_archive_tree_for_review/1` normalizes every record via `normalize_agent_keys/1` (top-level keys AND the nested `usage` sub-map). Children render nested under a `border-l-2 border-base-300/80` trunk.

#### Facade delegate list

`page_header`, `task_summary`, `agent_summary`, `objective_section` → `Header`; `repo_cards` → `RepoCards`; `task_actions`, `extract_skills_modal`, `conflict_files_summary/1` (function, not component) → `Actions`; `diff_stats_bar`, `commits_list` → `Stats`; `file_tree_sidebar`, `diff_viewer`, `split_diff_layout`, `commit_detail_header`, `commit_diff_layout` → `DiffViewer`.

### `RepoCards` (`repo_cards.ex`)

#### `repo_cards/1` — one card per repository

Attrs: `repos` (`:list`, **required**), `completion` (`:atom`, default `nil` — `nil | :merged | :rejected`), `back_url` (`:string`, default `nil`).

Root markup: `<div id="review-repo-cards" class="space-y-4">`. When `completion != nil` its FIRST child is the completion banner `<div id="review-completion-banner">` — success tint (`border-success/30 bg-success/10`) for `:merged`, error tint (`border-error/30 bg-error/10`) for `:rejected` — carrying a check/x icon, a one-line status ("All repositories merged." / "All repositories rejected."), and the "Back to Projects" action `<.link navigate={@back_url} id="review-completion-back">`. Then ONE CARD PER REPO, in `repos` order (primary first).

Each card root is `<div id={"repo-card-" <> repo_id}>` (`rounded-xl border border-base-300 bg-base-100`), with a `bg-base-200/30` header strip (`border-b border-base-300`) containing: the repo id (the `"primary"` entry renders the "Primary repository" label; every other entry renders its id in mono) + the truncated repo path (`title` attr holds the full path), the branch name (mono `badge badge-sm`, hidden when nil), the card's resolution badge `<span id={"repo-resolution-" <> repo_id}>` (empty until resolved; see the state machine), that repo's diff stat read DEFENSIVELY from `repo.review_data` (`+total_additions −total_deletions` + an `ngettext` file count; renders NOTHING when `review_data` is nil), and the jump-to-diff button (`phx-click="open_repo_diff"` + `phx-value-repo_id={repo_id}`, `hero-code-bracket`).

Every repo field is read defensively via `field/3` (atom key → string key → default) so both atom- and string-keyed repo maps render; the diff-stat numbers go through `review_stat/2` (same fallback, default `0`).

#### Resolution state machine

Each card is driven off `repo.resolution` (`nil | %{state: :merged, target: t} | %{state: :rejected} | %{state: :handled} | %{state: :error, detail: d} | %{state: :conflict, detail: d}`; `t` a String or nil, `d` a String) plus `repo.branch_exists`. TERMINAL = `:merged | :rejected | :handled`; NON-TERMINAL = `nil | :error | :conflict`.

1. TERMINAL → resolved/inert: the outcome shows in the resolution badge (`gettext("Merged into %{target}", target: t)` when a target is present, else `gettext("Merged")`; `gettext("Rejected")`; `gettext("Already handled")`) and the card body is a one-line check + outcome — NO merge/reject actions.
2. NON-TERMINAL (`:error` / `:conflict`) → the `detail` renders in a tinted strip (`border-error/20 bg-error/10 text-error` for `:error`, `border-warning/20 bg-warning/10 text-warning` for `:conflict` — FULL semantic text token, never `-content` on a tint) AND the merge/reject actions stay available (retry).
3. `resolution == nil && branch_exists` → normal: the per-repo merge-check strip (rendered when `repo.merge_status != nil`) + the target select + Merge + Reject.
4. `resolution == nil && !branch_exists` → informational only, NO actions: a nil `branch_name` renders the info tint with "The agent completed without making any code changes. You can resume from this investigation or dismiss it.", otherwise the warning tint with "This branch no longer exists.".

#### Per-repo actions row

Rendered in states 2 and 3: a `flex flex-wrap items-center gap-3` row holding the per-repo merge form and a SIBLING Reject button (not inside the form).

- Merge form (when `repo.merge_targets != []`): `<form id={"merge-form-" <> repo_id} phx-submit="merge" phx-change="merge_target_change" class="contents">` — `class="contents"` keeps its children flowing inline in the actions row, and a form-less input-level `phx-change` never delivers its event (LiveView's pushInput throws "form events require the input to be inside a form"). It contains a hidden `<input type="hidden" name="repo_id" value={repo_id}/>`, a "Merge into" label, and `<select name="target_branch" phx-value-repo_id={repo_id}>` — options from `repo.merge_targets`, `selected` on `target = repo.default_merge_target || List.first(repo.merge_targets)` — plus the `btn btn-success btn-sm rounded-lg gap-1.5` submit Merge button (`hero-check`, `phx-confirm` naming the target). It carries NO `disabled` attr (there is no per-repo loading flag).
- Form-less Merge fallback (when `repo.merge_targets == []`): a `<button class="btn btn-success btn-sm rounded-lg gap-1.5" phx-click="merge" phx-value-repo_id={repo_id} phx-confirm={gettext("Merge these changes into the current branch?")}>` with `hero-check` + "Merge".
- Reject: `btn btn-outline btn-error btn-sm rounded-lg gap-1.5` + `hero-x-mark`, `phx-click="reject"` + `phx-value-repo_id={repo_id}` + `phx-confirm` ("…This cannot be undone.").

#### `merge_status_block/1` — private

Attrs: `status` (`:map`, required). `%{state: :checking}` → spinner + "Checking if merge is clean…"; `%{state: :clean}` → green success strip "Merge check passed — clean merge."; `%{state: :conflict, files: files}` → amber strip with the `ngettext` "Merge conflict detected in %{count} files: %{files}" (files via the public `EvoDashWeb.ReviewComponents.Actions.conflict_files_summary/1`) + the PRIMARY-scoped **`auto_resolve`** button (`btn-warning`, `phx-click="auto_resolve"`, NO `repo_id`, `phx-confirm` explaining the new merge-agent task); any other shape (incl. `state: :error`) → the `_ ->` catch-all renders NOTHING. `merge_status.target` is NOT read by the component (the LiveView uses it for the merge call). Wrapped in a `rounded-lg border border-base-300 bg-base-200/30 p-3` well by its caller.

#### Element ids emitted by this subtree

`review-repo-cards`, `review-completion-banner`, `review-completion-back`, `repo-card-<repo_id>`, `repo-resolution-<repo_id>`, `merge-form-<repo_id>`.

### `Actions` (`actions.ex`)

#### `task_actions/1` — primary-scoped task-level actions row

Attrs: `can_resume` (`:boolean`, default `false`), `loading` (`:boolean`, default `false`), `branch_exists` (`:boolean`, default `true`), `has_pr` (`:boolean`, default `false`), `pr_url` (`:string`, default `nil`), `show_export` (`:boolean`, default `false`), `export_url` (`:string`, default `nil`).

One `rounded-xl border border-base-300 bg-base-100 p-4 flex flex-wrap items-center gap-3` row holding the **Continue task** button — only when `@can_resume` — and the "…" overflow menu (which carries `ml-auto` and is therefore pinned to the row's right edge as its last child).

**`continue_task_button/1`** (private): soft filled (`btn btn-sm rounded-lg gap-1.5 bg-base-200/60 hover:bg-base-200 border-0` — NO outline ring, consistent with the page's ghost-chip language), `hero-arrow-path`, fires **`resume`**.

**`overflow_menu/1`** (private): a native `<details class="dropdown dropdown-end dropdown-top ml-auto">` "…" menu. The row sits near the bottom of the conversation column, so `dropdown-top` opens the menu UPWARD (above the trigger) so it is never clipped below the browser window. Entries: Create GitHub PR (`phx-click="create_pr"`) when `@branch_exists and not @has_pr`; View PR as a plain `<a href={@pr_url} target="_blank">` when `@branch_exists and @has_pr and @pr_url`; Extract Skills (`phx-click="extract_skills"`) when `@branch_exists`; Export JSON as a plain download `<a href={@export_url} download>` when `@show_export`; Ignore renders LAST as a neutral (`rounded-md`) plain menu item — always available as the escape hatch for orphaned/deleted branches, keeping its `phx-confirm`. The `@branch_exists` gate stays because it gates Create-View PR / Extract Skills. Reject is NOT in this menu (it is per-repo, in `RepoCards`); there is no "Danger zone" divider. The `dropdown-content` (`z-50`) paints **outside** the card (the `task_actions` wrapper carries no `overflow-hidden`).

#### `conflict_files_summary/1` — public helper

First ~4 conflicting file names joined with `", "`, with a trailing `"…"` when more exist. Public (delegated from the facade) so `RepoCards.merge_status_block/1` can reuse it.

#### `extract_skills_modal/1`

Attrs: `show` (`:boolean`, default `false`) — the only attr; renders nothing when false. Fixed overlay + backdrop (`bg-black/50 backdrop-blur-sm`) + modal card with an academic-cap tile, explanatory copy, and a `<.form phx-submit="confirm_extract_skills">` carrying a `user_note` textarea. Events: **`confirm_extract_skills`** (form submit, param `user_note`), **`cancel_extract_skills`** (backdrop click + Cancel button).

### `Header` (`header.ex`)

#### `page_header/1` — compact page header

Attrs: `back_url` (`:string`, **required**), `title` (`:string`, **required**), `status` (`:atom`, default `:open` — review status), `task_status` (`:atom`, default `nil`), `task_type` (`:atom`, default `nil`), `task_id` (`:string`, default `nil`), `repo_path` (`:string`, default `nil`), `branch_name` (`:string`, default `nil`), `merge_target` (`:string`, default `nil`), `commit_sha` (`:string`, default `nil`), `model_id` (`:string`, default `nil`), `agent_count` (`:integer`, default `nil`), `started_at` (`:any`, default `nil`), `finished_at` (`:any`, default `nil`), `stats` (`:map`, default `nil`).

Three rows in one `rounded-xl` card: (1) back link (`<.link navigate>` ghost square, title/aria "Back to projects") + one-line truncated `h1` rendering `short_title(@title)` (full title in the `title` attr) + review-status badge (`Helpers.review_status_badge/icon/label`) + optional task-status badge (`Helpers.task_status_badge`, capitalized label); (2) a wrapping meta line — repo path (folder icon, mono, truncated), branch chip (mono on `bg-base-200`, `max-w-[16rem]` truncated), a `branch → merge_target` arrow, then the merge-target chip boxed in the same style as the branch chip (`font-mono bg-base-200 rounded-md px-1.5 py-0.5`, `max-w-[16rem]` truncated), capitalized task type, mono `task_id`, mono `model_id`, agent count (`format_number`), `relative_time(started_at)` [→ `relative_time(finished_at)`]. **Vertical rhythm**: every text span in the row carries `leading-none` so the boxed chips (symmetric `py-0.5`) and the bare spans center on one optical line; machine-ish values (path/branch/sha/task_id/model_id/merge_target) are `font-mono`, only the human words (task-type label, relative times) stay sans; (3) when `stats` present, a GitHub-style diff-stat row reading `commits_count`/`files_count`/`additions`/`deletions` with **atom-OR-string key fallback** (`Map.get(@stats, :k, Map.get(@stats, "k", 0))`) — `ngettext` commits, "%{count} files changed", green `+adds`, red `-dels`. Fires no events.

#### `short_title/1` — public helper

`@spec short_title(nil | String.t()) :: nil | String.t()`. First line of the title, trimmed, truncated to 100 chars with a trailing `…` when longer; `nil` passes through unchanged.

#### `agent_summary/1` — the agent's final message as a comment-style card

Attrs: `summary` (`:string`, **required**), `summary_raw` (`:boolean`, default `false`), `model_id` (`:string`, default `nil`), `finished_at` (`:any`, default `nil`).

Header strip: sparkles icon tile + "Agent Report" label + (sm+) mono `model_id` and mono `relative_time(finished_at)` (both `font-mono leading-none` so they share one optical line) + a `join` Markdown/Raw toggle + a copy button (`id="summary-copy-btn"`, `phx-hook="ClipboardCopy"`, `data-content={@summary}`). Events: **`toggle_summary_view`** with `phx-value-mode` ∈ `"markdown" | "raw"` (two join-item buttons; the active one gets `btn-active btn-primary`). Body: `summary_raw` → a single-line `<pre class="… whitespace-pre-wrap …">` (⚠️ the `<pre>` must stay single-line — a formatter-wrapped leading indent renders as visible text); markdown → `raw(EvoDash.MarkdownRender.render(@summary))` inside `.md-content`.

#### `objective_section/1` — the task's original objective card (Objective tab)

Attrs: `objective` (`:string`, default `nil`), `objective_raw` (`:boolean`, default `false`).

Same card shell + header contract as `agent_summary`: `rounded-xl border border-base-300 bg-base-100 overflow-hidden`, header strip (`bg-base-200/40`) with a `hero-chat-bubble-bottom-center-text` icon tile + "Objective" label, then `ml-auto` controls — a `join` Markdown/Raw toggle and a copy button (`id="objective-copy-btn"`, `phx-hook="ClipboardCopy"`, `data-content={@objective}`). Events: **`toggle_objective_view`** with `phx-value-mode` ∈ `"markdown" | "raw"` (two join-item buttons; the active one gets `btn-active btn-primary`). Body: markdown (default) → `raw(EvoDash.MarkdownRender.render/1)` inside `.md-content` within a `max-h-[32rem] overflow-y-auto` scroll container (objectives can be long); raw → the single-line `<pre class="… whitespace-pre-wrap …">` (⚠️ same gotcha as `agent_summary`: the `<pre>` must stay single-line). **Empty state**: when `objective` is `nil` or `""` (LoadData normalizes a missing objective to `""`), the body renders a `hero-chat-bubble-bottom-center-text` icon + "No objective recorded for this task." and the header controls are hidden — the card (and its tab) still render. The tab itself is always shown; placement (own readability column, off the conversation pane) is owned by ReviewLive.

#### `task_summary/1` — native `<details>` disclosure

Attrs: `usage` (`:map`, default `nil`), `agent_count` (`:integer`, default `nil`), `task_type` (`:atom`, default `nil`), `status` (`:atom`, default `nil` — the TASK status), `model_id` (`:string`, default `nil`), `started_at` (`:any`, default `nil`), `finished_at` (`:any`, default `nil`).

A native `<details class="group …">` with a `<summary>` ("Task Details", info icon, chevron that rotates via `group-open:rotate-180`; webkit marker hidden) — zero-JS disclosure. Content: a definition list (`Status` badge via `Helpers.task_status_badge`, `Type`, `Model`, `Agents` via `format_number`, `Started`/`Finished` via `relative_time`), then — gated on `@usage` — the full "Token & Cost Usage" breakdown read **only via `Map.get`** (atom keys): `input_tokens`, `output_tokens`, `total_tokens`; a cache sub-list gated on `cached_tokens > 0 or cache_creation_tokens > 0` showing `cached_tokens`, `cache_creation_tokens`, and "Cache Hit Rate" (`Helpers.format_cache_hit_rate/1` + an inline-computed `progress progress-success` bar, `min(round(cached/input*100), 100)`); then costs `input_cost`/`output_cost`/`total_cost` (`Helpers.format_cost/1`, total in `text-primary-standalone`). Fires no events.

### `Stats` (`stats.ex`)

#### `diff_stats_bar/1`

Attrs: `files_count` (`:integer`, **required**), `additions` (`:integer`, **required**), `deletions` (`:integer`, **required**), `commits_count` (`:integer`, default `0`). One wrapping row: clock icon + `ngettext` commits, document icon + "%{count} files changed", green `+additions`, red `-deletions`. Fires no events.

#### `commits_list/1`

Attrs: `commits` (`:list`, **required**), `repos` (`:list`, default `[]`), `active_repo_id` (`:string`, default `"primary"`). An optional multi-repo toolbar renders ABOVE the card (only when `length(@repos) > 1`): rectangle-stack icon + gettext "Repository" + `<select name="repo_id">` wrapped in its own `<form id="commits-repo-switch-form" phx-change="switch_repo">` — the form wrapper is mandatory, a form-less `<select phx-change>` never delivers its event (LiveView JS pushInput throws "form events require the input to be inside a form"); options labeled via the public `EvoDashWeb.ReviewComponents.DiffViewer.repo_option_label/1`, `selected` on `active_repo_id`; fires **`switch_repo`** (owned by the hosting LiveView). Card with a count header (`ngettext` over `length(@commits)`) and one full-width `<button>` row per commit firing **`inspect_commit`** with `phx-value-sha={commit.sha}`. Per `%EvoGit.Review.CommitInfo{}` reads: `short_sha` (mono soft chip `badge badge-sm bg-base-200 border-0` — matches the header chip language and the `page_tabs` count badges, NO outline ring), `message` (truncated text + `title`), `author_name` (hidden below `sm`), `date` (`relative_time`); trailing chevron.

### `DiffViewer` (`diff_viewer.ex`)

#### `file_tree_sidebar/1`

Attrs: `files` (`:list`, **required**), `selected_file` (`:string`, default `nil`), `expanded_dirs` (`:map`, default `%{}`), `file_filter` (`:string`, default `""`).

Sticky sidebar (`w-full lg:w-72 shrink-0 lg:sticky lg:top-0 lg:max-h-[100dvh] overflow-y-auto`). Header: "Files changed" title + file count; filter input (`name="filter"`, **`filter_files`**, `phx-debounce="200"`); **`collapse_all_dirs`** / **`expand_all_dirs`** ghost buttons. Body: see "Server-driven tree state" below. File rows (`file_row/1`, private, shared by tree file-nodes and the flat filtered list) fire **`select_file`** with `phx-value-path` and highlight via `selected_file` (`bg-primary/10 text-primary-standalone`).

#### `diff_viewer/1`

Attrs: `files` (`:list`, **required**), `expanded_files` (`:map`, default `%{}`), `selected_file` (`:string`, default `nil`), `file_context_levels` (`:map`, default `%{}`).

Renders `#diff-viewer` (`phx-hook="DiffViewer"`) with one `.diff-file-section` per file (`id={"file-section-#{file_path_to_id(file.path)}"}`, `data-language={file.language}`). Each collapsible header button fires **`toggle_file_expansion`** with `phx-value-path`; the body renders only when `Map.get(@expanded_files, file.path, false)` and reads the context level via `Map.get(@file_context_levels, file.path, 3)` (`:all` disables the expand bars). `selected_file` is declared but only drives the sidebar row highlight. Per-file expansion bars fire **`expand_context`** with `phx-value-path`.

#### `split_diff_layout/1`

Attrs: `files` (`:list`, **required**), `expanded_files` (`:map`, default `%{}`), `selected_file` (`:string`, default `nil`), `file_context_levels` (`:map`, default `%{}`), `expanded_dirs` (`:map`, default `%{}`), `file_filter` (`:string`, default `""`), `repos` (`:list`, default `[]`), `active_repo_id` (`:string`, default `"primary"`).

Full-width two-pane layout for the Files-changed tab: an optional multi-repo toolbar above the panes (only when `length(@repos) > 1`) — rectangle-stack icon + "Repository" label + `<select name="repo_id">` wrapped in its own `<form id="diff-repo-switch-form" phx-change="switch_repo">` (a form-less input-level phx-change never delivers its event — pushInput throws "form events require the input to be inside a form"; the select serializes by its `name="repo_id"` into `%{"repo_id" => ...}`) (option label `repo_option_label/1`: `"<repo_id> — <path prefix truncated at 30 chars>"` — `Helpers.truncate_string/2` keeps the head of the string —, bare `repo_id` when no usable path; `selected` on `active_repo_id`) + right-aligned summed `+adds`/`-dels` (`sum_files/2` over `@files`) — then `flex flex-col lg:flex-row gap-3 items-start` with `file_tree_sidebar` + the diff column (`flex-1 min-w-0 w-full space-y-3`). New event beyond the children's own: **`switch_repo`** (`repo_id`).

#### `commit_detail_header/1`

Attrs: `commit` (`:map`, **required**), `back_url` (`:string`, **required**), `task_title` (`:string`, default `nil`). Compact card reading `message` (title attr + truncated `h1`), `sha` (sliced `0..7` mono ghost badge), `author_name`, `date` (`relative_time`) of the commit map, plus a plain `<a href={@back_url}>` ghost square back link (title/aria "Back to review") and the muted truncated `task_title` breadcrumb. Fires no events.

#### `commit_diff_layout/1`

Attrs: `files` (`:list`, **required**), `expanded_files` (`:map`, default `%{}`), `selected_file` (`:string`, default `nil`), `file_context_levels` (`:map`, default `%{}`), `expanded_dirs` (`:map`, default `%{}`), `file_filter` (`:string`, default `""`). The commit-inspection variant of the two-pane layout — same `file_tree_sidebar` + `diff_viewer` pair, NO repo toolbar.

### DiffViewer JS/DOM contract (do not break)

`DiffViewer` has a single responsibility: parse raw git diff text and render it. **Syntax highlighting is applied CLIENT-SIDE by the `DiffViewer` JS hook** — the backend renders escaped plain-text diff lines only (no `Phoenix.HTML.raw`, no server-side highlighting, no Floki, no try/rescue for highlighting). This crash-isolates the highlighter: a frontend highlight failure is a harmless cosmetic issue, whereas a server-side Tree-sitter (Lumis/html5ever NIF) crash could kill a BEAM process mid-task.

- The `#diff-viewer` container (`diff_viewer/1`) carries `phx-hook="DiffViewer"`. **LiveView 1.2 supports exactly ONE hook name per element** — the whole attribute value is looked up as a single hook name; space-separated lists are pre-1.2 behavior and silently attach NOTHING (the console then warns `unknown hook found for "<value>"`). That is why scroll-to-file and highlighting are merged into the single `DiffViewer` hook. Each per-file `<div class="diff-file-section">` carries `data-language={file.language}` — the backend passes through `EvoGit.Review.language_for_file/1` Lumis-style names (`elixir`, `c_sharp`, `text`, …; `nil` → attribute omitted; `Review` stamps every file, defaulting unknown extensions to `"text"`).
- `render_diff_content/3` and `diff_split_row/1` render `line.content` directly as escaped text inside `phx-no-format` spans — no highlight markup is ever produced server-side.
- `commit_diff_layout/1` (commit-inspection view) shares the same `<.diff_viewer>` component as `split_diff_layout/1` (branch-review view).
- Context expansion (`expand_context`) re-fetches the diff with a wider window and `update_file_diff_in_socket/4` swaps only the file's `diff` field — no full-file content fetches, no `:preserve` sentinel.

Client-side highlighting flow (`assets/js/hooks/diff_viewer.js`, vendored highlight.js 11.11.1):

- The `DiffViewer` hook registers the `scroll_to_file` event handler in `mounted()` and runs its highlight pass in BOTH `mounted()` and `updated()`: morphdom applies in-place patches (lazy file load, `expand_context`, `select_file`) without re-initializing hooks, so `updated()` re-highlights new/changed rows; `mounted()` covers full remounts (tab switches destroy/recreate `#diff-viewer`, task reloads collapse files).
- Per `.diff-file-section`, reads `data-language` and maps lumis→hljs names (`c_sharp` → `csharp`, `text` → `plaintext`, everything else passes through). Unknown languages (`hljs.getLanguage` undefined) skip the whole section — a wrong grammar is worse than no highlighting.
- Per `.diff-split-cell` (skipping cells marked `dataset.hl === "1"` and empty/whitespace-only cells): reads `textContent`, calls `hljs.highlight(code, {language})` inside try/catch (a throw leaves the cell as plain text — never breaks the page), assigns `innerHTML`, and sets `dataset.hl = "1"` (morphdom replaces changed leaf cells without the marker, so only new cells are processed).
- No-ops gracefully if hljs failed to load (cells stay plain text).

Parsing/rendering functions:

- `parse_diff_lines/1` — splits the raw diff into typed lines (`:header`, `:hunk`, `:addition`, `:deletion`, `:meta`, `:no_newline`, `:context`), stripping `+`/`-` markers.
- `parse_hunk_header/1` — extracts `{old_start, new_start}` from `@@` headers.
- `build_diff_segments/1` — groups lines into `{:pre_hunk, lines}` (meta/header before the first hunk) and `{:hunk, hunk_line, pairs}` segments.
- `build_split_pairs/2` — converts a hunk body into paired split-view rows (context on both sides; deletions left-only; additions right-only; consecutive del+add blocks zipped with `nil` padding on the shorter side).
- `diff_split_row/1` — renders one split-view row (4 grid cells: old gutter | old content | new gutter | new content).
- `file_tree_sidebar/1` + `tree_node/1` + `file_row/1` — sidebar file tree with per-directory aggregate add/delete counts (state model below).
- `diff_expand_bar/1` — expandable context bar at hunk edges (fires the `expand_context` event).

The split layout uses a 4-column CSS grid (`.diff-split-table`). Hunk headers (`@@ -x,y +a,b @@`) and expand bars span all 4 columns via `grid-column: 1 / -1`.

### Highlight token CSS

The `.hljs-*` token palette lives in `assets/css/app.css` (light + `[data-theme="dark"]` variants, GitHub-light/dark inspired). The span-neutralizer rules (`.diff-line-content span` / `.diff-split-cell span` → inline, transparent background, inherited font — but NOT `color: inherit`, so the token colors show through) keep the injected highlight spans from breaking the diff grid.

### Full-content fields (inert)

`EvoGit.Review.FileInfo` carries `full_new_content`/`full_old_content` struct fields (nil by default) but NOTHING populates them — `ReviewLive` fetches only the diff text (via `load_file_diff`/`load_commit_file_diff`). Do not reintroduce full-file fetches: client-side highlighting needs only the diff lines.

## Server-driven tree state

The file-tree sidebar's interactivity is **100% server-driven — no `<details>` elements anywhere in the tree**:

- **`expanded_dirs`** — map attr, dir FULL path ⇒ boolean, **collapsed by default** (`Map.get(expanded_dirs, node.path, false)`). Directory rows are plain `<button>`s firing **`toggle_dir`** with `phx-value-dir` = the FULL accumulated dir path (`aria-expanded` reflects the state; children render only while open). Dir rows carry the accumulated `path` key — `build_file_tree`/`insert_into_tree` thread a `parent_path` accumulator joining segments with `/` (root dirs = the single segment) — plus aggregate `additions`/`deletions`/`file_count` for the whole subtree and an `aria` chevron that rotates when open.
- **`file_filter`** — string attr; a non-blank (trimmed) value switches the sidebar from the tree to a **FLAT case-insensitive full-path match** (`String.contains?(String.downcase(path), downcase(filter))` — no directory nodes; "No matching files" empty state). The filter input fires **`filter_files`** with a 200ms debounce.
- **`collapse_all_dirs` / `expand_all_dirs`** — ghost buttons acting on the whole tree (ReviewLive resets/populates the `expanded_dirs` map).
- Sibling sort is explicitly case-insensitive (`String.downcase(name)`), directories first then files (`sort_nodes/1`).

## Field-consumption audit

All components are **purely display** — none re-fetches data (no `EvoDash.NodeContext`/`EvoGit.Review`/`TaskRegistry` calls in the subtree); every event they fire (`switch_tab`, `switch_repo`, `toggle_summary_view`, `toggle_objective_view`, `select_file`, `toggle_file_expansion`, `expand_context`, `toggle_dir`, `filter_files`, `collapse_all_dirs`, `expand_all_dirs`, `inspect_commit`, `open_repo_diff`, `merge`, `merge_target_change`, `reject`, `resume`, `create_pr`, `ignore`, `auto_resolve`, `extract_skills`, `confirm_extract_skills`, `cancel_extract_skills`) belongs to the hosting LiveView, which does the actual fetches (`EvoDash.NodeContext.load_file_diff*`, `load_commit_files`, …).

- **`page_header`**: `title` (via `short_title/1`), `status`/`task_status` atoms only (badge helpers), `task_type` (capitalized), `task_id`/`model_id` (mono, title attr), `repo_path`/`branch_name`/`merge_target` (meta chips), `agent_count` (`format_number`), `started_at`/`finished_at` (`relative_time`), `stats` with atom-OR-string key fallback. `commit_sha` is declared but never referenced in the body. `Map.get` chains / `if`-gated dot access only — nil-safe by construction.
- **`task_summary`**: `usage` accessed ONLY via `Map.get` (`input_tokens`, `output_tokens`, `total_tokens`, `cached_tokens`, `cache_creation_tokens`, `input_cost`, `output_cost`, `total_cost`; details block gated on `@usage` truthy, cache rows on cached/cache_creation > 0); `status` badge; `task_type`; `model_id`; `agent_count` (`format_number`); `started_at`/`finished_at` (`relative_time`). Summary-map safe.
- **`agent_summary`**: `summary` only (raw `<pre>` vs `raw(EvoDash.MarkdownRender.render/1)`); `summary_raw` toggle; `model_id`/`finished_at` header meta. `MarkdownRender` runs server-side in the LiveView (in-process, no external fetch).
- **`objective_section`**: `objective` (markdown/raw bodies + the empty-state gate `@objective in [nil, ""]`) + `objective_raw` toggle.
- **`page_tabs`**: `active_tab` comparisons + the three count badges + `show_archive` gate.
- **`repo_cards`**: `repos` iterated in order; per-entry fields read via the defensive `field/3` (atom → string → default) — `repo_id`, `repo_path`, `branch_name`, `branch_exists`, `review_data`, `merge_targets`, `default_merge_target`, `merge_status`, `resolution`; `review_data`'s `changed_files_count`/`total_additions`/`total_deletions` via `review_stat/2` (same fallback, default `0`; the whole stat block is gated on `review_data` truthy); `merge_status` pattern-matched exactly as in `merge_status_block/1`; `resolution` state machine via `resolution_state/1` + `resolution_badge_text/1` + `resolution_detail_text/1`. `completion` gates the banner; `back_url` is the banner link target.
- **`task_actions`**: `can_resume` gates Continue task; `loading`/`branch_exists`/`has_pr`/`pr_url`/`show_export`/`export_url` thread into the private `overflow_menu/1`.
- **`extract_skills_modal`**: `show` gate only — no data fields (`user_note` textarea is client-side).
- **`diff_stats_bar`**: `files_count`, `additions`, `deletions`, `commits_count` — the component-level consumer of the diff-stat numbers (the `@review_data` top-level keys `changed_files_count`/`total_additions`/`total_deletions` map onto its attrs; `page_header`'s `stats` row shows the same numbers from its `stats` map).
- **`commits_list`**: per `CommitInfo` — `sha`, `short_sha`, `message`, `author_name`, `date`.
- **`commit_detail_header`**: `message`, `sha`, `author_name`, `date`, `back_url`, `task_title`.
- **`split_diff_layout` / `commit_diff_layout` / `diff_viewer`**: per-`FileInfo` field reads — **`path`** (tree build, header, `file_path_to_id`), **`status`** (header + tree via `file_status_icon/color` — "added"/"deleted"/"modified", catch-all else), **`additions`/`deletions`** (header, tree file node, dir aggregates, toolbar sums), **`language`** (→ `data-language`), **`diff`** (only in `render_diff_content`). Drivers: `expanded_files` (body renders only when true), `file_context_levels` (default 3; `:all` disables expand bars), `selected_file` (tree row highlight only — never referenced in `diff_viewer/1`'s body), `expanded_dirs`/`file_filter` (sidebar). **Lazy diff confirmed**: `render_diff_content` checks `file.diff` twice (`if file.diff, do: parse_diff_lines(file), else: []` and `is_nil(@file.diff)` → "Loading diff…" spinner); ReviewLive swaps in `file.diff` via `update_file_diff_in_socket/4`. Headers/stats render from metadata alone; full diff text renders only for expanded files whose diff has been fetched.
- **`archive_review_section`/`archive_tree_node`**: see the component section above (atom-keyed per-agent maps incl. the nested `usage` sub-map).
- **Full content rendering**: the ONLY full-content rendering is `render_diff_content` (split-view diff text for expanded files) and `agent_summary`/`objective_section` (markdown/raw). `full_new_content`/`full_old_content` FileInfo fields are never read (inert — see above).

**Locked `EvoDashWeb.Helpers` helpers consumed** (never re-implemented locally): `review_status_badge/icon/label` (page_header), `task_status_badge` (page_header, task_summary), `relative_time` (page_header, task_summary, commits_list, commit_detail_header, archive_tree_node), `format_number` (page_header, task_summary, archive_tree_node), `format_cost` (task_summary, archive_tree_node), `format_cache_hit_rate` (task_summary), `format_datetime` (archive_tree_node).

## Constraints

### `try/rescue` Policy

`try/rescue` is normally an anti-pattern in Elixir. Within these component files:

- **Do NOT** wrap `String.to_existing_atom/1` in `try/rescue`. When normalizing potentially untrusted DB-sourced data (e.g. agent archive maps after a Jason.decode round-trip), use an explicit **whitelist map lookup** (`@known_agent_keys` in `normalize_agent_keys/1`) with `Map.get/3` defaulting to the original key. This avoids dynamic atom creation AND avoids try/rescue.
- If any new `try/rescue` is introduced, it MUST include a clear inline comment explaining why it is justified.
mary), `relative_time` (page_header, task_summary, commits_list, commit_detail_header, archive_tree_node), `format_number` (page_header, task_summary, archive_tree_node), `format_cost` (task_summary, archive_tree_node), `format_cache_hit_rate` (task_summary), `format_datetime` (archive_tree_node).

## Constraints

### `try/rescue` Policy

`try/rescue` is normally an anti-pattern in Elixir. Within these component files:

- **Do NOT** wrap `String.to_existing_atom/1` in `try/rescue`. When normalizing potentially untrusted DB-sourced data (e.g. agent archive maps after a Jason.decode round-trip), use an explicit **whitelist map lookup** (`@known_agent_keys` in `normalize_agent_keys/1`) with `Map.get/3` defaulting to the original key. This avoids dynamic atom creation AND avoids try/rescue.
- If any new `try/rescue` is introduced, it MUST include a clear inline comment explaining why it is justified.
