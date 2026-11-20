defmodule EvoDashWeb.SettingsComponents.ProviderProfiles.WizardForm do
  @moduledoc """
  The two inline wizards of the provider-account panel.

    * `add_account_wizard/1` — a full provider-account creation flow rendered at
      the TOP of the account list (`#provider-wizard`);
    * `add_model_wizard/1` — the model step alone, rendered under the row it
      belongs to (`#provider-model-form-<slug>`).

  Both are ADAPTERS over the shared foundation: the step markup comes from
  `EvoDashWeb.SettingsComponents.ProviderWizard` (pure, every event name an
  attr), the step order/validation from `EvoDashWeb.LLMSetup.Wizard`, the
  reasoning vocabulary from `..Reasoning` and the presets/holidays from
  `..Schedule`. Nothing here reads config, the clock or a catalog cache: the
  provider/model choices are derived from the static `LLMCatalog` metadata and
  the caller-supplied draft.

  ## Which steps render

  Only `:provider`, `:auth`, `:model` and `:reasoning_schedule` are rendered
  here. `:test` and `:done` are the `/welcome` REPLAY/SUMMARY steps (a
  connection test and a "you are done, go to the dashboard" page), which make
  no sense inside `/settings`, where the account already saves straight to
  `config.toml` and every saved account stays editable in place. The progress
  rail is therefore computed by `Wizard.progress/2` / `Wizard.index/2` against
  the steps we ACTUALLY render, not against `Wizard.all_steps/0`.

  The ChatGPT authentication step binds the new provider account to a
  registration: it renders the in-browser sign-in (`sign_in`) unless the page
  says the dashboard cannot reach the execution node (`manual`), in which case
  it points at the CLI command.

  ## Events

  Every event name is the panel contract (see
  `EvoDashWeb.SettingsComponents.ProviderProfiles.Panel`): changes flow through
  `provider_wizard_change`, navigation through `provider_wizard_next`/`_back`/
  `_cancel`, and the last rendered step's primary action is
  `provider_wizard_save`. A published schedule preset is applied through
  `provider_wizard_change` carrying `phx-value-preset_id`, so the whole wizard
  keeps ONE change vocabulary. The add-model flow repeats only the model step
  with `provider_model_change` / `provider_model_save` / `provider_model_cancel`.
  """
  use EvoDashWeb, :html

  alias EvoDashWeb.LLMSetup.ChatGPT
  alias EvoDashWeb.LLMSetup.Reasoning
  alias EvoDashWeb.LLMSetup.Schedule
  alias EvoDashWeb.LLMSetup.Wizard
  alias EvoDashWeb.SettingsComponents.ProviderProfileFields, as: Fields
  alias EvoDashWeb.SettingsComponents.ProviderProfiles.Row
  alias EvoDashWeb.SettingsComponents.ProviderWizard
  import EvoDashWeb.SettingsComponents.ProviderWizard.ChatGPTAuth, only: [chatgpt_auth: 1]

  # The steps `/settings` renders — `:test` and `:done` stay on `/welcome`.
  @rendered_steps [:provider, :auth, :model, :reasoning_schedule]

  @step_labels %{
    provider: "Provider",
    auth: "Authentication",
    model: "Model",
    reasoning_schedule: "Reasoning & schedule"
  }

  # ═══════════════════════════════════════════════════════════════════════════
  # add_account_wizard/1
  # ═══════════════════════════════════════════════════════════════════════════

  attr(:wizard, :map, required: true)
  attr(:disabled, :boolean, default: false)

  def add_account_wizard(assigns) do
    wizard = normalize_wizard(assigns.wizard)
    draft = wizard.draft
    steps = rendered_steps(draft)
    step = current_step(steps, wizard.step)
    last? = step == List.last(steps)

    assigns =
      assigns
      |> assign(:draft, draft)
      |> assign(:steps, steps)
      |> assign(:step, step)
      |> assign(:step_labels, @step_labels)
      |> assign(:provider, text(draft, "provider"))
      |> assign(:provider_choices, provider_choices())
      |> assign(:oauth_only?, Fields.oauth_only?(draft))
      |> assign(:chatgpt?, ChatGPT.provider?(draft["provider"]))
      |> assign(:chatgpt_accounts, wizard.chatgpt_accounts)
      |> assign(:chatgpt_sign_in, wizard.chatgpt_sign_in)
      |> assign(:chatgpt_sign_in_manual, wizard.chatgpt_sign_in_manual)
      |> assign(:models, model_choices(draft, wizard.chatgpt_accounts))
      |> assign(:inventory, list(draft, "reasoning_efforts"))
      |> assign(:default_effort, text(draft, "default_reasoning_effort"))
      |> assign(:holidays, text(draft, "off_peak_holidays"))
      |> assign(:presets, Schedule.presets_for_provider(text(draft, "provider")))
      |> assign(:next_event, if(last?, do: "provider_wizard_save", else: "provider_wizard_next"))
      |> assign(:next_label, if(last?, do: gettext("Save account"), else: gettext("Continue")))
      |> assign(
        :next_disabled,
        next_disabled?(step, draft, assigns.disabled, last?, wizard.chatgpt_accounts)
      )
      |> assign(:wizard_error, wizard_error(wizard.errors))

    ~H"""
    <div id="provider-wizard" class="bg-base-200/30 px-4 py-5 sm:px-6">
      <ProviderWizard.wizard_shell
        step={@step}
        steps={@steps}
        title={gettext("Add provider account")}
        subtitle={
          gettext(
            "Provider, authentication, model and schedule — one account at a time. Nothing is written until you save."
          )
        }
        step_labels={@step_labels}
        back_event="provider_wizard_back"
        next_event={@next_event}
        next_label={@next_label}
        next_disabled={@next_disabled}
        cancel_event="provider_wizard_cancel"
        cancel_label={gettext("Cancel")}
        error={@wizard_error}
      >
        <%= case @step do %>
          <% :provider -> %>
            <form id="provider-wizard-provider-form" phx-change="provider_wizard_change">
              <ProviderWizard.step_provider
                providers={@provider_choices}
                selected={@provider}
                provider_event="provider_wizard_change"
                base_url={text(@draft, "base_url")}
              />
            </form>
          <% :auth -> %>
            <ProviderWizard.step_auth
              selected={text(@draft, "auth_mode")}
              auth_event="provider_wizard_change"
              oauth_only={@oauth_only?}
              chatgpt={@chatgpt?}
            >
              <:auth_detail :if={@chatgpt?}>
                <.chatgpt_auth
                  id="settings-chatgpt"
                  account={@draft["siwc_account"]}
                  accounts={@chatgpt_accounts}
                  change_event="provider_wizard_change"
                  refresh_event="provider_wizard_change"
                  sign_in={@chatgpt_sign_in}
                  manual={@chatgpt_sign_in_manual}
                />
              </:auth_detail>
            </ProviderWizard.step_auth>
          <% :model -> %>
            <%!-- The step component owns its own search + custom-model forms, so the
                  step must NOT be wrapped in another form here. --%>
            <ProviderWizard.step_model
              models={@models}
              selected={text(@draft, "model")}
              query={text(@draft, "query")}
              model_event="provider_wizard_change"
              model_search_event="provider_wizard_change"
              custom_model_event="provider_wizard_change"
              custom_model={text(@draft, "custom_model")}
              allow_custom_model={not @chatgpt?}
            />
          <% :reasoning_schedule -> %>
            <form id="provider-wizard-reasoning-form" phx-change="provider_wizard_change">
              <ProviderWizard.step_reasoning_schedule
                inventory={@inventory}
                default_effort={@default_effort}
                presets={@presets}
                preset_apply_event="provider_wizard_change"
                off_peak_holidays={@holidays}
                holiday_options={Schedule.holiday_options()}
                holiday_help={Schedule.holiday_help()}
                inventory_name={Reasoning.inventory_input_name()}
                default_name={Reasoning.default_input_name()}
              />
            </form>
        <% end %>
      </ProviderWizard.wizard_shell>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # add_model_wizard/1
  # ═══════════════════════════════════════════════════════════════════════════

  attr(:wizard, :map, required: true)
  attr(:profile, :any, default: nil)
  attr(:disabled, :boolean, default: false)

  def add_model_wizard(assigns) do
    wizard = normalize_wizard(assigns.wizard)
    draft = wizard.draft
    profile = if is_map(assigns.profile), do: assigns.profile, else: %{}
    profile_id = profile_id(wizard.mode) || text(profile, "id")

    assigns =
      assigns
      |> assign(:draft, draft)
      |> assign(:profile_id, profile_id)
      |> assign(:slug, Row.slug(profile_id))
      |> assign(:account_name, account_name(profile, profile_id))
      |> assign(:chatgpt?, ChatGPT.provider?(profile["provider"]))
      |> assign(:models, model_choices(Map.merge(profile, draft), wizard.chatgpt_accounts))
      |> assign(:wizard_error, wizard_error(wizard.errors))
      |> assign(:can_save?, Wizard.validate(:model, draft) == :ok and not assigns.disabled)

    ~H"""
    <div
      id={"provider-model-form-" <> @slug}
      class="border-t border-base-300 bg-base-200/30 px-4 py-5 sm:px-6"
    >
      <p class="mb-4 text-sm font-medium text-base-content">
        {gettext("Add a model to %{account}", account: @account_name)}
      </p>
      <%!-- No wrapping form: the step renders its own search and custom-model forms,
            and both report through `provider_model_change`. --%>
      <ProviderWizard.step_model
        models={@models}
        selected={text(@draft, "model")}
        query={text(@draft, "query")}
        model_event="provider_model_change"
        model_search_event="provider_model_change"
        custom_model_event="provider_model_change"
        custom_model={text(@draft, "custom_model")}
        allow_custom_model={not @chatgpt?}
      />
      <p :if={@wizard_error} role="alert" class="mt-2 text-sm text-error">{@wizard_error}</p>
      <div class="mt-5 flex items-center justify-end gap-2">
        <button
          type="button"
          phx-click="provider_model_cancel"
          class="btn btn-ghost btn-sm"
        >
          {gettext("Cancel")}
        </button>
        <button
          type="button"
          phx-click="provider_model_save"
          class="btn btn-primary btn-sm"
          disabled={not @can_save?}
        >
          {gettext("Add model")}
        </button>
      </div>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # steps & validation
  # ═══════════════════════════════════════════════════════════════════════════

  # ChatGPT uses the authentication step to select an authorized account.
  #
  # Public so the wizard's owner (`EvoDashWeb.SettingsLive.ProviderPanelEvents`)
  # steps over the SAME list this module renders — one definition, no drift.
  @doc """
  The step list actually rendered for `draft`.

  The authentication step includes the ChatGPT registration picker.
  """
  @spec rendered_steps(map()) :: [atom()]
  def rendered_steps(draft) do
    if Fields.oauth_only?(draft) and not ChatGPT.provider?(draft["provider"]) do
      List.delete(@rendered_steps, :auth)
    else
      @rendered_steps
    end
  end

  @doc """
  The step to display: `step` when it is rendered, else the list's first step.

  Public for the same reason as `rendered_steps/1` (a provider change can
  shrink the list under a parked `:auth` step).
  """
  @spec current_step([atom()], atom()) :: atom()
  def current_step(steps, step) do
    if step in steps, do: step, else: List.first(steps)
  end

  defp next_disabled?(step, draft, disabled, last?, accounts) do
    cond do
      disabled -> true
      step == :auth and not chatgpt_auth_ready?(draft, accounts) -> true
      Wizard.validate(step, draft) != :ok -> true
      last? -> Wizard.validate(:model, draft) != :ok
      true -> false
    end
  end

  def chatgpt_auth_ready?(draft, accounts) do
    not ChatGPT.provider?(draft["provider"]) or
      Map.has_key?(accounts, ChatGPT.account_name(draft["siwc_account"]))
  end

  defp wizard_error(%{} = errors) when map_size(errors) > 0 do
    errors |> Map.values() |> List.first()
  end

  defp wizard_error(_errors), do: nil

  # ═══════════════════════════════════════════════════════════════════════════
  # wizard state
  # ═══════════════════════════════════════════════════════════════════════════

  defp normalize_wizard(%{} = wizard) do
    %{
      mode: Map.get(wizard, :mode) || Map.get(wizard, "mode"),
      step: Map.get(wizard, :step) || Map.get(wizard, "step"),
      draft: Map.get(wizard, :draft) || Map.get(wizard, "draft") || %{},
      errors: Map.get(wizard, :errors) || Map.get(wizard, "errors") || %{},
      chatgpt_accounts: Map.get(wizard, :chatgpt_accounts, %{}),
      # Sign-in presentation is owned by the page; a wizard without those
      # assigns still renders the LOCAL flow (the same default the component
      # uses) instead of failing on a missing key.
      chatgpt_sign_in: Map.get(wizard, :chatgpt_sign_in) || %{},
      chatgpt_sign_in_manual: Map.get(wizard, :chatgpt_sign_in_manual) == true
    }
  end

  defp normalize_wizard(_wizard),
    do: %{
      mode: nil,
      step: nil,
      draft: %{},
      errors: %{},
      chatgpt_accounts: %{},
      chatgpt_sign_in: %{},
      chatgpt_sign_in_manual: false
    }

  defp profile_id({:model, profile_id}) when is_binary(profile_id), do: profile_id

  defp profile_id({:model, profile_id}) when is_atom(profile_id) and not is_nil(profile_id),
    do: Atom.to_string(profile_id)

  defp profile_id(_mode), do: nil

  defp account_name(profile, profile_id) do
    case text(profile, "name") do
      "" -> profile_id || gettext("this account")
      name -> name
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # catalog choices (static metadata only)
  # ═══════════════════════════════════════════════════════════════════════════

  # Mirrors `ProviderProfileFields.provider_select/1`'s option inventory (which
  # is private): one choice per provider ATOM, variant entries named by their
  # variant so two Z.AI accounts never look identical.
  defp provider_choices do
    EvoGit.Config.LLMCatalog.providers()
    |> Enum.flat_map(fn entry ->
      case List.wrap(entry.variants) do
        [] ->
          Enum.map(entry.provider_atoms, fn atom ->
            %{
              id: Atom.to_string(atom),
              label: EvoDashWeb.LLMSetup.Identity.provider_display_name(atom),
              note: nil
            }
          end)

        variants ->
          Enum.map(variants, fn variant ->
            %{
              id: Atom.to_string(variant.provider_atom),
              label: entry.display_name <> " · " <> variant.display_name,
              note: nil
            }
          end)
      end
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp model_choices(draft, accounts) do
    models =
      case catalog_atom(text(draft, "provider")) do
        nil -> []
        :openai_codex -> ChatGPT.model_entries(accounts, draft["siwc_account"])
        atom -> EvoGit.Config.LLMCatalog.provider_models(atom)
      end

    models
    |> Enum.map(&model_choice/1)
    |> Enum.filter(fn model ->
      query = text(draft, "query") |> String.downcase()

      String.contains?(String.downcase(model.id), query) or
        String.contains?(String.downcase(model.label), query)
    end)
  end

  defp model_choice(%{} = model) do
    id = text(model, "id") |> blank_to(text(model, "model"))
    %{id: id, label: text(model, "display_name") |> blank_to(id), variant: nil}
  end

  defp model_choice(other), do: %{id: to_string(other), label: to_string(other), variant: nil}

  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value

  # A whitelisted atom lookup: caller input never interns an atom.
  defp catalog_atom(name) do
    EvoGit.Config.LLMCatalog.providers()
    |> Enum.flat_map(& &1.provider_atoms)
    |> Enum.find(&(Atom.to_string(&1) == name))
  end

  defp text(map, key) do
    case fetch(map, key) do
      value when is_binary(value) -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _ -> ""
    end
  end

  defp list(map, key) do
    case fetch(map, key) do
      values when is_list(values) -> values
      _ -> []
    end
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key(key))
    end
  end

  defp fetch(_map, _key), do: nil

  # Static key → atom table (no dynamic atom creation).
  defp atom_key("provider"), do: :provider
  defp atom_key("auth_mode"), do: :auth_mode
  defp atom_key("model"), do: :model
  defp atom_key("custom_model"), do: :custom_model
  defp atom_key("query"), do: :query
  defp atom_key("base_url"), do: :base_url
  defp atom_key("name"), do: :name
  defp atom_key("id"), do: :id
  defp atom_key("display_name"), do: :display_name
  defp atom_key("off_peak_holidays"), do: :off_peak_holidays
  defp atom_key("default_reasoning_effort"), do: :default_reasoning_effort
  defp atom_key("reasoning_efforts"), do: :reasoning_efforts
  defp atom_key(_key), do: :__missing__
end
