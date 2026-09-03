defmodule EvoGit.CommandApproval do
  @moduledoc """
  Human-in-the-loop approval gate for the self-reflective agent's command shell.

  Commands dispatched by `EvoGit.CommandShell` carry a security level: level 1
  (pure read-only inspection) executes immediately, while level 2 (needs the
  user's attention — e.g. showing a dashboard guide) and level 3 (real side
  effects — start/cancel/force-kill/delete task) do NOT execute until the user
  confirms them in the /help chat.

  `request/5` is the blocking call made from inside the shell dispatch: it
  registers a pending request, broadcasts it on the `"approvals"` PubSub topic,
  and blocks the caller until the request is resolved. The dashboard approves
  or denies via `respond/2` (locally, or from another node through
  `EvoGit.RemoteNode.respond_approval/3` → `EvoGit.AgentScheduler.RemoteAPI.respond_approval/2`).

  ## PubSub contract (topic `"approvals"`)

  - `{:approval_requested, request}` — a request opened. `request` is a map:
    `%{request_id: String.t(), command: String.t(), args: String.t(),
    level: 1 | 2 | 3, agent_id: String.t() | nil, task_id: String.t() | nil,
    node: node()}`. `command` is the shell command path (e.g.
    `"StartTask.start_task"`); `args` is a human-readable rendering of the
    parsed command arguments.
  - `{:approval_resolved, request_id, decision}` — a request closed, where
    `decision` is `:approve | :deny | :timed_out` (`:approve`/`:deny` mirror
    the `respond/2` decision; `:timed_out` covers both the approval-window
    expiry and the case where the waiting caller died before a decision).

  Invariant: every `{:approval_requested, request}` is eventually followed by
  exactly one `{:approval_resolved, request_id, decision}`.

  ## Resolution paths

  - **User responds** (`respond/2` with `:approve`/`:deny`) — the blocked
    caller is replied `:approved`/`:denied` and the handler only runs on
    `:approved` (the shell enforces this — see `EvoGit.CommandShell`).
  - **Timeout** — the request waits up to the app-env approval window
    (`[:evo_git, :command_approval_timeout]`, default `120_000` ms), then the
    caller is replied `:timeout` and the request is resolved `:timed_out`.
  - **Owning-task lifecycle** — this GenServer subscribes to the `"tasks"`
    PubSub topic; when a task that owns pending requests (matched by the
    `task_id` each request carries) transitions to `:cancelling` or a terminal
    state, its pending requests are auto-resolved as `:denied`, so a graceful
    Stop/cancel never stalls on an approval wait.
  - **Caller death** — waiting callers are monitored; if one dies (e.g. its
    tool-task timeout fired first), its pending request is cleaned up and
    resolved `:timed_out` (never a crash).

  Fails closed: `request/5` returns `:timeout` (and the command is NOT
  executed) whenever the approval service is unavailable.

  ## Approval-window / tool-timeout interplay

  Level-2/3 `run_command` tool calls block on `request/5`. The tool-dispatch
  layer (`EvoGit.Agent.ToolDispatch.execute_tool_with_timeout/7`) detects
  approval-requiring commands up front and gives them a per-call timeout of
  `max(configured, approval window + 30s)`, capped by the scheduler's
  `max_tool_timeout` (30 min). The effective approval ceiling is therefore
  `min(approval window, max_tool_timeout - 30s)`; the default 120 s window is
  well inside it.
  """

  use GenServer

  require Logger

  @topic "approvals"
  @tasks_topic "tasks"

  # The default approval window (ms). Overridable via app env
  # `[:evo_git, :command_approval_timeout]`, read per request.
  @default_approval_timeout 120_000

  # Task statuses that make a task's pending approvals moot (auto-deny).
  # `:cancelling` is included so a graceful cancel never stalls on approvals;
  # terminal states mean the owning reflect agent is gone.
  @denying_task_statuses [:cancelling, :completed, :failed, :cancelled]

  # --- Public API ------------------------------------------------------------

  @doc """
  Registers a pending approval request and BLOCKS until it is resolved.

  Called from inside `EvoGit.CommandShell` dispatch for level-2/3 commands.
  `command` is the shell command path (e.g. `"StartTask.start_task"`),
  `args_human` a human-readable rendering of the parsed arguments, `level` the
  command's security level (2 or 3), and `agent_id`/`task_id` identify the
  requesting agent/task (may be `nil` when unknown).

  Returns `:approved` (the command may run), `:denied` (the user refused — the
  command must NOT run), or `:timeout` (no decision within the approval window
  — the command must NOT run). Fails closed: `:timeout` is also returned when
  the approval service is not running.
  """
  @spec request(String.t(), String.t(), 1 | 2 | 3, String.t() | nil, String.t() | nil) ::
          :approved | :denied | :timeout
  def request(command, args_human, level, agent_id, task_id)
      when is_binary(command) and is_binary(args_human) and level in [2, 3] do
    case Process.whereis(__MODULE__) do
      nil ->
        Logger.warning(
          "EvoGit.CommandApproval: approval requested for #{command} but the service is " <>
            "not running — failing closed without executing."
        )

        :timeout

      pid ->
        GenServer.call(
          pid,
          {:request, command, args_human, level, normalize_id(agent_id), normalize_id(task_id)},
          :infinity
        )
    end
  end

  @doc """
  Resolves a pending approval request. `decision` is `:approve` (the command
  may run) or `:deny` (it must not).

  Idempotent: returns `:ok` when a pending request was resolved, or
  `{:error, :not_found}` for an unknown or already-resolved request id — never
  raises, never crashes.
  """
  @spec respond(String.t(), :approve | :deny) :: :ok | {:error, :not_found}
  def respond(request_id, decision) when is_binary(request_id) and decision in [:approve, :deny] do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:respond, request_id, decision})
    end
  end

  @doc """
  Returns the PubSub topic on which approval broadcasts ride (`"approvals"`).
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc false
  # The configured approval window in ms (used by the shell gate and by
  # ToolDispatch to size the per-call timeout of approval-requiring tools).
  @spec timeout() :: non_neg_integer()
  def timeout do
    Application.get_env(:evo_git, :command_approval_timeout, @default_approval_timeout)
  end

  # --- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(_opts) do
    # PubSub is a supervision sibling started BEFORE this child (see
    # EvoGit.Application), so subscribing in init is safe. We subscribe to the
    # "tasks" topic to auto-deny pending approvals when the owning task is
    # cancelled/reaches a terminal state. (We do NOT subscribe to "approvals"
    # — the server must not observe its own broadcasts.)
    Phoenix.PubSub.subscribe(EvoGit.PubSub, @tasks_topic)
    {:ok, %{pending: %{}}}
  end

  @impl true
  def handle_call({:request, command, args_human, level, agent_id, task_id}, from, state) do
    request_id = new_request_id()
    {caller_pid, _tag} = from

    request = %{
      request_id: request_id,
      command: command,
      args: args_human,
      level: level,
      agent_id: agent_id,
      task_id: task_id,
      node: node()
    }

    entry = %{
      request: request,
      from: from,
      timer_ref: Process.send_after(self(), {:approval_timeout, request_id}, timeout()),
      monitor_ref: :erlang.monitor(:process, caller_pid)
    }

    # The caller blocks in GenServer.call(:infinity); we reply later via
    # GenServer.reply/2 once the request is resolved.
    Phoenix.PubSub.broadcast(EvoGit.PubSub, @topic,{:approval_requested, request})

    {:noreply, %{state | pending: Map.put(state.pending, request_id, entry)}}
  end

  @impl true
  def handle_call({:respond, request_id, decision}, _from, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        {:reply, {:error, :not_found}, state}

      {entry, pending} ->
        resolve(entry, caller_result(decision))
        Phoenix.PubSub.broadcast(EvoGit.PubSub, @topic,{:approval_resolved, request_id, decision})
        {:reply, :ok, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_info({:approval_timeout, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        {:noreply, state}

      {entry, pending} ->
        resolve(entry, :timeout)
        Phoenix.PubSub.broadcast(EvoGit.PubSub, @topic,{:approval_resolved, request_id, :timed_out})
        {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # The waiting caller died (e.g. its tool-task timeout fired, or the agent
    # was force-killed). Clean up every request it owned — never crash on a
    # dead caller. Resolution broadcasts keep the approval UI consistent
    # (every requested card eventually resolves).
    {owned, rest} =
      Enum.split_with(state.pending, fn {_request_id, entry} ->
        entry.monitor_ref == ref
      end)

    if owned == [] do
      {:noreply, state}
    else
      Enum.each(owned, fn {request_id, entry} ->
        resolve(entry, :timeout)
        Phoenix.PubSub.broadcast(EvoGit.PubSub, @topic,{:approval_resolved, request_id, :timed_out})
      end)

      {:noreply, %{state | pending: Map.new(rest)}}
    end
  end

  @impl true
  def handle_info({:task_updated, task_id, status, node}, state) when node == node() do
    if status in @denying_task_statuses do
      {owned, rest} =
        Enum.split_with(state.pending, fn {_request_id, entry} ->
          entry.request.task_id == task_id
        end)

      if owned == [] do
        {:noreply, state}
      else
        Enum.each(owned, fn {request_id, entry} ->
          resolve(entry, :denied)
          Phoenix.PubSub.broadcast(EvoGit.PubSub, @topic,{:approval_resolved, request_id, :deny})
        end)

        {:noreply, %{state | pending: Map.new(rest)}}
      end
    else
      {:noreply, state}
    end
  end

  # Ignore task updates from other nodes (task ids are per-node; per the
  # PubSub event contract, node-local state must be filtered by node identity).
  def handle_info({:task_updated, _task_id, _status, _node}, state), do: {:noreply, state}

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  # --- Helpers ---------------------------------------------------------------

  # Maps a respond decision to the caller reply: :approve -> :approved,
  # :deny -> :denied.
  defp caller_result(:approve), do: :approved
  defp caller_result(:deny), do: :denied

  # Replies the blocked caller, cancels the deadline timer and the caller
  # monitor. Idempotent per entry (callers pop the entry before resolving).
  defp resolve(entry, caller_result) do
    cancel_timer(entry.timer_ref)
    :erlang.demonitor(entry.monitor_ref, [:flush])
    GenServer.reply(entry.from, caller_result)
  end

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  # The contract types agent_id/task_id as String.t() | nil; scheduler agent
  # ids are integers, so normalize integer ids to strings at the boundary.
  defp normalize_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(_other), do: nil

  defp new_request_id do
    "aprv-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
