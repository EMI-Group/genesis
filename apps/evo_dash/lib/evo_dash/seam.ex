defmodule EvoDash.Seam do
  @moduledoc """
  The ONE way an injectable `:evo_dash` seam is resolved, so a test can scope
  an override to ITS OWN process tree instead of the whole BEAM.

  A seam is a piece of behaviour production leaves at its default and a test
  replaces (a runner fun, a module, an override value). Resolving it through
  `get/2` means the override is looked up on the CALL CHAIN: this process'
  dictionary, then the `:"$callers"` entries (written by `Task`/
  `Task.Supervisor`), then the `:"$ancestors"` entries (`proc_lib`, hence any
  `GenServer`/`Supervisor` child), and only then `Application.get_env/3`. That
  is the same walk `EvoDash.VCTScope.server/0` and `EvoDash.Test.ConfigDir.resolve/0`
  perform, and it is what lets an `async: true` test install a fixture in its
  own process dictionary (`EvoDash.Test.Seam.put/2`) and have exactly the pages
  and load tasks it spawned resolve it — a concurrently mounted page of another
  test walks its OWN chain, finds nothing, and resolves the production default.
  App-env overrides remain readable (they are the last step), but an app-env
  write is BEAM-global and therefore only appropriate for a singleton consumer
  that is not descended from any test (e.g. the `EvoDash.DirectoryPicker`
  GenServer's `:directory_picker_module` / `:directory_picker` config).

  The seam is DEFAULT-INERT: production writes nothing to either source, so
  `get/2` answers `default` and every call site behaves exactly as if it read
  `Application.get_env/3` directly. Resolution is TOTAL and cheap — no raising,
  no logging, a dead/unreadable/remote pid is simply skipped, the walk is
  bounded and cycle-safe — so a stale pid in someone's chain can never turn a
  page load into an error.
  """

  # Distinguishes "the key is absent" from "the key is present with value nil";
  # `Process.get/2` would otherwise collapse the two.
  @unset :__evodash_seam_unset__

  # The chain is normally 1-3 entries (`$callers` is already transitive, so a
  # flat walk over both lists is enough). The cap only exists so a pathological
  # dictionary cannot make seam resolution unbounded.
  @chain_limit 32

  @doc """
  Resolves the seam `key`, in order: this process' own dictionary entry, the
  same key on the `:"$callers"` chain, the same key on the `:"$ancestors"`
  chain, then `Application.get_env(:evo_dash, key, default)`.
  """
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when is_atom(key) do
    case Process.get(key, @unset) do
      @unset ->
        case chain_value(key) do
          {:ok, value} -> value
          :error -> Application.get_env(:evo_dash, key, default)
        end

      value ->
        value
    end
  end

  defp chain_value(key) do
    callers = List.wrap(Process.get(:"$callers", []))
    ancestors = List.wrap(Process.get(:"$ancestors", []))

    scan(callers ++ ancestors, key, MapSet.new(), @chain_limit)
  end

  defp scan(_chain, _key, _seen, 0), do: :error
  defp scan([], _key, _seen, _budget), do: :error

  defp scan([pid | rest], key, seen, budget) when is_pid(pid) do
    cond do
      MapSet.member?(seen, pid) ->
        scan(rest, key, seen, budget)

      node(pid) != node() ->
        scan(rest, key, seen, budget)

      true ->
        case dict_value(pid, key) do
          {:ok, value} -> {:ok, value}
          :error -> scan(rest, key, MapSet.put(seen, pid), budget - 1)
        end
    end
  end

  defp scan([_not_a_pid | rest], key, seen, budget), do: scan(rest, key, seen, budget)

  # `Process.info/2` answers `nil` for a dead or unreadable pid and
  # `{{:dictionary, key}, :undefined}` for a live pid without the key.
  defp dict_value(pid, key) do
    case Process.info(pid, {:dictionary, key}) do
      {{:dictionary, _key}, :undefined} -> :error
      {{:dictionary, _key}, value} -> {:ok, value}
      _other -> :error
    end
  end
end
