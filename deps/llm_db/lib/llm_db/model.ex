defmodule LLMDB.Model do
  @moduledoc """
  Model struct with Zoi schema validation.

  Represents an LLM model with complete metadata including identity, provider,
  dates, limits, costs, pricing, modalities, capabilities, tags, lifecycle status, and aliases.

  ## Lifecycle

  Models have a lifecycle with three possible states: `"active"`, `"deprecated"`, and `"retired"`.

  The lifecycle is represented in two ways for flexibility and backward compatibility:

  - `:deprecated` and `:retired` - Boolean flags for quick checks
  - `:lifecycle` - Structured map with status, dates, and replacement info

  These are automatically synchronized:
  - If `lifecycle.status` is set, the boolean flags are derived from it
  - If only boolean flags are set, `lifecycle.status` is derived from them

  ### Lifecycle Fields

  - `lifecycle.status` - One of `"active"`, `"deprecated"`, `"retired"`
  - `lifecycle.deprecated_at` - ISO8601 date when deprecation occurred/will occur
  - `lifecycle.retires_at` - ISO8601 date when retirement is planned
  - `lifecycle.replacement` - Suggested replacement model ID

  ### Temporal Lifecycle

  Use `effective_status/2`, `deprecated?/2`, and `retired?/2` to get status
  that respects `deprecated_at` and `retires_at` dates:

      model = LLMDB.Model.new!(%{
        id: "old-model",
        provider: :openai,
        lifecycle: %{status: "active", deprecated_at: "2025-01-01", retires_at: "2025-06-01"}
      })

      LLMDB.Model.effective_status(model, ~U[2025-03-01 00:00:00Z])
      # => "deprecated"

      LLMDB.Model.retired?(model, ~U[2025-07-01 00:00:00Z])
      # => true

  ## Pricing Fields

  Models have two pricing-related fields:

  - `:cost` - Legacy simple pricing (per-million-token rates for input/output/cache/reasoning)
  - `:pricing` - Flexible component-based pricing with support for tokens, tools, images, storage

  The `:cost` field is automatically converted to `:pricing.components` at load time
  for backward compatibility. See `LLMDB.Pricing` and the [Pricing and Billing guide](pricing-and-billing.md).
  """

  @limits_schema Zoi.object(%{
                   context: Zoi.integer() |> Zoi.min(1) |> Zoi.nullish(),
                   output: Zoi.integer() |> Zoi.min(1) |> Zoi.nullish()
                 })

  @cost_schema Zoi.object(%{
                 input: Zoi.number() |> Zoi.nullish(),
                 output: Zoi.number() |> Zoi.nullish(),
                 request: Zoi.number() |> Zoi.nullish(),
                 cache_read: Zoi.number() |> Zoi.nullish(),
                 cache_write: Zoi.number() |> Zoi.nullish(),
                 training: Zoi.number() |> Zoi.nullish(),
                 reasoning: Zoi.number() |> Zoi.nullish(),
                 image: Zoi.number() |> Zoi.nullish(),
                 audio: Zoi.number() |> Zoi.nullish(),
                 input_audio: Zoi.number() |> Zoi.nullish(),
                 output_audio: Zoi.number() |> Zoi.nullish(),
                 input_video: Zoi.number() |> Zoi.nullish(),
                 output_video: Zoi.number() |> Zoi.nullish()
               })

  @pricing_component_schema Zoi.object(%{
                              id: Zoi.string(),
                              kind:
                                Zoi.enum([
                                  "token",
                                  "tool",
                                  "image",
                                  "storage",
                                  "request",
                                  "other"
                                ])
                                |> Zoi.nullish(),
                              unit:
                                Zoi.enum([
                                  "token",
                                  "call",
                                  "query",
                                  "session",
                                  "gb_day",
                                  "image",
                                  "source",
                                  "other"
                                ])
                                |> Zoi.nullish(),
                              per: Zoi.integer() |> Zoi.min(1) |> Zoi.nullish(),
                              rate: Zoi.number() |> Zoi.nullish(),
                              meter: Zoi.string() |> Zoi.nullish(),
                              tool: Zoi.union([Zoi.atom(), Zoi.string()]) |> Zoi.nullish(),
                              size_class: Zoi.string() |> Zoi.nullish(),
                              notes: Zoi.string() |> Zoi.nullish()
                            })

  @pricing_schema Zoi.object(%{
                    currency: Zoi.string() |> Zoi.nullish(),
                    components: Zoi.array(@pricing_component_schema) |> Zoi.default([]),
                    merge: Zoi.enum(["replace", "merge_by_id"]) |> Zoi.default("merge_by_id")
                  })

  @reasoning_schema Zoi.object(%{
                      enabled: Zoi.boolean() |> Zoi.nullish(),
                      token_budget: Zoi.integer() |> Zoi.min(0) |> Zoi.nullish()
                    })

  @tools_schema Zoi.object(%{
                  enabled: Zoi.boolean() |> Zoi.nullish(),
                  streaming: Zoi.boolean() |> Zoi.nullish(),
                  strict: Zoi.boolean() |> Zoi.nullish(),
                  parallel: Zoi.boolean() |> Zoi.nullish(),
                  forced_choice: Zoi.boolean() |> Zoi.nullish()
                })

  @json_schema Zoi.object(%{
                 native: Zoi.boolean() |> Zoi.nullish(),
                 schema: Zoi.boolean() |> Zoi.nullish(),
                 strict: Zoi.boolean() |> Zoi.nullish()
               })

  @caching_schema Zoi.object(%{
                    type: Zoi.enum(["implicit", "explicit"]) |> Zoi.nullish()
                  })

  @streaming_schema Zoi.object(%{
                      text: Zoi.boolean() |> Zoi.nullish(),
                      tool_calls: Zoi.boolean() |> Zoi.nullish()
                    })

  @lifecycle_schema Zoi.object(%{
                      status: Zoi.enum(["active", "deprecated", "retired"]) |> Zoi.nullish(),
                      deprecated_at: Zoi.string() |> Zoi.nullish(),
                      retires_at: Zoi.string() |> Zoi.nullish(),
                      replacement: Zoi.string() |> Zoi.nullish()
                    })

  @embeddings_schema Zoi.object(%{
                       min_dimensions: Zoi.integer() |> Zoi.min(1) |> Zoi.nullish(),
                       max_dimensions: Zoi.integer() |> Zoi.min(1) |> Zoi.nullish(),
                       default_dimensions: Zoi.integer() |> Zoi.min(1) |> Zoi.nullish()
                     })

  @execution_operation_schema Zoi.object(%{
                                supported: Zoi.boolean() |> Zoi.default(false),
                                family: Zoi.string() |> Zoi.nullish(),
                                wire_protocol: Zoi.string() |> Zoi.nullish(),
                                transport: Zoi.string() |> Zoi.nullish(),
                                provider_model_id: Zoi.string() |> Zoi.nullish(),
                                base_url: Zoi.string() |> Zoi.nullish(),
                                path: Zoi.string() |> Zoi.nullish()
                              })

  @execution_schema Zoi.object(%{
                      text: @execution_operation_schema |> Zoi.nullish(),
                      object: @execution_operation_schema |> Zoi.nullish(),
                      embed: @execution_operation_schema |> Zoi.nullish(),
                      image: @execution_operation_schema |> Zoi.nullish(),
                      transcription: @execution_operation_schema |> Zoi.nullish(),
                      speech: @execution_operation_schema |> Zoi.nullish(),
                      realtime: @execution_operation_schema |> Zoi.nullish()
                    })

  @capabilities_schema Zoi.object(%{
                         chat: Zoi.boolean() |> Zoi.default(true),
                         embeddings:
                           Zoi.union([Zoi.boolean(), @embeddings_schema]) |> Zoi.default(false),
                         reasoning: @reasoning_schema |> Zoi.default(%{enabled: false}),
                         rerank: Zoi.boolean() |> Zoi.default(false),
                         tools:
                           @tools_schema
                           |> Zoi.default(%{
                             enabled: false,
                             streaming: false,
                             strict: false,
                             parallel: false
                           }),
                         json:
                           @json_schema
                           |> Zoi.default(%{native: false, schema: false, strict: false}),
                         caching: @caching_schema |> Zoi.nullish(),
                         streaming:
                           @streaming_schema |> Zoi.default(%{text: true, tool_calls: false})
                       })

  @derive {Jason.Encoder,
           only: [
             :id,
             :model,
             :provider,
             :provider_model_id,
             :name,
             :family,
             :doc_url,
             :release_date,
             :last_updated,
             :knowledge,
             :base_url,
             :limits,
             :cost,
             :pricing,
             :modalities,
             :capabilities,
             :tags,
             :deprecated,
             :retired,
             :lifecycle,
             :execution,
             :catalog_only,
             :aliases,
             :extra
           ]}

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              model: Zoi.string() |> Zoi.nullish(),
              provider: Zoi.atom(),
              provider_model_id: Zoi.string() |> Zoi.nullish(),
              name: Zoi.string() |> Zoi.nullish(),
              family: Zoi.string() |> Zoi.nullish(),
              doc_url: Zoi.string() |> Zoi.nullish(),
              release_date: Zoi.string() |> Zoi.nullish(),
              last_updated: Zoi.string() |> Zoi.nullish(),
              knowledge: Zoi.string() |> Zoi.nullish(),
              base_url: Zoi.string() |> Zoi.nullish(),
              limits: @limits_schema |> Zoi.nullish(),
              cost: @cost_schema |> Zoi.nullish(),
              pricing: @pricing_schema |> Zoi.nullish(),
              modalities:
                Zoi.object(%{
                  input: Zoi.array(Zoi.atom()) |> Zoi.nullish(),
                  output: Zoi.array(Zoi.atom()) |> Zoi.nullish()
                })
                |> Zoi.nullish(),
              capabilities: @capabilities_schema |> Zoi.nullish(),
              tags: Zoi.array(Zoi.string()) |> Zoi.nullish(),
              deprecated: Zoi.boolean() |> Zoi.default(false),
              retired: Zoi.boolean() |> Zoi.default(false),
              lifecycle: @lifecycle_schema |> Zoi.nullish(),
              execution: @execution_schema |> Zoi.nullish(),
              catalog_only: Zoi.boolean() |> Zoi.default(false),
              aliases: Zoi.array(Zoi.string()) |> Zoi.default([]),
              extra: Zoi.map() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Model"
  def schema, do: @schema

  @doc """
  Creates a new Model struct from a map, validating with Zoi schema.

  ## Examples

      iex> LLMDB.Model.new(%{id: "gpt-4", provider: :openai})
      {:ok, %LLMDB.Model{id: "gpt-4", model: "gpt-4", provider: :openai}}

      iex> LLMDB.Model.new(%{})
      {:error, _validation_errors}
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> sync_id_model_fields()
      |> normalize_execution_attrs()

    Zoi.parse(@schema, attrs)
  end

  @doc """
  Creates a new Model struct from a map, raising on validation errors.

  ## Examples

      iex> LLMDB.Model.new!(%{id: "gpt-4", provider: :openai})
      %LLMDB.Model{id: "gpt-4", model: "gpt-4", provider: :openai}
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, model} -> model
      {:error, reason} -> raise ArgumentError, "Invalid model: #{inspect(reason)}"
    end
  end

  defp sync_id_model_fields(attrs) do
    id_value = get_field_value(attrs, :id)
    model_value = get_field_value(attrs, :model)

    cond do
      is_binary(id_value) and is_binary(model_value) and id_value != model_value ->
        attrs |> put_field(:id, id_value) |> put_field(:model, id_value)

      is_binary(id_value) and is_nil(model_value) ->
        put_field(attrs, :model, id_value)

      is_binary(model_value) and is_nil(id_value) ->
        attrs |> put_field(:id, model_value) |> put_field(:model, model_value)

      true ->
        attrs
    end
  end

  defp get_field_value(attrs, key) do
    value = attrs[key] || attrs[to_string(key)]

    case value do
      "" -> nil
      val -> val
    end
  end

  defp put_field(attrs, key, value) do
    attrs
    |> Map.put(key, value)
    |> Map.put(to_string(key), value)
  end

  defp normalize_execution_attrs(attrs) do
    update_in_nested_map(attrs, :execution, fn execution ->
      Enum.reduce(
        [:text, :object, :embed, :image, :transcription, :speech, :realtime],
        execution,
        fn key, acc ->
          update_in_nested_map(acc, key, fn operation ->
            operation
            |> normalize_string_field(:family)
            |> normalize_string_field(:wire_protocol)
            |> normalize_string_field(:transport)
          end)
        end
      )
    end)
  end

  defp update_in_nested_map(attrs, key, fun) when is_map(attrs) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      nested when is_map(nested) ->
        normalized = fun.(nested)

        attrs
        |> Map.put(key, normalized)
        |> Map.put(to_string(key), normalized)

      _other ->
        attrs
    end
  end

  defp normalize_string_field(map, key) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, to_string(key))

    normalized =
      case value do
        atom when is_atom(atom) -> Atom.to_string(atom)
        other -> other
      end

    map
    |> Map.put(key, normalized)
    |> Map.put(to_string(key), normalized)
  end

  @doc """
  Returns the declared lifecycle status from the model's lifecycle field.

  ## Examples

      iex> model = %LLMDB.Model{id: "gpt-4", provider: :openai, lifecycle: %{status: "deprecated"}}
      iex> LLMDB.Model.lifecycle_status(model)
      "deprecated"

      iex> model = %LLMDB.Model{id: "gpt-4", provider: :openai}
      iex> LLMDB.Model.lifecycle_status(model)
      nil
  """
  @spec lifecycle_status(t()) :: String.t() | nil
  def lifecycle_status(%__MODULE__{lifecycle: %{status: status}}), do: status
  def lifecycle_status(_), do: nil

  @doc """
  Returns the effective lifecycle status, considering dates, declared status, and boolean flags.

  This function determines status using this precedence:
  1. Declared `lifecycle.status` (if it indicates an advanced stage)
  2. Date-based auto-advancement (`deprecated_at`, `retires_at`)
  3. Boolean flags (`retired`, `deprecated`) as fallback
  4. Default: `"active"`

  ## Examples

      iex> model = %LLMDB.Model{
      ...>   id: "gpt-4",
      ...>   provider: :openai,
      ...>   lifecycle: %{status: "active", deprecated_at: "2025-01-01T00:00:00Z"}
      ...> }
      iex> LLMDB.Model.effective_status(model, ~U[2025-06-01 00:00:00Z])
      "deprecated"
  """
  @spec effective_status(t(), DateTime.t()) :: String.t()
  def effective_status(model, now \\ DateTime.utc_now())

  def effective_status(%__MODULE__{} = model, %DateTime{} = now) do
    declared = lifecycle_status(model)
    lifecycle = model.lifecycle || %{}

    deprecated_at =
      parse_datetime(Map.get(lifecycle, :deprecated_at) || Map.get(lifecycle, "deprecated_at"))

    retires_at =
      parse_datetime(Map.get(lifecycle, :retires_at) || Map.get(lifecycle, "retires_at"))

    cond do
      declared == "retired" ->
        "retired"

      not is_nil(retires_at) and DateTime.compare(now, retires_at) != :lt ->
        "retired"

      declared == "deprecated" ->
        "deprecated"

      not is_nil(deprecated_at) and DateTime.compare(now, deprecated_at) != :lt ->
        "deprecated"

      model.retired ->
        "retired"

      model.deprecated ->
        "deprecated"

      true ->
        "active"
    end
  end

  @doc """
  Returns true if the model is deprecated or retired (effective status).

  Considers declared status, date-based lifecycle transitions, and boolean flags.

  ## Examples

      iex> model = %LLMDB.Model{id: "gpt-4", provider: :openai, deprecated: true}
      iex> LLMDB.Model.deprecated?(model)
      true
  """
  @spec deprecated?(t(), DateTime.t()) :: boolean()
  def deprecated?(model, now \\ DateTime.utc_now()) do
    effective_status(model, now) in ["deprecated", "retired"]
  end

  @doc """
  Returns true if the model is retired (effective status).

  Considers declared status, date-based lifecycle transitions, and boolean flags.

  ## Examples

      iex> model = %LLMDB.Model{id: "gpt-4", provider: :openai, retired: true}
      iex> LLMDB.Model.retired?(model)
      true
  """
  @spec retired?(t(), DateTime.t()) :: boolean()
  def retired?(model, now \\ DateTime.utc_now()) do
    effective_status(model, now) == "retired"
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        dt

      {:error, _} ->
        case Date.from_iso8601(str) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          {:error, _} -> nil
        end
    end
  end

  defp parse_datetime(_), do: nil

  @doc """
  Formats a model as a spec string in the given format.

  Delegates to `LLMDB.Spec.format_spec/2` with the model's provider and ID.
  If no format is specified, uses the application config `:llm_db, :model_spec_format`
  (default: `:provider_colon_model`).

  ## Parameters

  - `model` - The model struct
  - `format` - Optional format override (`:provider_colon_model`, `:model_at_provider`, `:filename_safe`)

  ## Examples

      iex> model = %LLMDB.Model{provider: :openai, id: "gpt-4"}
      iex> LLMDB.Model.spec(model)
      "openai:gpt-4"

      iex> LLMDB.Model.spec(model, :model_at_provider)
      "gpt-4@openai"

      iex> LLMDB.Model.spec(model, :filename_safe)
      "gpt-4@openai"
  """
  @spec spec(t()) :: String.t()
  @spec spec(t(), atom() | nil) :: String.t()
  def spec(%__MODULE__{provider: provider, id: id}, format \\ nil) do
    LLMDB.Spec.format_spec({provider, id}, format)
  end
end

defimpl DeepMerge.Resolver, for: LLMDB.Model do
  @moduledoc false

  def resolve(original, override = %LLMDB.Model{}, resolver) do
    cleaned_override =
      override
      |> Map.from_struct()
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Map.merge(original, cleaned_override, resolver)
  end

  def resolve(original, override, resolver) when is_map(override) do
    Map.merge(original, override, resolver)
  end

  def resolve(_original, override, _resolver), do: override
end
