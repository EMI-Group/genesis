defmodule EvoDashWeb.SettingsLive.ConfigIO do
  @moduledoc """
  Configuration I/O helpers for the SettingsLive page.

  Provides config loading, building config from category params, runtime
  updates, and untrusted-string-to-atom whitelist builders. All functions are
  pure (no socket dependency) except `update_runtime_from_file_config/2` which
  accepts and returns a LiveView socket.
  """

  alias EvoGit.Config.Schema
  alias EvoDash.SettingsUtils

  @doc """
  Loads the full user configuration from disk via `EvoGit.Config.resolve/0`.
  """
  def load_file_config do
    EvoGit.Config.resolve()
  end

  @doc """
  Reads the current scheduler configuration from the running AgentScheduler.
  """
  def load_scheduler_config do
    EvoGit.AgentScheduler.get_config()
  end

  @doc """
  Pushes relevant scheduler and LLM model config values from `file_config` to
  the running AgentScheduler. Returns the (possibly updated) socket.
  """
  def update_runtime_from_file_config(file_config, socket) do
    updates =
      []
      |> SettingsUtils.maybe_add_kw(:max_concurrency, get_in(file_config, [:scheduler, :max_concurrency]))
      |> SettingsUtils.maybe_add_kw(
        :max_tool_concurrency,
        get_in(file_config, [:scheduler, :max_tool_concurrency])
      )
      |> SettingsUtils.maybe_add_kw(:agent_max_retries, get_in(file_config, [:scheduler, :agent_max_retries]))
      |> SettingsUtils.maybe_add_kw(:max_agent_depth, get_in(file_config, [:scheduler, :max_agent_depth]))
      |> SettingsUtils.maybe_add_kw(:max_retries, get_in(file_config, [:scheduler, :max_retries]))
      |> SettingsUtils.maybe_add_kw(:max_turns, get_in(file_config, [:scheduler, :max_turns]))
      |> SettingsUtils.maybe_add_kw(:max_turns_root, get_in(file_config, [:scheduler, :max_turns_root]))

    # Note: :tools config (e.g., web_search) is read from EvoGit.Config.resolve()
    # at execution time — no runtime push needed here.

    # LLM model profiles: the scheduler now accepts the full profiles list and
    # derives the model + generation params from the default profile internally.
    # We no longer push :llm_model / :llm_generation_params separately.
    updates =
      SettingsUtils.maybe_add_kw(updates, :model_profiles, Schema.model_profiles(file_config))

    if updates != [] do
      case EvoGit.AgentScheduler.update_config(updates) do
        :ok ->
          socket
          |> Phoenix.Component.assign(scheduler_config: load_scheduler_config())

        {:error, _msg} ->
          socket
      end
    else
      socket
    end
  end

  @doc """
  Builds a config map from flat form params for a given category (or all
  matching schemas when `category` is nil).
  """
  def build_config_from_category_params(params, category, schemas, file_config) do
    # Build a nested map from flat params for this category
    {category_config, emptied_paths} = params_to_category_config(params, category, schemas)

    # Deep merge into file_config
    merged = SettingsUtils.deep_merge(file_config, category_config)

    # Delete keys that were explicitly emptied
    Enum.reduce(emptied_paths, merged, fn key_path, acc ->
      SettingsUtils.deep_delete(acc, key_path)
    end)
  end

  @doc """
  Converts flat form params into a nested config map and a list of paths to
  delete (for explicitly emptied values).
  """
  def params_to_category_config(params, _category, schemas) do
    # Skip :model_profiles type schemas entirely. These schemas (e.g. [:llm, :models])
    # are managed by dedicated event handlers (save_model_profile, delete_model_profile,
    # add_model_profile) and have no corresponding flat form field. If processed here,
    # they'd parse as :explicitly_empty (no matching form param) and get queued for
    # deletion via deep_delete, wiping the entire models list on every save_category.
    schemas = Enum.reject(schemas, &(&1.type == :model_profiles))

    Enum.reduce(schemas, {%{}, []}, fn schema, {config_acc, emptied_acc} ->
      value = Map.get(params, Enum.join(schema.key_path, "."))

      parsed =
        cond do
          schema.type == :boolean ->
            value == "true"

          is_nil(value) or value == "" ->
            :explicitly_empty

          schema.type in [:pos_integer, :non_neg_integer, :integer] ->
            SettingsUtils.parse_int(value)

          schema.type == :float ->
            SettingsUtils.parse_float(value)

          schema.type in [:string, :model_spec] ->
            value

          schema.type == :atom ->
            SettingsUtils.parse_atom(value, schema)
        end

      cond do
        parsed == :explicitly_empty ->
          {config_acc, [schema.key_path | emptied_acc]}

        is_nil(parsed) ->
          {config_acc, emptied_acc}

        true ->
          {SettingsUtils.deep_put(config_acc, schema.key_path, parsed), emptied_acc}
      end
    end)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: parsing
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Parses a dot-separated path string into a list of atoms, validated against
  all known schema key_path segments. Returns `nil` when any segment is unknown,
  so callers can surface a friendly error instead of crashing.
  """
  def parse_key_path(path_str, schemas_by_category) when is_binary(path_str) do
    valid_segment_str_to_atom =
      schemas_by_category
      |> Enum.flat_map(fn {_cat, schemas} -> schemas end)
      |> Enum.flat_map(fn schema -> schema.key_path end)
      |> Enum.uniq()
      |> Map.new(fn atom -> {Atom.to_string(atom), atom} end)

    segments = String.split(path_str, ".")

    if Enum.all?(segments, &Map.has_key?(valid_segment_str_to_atom, &1)) do
      Enum.map(segments, &Map.fetch!(valid_segment_str_to_atom, &1))
    else
      nil
    end
  end

  @doc """
  Finds the schema matching the given key_path in schemas_by_category.
  Returns `nil` when key_path is nil or not found.
  """
  def find_schema(nil, _schemas_by_category), do: nil

  def find_schema(key_path, schemas_by_category) do
    schemas_by_category
    |> Enum.flat_map(fn {_cat, schemas} -> schemas end)
    |> Enum.find(&(&1.key_path == key_path))
  end

  @doc """
  Flattens per-category error lists into a single list of errors.
  """
  def all_errors(per_category_errors) do
    Enum.flat_map(per_category_errors, fn {_cat, errors} -> errors end)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: untrusted-string → atom whitelists
  #
  # Each helper builds a map keyed by the *string* form of a known atom, so
  # client-supplied (untrusted) values can be validated via Map.get/2 without
  # ever calling String.to_existing_atom/1 or String.to_atom/1. Unknown values
  # resolve to nil so callers can surface a friendly default instead of crashing
  # with an ArgumentError (or risking atom-table exhaustion via to_atom/1).
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Builds a whitelist map from category string names to category atoms.
  """
  def category_str_to_atom(schemas_by_category) do
    Map.new(schemas_by_category, fn {cat_atom, _schemas} ->
      {Atom.to_string(cat_atom), cat_atom}
    end)
  end

  @doc """
  Builds a whitelist map from provider id strings to provider structs.
  """
  def provider_by_id_str do
    Map.new(EvoGit.Config.LLMCatalog.providers(), fn p -> {Atom.to_string(p.id), p} end)
  end

  @doc """
  Builds a whitelist map from variant id strings to variant atoms for the
  given provider.
  """
  def variant_id_by_str(provider_atom) when is_atom(provider_atom) do
    case EvoGit.Config.LLMCatalog.provider_variants(provider_atom) do
      nil -> %{}
      variants -> Map.new(variants, fn v -> {Atom.to_string(v.id), v.id} end)
    end
  end
end
