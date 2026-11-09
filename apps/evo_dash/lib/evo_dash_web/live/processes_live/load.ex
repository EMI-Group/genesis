defmodule EvoDashWeb.ProcessesLive.Load do
  @moduledoc """
  Async, exit-safe initial load for the Processes page
  (`EvoDashWeb.ProcessesLive`).

  ONE load = ONE supervised `EvoDash.TaskSupervisor` child that calls the
  process-manager RPC (`EvoDash.NodeContext.list_processes/2` by default) and
  reports back to the LiveView as `{:processes_loaded, seq, node, result}`.
  The LiveView process never blocks on a store/RPC call: a `GenServer.call`
  to a dead or busy target EXITS its caller instead of returning an error, so
  the fetch runs off-process inside `EvoDash.SafeCall.run/1` — an exit becomes
  an `{:error, reason}` value and the result message is ALWAYS sent, so the
  page's loading flag can never stick.

  `start/1` is the only writer of the monotonic `:load_seq` assign; the caller
  drops any result whose `seq` is stale or whose `node` no longer matches
  `socket.assigns.current_node`.

  App-env seam, resolved AT SPAWN TIME: `:processes_page_load_runner` — a
  2-arity `(node, opts)` function, default `&EvoDash.NodeContext.list_processes/2`.

  Liveness after the first load is push-based (PubSub topic `"processes"`);
  this module only constructs the initial snapshot, plus the refetch the page
  performs when a CORE-side filter (`:agent_id` / `:task_id`) or the node
  changes.
  """

  import Phoenix.Component, only: [assign: 3]

  alias EvoDash.SafeCall

  @doc """
  Starts one async load and returns the socket.

  Bumps `:load_seq`, paints the loading state, and spawns the loader. The node
  and the core-side filters are read from the socket BEFORE the spawn, so a
  later node switch cannot retarget an in-flight request.
  """
  @spec start(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def start(socket) do
    seq = socket.assigns.load_seq + 1
    node = socket.assigns.current_node
    opts = core_opts(socket)
    spawn_loader(self(), seq, node, opts)

    socket
    |> assign(:load_seq, seq)
    |> assign(:executions_loading, true)
  end

  @doc """
  Spawns the loader task and reports its result to `parent`.

  The page-load FUNCTION is resolved from the `:processes_page_load_runner`
  app-env seam at spawn time (the dashboard's runner-seam idiom), so an
  injected runner is honoured by every caller. `SafeCall.run/1` converts exits,
  raises and throws into values; the message is sent unconditionally.
  """
  @spec run(pid(), pos_integer(), node(), keyword()) :: :ok
  def run(parent, seq, node, opts) do
    runner = Application.get_env(:evo_dash, :processes_page_load_runner, &load/2)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = SafeCall.run(fn -> runner.(node, opts) end) |> normalize()
      send(parent, {:processes_loaded, seq, node, result})
    end)

    :ok
  end

  @doc """
  Fetches the tracked executions of `node`, newest first.

  The RPC itself is total (a failed call degrades to `[]`); this module keeps
  the list-or-error contract explicit so a runner returning something else is
  reported instead of rendered as a broken list.
  """
  @spec load(node(), keyword()) :: [EvoGit.ProcessManager.Execution.t()]
  def load(node, opts), do: EvoDash.NodeContext.list_processes(node, opts)

  @doc """
  The CORE-side RPC filters of the current page: only `:agent_id` and
  `:task_id` (the filters that need a server round trip because they narrow
  the tracked set itself). Status tab / kind / free text are render-time
  (`EvoDashWeb.ProcessesLive.Format.filter/2`).
  """
  @spec core_opts(Phoenix.LiveView.Socket.t()) :: keyword()
  def core_opts(socket) do
    []
    |> put_filter(:agent_id, Map.get(socket.assigns, :agent_filter))
    |> put_filter(:task_id, Map.get(socket.assigns, :task_filter))
  end

  @doc """
  Best-effort type for an id read from a URL query parameter.

  Core executions store `agent_id`/`task_id` as the runtime's own terms (agent
  ids are integers) while a URL parameter is always a string; an exact-match
  filter therefore needs the native shape back. A fully numeric value becomes
  an integer, everything else stays a string — never an atom conversion.
  """
  def typed_id(nil), do: nil
  def typed_id(""), do: nil

  def typed_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> value
    end
  end

  def typed_id(value), do: value

  defp put_filter(opts, key, value) do
    case typed_id(value) do
      nil -> opts
      typed -> Keyword.put(opts, key, typed)
    end
  end

  defp spawn_loader(parent, seq, node, opts) do
    run(parent, seq, node, opts)
  end

  defp normalize({:ok, list}) when is_list(list), do: {:ok, list}
  defp normalize({:ok, other}), do: {:error, {:invalid_result, other}}
  defp normalize({:error, reason}), do: {:error, reason}
end
