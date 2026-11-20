defmodule EvoGit.Util.Map do
  @moduledoc """
  The shared map normalization used when atom-keyed data crosses a TOML or
  JSON boundary into a string-keyed representation.

  This is the PLAIN transform: keys are stringified recursively and every
  value survives untouched. A caller that additionally wants nil-dropping or
  model-tuple handling keeps its own transform — those are caller policies,
  not part of the shared contract.
  """

  @doc """
  Recursively converts atom keys to string keys while leaving other keys
  intact:

  - a map → a map with every atom key converted via `Atom.to_string/1` (a
    binary or other key is kept as-is) and every value recursively converted,
    including the values under non-atom keys;
  - a list → each element recursively converted;
  - `nil` → `nil` (short-circuit, so an absent sub-tree stays absent);
  - any other term passes through unchanged.

  NO nil-dropping and NO model-tuple clause: a value of `nil` is preserved, so
  a caller relying on either must apply that policy itself.
  """
  @spec stringify_keys(term()) :: term()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {key, stringify_keys(value)}
    end)
  end

  def stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  def stringify_keys(nil), do: nil

  def stringify_keys(value), do: value
end
