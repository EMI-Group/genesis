defmodule EvoGit.Config.Schema.LLMConstraints do
  @moduledoc """
  Provider/model-aware filtering of LLM generation parameters.

  Genesis' generation-parameter set (`[:llm, :*]` config keys plus the optional
  per-profile `[[llm.models]]` fields) is deliberately provider-agnostic: the
  dashboard lets a user set `temperature`, `max_tokens`, `reasoning_effort`,
  `top_p`, `top_k`, `frequency_penalty` and `presence_penalty` for ANY model, and
  `EvoGit.Config.Schema.LLM.profile_generation_params/1` forwards them verbatim
  to ReqLLM. Providers reject unknown parameter NAMES or out-of-range VALUES with
  a hard 400 — e.g. Z.AI answers `{"code":"1210"}` ("Invalid API parameter") for
  an unrecognized parameter name and `1214` for an invalid value for a known
  field, which fails EVERY LLM call of a task.

  This module is the single place where such parameters are dropped before a
  request is built. It is **pure** (no I/O, no process state, no GenServer) and
  NEVER raises, whatever the input.

  ## Two constraint sources

  1. **Declarative provider/model table** (`@constraint_tables`) — hand-written,
     documented per rule, and independent of any catalog/library being present.
     Seeded with Z.AI/GLM.
  2. **Model metadata** — `%{limits: map(), capabilities: map()}`, resolved by
     the caller through `EvoGit.Config.Schema.LLM.model_metadata/1` (which reads
     the `:llm_model_metadata_fun` app-env seam). Used for `limits.output`
     (`:max_tokens`) and the capability gates (`:reasoning_effort`, tools).

  ## Degradation contract (never guess, never raise)

  Table rules fire from the table alone. Metadata rules fire ONLY when the
  metadata is actually available: a `nil`/empty metadata map, an unknown or
  unparseable model spec, or a model id the catalog does not know leaves the
  parameter list **byte-identical** — a parameter is never dropped merely
  because metadata is missing.

  A violation is always resolved by **omitting** the offending parameter (never
  by clamping or mapping the value — no documented value mapping exists for the
  affected families), together with a `Logger.warning` naming the parameter, the
  model and the reason. Rationale: config/runtime modules must degrade
  gracefully and never raise on user config, and silently substituting a value
  would hide the misconfiguration from the user.

  Keyword ORDER of the surviving parameters is preserved.
  """

  require Logger

  alias EvoGit.Config.Schema.LLM

  # ── Declarative constraint table ─────────────────────────────────────────
  #
  # One entry per provider/model family. Adding a provider = adding one map.
  #
  # Fields:
  #   * `:id`                — stable identifier (used in log messages)
  #   * `:provenance`        — the documented source every rule comes from
  #   * `:providers`         — provider atoms this entry applies to
  #   * `:model_id_pattern`  — regex matched against the model id
  #   * `:unsupported_params`— param names this provider does not document
  #   * `:max_temperature`   — documented maximum `temperature` value
  #   * `:reasoning_effort`  — `%{default: [atom], by_model: [{regex, [atom]}]}`
  #   * `:thinking_disable_unsupported` — model patterns whose
  #     `thinking.type = "disabled"` is rejected. INFORMATIONAL ONLY: Genesis
  #     itself never emits a `thinking` parameter (it is only reachable through
  #     the explicit user `provider_options` profile override, which always
  #     wins), so this field has no filter effect. It is recorded here so the
  #     documented constraint is not lost, and is surfaced by
  #     `constraints_for/1`.
  @constraint_tables [
    %{
      id: :zai_glm,
      provenance:
        "Z.AI GLM Chat-Completions API reference (docs.z.ai): the documented body " <>
          "fields are model, messages, temperature ([0.0, 1.0]), top_p, max_tokens " <>
          "(<= 131072 for GLM-5.x/4.7/4.6), stream, tools, tool_choice, tool_stream, " <>
          "thinking and reasoning_effort; top_k, frequency_penalty and " <>
          "presence_penalty are NOT documented. GLM-5.3 / GLM-5.3-FLASH accept " <>
          "reasoning_effort low|high|max only and reject thinking.type = \"disabled\"; " <>
          "GLM-5.2 and earlier accept the OpenAI reasoning_effort set with mapping " <>
          "(none/minimal skip thinking, low/medium -> high, xhigh -> max). Z.AI " <>
          "error codes: 1210 = unrecognized parameter NAME, 1211 = unknown model, " <>
          "1212 = unsupported method, 1213 = missing field, 1214 = invalid VALUE for " <>
          "a named field, 1215 = mutually exclusive fields.",
      # req_llm ships three Z.AI providers (zai, zai_coder, zai_coding_plan); all
      # three speak the same Z.AI Chat-Completions API.
      providers: [:zai, :zai_coder, :zai_coding_plan],
      # Model-id heuristic: any id containing "glm" (case-insensitive) is treated
      # as a GLM model — this also covers OpenRouter-style ids such as
      # "z-ai/glm-5.3-flash" served through a non-Z.AI provider atom.
      #
      # LIMITS of the heuristic: GLM weights served under an id that does NOT
      # contain "glm" are not matched (the GLM value restrictions stay inert),
      # while an unrelated id that merely contains "glm" (or a non-Z.AI provider
      # serving GLM weights) is matched and gets the Z.AI restrictions — which
      # are a conservative subset of what every OpenAI-compatible endpoint
      # accepts.
      model_id_pattern: ~r/glm/i,
      unsupported_params: [:top_k, :frequency_penalty, :presence_penalty],
      max_temperature: 1.0,
      reasoning_effort: %{
        # GLM-5.2 and earlier: the full OpenAI set is accepted.
        default: [:none, :minimal, :low, :medium, :high, :xhigh, :default],
        # GLM-5.3 / GLM-5.3-FLASH: low|high|max only.
        by_model: [{~r/glm-5\.3/i, [:low, :high, :max]}]
      },
      thinking_disable_unsupported: [~r/glm-5\.3/i]
    }
  ]

  @doc """
  Filters a generation-parameter keyword list for a concrete model spec.

  `params` is the assembled keyword list (the shape produced by
  `EvoGit.Config.Schema.LLM.profile_generation_params/1`), `model` is the raw
  model spec (string `"provider:id"`, map `%{provider: ..., id: ...}`, tuple
  `{provider, opts}` or `nil`) and `metadata` is the model metadata map
  (`%{limits: %{output: integer}, capabilities: %{reasoning: %{enabled: boolean},
  tools: %{enabled: boolean}}}`) or `nil` when unavailable.

  Returns the filtered keyword list with the surviving entries in their original
  order. Non-keyword / non-list input is returned unchanged (graceful guard).
  Never raises.

  ## Rules

  Table-driven (always applied when a table entry matches the model):

  * `:unsupported_params` — omitted (undocumented parameter name for the
    provider).
  * `:max_temperature` — `:temperature` above it is omitted.
  * `:reasoning_effort` — an effort outside the documented set is omitted.

  Metadata-driven (applied only when the metadata is present):

  * `:max_tokens` above `limits.output` — omitted (+ warning).
  * `capabilities.reasoning.enabled != true` — `:reasoning_effort` omitted.
  * `capabilities.tools.enabled != true` — `:tools` / `:tool_choice` omitted.
    (Genesis' params keyword list never contains tool keys today — the agent
    layer passes tools separately — so this branch is currently unreachable in
    production; it is implemented so the rule holds if such keys ever appear.)
  """
  @spec filter(term(), term(), map() | nil) :: term()
  def filter(params, _model, _metadata) when not is_list(params), do: params

  def filter(params, model, metadata) do
    if Keyword.keyword?(params) do
      meta = normalize_metadata(metadata)

      params
      |> drop_unsupported_params(model)
      |> filter_temperature(model)
      |> filter_max_tokens(model, meta)
      |> filter_reasoning_effort(model, meta)
      |> filter_tool_params(meta)
    else
      params
    end
  end

  @doc """
  Returns the declarative constraint entries that apply to a model spec.

  Matching is provider-atom based (`%{providers: [...]}`) OR model-id based
  (`%{model_id_pattern: regex}`), so a GLM model served through a non-Z.AI
  provider atom is still matched. Returns `[]` for `nil`, unknown or
  non-matching models.
  """
  @spec constraints_for(term()) :: [map()]
  def constraints_for(model), do: matching_tables(model)

  # ── Table-driven rules ───────────────────────────────────────────────────

  defp drop_unsupported_params(params, model) do
    keys =
      model
      |> matching_tables()
      |> Enum.flat_map(&Map.get(&1, :unsupported_params, []))
      |> Enum.uniq()

    drop_params(params, keys, model, "not accepted by this provider/model")
  end

  defp filter_temperature(params, model) do
    with {:ok, value} <- Keyword.fetch(params, :temperature),
         max when is_number(max) <- max_temperature(model),
         true <- is_number(value) and value > max do
      drop_param(
        params,
        :temperature,
        model,
        "value above the documented maximum #{inspect(max)}"
      )
    else
      _ -> params
    end
  end

  defp max_temperature(model) do
    model
    |> matching_tables()
    |> Enum.map(&Map.get(&1, :max_temperature))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp allowed_efforts(model) do
    sets =
      model
      |> matching_tables()
      |> Enum.flat_map(fn table ->
        case Map.get(table, :reasoning_effort) do
          %{} = spec -> [allowed_set(spec, model)]
          _ -> []
        end
      end)

    case sets do
      [] -> :any
      [only] -> only
      [first | rest] -> Enum.reduce(rest, first, &intersect_efforts(&2, &1))
    end
  end

  defp allowed_set(spec, model) do
    id = model_id(model)
    by_model = Map.get(spec, :by_model, [])
    default = Map.get(spec, :default)

    matched =
      Enum.find(by_model, fn
        {%Regex{} = pattern, _values} -> is_binary(id) and Regex.match?(pattern, id)
        _ -> false
      end)

    case matched do
      {_pattern, values} when is_list(values) -> values
      _ -> if(is_list(default), do: default, else: :any)
    end
  end

  defp intersect_efforts(:any, other), do: other
  defp intersect_efforts(other, :any), do: other
  defp intersect_efforts(a, b), do: Enum.filter(a, &(&1 in b))

  defp matching_tables(model) do
    provider = LLM.provider_from_model(model)
    id = model_id(model)

    Enum.filter(@constraint_tables, fn table ->
      provider in Map.get(table, :providers, []) or matches_model_id?(table, id)
    end)
  end

  defp matches_model_id?(table, id) when is_binary(id) do
    case Map.get(table, :model_id_pattern) do
      %Regex{} = pattern -> Regex.match?(pattern, id)
      _ -> false
    end
  end

  defp matches_model_id?(_table, _id), do: false

  # ── Metadata-driven rules ────────────────────────────────────────────────

  defp filter_max_tokens(params, model, %{limits: limits}) do
    with {:ok, value} <- Keyword.fetch(params, :max_tokens),
         limit when is_integer(limit) <- fetch_key(limits, :output),
         true <- is_integer(value) and value > limit do
      drop_param(
        params,
        :max_tokens,
        model,
        "value exceeds the model's output token limit (#{limit})"
      )
    else
      _ -> params
    end
  end

  defp filter_max_tokens(params, _model, _no_metadata), do: params

  defp filter_reasoning_effort(params, model, meta) do
    case Keyword.fetch(params, :reasoning_effort) do
      :error ->
        params

      {:ok, raw_effort} ->
        # Values arriving from TOML are strings; compare on the normalized atom
        # form so a documented level is not dropped merely because the config
        # layer forwarded it as a string (e.g. "max", which the config schema's
        # reasoning_effort set does not atomize).
        effort = normalize_effort(raw_effort)
        allowed = allowed_efforts(model)

        cond do
          not capability_enabled?(meta, :reasoning) ->
            drop_param(
              params,
              :reasoning_effort,
              model,
              "the model does not declare reasoning support"
            )

          allowed != :any and effort not in allowed ->
            drop_param(
              params,
              :reasoning_effort,
              model,
              "value #{inspect(raw_effort)} is not in the documented set " <>
                "#{inspect(Enum.map(allowed, &Atom.to_string/1))}"
            )

          true ->
            params
        end
    end
  end

  defp normalize_effort(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_effort(value), do: value

  defp filter_tool_params(params, meta) do
    if capability_enabled?(meta, :tools) do
      params
    else
      drop_params(params, [:tools, :tool_choice], nil, "the model does not declare tool support")
    end
  end

  # ── Shared helpers ───────────────────────────────────────────────────────

  defp drop_params(params, keys, model, reason) do
    Enum.reduce(keys, params, &drop_param(&2, &1, model, reason))
  end

  defp drop_param(params, key, model, reason) do
    case Keyword.fetch(params, key) do
      :error ->
        params

      {:ok, value} ->
        Logger.warning(
          "LLMConstraints: omitting #{inspect(key)} = #{inspect(value)} for model " <>
            "#{inspect(model)} — #{reason}"
        )

        Keyword.delete(params, key)
    end
  end

  # `true` when the metadata does not (or only partially) declare capabilities —
  # missing metadata must never cause a drop. A non-empty capabilities map that
  # does not declare the capability means "not supported".
  defp capability_enabled?(nil, _key), do: true

  defp capability_enabled?(%{capabilities: capabilities}, key) do
    if is_map(capabilities) and map_size(capabilities) > 0 do
      case fetch_key(capabilities, key) do
        %{} = section -> fetch_key(section, :enabled) == true
        _ -> false
      end
    else
      true
    end
  end

  defp capability_enabled?(_other, _key), do: true

  # Accepts both the documented metadata map and a raw catalog model struct
  # (anything carrying `:limits` / `:capabilities`); collapses to `nil` when
  # neither is usable, so downstream rules stay inert. Public so the metadata
  # source (`EvoGit.Config.Schema.LLM.model_metadata/1`, incl. the app-env seam)
  # can normalize its result to the documented contract.
  @doc false
  @spec normalize_metadata(term()) :: %{limits: map(), capabilities: map()} | nil
  def normalize_metadata(nil), do: nil

  def normalize_metadata(%{} = meta) do
    limits = to_map(fetch_key(meta, :limits))
    capabilities = to_map(fetch_key(meta, :capabilities))

    if map_size(limits) == 0 and map_size(capabilities) == 0 do
      nil
    else
      %{limits: limits, capabilities: capabilities}
    end
  end

  def normalize_metadata(_other), do: nil
  defp to_map(value) when is_map(value), do: value
  defp to_map(_other), do: %{}

  # Tolerant key read: accepts atom- and string-keyed maps (config-derived data
  # crosses TOML/JSON boundaries where keys are strings).
  defp fetch_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp fetch_key(_map, _key), do: nil

  defp model_id(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [_provider, id] when id != "" -> id
      _ -> if(model != "", do: model, else: nil)
    end
  end

  defp model_id(%{} = model) do
    case Map.get(model, :id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp model_id({_provider, opts}) when is_list(opts), do: model_id_from_opts(opts)
  defp model_id({_provider, id}) when is_binary(id), do: if(id != "", do: id, else: nil)
  defp model_id(_other), do: nil

  defp model_id_from_opts(opts) do
    case Keyword.get(opts, :id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end
end
