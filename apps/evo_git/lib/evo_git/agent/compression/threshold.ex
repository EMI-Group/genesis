defmodule EvoGit.Agent.Compression.Threshold do
  @moduledoc """
  Window-relative context-compression trigger.

  Historically the trigger was a single fixed number
  (`[:llm, :compression_threshold_tokens]`, default 180_000) applied to every
  model. That is wrong in both directions: a 1M-token window was compressed at
  18 % of its capacity (wasting the window, and paying for a summarising LLM
  call that was not needed), while a 128k-token window was compressed far too
  late. This module derives the trigger from the model's OWN context window, so
  the same policy fits every model.

  ## The formula (for a known window `W`)

      reserved = clamp(output_limit || 8_192, 1_024, 32_768)
      raw      = min(trunc(W * 0.8), W - reserved - 65_536)
      floor    = min(32_000, trunc(W * 0.9))
      threshold = raw |> max(floor) |> min(trunc(W * 0.9))

  Each constant has one job:

    * **0.8 of the window** — compress once 80 % of the window is in use, leaving
      room for the next tool-heavy turn to arrive before the summarising call.
    * **65_536 tokens of headroom** — an absolute safety margin subtracted with
      the model's declared output limit, so the compression request itself can
      never be the request that overflows.
    * **`reserved` = the model's output limit** — clamped to `[1_024, 32_768]`
      because a tiny declared output limit would eat the window and an enormous
      one would make the subtraction meaningless; `8_192` is used when the
      catalog does not declare one.
    * **32_000-token floor** — compress no earlier than a sane working set; on a
      small window the `0.9` cap below wins instead, so the floor can never
      exceed the window.
    * **0.9 hard cap** — never trigger at (or past) the window itself; a
      threshold equal to the window would mean "compress only after overflow".

  Worked examples:

      W = 1_000_000  ->  800_000   (a 1M model no longer compresses at the old
                                    fixed 180_000 = 18 % of its window)
      W =   131_072  ->   57_344   (a 128k model compresses comfortably before
                                    overflow: 131_072 - 8_192 - 65_536)
      W =    32_768  ->   29_491   (the 0.9 cap keeps a tiny window usable)

  When the window is unknown the module degrades to the legacy config value
  (`source: :config`), so behaviour is unchanged for models the catalog cannot
  describe.

  ## Purity

  `for_model/1` reads the model metadata through
  `EvoGit.Config.Schema.LLM.model_metadata/1` (which itself never raises) and
  the config fallback through `EvoGit.Config.resolve/1`. Everything is a plain
  function call — no scheduler/registry lookup, no process, no state, and no
  `try`/`rescue`.
  """

  @typedoc """
  `source` says which trigger is in force: `:window` (derived from the model's
  context window) or `:config` (the legacy fixed config value, used when the
  window is unknown).
  """
  @type info :: %{
          threshold: pos_integer(),
          window: pos_integer() | nil,
          source: :window | :config
        }

  # Compression starts at 80 % of the model's window.
  @window_fraction_numerator 8
  @window_fraction_denominator 10

  # Absolute safety margin: leave at least this much room below the window.
  @headroom_tokens 65_536

  # Never compress earlier than this working set, and never later than 90 %.
  @min_threshold_tokens 32_000
  @hard_cap_fraction_numerator 9
  @hard_cap_fraction_denominator 10

  # The model's declared output reservation, clamped to a sane band.
  @default_reserved_output_tokens 8_192
  @min_reserved_output_tokens 1_024
  @max_reserved_output_tokens 32_768

  @doc """
  Resolves the compression trigger for `llm_model`.

  `llm_model` is anything `EvoGit.Config.Schema.LLM.model_metadata/1` accepts (a
  `"provider:id"` string, a profile map, …). A model whose context window cannot
  be determined falls back to
  `[:llm, :compression_threshold_tokens]` with `window: nil` and
  `source: :config`.
  """
  @spec for_model(term()) :: info()
  def for_model(llm_model) do
    case context_window(llm_model) do
      {:ok, window, output_limit} ->
        %{
          threshold: threshold_for(window, output_limit),
          window: window,
          source: :window
        }

      :unknown ->
        %{
          threshold: EvoGit.Config.resolve([:llm, :compression_threshold_tokens]),
          window: nil,
          source: :config
        }
    end
  end

  @doc """
  Whether `total_tokens` is past the trigger.

  Strictly greater than, so a context sitting exactly on the threshold is left
  alone. Total: an info map without a usable integer threshold never triggers.
  """
  @spec exceeded?(non_neg_integer(), map()) :: boolean()
  def exceeded?(total_tokens, info) when is_integer(total_tokens) and is_map(info) do
    case Map.get(info, :threshold) do
      threshold when is_integer(threshold) -> total_tokens > threshold
      _other -> false
    end
  end

  def exceeded?(_total_tokens, _info), do: false

  @doc """
  Projects the reported token count through a character-based saving ratio.

  `state.total_tokens` is the LAST turn's provider-reported
  `input + output + reasoning` count, so scaling it by
  `chars_after / chars_before` is a sound approximation of what the pruned
  messages will cost (both quantities are proportional to the same text for a
  given tokenizer). Units therefore stay TOKENS.

  Degenerate cases keep the reported count: a `chars_before` of 0 has no ratio to
  apply, and a rewrite that did not shrink anything (`chars_after >=
  chars_before`) means nothing was saved. The result is clamped to never exceed
  `total_tokens`.
  """
  @spec project(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def project(total_tokens, chars_before, chars_after)
      when is_integer(total_tokens) and is_integer(chars_before) and is_integer(chars_after) do
    remaining = max(chars_after, 0)

    if chars_before <= 0 or remaining >= chars_before or total_tokens <= 0 do
      total_tokens
    else
      scaled = round(total_tokens * remaining / chars_before)
      scaled |> max(0) |> min(total_tokens)
    end
  end

  def project(total_tokens, _chars_before, _chars_after), do: total_tokens

  ## Window discovery

  # One metadata read serves both the window and the output reservation. Anything
  # unexpected (missing metadata, non-map limits, an unknown window) degrades to
  # `:unknown` so `for_model/1` can fall back — this is a per-turn code path and
  # must never raise.
  defp context_window(llm_model) do
    case EvoGit.Config.Schema.LLM.model_metadata(llm_model) do
      %{} = metadata ->
        case Map.get(metadata, :limits) do
          %{} = limits ->
            case positive_integer(limit(limits, :context)) do
              nil -> :unknown
              window -> {:ok, window, positive_integer(limit(limits, :output))}
            end

          _other ->
            :unknown
        end

      _other ->
        :unknown
    end
  end

  # Model metadata crosses TOML/JSON boundaries, so both key shapes are accepted.
  defp limit(limits, key) do
    case Map.fetch(limits, key) do
      {:ok, value} -> value
      :error -> Map.get(limits, Atom.to_string(key))
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  ## Formula

  defp threshold_for(window, output_limit) do
    reserved = reserve_for(output_limit)
    window_fraction = div(window * @window_fraction_numerator, @window_fraction_denominator)
    hard_cap = div(window * @hard_cap_fraction_numerator, @hard_cap_fraction_denominator)
    floor = min(@min_threshold_tokens, hard_cap)

    raw = min(window_fraction, window - reserved - @headroom_tokens)

    # The final `max(1)` only matters for a degenerate sub-two-token window, where
    # the 0.9 cap rounds to 0 — a caller must never be handed a 0 threshold.
    raw
    |> max(floor)
    |> min(hard_cap)
    |> max(1)
  end

  defp reserve_for(output_limit) when is_integer(output_limit) do
    output_limit
    |> max(@min_reserved_output_tokens)
    |> min(@max_reserved_output_tokens)
  end

  defp reserve_for(_output_limit), do: @default_reserved_output_tokens
end
