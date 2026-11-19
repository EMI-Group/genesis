defmodule EvoDashWeb.LLMSetup.Wizard do
  @moduledoc """
  The PURE step model shared by `/welcome` onboarding and `/settings`.

  A wizard run is an ordered list of steps plus the caller's draft. This
  module owns the ORDER, the navigation maths and the per-step gating — and
  nothing else: no LiveView, no assigns, no catalog or config access, no
  process, no persisted state. Both pages therefore present the same sequence,
  the same progress indicator and the same "may I advance?" rule.

  ## Steps

  `#{inspect([:provider, :auth, :model, :reasoning_schedule, :test, :done])}`

  `:auth` is CONDITIONAL: a provider with no real authentication choice
  (`capabilities.auth_choice? == false`, e.g. a single-mode or
  OpenAI-compatible endpoint) never shows that step, so onboarding only asks
  the question where it can actually be answered differently.

  ## Navigation is clamped, never raising

  `next/2` at the last step answers the last step and `back/2` at the first
  answers the first — a page can wire both buttons unconditionally. An
  unknown/nil step answers `nil` for `next/2`/`back/2` and `{0, total, 0}` for
  `progress/2`, so nothing ever crashes on stale state.
  """

  @all_steps [:provider, :auth, :model, :reasoning_schedule, :test, :done]

  @auth_modes ~w(api_key oauth)

  @doc """
  Every step, in wizard order.
  """
  @spec all_steps() :: [atom()]
  def all_steps, do: @all_steps

  @doc """
  The steps this run shows.

  `capabilities` may be any map (atom- or string-keyed); `auth_choice?: false`
  (or `"auth_choice?" => false`) drops `:auth`. Non-map input keeps every step.
  """
  @spec steps_for(term()) :: [atom()]
  def steps_for(capabilities) do
    if auth_choice_available?(capabilities) do
      @all_steps
    else
      List.delete(@all_steps, :auth)
    end
  end

  @doc """
  The first step of a run (`nil` for an empty list).
  """
  @spec first([atom()]) :: atom() | nil
  def first(steps), do: step_at(steps, 0)

  @doc """
  The step after `step`, clamped to the last step; `nil` when `step` is not in
  the run (or `steps` is not a list).
  """
  @spec next(term(), term()) :: atom() | nil
  def next(steps, step) do
    with index when is_integer(index) <- index(steps, step),
         count when count > 0 <- length(steps) do
      step_at(steps, min(index + 1, count - 1))
    else
      _ -> nil
    end
  end

  @doc """
  The step before `step`, clamped to the first step; `nil` when `step` is not
  in the run (or `steps` is not a list).
  """
  @spec back(term(), term()) :: atom() | nil
  def back(steps, step) do
    with index when is_integer(index) <- index(steps, step),
         count when count > 0 <- length(steps) do
      step_at(steps, max(index - 1, 0))
    else
      _ -> nil
    end
  end

  @doc """
  The zero-based position of `step` in `steps`; `nil` when absent or when
  `steps` is not a list.
  """
  @spec index(term(), term()) :: non_neg_integer() | nil
  def index(steps, step) when is_list(steps) do
    Enum.find_index(steps, &(&1 == step))
  end

  def index(_steps, _step), do: nil

  @doc """
  The step at zero-based position `n`; `nil` when out of range.
  """
  @spec step_at(term(), term()) :: atom() | nil
  def step_at(steps, n) when is_list(steps) and is_integer(n) and n >= 0 do
    Enum.at(steps, n)
  end

  def step_at(_steps, _n), do: nil

  @doc """
  `{current, total, percent}` for the progress indicator: `current` is the
  1-based position of `step`, `total` the number of steps, and `percent` a
  pure integer clamped to 1..100 (a run always shows visible progress).

  An unknown step answers `{0, total, 0}`.
  """
  @spec progress(term(), term()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def progress(steps, step) do
    total = if is_list(steps), do: length(steps), else: 0

    case index(steps, step) do
      nil when total == 0 -> {0, 0, 0}
      nil -> {0, total, 0}
      position -> {position + 1, total, percent(position + 1, total)}
    end
  end

  defp percent(_current, total) when total <= 0, do: 0

  defp percent(current, total) do
    current
    |> Kernel./(total)
    |> Kernel.*(100)
    |> Float.round()
    |> trunc()
    |> max(1)
    |> min(100)
  end

  @doc """
  The gate that decides whether the caller may advance from `step`.

  - `:provider` — `:ok` only with a non-blank provider (else
    `{:error, :missing_provider}`);
  - `:auth` — `:ok` only with a supported mode, `"api_key"` or `"oauth"`
    (else `{:error, :invalid_auth_mode}`);
  - `:model` — `:ok` with a non-blank catalog pick OR free-text custom model
    name (else `{:error, :missing_model}`);
  - `:reasoning_schedule`, `:test`, `:done` and any unknown step — always
    `:ok` (a reasoning inventory or a schedule is never mandatory, and a
    connection test is always skippable).

  `draft` may be atom- or string-keyed; non-map input is treated as empty.
  """
  @spec validate(term(), term()) :: :ok | {:error, atom()}
  def validate(:provider, draft) do
    if blank?(draft_get(draft, "provider")) do
      {:error, :missing_provider}
    else
      :ok
    end
  end

  def validate(:auth, draft) do
    if normalize_auth_mode(draft_get(draft, "auth_mode")) in @auth_modes do
      :ok
    else
      {:error, :invalid_auth_mode}
    end
  end

  def validate(:model, draft) do
    if blank?(draft_get(draft, "model")) and blank?(draft_get(draft, "custom_model")) do
      {:error, :missing_model}
    else
      :ok
    end
  end

  def validate(_step, _draft), do: :ok

  # ── private ────────────────────────────────────────────────────────────────

  defp auth_choice_available?(capabilities) when is_map(capabilities) do
    case Map.fetch(capabilities, :auth_choice?) do
      {:ok, value} -> value != false
      :error -> Map.get(capabilities, "auth_choice?", true) != false
    end
  end

  defp auth_choice_available?(_capabilities), do: true

  defp draft_get(draft, key) when is_map(draft) do
    case Map.fetch(draft, key) do
      {:ok, value} -> value
      :error -> Map.get(draft, draft_key_atom(key))
    end
  end

  defp draft_get(_draft, _key), do: nil

  # Static key → atom table: caller input never interns an atom.
  defp draft_key_atom("provider"), do: :provider
  defp draft_key_atom("auth_mode"), do: :auth_mode
  defp draft_key_atom("model"), do: :model
  defp draft_key_atom("custom_model"), do: :custom_model

  defp normalize_auth_mode(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_auth_mode(value) when is_atom(value) and value not in [nil, true, false],
    do: value |> Atom.to_string() |> normalize_auth_mode()

  defp normalize_auth_mode(_value), do: ""

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value) when is_atom(value), do: value in [nil, true, false]
  defp blank?(_value), do: false
end
