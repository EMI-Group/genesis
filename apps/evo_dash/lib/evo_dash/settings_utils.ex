defmodule EvoDash.SettingsUtils do
  @moduledoc """
  Shared utility functions for config manipulation.

  These helpers are used by the settings LiveView and other contexts that need
  to parse form values, manipulate nested maps, and build keyword lists from
  optional configuration keys.
  """

  @doc """
  Puts a value into a nested map given a list of keys representing the path.

  ## Examples

      iex> deep_put(%{}, [:a, :b], 1)
      %{a: %{b: 1}}

      iex> deep_put(%{a: %{c: 2}}, [:a, :b], 1)
      %{a: %{b: 1, c: 2}}
  """
  def deep_put(map, [key], value) do
    Map.put(map, key, value)
  end

  def deep_put(map, [key | rest], value) do
    existing = Map.get(map, key, %{})
    Map.put(map, key, deep_put(existing, rest, value))
  end

  @doc """
  Deep merges two maps. When both values are maps the merge recurses;
  otherwise the right-hand value wins.
  """
  def deep_merge(map1, map2) when is_map(map1) and is_map(map2) do
    Map.merge(map1, map2, fn _key, v1, v2 ->
      if is_map(v1) and is_map(v2) do
        deep_merge(v1, v2)
      else
        v2
      end
    end)
  end

  @doc """
  Removes a value from a nested map given a key path.

  When the resulting nested map becomes empty after deletion, the parent key
  is also removed.
  """
  def deep_delete(map, [key]) do
    Map.delete(map, key)
  end

  def deep_delete(map, [key | rest]) do
    case Map.get(map, key) do
      nested when is_map(nested) ->
        updated = deep_delete(nested, rest)

        if updated == %{} do
          Map.delete(map, key)
        else
          Map.put(map, key, updated)
        end

      _ ->
        map
    end
  end

  @doc """
  Parses a string to an integer. Returns `nil` when the input is not a valid
  integer string.
  """
  def parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  def parse_int(_), do: nil

  @doc """
  Parses a string to a float. Returns `nil` when the input is not a valid
  float string.
  """
  def parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> nil
    end
  end

  def parse_float(_), do: nil

  @doc """
  Converts a form string to an atom using a whitelist derived from the
  schema validation (`[in: [...]]`). This avoids calling `String.to_atom` or
  `String.to_existing_atom` on untrusted input. Unknown values return `nil`
  so downstream validation can report them.
  """
  def parse_atom(value, schema) when is_binary(value) and value != "" do
    allowed_atoms = schema[:validation][:in] || []

    Enum.find_value(allowed_atoms, fn atom ->
      if Atom.to_string(atom) == value, do: atom
    end)
  end

  def parse_atom(_, _), do: nil

  @doc """
  Conditionally adds a keyword to a keyword list, skipping when the value is
  `nil`.
  """
  def maybe_add_kw(list, _key, nil), do: list
  def maybe_add_kw(list, key, value), do: Keyword.put(list, key, value)
end
