defmodule LLMDB.Source do
  @moduledoc """
  Unified data source interface for LLMDB.

  Sources return providers and models data in **canonical Zoi format**.
  No filtering, no excludes. Validation happens later via Engine pipeline.

  ## Output Format: Canonical Zoi v1

  All sources MUST return data matching our canonical Zoi schema format.
  External formats (e.g., models.dev) must be transformed to canonical format
  before returning from `load/1`.

  ## Type Specifications

  - `provider_id` - Atom or string identifying a provider (e.g., `:openai`, `"anthropic"`)
  - `model_id` - String identifying a model (e.g., `"gpt-4o"`)
  - `provider_map` - Provider data map with atom keys matching Zoi Provider schema
  - `model_map` - Model data map with atom keys matching Zoi Model schema
  - `data` - Source output with providers map, each containing models list

  ## Contract: Canonical Format Required

  All source implementations must return `{:ok, data}` where data is:

      %{
        "openai" => %{
          id: :openai,                    # REQUIRED: atom or string
          name: "OpenAI",                 # Optional
          base_url: "...",                # Optional
          env: ["OPENAI_API_KEY"],        # Optional
          doc: "...",                     # Optional
          models: [                       # REQUIRED: list
            %{
              id: "gpt-4o",               # REQUIRED: string
              provider: :openai,          # REQUIRED: atom
              name: "GPT-4o",             # Optional
              limits: %{                  # Optional: Zoi Limits schema
                context: 128000,
                output: 16384
              },
              cost: %{                    # Optional: Zoi Cost schema
                input: 2.50,
                output: 10.00,
                cache_read: 1.25
              },
              capabilities: %{            # Optional: Zoi Capabilities schema
                streaming: %{text: true},
                tools: %{enabled: true}
              },
              modalities: %{              # Optional
                input: [:text, :image],
                output: [:text]
              },
              ...                         # Other Zoi Model schema fields
            }
          ]
        },
        ...
      }

  **Key requirements:**
  - Outer keys: strings (provider IDs as strings)
  - Provider maps: atom keys, MUST include `:id` (atom/string) and `:models` (list)
  - Model maps: atom keys matching Zoi Model schema

  Return `{:error, reason}` only if the source cannot produce any data.

  For partial failures (e.g., one file fails in multi-file source), handle
  internally, log warnings, and return available data.

  ## Format Transformation

  Sources that read external formats (e.g., models.dev JSON) should implement
  a public `transform/1` function to make the transformation explicit.
  Call this from `load/1` before returning.

  Example:

      def load(opts) do
        case read_external_data(opts) do
          {:ok, external_data} ->
            {:ok, transform(external_data)}
          error ->
            error
        end
      end

      def transform(external_data) do
        # Transform external format → canonical Zoi format
        ...
      end

  ## Testability

  Sources should accept optional test hooks via `opts` parameter:
  - `:file_reader` - Function for reading files (default: `File.read!/1`)
  - `:dir_reader` - Function for listing directories (default: `File.ls!/1`)

  This allows tests to inject stubs without filesystem access.
  """

  @type provider_id :: atom() | String.t()
  @type model_id :: String.t()
  @type provider_map :: map()
  @type model_map :: map()
  @type data :: %{required(String.t()) => provider_map}
  @type opts :: map()
  @type pull_result :: :noop | {:ok, String.t()} | {:error, term()}

  @doc """
  Load data from this source.

  For remote sources, this should read from locally cached data (no network calls).
  Run `mix llm_db.pull` to fetch and cache remote data first.

  ## Parameters

  - `opts` - Source-specific options map

  ## Returns

  - `{:ok, data}` - Success with providers/models data
  - `{:error, term}` - Fatal error (source cannot produce any data)
  """
  @callback load(opts) :: {:ok, data} | {:error, term()}

  @doc """
  Pull remote data and cache it locally.

  This callback is optional and only implemented by sources that fetch remote data.
  When implemented, it should:
  - Fetch data from a remote endpoint (e.g., via Req)
  - Cache the data locally in `priv/llm_db/remote/`
  - Write a manifest file with metadata (URL, checksum, timestamp)
  - Support conditional GET using ETag/Last-Modified headers

  ## Parameters

  - `opts` - Source-specific options map (may include `:url`, `:cache_id`, etc.)

  ## Returns

  - `:noop` - Data not modified (HTTP 304)
  - `{:ok, cache_path}` - Successfully cached to the given path
  - `{:error, term}` - Failed to fetch or cache
  """
  @callback pull(opts) :: pull_result

  @optional_callbacks pull: 1

  @doc """
  Validates that source data matches the canonical Zoi format.

  This is a lightweight shape assertion to fail fast if a source
  forgets to transform external data. Full schema validation happens
  later in the Engine pipeline.

  ## Checks

  - Outer structure is a map
  - Keys are strings (provider IDs)
  - Values are provider maps with atom keys
  - Provider maps have required :id and :models fields
  - :models is a list

  ## Examples

      iex> data = %{"openai" => %{id: :openai, models: []}}
      iex> Source.assert_canonical!(data)
      :ok

      iex> bad_data = %{"openai" => %{"id" => "openai"}}
      iex> Source.assert_canonical!(bad_data)
      ** (ArgumentError) Source.load/1 must return canonical Zoi format
  """
  @spec assert_canonical!(data) :: :ok
  def assert_canonical!(data) when is_map(data) do
    valid? =
      Enum.all?(data, fn
        {key, provider_map} when is_binary(key) and is_map(provider_map) ->
          # Provider map must have atom keys with at least :id and :models
          has_atom_keys = Map.has_key?(provider_map, :id)
          has_models_list = is_list(Map.get(provider_map, :models, nil))
          has_atom_keys and has_models_list

        _ ->
          false
      end)

    if valid? do
      :ok
    else
      raise ArgumentError, """
      Source.load/1 must return canonical Zoi format.

      Expected:
        - Outer map with string keys (provider IDs)
        - Provider maps with atom keys
        - Required fields: :id (atom/string), :models (list)

      See LLMDB.Source moduledoc for format specification.
      """
    end
  end

  def assert_canonical!(data) do
    raise ArgumentError,
          "Source.load/1 must return a map, got: #{inspect(data)}"
  end
end
