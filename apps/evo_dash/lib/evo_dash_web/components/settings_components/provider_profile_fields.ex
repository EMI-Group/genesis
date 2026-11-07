defmodule EvoDashWeb.SettingsComponents.ProviderProfileFields do
  @moduledoc """
  Pure form building blocks for ProviderProfilesEditor.
  No core configuration or credential files are read here.
  """

  use EvoDashWeb, :html

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

  attr(:prefix, :string, required: true)
  attr(:fields, :map, required: true)
  attr(:model_override, :boolean, default: false)

  def reasoning_fields(assigns) do
    assigns = assign(assigns, :efforts, efforts(value(assigns.fields, "reasoning_efforts", [])))

    ~H"""
    <fieldset class="min-w-0 space-y-3 rounded-lg border border-base-300 p-3">
      <%!-- zh_CN: 推理等级列表是有序能力清单，不是任务的速度/质量设置。 --%>
      <legend class="px-1 text-xs font-semibold">{gettext("Reasoning support and defaults")}</legend>
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.profile_field
          name={nested(@prefix, "reasoning_efforts")}
          label={gettext("Supported reasoning levels (ordered)")}
          value={inventory_text(value(@fields, "reasoning_efforts", []))}
          help={
            if @model_override,
              do:
                gettext(
                  "Comma-separated, lowest to highest. Blank explicitly disables reasoning for this model."
                ),
              else:
                gettext(
                  "Comma-separated, lowest to highest; for example: low, medium, high. Blank means no advertised reasoning support."
                )
          }
        />
        <.reasoning_default prefix={@prefix} fields={@fields} efforts={@efforts} />
      </div>
    </fieldset>
    """
  end

  attr(:prefix, :string, required: true)
  attr(:fields, :map, required: true)
  attr(:efforts, :list, required: true)
  attr(:inherit, :boolean, default: false)

  def reasoning_default(assigns) do
    assigns =
      assigns
      |> assign(:name, nested(assigns.prefix, "default_reasoning_effort"))
      |> assign(:selected, value(assigns.fields, "default_reasoning_effort"))

    ~H"""
    <div class="min-w-0">
      <label for={field_id(@name)} class="mb-1 block text-xs font-medium text-base-content/70">{gettext(
        "Default reasoning level"
      )}</label>
      <select
        id={field_id(@name)}
        name={@name}
        class="select select-sm w-full min-w-0 rounded-md border-base-300 bg-base-100"
        aria-describedby={field_id(@name) <> "-help"}
        aria-invalid={if @selected != "" and @selected not in @efforts, do: "true"}
      >
        <option value="" selected={@selected == ""}>
          {if @inherit, do: gettext("Inherit provider default"), else: gettext("Provider default")}
        </option>
        <option :if={@selected != "" and @selected not in @efforts} value={@selected} selected>
          {gettext("Unsupported level: %{level}", level: @selected)}
        </option>
        <option :for={effort <- @efforts} value={effort} selected={effort == @selected}>
          {effort}
        </option>
      </select>
      <p id={field_id(@name) <> "-help"} class="mt-1 text-xs text-base-content/70">
        {gettext("Choose a supported level. This is separate from task speed and quality.")}
      </p>
    </div>
    """
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

  def provider_auth_status(assigns) do
    state = auth_state(assigns.status)

    assigns =
      assigns
      |> assign(:state, state)
      |> assign(:label, auth_label(state, value(assigns.status, "expires", nil)))
      |> assign(:path, value(assigns.status, "oauth_file", value(assigns.profile, "oauth_file")))
      |> assign(
        :instructions,
        value(assigns.status, "login_instructions", login_guidance(assigns.profile))
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
        <%= if @state == :unwritable do %>
          <p>
            {gettext(
              "Genesis found the vendor login but could not write its managed credential file."
            )}
          </p>
          <p>{gettext("Set oauth_file on this profile to a writable location, then recheck.")}</p>
        <% else %>
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
  @keys ~w(id name provider auth_mode oauth_file base_url concurrency default_model models
    context_window reasoning_efforts default_reasoning_effort generation provider_options
    peak_concurrency peak_hours timezone off_peak_days start end days override_reasoning
    profile_id_new temperature max_tokens top_p top_k frequency_penalty presence_penalty
    state expires login_instructions)a
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
  defp inventory_text(text) when is_binary(text), do: text
  defp inventory_text(list), do: list |> efforts() |> Enum.join(", ")
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

  defp auth_label(:ok, expires) when is_integer(expires) do
    case DateTime.from_unix(expires, :millisecond) do
      {:ok, date} ->
        gettext("Login detected (expires %{date})",
          date: EvoDashWeb.Helpers.format_datetime(date)
        )

      {:error, _} ->
        gettext("Login detected")
    end
  end

  defp auth_label(:ok, _), do: gettext("Login detected")
  defp auth_label(:missing, _), do: gettext("No subscription login found")

  defp auth_label(:unwritable, _),
    do: gettext("Login found, managed credential file not writable")

  defp auth_label(_, _), do: gettext("Subscription login")

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
      :codex_cli ->
        gettext("Run codex login on the selected node, then recheck.")

      :claude_code ->
        gettext(
          "Run claude to sign in on the selected node, or use claude setup-token, then recheck."
        )

      _ ->
        gettext("Sign in with the provider's CLI on the selected node, then recheck.")
    end
  end
end
