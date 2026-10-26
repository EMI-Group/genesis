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
  | the lite detail (full `%EvoGit.TaskInfo{}`, archive nil'd) | `:tasks_task_detail_runner` (2-arity) | `EvoDash.NodeContext.get_task_lite/2` |
  | the archive records (`[map]`) | `:tasks_task_archive_runner` (2-arity) | `EvoDash.NodeContext.get_task_archive/2` |

  Both seams are resolved AT SPAWN TIME from app env (the dashboard's
  runner-seam idiom), so a test can inject an exiting runner and assert the
  LiveView survives.

  ## Async, exit-safe, push-only

  Every fetch is ONE supervised `EvoDash.TaskSupervisor` child running
  `EvoDash.SafeCall.run/1` around the runner call, which always sends its
  result back to the LiveView:

    * `{:task_detail_loaded, seq, node, task_id, result}`
    * `{:task_archive_loaded, seq, node, task_id, result}`

  A `GenServer.call` timeout / dead store EXITS its caller (`rescue` cannot
  catch it), so the call runs off-process and the exit becomes
  `{:error, reason}` — the card renders an inline error strip with a Retry
  action instead of the LiveView dying or its loading state wedging.
  No polling: results arrive only from those two messages.

  ## Guards (applied on apply, never crashing)

    1. the message's `node` must still equal `socket.assigns.current_node`
       (a node switch drops every in-flight result), and
    2. the entry for `task_id` must still exist AND its `seq` must equal the
       message's `seq` — a newer fetch (or an invalidated/pruned entry)
       supersedes an older one.

  ## Cached-entry shape

      %{
        state: :loading | :ok | :error,
        task: %EvoGit.TaskInfo{} | nil,
        error: term() | nil,
        seq: pos_integer(),
        archive:
          nil
          | %{state: :loading | :ok | :error, records: [map()], error: term() | nil, seq: pos_integer()}
      }

  `:task_details` never holds more than ONE page's worth of entries:
  `prune/2` runs on every landed page load and drops everything that is not on
  the freshly loaded page.
  """

  import Phoenix.Component, only: [assign: 3]

  alias EvoDash.SafeCall

  @typedoc "The lazy per-task detail entry stored under `:task_details`."
  @type entry :: %{
          state: :loading | :ok | :error,
          task: map() | nil,
          error: term() | nil,
          seq: pos_integer(),
          archive: archive_entry() | nil
        }

  @typedoc "The lazy per-task archive entry nested inside an `entry/0`."
  @type archive_entry :: %{
          state: :loading | :ok | :error,
          records: [map()],
          error: term() | nil,
          seq: pos_integer()
        }

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
  Fetches the archive records for `task_id` when the card asks for them.

  No-op unless the detail entry exists and is `:ok` (an archive read without
  the lite detail is not a state this page renders). Also a cache + in-flight
  guard: `archive: nil` or an `:error` archive is (re)fetched, while a
  `:loading`/`:ok` archive is left alone.
  """
  @spec load_archive(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def load_archive(socket, task_id) do
    case Map.get(details(socket), task_id) do
      %{state: :ok} = entry ->
        case Map.get(entry, :archive) do
          %{state: state} when state in [:loading, :ok] -> socket
          _ -> spawn_archive(socket, task_id)
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
  detail. A collapsed card stays uncached until the next expand.
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
  / `apply_archive/5`.
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

  Same node + entry + seq guards as `apply_detail/5`. `{:ok, records}` with a
  list → `:ok` (the empty list is a valid "this task archived nothing"), any
  other result → `:error`.
  """
  @spec apply_archive(Phoenix.LiveView.Socket.t(), pos_integer(), node(), String.t(), term()) ::
          Phoenix.LiveView.Socket.t()
  def apply_archive(socket, seq, node, task_id, result) do
    details = details(socket)

    case Map.get(details, task_id) do
      %{archive: %{seq: ^seq} = archive} = entry ->
        if node == socket.assigns.current_node do
          assign(
            socket,
            :task_details,
            Map.put(details, task_id, %{entry | archive: put_archive(archive, result)})
          )
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

  # Spawns ONE archive fetch for an entry that is already `:ok`. The archive
  # carries its OWN seq so a detail refetch does not invalidate it (and vice
  # versa) — both draw from the same monotonic counter.
  defp spawn_archive(socket, task_id) do
    seq = next_seq(socket)
    parent = self()
    node = socket.assigns.current_node

    runner =
      Application.get_env(
        :evo_dash,
        :tasks_task_archive_runner,
        &EvoDash.NodeContext.get_task_archive/2
      )

    entry = Map.fetch!(details(socket), task_id)
    archive = %{state: :loading, records: [], error: nil, seq: seq}

    socket =
      socket
      |> assign(:task_details, Map.put(details(socket), task_id, %{entry | archive: archive}))
      |> assign(:task_detail_seq, seq)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = SafeCall.run(fn -> runner.(node, task_id) end)
      send(parent, {:task_archive_loaded, seq, node, task_id, result})
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

  defp put_archive(archive, {:ok, records}) when is_list(records) do
    %{archive | state: :ok, records: records, error: nil}
  end

  defp put_archive(archive, {:error, reason}) do
    %{archive | state: :error, records: [], error: reason}
  end

  defp put_archive(archive, other) do
    %{archive | state: :error, records: [], error: other}
  end

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
