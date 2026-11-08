defmodule EvoDashWeb.AgentsLive.ModelLabel do
  @moduledoc """
  Derives the human-readable model label the Agents page's agent-detail panel
  shows next to "Model".

  PURE, total helper: no side effects, no RPC, no `inspect/1` and no gettext —
  the label is user configuration (provider-profile ids, model ids, reasoning
  efforts) and must never be translated or atomized.

  Resolution order (the first readable source wins):

    1. canonical `model_spec`  -> `"<provider_profile_id> - <model>[ - <effort>]"`
       (string-keyed by contract, atom-keyed tolerated)
    2. `llm_model`             -> a `"provider:model"` binary as-is, or a
       readable `provider:model`-shaped binary derived from an endpoint/model map
    3. legacy `model_id`       -> the binary as-is
    4. `nil`                   -> the template keeps its `gettext("N/A")` fallback

  A nil/empty/non-map intermediate value is skipped rather than rendered, so a
  canonical selection with an absent `reasoning_effort` yields
  `"work - glm-4.6"` — never `"work - glm-4.6 - "`.

  Every read goes through `Map.get/2`, so missing keys are `nil` and unknown
  shapes degrade to the next source instead of raising.
  """

  @separator " - "

  @doc """
  Returns the model label for an agent summary / agent row map (or any map
  carrying `:model_spec`, `:llm_model` and/or `:model_id`), or `nil` when
  nothing readable is present.
  """
  @spec label(term()) :: String.t() | nil
  def label(source) when is_map(source) do
    canonical_label(pget(source, :model_spec)) ||
      llm_model_label(pget(source, :llm_model)) ||
      binary_value(pget(source, :model_id))
  end

  def label(_source), do: nil

  # ── canonical selection ──────────────────────────────────────────────
  # `%{"provider_profile_id" => "work", "model" => "glm-4.6",
  #    "reasoning_effort" => "high"}` -> "work - glm-4.6 - high".
  # Present parts are joined; absent/blank parts contribute nothing.
  defp canonical_label(%{} = spec) do
    parts =
      [
        binary_value(pget(spec, :provider_profile_id)),
        binary_value(pget(spec, :model)),
        effort_value(pget(spec, :reasoning_effort))
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> nil
      parts -> Enum.join(parts, @separator)
    end
  end

  # A non-map `model_spec` (legacy id binary, %URI{}, ...) is not a canonical
  # selection — fall through to `llm_model` / `model_id`.
  defp canonical_label(_spec), do: nil

  # Reasoning effort may legitimately arrive as an atom; anything that is not a
  # non-empty binary/atom is skipped.
  defp effort_value(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: value |> Atom.to_string() |> blank_to_nil()

  defp effort_value(value), do: binary_value(value)

  # ── ReqLLM model input (`:llm_model`) ────────────────────────────────
  # ReqLLM's model input is either a qualified "provider:model" binary, an
  # endpoint/model map (atom- or string-keyed), or an `LLMDB.Model` struct. A
  # struct is still a map, so the map branch below covers it without ever
  # rendering the whole struct.
  defp llm_model_label(%{} = model) do
    model_id = binary_value(pget(model, :id))

    cond do
      not is_nil(model_id) ->
        model_id

      true ->
        provider = binary_value(pget(model, :provider))
        name = binary_value(pget(model, :model)) || binary_value(pget(model, :model_id))

        case {provider, name} do
          {nil, nil} -> nil
          {nil, name} -> name
          {provider, nil} -> provider
          {provider, name} -> provider <> ":" <> name
        end
    end
  end

  defp llm_model_label(model), do: binary_value(model)

  # ── helpers ──────────────────────────────────────────────────────────

  # Atom-keyed summaries AND string-keyed wire maps are both accepted; the atom
  # key wins when both are present (the core's native summary shape).
  defp pget(map, key) when is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp binary_value(value) when is_binary(value), do: blank_to_nil(value)
  defp binary_value(_value), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
