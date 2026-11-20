defmodule EvoDashWeb.SettingsComponents.ProviderProfiles.Panel do
  @moduledoc """
  The `/settings` LLM provider-account surface — ONE panel that lists every
  `[[llm.providers]]` account, expands exactly one of them into the full editor
  form, and hosts the two inline wizards.

  This module (with `Row`, `Detail`, `ScheduleEditor` and `WizardForm` under
  `settings_components/provider_profiles/`) is the only provider-account
  surface: there is no second place to create an account, no catalog shortcut
  that writes a half-configured profile, and no nested
  card-in-card-in-card borders.

  ## Data flow (presentation only)

  The LiveView owns ALL state and ALL persistence. This panel renders what it is
  given and emits events; it calls no config API, no store and no catalog write
  path.

  ## Events (the panel's whole vocabulary)

      add_provider_profile
      provider_wizard_change | provider_wizard_next | provider_wizard_back
      provider_wizard_cancel | provider_wizard_save
      start_add_provider_model  (phx-value-profile_id)
      provider_model_change | provider_model_save | provider_model_cancel
      edit_provider_profile     (phx-value-profile_id)
      cancel_edit_provider_profile
      provider_profile_form_change
      save_provider_profile
      set_default_provider_profile | delete_provider_profile (phx-value-profile_id)
      add_provider_model | remove_provider_model (phx-value-index)
      add_provider_peak_hours_row | remove_provider_peak_hours_row (phx-value-index)
      refresh_auth_status (phx-value-profile_id)
      toggle_profile_advanced
      apply_provider_schedule (phx-value-preset_id)
      undo_provider_schedule | dismiss_schedule_applied

  ## Design

  ONE section header (`#provider-profiles-title`) plus the settings category
  header rendered by `SettingsComponents.category_section/1`. The account list is
  ONE container with a single hairline border (`border border-base-300`,
  `rounded-xl`, `divide-y divide-base-300`); every account is one compact summary
  row (`Row.profile_row/1`) that expands IN PLACE into the editor form
  (`Detail.profile_detail/1`, separated by ONE `border-t` hairline with a faint
  `bg-base-200/30` body) or into the add-model wizard. Corners never exceed
  `rounded-xl`, colors are daisyUI tokens only, and no new keyframes are added
  (`wizard-step-enter` is the shared, reduced-motion-safe CSS the wizard shell
  already uses).
  """
  use EvoDashWeb, :html

  alias EvoDashWeb.SettingsComponents.ProviderProfiles.Detail
  alias EvoDashWeb.SettingsComponents.ProviderProfiles.Row
  alias EvoDashWeb.SettingsComponents.ProviderProfiles.WizardForm

  attr(:profiles, :list, default: [])
  attr(:default_profile_id, :any, default: nil)
  attr(:expanded_id, :any, default: nil)
  attr(:draft, :any, default: nil)
  attr(:errors, :map, default: %{})
  attr(:auth_statuses, :map, default: %{})
  attr(:disabled, :boolean, default: false)
  attr(:advanced_open, :any, default: nil)
  attr(:wizard, :any, default: nil)
  attr(:schedule, :map, default: %{})
  # Page-owned in-browser ChatGPT sign-in state + the local/remote verdict
  # (total defaults; forwarded to every row and the one expanded editor).
  attr(:chatgpt_sign_in, :map, default: %{})
  attr(:chatgpt_sign_in_manual, :boolean, default: false)

  def provider_profiles_panel(assigns) do
    assigns =
      assigns
      |> assign(:profiles, List.wrap(assigns.profiles))
      |> assign(:errors, if(is_map(assigns.errors), do: assigns.errors, else: %{}))
      |> assign(
        :auth_statuses,
        if(is_map(assigns.auth_statuses), do: assigns.auth_statuses, else: %{})
      )
      |> assign(:schedule, if(is_map(assigns.schedule), do: assigns.schedule, else: %{}))
      |> assign(:account_wizard?, wizard_mode(assigns.wizard) == :account)

    ~H"""
    <section id="provider-profiles-panel" class="space-y-4">
      <header class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 id="provider-profiles-title" class="text-base font-semibold text-base-content">
            {gettext("Provider accounts")}
            <%!-- zh_CN: 提供方账户 —— 一个账户 = 一个 [[llm.providers]] 条目（凭证、并发与时段共享）。 --%>
          </h2>
          <p class="mt-1 text-sm text-base-content/60">
            {gettext(
              "One account per provider credential: its models share the slot pool, the peak schedule and the authentication."
            )}
          </p>
        </div>
        <button
          type="button"
          phx-click="add_provider_profile"
          class="btn btn-primary btn-sm shrink-0"
          disabled={@disabled or @account_wizard?}
        >
          <.icon name="hero-plus" class="size-4" /> {gettext("Add account")}
        </button>
      </header>

      <div class="divide-y divide-base-300 rounded-xl border border-base-300">
        <WizardForm.add_account_wizard :if={@account_wizard?} wizard={@wizard} disabled={@disabled} />

        <div :for={profile <- @profiles} :key={profile_key(profile)}>
          <Row.profile_row
            profile={profile}
            default?={default?(profile, @default_profile_id)}
            expanded?={expanded?(profile, @expanded_id)}
            auth_status={auth_status(@auth_statuses, profile)}
            disabled={@disabled}
            chatgpt_sign_in={@chatgpt_sign_in}
            chatgpt_sign_in_manual={@chatgpt_sign_in_manual}
          />
          <Detail.profile_detail
            :if={expanded?(profile, @expanded_id)}
            profile={profile}
            draft={@draft}
            errors={@errors}
            auth_status={auth_status(@auth_statuses, profile)}
            advanced_open={@advanced_open}
            schedule={@schedule}
            chatgpt_sign_in={@chatgpt_sign_in}
            chatgpt_sign_in_manual={@chatgpt_sign_in_manual}
          />
          <WizardForm.add_model_wizard
            :if={model_wizard_for?(profile, @wizard)}
            wizard={@wizard}
            profile={profile}
            disabled={@disabled}
          />
        </div>

        <p
          :if={@profiles == [] and not @account_wizard?}
          class="px-4 py-8 text-center text-sm text-base-content/60"
        >
          {gettext("No provider accounts yet. Add one to start running tasks.")}
        </p>
      </div>
    </section>
    """
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # helpers (pure, total)
  # ═══════════════════════════════════════════════════════════════════════════

  defp profile_key(profile) when is_map(profile) do
    Row.slug(Row.profile_id(profile))
  end

  defp profile_key(_profile), do: "account"

  defp default?(profile, default_profile_id) do
    case Row.profile_id(profile) do
      nil -> false
      id -> to_string(id) == to_string(default_profile_id)
    end
  end

  defp expanded?(profile, expanded_id) do
    case {Row.profile_id(profile), expanded_id} do
      {nil, _expanded} -> false
      {_id, nil} -> false
      {id, expanded} -> to_string(id) == to_string(expanded)
    end
  end

  defp model_wizard_for?(profile, wizard) do
    case wizard_mode(wizard) do
      {:model, profile_id} ->
        case Row.profile_id(profile) do
          nil -> false
          id -> to_string(id) == to_string(profile_id)
        end

      _mode ->
        false
    end
  end

  defp wizard_mode(%{} = wizard) do
    Map.get(wizard, :mode) || Map.get(wizard, "mode")
  end

  defp wizard_mode(_wizard), do: nil

  defp auth_status(auth_statuses, profile) do
    case Row.profile_id(profile) do
      nil -> nil
      id -> Map.get(auth_statuses, id) || Map.get(auth_statuses, to_string(id))
    end
  end
end
