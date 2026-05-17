defmodule LLMDB.Enrich do
  @moduledoc """
  Lightweight, deterministic enrichment of model data.

  This module performs simple derivations and defaults, such as:
  - Deriving model family from model ID
  - Setting provider_model_id to id if not present
  - Attaching optional llmfit sidecar metadata for matching Hugging Face models
  - Ensuring capability defaults are applied (handled by Zoi schemas)
  """

  alias LLMDB.Sources.Llmfit

  @doc """
  Derives the family name from a model ID using prefix logic.

  Extracts family from model ID by splitting on "-" and taking all but the last segment.
  Returns nil if the family cannot be reasonably derived.

  ## Examples

      iex> LLMDB.Enrich.derive_family("gpt-4o-mini")
      "gpt-4o"

      iex> LLMDB.Enrich.derive_family("claude-3-opus")
      "claude-3"

      iex> LLMDB.Enrich.derive_family("gemini-1.5-pro")
      "gemini-1.5"

      iex> LLMDB.Enrich.derive_family("single")
      nil

      iex> LLMDB.Enrich.derive_family("two-parts")
      "two"
  """
  @spec derive_family(String.t()) :: String.t() | nil
  def derive_family(model_id) when is_binary(model_id) do
    parts = String.split(model_id, "-")

    case parts do
      [_single] ->
        nil

      parts when length(parts) >= 2 ->
        parts
        |> Enum.slice(0..-2//1)
        |> Enum.join("-")
    end
  end

  @doc """
  Enriches a single model map with derived and default values.

  Sets the following fields if not already present:
  - `family`: Derived from model ID
  - `provider_model_id`: Set to model ID

  Note: Capability defaults are handled automatically by Zoi schema validation.

  ## Examples

      iex> LLMDB.Enrich.enrich_model(%{id: "gpt-4o-mini", provider: :openai})
      %{id: "gpt-4o-mini", provider: :openai, family: "gpt-4o", provider_model_id: "gpt-4o-mini"}

      iex> LLMDB.Enrich.enrich_model(%{id: "claude-3-opus", provider: :anthropic, family: "claude-3-custom"})
      %{id: "claude-3-opus", provider: :anthropic, family: "claude-3-custom", provider_model_id: "claude-3-opus"}

      iex> LLMDB.Enrich.enrich_model(%{id: "model", provider: :openai, provider_model_id: "custom-id"})
      %{id: "model", provider: :openai, provider_model_id: "custom-id"}
  """
  @spec enrich_model(map()) :: map()
  def enrich_model(model) when is_map(model) do
    model
    |> maybe_set_family()
    |> maybe_set_provider_model_id()
  end

  @doc """
  Enriches a list of model maps.

  Applies `enrich_model/1` to each model in the list.

  ## Examples

      iex> LLMDB.Enrich.enrich_models([
      ...>   %{id: "gpt-4o", provider: :openai},
      ...>   %{id: "claude-3-opus", provider: :anthropic}
      ...> ])
      [
        %{id: "gpt-4o", provider: :openai, family: "gpt", provider_model_id: "gpt-4o"},
        %{id: "claude-3-opus", provider: :anthropic, family: "claude-3", provider_model_id: "claude-3-opus"}
      ]
  """
  @spec enrich_models([map()]) :: [map()]
  def enrich_models(models) when is_list(models) do
    models
    |> Enum.map(&enrich_model/1)
    |> inherit_canonical_costs()
    |> enrich_llmfit_metadata()
    |> LLMDB.Enrich.AzureWireProtocol.enrich_models()
  end

  @date_suffix ~r/-\d{4}-\d{2}-\d{2}$/

  @doc """
  Propagates cost from canonical models to their dated variants.

  For models with a date suffix (e.g., `gpt-4o-mini-2024-07-18`), if the model
  has no cost, looks up the canonical model (e.g., `gpt-4o-mini`) from the same
  provider and copies its cost.

  Models that already have a cost are left unchanged.

  ## Examples

      iex> models = [
      ...>   %{id: "gpt-4o-mini", provider: :openai, cost: %{input: 0.15, output: 0.6}},
      ...>   %{id: "gpt-4o-mini-2024-07-18", provider: :openai}
      ...> ]
      iex> [_, dated] = LLMDB.Enrich.inherit_canonical_costs(models)
      iex> dated.cost
      %{input: 0.15, output: 0.6}
  """
  @spec inherit_canonical_costs([map()]) :: [map()]
  def inherit_canonical_costs(models) when is_list(models) do
    canonicals_with_cost =
      models
      |> Enum.reject(&dated_model?/1)
      |> Enum.filter(&has_cost?/1)
      |> Map.new(&{{&1.provider, &1.id}, &1.cost})

    Enum.map(models, fn model ->
      if dated_model?(model) and not has_cost?(model) do
        canonical_id = Regex.replace(@date_suffix, model.id, "")

        case Map.get(canonicals_with_cost, {model.provider, canonical_id}) do
          nil -> model
          cost -> Map.put(model, :cost, cost)
        end
      else
        model
      end
    end)
  end

  defp dated_model?(%{id: id}), do: Regex.match?(@date_suffix, id)

  defp has_cost?(%{cost: cost}) when is_map(cost) and map_size(cost) > 0, do: true
  defp has_cost?(_), do: false

  defp enrich_llmfit_metadata(models) do
    if Application.get_env(:llm_db, :llmfit_enrichment, true) do
      case Llmfit.load_index(%{}) do
        {:ok, index} when map_size(index) > 0 ->
          Enum.map(models, &merge_llmfit_metadata(&1, index))

        _ ->
          models
      end
    else
      models
    end
  end

  defp merge_llmfit_metadata(model, llmfit_index) do
    with repo_id when is_binary(repo_id) <- find_hf_repo_id(model),
         llmfit_metadata when is_map(llmfit_metadata) <- Map.get(llmfit_index, repo_id) do
      model
      |> put_llmfit_extra(llmfit_metadata, repo_id)
      |> maybe_set_context_limit(Map.get(llmfit_metadata, :context_length))
      |> maybe_set_release_date(Map.get(llmfit_metadata, :release_date))
    else
      _ -> model
    end
  end

  defp put_llmfit_extra(model, llmfit_metadata, repo_id) do
    extra =
      model
      |> Map.get(:extra, %{})
      |> normalize_extra_map()
      |> Map.put(:llmfit, Map.put(llmfit_metadata, :matched_hugging_face_id, repo_id))

    Map.put(model, :extra, extra)
  end

  defp normalize_extra_map(extra) when is_map(extra), do: extra
  defp normalize_extra_map(_), do: %{}

  defp maybe_set_context_limit(model, context_length)
       when is_integer(context_length) and context_length > 0 do
    limits = Map.get(model, :limits)

    cond do
      is_map(limits) and not is_nil(Map.get(limits, :context)) ->
        model

      is_map(limits) ->
        Map.put(model, :limits, Map.put(limits, :context, context_length))

      true ->
        Map.put(model, :limits, %{context: context_length})
    end
  end

  defp maybe_set_context_limit(model, _), do: model

  defp maybe_set_release_date(%{release_date: release_date} = model, incoming)
       when is_binary(release_date) and byte_size(release_date) > 0 and is_binary(incoming),
       do: model

  defp maybe_set_release_date(model, incoming)
       when is_binary(incoming) and byte_size(incoming) > 0,
       do: Map.put(model, :release_date, incoming)

  defp maybe_set_release_date(model, _), do: model

  defp find_hf_repo_id(model) do
    from_extra =
      model
      |> Map.get(:extra, %{})
      |> case do
        extra when is_map(extra) ->
          Map.get(extra, :hugging_face_id) || Map.get(extra, "hugging_face_id")

        _ ->
          nil
      end

    cond do
      is_binary(from_extra) and byte_size(from_extra) > 0 ->
        from_extra

      is_binary(model_id = Map.get(model, :id)) and String.contains?(model_id, "/") ->
        model_id

      true ->
        nil
    end
  end

  # Private helpers

  defp maybe_set_family(%{family: _} = model), do: model

  defp maybe_set_family(%{id: id} = model) do
    case derive_family(id) do
      nil -> model
      family -> Map.put(model, :family, family)
    end
  end

  defp maybe_set_provider_model_id(%{provider_model_id: _} = model), do: model

  defp maybe_set_provider_model_id(%{id: id} = model) do
    Map.put(model, :provider_model_id, id)
  end
end
