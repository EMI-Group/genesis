defmodule EvoGit.Agent.Tools.ElixirEval.ReadAllowlist.Base do
  @moduledoc false
  use Dune.Allowlist, extend: Dune.Allowlist.Default

  allow(EvoGit.Agent.Tools.ElixirEval.Read,
    only: [
      :help,
      :system_info,
      :list_tasks,
      :get_task,
      :list_agents,
      :scheduler_status,
      :model_profiles
    ]
  )
end

defmodule EvoGit.Agent.Tools.ElixirEval.WriteAllowlist.Base do
  @moduledoc false
  use Dune.Allowlist, extend: EvoGit.Agent.Tools.ElixirEval.ReadAllowlist.Base

  allow(EvoGit.Agent.Tools.ElixirEval.Write,
    only: [:start_task, :cancel_task, :force_kill_task, :delete_task, :guide]
  )
end

defmodule EvoGit.Agent.Tools.ElixirEval.ReadAllowlist do
  @moduledoc false
  @behaviour Dune.Allowlist
  alias EvoGit.Agent.Tools.ElixirEval.{IOShim, ReadAllowlist}

  # Default already specifies IO, so its DSL cannot replace those entries.
  # Check arities explicitly: Dune's `only` lists contain NAMES, not MFA tuples.
  @impl true
  def fun_status(IO, :puts, arity) when arity in [1, 2], do: {:shimmed, IOShim, :puts}
  def fun_status(IO, :inspect, arity) when arity in [1, 2, 3], do: {:shimmed, IOShim, :inspect}
  def fun_status(IO, name, _arity) when name in [:puts, :inspect], do: :restricted
  def fun_status(Kernel, :dbg, _arity), do: :restricted
  def fun_status(module, name, arity), do: ReadAllowlist.Base.fun_status(module, name, arity)
end

defmodule EvoGit.Agent.Tools.ElixirEval.WriteAllowlist do
  @moduledoc false
  @behaviour Dune.Allowlist
  alias EvoGit.Agent.Tools.ElixirEval.{ReadAllowlist, WriteAllowlist}

  @impl true
  def fun_status(module, name, arity) when module in [IO, Kernel],
    do: ReadAllowlist.fun_status(module, name, arity)

  def fun_status(module, name, arity), do: WriteAllowlist.Base.fun_status(module, name, arity)
end
