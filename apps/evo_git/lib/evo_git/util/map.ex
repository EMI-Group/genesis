defmodule EvoGit.Util.Map do
  @moduledoc """
  The shared map normalization used when atom-keyed data crosses a TOML or
  JSON boundary into a string-keyed representation.

  The shared contract is: stringify keys recursively, and optionally drop
  nil-valued MAP entries. Model-tuple handling stays deliberately out of
  scope — it is a caller policy, not part of this transform, so a caller that
  needs it keeps its own transform.
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

  ## Options

  - `:drop_nil` (default `false`) — when `true`, every MAP level drops the
    entries whose converted value is `nil`, so an absent sub-tree stays absent
    in the serialized output. A `nil` element inside a list is kept, and with
    the default every entry survives.

  NO model-tuple clause: a caller relying on one must apply that policy itself.
  """
  @spec stringify_keys(term(), keyword()) :: term()
  def stringify_keys(value, opts) when is_list(opts) do
    do_stringify_keys(value, Keyword.get(opts, :drop_nil, false))
  end

  @doc """
  `stringify_keys(value, [])` — every entry survives, `nil` values included.
  """
  @spec stringify_keys(term()) :: term()
  def stringify_keys(value), do: stringify_keys(value, [])

  defp do_stringify_keys(map, drop_nil?) when is_map(map) do
    converted =
      Map.new(map, fn
        {key, value} when is_atom(key) ->
          {Atom.to_string(key), do_stringify_keys(value, drop_nil?)}

        {key, value} ->
          {key, do_stringify_keys(value, drop_nil?)}
      end)

    if drop_nil? do
      converted
      |> Enum.reject(fn {_key, value} -> value == nil end)
      |> Map.new()
    else
      converted
    end
  end

  defp do_stringify_keys(list, drop_nil?) when is_list(list) do
    Enum.map(list, &do_stringify_keys(&1, drop_nil?))
  end

  defp do_stringify_keys(nil, _drop_nil?), do: nil

  defp do_stringify_keys(value, _drop_nil?), do: value
end
