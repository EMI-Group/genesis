defmodule EvoGit.Agent.Tools.ElixirEval.DirectAPI do
  @moduledoc """
  Exact direct API admission registry and trusted Dune shims.
  Real API spellings are not namespace grants: every admitted MFA is intercepted
  and routed through the same authenticated, quota-limited broker as the facades.
  """
  alias EvoGit.Agent.Tools.ElixirEval.{Broker, Projection, Validation}

  @entries [
    {EvoGit.TaskRegistry, :list_tasks_page, 0, :read, :task_page, :task_page},
    {EvoGit.TaskRegistry, :list_tasks_page, 1, :read, :task_page, :task_page},
    {EvoGit.TaskRegistry, :get_task_lite, 1, :read, :task_detail, :task_detail},
    {EvoGit.TaskRegistry, :get_task, 1, :read, :task_detail, :task_detail},
    {EvoGit.AgentScheduler.RemoteAPI, :list_agents, 0, :read, :agent_page, :agent_page},
    {EvoGit.AgentScheduler, :get_config, 1, :read, :config_leaf, :config_leaf},
    {EvoGit.AgentScheduler, :paused?, 0, :read, :paused, :paused},
    {EvoGit.AgentScheduler, :get_llm_slot_status, 0, :read, :slots, :slots},
    {EvoGit.Config, :resolve, 1, :read, :resolved_leaf, :resolved_leaf},
    {EvoGit.TaskRegistry, :start_task, 2, :write, :start_task, :start_task},
    {EvoGit.TaskRegistry, :cancel_task, 1, :write, :cancel_task, :cancel_task},
    {EvoGit.TaskRegistry, :force_kill_task, 1, :write, :force_kill_task, :force_kill_task},
    {EvoGit.TaskRegistry, :delete_task, 1, :write, :delete_task, :delete_task},
    {EvoGit.AgentScheduler, :update_config, 1, :write, :update_scheduler_config, :update_config},
    {EvoGit.AgentScheduler, :pause, 0, :write, :pause, :pause},
    {EvoGit.AgentScheduler, :resume, 0, :write, :resume, :resume}
  ]
  @scalar_keys [:default_llm_max_concurrency, :max_tool_concurrency, :max_turns, :max_turns_root]
  @read_operations for {_, _, _, :read, operation, _} <- @entries, uniq: true, do: operation

  def entries, do: @entries
  def read_operations, do: @read_operations
  def scalar_keys, do: @scalar_keys

  @facades [
    {EvoGit.Agent.Tools.ElixirEval.Read, :help, 0, :read},
    {EvoGit.Agent.Tools.ElixirEval.Read, :system_info, 0, :read},
    {EvoGit.Agent.Tools.ElixirEval.Read, :list_tasks, 0, :read},
    {EvoGit.Agent.Tools.ElixirEval.Read, :list_tasks, 1, :read},
    {EvoGit.Agent.Tools.ElixirEval.Read, :get_task, 1, :read},
    {EvoGit.Agent.Tools.ElixirEval.Read, :list_agents, 0, :read},
    {EvoGit.Agent.Tools.ElixirEval.Read, :scheduler_status, 0, :read},
    {EvoGit.Agent.Tools.ElixirEval.Read, :model_profiles, 0, :read},
    {EvoGit.Agent.Tools.ElixirEval.Read, :configuration_status, 0, :read},
    {EvoGit.Agent.Tools.ElixirEval.Write, :start_task, 2, :write},
    {EvoGit.Agent.Tools.ElixirEval.Write, :cancel_task, 1, :write},
    {EvoGit.Agent.Tools.ElixirEval.Write, :force_kill_task, 1, :write},
    {EvoGit.Agent.Tools.ElixirEval.Write, :delete_task, 1, :write},
    {EvoGit.Agent.Tools.ElixirEval.Write, :guide, 1, :write},
    {EvoGit.Agent.Tools.ElixirEval.Write, :guide, 2, :write},
    {EvoGit.Agent.Tools.ElixirEval.Write, :update_scheduler_config, 1, :write}
  ]

  def runtime_module?(module) when is_atom(module),
    do: module == EvoGit or String.starts_with?(Atom.to_string(module), "Elixir.EvoGit.")

  def runtime_module?(_), do: false

  def status(module, name, arity, tier) do
    cond do
      {module, name, arity, :read} in @facades -> :allowed
      tier == :write and {module, name, arity, :write} in @facades -> :allowed
      true -> direct_status(module, name, arity, tier)
    end
  end

  defp direct_status(module, name, arity, tier) do
    case Enum.find(@entries, fn {m, f, a, _, _, _} -> {m, f, a} == {module, name, arity} end) do
      {_, _, _, required, _, shim} when required == :read or tier == :write ->
        {:shimmed, __MODULE__, shim}

      _ ->
        :restricted
    end
  end

  # Dune supplies its environment as the first shim argument. No evaluated
  # module/function is ever passed to apply; these functions are generated only
  # from the literal registry, and the broker receives a fixed operation token.
  for {_, _, arity, _, operation, shim} <-
        Enum.uniq_by(@entries, fn {_, _, a, _, _, s} -> {s, a} end) do
    args = Macro.generate_arguments(arity, __MODULE__)

    def unquote(shim)(_env, unquote_splicing(args)),
      do: Broker.call({:direct, unquote(operation)}, [unquote_splicing(args)])
  end

  def prepare(:task_page, []), do: prepare(:task_page, [[]])
  def prepare(:task_page, [opts]), do: keyword_options(:task_page, opts)

  def prepare(:start_task, [type, opts])
      when type in [:genesis, :evolve, :reflect, :extract_skills] do
    with {:ok, map} <- Validation.keyword_map(opts) do
      {:ok, :start_task, [Atom.to_string(type), map]}
    end
  end

  def prepare(:pause, []), do: {:ok, :update_scheduler_config, [%{paused: true}]}
  def prepare(:resume, []), do: {:ok, :update_scheduler_config, [%{paused: false}]}

  def prepare(:update_scheduler_config, []) do
    {:error, "Invalid scheduler mutation arguments."}
  end

  def prepare(:update_scheduler_config, [opts]) do
    with {:ok, map} <- Validation.keyword_map(opts),
         false <- Map.has_key?(map, :paused) do
      {:ok, :update_scheduler_config, [map]}
    else
      _ ->
        {:error,
         "update_config accepts numeric scheduler keywords only; use pause/0 or resume/0."}
    end
  end

  def prepare(operation, args)
      when operation in @read_operations or
             operation in [:cancel_task, :force_kill_task, :delete_task],
      do: {:ok, operation, args}

  def prepare(_, _), do: {:error, "Invalid direct API arguments."}

  defp keyword_options(operation, opts) do
    with {:ok, map} <- Validation.keyword_map(opts), do: {:ok, operation, [map]}
  end

  def execute_read(:task_page, [options], context) do
    case Projection.tasks(context, options) do
      %{rows: rows, total: total} -> %{rows: rows, total: total}
      error -> error
    end
  end

  def execute_read(:task_detail, [id], context) do
    with :ok <- Projection.task_id(id) do
      context.registry
      |> GenServer.call({:get_task_lite, id}, 1_000)
      |> Projection.task_detail()
    end
  end

  # Avoid RemoteAPI.list_agents' unbounded copies of contexts and credentials.
  # Preserve its list shape, but expose only one projected ETS page.
  def execute_read(:agent_page, [], _), do: Projection.agents().agents

  def execute_read(:config_leaf, [key], _) when key in @scalar_keys or key == :paused do
    value = GenServer.call(EvoGit.AgentScheduler, {:get_config, key}, 1_000)
    if key == :paused, do: Projection.enum(value, [true, false]), else: Projection.count(value)
  end

  def execute_read(:paused, [], _),
    do: Projection.enum(GenServer.call(EvoGit.AgentScheduler, :paused?, 1_000), [true, false])

  def execute_read(:slots, [], _) do
    case GenServer.call(EvoGit.AgentScheduler, :get_llm_slot_status, 1_000) do
      slots when is_map(slots) and map_size(slots) <= 100 ->
        Map.new(slots, fn {id, slot} ->
          {Projection.text(id, 128),
           Map.new([:used, :waiting, :capacity], fn key ->
             {key, Projection.count(Map.get(slot, key))}
           end)}
        end)

      _ ->
        {:error, "Slot status exceeds the inspection limit."}
    end
  end

  def execute_read(:resolved_leaf, [[:scheduler, key] = path], _) when key in @scalar_keys do
    # Config resolution may read disk; bound it independently of engine timeout.
    task = Task.async(fn -> resolve_leaf(path) end)

    case Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, "Resolved configuration unavailable."}
    end
  end

  def execute_read(_, _, _),
    do: {:error, "Only documented nonsecret scalar keys and scheduler leaf paths are admitted."}

  # This extra IPC worker must never die abnormally through its Task link:
  # configuration callbacks/errors can contain secrets, so withhold all details.
  defp resolve_leaf(path) do
    try do
      Projection.count(EvoGit.Config.resolve(path))
    rescue
      _ -> {:error, "Resolved configuration unavailable."}
    catch
      _, _ -> {:error, "Resolved configuration unavailable."}
    end
  end

  def help do
    reads = signatures(:read)
    writes = signatures(:write)

    """
    Direct local APIs (fully qualified calls, no alias declarations):
    Read: #{reads}.
    Write (exact-code approval required): #{writes}.
    Example: EvoGit.TaskRegistry.list_tasks_page(limit: 10, status: :running)
    Example: EvoGit.AgentScheduler.get_config(:max_turns)
    Example (write): EvoGit.AgentScheduler.update_config(max_tool_concurrency: 8)
    Start uses an atom type and keyword options, e.g. EvoGit.TaskRegistry.start_task(:reflect, objective: "Inspect tasks").
    Task pages accept only limit 1..50, offset 0..10000 and status; return %{rows: projected_maps, total: count}.
    get_task/get_task_lite return nil or a projected map (NOT TaskInfo): status/timestamps plus objective (falling back to prompt) and selected report text, each capped at 8000 bytes with truncation flags. Error/exit terms and failed/nonterminal binary crash fallbacks are omitted; opts, attachments, histories and credential fields are never returned. Deliberately supplied objective/report text is not secret-redacted.
    list_agents returns at most 100 unsorted projected maps (id,parent_id,depth,status,task_id); it omits heavy state and may be truncated.
    start_task returns {:ok, projected_task}, cancel/force_kill return :ok, delete returns :ok meaning queued cast ONLY, not persisted deletion.
    get_config accepts only #{@scalar_keys |> Enum.map_join(", ", &inspect/1)} and :paused; get_llm_slot_status returns at most 100 scalar-projected model entries.
    Config.resolve accepts only [:scheduler, key] for those four numeric keys: resolved defaults/user/session config, NOT necessarily live scheduler state.
    update_config accepts nonempty numeric keywords for those four keys (concurrency 1..256, turns 1..10000); pause/resume are separate calls. Updates are runtime-only, turn caps affect future agents, floors and peak pauses remain intact.
    Start options are path/mode/objective/prompt/model_id only; no custom, resume, merge or foreign-repo modes. Self-targeting mutations are refused.
    Every call retains broker authority, quotas and 1s runtime-call deadlines. Timeouts do not roll back effects; inspect state before retrying mutations.
    No other EvoGit MFAs/arities are admitted. Existing Read/Write facades remain available.
    Config.save_user_config and RemoteAPI.save_user_config are excluded: whole-config replacement is not a patch, is non-atomic and lacks reliable reload acknowledgement. No persistent configuration write API is admitted.
    """
  end

  defp signatures(tier) do
    @entries
    |> Enum.filter(fn {_, _, _, t, _, _} -> t == tier end)
    |> Enum.map_join(", ", fn {m, f, a, _, _, _} -> "#{inspect(m)}.#{f}/#{a}" end)
  end
end
