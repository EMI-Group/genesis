defmodule EvoGit.Agent.Tools.ElixirEval.DirectAPI do
  @moduledoc """
  Literal exact-MFA admission and trusted Dune shims for real runtime APIs.
  Calls retain broker authority and tier checks, but pass arguments and return
  values unchanged: these are not aliases for the projected Read/Write facades.
  """
  alias EvoGit.Agent.Tools.ElixirEval.Broker

  @entries [
    {EvoGit.TaskRegistry, :list_tasks_page, 0, :read},
    {EvoGit.TaskRegistry, :list_tasks_page, 1, :read},
    {EvoGit.TaskRegistry, :get_task_lite, 1, :read},
    {EvoGit.TaskRegistry, :get_task, 1, :read},
    {EvoGit.AgentScheduler.RemoteAPI, :list_agents, 0, :read},
    {EvoGit.AgentScheduler, :get_config, 1, :read},
    {EvoGit.AgentScheduler, :paused?, 0, :read},
    {EvoGit.AgentScheduler, :get_llm_slot_status, 0, :read},
    {EvoGit.Config, :resolve, 0, :read},
    {EvoGit.Config, :resolve, 1, :read},
    {EvoGit.Config, :list_settings, 0, :read},
    {EvoGit.Config, :show, 0, :read},
    {EvoGit.Config, :show, 1, :read},
    {EvoGit.Config, :user_config, 0, :read},
    {EvoGit.Config, :config_path, 0, :read},
    {EvoGit.VCT, :projects, 0, :read},
    {EvoGit.VCT, :projects, 1, :read},
    {EvoGit.VCT, :search, 1, :read},
    {EvoGit.VCT, :search, 2, :read},
    {EvoGit.TaskRegistry, :start_task, 2, :write},
    {EvoGit.TaskRegistry, :cancel_task, 1, :write},
    {EvoGit.TaskRegistry, :force_kill_task, 1, :write},
    {EvoGit.TaskRegistry, :pause_task, 1, :write},
    {EvoGit.TaskRegistry, :resume_task, 1, :write},
    {EvoGit.TaskRegistry, :delete_task, 1, :write},
    {EvoGit.AgentScheduler, :update_config, 1, :write},
    {EvoGit.AgentScheduler, :pause, 0, :write},
    {EvoGit.AgentScheduler, :resume, 0, :write},
    {EvoGit.Config, :save_user_config, 1, :write},
    {EvoGit.Config, :update, 1, :write},
    {EvoGit.AgentScheduler.RemoteAPI, :reload_config, 0, :write}
  ]
  @read_operations for {m, f, a, :read} <- @entries, do: {m, f, a}
  @write_operations for {m, f, a, :write} <- @entries, do: {m, f, a}

  def entries, do: @entries
  def read_operations, do: @read_operations
  def write_operations, do: @write_operations

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
    {EvoGit.Agent.Tools.ElixirEval.Write, :pause_task, 1, :write},
    {EvoGit.Agent.Tools.ElixirEval.Write, :resume_task, 1, :write},
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
      {module, name, arity, :read} in @facades ->
        :allowed

      tier == :write and {module, name, arity, :write} in @facades ->
        :allowed

      {module, name, arity, :read} in @entries ->
        {:shimmed, __MODULE__, name}

      tier == :write and {module, name, arity, :write} in @entries ->
        {:shimmed, __MODULE__, name}

      true ->
        :restricted
    end
  end

  # Dune supplies env first. Every shim and native invocation is generated from
  # this literal registry; evaluated code never selects an arbitrary apply target.
  # Function names are unique across the admitted modules (arities may differ).
  for {module, name, arity, _tier} <- @entries do
    args = Macro.generate_arguments(arity, __MODULE__)
    operation = Macro.escape({module, name, arity})

    def unquote(name)(_env, unquote_splicing(args)),
      do: Broker.call({:direct, unquote(operation)}, [unquote_splicing(args)])
  end

  for {module, name, arity, _tier} <- @entries do
    args = Macro.generate_arguments(arity, __MODULE__)
    operation = Macro.escape({module, name, arity})

    def execute(unquote(operation), [unquote_splicing(args)], context) do
      # Public TaskRegistry clients use a process-local routing seam. Preserve
      # the authenticated registry, not an evaluator-supplied destination.
      Process.put(:evogit_task_registry_server, context.registry)
      unquote(module).unquote(name)(unquote_splicing(args))
    end
  end

  def prepare(operation, args)
      when (operation in @read_operations or operation in @write_operations) and is_list(args) do
    if length(args) == elem(operation, 2),
      do: {:ok, operation, args},
      else: {:error, "Invalid direct API arity."}
  end

  def prepare(_, _), do: {:error, "Unadmitted direct API."}

  def help do
    """
    Direct local APIs (fully qualified calls, no alias declarations):
    Read: #{signatures(:read)}.
    Write (exact-code approval required): #{signatures(:write)}.
    These invoke the actual named functions with unchanged arguments and return values, not projected facade substitutes. Inspect the source for options and errors; only these exact MFAs are admitted, never an entire module or another arity. A refusal does not auto-escalate.
    Example: EvoGit.TaskRegistry.list_tasks_page(limit: 10, status: "running")
    Example: EvoGit.AgentScheduler.get_config(:model_profiles)
    List settings: EvoGit.Config.list_settings()
    Show resolved settings: EvoGit.Config.show()
    Inspect persisted overrides and file location: {EvoGit.Config.user_config(), EvoGit.Config.config_path()}
    Discover projects: EvoGit.VCT.projects(limit: 10)
    Find projects: EvoGit.VCT.search("project name", limit: 10)
    Task pages return the real %{rows: rows, total: count}; get_task/get_task_lite return TaskInfo structs or nil, not redacted maps. list_agents returns the real full list of agent summaries, and get_llm_slot_status returns the real per-model map. These reads are not facade-row-bounded or secret-redacted; select only needed data before printing.
    start_task takes the real task type/options and returns {:ok, TaskInfo} or the API error; enqueue is not execution success. cancel/force_kill return their real acknowledgements/errors. delete returns :ok for a queued cast ONLY, not persisted deletion. Direct calls add no facade self-target/status/option policies.
    get_config/1 uses the scheduler's actual key semantics (including nonscalar values and nil for unknown keys). Config.resolve/1 accepts the real atom key or key-path list with no direct-key restriction.
    Config.show/0,1 and resolve/0,1 read the resolved defaults-plus-persisted snapshot, NOT live scheduler runtime overrides; show/1 selects settings using the actual API's key/path contract. list_settings/0 discovers supported settings. user_config/0 reads persisted user overrides without defaults, and config_path/0 returns the config.toml location.
    VCT.projects/0,1 and search/1,2 return real project Mount structs, newest first, with an optional keyword :limit. Search is a case-insensitive substring match on name/path/point; a blank query matches all projects. Reserved system mounts are excluded; paths may be missing on disk. Results are node-local and an empty list can also mean the VCT is unavailable. No VCT mutation is admitted.
    Runtime-only example (write): EvoGit.AgentScheduler.update_config(max_tool_concurrency: 8). This uses the real update_config options/return contract; it does not persist. pause/0 and resume/0 use the scheduler's separate transitions. Turn caps affect future agent registrations.
    Persist a partial patch (write): EvoGit.Config.update(%{scheduler: %{max_tool_concurrency: 8}})
    update/1 merges a nested partial patch into persisted user configuration, preserving unrelated settings; schema keys are normalized without creating atoms from input. It validates and saves, returning :ok or {:error, reason}, but does NOT reload runtime state. Prefer it over saving a resolved map, which also materializes defaults.
    Apply persisted settings explicitly (write): case EvoGit.Config.update(%{scheduler: %{max_tool_concurrency: 8}}) do :ok -> EvoGit.AgentScheduler.RemoteAPI.reload_config(); error -> error end
    save_user_config/1 remains a whole-file REPLACEMENT, not a patch; preserve unrelated user settings when using it. Saves refresh the persisted-config read snapshot, not scheduler runtime state. Avoid concurrent editing: read-modify-save can overwrite another writer's changes.
    RemoteAPI.reload_config/0 explicitly applies reloadable scheduler settings and returns the actual :ok or error. Persistence success does not guarantee reload success. Boot-only settings (such as distribution/node configuration) require a restart; reload is not a restart.
    Every direct call retains broker authorization/lifecycle checks, read/write/request/start quotas and engine time/output limits, but uses the real API's own call deadlines. Timeouts or lost authority do not roll back committed effects; inspect state before retrying mutations. Returned configuration/task data can contain sensitive values; output caps are not redaction.
    Existing Read/Write convenience facades remain separately available with their bounded projections, validators, quotas and one-second runtime-call deadlines.
    """
  end

  defp signatures(tier) do
    @entries
    |> Enum.filter(fn {_, _, _, t} -> t == tier end)
    |> Enum.map_join(", ", fn {m, f, a, _} -> "#{inspect(m)}.#{f}/#{a}" end)
  end
end
