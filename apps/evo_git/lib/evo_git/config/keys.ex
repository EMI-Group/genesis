defmodule EvoGit.Config.Keys do
  @moduledoc """
  ONE implementation of the two map-shape operations the config subtree needs:
  tolerant key lookup and string-key conversion.

  Config data crosses TOML/JSON/`keyword` boundaries, so the same logical map
  may arrive atom-keyed (in-code defaults, a resolved snapshot, a model entry
  built in Elixir) or string-keyed (parsed `config.toml`, a decoded JSON
  payload, a canonical provider/account inventory). Re-implementing that
  tolerance per module is how the subtree drifted into five subtly different
  readers; every tolerant read and every string-key conversion in
  `EvoGit.Config.*` goes through this module instead.

  ## Lookup rules (`fetch/2`, `get/2,3`)

    * an atom key reads an atom-keyed map first, then its string spelling;
    * a string key reads a string-keyed map first, then the SAME-SPELLED
      EXISTING atom — `String.to_existing_atom/1` is used deliberately, so a
      user-supplied key can never intern a new atom (the subtree's standing
      atom policy);
    * presence, not truthiness, decides: a present key whose value is `nil`
      is returned as `nil` rather than falling through to the other spelling.
      Config maps are never mixed-keyed in practice, so the distinction only
      matters for malformed input, where "present but nil" is the honest read;
    * a non-map value answers `:error` / the default — these readers are total
      because they run on unvalidated user config.

  ## Stringification rules (`stringify/2`)

  The recursive shape is shared; the three opt-in policies are what the
  callers actually differ on:

    * `:drop_nils` (default `false`) — omit map entries whose value is `nil`.
      TOML serialization needs this (TOML has no null), normalization must not
      do it (a present `nil` is meaningful input).
    * `:model_tuples` (default `false`) — convert an LLMDB-style
      `{provider_atom, keyword}` tuple into a `%{"provider" => …, …}` map, as
      required when persisting a model spec.
    * `:keyword_lists` (default `false`) — treat a non-empty keyword LIST as a
      map (provider-profile normalization does; array-valued settings such as
      `[[llm.providers]]` must stay lists when serialized).

  Both operations are total: no clause raises on any term.
  """

  @type key :: atom() | String.t()

  @type stringify_opts :: [
          drop_nils: boolean(),
          model_tuples: boolean(),
          keyword_lists: boolean()
        ]

  @doc """
  Reads `key` from an atom- or string-keyed map.

  Returns `{:ok, value}` when either spelling is present (see the module doc
  for the precedence rules) and `:error` otherwise, including for a non-map
  input.
  """
  @spec fetch(map(), key()) :: {:ok, term()} | :error
  def fetch(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  def fetch(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_existing_atom(map, key)
    end
  end

  def fetch(_map, _key), do: :error

  @doc "Like `fetch/2`, answering `nil` instead of `:error`."
  @spec get(map(), key()) :: term() | nil
  def get(map, key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  @doc "Like `fetch/2`, answering `default` instead of `:error`."
  @spec get(map(), key(), term()) :: term()
  def get(map, key, default) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  Recursively converts atom map keys to strings, applying the opt-in policies
  described in the module doc.

  Non-atom keys are kept as they are, `nil` stays `nil`, and any other term
  (numbers, binaries, structs, PIDs, …) passes through untouched.
  """
  @spec stringify(term(), stringify_opts()) :: term()
  def stringify(value, opts \\ []) when is_list(opts) do
    do_stringify(
      value,
      Keyword.get(opts, :drop_nils, false),
      Keyword.get(opts, :model_tuples, false),
      Keyword.get(opts, :keyword_lists, false)
    )
  end

  defp do_stringify(map, drop_nils, tuples, keyword_lists)
       when is_map(map) and not is_struct(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      value = do_stringify(value, drop_nils, tuples, keyword_lists)

      if drop_nils and is_nil(value) do
        acc
      else
        Map.put(acc, string_key(key), value)
      end
    end)
  end

  defp do_stringify(list, drop_nils, tuples, true)
       when is_list(list) and list != [] do
    if Keyword.keyword?(list) do
      do_stringify(Map.new(list), drop_nils, tuples, true)
    else
      Enum.map(list, &do_stringify(&1, drop_nils, tuples, true))
    end
  end

  defp do_stringify(list, drop_nils, tuples, keyword_lists) when is_list(list) do
    Enum.map(list, &do_stringify(&1, drop_nils, tuples, keyword_lists))
  end

  defp do_stringify({provider, opts}, drop_nils, true, _keyword_lists)
       when is_atom(provider) and is_list(opts) do
    opts
    |> Map.new()
    |> Map.put(:provider, provider)
    |> do_stringify(drop_nils, true, false)
  end

  defp do_stringify(value, _drop_nils, _tuples, _keyword_lists), do: value

  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key), do: key

  # A string key may address an atom-keyed map. `String.to_existing_atom/1`
  # never interns a new atom, which is the whole point: user config keys are
  # untrusted input and must not grow the atom table. An unknown spelling is
  # simply absent.
  defp fetch_existing_atom(map, key) do
    try do
      Map.fetch(map, String.to_existing_atom(key))
    rescue
      ArgumentError -> :error
    end
  end
end
