defmodule EvoDashWeb.TasksLive.PageLoad do
  @moduledoc """
  Async, exit-safe page loading for the Tasks page (`EvoDashWeb.TasksLive`).

  ONE page load = ONE supervised `EvoDash.TaskSupervisor` task that fetches one
  page of task SUMMARY rows plus the distinct project paths and reports back to
  the LiveView as `{:tasks_page_loaded, seq, node, result}`. The LiveView
  process never blocks on a store/RPC call: store reads can take many seconds
  and a `GenServer.call` can EXIT (timeout / dead store), so the fetch runs
  off-process and inside `EvoDash.SafeCall.run/1` — an exit becomes
  `{:error, reason}` instead of killing the loader and wedging the page's
  loading state forever.

  The page itself is the LIGHTWEIGHT projection
  (`EvoDash.NodeContext.list_tasks_page/2`): each row carries the 16 summary
  keys only (`id`, `status`, `review_status`, `started_at`, `finished_at`,
  `type`, `project_path`, `opts`, `branch_name`, `model_id`, `agent_count`,
  `base_sha`, `commit_sha`, `lease_expires_at`, `updated_at`, `error`) — the
  heavy `result` / `usage` / `logs` / `archive_metadata` blobs are NEVER read
  for the list. They are fetched per card, on demand, by
  `EvoDashWeb.TasksLive.TaskDetail` (lite detail + archive).

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
  Loads one page of task SUMMARY rows plus the distinct project paths for
  `node`.

  Returns `%{tasks:, current_page:, total_count:, total_pages:, project_paths:}`.

  ONE read: `EvoDash.NodeContext.list_tasks_page/2` (the summary projection)
  with the requested limit/offset. The store CLAMPS an out-of-range offset onto
  the LAST page and returns THAT page's rows while still reporting the full
  filtered `total` — so an out-of-range page number (a stale URL, a filter that
  shrank the result set) needs NO second fetch: the single returned page already
  IS the clamped page. `current_page` is therefore derived arithmetically from
  the requested page and the real `total_pages`.

  Failures propagate to `run/6`, which converts them to values.
  """
  def load(node, requested_page, page_size, filters) do
    offset = (requested_page - 1) * page_size

    %{rows: rows, total: total_count} =
      EvoDash.NodeContext.list_tasks_page(node,
        limit: page_size,
        offset: offset,
        filters: filters
      )

    %{
      tasks: rows,
      current_page: min(max(1, requested_page), total_pages(total_count, page_size)),
      total_count: total_count,
      total_pages: total_pages(total_count, page_size),
      project_paths: EvoDash.NodeContext.get_unique_paths(node)
    }
  end

  @doc """
  The SQL `filters` keyword for the current filter assigns.

  `"all"` / `""` passthrough is handled by the store's own WHERE builder.
  """
  def filters(socket) do
    [
      status: socket.assigns.status_filter,
      project_path: socket.assigns.project_filter,
      review_status: socket.assigns.review_status_filter,
      search: socket.assigns.search_query
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
  the 16-key summary maps, so `type` is already a decoded atom — no atom
  conversion — and it is read with `Map.get/2` (summary-safe: never a dot
  access that would raise on a row without the key).
  """
  def visible_tasks(tasks, true), do: tasks
  def visible_tasks(tasks, false), do: Enum.reject(tasks, &(Map.get(&1, :type) == :reflect))
end
