defmodule EvoDash.SourceStatus do
  @moduledoc """
  Shared, total (never-raising) wrapper over the optionally-present
  `EvoGit.SelfReflectiveSource` core backend.

  The core module owns the managed Genesis source checkout read by the
  repo-less self-reflective agent, but it is not compiled into every release
  (e.g. the dashboard may run against a build without it). Every call is
  therefore guarded with `Code.ensure_loaded?/1` + `function_exported?/3` and
  dispatched via `apply/3` — a direct call would emit an "undefined function"
  compile warning against a missing module.

  Instead of raising when the backend or a function is absent, the functions
  return a tri-state `{:unavailable, reason}` so callers (the dashboard's
  `SourceCard` and `HomeLive`) can render a degraded UI without crashing:

    * `:module_missing` — `EvoGit.SelfReflectiveSource` is not loaded.
    * `:function_missing` — the module is loaded but the function/arity is not
      exported (e.g. `available?/0` on an older build).
    * `:call_failed` — the underlying call itself raised.
  """

  @doc """
  Whether the self-reflective source backend is available.

  Returns `true | false | {:unavailable, reason}`.
  """
  @spec available?() :: boolean() | {:unavailable, atom()}
  def available?, do: guarded(:available?)

  @doc """
  Read-only snapshot of the managed source checkout.

  Returns a status map or `{:unavailable, reason}`.
  """
  @spec status() :: map() | {:unavailable, atom()}
  def status, do: guarded(:status)

  @doc """
  Shallow-clones the upstream source into the managed directory.

  Returns `{:ok, status} | {:error, reason} | {:unavailable, reason}`.
  """
  @spec clone() :: {:ok, map()} | {:error, term()} | {:unavailable, atom()}
  def clone, do: guarded(:clone)

  @doc """
  Fetches + fast-forwards the managed source clone.

  Returns `{:ok, status} | {:error, reason} | {:unavailable, reason}`.
  """
  @spec update() :: {:ok, map()} | {:error, term()} | {:unavailable, atom()}
  def update, do: guarded(:update)

  # Shared guarded dispatcher: checks module presence, then function/arity
  # presence, then invokes via `apply/3` so a missing backend never warns.
  #
  # Expected error? Yes — this is the untrusted/external-module boundary: the
  # backend may be absent, may not export the function, or may itself raise.
  # Cleanest approach? A single guarded entry point returning the documented
  # `{:unavailable, reason}` tri-state keeps all four public wrappers as
  # one-liners and confines the (deliberate) rescue to this one boundary, so
  # callers can render a degraded UI instead of crashing a LiveView.
  defp guarded(fun, args \\ []) do
    if Code.ensure_loaded?(EvoGit.SelfReflectiveSource) do
      if function_exported?(EvoGit.SelfReflectiveSource, fun, length(args)) do
        try do
          apply(EvoGit.SelfReflectiveSource, fun, args)
        rescue
          _error -> {:unavailable, :call_failed}
        end
      else
        {:unavailable, :function_missing}
      end
    else
      {:unavailable, :module_missing}
    end
  end
end
