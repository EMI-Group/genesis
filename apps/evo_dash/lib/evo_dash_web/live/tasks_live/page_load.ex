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
  (`EvoDash.NodeContext.list_tasks_page/2`): each row carries the 17 summary
  keys only (`id`, `status`, `review_status`, `started_at`, `finished_at`,
  `type`, `project_path`, `opts`, `branch_name`, `model_id`, `agent_count`,
  `base_sha`, `commit_sha`, `lease_expires_at`, `updated_at`, `error`,
  `session_mode`) — the heavy `result` / `usage` / `logs` / `archive_metadata`
  blobs are NEVER read for the list. They are fetched per card, on demand, by
  `EvoDashWeb.TasksLive.TaskDetail` (lite detail + archive).

  ## The `session_mode` filter is applied by a server-side scan

  `session_mode` is `"oneshot"` or `"interactive"` on every row (a stored NULL
  cell reads as `"oneshot"`). The core's SQL WHERE builder has NO `session_mode`
  predicate and silently ignores an unknown filter key, so the filter CANNOT be
  pushed into SQL — `filters/1` merely carries it through the 4-arity
  `:tasks_page_load_runner` seam and `load/4` strips it (`Keyword.pop/3`) and
  applies it itself.

  For `"oneshot"` / `"interactive"`, `load/4` therefore SCANS the SQL-filtered
  result set page by page (`@scan_page_size` = 50 rows, the store's maximum page
  size), collects the rows whose `session_mode` matches, and paginates that
  collection in memory — so the reported `total_count` is the FILTERED count,
  never the unfiltered SQL total. The scan never probes past the FIRST page's
  reported `total`, because the store CLAMPS an out-of-range offset onto its
  LAST page (probing past the end would keep re-reading that same page), and it
  stops on an empty or fully-repeated page as a second, defensive bound.

  `"all"` (and any other value) is the untouched single-read path: ONE
  `list_tasks_page/2` call whose `rows` ARE the page.

  ## `awaiting_sessions`

  Both paths also report `awaiting_sessions: %{task_id => agent_id}` built from
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

  # Page size of the `session_mode` SCAN — the store's maximum page size.
  @scan_page_size 50

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
    filters = filters(socket)

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

  The 4-arity signature is the `:tasks_page_load_runner` seam's contract; the
  `:session_mode` key of `filters` is NOT a SQL predicate — it is popped here
  and applied by this module (see the moduledoc):

    * `"all"` (or any unknown value) — ONE `list_tasks_page/2` read with the
      requested limit/offset, exactly as before. The store CLAMPS an
      out-of-range offset onto the LAST page and returns THAT page's rows while
      still reporting the full filtered `total` — so an out-of-range page
      number (a stale URL, a filter that shrank the result set) needs NO second
      fetch: the single returned page already IS the clamped page.
    * `"oneshot"` / `"interactive"` — scan the SQL-filtered rows in pages of
      `@scan_page_size`, keep the matching rows (in order) and slice the
      requested page out of that in-memory collection, so `total_count` reports
      the FILTERED count.

  Failures propagate to `run/6`, which converts them to values.
  """
  def load(node, requested_page, page_size, filters) do
    {session_mode, sql_filters} = Keyword.pop(filters, :session_mode, "all")
    session_mode = normalize_session_mode(session_mode)

    {tasks, total_count, current_page} =
      page_rows(node, requested_page, page_size, sql_filters, session_mode)

    %{
      tasks: tasks,
      current_page: current_page,
      total_count: total_count,
      total_pages: total_pages(total_count, page_size),
      project_paths: EvoDash.NodeContext.get_unique_paths(node),
      awaiting_sessions: awaiting_sessions(node)
    }
  end

  @doc """
  The `filters` keyword for the current filter assigns.

  `"all"` / `""` passthrough is handled by the store's own WHERE builder.

  `:session_mode` is NOT a SQL predicate: the core's WHERE builder has no such
  filter and silently ignores unknown keys. It rides along here only to reach
  the 4-arity `:tasks_page_load_runner` seam, and `load/4` strips it before the
  `list_tasks_page/2` call and applies it server-side.
  """
  def filters(socket) do
    [
      status: socket.assigns.status_filter,
      project_path: socket.assigns.project_filter,
      review_status: socket.assigns.review_status_filter,
      search: socket.assigns.search_query,
      # Defensive read: the page seeds this assign; a context without it means
      # "no session-mode filter", which `load/4` normalizes to `"all"` anyway.
      session_mode: Map.get(socket.assigns, :session_mode_filter, "all")
    ]
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
  the 17-key summary maps, so `type` is already a decoded atom — no atom
  conversion — and it is read with `Map.get/2` (summary-safe: never a dot
  access that would raise on a row without the key).

  An `"interactive"` session is NEVER hidden this way: it is a live conversation
  parked at `:awaiting_input` (today's interactive sessions are `:reflect`
  tasks), not chat-history noise, and the user must be able to find and resume
  it. A missing/blank `session_mode` reads as `"oneshot"`, so the historic
  behaviour is unchanged for every one-shot task.
  """
  def visible_tasks(tasks, true), do: tasks

  def visible_tasks(tasks, false) do
    Enum.reject(tasks, fn row ->
      Map.get(row, :type) == :reflect and session_mode_of(row) != "interactive"
    end)
  end

  # --- page selection -------------------------------------------------------

  # `"all"`: the untouched single-read path — its rows ARE the page.
  defp page_rows(node, requested_page, page_size, sql_filters, "all") do
    offset = (requested_page - 1) * page_size

    %{rows: rows, total: total_count} =
      EvoDash.NodeContext.list_tasks_page(node,
        limit: page_size,
        offset: offset,
        filters: sql_filters
      )

    {rows, total_count, min(max(1, requested_page), total_pages(total_count, page_size))}
  end

  # `"oneshot"` / `"interactive"`: SQL cannot express the predicate, so scan the
  # SQL-filtered rows and paginate the matches in memory.
  defp page_rows(node, requested_page, page_size, sql_filters, session_mode) do
    matched = scan_session_mode(node, sql_filters, session_mode)
    total_count = length(matched)
    total_pages = total_pages(total_count, page_size)
    current_page = min(max(1, requested_page), total_pages)

    tasks =
      matched
      |> Enum.drop((current_page - 1) * page_size)
      |> Enum.take(page_size)

    {tasks, total_count, current_page}
  end

  # Walks the SQL-filtered result set in `@scan_page_size` steps from offset 0.
  #
  # Bounds: the FIRST page's reported `total` (the store clamps an out-of-range
  # offset onto its LAST page, so probing past the end would re-read that page
  # forever), an EMPTY page, and a page that repeats already-seen rows (the
  # defensive backstop for a bogus/huge reported `total`).
  defp scan_session_mode(node, sql_filters, session_mode) do
    scan_pages(node, sql_filters, session_mode, 0, nil, MapSet.new(), [])
  end

  defp scan_pages(node, sql_filters, session_mode, offset, total, seen, acc) do
    if is_integer(total) and offset >= total do
      acc
    else
      %{rows: rows, total: page_total} =
        EvoDash.NodeContext.list_tasks_page(node,
          limit: @scan_page_size,
          offset: offset,
          filters: sql_filters
        )

      rows = if is_list(rows), do: rows, else: []
      total = if is_integer(total), do: total, else: page_total
      fresh = Enum.reject(rows, &MapSet.member?(seen, &1))
      acc = acc ++ Enum.filter(fresh, &(session_mode_of(&1) == session_mode))

      cond do
        rows == [] ->
          acc

        fresh == [] ->
          acc

        is_integer(total) and offset + @scan_page_size >= total ->
          acc

        true ->
          scan_pages(
            node,
            sql_filters,
            session_mode,
            offset + @scan_page_size,
            total,
            MapSet.union(seen, MapSet.new(rows)),
            acc
          )
      end
    end
  end

  # --- helpers --------------------------------------------------------------

  # Only the two canonical session modes filter; anything else (a missing
  # assign, a blank/unknown string) means "no filter".
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
