defmodule EvoDashWeb.WelcomeLive.Wizard do
  @moduledoc """
  The DRAFT model and the pure transitions behind the `/welcome` wizard: the page
  keeps ONE string-keyed draft and renders it, so every transition lives here.

      %{
        "provider" => "anthropic",        # catalog provider id STRING, "custom", nil
        "variant" => nil,                 # catalog variant id STRING, or nil
        "auth_mode" => "api_key",         # "api_key" | "oauth"
        "base_url" => "",
        "api_key" => "",                  # transient: never persisted by this module
        "models" => [],                   # ordered "<resolved_atom>:<model_id>"
        "custom_model" => "",             # free-text name for any other model
        "default_model" => nil,           # a model string OR the custom name
        "model_reasoning" => %{},         # %{model_or_custom_name => effort | ""}
        "reasoning_efforts" => [],        # chips for the CUSTOM model name
        "default_reasoning_effort" => "", # custom name's default ("" = provider)
        "schedule" => %{},                # string-keyed schedule subset
        "schedule_snapshot" => nil,       # pre-preset snapshot for undo
        "preset_id" => nil                # the applied preset id
      }

  Every key is a STRING; `put/3` accepts an atom or string key from that STATIC
  whitelist and never interns an atom from caller input.

  Step order, navigation maths and the per-step gates are delegated to
  `EvoDashWeb.LLMSetup.Wizard` (`:provider → [:auth] → :model →
  :reasoning_schedule → :test → :done`, `:auth` only for a REAL auth choice);
  the reasoning ladder, provider display names and the schedule presets/undo
  cycle/holidays belong to `EvoDashWeb.LLMSetup.Reasoning`, `.Identity` and
  `.Schedule` and are never copied. The only extra reads are the core catalog's
  PURE tables (`EvoGit.Config.LLMCatalog`), compared as STRINGS.

  Pure and total: no I/O, no process, no clock, no persisted state, no
  `try/rescue`; `nil`/wrongly-typed input degrades to `%{}`, `[]`, `nil` or the
  input unchanged, and nothing raises.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.LLMSetup.{Identity, Reasoning, Schedule}
  alias EvoDashWeb.LLMSetup.Wizard, as: Steps
  alias EvoGit.Config.LLMCatalog, as: Catalog

  # The draft keys `put/3` accepts (static table: caller input never interns).
  @draft_keys ~w(
    provider variant auth_mode base_url api_key models custom_model default_model
    model_reasoning reasoning_efforts default_reasoning_effort schedule
    schedule_snapshot preset_id
  )

  # No auth choice and a required endpoint: the OpenAI-compatible row, and a
  # provider that is not (yet) resolvable at all.
  @custom_capabilities %{
    auth_choice?: false,
    auth_modes: ["api_key"],
    oauth_only?: false,
    requires_base_url?: true
  }

  # No provider picked yet: the page still shows the WHOLE plan.
  @open_capabilities %{
    auth_choice?: true,
    auth_modes: ["api_key", "oauth"],
    oauth_only?: false,
    requires_base_url?: false
  }

  @doc "An empty draft: no provider, API-key authentication, no model, no schedule."
  def new do
    %{
      "provider" => nil,
      "variant" => nil,
      "auth_mode" => "api_key",
      "base_url" => "",
      "api_key" => "",
      "models" => [],
      "custom_model" => "",
      "default_model" => nil,
      "model_reasoning" => %{},
      "reasoning_efforts" => [],
      "default_reasoning_effort" => "",
      "schedule" => %{},
      "schedule_snapshot" => nil,
      "preset_id" => nil
    }
  end

  @doc "`new/0` seeded with a provider id string (`\"anthropic\"`, `\"custom\"`)."
  def new(provider) do
    case clean(provider) do
      "" -> new()
      id -> Map.put(new(), "provider", id)
    end
  end

  @doc "Puts `value` under `key` (atom/string, whitelisted); an unknown key leaves the draft unchanged."
  def put(draft, key, value) do
    case key_string(key) do
      nil -> ensure_map(draft)
      key -> Map.put(ensure_map(draft), key, value)
    end
  end

  @doc "The auth/endpoint capabilities of a catalog entry: `%{auth_choice?, auth_modes, oauth_only?, requires_base_url?}`. A `\"custom\"`/nil/non-map entry answers API-key + a required base URL; pure over the GIVEN data (no catalog lookup, no atom interning)."
  def capabilities(entry) when is_map(entry) do
    modes = auth_modes(entry)

    %{
      auth_choice?: length(modes) > 1,
      auth_modes: modes,
      oauth_only?: modes == ["oauth"],
      requires_base_url?: entry_value(entry, :requires_base_url, "requires_base_url") == true
    }
  end

  def capabilities(_entry), do: @custom_capabilities

  @doc "The ordered step list, from a capabilities map OR a draft (a draft follows its provider's capabilities)."
  def steps(input), do: input |> capabilities_for() |> Steps.steps_for()

  @doc "The gate for leaving `step`, delegating `:auth`/`:model`/`:reasoning_schedule` to `EvoDashWeb.LLMSetup.Wizard`; `:test`/`:done`/unknown → `:ok`."
  def validate(step, draft, capabilities \\ nil)

  def validate(:provider, draft, capabilities) do
    draft = ensure_map(draft)

    cond do
      blank?(Map.get(draft, "provider")) ->
        {:error, :missing_provider}

      requires_base_url?(draft, capabilities) and blank?(Map.get(draft, "base_url")) ->
        {:error, :missing_base_url}

      true ->
        :ok
    end
  end

  def validate(step, draft, _capabilities) when step in [:auth, :model, :reasoning_schedule],
    do: Steps.validate(step, step_draft(draft))

  def validate(_step, _draft, _capabilities), do: :ok

  @doc "`true` when `validate/2` answers `:ok` — a button's `disabled`."
  def valid?(step, draft), do: validate(step, draft) == :ok

  @doc "The capabilities-aware `valid?/2`."
  def valid?(step, draft, capabilities), do: validate(step, draft, capabilities) == :ok

  @doc "The step after `current` in this draft's step list (clamped; `nil` off-run). The current step lives in the page, so it is an argument."
  def next_step(draft, current), do: Steps.next(steps(draft), current)

  @doc "The step before `current` (clamped to the first step)."
  def prev_step(draft, current), do: Steps.back(steps(draft), current)

  @doc "`{current, total, percent}` for the progress rail over this draft's steps."
  def progress(draft, current), do: Steps.progress(steps(draft), current)

  @doc "The canonical reasoning ladder for the custom-model chip group (`EvoDashWeb.LLMSetup.Reasoning.efforts/0`, never a local copy)."
  def reasoning_choices, do: Reasoning.efforts()

  @doc "The DISPLAYED chip inventory of a persisted `reasoning_efforts`: normalized, with an UNRESTRICTED empty inventory expanded to the ladder for display only (reading never changes the persisted `[]`)."
  def reasoning_choices(inventory) do
    case Reasoning.normalize_inventory(inventory) do
      [] -> Reasoning.efforts()
      levels -> levels
    end
  end

  @doc "`EvoDashWeb.LLMSetup.Schedule.schedule_keys/0` — the keys a preset touches."
  def schedule_keys, do: Schedule.schedule_keys()

  @doc "Applies a schedule preset, returning `{draft, pre_apply_snapshot}`; only `\"schedule\"`, `\"schedule_snapshot\"` and `\"preset_id\"` change, and an unknown id leaves everything unchanged."
  def apply_preset(draft, preset_id) do
    draft = ensure_map(draft)
    current = schedule_map(draft)
    snapshot = Schedule.snapshot(current)
    id = normalize_id(preset_id)

    case Schedule.preset(id) do
      %{} = preset ->
        {applied, _before} = Schedule.apply(preset, current)

        {draft
         |> Map.put("schedule", applied)
         |> Map.put("schedule_snapshot", snapshot)
         |> Map.put("preset_id", id), snapshot}

      _unknown ->
        {draft, snapshot}
    end
  end

  @doc "Restores the pre-preset schedule (`EvoDashWeb.LLMSetup.Schedule.undo/2`) and clears the applied-preset bookkeeping; idempotent when nothing was applied."
  def undo_preset(draft) do
    draft = ensure_map(draft)
    snapshot = Map.get(draft, "schedule_snapshot")

    draft =
      if is_map(snapshot),
        do: Map.put(draft, "schedule", Schedule.undo(schedule_map(draft), snapshot)),
        else: draft

    draft |> Map.put("schedule_snapshot", nil) |> Map.put("preset_id", nil)
  end

  @doc "`%{applied?: boolean, preset: map | nil, changed?: boolean}` for the \"Recommended schedule applied\" strip; `changed?` compares the draft's schedule with the APPLIED PRESET's own (`\"schedule_snapshot\"` is only the undo reference)."
  def preset_state(draft) do
    draft = ensure_map(draft)
    preset = Schedule.preset(normalize_id(Map.get(draft, "preset_id")))
    applied? = is_map(preset)

    %{
      applied?: applied?,
      preset: if(applied?, do: preset, else: nil),
      changed?: applied? and Schedule.changed?(schedule_map(draft), Map.get(preset, :schedule))
    }
  end

  @doc "`EvoDashWeb.LLMSetup.Schedule.summary_rows/1` over the draft's schedule."
  def schedule_rows(draft), do: Schedule.summary_rows(schedule_map(draft))

  @doc "The selected off-peak holiday calendar (e.g. `\"CN\"`), or `nil`."
  def holiday_value(draft), do: draft |> schedule_map() |> Map.get("off_peak_holidays")

  @doc "Adds `model_string` to the draft's catalog picks, or removes it when present; `\"default_model\"` stays valid (first remaining selection, else `nil`) and `\"model_reasoning\"` is pruned to the survivors."
  def toggle_model(draft, model_string) do
    draft = ensure_map(draft)

    case clean(model_string) do
      "" ->
        draft

      model ->
        models = model_list(draft)
        models = if model in models, do: List.delete(models, model), else: models ++ [model]

        draft
        |> Map.put("models", models)
        |> keep_default_valid()
        |> prune_reasoning()
    end
  end

  @doc "Sets the free-text custom model name (trimmed): a non-blank name becomes the draft's custom model AND — with no valid catalog default yet — its `\"default_model\"`; a blank name clears it and falls back to the first catalog pick."
  def set_custom_model(draft, name) do
    draft = ensure_map(draft)
    name = clean(name)
    models = model_list(draft)
    current = clean(Map.get(draft, "default_model"))

    default =
      cond do
        current != "" and current in models -> current
        name != "" -> name
        models != [] -> hd(models)
        true -> nil
      end

    draft
    |> Map.put("custom_model", name)
    |> Map.put("default_model", default)
    |> prune_reasoning()
  end

  @doc "`{label, value}` rows for the DONE step — provider (with its variant), model, default reasoning, then the schedule rows; blank values are never emitted."
  def summary_rows(draft) do
    draft = ensure_map(draft)

    [
      # zh_CN: Provider → "提供方"; Model → "模型"; Reasoning → "推理"
      {gettext("Provider"), provider_label(draft)},
      {gettext("Model"), model_value(draft)},
      {gettext("Reasoning"), draft |> default_reasoning() |> Reasoning.label()}
    ]
    |> Enum.reject(fn {_label, value} -> blank?(value) end)
    |> Kernel.++(schedule_rows(draft))
  end

  # ── private ───────────────────────────────────────────────────────────────

  defp capabilities_for(input) when is_map(input) do
    keys = [:auth_choice?, :auth_modes, "auth_choice?", "auth_modes"]

    if Enum.any?(keys, &Map.has_key?(input, &1)) do
      input
    else
      case clean(Map.get(input, "provider")) do
        "" -> @open_capabilities
        provider -> capabilities(provider_entry(provider))
      end
    end
  end

  defp capabilities_for(_input), do: @open_capabilities

  defp auth_modes(entry) do
    entry
    |> entry_value(:auth_modes, "auth_modes")
    |> List.wrap()
    |> Enum.map(&normalize_auth_mode/1)
    |> Enum.filter(&(&1 in ["api_key", "oauth"]))
    |> Enum.uniq()
    |> case do
      [] -> ["api_key"]
      modes -> modes
    end
  end

  defp normalize_auth_mode(value) do
    case clean(value) do
      "" -> ""
      mode -> mode |> String.downcase() |> String.replace("-", "_")
    end
  end

  # The draft mapped onto `EvoDashWeb.LLMSetup.Wizard`'s vocabulary.
  defp step_draft(draft) do
    %{
      "provider" => Map.get(draft, "provider"),
      "auth_mode" => Map.get(draft, "auth_mode"),
      "model" => Map.get(draft, "default_model"),
      "custom_model" => Map.get(draft, "custom_model")
    }
  end

  defp requires_base_url?(_draft, capabilities) when is_map(capabilities),
    do: entry_value(capabilities, :requires_base_url?, "requires_base_url?") == true

  defp requires_base_url?(draft, _capabilities) do
    case clean(Map.get(draft, "provider")) do
      "" -> false
      "custom" -> true
      provider -> Map.get(provider_entry(provider) || %{}, :requires_base_url) == true
    end
  end

  # Catalog reads are pure-table lookups compared as STRINGS: no atom interning.
  defp provider_entry(provider) do
    case provider |> clean() |> String.downcase() do
      "" -> nil
      wanted -> Enum.find(Catalog.providers(), &provider_match?(&1, wanted))
    end
  end

  defp provider_match?(entry, wanted) do
    Atom.to_string(entry.id) == wanted or
      Enum.any?(List.wrap(Map.get(entry, :provider_atoms)), &(Atom.to_string(&1) == wanted)) or
      Enum.any?(List.wrap(Map.get(entry, :variants)), &(Atom.to_string(&1.id) == wanted))
  end

  defp provider_label(draft) do
    name = Identity.provider_display_name(Map.get(draft, "provider"))
    variant = variant_display(Map.get(draft, "provider"), clean(Map.get(draft, "variant")))
    if variant, do: name <> " · " <> variant, else: name
  end

  defp variant_display(_provider, ""), do: nil

  defp variant_display(provider, variant) do
    found =
      case provider_entry(provider) do
        %{} = entry ->
          entry
          |> Map.get(:variants)
          |> List.wrap()
          |> Enum.find(&(Atom.to_string(&1.id) == String.downcase(variant)))

        _unknown ->
          nil
      end

    case found do
      %{display_name: name} when is_binary(name) and name != "" -> name
      _unknown -> variant
    end
  end

  defp model_value(draft) do
    case clean(Map.get(draft, "default_model")) do
      "" ->
        nil

      model ->
        case String.split(model, ":", parts: 2) do
          [atom_string, model_id] -> displayed_model(atom_string, model_id) || model
          _parts -> model
        end
    end
  end

  defp displayed_model(atom_string, model_id) do
    with wanted when wanted != "" <- atom_string |> String.trim() |> String.downcase(),
         model_id when model_id != "" <- String.trim(model_id),
         %{} = entry <- Enum.find(Catalog.providers(), &provider_match?(&1, wanted)),
         %{display_name: name} when is_binary(name) and name != "" <-
           Enum.find(entry.models, &(&1.id == model_id)) do
      name
    else
      _unknown -> nil
    end
  end

  # The default's reasoning: the custom model reads its own field, a catalog
  # pick reads the per-model map.
  defp default_reasoning(draft) do
    model = clean(Map.get(draft, "default_model"))

    cond do
      model == "" -> nil
      model == clean(Map.get(draft, "custom_model")) -> Map.get(draft, "default_reasoning_effort")
      true -> Map.get(map_field(draft, "model_reasoning"), model)
    end
  end

  defp model_list(draft) do
    case Map.get(draft, "models") do
      list when is_list(list) ->
        list
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      _other ->
        []
    end
  end

  defp custom_model_list(draft) do
    case clean(Map.get(draft, "custom_model")) do
      "" -> []
      name -> [name]
    end
  end

  defp map_field(draft, key) do
    case Map.get(ensure_map(draft), key) do
      %{} = map -> map
      _other -> %{}
    end
  end

  defp schedule_map(draft), do: map_field(draft, "schedule")

  defp keep_default_valid(draft) do
    selections = model_list(draft) ++ custom_model_list(draft)
    current = clean(Map.get(draft, "default_model"))

    default =
      if current != "" and current in selections, do: current, else: List.first(selections)

    Map.put(draft, "default_model", default)
  end

  defp prune_reasoning(draft) do
    keep = MapSet.new(model_list(draft) ++ custom_model_list(draft))

    reasoning =
      draft
      |> map_field("model_reasoning")
      |> Enum.filter(fn {model, _effort} -> MapSet.member?(keep, model) end)
      |> Map.new()

    Map.put(draft, "model_reasoning", reasoning)
  end

  defp key_string(key) when is_atom(key) and key not in [nil, true, false],
    do: key_string(Atom.to_string(key))

  defp key_string(key) when is_binary(key) do
    key = String.trim(key)
    if key in @draft_keys, do: key
  end

  defp key_string(_key), do: nil

  defp entry_value(%{} = entry, atom_key, string_key),
    do: Map.get(entry, atom_key, Map.get(entry, string_key))

  defp entry_value(_entry, _atom_key, _string_key), do: nil

  defp normalize_id(value) do
    case clean(value) do
      "" -> nil
      id -> id
    end
  end

  defp ensure_map(draft) when is_map(draft), do: draft
  defp ensure_map(_draft), do: %{}

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp clean(nil), do: ""
  defp clean(value) when is_binary(value), do: String.trim(value)
  defp clean(value) when is_atom(value) and value not in [true, false], do: Atom.to_string(value)
  defp clean(_value), do: ""
end
