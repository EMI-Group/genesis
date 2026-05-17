defmodule LLMDB.Merge do
  @moduledoc """
  Precedence-aware merging with exclude handling for LLM model data.

  Provides functions to merge providers, models, and arbitrary maps with
  configurable precedence rules. Handles excludes via exact match or glob patterns.
  """

  alias LLMDB.DeepMergeShim

  @doc """
  Creates a configurable deep merge resolver function.

  Returns a 3-arity function that can be passed to DeepMerge.deep_merge/3
  with customizable behavior for list and special key handling.

  ## Options

  - `:union_list_keys` - List of keys whose list values should be unioned (default: [])
  - `:preserve_empty_list_keys` - List of keys where empty list on right preserves left (default: [])

  ## Examples

      # Model merging with list unions
      resolver = Merge.resolver(union_list_keys: [:aliases, :tags])
      DeepMerge.deep_merge(base, override, resolver)

      # Provider merging preserving exclude_models
      resolver = Merge.resolver(preserve_empty_list_keys: [:exclude_models])
      DeepMerge.deep_merge(base, override, resolver)
  """
  @spec resolver(keyword()) :: (any(), any(), any() -> any())
  def resolver(opts \\ []) do
    union_keys = Keyword.get(opts, :union_list_keys, [])
    preserve_empty_keys = Keyword.get(opts, :preserve_empty_list_keys, [])

    fn
      key, left, right when is_list(left) and is_list(right) ->
        cond do
          key in union_keys -> union_unique(left, right)
          key in preserve_empty_keys and right == [] -> left
          true -> right
        end

      _key, left, right when is_map(left) and is_map(right) ->
        DeepMerge.continue_deep_merge()

      _key, left, nil ->
        left

      _key, _left, right ->
        right
    end
  end

  @doc """
  Merges two maps with precedence rules.

  - Scalar values: higher precedence wins
  - Maps: deep merge recursively
  - Lists: concat and de-dup by value
  - Higher precedence source always wins on scalars

  ## Examples

      iex> LLMDB.Merge.merge(%{a: 1}, %{b: 2}, :higher)
      %{a: 1, b: 2}

      iex> LLMDB.Merge.merge(%{a: 1}, %{a: 2}, :higher)
      %{a: 2}

      iex> LLMDB.Merge.merge(%{a: 1}, %{a: 2}, :lower)
      %{a: 1}

      iex> LLMDB.Merge.merge(%{a: %{b: 1}}, %{a: %{c: 2}}, :higher)
      %{a: %{b: 1, c: 2}}

      iex> LLMDB.Merge.merge(%{a: [1, 2]}, %{a: [2, 3]}, :higher)
      %{a: [1, 2, 3]}
  """
  @spec merge(map(), map(), :higher | :lower) :: map()
  def merge(base, override, precedence) when is_map(base) and is_map(override) do
    case precedence do
      :higher -> deep_merge(base, override, fn _k, _v1, v2 -> v2 end)
      :lower -> deep_merge(base, override, fn _k, v1, _v2 -> v1 end)
    end
  end

  @doc """
  Merges two provider lists by :id key.

  Higher precedence (override) wins on conflicts.

  ## Examples

      iex> base = [%{id: :openai, name: "OpenAI"}]
      iex> override = [%{id: :openai, name: "OpenAI Updated"}, %{id: :anthropic, name: "Anthropic"}]
      iex> result = LLMDB.Merge.merge_providers(base, override)
      iex> Enum.sort_by(result, & &1.id)
      [%{id: :anthropic, name: "Anthropic"}, %{id: :openai, name: "OpenAI Updated"}]
  """
  @spec merge_providers([map()], [map()]) :: [map()]
  def merge_providers(base_providers, override_providers)
      when is_list(base_providers) and is_list(override_providers) do
    base_map = Map.new(base_providers, fn p -> {Map.get(p, :id), p} end)
    override_map = Map.new(override_providers, fn p -> {Map.get(p, :id), p} end)

    Map.merge(base_map, override_map, fn _id, base_provider, override_provider ->
      DeepMergeShim.deep_merge(
        base_provider,
        override_provider,
        resolver(preserve_empty_list_keys: [:exclude_models])
      )
    end)
    |> Map.values()
  end

  @doc """
  Merges two model lists by {provider, id} identity, applying excludes.

  - Merge models by {provider, id} identity
  - Apply excludes: %{provider_atom => [patterns]} where patterns can be exact strings or globs with *
  - Compile glob patterns to regex once for performance
  - Higher precedence (override) wins on conflicts

  ## Examples

      iex> base = [%{id: "gpt-4", provider: :openai}]
      iex> override = [%{id: "gpt-4", provider: :openai, capabilities: %{tools: true}}]
      iex> LLMDB.Merge.merge_models(base, override, %{})
      [%{id: "gpt-4", provider: :openai, capabilities: %{tools: true}}]

      iex> base = [%{id: "gpt-4", provider: :openai}, %{id: "gpt-3", provider: :openai}]
      iex> excludes = %{openai: ["gpt-3"]}
      iex> LLMDB.Merge.merge_models(base, [], excludes)
      [%{id: "gpt-4", provider: :openai}]

      iex> base = [%{id: "gpt-4o-mini", provider: :openai}, %{id: "gpt-5-pro", provider: :openai}]
      iex> excludes = %{openai: ["gpt-5-*"]}
      iex> LLMDB.Merge.merge_models(base, [], excludes)
      [%{id: "gpt-4o-mini", provider: :openai}]
  """
  @spec merge_models([map()], [map()], map()) :: [map()]
  def merge_models(base_models, override_models, excludes)
      when is_list(base_models) and is_list(override_models) and is_map(excludes) do
    compiled_excludes = compile_excludes(excludes)

    base_map = Map.new(base_models, fn m -> {{Map.get(m, :provider), Map.get(m, :id)}, m} end)

    override_map =
      Map.new(override_models, fn m -> {{Map.get(m, :provider), Map.get(m, :id)}, m} end)

    Map.merge(base_map, override_map, fn _identity, base_model, override_model ->
      deep_merge(base_model, override_model, fn _k, _v1, v2 -> v2 end)
    end)
    |> Map.values()
    |> Enum.reject(fn model ->
      provider = Map.get(model, :provider)
      model_id = Map.get(model, :id)
      patterns = Map.get(compiled_excludes, provider, [])
      matches_exclude?(model_id, patterns)
    end)
  end

  @doc """
  Merges two lists of maps by a shared ID key.

  Keeps the base list order, overrides items with matching IDs from the override list,
  and appends override-only items in their original order.

  Used by `LLMDB.Pricing` to merge pricing components from provider defaults
  with model-specific overrides.

  ## Parameters

  - `base_list` - The base list of maps (order preserved)
  - `override_list` - Maps that override or extend the base list
  - `id_key` - The key to match on (default: `:id`). Supports both atom and string keys.

  ## Examples

      # Override matching items, preserve order
      iex> base = [%{id: "a", value: 1}, %{id: "b", value: 2}]
      iex> override = [%{id: "b", value: 20}]
      iex> LLMDB.Merge.merge_list_by_id(base, override)
      [%{id: "a", value: 1}, %{id: "b", value: 20}]

      # Append new items from override
      iex> base = [%{id: "a", value: 1}]
      iex> override = [%{id: "b", value: 2}, %{id: "c", value: 3}]
      iex> LLMDB.Merge.merge_list_by_id(base, override)
      [%{id: "a", value: 1}, %{id: "b", value: 2}, %{id: "c", value: 3}]

      # Pricing component merge example
      iex> defaults = [%{id: "tool.search", rate: 10.0}, %{id: "tool.code", rate: 5.0}]
      iex> overrides = [%{id: "tool.search", rate: 0.0}]  # Free search
      iex> LLMDB.Merge.merge_list_by_id(defaults, overrides)
      [%{id: "tool.search", rate: 0.0}, %{id: "tool.code", rate: 5.0}]
  """
  @spec merge_list_by_id([map()], [map()], atom() | String.t()) :: [map()]
  def merge_list_by_id(base_list, override_list, id_key \\ :id)
      when is_list(base_list) and is_list(override_list) do
    base_ids =
      base_list
      |> Enum.map(&list_item_id(&1, id_key))
      |> MapSet.new()

    overrides =
      override_list
      |> Enum.reduce(%{}, fn item, acc ->
        Map.put(acc, list_item_id(item, id_key), item)
      end)

    merged =
      Enum.map(base_list, fn item ->
        Map.get(overrides, list_item_id(item, id_key), item)
      end)

    extras =
      Enum.filter(override_list, fn item ->
        id = list_item_id(item, id_key)
        not MapSet.member?(base_ids, id)
      end)

    merged ++ extras
  end

  defp list_item_id(item, id_key) when is_map(item) and is_atom(id_key) do
    Map.get(item, id_key) || Map.get(item, Atom.to_string(id_key))
  end

  defp list_item_id(item, id_key) when is_map(item) and is_binary(id_key) do
    Map.get(item, id_key) || map_get_existing_atom(item, id_key)
  end

  defp map_get_existing_atom(item, key) do
    case to_existing_atom(key) do
      {:ok, atom} -> Map.get(item, atom)
      :error -> nil
    end
  end

  defp to_existing_atom(key) do
    try do
      {:ok, String.to_existing_atom(key)}
    rescue
      ArgumentError -> :error
    end
  end

  @doc """
  Compiles exclude patterns to regex for performance.

  Converts a map of %{provider => [patterns]} to %{provider => [compiled_patterns]}
  where each pattern is either kept as a string (for exact match) or compiled to regex (for globs).

  ## Examples

      iex> result = LLMDB.Merge.compile_excludes(%{openai: ["gpt-3", "gpt-5-*"]})
      iex> [exact, pattern] = result.openai
      iex> exact
      "gpt-3"
      iex> Regex.match?(pattern, "gpt-5-pro")
      true
  """
  @spec compile_excludes(map()) :: map()
  def compile_excludes(excludes) when is_map(excludes) do
    Map.new(excludes, fn {provider, patterns} ->
      compiled =
        Enum.map(patterns, fn pattern ->
          if String.contains?(pattern, "*") do
            compile_pattern(pattern)
          else
            pattern
          end
        end)

      {provider, compiled}
    end)
  end

  @doc """
  Converts a glob pattern to an anchored regex.

  - "*" becomes ".*"
  - Escape other regex special chars
  - Anchor with ^ and $

  ## Examples

      iex> pattern = LLMDB.Merge.compile_pattern("gpt-*")
      iex> Regex.match?(pattern, "gpt-4")
      true

      iex> pattern = LLMDB.Merge.compile_pattern("gpt-5-*-mini")
      iex> Regex.match?(pattern, "gpt-5-turbo-mini")
      true
  """
  @spec compile_pattern(String.t()) :: Regex.t()
  def compile_pattern(pattern) when is_binary(pattern) do
    escaped = Regex.escape(pattern)
    regex_pattern = String.replace(escaped, "\\*", ".*")
    Regex.compile!("^#{regex_pattern}$")
  end

  @doc """
  Checks if a model_id matches any exclude pattern.

  Patterns can be exact strings or compiled regexes.

  ## Examples

      iex> LLMDB.Merge.matches_exclude?("gpt-4", ["gpt-3", "gpt-5"])
      false

      iex> LLMDB.Merge.matches_exclude?("gpt-3", ["gpt-3", "gpt-5"])
      true

      iex> LLMDB.Merge.matches_exclude?("gpt-5-pro", [~r/^gpt-5-.*$/])
      true

      iex> LLMDB.Merge.matches_exclude?("gpt-4", [~r/^gpt-5-.*$/])
      false
  """
  @spec matches_exclude?(String.t() | nil, [String.t() | Regex.t()]) :: boolean()
  def matches_exclude?(nil, _patterns), do: false

  def matches_exclude?(model_id, patterns) when is_binary(model_id) and is_list(patterns) do
    Enum.any?(patterns, fn
      pattern when is_binary(pattern) -> model_id == pattern
      %Regex{} = pattern -> Regex.match?(pattern, model_id)
    end)
  end

  # Private helpers

  defp union_unique(left, right) when is_list(left) and is_list(right) do
    (left ++ right) |> Enum.uniq()
  end

  defp deep_merge(left, right, resolve_conflict) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn key, left_val, right_val ->
      deep_merge_value(left_val, right_val, fn l, r -> resolve_conflict.(key, l, r) end)
    end)
  end

  defp deep_merge_value(left, right, resolve_conflict) do
    cond do
      is_map(left) and is_map(right) ->
        deep_merge(left, right, fn _k, l, r -> resolve_conflict.(l, r) end)

      is_list(left) and is_list(right) ->
        (left ++ right) |> Enum.uniq()

      true ->
        resolve_conflict.(left, right)
    end
  end
end
