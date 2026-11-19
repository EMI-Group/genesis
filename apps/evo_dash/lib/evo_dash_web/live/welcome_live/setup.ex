defmodule EvoDashWeb.WelcomeLive.Setup do
  @moduledoc """
  Catalog-backed onboarding drafts and canonical provider-profile persistence.

  No legacy model profiles are created or edited here.
  Reads the user file afresh before saving, rather than persisting resolved
  defaults or migration-generated `llm.models` into the user's configuration.

  An account's `"id"`/`"name"` are PROVIDER-derived (`EvoDashWeb.LLMSetup.Identity`):
  the id is a slug of the chosen catalog provider (`"<provider>-<variant>"` when
  a variant is selected) and the name is that provider's display name, plus the
  variant's when one is selected.
  Both are uniquified against the accounts already in the file, so a second
  account of one provider becomes `"zai-2"` rather than a duplicate key, and a
  model name never leaks into either field.
  The profile's `"provider"` stays the resolved WIRE atom string — runtime
  identity, orthogonal to id/name.

  The reasoning inventory and the reasoning default are independent: selecting
  a default never reduces the efforts offered to later task picks, and a model
  that declares no inventory keeps `[]` (unrestricted) in its persisted row.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.LLMSetup.{Identity, Reasoning, Schedule}
  alias EvoDashWeb.WelcomeLive.Wizard, as: Draft
  alias EvoGit.Config.LLMCatalog, as: Catalog
  alias EvoGit.Config.Schema

  @auth_modes ~w(api_key oauth)
  @variant_separator " · "
  # Account keys a schedule may never write (identity, auth and model keys).
  @identity_keys ~w(id name provider auth_mode models default_model api_key_env_var oauth_file)
  @selection_error "Choose models and a default model from the selected provider."

  # ── Reasoning vocabulary ───────────────────────────────────────────────────

  @doc "The canonical reasoning ladder as strings (six levels, never `\"max\"`/`\"default\"`)."
  @spec reasoning_efforts() :: [String.t()]
  def reasoning_efforts, do: Reasoning.efforts()

  @doc """
  An entry's reasoning inventory for DISPLAY: normalized, and the canonical
  ladder when the entry declares none.

  Display only — `prepare/3` persists `[]` for a model that declares an empty
  inventory (an empty inventory is unrestricted, not unsupported).
  """
  @spec reasoning_efforts(term()) :: [String.t()]
  def reasoning_efforts(entry) do
    case declared_inventory(entry) do
      [] -> Reasoning.efforts()
      inventory -> inventory
    end
  end

  # ── Catalog projections ────────────────────────────────────────────────────

  def flatten_models(providers) do
    providers
    |> Enum.reject(&(&1[:custom_model] == true))
    |> Enum.flat_map(fn provider ->
      for variant <- provider[:variants] || [nil], model <- provider.models do
        resolved =
          Catalog.resolve_provider_atom(hd(provider.provider_atoms), variant && variant.id)

        declared = declared_model_inventory(model)

        %{
          provider_id: provider.id,
          provider_display_name: provider.display_name,
          variant_id: variant && variant.id,
          variant_display_name: variant && variant.display_name,
          credential_key: if(variant, do: variant.credential_key, else: provider.credential_key),
          model_id: model.id,
          model_display_name: model.display_name,
          reasoning_efforts: display_inventory(declared),
          declared_reasoning_efforts: declared,
          resolved_atom: resolved,
          model_string: "#{resolved}:#{model.id}"
        }
      end
    end)
  end

  def provider_models(entries, provider_id, variant_id) do
    Enum.filter(entries, &(&1.provider_id == provider_id and &1.variant_id == variant_id))
  end

  def filtered_models(entries, query) do
    needle = String.downcase(String.trim(query || ""))

    Enum.filter(entries, fn entry ->
      String.contains?(String.downcase(entry.model_display_name), needle) or
        String.contains?(String.downcase(entry.variant_display_name || ""), needle)
    end)
  end

  def has_model?(config), do: Schema.model_selections(config) != []

  @doc """
  The default authentication mode for a provider: `"oauth"` when the catalog
  marks it OAuth-only, `"api_key"` otherwise (the catalog's own default for
  providers that declare no auth modes).

  Total: accepts the resolved wire provider atom, a catalog entry map, or
  `nil` / an unknown term (which is never OAuth-only, so it yields `"api_key"`).
  `EvoGit.Config.LLMCatalog.oauth_only?/1` is atom-only, hence the normalization.
  """
  def auth_mode(provider) do
    case provider_atom(provider) do
      nil -> "api_key"
      atom -> if Catalog.oauth_only?(atom), do: "oauth", else: "api_key"
    end
  end

  def can_save?(assigns) do
    entry = assigns.selected_entry

    entry != nil and
      (assigns.auth_mode == "oauth" or String.trim(assigns.api_key_input) != "" or
         Map.get(assigns.credentials, entry.credential_key) not in [nil, ""])
  end

  # ── Draft validation & persistence ─────────────────────────────────────────

  @doc """
  Validates every draft field before either credentials or config can be written.

  A nonblank value in `params` wins over the matching assign, so the caller may
  either edit the draft itself (`custom_model`, `reasoning_efforts`,
  `default_reasoning_effort`, `base_url`, `api_key`, `auth_mode`, `schedule`) or
  submit it with the form.

  On success returns `{:ok, config, profile, default_entry, trimmed_api_key}`:
  the raw file config with the new profile appended and `default_provider_profile`
  set to its id, the profile itself, the default model's entry (a synthesized
  entry for a free-text custom model) and the trimmed API key — never written
  here.
  Errors carry schema PATHS only, because validation records include raw config
  values, potentially credentials.
  """
  def prepare(config, assigns, params) do
    draft = draft(assigns, params)

    with :ok <- validate_selection(draft),
         :ok <- validate_auth(draft),
         :ok <- validate_api_key(draft),
         :ok <- validate_base_url(draft),
         :ok <- validate_reasoning(draft) do
      profile = build_profile(config, draft)
      llm = value(config, :llm) || %{}
      providers = value(llm, :providers) || []
      llm = llm |> delete_key(:providers) |> delete_key(:default_provider_profile)

      llm =
        Map.merge(llm, %{
          providers: providers ++ [profile],
          default_provider_profile: profile["id"]
        })

      config = config |> delete_key(:llm) |> Map.put(:llm, llm)

      case Schema.validate(config) do
        {:ok, _} -> {:ok, config, profile, draft.default_entry, draft.api_key}
        {:error, errors} -> {:error, invalid_configuration(errors)}
      end
    end
  end

  @doc "Read without defaults/migrations; malformed or unreadable files must never be overwritten."
  def read_config do
    case File.read(EvoGit.Config.config_path()) do
      {:ok, text} ->
        case TomlElixir.decode(text) do
          {:ok, config} ->
            {:ok, config}

          {:error, reason} ->
            {:error, gettext("Cannot read configuration: %{reason}", reason: inspect(reason))}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, gettext("Cannot read configuration: %{reason}", reason: inspect(reason))}
    end
  end

  @doc """
  Resolves a validated draft into `{reqllm_model, generation_params}` for the
  server-side connection-test worker, using the same canonical resolver as tasks.

  Neither the resolved config nor generation params may be pushed to a client.
  The resolver's `model_spec` is a ReqLLM identifier, NOT a canonical task-picker
  map. Invalid drafts raise here and are reported by the worker's SafeCall boundary.
  """
  def test_request(profile, entry, reasoning) do
    config = %{llm: %{providers: [profile], default_provider_profile: profile["id"]}}
    spec = %{"provider_profile_id" => profile["id"], "model" => value(entry, :model_id)}
    effort = reasoning |> reasoning_map() |> Map.get(value(entry, :model_string), "")
    spec = if effort == "", do: spec, else: Map.put(spec, "reasoning_effort", effort)
    {:ok, resolved} = Schema.resolve_model_spec(config, spec)
    {resolved.model_spec, resolved.generation_params}
  end

  def write(fun) do
    case EvoDash.SafeCall.run(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  def value(_, _), do: nil
  defp delete_key(map, key), do: map |> Map.delete(key) |> Map.delete(Atom.to_string(key))

  # ── Draft assembly ─────────────────────────────────────────────────────────

  defp draft(assigns, params) do
    provider_id = Map.get(assigns, :selected_provider_id)
    variant_id = Map.get(assigns, :selected_variant_id)
    requested = selected_model_strings(assigns)

    selected =
      provider_models(Map.get(assigns, :flat_models) || [], provider_id, variant_id)
      |> Enum.filter(&(&1.model_string in requested))

    custom = custom_model(assigns, params)
    atom = resolved_atom(provider_id, variant_id, selected)
    catalog_id = catalog_provider_atom(provider_id, selected)
    credential_key = credential_key(selected, provider_id, variant_id)
    inventory = Reasoning.normalize_inventory(inventory_input(assigns, params))
    effort = custom_effort(effort_input(assigns, params), inventory)
    reasoning = reasoning_map(Map.get(assigns, :model_reasoning))

    draft = %{
      provider_id: provider_id,
      variant_id: variant_id,
      requested: requested,
      selected: selected,
      custom_model: custom,
      custom_inventory: inventory,
      custom_effort: effort,
      efforts: Map.new(selected, &{&1.model_string, model_effort(reasoning, &1)}),
      reasoning: reasoning,
      auth_mode: auth_mode_input(assigns, params),
      api_key: text_input(assigns, params, "api_key", :api_key_input),
      base_url: text_input(assigns, params, "base_url", :base_url_input),
      credentials: Map.get(assigns, :credentials),
      schedule: schedule_input(assigns, params),
      resolved_atom: atom,
      catalog_provider_id: catalog_id,
      credential_key: credential_key
    }

    Map.put(draft, :default_entry, default_entry(draft, atom, custom))
  end

  defp default_entry(draft, atom, custom) do
    choice = text(Map.get(draft, :default_model_choice) || draft_choice(draft))
    found = Enum.find(draft.selected, &(&1.model_string == choice))

    cond do
      found != nil -> found
      choice == "" and draft.selected != [] -> hd(draft.selected)
      custom != "" and (choice == "" or choice == custom) -> custom_entry(draft, atom)
      true -> nil
    end
  end

  # ── Input readers (params win over assigns; blank counts as absent) ────────

  # Whitelisted client key → assign key. Never `String.to_atom/1` on input.
  @input_keys %{
    "api_key" => :api_key_input,
    "api_key_input" => :api_key_input,
    "base_url" => :base_url_input,
    "base_url_input" => :base_url_input,
    "auth_mode" => :auth_mode,
    "custom_model" => :custom_model,
    "reasoning_efforts" => :reasoning_efforts,
    "default_reasoning_effort" => :default_reasoning_effort,
    "default_model" => :default_model,
    "schedule" => :schedule
  }
  @schedule_atom_keys %{
    "concurrency" => :concurrency,
    "peak_concurrency" => :peak_concurrency,
    "peak_hours" => :peak_hours,
    "timezone" => :timezone,
    "off_peak_days" => :off_peak_days,
    "off_peak_holidays" => :off_peak_holidays
  }

  defp input(assigns, params, key) do
    case present_value(params, key) do
      nil -> assign_value(assigns, key)
      value -> value
    end
  end

  defp assign_value(assigns, key) when is_map(assigns) do
    atom = Map.get(@input_keys, key)
    assigns |> Map.get(atom, Map.get(assigns, key)) |> blank_to_nil()
  end

  defp assign_value(_assigns, _key), do: nil

  defp present_value(map, key) when is_map(map) do
    map |> Map.get(key, Map.get(map, Map.get(@input_keys, key))) |> blank_to_nil()
  end

  defp present_value(_map, _key), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp blank_to_nil(value), do: value

  defp text_input(assigns, params, key, fallback) do
    case input(assigns, params, key) do
      nil ->
        if is_binary(Map.get(assigns, fallback)),
          do: String.trim(Map.get(assigns, fallback)),
          else: ""

      value when is_binary(value) ->
        String.trim(value)

      value ->
        to_string(value)
    end
  end

  defp custom_model(assigns, params),
    do: text_input(assigns, params, "custom_model", :custom_model)

  defp auth_mode_input(assigns, params) do
    candidate = text(input(assigns, params, "auth_mode"))
    fallback = text(assigns |> Map.get(:auth_mode, "api_key"))

    cond do
      candidate in @auth_modes -> candidate
      fallback in @auth_modes -> fallback
      true -> "api_key"
    end
  end

  defp inventory_input(assigns, params), do: input(assigns, params, "reasoning_efforts")
  defp effort_input(assigns, params), do: input(assigns, params, "default_reasoning_effort")
  defp schedule_input(assigns, params), do: input(assigns, params, "schedule")

  defp custom_effort(value, _inventory) do
    effort = Reasoning.canonical(text(value))
    if Reasoning.level?(effort), do: effort, else: ""
  end

  defp model_effort(reasoning, entry) do
    effort =
      reasoning
      |> Map.get(entry.model_string)
      |> Draft.model_default_effort()
      |> Reasoning.canonical()

    if Reasoning.level?(effort), do: effort, else: ""
  end

  # Key normalization ONLY: an entry keeps its recorded shape (the nested
  # `%{"efforts" => [...], "default" => ...}` map a catalog pick writes, or a
  # flat effort string), because `Wizard.model_default_effort/1` is the ONE
  # unwrap — flattening it here is what used to drop a catalog default.
  defp reasoning_map(value) when is_map(value) do
    Map.new(value, fn {key, entry} -> {to_string(key), entry} end)
  end

  defp reasoning_map(_value), do: %{}

  # ── Inventory helpers ──────────────────────────────────────────────────────

  defp declared_inventory(entry) when is_map(entry) do
    entry
    |> Map.get(:declared_reasoning_efforts, Map.get(entry, "declared_reasoning_efforts"))
    |> Reasoning.normalize_inventory()
  end

  defp declared_inventory(_entry), do: []

  defp display_inventory(declared) do
    case Reasoning.normalize_inventory(declared) do
      [] -> Reasoning.efforts()
      inventory -> inventory
    end
  end

  defp declared_model_inventory(model) when is_map(model) do
    model
    |> Map.get(:reasoning_efforts, Map.get(model, "reasoning_efforts"))
    |> Reasoning.normalize_inventory()
  end

  defp declared_model_inventory(_model), do: []

  defp selected_model_strings(assigns) do
    case Map.get(assigns, :selected_models) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _other -> []
    end
  end

  # ── Catalog lookups (tolerate an id atom OR the catalog provider map) ──────

  defp provider_atom(provider) when is_atom(provider) and not is_nil(provider), do: provider

  defp provider_atom(%{} = provider),
    do: Map.get(provider, :id) || List.first(Map.get(provider, :provider_atoms) || [])

  defp provider_atom(_provider), do: nil

  defp catalog_provider(provider_id) do
    case provider_atom(provider_id) do
      nil ->
        nil

      atom ->
        Enum.find(Catalog.providers(), fn provider ->
          provider.id == atom or atom in (provider[:provider_atoms] || [])
        end)
    end
  end

  defp catalog_provider_atom(provider_id, selected) do
    provider_atom(provider_id) || selected |> List.first() |> entry_provider_id()
  end

  defp entry_provider_id(%{provider_id: id}) when is_atom(id) and not is_nil(id), do: id
  defp entry_provider_id(_entry), do: nil

  defp resolved_atom(provider_id, variant_id, selected) do
    case List.first(selected) do
      %{resolved_atom: atom} when is_atom(atom) and not is_nil(atom) -> atom
      _other -> catalog_atom(provider_id, variant_id)
    end
  end

  defp catalog_atom(provider_id, variant_id) do
    case provider_atom(provider_id) do
      nil -> nil
      atom -> Catalog.resolve_provider_atom(atom, variant_id)
    end
  end

  defp credential_key(selected, provider_id, variant_id) do
    case List.first(selected) do
      %{credential_key: key} when is_binary(key) ->
        key

      _other ->
        case catalog_provider(provider_id) do
          nil ->
            nil

          provider ->
            case Enum.find(provider[:variants] || [], &(&1.id == variant_id)) do
              nil -> provider.credential_key
              variant -> variant.credential_key
            end
        end
    end
  end

  defp custom_entry(draft, atom) do
    %{
      provider_id: atom,
      provider_display_name: nil,
      variant_id: draft.variant_id,
      variant_display_name: nil,
      credential_key: draft.credential_key,
      model_id: draft.custom_model,
      model_display_name: draft.custom_model,
      reasoning_efforts: display_inventory(draft.custom_inventory),
      declared_reasoning_efforts: draft.custom_inventory,
      resolved_atom: atom,
      model_string: draft.custom_model
    }
  end

  # ── Profile construction ───────────────────────────────────────────────────

  defp build_profile(config, draft) do
    existing = existing_accounts(config)

    profile = %{
      "id" =>
        Identity.unique_id(
          Identity.provider_slug(identity_base(draft)),
          Identity.account_ids(existing)
        ),
      "name" => Identity.unique_name(identity_display(draft), Identity.account_names(existing)),
      "provider" => to_string(draft.resolved_atom),
      "auth_mode" => draft.auth_mode,
      "default_model" => value(draft.default_entry, :model_id),
      "models" => model_rows(draft)
    }

    profile
    |> maybe_put("base_url", draft.base_url)
    |> merge_schedule(draft.schedule)
  end

  defp existing_accounts(config) do
    case value(value(config, :llm) || %{}, :providers) do
      providers when is_list(providers) -> providers
      _other -> []
    end
  end

  defp identity_base(draft) do
    base = Identity.provider_slug(provider_atom(draft.provider_id) || "")

    case draft.variant_id do
      nil -> base
      variant -> "#{base}-#{variant}"
    end
  end

  defp identity_display(draft) do
    base = Identity.provider_display_name(provider_atom(draft.provider_id) || "")

    case variant_display_name(draft) do
      nil -> base
      variant -> base <> @variant_separator <> variant
    end
  end

  defp variant_display_name(draft) do
    with %{} = provider <- catalog_provider(draft.provider_id),
         %{display_name: name} <-
           Enum.find(provider[:variants] || [], &(&1.id == draft.variant_id)) do
      name
    else
      _other -> nil
    end
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp model_rows(draft) do
    rows = Enum.map(draft.selected, &catalog_row(&1, Map.get(draft.efforts, &1.model_string, "")))
    if draft.custom_model == "", do: rows, else: rows ++ [custom_row(draft)]
  end

  defp catalog_row(entry, effort) do
    %{
      "model" => entry.model_id,
      "reasoning_efforts" => display_inventory(declared_inventory(entry))
    }
    |> put_effort(effort)
  end

  defp custom_row(draft) do
    %{"model" => draft.custom_model, "reasoning_efforts" => draft.custom_inventory}
    |> put_effort(draft.custom_effort)
  end

  defp put_effort(row, effort) do
    if Reasoning.level?(effort) and effort != "default",
      do: Map.put(row, "default_reasoning_effort", effort),
      else: row
  end

  # Only `Schedule.schedule_keys/0` keys PRESENT in the draft map land in the
  # account, deep-string-keyed; identity/auth/model keys are unreachable here.
  defp merge_schedule(profile, schedule) when is_map(schedule) and map_size(schedule) > 0 do
    Enum.reduce(Schedule.schedule_keys(), profile, fn key, acc ->
      case schedule_value(schedule, key) do
        nil -> acc
        _value when key in @identity_keys -> acc
        value -> Map.put(acc, key, stringify(value))
      end
    end)
  end

  defp merge_schedule(profile, _schedule), do: profile

  defp schedule_value(schedule, key) do
    schedule
    |> Map.get(key, Map.get(schedule, Map.get(@schedule_atom_keys, key)))
    |> blank_to_nil()
  end

  defp stringify(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)

  defp stringify(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp stringify(value), do: value

  # ── Validation ─────────────────────────────────────────────────────────────

  defp validate_selection(draft) do
    if value(draft.default_entry, :model_id) in [nil, ""],
      do: {:error, gettext(@selection_error)},
      else: :ok
  end

  defp validate_auth(draft) do
    if draft.auth_mode in @auth_modes,
      do: :ok,
      else: {:error, gettext("Choose a supported authentication mode.")}
  end

  defp validate_api_key(draft) do
    existing = credentials(draft.credentials, draft.credential_key)

    cond do
      draft.auth_mode == "oauth" -> :ok
      draft.api_key != "" -> :ok
      existing not in [nil, ""] -> :ok
      # zh_CN: API key 必填（未保存过凭据时）
      true -> {:error, gettext("Enter an API key.")}
    end
  end

  defp credentials(credentials, key) when is_map(credentials) and is_binary(key),
    do: Map.get(credentials, key)

  defp credentials(_credentials, _key), do: nil

  defp validate_base_url(draft) do
    if requires_base_url?(draft.provider_id) and draft.base_url == "",
      # zh_CN: 自定义端点提供方必须填写 Base URL
      do: {:error, gettext("Enter a base URL for this provider.")},
      else: :ok
  end

  defp requires_base_url?(provider_id) do
    case provider_atom(provider_id) do
      nil ->
        false

      atom ->
        function_exported?(Catalog, :requires_base_url?, 1) and Catalog.requires_base_url?(atom)
    end
  end

  defp validate_reasoning(draft) do
    declared =
      Enum.map(
        draft.selected,
        &{declared_inventory(&1), Map.get(draft.efforts, &1.model_string, "")}
      )

    custom =
      if draft.custom_model == "", do: [], else: [{draft.custom_inventory, draft.custom_effort}]

    if Enum.all?(declared ++ custom, fn {inventory, effort} ->
         valid_effort?(inventory, effort)
       end),
       # zh_CN: 推理强度取值为无效值
       do: :ok,
       else: {:error, gettext("Invalid reasoning effort.")}
  end

  defp valid_effort?(_inventory, effort) when effort in [nil, ""], do: true

  defp valid_effort?(inventory, effort),
    do: Reasoning.level?(effort) and (inventory == [] or effort in inventory)

  defp invalid_configuration(errors) do
    paths = errors |> List.wrap() |> Enum.map(&error_path/1) |> Enum.reject(&(&1 == ""))

    # zh_CN: 校验失败，仅列出字段路径（不包含任何配置值）
    gettext("Invalid configuration: %{paths}", paths: Enum.join(paths, ", "))
  end

  defp error_path({path, _message}), do: path_string(path)
  defp error_path(%{path: path}), do: path_string(path)
  defp error_path(path), do: path_string(path)

  defp path_string(path) when is_binary(path), do: path
  defp path_string(path) when is_list(path), do: Enum.map_join(path, ".", &path_string/1)
  defp path_string(path) when is_atom(path) and not is_nil(path), do: Atom.to_string(path)
  defp path_string(_path), do: ""

  defp text(value) when is_binary(value), do: String.trim(value)

  defp text(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp text(_value), do: ""

  defp draft_choice(_draft), do: ""
end
