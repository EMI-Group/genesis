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

defmodule EvoGit.Agent.Tools.ElixirEval.AllowlistAliases do
  @moduledoc false

  # Compile-time helper. Dune's safe parser never CREATES alias atoms: it maps each
  # dotted segment to an already-existing atom, so a segment that does not exist yet
  # becomes an opaque placeholder and a fully qualified module cannot resolve.
  # Dune derives the same list for its own generated `@on_load :ensure_alias_atoms`,
  # so each wrapper bakes in the atoms of ITS generated Base spec (`spec()` is the
  # single source of truth for the allowed modules).
  @spec atoms(:read | :write) :: [atom()]
  def atoms(:read), do: atoms_for_spec(EvoGit.Agent.Tools.ElixirEval.ReadAllowlist.Base.spec())
  def atoms(:write), do: atoms_for_spec(EvoGit.Agent.Tools.ElixirEval.WriteAllowlist.Base.spec())

  defp atoms_for_spec(%Dune.Allowlist.Spec{modules: modules}) do
    modules
    |> Map.keys()
    |> Enum.filter(&elixir_module?/1)
    |> Enum.flat_map(&Module.split/1)
    |> Enum.map(&String.to_atom/1)
    |> Enum.uniq()
  end

  defp elixir_module?(module), do: match?("Elixir." <> _, Atom.to_string(module))
end

defmodule EvoGit.Agent.Tools.ElixirEval.ReadAllowlist do
  @moduledoc false
  @behaviour Dune.Allowlist
  alias EvoGit.Agent.Tools.ElixirEval.{AllowlistAliases, IOShim, ReadAllowlist}

  # An embedded-mode release primLoads modules and runs their `@on_load` handlers
  # while `Code.ensure_loaded/1` can still answer `{:error, :embedded}` for a module
  # that is not loaded yet, so an on_load that loads a sibling module takes kernel
  # down with `on_load_function_failed`. This hook is therefore side-effect-only
  # atom materialization of compile-time literals: it never loads a module and
  # cannot fail. The Base allowlist itself is loaded at the parse chokepoint by
  # `ensure_initialized/0`.
  @alias_atoms AllowlistAliases.atoms(:read)
  @on_load :ensure_alias_atoms
  def ensure_alias_atoms do
    # Aliases like Foo.Bar are AST `{:__aliases__, _, [:Foo, :Bar]}` nodes that Dune
    # only maps to existing atoms. Enumerating the literals forces their creation.
    Enum.each(@alias_atoms, & &1)
    :ok
  end

  @doc false
  # Called by the Engine immediately before handing code to Dune. Unlike the on_load
  # above this is an ordinary runtime call, so it MAY load the generated Base
  # allowlists (BOTH of them) and materialize the whole deny/resolvable surface; a
  # genuine failure is reported at the parse site instead of crashing boot or
  # silently degrading to a restriction error. Because the surface is complete for
  # either tier, a read-tier run can classify a write-facade call as :restricted
  # instead of failing it as an undefined module.
  @spec ensure_initialized() :: :ok | {:error, term()}
  def ensure_initialized do
    case EvoGit.Agent.Tools.ElixirEval.Surface.ensure_initialized() do
      :ok ->
        ensure_alias_atoms()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
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
  alias EvoGit.Agent.Tools.ElixirEval.{AllowlistAliases, ReadAllowlist, WriteAllowlist}

  # Same embedded-mode constraint as ReadAllowlist: atom materialization only, so
  # the write spec's aliases exist before parsing even when write is the first tier
  # used in a fresh BEAM. Never load a module here.
  @alias_atoms AllowlistAliases.atoms(:write)
  @on_load :ensure_alias_atoms
  def ensure_alias_atoms do
    Enum.each(@alias_atoms, & &1)
    :ok
  end

  @doc false
  # See ReadAllowlist.ensure_initialized/0: the same runtime chokepoint loads both
  # generated Base allowlists and materializes the deny/resolvable surface, so an
  # alias always resolves to a real module and policy decides the outcome.
  @spec ensure_initialized() :: :ok | {:error, term()}
  def ensure_initialized do
    case EvoGit.Agent.Tools.ElixirEval.Surface.ensure_initialized() do
      :ok ->
        ensure_alias_atoms()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
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
