defmodule EvoDashWeb.LLMSetup.Reasoning do
  @moduledoc """
  The dashboard's SINGLE reasoning-effort vocabulary.

  Every LLM-setup surface (`/welcome` onboarding and `/settings`) renders the
  reasoning ladder from THIS module, and this module delegates the ladder
  itself to the core — `EvoGit.Config.Schema.LLM.reasoning_efforts/0` and
  `reasoning_effort_options/0` are the only source of truth. There is NO copy
  of the level list here, so a core change (a new level, a retired one) is
  picked up with no dashboard edit.

  ## Why `"max"` is not a level

  `:max` is a provider WIRE alias of `:xhigh` (`Z.AI` GLM spells its top level
  `max`). It is therefore never offered as its own chip: `efforts/0` never
  contains `"max"`, and `canonical/1` reads a persisted `"max"` as `"xhigh"`.
  A picker built from `options/0` can consequently never produce a duplicate
  top level.

  ## Totality

  Every function is pure and total — no config access, no catalog, no process,
  and never a raise: an unknown, blank or wrongly-typed value degrades to
  `nil` / `[]` / its own cleaned string.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoGit.Config.Schema.LLM

  # zh_CN: None → "无" (send no reasoning effort at all), Minimal → "极低",
  # Low → "低", Medium → "中", High → "高", Extra high → "极高" (the core's
  # top level `xhigh`; providers may spell it `max`), Provider default →
  # "跟随提供方" (omit the field so the provider's own default applies).
  @doc """
  The offered reasoning LEVELS as strings, in core order:
  `["none", "minimal", "low", "medium", "high", "xhigh"]`.

  Never contains `"max"` (a wire alias, see the moduledoc) and never contains
  `"default"` (a UI choice, not a level — see `options/0`).
  """
  @spec efforts() :: [String.t()]
  def efforts do
    Enum.map(LLM.reasoning_efforts(), &Atom.to_string/1)
  end

  @doc """
  The ordered pick list a UI renders: `efforts/0` plus `"default"` last.

  `"default"` means "send no `reasoning_effort` field at all, i.e. let the
  provider decide"; it is deliberately NOT part of `efforts/0`, so an
  inventory multi-select and the per-model default select cannot confuse the
  two vocabularies.
  """
  @spec options() :: [String.t()]
  def options do
    Enum.map(LLM.reasoning_effort_options(), &Atom.to_string/1)
  end

  @doc """
  `true` when `value` is one of the OFFERED options (levels or `"default"`),
  `false` for anything else — including `"max"` (an alias, not an option).

  Delegates to the core (`EvoGit.Config.Schema.LLM.allowed?/1`), which already
  trims, ignores case and accepts atoms or strings.
  """
  @spec allowed?(term()) :: boolean()
  def allowed?(value) do
    LLM.allowed?(value)
  end

  @doc """
  The canonical level for any accepted input as a STRING, or `nil` when the
  input is not a known reasoning value.

  Levels pass through (`" High "` → `"high"`), the legacy alias `"max"` /
  `:max` becomes `"xhigh"`, `"default"` stays `"default"`, and `nil` stays
  `nil` (meaning "provider default").
  """
  @spec canonical(term()) :: String.t() | nil
  def canonical(value) do
    case LLM.canonical_reasoning_effort(value) do
      nil -> nil
      effort -> Atom.to_string(effort)
    end
  end

  @doc """
  `true` when `value` canonicalizes to one of `efforts/0` (a real LEVEL, not
  `"default"`), `false` otherwise.

  The alias `"max"` is `true` here because it canonicalizes to `"xhigh"`.
  """
  @spec level?(term()) :: boolean()
  def level?(value) do
    canonical(value) in efforts()
  end

  @doc """
  The human label for a reasoning value (gettext-wrapped).

  Unknown values are returned cleaned (`"ultra"` → `"ultra"`) so a configured
  custom spelling is displayed as the user wrote it instead of disappearing;
  blank/non-string input → `""`.
  """
  @spec label(term()) :: String.t()
  def label(value) do
    case canonical(value) do
      nil -> value |> raw_string() |> String.trim()
      "none" -> gettext("None")
      "minimal" -> gettext("Minimal")
      "low" -> gettext("Low")
      "medium" -> gettext("Medium")
      "high" -> gettext("High")
      "xhigh" -> gettext("Extra high")
      "default" -> gettext("Provider default")
      other -> other
    end
  end

  @doc """
  Normalizes a persisted/edited reasoning INVENTORY (the per-model list of
  supported levels) into a render-ready string list.

  Order-preserving, blank-dropping, case-insensitive dedup, known values
  canonicalized (`" High "` → `"high"`, `"max"` → `"xhigh"`), and UNKNOWN
  configured values KEPT verbatim so a provider-specific level a future core
  release adds is never silently dropped. It never invents a level (an empty
  or non-list input is `[]`) and never turns `"xhigh"` into `"max"`.
  """
  @spec normalize_inventory(term()) :: [String.t()]
  def normalize_inventory(inventory) when is_list(inventory) do
    inventory
    |> Enum.reduce({[], MapSet.new()}, fn entry, {acc, seen} ->
      case entry do
        value when is_binary(value) or is_atom(value) ->
          record_inventory_entry(acc, seen, value)

        _other ->
          {acc, seen}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  def normalize_inventory(_inventory), do: []

  defp record_inventory_entry(acc, seen, value) do
    raw = value |> raw_string() |> String.trim()

    if raw == "" do
      {acc, seen}
    else
      entry = canonical(raw) || raw
      key = String.downcase(entry)

      if MapSet.member?(seen, key) do
        {acc, seen}
      else
        {[entry | acc], MapSet.put(seen, key)}
      end
    end
  end

  @doc """
  The normalized reasoning inventory of a STRING- or atom-keyed account/model
  draft map (`"reasoning_efforts"` / `:reasoning_efforts`).

  Non-map input (or a draft without the key) → `[]`.
  """
  @spec inventory_of(term()) :: [String.t()]
  def inventory_of(draft) do
    draft |> inventory_value() |> normalize_inventory()
  end

  @doc """
  The draft's DEFAULT effort, as a canonical string, but only when it is one
  of the draft's own inventory levels.

  `nil` means "Provider default" — either the draft has no default, or it
  points at a level the model no longer advertises (so a stale default can
  never be rendered as a selectable option).
  """
  @spec default_of(term()) :: String.t() | nil
  def default_of(draft) do
    effort = canonical(default_value(draft))

    if effort != nil and MapSet.member?(MapSet.new(inventory_of(draft)), effort) do
      effort
    else
      nil
    end
  end

  @doc """
  The form input name the inventory multi-select submits under
  (`"reasoning_efforts[]"`, i.e. one list value on the server).
  """
  @spec inventory_input_name() :: String.t()
  def inventory_input_name, do: "reasoning_efforts[]"

  @doc """
  The form input name the per-model default-effort select submits under.
  """
  @spec default_input_name() :: String.t()
  def default_input_name, do: "default_reasoning_effort"

  # ── private ────────────────────────────────────────────────────────────────

  defp inventory_value(%{"reasoning_efforts" => value}), do: value
  defp inventory_value(%{reasoning_efforts: value}), do: value
  defp inventory_value(_draft), do: nil

  defp default_value(%{"default_reasoning_effort" => value}), do: value
  defp default_value(%{default_reasoning_effort: value}), do: value
  defp default_value(_draft), do: nil

  defp raw_string(value) when is_binary(value), do: value

  defp raw_string(value) when is_atom(value) and value not in [nil, true, false],
    do: value |> Atom.to_string() |> String.trim()

  defp raw_string(_value), do: ""
end
