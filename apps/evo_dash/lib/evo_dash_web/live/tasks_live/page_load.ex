defmodule EvoDashWeb.TasksLive.PageLoad do
  @moduledoc """
  Async, exit-safe page loading for the Tasks page (`EvoDashWeb.TasksLive`).

  ONE page load = ONE supervised `EvoDash.TaskSupervisor` task that fetches one
  page of tasks plus the distinct project paths and reports back to the LiveView
  as `{:tasks_page_loaded, seq, node, result}`. The LiveView process never
  blocks on a store/RPC call: store reads can take many seconds (a task `result`
  / `archive_metadata` blob can be >100 MB) and a `GenServer.call` can EXIT
  (timeout / dead store), so the fetch runs off-process and inside
  `EvoDash.SafeCall.run/1` — an exit becomes `{:error, reason}` instead of
  killing the loader and wedging the page's loading state forever.

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
  Loads one page of tasks plus the distinct project paths for `node`.

  Returns `%{tasks:, current_page:, total_count:, total_pages:, project_paths:}`.
  The requested page is clamped against the real `total_pages`; a clamp change
  costs one extra fetch (edge cases only, e.g. a stale/high page number).
  Failures propagate to `run/6`, which converts them to values.
  """
  def load(node, requested_page, page_size, filters) do
    offset = (requested_page - 1) * page_size

    # the upcoming TaskRegistry.select_tasks_page/3 replaces this full-%TaskInfo{} page fetch
    {tasks, total_count} =
      EvoDash.NodeContext.list_tasks_paginated(node,
        limit: page_size,
        offset: offset,
        filters: filters
      )

    total_pages = total_pages(total_count, page_size)
    clamped_page = min(max(1, requested_page), total_pages)

    {tasks, clamped_page, total_count} =
      if clamped_page != requested_page do
        clamped_offset = (clamped_page - 1) * page_size

        {clamped_tasks, _total_count} =
          EvoDash.NodeContext.list_tasks_paginated(node,
            limit: page_size,
            offset: clamped_offset,
            filters: filters
          )

        {clamped_tasks, clamped_page, total_count}
      else
        {tasks, clamped_page, total_count}
      end

    %{
      tasks: tasks,
      current_page: clamped_page,
      total_count: total_count,
      total_pages: total_pages,
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
  Applies the `:reflect` client-side exclusion to a loaded page of task rows.

  `:reflect` tasks are repo-less Home-chat (self-reflective agent) tasks that
  would pollute the cross-project list, so they are hidden unless the reveal
  toggle is on. The exclusion is client-side because the SQL `filters` keyword
  cannot express "exclude type" (the WHERE builder lives in evo_git). Rows are
  full `%TaskInfo{}` structs, so `type` is already a decoded atom — no atom
  conversion.
  """
  def visible_tasks(tasks, true), do: tasks
  def visible_tasks(tasks, false), do: Enum.reject(tasks, &(&1.type == :reflect))
end
