defmodule EvoDash.VCTScope do
  @moduledoc """
  Resolves the VCT instance for the CURRENT call chain, so a mounted page and
  the load tasks it supervises honour the instance its owner designated.
  `EvoGit.VCT.server/0` reads `:evogit_vct_server` from the CALLING process
  only, so a process-dictionary designation never reaches a LiveView (a
  different process) or a supervised load task (a child of it).
  This module turns that designation into a SPAWN-CHAIN property — own
  dictionary first, then `$callers` (`Task`) and `$ancestors` (`proc_lib`, hence
  any `GenServer`/`Supervisor` child), the same walk
  `EvoDash.Test.ConfigDir.resolve/0` performs for the config directory.
  It uses the SAME `:evogit_vct_server` key as the core, so a process that
  designates an instance with `Process.put(:evogit_vct_server, name)` also gets
  its direct `EvoGit.VCT` calls routed — there is no second key to keep in sync.
  The seam is DEFAULT-INERT: production designates nothing, so `server/0`
  answers `nil` and `scoped/1` is a plain call of the wrapped function, leaving
  every project-registry call byte-identical to the registered singleton.
  `:evo_git` must NOT be changed for this; the core's own resolution stays a
  per-process lookup and this module is the dashboard-side bridge.
  """
  # The core's key (`EvoGit.VCT`), reused verbatim — see the moduledoc.
  @server_key :evogit_vct_server
  @doc """
  Returns the VCT instance designated for the current call chain, or `nil`.
  Order: this process' own designation, then `$callers`, then `$ancestors`
  (local pids only; a dead pid answers `nil` through `Process.info/2`, so the
  walk falls through to the next entry).
  """
  @spec server() :: term() | nil
  def server do
    case Process.get(@server_key) do
      nil ->
        chain = Process.get(:"$callers", []) ++ Process.get(:"$ancestors", [])
        Enum.find_value(chain, &caller_designation/1)

      designated ->
        designated
    end
  end

  @doc """
  Runs `fun` with the chain's VCT instance designated for the current process.
  When `server/0` answers `nil` this is exactly `fun.()` — no dictionary write,
  nothing to restore (the inert path). Otherwise the previous value is put back
  afterwards (`nil` → `Process.delete/1`), so nesting and an outer designation
  both survive the call.
  """
  @spec scoped((-> result)) :: result when result: term()
  def scoped(fun) when is_function(fun, 0) do
    case server() do
      nil -> fun.()
      designated -> run_designated(designated, fun)
    end
  end

  defp run_designated(designated, fun) do
    previous = Process.get(@server_key)
    Process.put(@server_key, designated)

    try do
      fun.()
    after
      case previous do
        nil -> Process.delete(@server_key)
        value -> Process.put(@server_key, value)
      end
    end
  end

  # One chain entry's designation. `Process.info/2` answers `nil` for a dead
  # pid, and a pid on another node has no readable dictionary here.
  # The PER-KEY form (`{:dictionary, key}`) is load-bearing, not cosmetic: it
  # copies only that one entry into this process, whereas the whole-dictionary
  # form copies every key of the probed process. Production designates nothing,
  # so the walk always runs to the end of an `$ancestors` chain that reaches into
  # the OTP supervisors — on every wrapped `EvoDash.NodeContext` delegation —
  # and only then falls through to `nil`. Same shape as `EvoDash.Seam.dict_value/2`.
  defp caller_designation(pid) when is_pid(pid) do
    if node(pid) == node() do
      case Process.info(pid, {:dictionary, @server_key}) do
        # A live pid that simply does not hold the key.
        {{:dictionary, _key}, :undefined} -> nil
        {{:dictionary, _key}, value} -> value
        # Dead or otherwise unreadable pid — fall through to the next entry.
        _other -> nil
      end
    end
  end

  defp caller_designation(_entry), do: nil
end
