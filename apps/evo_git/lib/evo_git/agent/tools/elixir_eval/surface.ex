defmodule EvoGit.Agent.Tools.ElixirEval.Surface do
  @moduledoc false

  # The evaluator's DENY/resolvable surface: every fully qualified name evaluated
  # code can encounter must RESOLVE so the policy layer classifies it through
  # `DirectAPI.status/4` (:allowed | {:shimmed, ...} | :restricted).
  #
  # Dune's safe parser never creates alias atoms: it maps each dotted segment to an
  # already-existing atom, and a missing segment becomes an opaque placeholder that
  # the sanitizer reports as `:undefined_module` — which the Engine can only render
  # as a generic runtime failure rather than the descriptive restriction. A read-tier
  # run therefore cannot rely on the write spec having been loaded first.
  #
  # This module is loaded ONLY at the runtime parse chokepoint
  # (`ReadAllowlist.ensure_initialized/0` / `WriteAllowlist.ensure_initialized/0`);
  # the wrappers' side-effect-only `@on_load` hooks deliberately never name it, so
  # loading a wrapper still interns nothing beyond its own spec's alias atoms.
  #
  # A module here contributes BOTH its own atom and its alias-segment atoms; the list
  # is COMPILE-TIME literals only, so materializing it never creates an atom from
  # evaluated input. It covers this tool's namespace, the refused terminal command
  # shell and the EvoGit root module; a module added to this namespace must be listed
  # here.
  @resolvable_modules [
    EvoGit,
    EvoGit.CommandShell,
    EvoGit.Agent.Tools.ElixirEval.Read,
    EvoGit.Agent.Tools.ElixirEval.Write,
    EvoGit.Agent.Tools.ElixirEval.Broker,
    EvoGit.Agent.Tools.ElixirEval.DirectAPI,
    EvoGit.Agent.Tools.ElixirEval.Engine,
    EvoGit.Agent.Tools.ElixirEval.WorkerTree,
    EvoGit.Agent.Tools.ElixirEval.Custodian,
    EvoGit.Agent.Tools.ElixirEval.BoundedIO,
    EvoGit.Agent.Tools.ElixirEval.Authorization,
    EvoGit.Agent.Tools.ElixirEval.Ancestry,
    EvoGit.Agent.Tools.ElixirEval.Projection,
    EvoGit.Agent.Tools.ElixirEval.Validation,
    EvoGit.Agent.Tools.ElixirEval.Render,
    EvoGit.Agent.Tools.ElixirEval.IOShim,
    EvoGit.Agent.Tools.ElixirEval.ReadAllowlist,
    EvoGit.Agent.Tools.ElixirEval.WriteAllowlist,
    EvoGit.Agent.Tools.ElixirEval.ReadAllowlist.Base,
    EvoGit.Agent.Tools.ElixirEval.WriteAllowlist.Base,
    EvoGit.Agent.Tools.ElixirEval.AllowlistAliases,
    EvoGit.Agent.Tools.ElixirEval.Surface
  ]

  @resolvable_atoms @resolvable_modules
                    |> Enum.flat_map(fn module ->
                      [module | Enum.map(Module.split(module), &String.to_atom/1)]
                    end)
                    |> Enum.uniq()

  @doc false
  @spec resolvable_atoms() :: [atom()]
  def resolvable_atoms, do: @resolvable_atoms

  @doc false
  # Loads BOTH generated Base allowlists and materializes the resolvable deny
  # surface. Runtime-only: an `@on_load` must never load a sibling module, so this
  # runs at the parse chokepoint for either tier. Loading both specs also interns the
  # alias segments of every module each spec admits.
  @spec ensure_initialized() :: :ok | {:error, term()}
  def ensure_initialized do
    with {:module, _} <-
           Code.ensure_loaded(EvoGit.Agent.Tools.ElixirEval.ReadAllowlist.Base),
         {:module, _} <-
           Code.ensure_loaded(EvoGit.Agent.Tools.ElixirEval.WriteAllowlist.Base) do
      Enum.each(@resolvable_atoms, & &1)
      :ok
    end
  end
end
