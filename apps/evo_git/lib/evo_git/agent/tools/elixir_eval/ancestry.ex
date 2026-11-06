defmodule EvoGit.Agent.Tools.ElixirEval.Ancestry do
  @moduledoc false

  # These are runtime-maintained Task/proc_lib ancestry dictionaries, not role
  # flags inherited from a tool. Dune must never allow Process dictionary APIs.
  # Traversal is local, cycle-safe and bounded even for malformed dictionaries.
  @max_processes 32

  def includes?(pid, ancestor) when is_pid(pid) and is_pid(ancestor) do
    Enum.any?(walk(pid), fn {current, _dictionary} -> current == ancestor end)
  end

  def includes?(_, _), do: false

  def broker(pid) do
    Enum.find_value(walk(pid), fn {_pid, dictionary} ->
      case Keyword.get(dictionary, :evogit_eval_broker) do
        broker when is_pid(broker) -> broker
        _ -> nil
      end
    end)
  end

  defp walk(pid), do: walk([pid], MapSet.new(), [], @max_processes)
  defp walk(_, _, acc, 0), do: Enum.reverse(acc)
  defp walk([], _, acc, _), do: Enum.reverse(acc)

  defp walk([pid | rest], seen, acc, budget) do
    if is_pid(pid) and node(pid) == node() and not MapSet.member?(seen, pid) do
      seen = MapSet.put(seen, pid)

      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          parents = parents(dictionary, :"$callers") ++ parents(dictionary, :"$ancestors")
          walk(rest ++ parents, seen, [{pid, dictionary} | acc], budget - 1)

        _ ->
          walk(rest, seen, acc, budget - 1)
      end
    else
      walk(rest, seen, acc, budget - 1)
    end
  end

  defp parents(dictionary, key) do
    case Keyword.get(dictionary, key) do
      list when is_list(list) -> Enum.take(list, 8) |> Enum.filter(&is_pid/1)
      _ -> []
    end
  end
end
