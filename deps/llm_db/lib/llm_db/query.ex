defmodule LLMDB.Query do
  @moduledoc """
  Query functions for selecting models based on capabilities and requirements.

  Provides capability-based model selection with provider preferences.
  All queries operate on the filtered catalog loaded into the Store.
  """

  alias LLMDB.{Model, Spec, Store}

  @type provider :: atom()
  @type model_id :: String.t()
  @type model_spec :: {provider(), model_id()} | String.t() | Model.t()

  # Maps query capability keys to their paths in the Model.capabilities schema.
  # This map is the single source of truth for capability lookups, derived from
  # the capability schema in LLMDB.Model. Top-level capabilities like :chat and
  # :embeddings map to single-element paths, while nested capabilities like
  # :tools_streaming map to [:tools, :streaming].
  @capability_paths %{
    chat: [:chat],
    embeddings: [:embeddings],
    reasoning: [:reasoning, :enabled],
    rerank: [:rerank],
    tools: [:tools, :enabled],
    tools_streaming: [:tools, :streaming],
    tools_strict: [:tools, :strict],
    tools_parallel: [:tools, :parallel],
    json_native: [:json, :native],
    json_schema: [:json, :schema],
    json_strict: [:json, :strict],
    streaming_text: [:streaming, :text],
    streaming_tool_calls: [:streaming, :tool_calls]
  }

  @doc """
  Selects the first model matching capability requirements.

  Returns the first allowed model that matches the required capabilities,
  in provider preference order.

  ## Options

  - `:require` - Keyword list of required capabilities (e.g., `[tools: true, json_native: true]`)
  - `:forbid` - Keyword list of forbidden capabilities
  - `:prefer` - List of provider atoms in preference order (e.g., `[:openai, :anthropic]`)
  - `:scope` - Either `:all` (default) or a specific provider atom

  ## Returns

  - `{:ok, {provider, model_id}}` - First matching model
  - `{:error, :no_match}` - No models match the criteria

  ## Examples

      {:ok, {provider, model_id}} = Query.select(
        require: [chat: true, tools: true],
        prefer: [:openai, :anthropic]
      )

      {:ok, {:openai, model_id}} = Query.select(
        require: [json_native: true],
        scope: :openai
      )
  """
  @spec select(keyword()) :: {:ok, {provider(), model_id()}} | {:error, :no_match}
  def select(opts \\ []) do
    require_kw = Keyword.get(opts, :require, [])
    forbid_kw = Keyword.get(opts, :forbid, [])
    scope = Keyword.get(opts, :scope, :all)

    # Use snapshot.prefer as default if :prefer not explicitly provided
    prefer =
      case Keyword.fetch(opts, :prefer) do
        :error ->
          case Store.snapshot() do
            %{prefer: p} when is_list(p) -> p
            _ -> []
          end

        {:ok, p} ->
          p
      end

    providers = build_provider_list(scope, prefer)
    find_first_match(providers, require_kw, forbid_kw)
  end

  @doc """
  Gets all allowed models matching capability requirements.

  Returns all models that match the capability filters in preference order.
  Similar to `select/1` but returns all matches instead of just the first.

  ## Options

  - `:require` - Keyword list of required capabilities (e.g., `[tools: true, json_native: true]`)
  - `:forbid` - Keyword list of forbidden capabilities
  - `:prefer` - List of provider atoms in preference order (e.g., `[:openai, :anthropic]`)
  - `:scope` - Either `:all` (default) or a specific provider atom

  ## Returns

  List of `{provider, model_id}` tuples matching the criteria, in preference order.

  ## Examples

      candidates = Query.candidates(
        require: [chat: true, tools: true],
        prefer: [:openai, :anthropic]
      )
      #=> [{:openai, "gpt-4o"}, {:openai, "gpt-4o-mini"}, {:anthropic, "claude-3-5-sonnet-20241022"}, ...]

      candidates = Query.candidates(
        require: [json_native: true],
        scope: :openai
      )
      #=> [{:openai, "gpt-4o"}, {:openai, "gpt-4o-mini"}, ...]
  """
  @spec candidates(keyword()) :: [{provider(), model_id()}]
  def candidates(opts \\ []) do
    require_kw = Keyword.get(opts, :require, [])
    forbid_kw = Keyword.get(opts, :forbid, [])
    scope = Keyword.get(opts, :scope, :all)

    prefer =
      case Keyword.fetch(opts, :prefer) do
        :error ->
          case Store.snapshot() do
            %{prefer: p} when is_list(p) -> p
            _ -> []
          end

        {:ok, p} ->
          p
      end

    providers = build_provider_list(scope, prefer)
    find_all_matches(providers, require_kw, forbid_kw)
  end

  @doc """
  Gets capabilities for a model spec.

  Returns capabilities map or nil if model not found.

  ## Parameters

  - `spec` - Either `{provider, model_id}` tuple, `"provider:model"` string, or `%Model{}` struct

  ## Examples

      caps = Query.capabilities({:openai, "gpt-4o-mini"})
      #=> %{chat: true, tools: %{enabled: true, ...}, ...}

      caps = Query.capabilities("openai:gpt-4o-mini")
      #=> %{chat: true, tools: %{enabled: true, ...}, ...}

      {:ok, model} = LLMDB.model("openai:gpt-4o-mini")
      caps = Query.capabilities(model)
      #=> %{chat: true, tools: %{enabled: true, ...}, ...}
  """
  @spec capabilities(model_spec()) :: map() | nil
  def capabilities(%Model{capabilities: caps}), do: caps

  def capabilities({provider, model_id}) when is_atom(provider) and is_binary(model_id) do
    case Store.model(provider, model_id) do
      {:ok, m} -> Map.get(m, :capabilities)
      _ -> nil
    end
  end

  def capabilities(spec) when is_binary(spec) do
    case Spec.parse_spec(spec) do
      {:ok, {p, id}} -> capabilities({p, id})
      _ -> nil
    end
  end

  # Private helpers

  defp build_provider_list(:all, prefer) do
    all_providers = Store.providers() |> Enum.map(& &1.id)

    if prefer != [] do
      prefer ++ (all_providers -- prefer)
    else
      all_providers
    end
  end

  defp build_provider_list(provider, _prefer) when is_atom(provider) do
    [provider]
  end

  defp find_first_match([], _require_kw, _forbid_kw), do: {:error, :no_match}

  defp find_first_match([provider | rest], require_kw, forbid_kw) do
    models_list =
      Store.models(provider)
      |> Enum.filter(&matches_require?(&1, require_kw))
      |> Enum.reject(&matches_forbid?(&1, forbid_kw))

    case models_list do
      [] -> find_first_match(rest, require_kw, forbid_kw)
      [model | _] -> {:ok, {provider, model.id}}
    end
  end

  defp find_all_matches(providers, require_kw, forbid_kw) do
    Enum.flat_map(providers, fn provider ->
      Store.models(provider)
      |> Enum.filter(&matches_require?(&1, require_kw))
      |> Enum.reject(&matches_forbid?(&1, forbid_kw))
      |> Enum.map(&{provider, &1.id})
    end)
  end

  defp matches_require?(_model, []), do: true

  defp matches_require?(model, require_kw) do
    caps = Map.get(model, :capabilities) || %{}

    Enum.all?(require_kw, fn {key, value} ->
      check_capability(caps, key, value)
    end)
  end

  defp matches_forbid?(_model, []), do: false

  defp matches_forbid?(model, forbid_kw) do
    caps = Map.get(model, :capabilities) || %{}

    Enum.any?(forbid_kw, fn {key, value} ->
      check_capability(caps, key, value)
    end)
  end

  defp check_capability(caps, key, expected_value) do
    case Map.get(@capability_paths, key) do
      nil -> false
      path -> get_in(caps, path) == expected_value
    end
  end
end
