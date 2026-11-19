defmodule EvoDashWeb.WelcomeLive.Steps do
  @moduledoc """
  The per-step BODIES of the `/welcome` wizard.

  `EvoDashWeb.WelcomeLive` keeps the socket, the event vocabulary and the one
  save path; this module owns nothing but the markup of ONE step at a time, as
  one public function component per step (`step_provider_body/1`,
  `step_auth_body/1`, `step_model_body/1`, `step_reasoning_schedule_body/1`,
  `step_test_body/1`, `step_done_body/1`). The page renders the step bodies
  inside `EvoDashWeb.SettingsComponents.ProviderWizard.wizard_shell/1`.

  Every body is a pure function of the assigns it declares: no socket, no
  event handling, no I/O and no view-model derivation (that belongs to
  `EvoDashWeb.WelcomeLive.Presentation`). Event names, element ids, class lists
  and the wrapping `phx-change` forms are part of the rendered contract.
  """
  use EvoDashWeb, :html

  alias EvoDashWeb.LLMSetup.Reasoning
  alias EvoDashWeb.SettingsComponents.ProviderWizard
  alias EvoDashWeb.WelcomeLive.Presentation

  attr(:provider_options, :list, default: [])
  attr(:draft, :map, required: true)
  attr(:variant_options, :list, default: [])

  def step_provider_body(assigns) do
    ~H"""
    <form
      id="wizard-provider-form"
      phx-change="wizard_field_changed"
      phx-submit="noop"
      class="space-y-4"
    >
      <ProviderWizard.step_provider
        providers={@provider_options}
        selected={@draft["provider"]}
        provider_event="select_wizard_provider"
        custom_value={Presentation.custom_value()}
        base_url={@draft["base_url"]}
        base_url_name="base_url"
      />
      <div :if={@variant_options != []} class="flex flex-wrap gap-2">
        <button
          :for={variant <- @variant_options}
          type="button"
          phx-click="select_wizard_variant"
          phx-value-variant={variant["id"]}
          class={"btn btn-sm " <> if(variant["selected"], do: "btn-primary", else: "btn-outline")}
        >
          {variant["label"]}
        </button>
      </div>
    </form>
    """
  end

  attr(:draft, :map, required: true)
  attr(:auth_modes, :list, default: ["api_key"])
  attr(:oauth_only, :boolean, default: false)
  attr(:login_instructions, :string, default: "")
  attr(:key_placeholder, :string, default: nil)
  attr(:key_present, :boolean, default: false)

  def step_auth_body(assigns) do
    ~H"""
    <ProviderWizard.step_auth
      selected={@draft["auth_mode"]}
      auth_event="select_wizard_auth"
      modes={@auth_modes}
      oauth_only={@oauth_only}
    >
      <:auth_detail>
        <%= if @draft["auth_mode"] == "oauth" do %>
          <p class="text-xs text-base-content/70">
            {gettext("Log in once with the vendor CLI; Genesis imports the credentials lazily.")}
          </p>
          <pre class="mt-2 whitespace-pre-wrap rounded-lg border border-base-300 bg-base-200/50 p-3 text-xs text-base-content/80">{@login_instructions}</pre>
        <% else %>
          <form
            id="wizard-auth-key-form"
            phx-change="wizard_api_key"
            phx-submit="noop"
            class="space-y-2"
          >
            <label class="text-xs font-medium" for="wizard-api-key">
              {gettext("API key")}
            </label>
            <input
              id="wizard-api-key"
              type="password"
              name="api_key"
              value={@draft["api_key"]}
              autocomplete="off"
              class="input input-sm w-full"
              placeholder={@key_placeholder}
            />
            <p :if={@key_present} class="text-xs text-base-content/60">
              {gettext("A key is already stored for this provider.")}
            </p>
          </form>
        <% end %>
      </:auth_detail>
    </ProviderWizard.step_auth>
    """
  end

  attr(:model_rows, :list, default: [])
  attr(:all_model_rows, :list, default: [])
  attr(:draft, :map, required: true)
  attr(:search_query, :any, default: "")

  def step_model_body(assigns) do
    ~H"""
    <div class="space-y-4">
      <ProviderWizard.step_model
        models={@model_rows}
        selected={@draft["default_model"]}
        query={@search_query}
        model_event="select_wizard_model"
        model_search_event="wizard_model_search"
        search_name="query"
        custom_model_event="wizard_custom_model"
        custom_model_name="custom_model"
        custom_model={@draft["custom_model"]}
        custom_model_value={@draft["custom_model"]}
      />
      <details :if={@all_model_rows != []} class="rounded-lg border border-base-300 p-3">
        <summary class="cursor-pointer text-sm font-medium">
          {gettext("Add another model")}
        </summary>
        <div class="mt-3 flex flex-wrap gap-2">
          <label
            :for={row <- @all_model_rows}
            class="flex items-center gap-2 rounded-lg border border-base-300 px-2 py-1 text-xs"
          >
            <input
              type="checkbox"
              phx-click="toggle_wizard_model"
              phx-value-model={row["id"]}
              checked={row["id"] in List.wrap(@draft["models"])}
            />
            <span>{row["label"]}</span>
          </label>
        </div>
      </details>
    </div>
    """
  end

  attr(:inventory, :list, default: [])
  attr(:default_effort, :any, default: nil)
  attr(:presets, :list, default: [])
  attr(:preset_applied, :any, default: nil)
  attr(:holidays, :any, default: nil)
  attr(:holiday_options, :list, default: nil)
  attr(:holiday_help, :string, default: nil)
  attr(:schedule_rows, :list, default: [])
  attr(:inventory_name, :string, default: nil)
  attr(:default_name, :string, default: nil)
  attr(:extra_models, :list, default: [])

  def step_reasoning_schedule_body(assigns) do
    ~H"""
    <form
      id="wizard-reasoning-form"
      phx-change="wizard_reasoning"
      phx-submit="noop"
      class="space-y-4"
    >
      <ProviderWizard.step_reasoning_schedule
        inventory={@inventory}
        default_effort={@default_effort}
        presets={@presets}
        preset_applied={@preset_applied}
        preset_apply_event="apply_schedule_preset"
        preset_undo_event="undo_schedule_preset"
        preset_dismiss_event="dismiss_schedule_preset"
        off_peak_holidays={@holidays}
        holiday_options={@holiday_options}
        holiday_help={@holiday_help}
        schedule_rows={@schedule_rows}
        inventory_name={@inventory_name}
        default_name={@default_name}
      />
      <div :if={@extra_models != []} class="space-y-2 border-t border-base-300 pt-3">
        <p class="text-xs font-medium">{gettext("Other selected models")}</p>
        <div :for={row <- @extra_models} class="flex items-center justify-between gap-3 text-sm">
          <span class="truncate">{row["label"]}</span>
          <select
            name={"model_reasoning[#{row["id"]}]"}
            class="select select-sm w-40"
            aria-label={gettext("Default reasoning effort")}
          >
            <option value="">{gettext("Provider default")}</option>
            <option :for={effort <- row["efforts"]} value={effort} selected={effort == row["default"]}>
              {Reasoning.label(effort)}
            </option>
          </select>
        </div>
      </div>
    </form>
    """
  end

  attr(:llm_test_status, :any, default: :idle)

  def step_test_body(assigns) do
    ~H"""
    <ProviderWizard.step_test
      test_state={@llm_test_status}
      test_event="test_connection"
      skip_event="skip_test"
    />
    """
  end

  attr(:summary, :list, default: [])

  def step_done_body(assigns) do
    ~H"""
    <ProviderWizard.step_done summary={@summary} dashboard_path={~p"/welcome/complete"}>
      <:secondary>
        <button type="button" phx-click="add_another_provider" class="btn btn-outline btn-sm">
          {gettext("Add another provider")}
        </button>
        <a href={~p"/settings"} class="btn btn-ghost btn-sm">
          {gettext("Open Settings")}
        </a>
      </:secondary>
    </ProviderWizard.step_done>
    """
  end
end
