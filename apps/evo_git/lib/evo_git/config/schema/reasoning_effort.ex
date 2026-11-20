defmodule EvoGit.Config.Schema.ReasoningEffort do
  @moduledoc """
  ONE canonical reasoning-effort ladder for the whole runtime.

  `EvoGit.Config.Schema.LLM` re-exports this API (`reasoning_efforts/0`,
  `reasoning_effort_options/0`, `allowed?/1`, `canonical_reasoning_effort/1`,
  `convert_reasoning_effort/1`) and remains the public entry point every caller
  uses — schema validation (`config/schema/definitions.ex`), scheduler
  selection, request assembly and the dashboard. The ladder itself lives here
  so the module that assembles request parameters only does that.

  ## The ladder

  `[:none, :minimal, :low, :medium, :high, :xhigh]` — ascending by intensity,
  and the ONLY user-selectable set. `:max` is deliberately ABSENT: it is a
  provider wire/value ALIAS of `:xhigh` (Z.AI GLM documents `max` natively),
  never a Genesis level of its own, so it is accepted on input (`canonical/1`)
  but never offered (`options/0`).

  `:default` is not a provider level either: it means "send NO
  `reasoning_effort` field at all, so the provider's own default applies".

  ## Totality

  Every function here is total and pure: no clause raises on any term, and no
  input interns an atom (string matching is explicit — see `effort_atom/1`).
  """

  @levels [:none, :minimal, :low, :medium, :high, :xhigh]
  @default :default
  @options @levels ++ [@default]
  @alias_max :max

  @typedoc "A user-selectable reasoning-effort level, ascending by intensity."
  @type level :: :none | :minimal | :low | :medium | :high | :xhigh

  @typedoc """
  Anything the ladder recognises on INPUT: an offered level, the
  provider-default choice (`:default`), or the legacy `:max` alias.
  """
  @type effort :: level() | :default | :max

  @doc """
  Returns the canonical levels in ascending intensity order:

  `#{inspect(@levels)}`
  """
  @spec levels() :: [level()]
  def levels, do: @levels

  @doc """
  Returns the ordered pick list a UI renders: `levels/0` plus `:default`
  (`#{inspect(@options)}`).
  """
  @spec options() :: [level() | :default]
  def options, do: @options

  @doc """
  Returns `true` when `value` is one of the OFFERED choices, `false`
  otherwise. Total — never raises, whatever the input.

  True for the canonical levels and for the provider-default choice
  (`:default` / `nil`), given as atoms or as strings (case-insensitive,
  surrounding whitespace ignored — `" High "` is `:high`).

  `"max"` / `:max` are ACCEPTED legacy ALIASES read as `:xhigh` (`canonical/1`),
  NOT offered levels — so `allowed?("max")` is `false` and `options/0` never
  contains it. Anything else (`"garbage"`, `42`, `%{}`) is `false` too.

  ## Examples

      iex> EvoGit.Config.Schema.ReasoningEffort.allowed?(:xhigh)
      true

      iex> EvoGit.Config.Schema.ReasoningEffort.allowed?(" High ")
      true

      iex> EvoGit.Config.Schema.ReasoningEffort.allowed?(nil)
      true

      iex> EvoGit.Config.Schema.ReasoningEffort.allowed?("max")
      false

      iex> EvoGit.Config.Schema.ReasoningEffort.allowed?("garbage")
      false
  """
  @spec allowed?(term()) :: boolean()
  def allowed?(nil), do: true
  def allowed?(value), do: effort_atom(value) in @options

  @doc """
  Returns the canonical effort atom for any accepted input, or `nil` for
  anything unrecognized. Total — never raises, whatever the input.

  The canonical levels pass through as themselves, `:max` / `"max"` alias to
  `:xhigh` (Z.AI GLM's native spelling), `:default` / `"default"` stay
  `:default`, and `nil` stays `nil` (meaning "provider default"). Strings are
  trimmed and case-insensitive.

  ## Examples

      iex> EvoGit.Config.Schema.ReasoningEffort.canonical("MAX")
      :xhigh

      iex> EvoGit.Config.Schema.ReasoningEffort.canonical(:max)
      :xhigh

      iex> EvoGit.Config.Schema.ReasoningEffort.canonical("high")
      :high

      iex> EvoGit.Config.Schema.ReasoningEffort.canonical(nil)
      nil

      iex> EvoGit.Config.Schema.ReasoningEffort.canonical("garbage")
      nil
  """
  @spec canonical(term()) :: level() | :default | nil
  def canonical(nil), do: nil

  def canonical(value) do
    case effort_atom(value) do
      @alias_max -> :xhigh
      effort -> effort
    end
  end

  @doc """
  `canonical/1` with the documented ECHO: a value the ladder does not
  recognize comes back UNCHANGED, so validation can report it (`"garbage"`
  stays `"garbage"`, `42` stays `42`).

  ## Examples

      iex> EvoGit.Config.Schema.ReasoningEffort.convert("max")
      :xhigh

      iex> EvoGit.Config.Schema.ReasoningEffort.convert("xhigh")
      :xhigh

      iex> EvoGit.Config.Schema.ReasoningEffort.convert("garbage")
      "garbage"

      iex> EvoGit.Config.Schema.ReasoningEffort.convert(42)
      42
  """
  @spec convert(term()) :: term()
  def convert(value), do: canonical(value) || value

  # The RAW input spelling -> atom, WITHOUT the legacy alias: `:max` stays
  # `:max` so callers can tell an accepted alias from an offered level.
  # String matching is explicit (never String.to_existing_atom on user input).
  defp effort_atom(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "none" -> :none
      "minimal" -> :minimal
      "low" -> :low
      "medium" -> :medium
      "high" -> :high
      "xhigh" -> :xhigh
      "max" -> @alias_max
      "default" -> @default
      _ -> nil
    end
  end

  defp effort_atom(value) when is_atom(value) do
    if value in @options or value == @alias_max, do: value, else: nil
  end

  defp effort_atom(_value), do: nil
end
