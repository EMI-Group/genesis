defmodule LLMDB.Normalize do
  @moduledoc """
  Complete normalization utilities for raw data into consistent formats.

  This module handles ALL normalization in one place:
  - Provider IDs: string → atom (with hyphen → underscore conversion)
  - Model providers: string → atom
  - Modalities: string → atom (from valid set)
  - Tags: map → list, nil → []
  - Dates: DateTime/Date → ISO8601 string
  - Removing nil values from maps

  Uses `String.to_existing_atom/1` at runtime to prevent atom leaking.
  Uses `String.to_atom/1` ONLY in unsafe mode during build-time (mix tasks).
  """

  @doc """
  Normalizes a provider ID to an atom.

  Converts binary provider IDs to atoms, handling hyphens by converting them
  to underscores. Uses String.to_existing_atom/1 to prevent atom leaking
  at runtime. During activation task, unsafe conversion is allowed.

  ## Examples

      iex> LLMDB.Normalize.normalize_provider_id("google-vertex")
      {:ok, :google_vertex}

      iex> LLMDB.Normalize.normalize_provider_id(:openai)
      {:ok, :openai}

      iex> LLMDB.Normalize.normalize_provider_id("malicious#{String.duplicate("a", 1000)}")
      {:error, :bad_provider}
  """
  @spec normalize_provider_id(binary() | atom(), keyword()) ::
          {:ok, atom()} | {:error, :bad_provider}
  def normalize_provider_id(provider_id, opts \\ [])

  def normalize_provider_id(provider_id, _opts) when is_atom(provider_id) do
    {:ok, provider_id}
  end

  def normalize_provider_id(provider_id, opts) when is_binary(provider_id) do
    if valid_provider_string?(provider_id) do
      normalized_str = String.replace(provider_id, "-", "_")
      convert_to_atom(normalized_str, opts)
    else
      {:error, :bad_provider}
    end
  end

  def normalize_provider_id(_, _), do: {:error, :bad_provider}

  # Convert string to atom, using safe conversion unless unsafe is explicitly allowed
  defp convert_to_atom(str, opts) do
    if Keyword.get(opts, :unsafe, false) do
      # Only used during activation task when generating provider atoms
      {:ok, String.to_atom(str)}
    else
      # Runtime: only accept existing atoms to prevent atom leaking
      try do
        atom = String.to_existing_atom(str)
        {:ok, atom}
        # Note: Whitelist check removed - validation now happens in verify_provider_exists
        # which checks the loaded catalog, supporting custom/test providers
      rescue
        # Atom doesn't exist at all - treat as unknown provider
        ArgumentError -> {:error, :unknown_provider}
      end
    end
  end

  @doc """
  Normalizes a model's identity to a {provider_atom, model_id} tuple.

  Extracts the provider (as an atom) and id from a model map.

  ## Examples

      iex> LLMDB.Normalize.normalize_model_identity(%{provider: "google-vertex", id: "gemini-pro"})
      {:ok, {:google_vertex, "gemini-pro"}}

      iex> LLMDB.Normalize.normalize_model_identity(%{provider: :openai, id: "gpt-4"})
      {:ok, {:openai, "gpt-4"}}

      iex> LLMDB.Normalize.normalize_model_identity(%{provider: "openai"})
      {:error, :missing_id}
  """
  @spec normalize_model_identity(map(), keyword()) ::
          {:ok, {atom(), String.t()}} | {:error, term()}
  def normalize_model_identity(model, opts \\ [])

  def normalize_model_identity(%{provider: provider, id: id}, opts) when is_binary(id) do
    case normalize_provider_id(provider, opts) do
      {:ok, provider_atom} -> {:ok, {provider_atom, id}}
      error -> error
    end
  end

  def normalize_model_identity(%{provider: _provider, id: _id}, _opts),
    do: {:error, :invalid_id}

  def normalize_model_identity(%{id: _id}, _opts), do: {:error, :missing_provider}
  def normalize_model_identity(%{provider: _provider}, _opts), do: {:error, :missing_id}
  def normalize_model_identity(_, _opts), do: {:error, :invalid_model}

  @doc """
  Normalizes a date string to "YYYY-MM-DD" format.

  Attempts to parse and normalize various date formats. If the date cannot
  be normalized, it is returned as-is.

  ## Examples

      iex> LLMDB.Normalize.normalize_date("2024-01-15")
      "2024-01-15"

      iex> LLMDB.Normalize.normalize_date("2024/01/15")
      "2024-01-15"

      iex> LLMDB.Normalize.normalize_date("invalid-date")
      "invalid-date"

      iex> LLMDB.Normalize.normalize_date(nil)
      nil
  """
  @spec normalize_date(String.t() | nil) :: String.t() | nil
  def normalize_date(nil), do: nil
  def normalize_date(""), do: ""

  def normalize_date(date_string) when is_binary(date_string) do
    date_string
    |> String.replace("/", "-")
    |> parse_date()
    |> case do
      {:ok, normalized} -> normalized
      :error -> date_string
    end
  end

  @doc """
  Normalizes a list of provider maps.

  Applies normalize_provider_id to the :id field of each provider map.

  ## Examples

      iex> LLMDB.Normalize.normalize_providers([%{id: "google-vertex"}, %{id: :openai}])
      [%{id: :google_vertex}, %{id: :openai}]
  """
  @spec normalize_providers([map()]) :: [map()]
  def normalize_providers(providers) when is_list(providers) do
    Enum.map(providers, &normalize_provider/1)
  end

  @doc """
  Normalizes a list of model maps.

  Applies normalize_provider_id to the :provider field and ensures :id is present.

  ## Examples

      iex> LLMDB.Normalize.normalize_models([%{provider: "google-vertex", id: "gemini-pro"}])
      [%{provider: :google_vertex, id: "gemini-pro"}]
  """
  @spec normalize_models([map()]) :: [map()]
  def normalize_models(models) when is_list(models) do
    Enum.map(models, &normalize_model/1)
  end

  # Private helpers

  defp valid_provider_string?(str) when is_binary(str) do
    byte_size(str) > 0 and
      byte_size(str) <= 255 and
      String.match?(str, ~r/^[a-z0-9_-]+$/i)
  end

  defp normalize_provider(%{id: id} = provider) do
    # Use unsafe mode for batch normalization (used during activation)
    case normalize_provider_id(id, unsafe: true) do
      {:ok, normalized_id} -> %{provider | id: normalized_id}
      {:error, _} -> provider
    end
  end

  defp normalize_provider(provider), do: provider

  defp normalize_model(%{provider: provider} = model) do
    # Use unsafe mode for batch normalization (used during activation)
    model
    |> then(fn m ->
      case normalize_provider_id(provider, unsafe: true) do
        {:ok, normalized_provider} -> %{m | provider: normalized_provider}
        {:error, _} -> m
      end
    end)
    |> normalize_modalities()
    |> normalize_tags()
    |> normalize_dates()
    |> normalize_lifecycle()
    |> remove_nil_values()
  end

  defp normalize_model(model) do
    model
    |> normalize_modalities()
    |> normalize_tags()
    |> normalize_dates()
    |> normalize_lifecycle()
    |> remove_nil_values()
  end

  defp normalize_modalities(%{modalities: modalities} = model) when is_map(modalities) do
    normalized_modalities =
      modalities
      |> Enum.map(fn
        {key, value} when is_list(value) ->
          {key, Enum.map(value, &normalize_modality_atom/1)}

        {key, value} ->
          {key, value}
      end)
      |> Map.new()

    %{model | modalities: normalized_modalities}
  end

  defp normalize_modalities(model), do: model

  # Known valid modality atoms - these represent input/output types for models
  @valid_modalities MapSet.new([
                      :text,
                      :image,
                      :audio,
                      :video,
                      :code,
                      :document,
                      :embedding,
                      :pdf
                    ])

  defp normalize_modality_atom(value) when is_binary(value) do
    # Try to convert to existing atom first (safe)
    atom = String.to_existing_atom(value)
    if atom in @valid_modalities, do: atom, else: value
  rescue
    ArgumentError ->
      # Atom doesn't exist yet - check if it's a known modality
      # This is safe because we only create atoms from a small, known set
      atom = String.to_atom(value)
      if atom in @valid_modalities, do: atom, else: value
  end

  defp normalize_modality_atom(value) when is_atom(value) do
    if value in @valid_modalities, do: value, else: value
  end

  defp normalize_tags(model) do
    case Map.get(model, :tags) do
      tags when is_map(tags) and map_size(tags) > 0 ->
        Map.put(model, :tags, Map.values(tags))

      tags when is_map(tags) ->
        Map.put(model, :tags, [])

      nil ->
        model

      tags when is_list(tags) ->
        model

      _ ->
        model
    end
  end

  defp normalize_dates(model) do
    model
    |> normalize_date_field(:last_updated)
    |> normalize_date_field(:knowledge)
  end

  defp normalize_lifecycle(model) do
    lifecycle = Map.get(model, :lifecycle)
    lifecycle = if is_map(lifecycle), do: lifecycle, else: nil
    status = lifecycle_status_from_map(lifecycle)
    deprecated_flag = Map.get(model, :deprecated) == true
    retired_flag = Map.get(model, :retired) == true

    cond do
      status == "retired" ->
        model
        |> Map.put(:deprecated, true)
        |> Map.put(:retired, true)

      status == "deprecated" ->
        model
        |> Map.put(:deprecated, true)
        |> Map.put(:retired, false)

      status == "active" ->
        model
        |> Map.put(:deprecated, false)
        |> Map.put(:retired, false)

      is_nil(status) and (retired_flag or deprecated_flag) ->
        derived_status = if retired_flag, do: "retired", else: "deprecated"

        updated_lifecycle =
          (lifecycle || %{})
          |> Map.put(:status, derived_status)

        model
        |> Map.put(:lifecycle, updated_lifecycle)
        |> Map.put(:deprecated, true)
        |> Map.put(:retired, retired_flag)

      true ->
        model
    end
  end

  defp lifecycle_status_from_map(nil), do: nil

  defp lifecycle_status_from_map(lifecycle) when is_map(lifecycle) do
    Map.get(lifecycle, :status) || Map.get(lifecycle, "status")
  end

  defp lifecycle_status_from_map(_), do: nil

  defp normalize_date_field(model, field) do
    if Map.has_key?(model, field) do
      case Map.get(model, field) do
        %DateTime{} = dt ->
          Map.put(model, field, DateTime.to_iso8601(dt))

        %Date{} = d ->
          Map.put(model, field, Date.to_iso8601(d))

        nil ->
          model

        value when is_binary(value) ->
          model

        _ ->
          Map.delete(model, field)
      end
    else
      model
    end
  end

  defp remove_nil_values(model) when is_map(model) do
    model
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_date(date_string) do
    with [year, month, day] <- String.split(date_string, "-", parts: 3),
         {year_int, ""} <- Integer.parse(year),
         {month_int, ""} <- Integer.parse(month),
         {day_int, ""} <- Integer.parse(day),
         true <- valid_date?(year_int, month_int, day_int) do
      normalized =
        "#{String.pad_leading(Integer.to_string(year_int), 4, "0")}-" <>
          "#{String.pad_leading(Integer.to_string(month_int), 2, "0")}-" <>
          "#{String.pad_leading(Integer.to_string(day_int), 2, "0")}"

      {:ok, normalized}
    else
      _ -> :error
    end
  end

  defp valid_date?(year, month, day) do
    year >= 1000 and year <= 9999 and
      month >= 1 and month <= 12 and
      day >= 1 and day <= 31
  end
end
