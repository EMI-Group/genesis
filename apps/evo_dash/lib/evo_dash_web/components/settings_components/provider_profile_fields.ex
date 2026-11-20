defmodule EvoDashWeb.SettingsComponents.ProviderProfileFields do
  @moduledoc """
  Pure form building blocks for ProviderProfilesEditor.
  No core configuration or credential files are read here.
  """

  use EvoDashWeb, :html

  # The dashboard's SINGLE reasoning-effort vocabulary (levels, labels and the
  # `"max"` → `"xhigh"` canonicalization). Never copy a level list here.
  alias EvoDashWeb.LLMSetup.Reasoning

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :any, default: "")
  attr(:type, :string, default: "text")
  attr(:min, :any, default: nil)
  attr(:max, :any, default: nil)
  attr(:step, :any, default: nil)
  attr(:required, :boolean, default: false)
  attr(:help, :string, default: nil)

  def profile_field(assigns) do
    assigns = assign(assigns, :field_id, field_id(assigns.name))

    ~H"""
    <div class="min-w-0">
      <label for={@field_id} class="mb-1 block text-xs font-medium text-base-content/70">{@label}</label>
      <input
        id={@field_id}
        name={@name}
        type={@type}
        value={@value}
        min={@min}
        max={@max}
        step={@step}
        required={@required}
        aria-describedby={@help && @field_id <> "-help"}
        class="input input-sm w-full min-w-0 rounded-md border-base-300 bg-base-100 font-mono focus-visible:outline-primary-standalone"
      />
      <p
        :if={@help}
        id={@field_id <> "-help"}
        class="mt-1 text-xs leading-relaxed text-base-content/70"
      >
        {@help}
      </p>
    </div>
    """
  end

  attr(:fields, :map, required: true)

  def provider_select(assigns) do
    assigns =
      assigns
      |> assign(:selected, value(assigns.fields, "provider"))
      |> assign(:options, provider_options())

    ~H"""
    <div class="min-w-0">
      <label for="provider-field-provider" class="mb-1 block text-xs font-medium text-base-content/70">
        {gettext("Provider")}
      </label>
      <select id="provider-field-provider" name="provider" required class="select select-sm w-full">
        <option value="" selected={@selected == ""}>{gettext("Choose a provider")}</option>
        <option
          :if={@selected != "" and not Enum.any?(@options, fn {id, _} -> id == @selected end)}
          value={@selected}
          selected
        >
          {gettext("Configured provider: %{provider}", provider: @selected)}
        </option>
        <option :for={{id, label} <- @options} value={id} selected={id == @selected}>{label}</option>
      </select>
    </div>
    """
  end

  attr(:prefix, :string, required: true)
  attr(:fields, :map, required: true)
  attr(:model_override, :boolean, default: false)
  attr(:show_default, :boolean, default: true)
  # Advisory only: catalog metadata never changes chip membership or order.
  attr(:suggestions, :list, default: [])

  def reasoning_fields(assigns) do
    inventory = reasoning_inventory(assigns.fields)
    suggested = Reasoning.normalize_inventory(assigns.suggestions)

    # The chip list is STABLE: the canonical vocabulary in canonical order,
    # then any configured custom level appended once at the END. It never
    # depends on the submitted draft order, so a `phx-change` repaint patches
    # the same keyed nodes in the same positions (a positional patch used to
    # rewrite an already-flipped checkbox to a different level).
    assigns =
      assigns
      |> assign(:inventory, inventory)
      |> assign(:chips, reasoning_chips(inventory, suggested, assigns.prefix))
      |> assign(:suggestion_text, suggested |> Enum.map(&Reasoning.label/1) |> Enum.join(", "))
      |> assign(:name, nested(assigns.prefix, "reasoning_efforts") <> "[]")

    ~H"""
    <fieldset class="min-w-0 space-y-3 rounded-xl border border-base-300 p-3">
      <%!-- zh_CN: 推理等级 = 该模型支持的推理强度清单（固定顺序），不是任务速度。 --%>
      <legend class="px-1 text-xs font-semibold">{gettext("Reasoning levels")}</legend>
      <p :if={@suggestion_text == ""} class="text-xs leading-relaxed text-base-content/70">
        {gettext(
          "No verified catalog level list is available for this selection. Pick only the levels you have confirmed with your provider."
        )}
      </p>
      <p :if={@suggestion_text != ""} class="text-xs leading-relaxed text-base-content/70">
        {gettext(
          "Catalog suggestions are advisory: verify support with your provider, and nothing is selected automatically."
        )}
        <span class="font-mono text-base-content/60">{@suggestion_text}</span>
      </p>
      <input type="hidden" name={@name} value="" />
      <div class="flex flex-wrap gap-2">
        <label
          :for={chip <- @chips}
          :key={chip.id}
          class={reasoning_chip_class(chip.checked)}
          title={if chip.suggested, do: gettext("Suggested by the model catalog")}
        >
          <input
            id={chip.id}
            type="checkbox"
            name={@name}
            value={chip.value}
            checked={chip.checked}
            class="checkbox checkbox-xs"
          />
          <span class="text-xs">{chip.label}</span>
          <span :if={chip.suggested} class="text-[10px] text-base-content/50">*</span>
        </label>
      </div>
      <p class="text-xs leading-relaxed text-base-content/70">
        {if @model_override,
          do: gettext("No levels selected explicitly disables reasoning for this model."),
          else:
            gettext(
              "Select only levels supported by your models. No selection advertises no reasoning support."
            )}
      </p>
      <.reasoning_default
        :if={@show_default}
        prefix={@prefix}
        fields={@fields}
        efforts={@inventory}
      />
    </fieldset>
    """
  end

  attr(:prefix, :string, required: true)
  attr(:fields, :map, required: true)
  attr(:efforts, :list, required: true)
  attr(:inherit, :boolean, default: false)

  def reasoning_default(assigns) do
    inventory = default_inventory(assigns)
    selected = selected_default(assigns.fields)

    assigns =
      assigns
      |> assign(:name, nested(assigns.prefix, "default_reasoning_effort"))
      |> assign(:inventory, inventory)
      |> assign(:selected, selected)
      |> assign(:invalid?, selected != "" and selected not in inventory)

    ~H"""
    <div :if={@inventory != [] or @selected != ""} class="min-w-0">
      <%!-- zh_CN: 默认推理等级 → 该模型默认使用的推理强度;跟随提供方 = 不发送该字段 --%>
      <label for={field_id(@name)} class="mb-1 block text-xs font-medium text-base-content/70">{gettext(
        "Default reasoning level"
      )}</label>
      <select
        id={field_id(@name)}
        name={@name}
        class="select select-sm w-full min-w-0 rounded-md border-base-300 bg-base-100"
        aria-describedby={field_id(@name) <> "-help"}
        aria-invalid={if @invalid?, do: "true"}
      >
        <option :if={@inventory != []} value="" selected={@selected == ""}>
          {if @inherit, do: gettext("Inherit provider default"), else: gettext("Provider default")}
        </option>
        <option :if={@invalid?} value={@selected} selected>
          {gettext("Unsupported level: %{level}", level: Reasoning.label(@selected))}
        </option>
        <option :for={effort <- @inventory} value={effort} selected={effort == @selected}>
          {Reasoning.label(effort)}
        </option>
      </select>
      <p id={field_id(@name) <> "-help"} class="mt-1 text-xs text-base-content/70">
        {gettext("Choose a supported level. This is separate from task speed and quality.")}
      </p>
    </div>
    """
  end

  # The configured draft inventory (order-preserving, canonicalized, unknown
  # configured levels kept) — the ONLY membership source for both controls.
  defp reasoning_inventory(fields) do
    fields |> value("reasoning_efforts", []) |> efforts() |> Reasoning.normalize_inventory()
  end

  defp default_inventory(assigns) do
    case Reasoning.normalize_inventory(assigns.efforts) do
      [] -> reasoning_inventory(assigns.fields)
      inventory -> inventory
    end
  end

  defp selected_default(fields) do
    raw = fields |> value("default_reasoning_effort") |> default_text()
    Reasoning.canonical(raw) || raw
  end

  defp default_text(value) when is_binary(value), do: String.trim(value)

  defp default_text(value) when is_atom(value) and value not in [nil, true, false],
    do: value |> Atom.to_string() |> String.trim()

  defp default_text(_value), do: ""

  defp reasoning_chips(inventory, suggested, prefix) do
    selected = MapSet.new(inventory)
    suggested = MapSet.new(suggested)

    canonical =
      Enum.map(Reasoning.efforts(), fn effort ->
        %{value: effort, checked: MapSet.member?(selected, effort)}
      end)

    extras =
      inventory
      |> Enum.reject(&Reasoning.level?/1)
      |> Enum.map(fn value -> %{value: value, checked: true} end)

    (canonical ++ extras)
    |> Enum.map(fn chip ->
      Map.merge(chip, %{
        label: Reasoning.label(chip.value),
        suggested: MapSet.member?(suggested, String.downcase(chip.value)),
        id: reasoning_chip_id(prefix, chip.value)
      })
    end)
    |> Enum.map_reduce(MapSet.new(), fn chip, seen ->
      id = unique_chip_id(chip.id, seen)
      {Map.put(chip, :id, id), MapSet.put(seen, id)}
    end)
    |> elem(0)
  end

  # One stable, prefix-scoped DOM id per chip so morphdom patches in place.
  defp reasoning_chip_id(prefix, value),
    do: "reasoning-" <> chip_scope(prefix) <> chip_slug(value)

  defp chip_scope(prefix) do
    scope =
      prefix
      |> to_string()
      |> String.replace(["[", "]"], "-")
      |> String.replace(~r/-{2,}/, "-")
      |> String.trim("-")

    if scope == "", do: "", else: scope <> "-"
  end

  defp chip_slug(value) do
    slug =
      value
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "-")
      |> String.trim("-")

    if slug == "", do: "level-" <> Integer.to_string(:erlang.phash2(value)), else: slug
  end

  defp unique_chip_id(id, seen), do: unique_chip_id(id, seen, 1)

  defp unique_chip_id(id, seen, suffix) do
    candidate = if suffix == 1, do: id, else: id <> "-" <> Integer.to_string(suffix)

    if MapSet.member?(seen, candidate),
      do: unique_chip_id(id, seen, suffix + 1),
      else: candidate
  end

  defp reasoning_chip_class(true) do
    "flex cursor-pointer items-center gap-1.5 rounded-lg border border-primary bg-primary/5 px-2 py-1"
  end

  defp reasoning_chip_class(_checked?) do
    "flex cursor-pointer items-center gap-1.5 rounded-lg border border-base-300 bg-base-100 px-2 py-1"
  end

  attr(:prefix, :string, required: true)
  attr(:fields, :any, default: %{})

  def generation_fields(assigns) do
    assigns =
      assigns
      |> assign(:parameters, generation_parameters())
      |> assign(:json_fields, [
        {"extra", gettext("Extra config (JSON, optional)")},
        {"provider_options", gettext("Provider options (JSON, optional)")}
      ])

    ~H"""
    <div class="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
      <.profile_field
        :for={{key, label, type, step, min, max} <- @parameters}
        name={nested(@prefix, key)}
        label={label}
        value={value(@fields, key)}
        type={type}
        step={step}
        min={min}
        max={max}
      />
    </div>
    <div :for={{key, label} <- @json_fields} class="mt-3">
      <label
        for={field_id(nested(@prefix, key))}
        class="mb-1 block text-xs font-medium text-base-content/70"
      >{label}</label>
      <textarea
        id={field_id(nested(@prefix, key))}
        name={nested(@prefix, key)}
        rows="3"
        spellcheck="false"
        class="textarea w-full min-w-0 rounded-md border-base-300 bg-base-100 font-mono text-xs"
        aria-describedby={field_id(nested(@prefix, key)) <> "-help"}
      >{json_text(value(@fields, key))}</textarea>
      <p
        id={field_id(nested(@prefix, key)) <> "-help"}
        class="mt-1 text-xs text-base-content/70"
      >
        {gettext(
          "A JSON object of advanced request options. Never paste API keys or login tokens here."
        )}
      </p>
    </div>
    """
  end

  attr(:fields, :map, required: true)

  def provider_schedule(assigns) do
    windows = indexed_rows(value(assigns.fields, "peak_hours", []))
    assigns = assign(assigns, :windows, if(windows == [], do: [{%{}, 0}], else: windows))

    ~H"""
    <details id="provider-peak-schedule" class="rounded-lg border border-base-300 p-3">
      <summary class="cursor-pointer rounded-md text-sm font-medium focus-visible:outline-2 focus-visible:outline-primary-standalone">
        {gettext("Peak / off-peak scheduling (optional)")}
      </summary>
      <p class="mt-2 text-xs leading-relaxed text-base-content/70">
        {gettext(
          "Shared by all models in this profile. A peak capacity of 0 pauses new requests; existing requests continue."
        )}
      </p>
      <div class="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.profile_field
          name="peak_concurrency"
          label={gettext("Peak concurrency")}
          value={value(@fields, "peak_concurrency")}
          type="number"
          min={0}
        />
        <.profile_field
          name="timezone"
          label={gettext("Timezone (optional)")}
          value={value(@fields, "timezone")}
          help={
            gettext(
              "IANA timezone, such as Asia/Shanghai. Blank uses the selected node's local time."
            )
          }
        />
      </div>
      <div class="mt-3">
        <.day_chips
          name="off_peak_days"
          label={gettext("Always off-peak on these days")}
          selected={value(@fields, "off_peak_days", [])}
        />
        <p class="mt-1 text-xs text-base-content/70">
          {gettext("These days ignore every peak window and use normal concurrency all day.")}
        </p>
      </div>
      <fieldset
        :for={{window, index} <- @windows}
        class="mt-3 min-w-0 rounded-md border border-base-300 p-3"
      >
        <legend class="px-1 text-xs font-medium">
          {gettext("Peak window %{number}", number: row_number(index))}
        </legend>
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <.profile_field
            name={"peak_hours[#{index}][start]"}
            label={gettext("Start time")}
            value={value(window, "start")}
            type="time"
          />
          <.profile_field
            name={"peak_hours[#{index}][end]"}
            label={gettext("End time")}
            value={value(window, "end")}
            type="time"
          />
        </div>
        <div class="mt-3">
          <.day_chips
            name={"peak_hours[#{index}][days]"}
            label={gettext("Apply this window on")}
            selected={value(window, "days", [])}
          />
        </div>
        <div class="mt-2 flex flex-wrap items-center justify-between gap-2">
          <p class="text-xs text-base-content/70">
            {gettext("No days selected means every day. End before start crosses midnight.")}
          </p>
          <button
            type="button"
            phx-click="remove_provider_peak_hours_row"
            phx-value-index={index}
            class="btn btn-ghost btn-xs text-error"
            aria-label={gettext("Remove peak window %{number}", number: row_number(index))}
          >{gettext("Remove window")}</button>
        </div>
      </fieldset>
      <button
        type="button"
        phx-click="add_provider_peak_hours_row"
        class="btn btn-ghost btn-sm mt-2 gap-1"
      ><.icon name="hero-plus" class="size-4" />{gettext("Add peak window")}</button>
    </details>
    """
  end

  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:selected, :any, default: [])

  defp day_chips(assigns) do
    assigns =
      assigns |> assign(:days, day_options()) |> assign(:selected, efforts(assigns.selected))

    ~H"""
    <fieldset>
      <legend class="mb-1.5 text-xs font-medium text-base-content/70">{@label}</legend>
      <input type="hidden" name={@name <> "[]"} value="" />
      <div class="flex flex-wrap gap-2">
        <label
          :for={{day, label} <- @days}
          class="flex cursor-pointer items-center gap-1.5 rounded-md border border-base-300 bg-base-100 px-2 py-1 text-xs"
        >
          <input
            type="checkbox"
            name={@name <> "[]"}
            value={day}
            checked={day in @selected}
            class="checkbox checkbox-xs"
          />{label}
        </label>
      </div>
    </fieldset>
    """
  end

  attr(:status, :any, default: nil)
  attr(:profile, :map, required: true)
  attr(:details, :boolean, default: true)
  # Page-owned in-browser ChatGPT sign-in state + the local/remote verdict.
  # TOTAL defaults: every caller (and the collapsed summary row) renders before
  # the page assigns them.
  attr(:chatgpt_sign_in, :map, default: %{})
  attr(:chatgpt_sign_in_manual, :boolean, default: false)

  def provider_auth_status(assigns) do
    state = auth_state(assigns.status)
    chatgpt? = provider_atom(assigns.profile) == :openai_codex
    profile_id = value(assigns.profile, "id")

    assigns =
      assigns
      |> assign(:state, state)
      |> assign(:chatgpt?, chatgpt?)
      |> assign(:profile_id, profile_id)
      |> assign(:slug, EvoDashWeb.SettingsComponents.ProviderProfiles.Row.slug(profile_id))
      |> assign(:chatgpt_command, chatgpt_login_command(assigns.profile))
      |> assign(:label, auth_label(state, value(assigns.status, "expires", nil), chatgpt?))
      |> assign(:path, value(assigns.status, "oauth_file", value(assigns.profile, "oauth_file")))
      |> assign(
        :instructions,
        value(assigns.status, "login_instructions", login_guidance(assigns.profile))
      )
      |> assign(
        :sign_in,
        EvoDashWeb.SettingsComponents.ChatGPTSignInPanel.surface_state(
          assigns.chatgpt_sign_in,
          {:status, profile_id}
        )
      )

    ~H"""
    <div class="mt-3 space-y-2" role="status">
      <div class="flex flex-wrap items-center gap-2">
        <.icon
          name={if @state == :ok, do: "hero-check-circle", else: "hero-information-circle"}
          class={"size-4 shrink-0 " <> auth_tone(@state)}
        />
        <span class={"text-xs font-medium " <> auth_tone(@state)}>{@label}</span>
        <button
          type="button"
          phx-click="refresh_auth_status"
          phx-value-profile_id={value(@profile, "id")}
          class="btn btn-ghost btn-xs gap-1"
          aria-label={gettext("Recheck subscription login")}
        ><.icon name="hero-arrow-path" class="size-3.5" />{gettext("Recheck")}</button>
      </div>
      <div :if={@details} class="space-y-1 text-xs leading-relaxed text-base-content/70">
        <%= cond do %>
          <% @chatgpt? and @state != :ok -> %>
            <EvoDashWeb.SettingsComponents.ChatGPTSignInPanel.sign_in_panel
              id={"provider-status-" <> @slug <> "-chatgpt"}
              surface="status"
              profile_id={@profile_id}
              manual={@chatgpt_sign_in_manual}
              sign_in={@sign_in}
              command={@chatgpt_command}
            />
          <% @chatgpt? -> %>
            <p :if={value(@status, "account_id") != ""}>{value(@status, "account_id")}</p>
          <% @state == :unwritable -> %>
            <p>
              {gettext(
                "Genesis found the vendor login but could not write its managed credential file."
              )}
            </p>
            <p>{gettext("Set oauth_file on this profile to a writable location, then recheck.")}</p>
          <% true -> %>
            <p class="whitespace-pre-wrap">{@instructions}</p>
            <p :if={@state == :missing}>
              {gettext("Genesis imports the vendor login automatically on the next run.")}
            </p>
        <% end %>
        <p :if={@path != ""} class="break-all">
          {gettext("Managed credential file: %{path}", path: @path)}
        </p>
      </div>
    </div>
    """
  end

  # Pure normalization shared by the parent editor; canonical projections are
  # string-keyed, and the whitelist also accepts existing atom-keyed auth maps.
  @keys ~w(id name provider auth_mode oauth_file siwc_account api_key_env_var base_url concurrency default_model models
    context_window reasoning_efforts default_reasoning_effort generation provider_options
    peak_concurrency peak_hours timezone off_peak_days start end days override_reasoning
    profile_id_new temperature max_tokens top_p top_k frequency_penalty presence_penalty
    state expires account_id login_instructions)a
  @atom_keys Map.new(@keys, &{Atom.to_string(&1), &1})

  def value(map, key, default \\ "")

  def value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, nil} ->
        default

      {:ok, value} ->
        value

      :error ->
        case Map.fetch(map, Map.get(@atom_keys, key)) do
          {:ok, nil} -> default
          {:ok, value} -> value
          :error -> default
        end
    end
  end

  def value(_, _, default), do: default

  def indexed_rows(rows) when is_list(rows) do
    rows |> Enum.with_index() |> Enum.filter(fn {row, _} -> is_map(row) end)
  end

  def indexed_rows(rows) when is_map(rows) do
    rows
    |> Enum.filter(fn {index, row} ->
      is_binary(index) and is_map(row) and match?({_, ""}, Integer.parse(index))
    end)
    |> Enum.sort_by(fn {index, _} -> String.to_integer(index) end)
    |> Enum.map(fn {index, row} -> {row, index} end)
  end

  def indexed_rows(_), do: []

  def efforts(list) when is_list(list),
    do:
      list
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

  def efforts(text) when is_binary(text), do: text |> String.split(",") |> efforts()
  def efforts(_), do: []

  @doc "Advisory exact-catalog effort values, never inferred from a reasoning boolean."
  def reasoning_suggestions(profile, model \\ nil) do
    # A custom endpoint may run a different model under the same name. Do not
    # borrow metadata from another provider, regional variant, or Codex route.
    if value(profile, "base_url") != "" do
      []
    else
      names =
        if is_binary(model) do
          [model]
        else
          [
            value(profile, "default_model")
            | Enum.map(indexed_rows(value(profile, "models", [])), fn
                {row, _} -> value(row, "model")
              end)
          ]
        end
        |> efforts()

      names
      |> Enum.map(&catalog_efforts(value(profile, "provider"), &1))
      |> case do
        [] -> []
        [first | rest] -> Enum.filter(first, fn effort -> Enum.all?(rest, &(effort in &1)) end)
      end
    end
  end

  defp catalog_efforts(provider, model) when is_binary(provider) do
    case LLMDB.model({provider, model}) do
      {:ok, entry} ->
        exact? = to_string(entry.provider) == provider and entry.id == model

        case {exact?, get_in(entry.capabilities || %{}, [:reasoning, :effort])} do
          {true, %{supported: true, values: values}} -> efforts(values)
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  defp catalog_efforts(_, _), do: []

  def oauth_only?(profile), do: EvoGit.Config.LLMCatalog.oauth_only?(provider_atom(profile))

  def oauth_supported?(profile),
    do: EvoGit.Config.LLMCatalog.supports_oauth?(provider_atom(profile))

  def oauth?(profile),
    do:
      oauth_only?(profile) or
        (oauth_supported?(profile) and value(profile, "auth_mode") == "oauth")

  defp nested("", key), do: key
  defp nested(prefix, key), do: prefix <> "[" <> key <> "]"
  defp field_id(name), do: "provider-field-" <> String.replace(name, ["[", "]"], "-")
  defp row_number(index) when is_integer(index), do: index + 1
  defp row_number(index), do: String.to_integer(index) + 1
  # Each variant submits its real provider atom; the generic OpenAI-compatible
  # catalog entry shares :openai and is configured through the Advanced endpoint.
  defp provider_options do
    EvoGit.Config.LLMCatalog.providers()
    |> Enum.flat_map(fn entry ->
      case entry.variants do
        variants when is_list(variants) and variants != [] ->
          Enum.map(variants, fn variant ->
            {Atom.to_string(variant.provider_atom),
             entry.display_name <> " · " <> variant.display_name}
          end)

        _ ->
          Enum.map(entry.provider_atoms, &{Atom.to_string(&1), entry.display_name})
      end
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp json_text(text) when is_binary(text), do: text

  defp json_text(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, text} -> text
      {:error, _} -> inspect(value)
    end
  end

  defp generation_parameters do
    [
      {"temperature", gettext("Temperature"), "number", "0.01", 0, 2},
      {"max_tokens", gettext("Max output tokens"), "number", "1", 1, nil},
      {"top_p", gettext("Top P"), "number", "0.01", 0, 1},
      {"top_k", gettext("Top K"), "number", "1", 1, nil},
      {"frequency_penalty", gettext("Frequency penalty"), "number", "0.01", -2, 2},
      {"presence_penalty", gettext("Presence penalty"), "number", "0.01", -2, 2}
    ]
  end

  defp day_options do
    [
      {"mon", gettext("Mon")},
      {"tue", gettext("Tue")},
      {"wed", gettext("Wed")},
      {"thu", gettext("Thu")},
      {"fri", gettext("Fri")},
      {"sat", gettext("Sat")},
      {"sun", gettext("Sun")},
      {"weekdays", gettext("Weekdays")},
      {"weekends", gettext("Weekends")}
    ]
  end

  defp auth_state(status) do
    case value(status, "state", :unknown) do
      state when state in [:ok, :missing, :unwritable] -> state
      "ok" -> :ok
      "missing" -> :missing
      "unwritable" -> :unwritable
      _ -> :unknown
    end
  end

  defp auth_tone(:ok), do: "text-success"
  defp auth_tone(state) when state in [:missing, :unwritable], do: "text-warning"
  defp auth_tone(_), do: "text-base-content/70"

  defp auth_label(:ok, expires, chatgpt?) when is_integer(expires) do
    case DateTime.from_unix(expires, :millisecond) do
      {:ok, date} ->
        gettext("Login detected (expires %{date})",
          date: format_auth_expiry(date, chatgpt?)
        )

      {:error, _} ->
        gettext("Login detected")
    end
  end

  defp auth_label(:ok, _, _), do: gettext("Login detected")
  defp auth_label(:missing, _, _), do: gettext("No subscription login found")

  defp auth_label(:unwritable, _, _),
    do: gettext("Login found, managed credential file not writable")

  defp auth_label(_, _, _), do: gettext("Subscription login")

  defp format_auth_expiry(date, true), do: EvoDashWeb.Helpers.format_local_datetime(date)
  defp format_auth_expiry(date, false), do: EvoDashWeb.Helpers.format_datetime(date)

  defp chatgpt_login_command(profile) do
    alias EvoGit.Auth.ChatGPT.Store

    account = value(profile, "siwc_account")

    if Store.valid_account?(account),
      do: "genesis chatgpt login --account " <> account,
      else: "genesis chatgpt login"
  end

  # Resolve only catalog-owned atoms; never intern a user-entered identifier.
  defp provider_atom(profile) do
    name = value(profile, "provider")

    EvoGit.Config.LLMCatalog.providers()
    |> Enum.flat_map(& &1.provider_atoms)
    |> Enum.find(:unknown_provider, &(Atom.to_string(&1) == name))
  end

  # Login commands are provider metadata, not a verdict about the local machine.
  # Never resolve EvoGit.Auth.default_oauth_file/0 on a remote page.
  defp login_guidance(profile) do
    case EvoGit.Config.LLMCatalog.oauth_source(provider_atom(profile)) do
      :claude_code ->
        gettext(
          "Run claude to sign in on the selected node, or use claude setup-token, then recheck."
        )

      _ ->
        gettext("Sign in with the provider's CLI on the selected node, then recheck.")
    end
  end
end
