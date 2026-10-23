defmodule EvoGit.Agent.Compression.Threshold do
  @moduledoc """
  Window-relative context-compression trigger and stage-1 pruning target.

  ## The window comes from configuration, not from the catalog

  The trigger is derived from the agent's CONFIGURED context window: the model
  profile's `[[llm.models]] context_window` key, resolved by the data-plane gate
  and threaded down as `opts[:context_window]`, falling back to
  `EvoGit.Config.Schema.LLM.default_context_window/0` (200_000) when the caller
  supplies nothing usable. The model catalog is consulted only for the OUTPUT
  reservation (`limits.output`) — its `limits.context` is deliberately never
  read, because catalog windows are frequently missing or stale while the
  operator's configured window is the number the runtime actually provisions.

  ## The formula (for a window `W`)

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

  Worked examples (default 8_192-token output reservation):

      W = 1_000_000  ->  800_000
      W =   200_000  ->  126_272   (the default window)
      W =   131_072  ->   57_344
      W =    64_000  ->   32_000   (the floor wins: W - 8_192 - 65_536 < 0)
      W =    32_768  ->   29_491   (the 0.9 cap keeps a tiny window usable)

  ## The explicit override

  `[:llm, :compression_threshold_tokens]` is an OPTIONAL override: when it is a
  positive integer it wins verbatim (`source: :config`), whatever the configured
  window says. Its schema default is `nil`, which means "derive from the window"
  (`source: :window`).

  ## Stage-1 pruning target

  `pruning_target/2` is the token count the model-free tool-result prune must
  reach before it is worth adopting: `min(threshold, round(W * fraction))`, with
  `fraction` defaulting to `default_pruning_target_fraction/0` (0.5) and an
  unusable fraction normalizing to that default. Reaching the trigger is NOT
  enough reason to prune — pruning rewrites old tool results and therefore
  invalidates the provider's cached prefix, so it must recover a LOT of context
  to pay for itself (`EvoGit.Agent.ContextCompression` owns that decision).

  ## Purity

  `for_model/2` reads the output reservation through
  `EvoGit.Config.Schema.LLM.model_metadata/1` (which itself never raises) and
  the override through `EvoGit.Config.resolve/1`. Everything is a plain
  function call — no scheduler/registry lookup, no process, no state, and no
  `try`/`rescue`.
  """

  @typedoc """
  `source` says which trigger is in force: `:window` (derived from the
  configured context window) or `:config` (an explicit positive
  `[:llm, :compression_threshold_tokens]` override).
  """
  @type info :: %{
          threshold: pos_integer(),
          window: pos_integer(),
          source: :window | :config
        }

  # Compression starts at 80 % of the configured window.
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

  # Stage 1 must reclaim down to this fraction of the window to be adopted.
  @default_pruning_target_fraction 0.5

  @doc """
  Resolves the compression trigger for `llm_model`.

  `llm_model` is anything `EvoGit.Config.Schema.LLM.model_metadata/1` accepts
  (a `"provider:id"` string, a profile map, …); it is consulted ONLY for the
  output reservation.

  ## Options

    * `:context_window` — the configured context window in tokens (a positive
      integer); anything else falls back to
      `EvoGit.Config.Schema.LLM.default_context_window/0`

  ## Returns

  `%{threshold: pos_integer, window: pos_integer, source: :window | :config}` —
  `window` is ALWAYS the configured window (never nil).
  """
  @spec for_model(term(), keyword()) :: info()
  def for_model(llm_model, opts \\ []) do
    window = configured_window(opts)

    case config_threshold() do
      threshold when is_integer(threshold) and threshold > 0 ->
        %{threshold: threshold, window: window, source: :config}

      _unset ->
        %{
          threshold: threshold_for(window, output_limit(llm_model)),
          window: window,
          source: :window
        }
    end
  end

  @doc """
  The token count Stage-1 tool-result pruning must reach to be worth adopting.

  `min(threshold, round(window * fraction))` — a prune that leaves the context
  above this target is not considered a real recovery (it invalidated the
  provider's cached prefix, so it has to buy real headroom).

  A nil/unusable `window` yields the threshold itself (nothing tighter to aim
  for), and a `fraction` outside the open interval `(0, 1)` — including
  non-numbers — normalizes to `default_pruning_target_fraction/0`. Total: never
  raises, an unusable `info` yields 0.
  """
  @spec pruning_target(map(), term()) :: non_neg_integer()
  def pruning_target(info, fraction) when is_map(info) do
    threshold = threshold_of(info)

    case Map.get(info, :window) do
      window when is_integer(window) and window > 0 ->
        min(threshold, round(window * normalize_fraction(fraction)))

      _unusable ->
        threshold
    end
  end

  def pruning_target(_info, _fraction), do: 0

  @doc """
  The default Stage-1 pruning target fraction of the window (0.5).
  """
  @spec default_pruning_target_fraction() :: float()
  def default_pruning_target_fraction, do: @default_pruning_target_fraction

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

  ## Inputs

  defp configured_window(opts) do
    case Keyword.get(opts, :context_window) do
      window when is_integer(window) and window > 0 ->
        window

      _unusable ->
        EvoGit.Config.Schema.LLM.default_context_window()
    end
  end

  # The override is optional: `nil` (the schema default) means "derive".
  defp config_threshold do
    EvoGit.Config.resolve([:llm, :compression_threshold_tokens])
  end

  # The catalog supplies ONLY the output reservation; `limits.context` is
  # deliberately ignored (the configured window governs). Anything unexpected
  # degrades to `nil` (→ the 8_192 default) — this is a per-turn code path and
  # must never raise.
  defp output_limit(llm_model) do
    case EvoGit.Config.Schema.LLM.model_metadata(llm_model) do
      %{} = metadata ->
        case Map.get(metadata, :limits) do
          %{} = limits -> positive_integer(limit(limits, :output))
          _other -> nil
        end

      _other ->
        nil
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

  defp threshold_of(info) do
    case Map.get(info, :threshold) do
      threshold when is_integer(threshold) and threshold > 0 -> threshold
      _other -> 0
    end
  end

  defp normalize_fraction(fraction) when is_number(fraction) and fraction > 0 and fraction < 1,
    do: fraction

  defp normalize_fraction(_fraction), do: @default_pruning_target_fraction

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
