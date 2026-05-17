defmodule ReqLLM.MapAccess do
  @moduledoc false

  @spec get(map(), atom() | String.t(), any()) :: any()
  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  def get(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      case existing_atom(key) do
        nil -> default
        atom -> Map.get(map, atom) || default
      end
  end

  def get(_map, _key, default), do: default

  defp existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end
