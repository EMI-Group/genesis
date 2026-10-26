defmodule EvoDashWeb.TasksLive.TaskDetail do
  @moduledoc """
  Lazy per-card task DETAIL + ARCHIVE cache for the Tasks page
  (`EvoDashWeb.TasksLive`).

  The task list is loaded as one page of LIGHTWEIGHT summary rows
  (`EvoDashWeb.TasksLive.PageLoad` → `EvoDash.NodeContext.list_tasks_page/2`),
  which carry the 16 summary keys only — `result`, `usage`, `logs` and
  `archive_metadata` are never transferred. The heavy data is fetched
  PER CARD, on demand, when the user expands that card:

  | read | seam | default |
  |------|------|---------|
  | the lite detail (full `%EvoGit.TaskInfo{}`, archive nil'd) | `:tasks_task_detail_runner` (2-arity `fn node, task_id -> end`) | `EvoDash.NodeContext.get_task_lite/2` |
  | ONE PAGE of the agent archive (`%{entries:, total:}`) | `:tasks_task_archive_runner` (3-arity `fn node, task_id, opts -> end`) | `EvoDash.NodeContext.list_task_archives/3` |
  | ONE agent's full archive entry (incl. its `"result"`) | `:tasks_task_archive_agent_runner` (3-arity `fn node, task_id, agent_id -> end`) | `EvoDash.NodeContext.get_agent_archive/3` |

  All three seams are resolved AT SPAWN TIME from app env (the dashboard's
  runner-seam idiom), so a test can inject an exiting runner and assert the
  LiveView survives.

  ## The archive is PAGED + lazy per agent

  A single real task carried 7 149 agent records (~108 MB). The archive is
  therefore read 100 entries at a time with `include_results: false` (every
  entry then OMITS its `"result"` key), and one agent's result is fetched
  separately only when the user asks for it (`load_agent_result/3`). Nothing
  auto-fetches at render time.

  ## Async, exit-safe, push-only

  Every fetch is ONE supervised `EvoDash.TaskSupervisor` child running
  `EvoDash.SafeCall.run/1` around the runner call, which always sends its
  result back to the LiveView:

    * `{:task_detail_loaded, seq, node, task_id, result}`
    * `{:task_archive_loaded, seq, node, task_id, result}`
    * `{:task_archive_agent_loaded, seq, node, task_id, agent_id, result}`

  A `GenServer.call` timeout / dead store EXITS its caller (`rescue` cannot
  catch it), so the call runs off-process and the exit becomes
  `{:error, reason}` — the card renders an inline error strip with a Retry
  action instead of the LiveView dying or its loading state wedging.
  No polling: results arrive only from those three messages.

  ## Guards (applied on apply, never crashing)

    1. the message's `node` must still equal `socket.assigns.current_node`
       (a node switch drops every in-flight result), and
    2. the entry for `task_id` must still exist AND its (archive) `seq` must
       equal the message's `seq` — a newer fetch (or an invalidated/pruned
       entry) supersedes an older one.

  A page APPEND keeps the archive's `seq` (only a first-page fetch bumps it);
  its result is identified by the envelope's `next_offset`, which is the offset
  that page was requested at. A stale/foreign-node result is dropped silently
  and every shape is terminal (no wedged spinners).

  ## Cached-entry shape

      %{
        state: :loading | :ok | :error,
        task: %EvoGit.TaskInfo{} | nil,
        error: term() | nil,
        seq: pos_integer(),
        archive:
          nil
          | %{
              state: :loading | :ok | :error,      # first page
              entries: [map()],                    # accumulated pages
              total: non_neg_integer(),
              next_offset: non_neg_integer(),
              loading_more?: boolean(),
              more_error: term() | nil,
              error: term() | nil,
              seq: pos_integer(),                  # first-page fetch token
              agent_results: %{
                agent_id => %{state: :loading | :ok | :error, entry: map() | nil, error: term() | nil}
              }
            }
      }

  `:task_details` never holds more than ONE page's worth of entries:
  `prune/2` runs on every landed page load and drops everything that is not on
  the freshly loaded page. `invalidate/2` drops the whole entry (including its
  archive and every cached agent result) on a task broadcast — that is the
  invalidation path for archives too.
  """

  import Phoenix.Component, only: [assign: 3]

  alias EvoDash.SafeCall
  alias EvoDashWeb.ArchiveHelpers

  # One archive page: bounded so a 7 000-agent archive never rides one read.
  @page_limit 100

  @typedoc "The lazy per-task detail entry stored under `:task_details`."
  @type entry :: %{
          state: :loading | :ok | :error,
          task: map() | nil,
          error: term() | nil,
          seq: pos_integer(),
          archive: archive_entry() | nil
        }

  @typedoc "The lazily-paged archive envelope nested inside an `entry/0`."
  @type archive_entry :: %{
          state: :loading | :ok | :error,
          entries: [map()],
          total: non_neg_integer(),
          next_offset: non_neg_integer(),
          loading_more?: boolean(),
          more_error: term() | nil,
          error: term() | nil,
          seq: pos_integer(),
          agent_results: %{optional(String.t()) => agent_result_entry()}
        }

  @typedoc "One lazily-fetched agent archive entry (its full `\"result\"` included)."
  @type agent_result_entry :: %{
          state: :loading | :ok | :error,
          entry: map() | nil,
          error: term() | nil
        }

  @doc """
  Toggles one card's expanded state, fetching its detail when it opens.

  COLLAPSE only drops the id from `:expanded_task_ids`: the cached detail is
  kept (a re-expand renders instantly) and nothing is fetched. OPEN adds the id
  and kicks off that card's ONE lazy detail fetch — `ensure/2` is the
  in-flight/cache guard, so a second expand while loading is a no-op.
  """
  @spec toggle(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def toggle(socket, task_id) do
    if MapSet.member?(expanded_ids(socket), task_id) do
      assign(socket, :expanded_task_ids, MapSet.delete(expanded_ids(socket), task_id))
    else
      socket
      |> assign(:expanded_task_ids, MapSet.put(expanded_ids(socket), task_id))
      |> ensure(task_id)
    end
  end

  @doc """
  Ensures a detail entry exists for `task_id`, fetching it when it does not.

  This is the per-card in-flight AND cache guard: an entry in ANY state
  (including `:error`) is a no-op, so a second expand while the fetch is in
  flight never issues a second read — and a re-expand of an already-loaded card
  renders from cache. Use `retry/2` to force a refetch.
  """
  @spec ensure(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def ensure(socket, task_id) do
    if Map.has_key?(details(socket), task_id) do
      socket
    else
      spawn_detail(socket, task_id)
    end
  end

  @doc """
  Drops the cached entry for `task_id` and fetches it again.

  Backs the inline "could not load this task" strip's Retry button, so a failed
  detail fetch is recoverable without collapsing/reloading the card.
  """
  @spec retry(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def retry(socket, task_id) do
    socket
    |> drop(task_id)
    |> ensure(task_id)
  end

  @doc """
  Fetches the FIRST archive page for `task_id` when the card asks for it.

  No-op unless the detail entry exists and is `:ok` (an archive read without
  the lite detail is not a state this page renders). Also a cache + in-flight
  guard: `archive: nil` or an `:error` archive is (re)fetched (the retry path),
  while a `:loading`/`:ok` archive is left alone.
  """
  @spec load_archive(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def load_archive(socket, task_id) do
    case Map.get(details(socket), task_id) do
      %{state: :ok} = entry ->
        case Map.get(entry, :archive) do
          %{state: state} when state in [:loading, :ok] -> socket
          _ -> spawn_archive_page(socket, task_id, :first)
        end

      _ ->
        socket
    end
  end

  @doc """
  Fetches the NEXT archive page (append) for `task_id`.

  No-op unless the archive is `:ok`, more entries exist
  (`length(entries) < total`) and no append is already in flight. A failed
  append keeps the already-loaded page (`more_error`) and this same function is
  the retry.
  """
  @spec load_more_archive(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def load_more_archive(socket, task_id) do
    case Map.get(details(socket), task_id) do
      %{state: :ok, archive: %{state: :ok} = archive} ->
        if more_pages?(archive), do: spawn_archive_page(socket, task_id, :more), else: socket

      _ ->
        socket
    end
  end

  @doc """
  Fetches ONE agent's full archive entry (including its `"result"`) for `task_id`.

  No-op unless the archive is `:ok`, and a cache + in-flight guard per agent:
  an agent already `:loading`/`:ok` is left alone (use the `:error` state to
  retry — an error entry IS refetched). Never called automatically on render.
  """
  @spec load_agent_result(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def load_agent_result(socket, task_id, agent_id) do
    case Map.get(details(socket), task_id) do
      %{state: :ok, archive: %{state: :ok} = archive} = entry ->
        case Map.get(agent_results(archive), agent_id) do
          %{state: state} when state in [:loading, :ok] -> socket
          _ -> spawn_agent_result(socket, task_id, entry, agent_id)
        end

      _ ->
        socket
    end
  end

  @doc """
  Drops the cached entry for `task_id` (a `:task_updated` / `:task_deleted`
  broadcast made it stale).

  When the card is currently EXPANDED, the entry is immediately refetched, so
  an open card never blanks out — it shows the loading state and then the fresh
  detail. A collapsed card stays uncached until the next expand. The drop takes
  the nested archive (and every cached agent result) with it, so a re-expand
  re-reads the archive from its FIRST page.
  """
  @spec invalidate(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def invalidate(socket, task_id) do
    socket = drop(socket, task_id)

    if MapSet.member?(expanded_ids(socket), task_id) do
      ensure(socket, task_id)
    else
      socket
    end
  end

  @doc """
  Keeps ONLY the entries for ids present in `rows` (the freshly loaded page).

  Bounds the cache to one page: every entry belonging to another page — and any
  stale in-flight `:loading` entry — is dropped. Dropping an in-flight entry is
  safe: its result is discarded by the entry-exists guard in `apply_detail/5`
  / `apply_archive/5` / `apply_archive_agent/6`.
  """
  @spec prune(Phoenix.LiveView.Socket.t(), [map()]) :: Phoenix.LiveView.Socket.t()
  def prune(socket, rows) do
    ids = rows |> row_ids() |> MapSet.to_list()
    assign(socket, :task_details, Map.take(details(socket), ids))
  end

  @doc """
  Fetches the detail for every id in `:expanded_task_ids` that is present in
  `rows` and not cached yet.

  Runs after `prune/2` on a landed page load, so a card that stays expanded
  across a reload (a background refresh, a pagination round-trip) gets its
  detail back without the user collapsing/re-expanding it.
  """
  @spec ensure_expanded(Phoenix.LiveView.Socket.t(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def ensure_expanded(socket, rows) do
    ids = row_ids(rows)

    Enum.reduce(expanded_ids(socket), socket, fn task_id, acc ->
      if MapSet.member?(ids, task_id), do: ensure(acc, task_id), else: acc
    end)
  end

  @doc """
  Applies a `{:task_detail_loaded, seq, node, task_id, result}` message.

  Drops the result silently (never crashes) when the node no longer matches or
  the entry / seq is stale. `{:ok, %EvoGit.TaskInfo{}}` → `:ok`; `{:ok, nil}`
  (the task vanished between the page load and the expand) → `:error` with
  `:not_found`; `{:error, reason}` → `:error` with that reason.
  """
  @spec apply_detail(Phoenix.LiveView.Socket.t(), pos_integer(), node(), String.t(), term()) ::
          Phoenix.LiveView.Socket.t()
  def apply_detail(socket, seq, node, task_id, result) do
    details = details(socket)

    case Map.get(details, task_id) do
      %{seq: ^seq} = entry ->
        if node == socket.assigns.current_node do
          assign(socket, :task_details, Map.put(details, task_id, put_detail(entry, result)))
        else
          socket
        end

      _ ->
        # Stale (a newer fetch superseded this one), unknown (the entry was
        # pruned or invalidated) or already applied — drop it.
        socket
    end
  end

  @doc """
  Applies a `{:task_archive_loaded, seq, node, task_id, result}` message.

  Same node + entry + seq guards as `apply_detail/5`. Whether the result is the
  FIRST page or an APPEND is read from the envelope: an envelope with
  `loading_more?: true` is waiting on the page at `next_offset`, so the result
  is appended (deduped by `agent_id`, so a retried page is idempotent); anything
  else folds as the first page.

  First page: `{:ok, %{entries: list, total: n}}` → `:ok` (an empty list is a
  valid "this task archived nothing"); `{:error, reason}` / any other shape →
  `:error` (Retry → `load_archive/2`). Append: a failure keeps the loaded page
  and records `more_error` (Retry → `load_more_archive/2`).
  """
  @spec apply_archive(Phoenix.LiveView.Socket.t(), pos_integer(), node(), String.t(), term()) ::
          Phoenix.LiveView.Socket.t()
  def apply_archive(socket, seq, node, task_id, result) do
    details = details(socket)

    case Map.get(details, task_id) do
      %{archive: %{seq: ^seq} = archive} = entry ->
        if node == socket.assigns.current_node do
          archive =
            if Map.get(archive, :loading_more?, false) do
              put_archive_more(archive, result)
            else
              put_archive_first(archive, result)
            end

          assign(socket, :task_details, Map.put(details, task_id, %{entry | archive: archive}))
        else
          socket
        end

      _ ->
        socket
    end
  end

  @doc """
  Applies a `{:task_archive_agent_loaded, seq, node, task_id, agent_id, result}`
  message.

  Guarded like `apply_archive/5` (node + entry + the archive's `seq`), plus the
  agent must still be tracked in `agent_results`. `{:ok, entry_map}` caches the
  entry AND folds it into `entries` via `ArchiveHelpers.merge_entry/2` (in
  place, order preserved), so the rendered tree shows the result without
  re-fetching the page; `{:ok, nil}` / `{:error, reason}` / any other shape →
  `%{state: :error, error: reason}` (Retry re-fires the same event).
  """
  @spec apply_archive_agent(
          Phoenix.LiveView.Socket.t(),
          pos_integer(),
          node(),
          String.t(),
          String.t(),
          term()
        ) :: Phoenix.LiveView.Socket.t()
  def apply_archive_agent(socket, seq, node, task_id, agent_id, result) do
    details = details(socket)

    case Map.get(details, task_id) do
      %{archive: %{seq: ^seq} = archive} = entry ->
        if node == socket.assigns.current_node and
             Map.has_key?(agent_results(archive), agent_id) do
          archive = put_agent_result(archive, agent_id, result)
          assign(socket, :task_details, Map.put(details, task_id, %{entry | archive: archive}))
        else
          socket
        end

      _ ->
        socket
    end
  end

  ## Private — spawn helpers (ONE supervised child each, runner resolved here)

  # Seeds `state: :loading` and spawns ONE lite-detail fetch. The seq bump is
  # the supersede token for both the entry and its still-`:loading` state.
  defp spawn_detail(socket, task_id) do
    seq = next_seq(socket)
    parent = self()
    node = socket.assigns.current_node

    runner =
      Application.get_env(
        :evo_dash,
        :tasks_task_detail_runner,
        &EvoDash.NodeContext.get_task_lite/2
      )

    entry = %{state: :loading, task: nil, error: nil, seq: seq, archive: nil}

    socket =
      socket
      |> assign(:task_details, Map.put(details(socket), task_id, entry))
      |> assign(:task_detail_seq, seq)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = SafeCall.run(fn -> runner.(node, task_id) end)
      send(parent, {:task_detail_loaded, seq, node, task_id, result})
    end)

    socket
  end

  # Spawns ONE archive page fetch for an entry that is already `:ok`. A FIRST
  # page takes a fresh seq (its own token, so a detail refetch never invalidates
  # a landed archive and vice versa — both draw from the same monotonic
  # counter) and resets the envelope; an APPEND keeps the archive's seq and
  # `next_offset`, marking `loading_more?` so `apply_archive/5` can tell the two
  # results apart.
  defp spawn_archive_page(socket, task_id, mode) do
    parent = self()
    node = socket.assigns.current_node
    entry = Map.fetch!(details(socket), task_id)
    previous = entry.archive

    {seq, offset, archive} =
      case mode do
        :first ->
          seq = next_seq(socket)
          {seq, 0, new_archive(seq)}

        :more ->
          seq = previous.seq
          {seq, previous.next_offset, %{previous | loading_more?: true, more_error: nil}}
      end

    runner =
      Application.get_env(
        :evo_dash,
        :tasks_task_archive_runner,
        &EvoDash.NodeContext.list_task_archives/3
      )

    opts = [limit: @page_limit, offset: offset, include_results: false]

    socket =
      socket
      |> assign(:task_details, Map.put(details(socket), task_id, %{entry | archive: archive}))
      |> maybe_bump_seq(mode, seq)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = SafeCall.run(fn -> runner.(node, task_id, opts) end)
      send(parent, {:task_archive_loaded, seq, node, task_id, result})
    end)

    socket
  end

  # Spawns ONE per-agent result fetch. The archive's seq identifies the page
  # generation: a first-page refetch (or an invalidation) supersedes the result.
  defp spawn_agent_result(socket, task_id, entry, agent_id) do
    parent = self()
    node = socket.assigns.current_node
    archive = entry.archive

    runner =
      Application.get_env(
        :evo_dash,
        :tasks_task_archive_agent_runner,
        &EvoDash.NodeContext.get_agent_archive/3
      )

    results =
      Map.put(agent_results(archive), agent_id, %{state: :loading, entry: nil, error: nil})

    socket =
      assign(
        socket,
        :task_details,
        Map.put(details(socket), task_id, %{entry | archive: %{archive | agent_results: results}})
      )

    seq = archive.seq

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = SafeCall.run(fn -> runner.(node, task_id, agent_id) end)
      send(parent, {:task_archive_agent_loaded, seq, node, task_id, agent_id, result})
    end)

    socket
  end

  ## Private — result folding

  # `{:ok, task}` with a map (the `%EvoGit.TaskInfo{}` struct) is the success
  # case. `{:ok, nil}` means the row vanished between the page load and the
  # expand — surfaced as `:not_found` so the card can say so.
  defp put_detail(entry, {:ok, task}) when is_map(task) do
    %{entry | state: :ok, task: task, error: nil}
  end

  defp put_detail(entry, {:ok, _other}) do
    %{entry | state: :error, task: nil, error: :not_found}
  end

  defp put_detail(entry, {:error, reason}) do
    %{entry | state: :error, task: nil, error: reason}
  end

  defp put_detail(entry, other) do
    %{entry | state: :error, task: nil, error: other}
  end

  defp new_archive(seq) do
    %{
      state: :loading,
      entries: [],
      total: 0,
      next_offset: 0,
      loading_more?: false,
      more_error: nil,
      error: nil,
      seq: seq,
      agent_results: %{}
    }
  end

  defp put_archive_first(archive, {:ok, %{entries: entries, total: total}})
       when is_list(entries) and is_integer(total) do
    entries = dedupe(entries)

    %{
      archive
      | state: :ok,
        entries: entries,
        total: max(total, 0),
        next_offset: length(entries),
        loading_more?: false,
        more_error: nil,
        error: nil
    }
  end

  defp put_archive_first(archive, {:error, reason}) do
    %{
      archive
      | state: :error,
        entries: [],
        total: 0,
        next_offset: 0,
        loading_more?: false,
        more_error: nil,
        error: reason
    }
  end

  defp put_archive_first(archive, other) do
    %{
      archive
      | state: :error,
        entries: [],
        total: 0,
        next_offset: 0,
        loading_more?: false,
        more_error: nil,
        error: other
    }
  end

  defp put_archive_more(archive, {:ok, %{entries: entries} = page}) when is_list(entries) do
    merged = dedupe(List.wrap(archive.entries) ++ entries)

    %{
      archive
      | entries: merged,
        total: more_total(page, archive.total),
        next_offset: length(merged),
        loading_more?: false,
        more_error: nil
    }
  end

  defp put_archive_more(archive, {:error, reason}) do
    # Keep the already-loaded page; the button is the retry.
    %{archive | loading_more?: false, more_error: reason}
  end

  defp put_archive_more(archive, other) do
    %{archive | loading_more?: false, more_error: other}
  end

  defp more_total(%{total: total}, _previous) when is_integer(total) and total >= 0, do: total
  defp more_total(_page, previous), do: previous

  defp put_agent_result(archive, agent_id, {:ok, entry}) when is_map(entry) do
    results =
      Map.put(agent_results(archive), agent_id, %{state: :ok, entry: entry, error: nil})

    %{
      archive
      | agent_results: results,
        entries: ArchiveHelpers.merge_entry(List.wrap(archive.entries), entry)
    }
  end

  defp put_agent_result(archive, agent_id, result) do
    error =
      case result do
        {:ok, nil} -> :not_found
        {:ok, other} -> other
        {:error, reason} -> reason
        other -> other
      end

    results =
      Map.put(agent_results(archive), agent_id, %{
        state: :error,
        entry: nil,
        error: error
      })

    %{archive | agent_results: results}
  end

  ## Private — helpers

  defp more_pages?(archive) do
    loaded = length(List.wrap(archive.entries))
    total = Map.get(archive, :total) || 0

    loaded < total and not Map.get(archive, :loading_more?, false)
  end

  defp agent_results(archive) do
    case Map.get(archive, :agent_results) do
      %{} = results -> results
      _ -> %{}
    end
  end

  # Appends are deduped by `agent_id` (first occurrence wins, input order kept),
  # so a retried page never duplicates a rendered agent. Entries without a
  # usable `agent_id` are kept as-is — the tree builder skips them.
  defp dedupe(entries) when is_list(entries) do
    {acc, _seen} =
      Enum.reduce(entries, {[], MapSet.new()}, fn
        entry, {acc, seen} when is_map(entry) ->
          case ArchiveHelpers.agent_key(entry, :agent_id) do
            id when is_binary(id) and id != "" ->
              if MapSet.member?(seen, id) do
                {acc, seen}
              else
                {[entry | acc], MapSet.put(seen, id)}
              end

            _ ->
              {[entry | acc], seen}
          end

        entry, {acc, seen} ->
          {[entry | acc], seen}
      end)

    Enum.reverse(acc)
  end

  defp maybe_bump_seq(socket, :first, seq), do: assign(socket, :task_detail_seq, seq)
  defp maybe_bump_seq(socket, :more, _seq), do: socket

  ## Private — assigns accessors (total: a missing assign is an empty cache)

  defp details(socket), do: Map.get(socket.assigns, :task_details) || %{}

  defp expanded_ids(socket) do
    case Map.get(socket.assigns, :expanded_task_ids) do
      %MapSet{} = ids -> ids
      _ -> MapSet.new()
    end
  end

  defp next_seq(socket), do: (Map.get(socket.assigns, :task_detail_seq) || 0) + 1

  defp row_ids(rows) do
    rows
    |> List.wrap()
    |> Enum.map(&Map.get(&1, :id))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp drop(socket, task_id) do
    assign(socket, :task_details, Map.delete(details(socket), task_id))
  end
end
