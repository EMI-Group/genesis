defmodule EvoGit.Agent.Tools.ElixirEval.ReadAllowlist.Base do
  @moduledoc false
  use Dune.Allowlist, extend: Dune.Allowlist.Default

  for {module, entries} <-
        EvoGit.Agent.Tools.ElixirEval.DirectAPI.entries()
        |> Enum.group_by(&elem(&1, 0)) do
    allow(module, only: Enum.map(entries, &elem(&1, 1)) |> Enum.uniq())
  end

  allow(EvoGit.Agent.Tools.ElixirEval.Read,
    only: [
      :help,
      :system_info,
      :list_tasks,
      :get_task,
      :list_agents,
      :scheduler_status,
      :model_profiles,
      :configuration_status
    ]
  )
end

defmodule EvoGit.Agent.Tools.ElixirEval.WriteAllowlist.Base do
  @moduledoc false
  use Dune.Allowlist, extend: EvoGit.Agent.Tools.ElixirEval.ReadAllowlist.Base

  allow(EvoGit.Agent.Tools.ElixirEval.Write,
    only: [
      :start_task,
      :cancel_task,
      :force_kill_task,
      :delete_task,
      :guide,
      :update_scheduler_config
    ]
  )
end

defmodule EvoGit.Agent.Tools.ElixirEval.ReadAllowlist do
  @moduledoc false
  @behaviour Dune.Allowlist
  alias EvoGit.Agent.Tools.ElixirEval.{IOShim, ReadAllowlist}

  # Dune loads this wrapper before parsing, but only calls fun_status afterwards.
  # Load the generated allowlist now so its on_load initializes the facade alias
  # atoms before Dune's safe parser encodes otherwise-unknown module names.
  @on_load :ensure_base_loaded
  def ensure_base_loaded do
    Code.ensure_loaded!(ReadAllowlist.Base)
    :ok
  end

  # Default already specifies IO, so its DSL cannot replace those entries.
  # Check arities explicitly: Dune's `only` lists contain NAMES, not MFA tuples.
  @impl true
  def fun_status(IO, :puts, arity) when arity in [1, 2], do: {:shimmed, IOShim, :puts}
  def fun_status(IO, :inspect, arity) when arity in [1, 2, 3], do: {:shimmed, IOShim, :inspect}
  def fun_status(IO, name, _arity) when name in [:puts, :inspect], do: :restricted
  def fun_status(Kernel, :dbg, _arity), do: :restricted

  def fun_status(module, name, arity) do
    if EvoGit.Agent.Tools.ElixirEval.DirectAPI.runtime_module?(module),
      do: EvoGit.Agent.Tools.ElixirEval.DirectAPI.status(module, name, arity, :read),
      else: ReadAllowlist.Base.fun_status(module, name, arity)
  end
end

defmodule EvoGit.Agent.Tools.ElixirEval.WriteAllowlist do
  @moduledoc false
  @behaviour Dune.Allowlist
  alias EvoGit.Agent.Tools.ElixirEval.{ReadAllowlist, WriteAllowlist}

  # The write spec includes both facades; initialize all its alias atoms before
  # parsing even when write is the first tier used in a fresh BEAM.
  @on_load :ensure_base_loaded
  def ensure_base_loaded do
    Code.ensure_loaded!(WriteAllowlist.Base)
    :ok
  end

  @impl true
  def fun_status(module, name, arity) when module in [IO, Kernel],
    do: ReadAllowlist.fun_status(module, name, arity)

  def fun_status(module, name, arity) do
    if EvoGit.Agent.Tools.ElixirEval.DirectAPI.runtime_module?(module),
      do: EvoGit.Agent.Tools.ElixirEval.DirectAPI.status(module, name, arity, :write),
      else: WriteAllowlist.Base.fun_status(module, name, arity)
  end
end
