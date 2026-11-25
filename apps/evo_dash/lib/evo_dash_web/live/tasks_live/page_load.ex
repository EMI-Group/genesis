defmodule EvoDashWeb.TasksLive.PageLoad do
  @moduledoc """
  Async, exit-safe page loading for the Tasks page (`EvoDashWeb.TasksLive`).

  ONE page load = ONE supervised `EvoDash.TaskSupervisor` task that fetches one
  page of task SUMMARY rows plus the distinct project paths and the node's idle
  interactive sessions, and reports back to the LiveView as
  `{:tasks_page_loaded, seq, node, result}`. The LiveView process never blocks
  on a store/RPC call: store reads can take many seconds and a `GenServer.call`
  can EXIT (timeout / dead store), so the fetch runs off-process and inside
  `EvoDash.SafeCall.run/1` — an exit becomes `{:error, reason}` instead of
  killing the loader and wedging the page's loading state forever.

  The page itself is the LIGHTWEIGHT projection
  (`EvoDash.NodeContext.list_tasks_page/2`): each row carries the 18 summary
  keys only (`id`, `status`, `review_status`, `started_at`, `finished_at`,
  `type`, `project_path`, `opts`, `branch_name`, `model_id`, `agent_count`,
  `base_sha`, `commit_sha`, `lease_expires_at`, `updated_at`, `error`,
  `session_mode`, `pause_kind`) — the heavy `result` / `usage` / `logs` /
  `archive_metadata` blobs are NEVER read for the list. They are fetched per
  card, on demand, by `EvoDashWeb.TasksLive.TaskDetail` (lite detail + archive).

  ## Every filter is a SQL predicate — including `session_mode`

  `session_mode` is `"oneshot"` or `"interactive"` on every row (a stored NULL
  cell reads as `"oneshot"`, and so does a legacy blank cell). The core's
  shared WHERE builder (`EvoGit.Store.Operations.Filters.where_filters/2`) has
  a `:session_mode` predicate, so the filter travels in the SAME `filters`
  keyword as status/path/review_status/search and the store's
  `count(*) OVER ()` computes the FILTERED total. A page load is therefore
  always exactly ONE `list_tasks_page/2` read: no scan, no in-memory
  pagination, and `total_count` describes the rows the filter actually selects.

  `"all"` (and any other value, after `normalize_session_mode/1`) means "no
  clause" — still the same single read, just without that predicate.

  ## `awaiting_sessions`

  Every load also reports `awaiting_sessions: %{task_id => agent_id}` built from
  `EvoDash.NodeContext.list_awaiting_input/1` — the tasks that have an idle
  interactive agent session parked at the non-terminal `:awaiting_input` status
  (the session is live but NOT busy: it is waiting for the user). Entries
  without both a `task_id` and an `agent_id` are dropped; that helper already
  degrades to `[]` on any failure.

  `start/3` is the only writer of the monotonic `:page_load_seq` assign; the
  caller drops any result whose `seq` is stale or whose `node` no longer matches
  `socket.assigns.current_node`.

  Two app-env seams, both resolved AT SPAWN TIME: `:tasks_page_load_hook`
  (1-arity, wraps the spawn; default identity) and `:tasks_page_load_runner`
  (4-arity page-load function; default `&load/4`), so a test can inject an
  exiting runner and assert the LiveView survives with its loading flag
  cleared.
  """
  import Phoenix.Component, only: [assign: 3]

  alias EvoDash.SafeCall

  @doc """
  Starts one async page load and returns the socket.

  Bumps `:page_load_seq`, optionally paints the loading placeholder
  (`show_loading?` — user-initiated loads only; a background refresh keeps the
  already-loaded rows on screen), and hands the spawn to the
  `:tasks_page_load_hook` app-env seam (1-arity, default identity, resolved at
  spawn time like EvoDash's other runner seams) so tests can count page-load
  spawns.
  """
  @spec start(Phoenix.LiveView.Socket.t(), pos_integer(), boolean()) ::
          Phoenix.LiveView.Socket.t()
  def start(socket, page, show_loading?) do
    seq = socket.assigns.page_load_seq + 1
    socket = assign(socket, :page_load_seq, seq)
    socket = if show_loading?, do: assign(socket, :tasks_loading, true), else: socket

    parent = self()
    node = socket.assigns.current_node
    page_size = socket.assigns.page_size

    filters =
      case Map.get(socket.assigns, :focused_task_id) do
        nil ->
          filters(socket)

        id ->
          [
            focused_task: id,
            pending_remote: socket.assigns[:workbench_remote_requested] and node == node()
          ]
      end

    hook = Application.get_env(:evo_dash, :tasks_page_load_hook, fn inner -> inner.() end)
    hook.(fn -> run(parent, seq, node, page, page_size, filters) end)

    socket
  end

  @doc """
  Spawns the loader task and reports its result to `parent`.

  The page-load FUNCTION is resolved from the `:tasks_page_load_runner` app-env
  seam AT SPAWN TIME (the dashboard's runner-seam idiom, resolved inside
  `run/6` so every caller — including `EvoDash.SafeCall`-wrapped ones — gets the
  injected runner). Default is `&load/4`, so production behaviour is unchanged;
  a test may inject e.g. `fn _, _, _, _ -> exit(:boom) end`.

  The result message is ALWAYS sent — `SafeCall.run/1` captures exits, raises
  and throws as values — so the caller's `:tasks_loading` flag can never stick,
  even when the injected runner exits.
  """
  def run(parent, seq, node, page, page_size, filters) do
    runner = Application.get_env(:evo_dash, :tasks_page_load_runner, &load/4)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = SafeCall.run(fn -> runner.(node, page, page_size, filters) end)
      send(parent, {:tasks_page_loaded, seq, node, result})
    end)
  end

  @doc """
  Loads one page of task SUMMARY rows, the distinct project paths and the idle
  interactive sessions for `node`.

  Returns
  `%{tasks:, current_page:, total_count:, total_pages:, project_paths:, awaiting_sessions:}`.

  The 4-arity signature is the `:tasks_page_load_runner` seam's contract. ONE
  `EvoDash.NodeContext.list_tasks_page/2` read serves every filter combination,
  `:session_mode` included — it is a SQL predicate (`"oneshot"` also matches a
  stored NULL cell), so the read's `total` IS the filtered count. The store
  CLAMPS an out-of-range offset onto the LAST page and returns THAT page's rows
  while still reporting the full filtered `total`, so an out-of-range page
  number (a stale URL, a filter that shrank the result set) needs NO second
  fetch: the single returned page already IS the clamped page, and
  `current_page` is clamped to the same range.

  Failures propagate to `run/6`, which converts them to values.
  """
  def load(node, _requested_page, _page_size, focused_task: id, pending_remote: pending?) do
    tasks =
      if !pending? do
        case EvoDash.NodeContext.get_task_lite(node, id) do
          %EvoGit.TaskInfo{} = task -> [Map.from_struct(task)]
          _ -> []
        end
      else
        []
      end

    %{
      tasks: tasks,
      current_page: 1,
      total_count: length(tasks),
      total_pages: 1,
      project_paths: [],
      awaiting_sessions: if(pending?, do: %{}, else: Map.take(awaiting_sessions(node), [id]))
    }
  end

  def load(node, requested_page, page_size, filters) do
    offset = (requested_page - 1) * page_size

    %{rows: tasks, total: total_count} =
      EvoDash.NodeContext.list_tasks_page(node,
        limit: page_size,
        offset: offset,
        filters: sql_filters(filters)
      )

    %{
      tasks: tasks,
      current_page: min(max(1, requested_page), total_pages(total_count, page_size)),
      total_count: total_count,
      total_pages: total_pages(total_count, page_size),
      project_paths: EvoDash.NodeContext.get_unique_paths(node),
      awaiting_sessions: awaiting_sessions(node)
    }
  end

  @doc """
  The `filters` keyword for the current filter assigns.

  Every entry is a SQL predicate understood by the core's WHERE builder; the
  store itself treats `"all"` (and, for `:session_mode`, any unknown value) as
  "no clause", so no filter is stripped before the `list_tasks_page/2` call.

  `"needs_review"` is a REVIEW-TRIAGE filter, not a stored status: it translates
  to no `status` clause plus `review_status: "pending"`, which the store expands
  to its composite `status = 'completed' AND review_status IS NULL AND
  branch_name IS NOT NULL` predicate. While it is active it WINS over the
  separate review filter (see `review_status_filter/1`), so the two selects can
  never contradict each other.
  """
  def filters(socket) do
    status_filter = socket.assigns.status_filter
    needs_review? = needs_review_filter?(status_filter)

    [
      status: if(needs_review?, do: "all", else: status_filter),
      project_path: socket.assigns.project_filter,
      review_status: review_status_filter(socket),
      search: socket.assigns.search_query,
      # Defensive read: the page seeds this assign; a context without it means
      # "no session-mode filter", which `normalize_session_mode/1` maps to
      # "all".
      session_mode: Map.get(socket.assigns, :session_mode_filter, "all")
    ]
  end

  @doc """
  True when the STATUS filter is the review-triage value `"needs_review"`.

  The status filter takes precedence over the separate review filter: a task
  either needs review (no decision yet) and appears under `needs_review`, or it
  has a decision and appears under that review state — never both.
  """
  def needs_review_filter?(status_filter), do: status_filter == "needs_review"

  @doc """
  The effective `:review_status` SQL filter.

  `"needs_review"` in the status filter forces the store's composite
  `"pending"` predicate and the separate review select is ignored; otherwise the
  review select travels through unchanged.
  """
  def review_status_filter(socket) do
    if needs_review_filter?(socket.assigns.status_filter) do
      "pending"
    else
      socket.assigns.review_status_filter
    end
  end

  @doc """
  Number of pages for `total_count` rows at `page_size` rows per page (min 1).
  """
  def total_pages(total_count, page_size) when page_size > 0 do
    max(1, ceil(total_count / page_size))
  end

  @doc """
  Applies the `:reflect` client-side exclusion to a loaded page of task summary
  rows.

  `:reflect` tasks are repo-less Home-chat (self-reflective agent) tasks that
  would pollute the cross-project list, so they are hidden unless the reveal
  toggle is on. The exclusion is client-side because the SQL `filters` keyword
  cannot express "exclude type" (the WHERE builder lives in evo_git). Rows are
  the 18-key summary maps, so `type` is already a decoded atom — no atom
  conversion — and it is read with `Map.get/2` (summary-safe: never a dot
  access that would raise on a row without the key).

  An `"interactive"` session is NEVER hidden this way: it is a live conversation
  parked at `:awaiting_input` (today's interactive sessions are `:reflect`
  tasks), not chat-history noise, and the user must be able to find and resume
  it. A missing/blank `session_mode` reads as `"oneshot"`, so the historic
  behaviour is unchanged for every one-shot task.
  """
  def visible_tasks(tasks, show_reflect_tasks) do
    visible_tasks(tasks, show_reflect_tasks, "all")
  end

  @doc """
  `visible_tasks/2` plus the `"needs_review"` EXACTNESS guard.

  The status filter `"needs_review"` is review TRIAGE, not a stored status: the
  store predicate is the composite `status = 'completed' AND review_status IS
  NULL AND branch_name IS NOT NULL`. The SQL side cannot be narrowed further
  from here (the WHERE builder owns the store), so this choke point additionally
  rejects any row that has a `review_status` set — the filter must NEVER list a
  task whose review decision already exists.

  Total for every shape: an absent/unreadable `review_status` counts as "no
  decision" (nil), so the guard only ever drops a row that provably HAS one.
  """
  def visible_tasks(tasks, show_reflect_tasks, status_filter) do
    tasks
    |> hide_reflect_tasks(show_reflect_tasks)
    |> enforce_review_exactness(status_filter)
  end

  defp hide_reflect_tasks(tasks, true), do: tasks

  defp hide_reflect_tasks(tasks, false) do
    Enum.reject(tasks, fn row ->
      Map.get(row, :type) == :reflect and session_mode_of(row) != "interactive"
    end)
  end

  defp enforce_review_exactness(tasks, status_filter) do
    if needs_review_filter?(status_filter) do
      Enum.reject(tasks, &has_review_decision?/1)
    else
      tasks
    end
  end

  # A row "has a review decision" when its `review_status` is non-nil. Read with
  # `Map.get/2` (summary-safe, never a dot access) and tolerate a non-map row.
  defp has_review_decision?(row) when is_map(row) do
    not is_nil(Map.get(row, :review_status)) and Map.get(row, :review_status) != ""
  end

  defp has_review_decision?(_row), do: false

  # --- helpers --------------------------------------------------------------

  # The filter keyword as it reaches the store: identical to the caller's, with
  # `:session_mode` normalized so only the two canonical values ever act as a
  # predicate (the store ignores anything else anyway — this keeps the
  # `:tasks_page_load_runner` seam's keyword canonical for injected runners).
  defp sql_filters(filters) do
    Keyword.put(
      filters,
      :session_mode,
      normalize_session_mode(Keyword.get(filters, :session_mode))
    )
  end

  # Only the two canonical session modes filter; anything else (a missing
  # value, a blank/unknown string) means "no filter".
  defp normalize_session_mode(mode) when mode in ["oneshot", "interactive"], do: mode
  defp normalize_session_mode(_mode), do: "all"

  # Total: an absent (or unusable) value is the canonical `"oneshot"`.
  defp session_mode_of(row) do
    case Map.get(row, :session_mode, "oneshot") do
      "interactive" -> "interactive"
      _other -> "oneshot"
    end
  end

  # `%{task_id => agent_id}` for the tasks holding an idle interactive session.
  # Entries missing either id (or not maps at all) are dropped — never raise.
  defp awaiting_sessions(node) do
    node
    |> EvoDash.NodeContext.list_awaiting_input()
    |> Enum.reduce(%{}, fn entry, acc ->
      with task_id when not is_nil(task_id) <- entry_field(entry, :task_id),
           agent_id when not is_nil(agent_id) <- entry_field(entry, :agent_id) do
        Map.put(acc, task_id, agent_id)
      else
        _missing -> acc
      end
    end)
  end

  # The core's entry is atom-keyed (`:task_id` / `:agent_id`); accept a
  # string-keyed map too, since the shape crosses an RPC boundary.
  defp entry_field(entry, key) when is_map(entry) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp entry_field(_entry, _key), do: nil
end
