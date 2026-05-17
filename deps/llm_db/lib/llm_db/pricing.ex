defmodule LLMDB.Pricing do
  @moduledoc """
  Pricing pipeline for converting legacy cost data and applying provider defaults.

  This module handles two key transformations during snapshot loading:

  1. **Legacy cost conversion** - Converts the simple `cost` map (input/output/cache rates)
     into the flexible `pricing.components` format for backward compatibility.

  2. **Provider defaults** - Merges provider-level pricing defaults (e.g., tool pricing)
     into each model's pricing, respecting merge strategies.

  ## Pipeline

  The pricing transformations run during `LLMDB.Loader.load/1`:

      models
      |> Pricing.apply_cost_components()      # Convert cost -> pricing.components
      |> Pricing.apply_provider_defaults()    # Merge provider defaults

  ## Pricing Structure

  The `pricing` field on models contains:

      %{
        currency: "USD",
        merge: "merge_by_id",  # or "replace"
        components: [
          %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 3.0},
          %{id: "tool.web_search", kind: "tool", tool: "web_search", unit: "call", per: 1000, rate: 10.0}
        ]
      }

  See the [Pricing and Billing guide](pricing-and-billing.md) for full documentation.
  """

  alias LLMDB.Merge

  @doc """
  Converts legacy `cost` fields to `pricing.components` format.

  For each model with a `cost` map, generates corresponding pricing components:

  | Cost Field | Component ID |
  |------------|--------------|
  | `input` | `token.input` |
  | `output` | `token.output` |
  | `cache_read` | `token.cache_read` |
  | `cache_write` | `token.cache_write` |
  | `reasoning` | `token.reasoning` |

  Existing `pricing.components` are preserved and take precedence over
  generated components (merged by ID).

  ## Examples

      iex> models = [%{id: "gpt-4", provider: :openai, cost: %{input: 3.0, output: 15.0}}]
      iex> [model] = LLMDB.Pricing.apply_cost_components(models)
      iex> model.pricing.components
      [
        %{id: "token.input", kind: "token", unit: "token", per: 1_000_000, rate: 3.0},
        %{id: "token.output", kind: "token", unit: "token", per: 1_000_000, rate: 15.0}
      ]
  """
  @spec apply_cost_components([LLMDB.Model.t()]) :: [LLMDB.Model.t()]
  def apply_cost_components(models) when is_list(models) do
    Enum.map(models, &apply_cost_components_to_model/1)
  end

  @doc """
  Applies provider-level pricing defaults to models.

  For each model, looks up its provider's `pricing_defaults` and merges them
  into the model's `pricing` field. The merge behavior depends on the model's
  `pricing.merge` setting:

  - `"merge_by_id"` (default) - Provider defaults are merged with model components
    by ID. Model components override matching defaults.
  - `"replace"` - Model pricing completely replaces provider defaults.

  Models without existing `pricing` inherit the full provider defaults.

  ## Examples

      iex> providers = [%{id: :openai, pricing_defaults: %{
      ...>   currency: "USD",
      ...>   components: [%{id: "tool.web_search", kind: "tool", rate: 10.0}]
      ...> }}]
      iex> models = [%{id: "gpt-4", provider: :openai, pricing: nil}]
      iex> [model] = LLMDB.Pricing.apply_provider_defaults(providers, models)
      iex> model.pricing.components
      [%{id: "tool.web_search", kind: "tool", rate: 10.0}]
  """
  @spec apply_provider_defaults([LLMDB.Provider.t()], [LLMDB.Model.t()]) :: [LLMDB.Model.t()]
  def apply_provider_defaults(providers, models) when is_list(providers) and is_list(models) do
    defaults_by_provider =
      Map.new(providers, fn provider ->
        {provider.id, Map.get(provider, :pricing_defaults)}
      end)

    Enum.map(models, fn model ->
      case Map.get(defaults_by_provider, model.provider) do
        nil -> model
        defaults -> apply_defaults_to_model(model, defaults)
      end
    end)
  end

  defp apply_defaults_to_model(model, defaults) do
    case Map.get(model, :pricing) do
      nil -> Map.put(model, :pricing, defaults)
      pricing -> Map.put(model, :pricing, merge_pricing(defaults, pricing))
    end
  end

  defp apply_cost_components_to_model(model) do
    cost = Map.get(model, :cost) || Map.get(model, "cost")

    if is_map(cost) and map_size(cost) > 0 do
      pricing = Map.get(model, :pricing) || Map.get(model, "pricing") || %{}
      existing_components = components_list(pricing)
      cost_components = cost_components(cost)
      merged_components = Merge.merge_list_by_id(cost_components, existing_components)

      currency =
        Map.get(pricing, :currency) || Map.get(pricing, "currency") || "USD"

      updated_pricing =
        pricing
        |> Map.put(:currency, currency)
        |> Map.put(:components, merged_components)

      Map.put(model, :pricing, updated_pricing)
    else
      model
    end
  end

  defp merge_pricing(defaults, pricing) do
    case merge_mode(pricing) do
      "replace" -> pricing
      _ -> merge_by_id(defaults, pricing)
    end
  end

  defp merge_mode(pricing) do
    mode = Map.get(pricing, :merge) || Map.get(pricing, "merge")

    case mode do
      :replace -> "replace"
      "replace" -> "replace"
      :merge_by_id -> "merge_by_id"
      "merge_by_id" -> "merge_by_id"
      _ -> "merge_by_id"
    end
  end

  defp merge_by_id(defaults, pricing) do
    currency =
      Map.get(pricing, :currency) ||
        Map.get(pricing, "currency") ||
        Map.get(defaults, :currency) ||
        Map.get(defaults, "currency")

    default_components = components_list(defaults)
    pricing_components = components_list(pricing)
    merged_components = Merge.merge_list_by_id(default_components, pricing_components)

    pricing
    |> Map.put(:currency, currency)
    |> Map.put(:components, merged_components)
  end

  defp components_list(pricing) do
    Map.get(pricing, :components) || Map.get(pricing, "components") || []
  end

  defp cost_components(cost) when is_map(cost) do
    []
    |> maybe_add_token_component("token.input", Map.get(cost, :input) || Map.get(cost, "input"))
    |> maybe_add_token_component(
      "token.output",
      Map.get(cost, :output) || Map.get(cost, "output")
    )
    |> maybe_add_token_component(
      "token.cache_read",
      Map.get(cost, :cache_read) || Map.get(cost, "cache_read") ||
        Map.get(cost, :cached_input) || Map.get(cost, "cached_input")
    )
    |> maybe_add_token_component(
      "token.cache_write",
      Map.get(cost, :cache_write) || Map.get(cost, "cache_write")
    )
    |> maybe_add_token_component(
      "token.reasoning",
      Map.get(cost, :reasoning) || Map.get(cost, "reasoning")
    )
  end

  defp maybe_add_token_component(components, _id, nil), do: components

  defp maybe_add_token_component(components, id, rate) when is_number(rate) do
    components ++ [%{id: id, kind: "token", unit: "token", per: 1_000_000, rate: rate}]
  end

  defp maybe_add_token_component(components, _id, _rate), do: components
end
