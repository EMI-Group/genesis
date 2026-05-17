defmodule LLMDB.Spec do
  @moduledoc """
  Canonical "provider:model" spec parsing and resolution.

  This module provides functions to parse and resolve model specifications in various formats,
  including "provider:model" strings, "model@provider" strings (filename-safe), tuples,
  and bare model IDs with provider scope.

  ## String Formats

  Two string formats are supported:

  - `"provider:model"` - Traditional colon separator (default)
  - `"model@provider"` - Email-like format, filesystem-safe for filenames

  Both formats parse to the same internal representation and can be used interchangeably.
  The @ format is recommended when model specs are used in filenames, CI artifact names,
  or other filesystem contexts.

  ## Amazon Bedrock Inference Profiles

  For Amazon Bedrock models, inference profile IDs with region prefixes (us., eu., ap., apac., ca.,
  au., jp., us-gov., global.) are supported. The region prefix is stripped for catalog lookup but
  preserved in the returned model ID. For example:

      iex> LLMDB.Spec.resolve("amazon_bedrock:us.anthropic.claude-opus-4-1-20250805-v1:0")
      {:ok, {:amazon_bedrock, "us.anthropic.claude-opus-4-1-20250805-v1:0", %LLMDB.Model{}}}

  The lookup uses "anthropic.claude-opus-4-1-20250805-v1:0" to find metadata, but the returned
  model ID retains the "us." prefix for API routing purposes.
  """

  alias LLMDB.{Normalize, Store}
  alias LLMDB.Model

  # Valid Bedrock inference profile region prefixes.
  # See: https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-support.html
  @bedrock_prefixes ~w(us. eu. ap. apac. ca. au. jp. us-gov. global.)

  @doc """
  Parses and validates a provider identifier.

  Accepts atom or binary input, normalizes to atom, and verifies the provider
  exists in the current catalog.

  ## Parameters

  - `input` - Provider identifier as atom or binary

  ## Returns

  - `{:ok, atom}` - Normalized provider atom if valid and exists in catalog
  - `{:error, :unknown_provider}` - Provider not found in catalog
  - `{:error, :bad_provider}` - Invalid provider format

  ## Examples

      iex> LLMDB.Spec.parse_provider(:openai)
      {:ok, :openai}

      iex> LLMDB.Spec.parse_provider("google-vertex")
      {:ok, :google_vertex}

      iex> LLMDB.Spec.parse_provider("nonexistent")
      {:error, :unknown_provider}
  """
  @spec parse_provider(atom() | binary()) ::
          {:ok, atom()} | {:error, :unknown_provider | :bad_provider}
  def parse_provider(input) do
    with {:ok, provider_atom} <- Normalize.normalize_provider_id(input),
         {:ok, _} <- verify_provider_exists(provider_atom) do
      {:ok, provider_atom}
    else
      {:error, :bad_provider} -> {:error, :bad_provider}
      {:error, :unknown_provider} -> {:error, :unknown_provider}
    end
  end

  @doc """
  Parses a model specification string in either "provider:model" or "model@provider" format.

  Automatically detects the format based on separators present. Validates the provider
  exists in the catalog and checks for reserved characters in segments.

  ## Parameters

  - `spec` - String in "provider:model" or "model@provider" format, or {provider, model_id} tuple
  - `opts` - Keyword list with optional `:format` to explicitly specify format

  ## Options

  - `:format` - Explicitly specify the format as `:colon` or `:at`. Required when both separators present.

  ## Returns

  - `{:ok, {provider_atom, model_id}}` - Parsed and normalized spec
  - `{:error, :invalid_format}` - No valid separator found
  - `{:error, :ambiguous_format}` - Both separators present without explicit format
  - `{:error, :unknown_provider}` - Provider not found in catalog
  - `{:error, :bad_provider}` - Invalid provider format
  - `{:error, :invalid_chars}` - Reserved characters in provider or model segments
  - `{:error, :empty_segment}` - Provider or model segment is empty

  ## Examples

      iex> LLMDB.Spec.parse_spec("openai:gpt-4")
      {:ok, {:openai, "gpt-4"}}

      iex> LLMDB.Spec.parse_spec("gpt-4@openai")
      {:ok, {:openai, "gpt-4"}}

      iex> LLMDB.Spec.parse_spec("google-vertex:gemini-pro")
      {:ok, {:google_vertex, "gemini-pro"}}

      iex> LLMDB.Spec.parse_spec("provider:model@ambiguous", format: :colon)
      {:ok, {:provider, "model@ambiguous"}}

      iex> LLMDB.Spec.parse_spec("gpt-4")
      {:error, :invalid_format}
  """
  @spec parse_spec(String.t() | {atom(), String.t()}, keyword()) ::
          {:ok, {atom(), String.t()}}
          | {:error,
             :invalid_format
             | :ambiguous_format
             | :unknown_provider
             | :bad_provider
             | :invalid_chars
             | :empty_segment}
  def parse_spec(input, opts \\ [])

  def parse_spec({provider, model_id}, _opts) when is_atom(provider) and is_binary(model_id) do
    {:ok, {provider, model_id}}
  end

  def parse_spec(spec, opts) when is_binary(spec) do
    has_colon = String.contains?(spec, ":")
    has_at = String.contains?(spec, "@")

    case {has_colon, has_at, Keyword.get(opts, :format)} do
      {true, true, nil} ->
        # When both separators present, try to determine format based on provider validity
        # Try @ format first (model@provider), check if potential provider is valid
        case String.split(spec, "@", parts: 2) do
          [_model_part, provider_part] ->
            # Check if the part after @ could be a valid provider
            case parse_provider(provider_part) do
              {:ok, _} ->
                # @ format works, use it
                parse_at_format(spec)

              {:error, _} ->
                # @ format doesn't work, try colon format
                parse_colon_format(spec)
            end

          _ ->
            parse_colon_format(spec)
        end

      {true, true, :colon} ->
        parse_colon_format(spec)

      {true, true, :at} ->
        parse_at_format(spec)

      {true, false, _} ->
        parse_colon_format(spec)

      {false, true, _} ->
        parse_at_format(spec)

      {false, false, _} ->
        {:error, :invalid_format}
    end
  end

  @doc """
  Parses a model specification string, raising on error.

  Same as `parse_spec/2` but raises `ArgumentError` instead of returning error tuple.

  ## Examples

      iex> LLMDB.Spec.parse_spec!("openai:gpt-4")
      {:openai, "gpt-4"}

      iex> LLMDB.Spec.parse_spec!("gpt-4@openai")
      {:openai, "gpt-4"}
  """
  @spec parse_spec!(String.t() | {atom(), String.t()}, keyword()) :: {atom(), String.t()}
  def parse_spec!(input, opts \\ []) do
    case parse_spec(input, opts) do
      {:ok, result} ->
        result

      {:error, reason} ->
        raise ArgumentError,
              "invalid model spec: #{inspect(input)} (#{inspect(reason)})"
    end
  end

  @doc """
  Formats a model specification as a string.

  Converts a {provider, model_id} tuple to string format. The output format can be
  controlled via the `format` parameter or falls back to the application config
  `:llm_db, :model_spec_format` (default: `:provider_colon_model`).

  ## Parameters

  - `spec` - {provider_atom, model_id} tuple
  - `format` - Optional format override (atom)

  ## Supported Formats

  - `:provider_colon_model` - "provider:model" (default)
  - `:model_at_provider` - "model@provider" (filename-safe)
  - `:filename_safe` - alias for `:model_at_provider`

  ## Examples

      iex> LLMDB.Spec.format_spec({:openai, "gpt-4"})
      "openai:gpt-4"

      iex> LLMDB.Spec.format_spec({:openai, "gpt-4"}, :model_at_provider)
      "gpt-4@openai"

      iex> LLMDB.Spec.format_spec({:openai, "gpt-4o-mini"}, :filename_safe)
      "gpt-4o-mini@openai"
  """
  @spec format_spec({atom(), String.t()}, atom() | nil) :: String.t()
  def format_spec({provider, model_id}, format \\ nil)
      when is_atom(provider) and is_binary(model_id) do
    actual_format =
      format || Application.get_env(:llm_db, :model_spec_format, :provider_colon_model)

    case actual_format do
      :provider_colon_model ->
        "#{provider}:#{model_id}"

      :model_at_provider ->
        "#{model_id}@#{provider}"

      :filename_safe ->
        "#{model_id}@#{provider}"

      other ->
        raise ArgumentError, "unknown format #{inspect(other)}"
    end
  end

  @doc """
  Builds a model specification string from various inputs.

  Accepts strings (in any supported format) or tuples and outputs a string
  in the desired format.

  ## Parameters

  - `input` - Model spec as string or tuple
  - `opts` - Keyword list with optional `:format` for output format

  ## Examples

      iex> LLMDB.Spec.build_spec("openai:gpt-4", format: :filename_safe)
      "gpt-4@openai"

      iex> LLMDB.Spec.build_spec({:openai, "gpt-4"}, format: :model_at_provider)
      "gpt-4@openai"
  """
  @spec build_spec(String.t() | {atom(), String.t()}, keyword()) :: String.t()
  def build_spec(input, opts \\ []) do
    spec = normalize_spec(input)
    format_spec(spec, Keyword.get(opts, :format))
  end

  @doc """
  Normalizes a model specification to tuple format.

  Accepts either a string (in any supported format) or a tuple and returns
  a normalized {provider, model_id} tuple.

  ## Examples

      iex> LLMDB.Spec.normalize_spec("openai:gpt-4")
      {:openai, "gpt-4"}

      iex> LLMDB.Spec.normalize_spec("gpt-4@openai")
      {:openai, "gpt-4"}

      iex> LLMDB.Spec.normalize_spec({:openai, "gpt-4"})
      {:openai, "gpt-4"}
  """
  @spec normalize_spec(String.t() | {atom(), String.t()}) :: {atom(), String.t()}
  def normalize_spec({provider, model_id}) when is_atom(provider) and is_binary(model_id) do
    {provider, model_id}
  end

  def normalize_spec(input) when is_binary(input) do
    parse_spec!(input)
  end

  # Private parsing helpers

  defp parse_colon_format(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider_str, model_id] ->
        with {:ok, _} <- validate_provider_segment(provider_str),
             {:ok, _} <- validate_model_segment(model_id, :colon),
             {:ok, provider_atom} <- parse_provider(provider_str) do
          {:ok, {provider_atom, String.trim(model_id)}}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  defp parse_at_format(spec) do
    case String.split(spec, "@", parts: 2) do
      [model_id, provider_str] ->
        with {:ok, _} <- validate_model_segment(model_id, :at),
             {:ok, _} <- validate_provider_segment(provider_str),
             {:ok, provider_atom} <- parse_provider(provider_str) do
          {:ok, {provider_atom, String.trim(model_id)}}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  defp validate_provider_segment(segment) do
    trimmed = String.trim(segment)

    cond do
      trimmed == "" ->
        {:error, :empty_segment}

      String.contains?(segment, ":") ->
        {:error, :invalid_chars}

      String.contains?(segment, "@") ->
        {:error, :invalid_chars}

      true ->
        {:ok, segment}
    end
  end

  defp validate_model_segment(segment, _format) do
    trimmed = String.trim(segment)

    cond do
      trimmed == "" ->
        {:error, :empty_segment}

      true ->
        {:ok, segment}
    end
  end

  @doc """
  Resolves a model specification to a canonical model record.

  Accepts multiple input formats:
  - "provider:model" string
  - {provider, model_id} tuple
  - Bare "model" string with opts[:scope] = provider_atom

  Handles alias resolution and validates the model exists in the catalog.

  ## Parameters

  - `input` - Model specification in one of the supported formats
  - `opts` - Keyword list with optional `:scope` for bare model resolution

  ## Returns

  - `{:ok, {provider, canonical_id, Model.t()}}` - Resolved model
  - `{:error, :not_found}` - Model doesn't exist
  - `{:error, :ambiguous}` - Bare model ID exists under multiple providers without scope
  - `{:error, :invalid_format}` - Malformed input
  - `{:error, term}` - Other parsing errors

  ## Examples

      iex> LLMDB.Spec.resolve("openai:gpt-4")
      {:ok, {:openai, "gpt-4", %LLMDB.Model{}}}

      iex> LLMDB.Spec.resolve({:openai, "gpt-4"})
      {:ok, {:openai, "gpt-4", %LLMDB.Model{}}}

      iex> LLMDB.Spec.resolve("gpt-4", scope: :openai)
      {:ok, {:openai, "gpt-4", %LLMDB.Model{}}}

      iex> LLMDB.Spec.resolve("gpt-4")
      {:error, :ambiguous}
  """
  @spec resolve(String.t() | {atom(), String.t()}, keyword()) ::
          {:ok, {atom(), String.t(), Model.t()}} | {:error, term()}
  def resolve(input, opts \\ [])

  def resolve(spec, opts) when is_binary(spec) do
    case String.contains?(spec, ":") do
      true ->
        with {:ok, {provider, model_id}} <- parse_spec(spec) do
          resolve_model(provider, model_id)
        end

      false ->
        case Keyword.get(opts, :scope) do
          nil -> resolve_bare_model(spec)
          scope -> resolve_model(scope, spec)
        end
    end
  end

  def resolve({provider, model_id}, _opts) when is_atom(provider) and is_binary(model_id) do
    resolve_model(provider, model_id)
  end

  def resolve(_, _), do: {:error, :invalid_format}

  # Private helpers

  defp verify_provider_exists(provider_atom) do
    case Store.snapshot() do
      %{providers_by_id: providers} when is_map(providers) ->
        if Map.has_key?(providers, provider_atom) do
          {:ok, provider_atom}
        else
          {:error, :unknown_provider}
        end

      _ ->
        {:error, :unknown_provider}
    end
  end

  @doc """
  Strips any inference profile prefix from a model ID.

  For Amazon Bedrock, splits prefixes like `"us."`, `"eu."`, `"au."` etc. from the model ID
  so the base ID can be used for catalog lookup. Returns `{base_id, prefix}` where prefix
  is `nil` if no prefix was found.

  For other providers, returns `{model_id, nil}` unchanged.
  """
  @spec strip_prefix(atom(), String.t()) :: {String.t(), String.t() | nil}
  def strip_prefix(provider, model_id) do
    lookup_id_and_prefix(provider, model_id)
  end

  defp lookup_id_and_prefix(provider, model_id) do
    if provider == :amazon_bedrock do
      case Enum.find_value(@bedrock_prefixes, fn prefix ->
             if String.starts_with?(model_id, prefix),
               do: {prefix, String.replace_prefix(model_id, prefix, "")}
           end) do
        nil -> {model_id, nil}
        {prefix, base_id} -> {base_id, prefix}
      end
    else
      {model_id, nil}
    end
  end

  defp resolve_model(provider, model_id) do
    case Store.snapshot() do
      nil ->
        {:error, :not_found}

      snapshot ->
        {lookup_id, prefix} = lookup_id_and_prefix(provider, model_id)

        key = {provider, lookup_id}
        canonical_base_id = Map.get(snapshot.aliases_by_key, key, lookup_id)
        canonical_key = {provider, canonical_base_id}

        case Map.get(snapshot.models_by_key, canonical_key) do
          nil ->
            {:error, :not_found}

          model ->
            returned_id =
              case prefix do
                nil -> canonical_base_id
                p -> p <> canonical_base_id
              end

            {:ok, {provider, returned_id, model}}
        end
    end
  end

  defp resolve_bare_model(model_id) do
    case Store.snapshot() do
      nil ->
        {:error, :not_found}

      snapshot ->
        matches = find_all_matches(snapshot, model_id)

        case matches do
          [] -> {:error, :not_found}
          [{provider, canonical_id, model}] -> {:ok, {provider, canonical_id, model}}
          [_ | _] -> {:error, :ambiguous}
        end
    end
  end

  defp find_all_matches(snapshot, model_id) do
    providers = Map.keys(snapshot.providers_by_id)

    Enum.flat_map(providers, fn provider ->
      {lookup_id, prefix} = lookup_id_and_prefix(provider, model_id)

      key = {provider, lookup_id}
      canonical_base_id = Map.get(snapshot.aliases_by_key, key, lookup_id)
      canonical_key = {provider, canonical_base_id}

      case Map.get(snapshot.models_by_key, canonical_key) do
        nil ->
          []

        model ->
          returned_id =
            case prefix do
              nil -> canonical_base_id
              p -> p <> canonical_base_id
            end

          [{provider, returned_id, model}]
      end
    end)
  end
end
