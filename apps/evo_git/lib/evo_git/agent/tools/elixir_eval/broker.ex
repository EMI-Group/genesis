defmodule EvoGit.Agent.Tools.ElixirEval.Broker do
  @moduledoc """
  One short-lived, unregistered capability broker per evaluation.

  Only the original authorized tool may create a broker and nominate its trusted
  guardian as controller. Only that controller may attach one worker or collect
  output; the tool retains stop authority for failed handoffs. The broker monitors
  the original tool, owner and controller independently. Sandboxed requests must
  descend from the attached worker via Task/proc_lib ancestry, seeded by the
  trusted worker entry, never by evaluated code. The broker is not allowlisted.
  Caps: 128 requests (including IO), 32 reads, 500 accounting rows, 16 writes,
  four task starts, requested stdout bytes (at most 65,536). The stdout cap is
  enforced by truncation to the remaining budget (valid UTF-8 prefix, marker
  inside the cap), never by failing the evaluation; a write with no budget left
  is a bounded no-op. Facades use 1s
  registry deadlines; direct calls retain the actual public API deadlines.
  Engine applies its own timeout and final output limit as well.
  """
  use GenServer

  alias EvoGit.Agent.Tools.ElixirEval.{
    Ancestry,
    Authorization,
    DirectAPI,
    Projection,
    Render
  }

  alias EvoGit.TaskRegistry.TaskExecutor

  @reads [
           :help,
           :system_info,
           :list_tasks,
           :get_task,
           :list_agents,
           :scheduler_status,
           :model_profiles,
           :configuration_status
         ] ++ DirectAPI.read_operations()
  @writes [
            :start_task,
            :cancel_task,
            :force_kill_task,
            :delete_task,
            :guide,
            :update_scheduler_config
          ] ++ DirectAPI.write_operations()
  @starts [:start_task, {EvoGit.TaskRegistry, :start_task, 2}]
  @unavailable {:error, "Evaluation capability unavailable or expired."}
  @max_output_cap 65_536

  # This is an explicit handoff by the ORIGINAL tool, not re-authorization of
  # an unlinked guardian as if it were a tool. Keep context.tool_pid unchanged.
  def start(context, tier, controller \\ self(), timeout \\ 5_000)

  def start(context, tier, controller, timeout)
      when tier in [:read, :write, :sudo, "read", "write", "sudo"] and is_pid(controller) do
    with :ok <- Authorization.revalidate(context),
         true <- context.tool_pid == self(),
         true <- node(controller) == node() and Process.alive?(controller),
         cap when is_integer(cap) and cap > 0 and cap <= @max_output_cap <-
           Map.get(context, :max_output_bytes, 16_384) do
      GenServer.start(__MODULE__, {context, tier, self(), controller, cap}, timeout: timeout)
    else
      _ -> @unavailable
    end
  end

  def start(_, _, _, _), do: @unavailable

  def attach(pid, worker_pid, timeout \\ 5_000),
    do: safe_call(pid, {:attach, worker_pid}, timeout)

  def stop(pid, timeout \\ 5_000), do: safe_call(pid, :stop, timeout)

  def output(pid, timeout \\ 5_000) do
    case safe_call(pid, :output, timeout) do
      output when is_binary(output) -> output
      _ -> ""
    end
  end

  def call(operation, args) do
    case Ancestry.broker(self()) do
      pid when is_pid(pid) -> safe_call(pid, {:operation, operation, args})
      _ -> @unavailable
    end
  end

  # This is the IPC boundary: never include server exit reasons, which can
  # contain request arguments, exception values or configuration secrets.
  defp safe_call(pid, message, timeout \\ 5_000) do
    try do
      GenServer.call(pid, message, timeout)
    catch
      :exit, _ -> @unavailable
    end
  end

  @impl true
  def init({context, tier, creator, controller, cap}) do
    {:ok,
     %{
       context: context,
       tier: tier,
       creator: creator,
       controller: controller,
       output_cap: cap,
       owner_monitor: Process.monitor(context.owner_pid),
       creator_monitor: Process.monitor(creator),
       controller_monitor: Process.monitor(controller),
       worker: nil,
       worker_monitor: nil,
       attached: false,
       pending: nil,
       output: "",
       requests: 0,
       reads: 0,
       rows: 0,
       writes: 0,
       starts: 0
     }}
  end

  @impl true
  def handle_call({:attach, worker}, {caller, _}, state) do
    if caller == state.controller and not state.attached and is_pid(worker) and
         worker != caller and worker_child?(worker, caller) and
         Authorization.revalidate(state.context) == :ok do
      {:reply, :ok,
       %{state | worker: worker, worker_monitor: Process.monitor(worker), attached: true}}
    else
      {:reply, @unavailable, state}
    end
  end

  def handle_call(:output, {caller, _}, state) do
    output =
      if caller == state.controller and Authorization.revalidate(state.context) == :ok,
        do: state.output,
        else: ""

    {:reply, output, state}
  end

  def handle_call(:stop, {caller, _}, state)
      when caller == state.creator or caller == state.controller do
    {:stop, :normal, :ok, state}
  end

  def handle_call({:operation, operation, args}, {caller, _} = from, state) do
    if not is_pid(state.worker) or not Ancestry.includes?(caller, state.worker) do
      {:reply, @unavailable, state}
    else
      if state.requests >= 128 or state.pending != nil do
        {:reply, {:error, "Evaluation request limit reached."}, state}
      else
        process_operation(operation, args, from, %{state | requests: state.requests + 1})
      end
    end
  end

  def handle_call(_, _, state), do: {:reply, @unavailable, state}

  defp process_operation({:direct, operation}, args, from, state) do
    case DirectAPI.prepare(operation, args) do
      {:ok, mfa, arguments} -> process_validated(mfa, arguments, from, state, :direct)
      error -> {:reply, error, state}
    end
  end

  defp process_operation(operation, args, from, state),
    do: process_validated(operation, args, from, state, :facade)

  defp process_validated(operation, args, from, state, mode) do
    cost = read_cost(operation, args)

    cond do
      operation in @reads and (state.reads >= 32 or state.rows + cost > 500) ->
        {:reply, {:error, "Evaluation read limit reached."}, state}

      operation in @writes and
          (state.tier not in [:write, :sudo, "write", "sudo"] or state.writes >= 16 or
             (operation in @starts and state.starts >= 4)) ->
        {:reply, {:error, "Write capability unavailable or write limit reached."}, state}

      operation == :stdio ->
        append_stdio(args, state)

      operation in @reads or operation in @writes ->
        context = state.context
        # A separate trusted task keeps the broker responsive to owner/tool/
        # evaluator DOWN while bounded runtime calls are in progress.
        task = Task.async(fn -> execute_safely(operation, args, context, mode) end)

        {:noreply,
         %{
           state
           | pending: {task, from},
             reads: state.reads + if(operation in @reads, do: 1, else: 0),
             rows: state.rows + cost,
             writes: state.writes + if(operation in @writes, do: 1, else: 0),
             starts: state.starts + if(operation in @starts, do: 1, else: 0)
         }}

      true ->
        {:reply, {:error, "Unknown evaluation operation."}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{pending: {%Task{ref: ref}, from}} = state) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(from, result)
    {:noreply, %{state | pending: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state)
      when ref == state.owner_monitor or ref == state.creator_monitor or
             ref == state.controller_monitor do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{worker_monitor: ref} = state) do
    cancel_pending(state.pending)
    {:noreply, %{state | worker: nil, pending: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{pending: {%Task{ref: ref}, from}} = state) do
    GenServer.reply(from, @unavailable)
    {:noreply, %{state | pending: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    cancel_pending(state.pending)

    if is_pid(state.worker) and Process.alive?(state.worker),
      do: Process.exit(state.worker, :kill)

    :ok
  end

  # The trusted worker entry installs precisely this immediate ancestor BEFORE
  # announcing readiness. A transitive ancestor or native link is not sufficient:
  # links are mutable and would admit unrelated processes during startup.
  defp worker_child?(worker, controller) do
    case Process.info(worker, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, :"$ancestors") == [controller]
      _ -> false
    end
  end

  defp cancel_pending(nil), do: :ok

  defp cancel_pending({task, from}) do
    Task.shutdown(task, :brutal_kill)
    GenServer.reply(from, @unavailable)
  end

  # The broker is the SINGLE enforcement point for the captured-stdout budget.
  # Output volume never fails an evaluation: an item larger than the remaining
  # budget is truncated to it, and a write with no budget left is a bounded
  # no-op. Only expired authority or a malformed item is refused.
  defp append_stdio([binary], state) when is_binary(binary) do
    cond do
      Authorization.revalidate(state.context) != :ok ->
        {:reply, {:error, "Evaluation stdout rejected or authority expired."}, state}

      byte_size(state.output) >= state.output_cap ->
        {:reply, :ok, state}

      String.valid?(binary) ->
        {:reply, :ok, append_to_budget(state, binary)}

      true ->
        {:reply, {:error, "Invalid stdout."}, state}
    end
  end

  defp append_stdio(_, state), do: {:reply, {:error, "Invalid stdout."}, state}

  # Total captured stdout never exceeds output_cap: keep the longest valid UTF-8
  # prefix that fits the remaining budget, with Render.text/2's truncation marker
  # inside the cap when bytes were dropped. An exhausted budget appends nothing.
  defp append_to_budget(state, binary) do
    remaining = max(state.output_cap - byte_size(state.output), 0)

    case Render.text(binary, remaining) do
      "" -> state
      chunk -> %{state | output: state.output <> chunk}
    end
  end

  # Native facade boundary: unexpected runtime failures must not leak inspected
  # errors or secrets to Dune's value/stdout channel. Known errors stay explicit.
  defp execute_safely(operation, args, context, mode) do
    try do
      with :ok <- Authorization.revalidate(context) do
        result = execute(operation, args, context, mode)
        with :ok <- Authorization.revalidate(context), do: result
      end
    rescue
      _ -> {:error, "Runtime operation failed."}
    catch
      :exit, _ when operation == :update_scheduler_config ->
        {:error,
         "Scheduler update outcome unknown; inspect configuration_status before retrying. A timeout does not roll back effects."}

      _, _ ->
        {:error, "Runtime operation unavailable."}
    end
  end

  defp execute(:help, [], _), do: EvoGit.Agent.Tools.ElixirEval.help()

  defp execute(:system_info, [], _), do: Projection.system_info()
  defp execute(:list_tasks, [options], context), do: Projection.tasks(context, options)
  defp execute(:get_task, [id], context), do: Projection.get_task(context, id)
  defp execute(:list_agents, [], _), do: Projection.agents()
  defp execute(:scheduler_status, [], _), do: Projection.scheduler_status()
  defp execute(:model_profiles, [], _), do: Projection.model_profiles()
  defp execute(:configuration_status, [], _), do: Projection.configuration_status()

  defp execute(:guide, [message, options], context) do
    with {:ok, payload} <- EvoGit.Agent.Tools.ElixirEval.Validation.guide(message, options),
         :ok <- Authorization.revalidate(context) do
      id = "guide-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

      case Phoenix.PubSub.broadcast(
             EvoGit.PubSub,
             "guides",
             {:guide_updated, id, payload, node()}
           ) do
        :ok -> %{status: :sent}
        _ -> {:error, "Guide delivery unavailable."}
      end
    end
  end

  defp execute(_, _, _), do: {:error, "Invalid operation arguments."}

  # Direct operations are exact MFA tokens, never facade operation names.
  # Authorization is revalidated around this call by execute_safely/4, and the
  # real API alone owns argument validation, effects and returned terms.
  defp execute(operation, args, context, :direct),
    do: DirectAPI.execute(operation, args, context)

  defp execute(:update_scheduler_config, [options], context, :facade) do
    with {:ok, opts} <-
           EvoGit.Agent.Tools.ElixirEval.Validation.scheduler_options(options),
         :ok <- Authorization.revalidate(context) do
      # Pause/resume must use their own scheduler transitions: update_config
      # intentionally ignores :paused, and resume also dispatches queued agents.
      # Require paused alone so each facade call sends exactly one mutation.
      request =
        case opts do
          [paused: true] -> :pause
          [paused: false] -> :resume
          _ -> {:update_config, opts}
        end

      case GenServer.call(EvoGit.AgentScheduler, request, 1_000) do
        :ok ->
          %{status: :updated, scope: :runtime, persisted: false, settings: Map.new(opts)}

        _ ->
          {:error,
           "Scheduler update not acknowledged; inspect configuration_status before retrying."}
      end
    end
  end

  defp execute(:start_task, [type, options], context, :facade) do
    with {:ok, task_type, opts} <-
           EvoGit.Agent.Tools.ElixirEval.Validation.start_options(type, options),
         :ok <- Authorization.revalidate(context) do
      id = TaskExecutor.generate_id()

      case GenServer.call(context.registry, {:start_task, id, task_type, opts}, 1_000) do
        {:ok, task} when is_map(task) ->
          %{task_id: Projection.text(Map.get(task, :id), 128), status: :submitted}

        _ ->
          {:error, "Task submission failed; inspect tasks before retrying."}
      end
    end
  end

  defp execute(operation, [id], context, :facade)
       when operation in [:cancel_task, :force_kill_task, :delete_task] do
    allowed =
      case operation do
        :cancel_task -> [:pending, :running]
        :force_kill_task -> [:running, :cancelling]
        :delete_task -> [:completed, :failed, :cancelled]
      end

    with :ok <- Projection.task_id(id),
         false <- id == context.task_id,
         %{status: status} <- Projection.get_task(context, id),
         true <- status in allowed,
         :ok <- Authorization.revalidate(context) do
      case operation do
        :delete_task ->
          GenServer.cast(context.registry, {:delete_task, id})

          %{
            task_id: id,
            status: :queued,
            acknowledgement: "Deletion queued; persistence is not acknowledged."
          }

        _ ->
          case GenServer.call(context.registry, {operation, id}, 1_000) do
            :ok -> %{task_id: id, status: :requested}
            _ -> {:error, "Task action refused; refresh its current state."}
          end
      end
    else
      _ -> {:error, "Task action requires a different, existing task in an allowed state."}
    end
  end

  defp execute(operation, args, context, _mode), do: execute(operation, args, context)

  defp read_cost(:list_tasks, [options]) when is_map(options) do
    case Projection.page_options(options) do
      {:ok, opts} -> opts[:limit]
      _ -> 0
    end
  end

  defp read_cost(operation, _)
       when operation in [:list_agents, :model_profiles], do: 100

  defp read_cost(operation, _) when operation in @reads, do: 1
  defp read_cost(_, _), do: 0
end
