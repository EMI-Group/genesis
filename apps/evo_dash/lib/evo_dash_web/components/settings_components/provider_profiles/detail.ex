defmodule EvoDashWeb.SettingsComponents.ProviderProfiles.Detail do
  @moduledoc """
  The ONE expanded full editor form of a `[[llm.providers]]` account.

  It is rendered INSIDE the account list (under the row it belongs to) and is a
  real `<form>`, so the whole account is edited in place:

    * identity + authentication + models + defaults stay visible;
    * optional account settings (identity overrides, base URL, concurrency,
      schedule, context window, reasoning inventory, generation defaults) live
      inside `<details id="provider-profile-advanced">`, closed by default and
      driven by the owner's `:advanced_open` (`nil` = the automatic rule);
    * the schedule half is `ProviderProfiles.ScheduleEditor`, which owns the
      holiday calendar and the provider's recommended presets.

  Field NAMES are canonical (`profile_id_new`, `name`, `models[i][model]`,
  `reasoning_efforts[]`, `off_peak_holidays`, …): the owner parses and validates
  every value, and no credential value ever enters this form.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.LLMSetup.Identity
  alias EvoDashWeb.SettingsComponents.ProviderProfiles.Row

  alias EvoDashWeb.LLMSetup.ChatGPT

  import EvoDashWeb.SettingsComponents.FormFooter, only: [form_footer: 1]

  import EvoDashWeb.SettingsComponents.ProviderProfiles.ScheduleEditor,
    only: [schedule_editor: 1]

  import EvoDashWeb.SettingsComponents.ProviderProfileFields,
    only: [
      efforts: 1,
      generation_fields: 1,
      indexed_rows: 1,
      oauth?: 1,
      oauth_only?: 1,
      oauth_supported?: 1,
      profile_field: 1,
      provider_auth_status: 1,
      provider_select: 1,
      reasoning_default: 1,
      reasoning_fields: 1,
      reasoning_suggestions: 1,
      reasoning_suggestions: 2,
      value: 2,
      value: 3
    ]

  attr :profile, :map, required: true
  attr :draft, :any, default: nil
  attr :errors, :map, default: %{}
  attr :auth_status, :any, default: nil
  attr :advanced_open, :any, default: nil
  attr :schedule, :map, default: %{}

  def profile_detail(assigns) do
    fields = Map.merge(assigns.profile, if(is_map(assigns.draft), do: assigns.draft, else: %{}))
    models = indexed_rows(value(fields, "models", []))

    # Auth status belongs to the SAVED credential scope: as soon as the draft
    # changes provider or subscription settings the old status is meaningless.
    same_credential_scope? =
      Enum.all?(
        ["provider", "oauth_file", "siwc_account"],
        &(value(fields, &1) == value(assigns.profile, &1))
      ) and
        oauth?(fields) == oauth?(assigns.profile)

    assigns =
      assigns
      |> assign(:fields, fields)
      |> assign(:chatgpt?, ChatGPT.provider?(value(fields, "provider")))
      |> assign(:models, models)
      |> assign(:default_models, default_models(fields, models))
      |> assign(:auth_status, if(same_credential_scope?, do: assigns.auth_status, else: nil))
      |> assign(:advanced_open?, advanced_open?(assigns.advanced_open))
      |> assign(:slug, Row.slug(value(assigns.profile, "id")))
      |> assign(:provider_name, Identity.provider_display_name(value(fields, "provider")))

    ~H"""
    <form
      id={"provider-profile-detail-" <> @slug}
      phx-submit="save_provider_profile"
      phx-change="provider_profile_form_change"
      aria-describedby={map_size(@errors) > 0 && "provider-profile-errors"}
      class="min-w-0 space-y-5 border-t border-base-300 bg-base-200/30 px-4 py-5 sm:px-6"
    >
      <input type="hidden" name="profile_id" value={value(@profile, "id")} />

      <p class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
        <span class="text-sm font-semibold text-base-content">{@provider_name}</span>
        <code class="font-mono text-[11px] text-base-content/60">{value(@fields, "id")}</code>
      </p>

      <div
        :if={map_size(@errors) > 0}
        id="provider-profile-errors"
        role="alert"
        class="rounded-lg border border-error/30 bg-error/10 p-3 text-sm text-error"
      >
        <p class="font-medium">{gettext("Check the account settings before saving.")}</p>
        <ul class="mt-1 list-inside list-disc">
          <li :for={{field, message} <- Enum.sort(@errors)}><code>{field}</code>: {message}</li>
        </ul>
      </div>

      <.provider_select fields={@fields} />

      <fieldset class="min-w-0 space-y-3 rounded-lg border border-base-300 bg-base-100 p-3">
        <legend class="px-1 text-sm font-semibold">{gettext("Authentication")}</legend>
        <div :if={oauth_supported?(@fields)} class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div>
            <label
              :if={not oauth_only?(@fields)}
              for="provider-auth-mode"
              class="mb-1 block text-xs font-medium text-base-content/70"
            >{gettext("Authentication mode")}</label>
            <p :if={oauth_only?(@fields)} class="mb-1 text-xs font-medium text-base-content/70">
              {gettext("Authentication mode")}
            </p>
            <select
              :if={not oauth_only?(@fields)}
              id="provider-auth-mode"
              name="auth_mode"
              class="select select-sm w-full"
            >
              <option value="api_key" selected={not oauth?(@fields)}>{gettext("API key")}</option>
              <option value="oauth" selected={oauth?(@fields)}>
                {gettext("Subscription (OAuth)")}
              </option>
            </select>
            <div :if={oauth_only?(@fields)} id="provider-auth-mode" class="flex min-h-8 items-center">
              <input type="hidden" name="auth_mode" value="oauth" />
              <span class="badge badge-secondary badge-sm">{gettext("Sign in with ChatGPT")}</span>
            </div>
          </div>
          <.profile_field
            :if={@chatgpt?}
            name="siwc_account"
            label={gettext("ChatGPT account name")}
            value={ChatGPT.account_name(value(@fields, "siwc_account"))}
            help={
              gettext(
                "Use the account name you signed in with — or the one passed to genesis chatgpt login --account on the execution node."
              )
            }
          />
          <.profile_field
            :if={oauth?(@fields) and not @chatgpt?}
            name="oauth_file"
            label={gettext("Credential file (optional)")}
            value={value(@fields, "oauth_file")}
            help={
              gettext(
                "Blank uses the managed credential file on the selected node. Absolute and ~-relative paths are accepted."
              )
            }
          />
        </div>
        <input :if={not oauth_supported?(@fields)} type="hidden" name="auth_mode" value="api_key" />
        <.provider_auth_status :if={oauth?(@fields)} status={@auth_status} profile={@fields} />
        <p :if={not oauth?(@fields)} class="text-xs leading-relaxed text-base-content/70">
          {gettext(
            "Configure the provider's API key in the selected node's credentials file or environment. Keys are never displayed or copied into this account form."
          )}
        </p>
      </fieldset>

      <section class="space-y-3" aria-labelledby="provider-models-title">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h4 id="provider-models-title" class="text-sm font-semibold">{gettext("Models")}</h4>
            <p class="mt-1 text-xs text-base-content/70">
              {gettext(
                "Enter model names supported by this provider. Open model details only when you need overrides."
              )}
            </p>
          </div>
          <button type="button" phx-click="add_provider_model" class="btn btn-outline btn-sm gap-1"><.icon
            name="hero-plus"
            class="size-4"
          />{gettext("Add model")}</button>
        </div>
        <%!-- UI-only helper: the owner synchronizes default_model without creating models rows. --%>
        <.profile_field
          :if={@models == []}
          name="default_model_name"
          label={gettext("Model name")}
          value={value(@fields, "default_model_name", value(@fields, "default_model"))}
          required
          help={
            gettext(
              "Edit the default model name. Add model rows only when you need per-model overrides."
            )
          }
        />
        <.model_fields
          :for={{model, index} <- @models}
          model={model}
          index={index}
          provider={@fields}
        />
      </section>

      <fieldset class="grid min-w-0 grid-cols-1 gap-3 rounded-lg border border-base-300 bg-base-100 p-3 sm:grid-cols-2">
        <legend class="px-1 text-sm font-semibold">{gettext("Defaults")}</legend>
        <div class="min-w-0">
          <label
            for="provider-field-default_model"
            class="mb-1 block text-xs font-medium text-base-content/70"
          >
            {gettext("Default model")}
          </label>
          <select
            id="provider-field-default_model"
            name="default_model"
            required
            class="select select-sm w-full min-w-0"
            aria-describedby="provider-default-model-help"
          >
            <option value="" selected={value(@fields, "default_model") == ""}>
              {gettext("Choose a default model")}
            </option>
            <option
              :for={model <- @default_models}
              value={model}
              selected={model == value(@fields, "default_model")}
            >
              {model}
            </option>
          </select>
          <p id="provider-default-model-help" class="mt-1 text-xs text-base-content/70">
            {gettext("Choose the default model. This does not create a model override.")}
          </p>
        </div>
        <.reasoning_default
          prefix=""
          fields={@fields}
          efforts={efforts(value(@fields, "reasoning_efforts", []))}
        />
      </fieldset>

      <details
        id="provider-profile-advanced"
        class="rounded-lg border border-base-300 bg-base-100 p-3"
        open={@advanced_open?}
      >
        <summary
          phx-click="toggle_profile_advanced"
          class="cursor-pointer rounded-md text-sm font-medium focus-visible:outline-2 focus-visible:outline-primary-standalone"
        >
          {gettext("Advanced")}
        </summary>
        <div class="mt-3 space-y-4">
          <fieldset class="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2">
            <legend class="mb-2 text-xs font-semibold">
              {gettext("Account identity and connection")}
            </legend>
            <.profile_field
              name="profile_id_new"
              label={gettext("Profile ID (optional)")}
              value={value(@fields, "profile_id_new", value(@fields, "id"))}
              help={
                gettext(
                  "Leave blank for an automatic ID. Use a distinct ID for another account with the same provider."
                )
              }
            />
            <.profile_field
              name="name"
              label={gettext("Display name (optional)")}
              value={value(@fields, "name")}
              help={
                gettext("An optional label to distinguish accounts. Existing names are preserved.")
              }
            />
            <.profile_field
              :if={not oauth?(@fields)}
              name="api_key_env_var"
              label={gettext("API key environment variable (optional)")}
              value={value(@fields, "api_key_env_var")}
              help={
                gettext(
                  "Enter the variable name, not the key. In API-key mode this exact variable is used on the selected node, with no fallback to another account's key. Clear it to use the provider's default credential source."
                )
              }
            />
            <.profile_field
              name="base_url"
              label={gettext("Base URL (optional)")}
              value={value(@fields, "base_url")}
              type="url"
              help={
                gettext(
                  "Leave blank for the provider endpoint. For an OpenAI-compatible service, choose OpenAI and enter its endpoint here."
                )
              }
            />
            <.profile_field
              name="concurrency"
              label={gettext("Shared concurrency")}
              value={value(@fields, "concurrency", 3)}
              type="number"
              min={0}
              help={
                gettext("All models in this account share this capacity. Zero pauses new requests.")
              }
            />
          </fieldset>

          <.schedule_editor fields={@fields} schedule={@schedule} />

          <.profile_field
            name="context_window"
            label={gettext("Shared context window (optional)")}
            value={value(@fields, "context_window")}
            type="number"
            min={1024}
            help={gettext("Leave blank for the runtime default. Models may override this value.")}
          />
          <.reasoning_fields
            prefix=""
            fields={@fields}
            suggestions={reasoning_suggestions(@fields)}
            show_default={false}
          />
          <details id="provider-generation-defaults" class="rounded-lg border border-base-300 p-3">
            <summary class="cursor-pointer rounded-md text-sm font-medium focus-visible:outline-2 focus-visible:outline-primary-standalone">
              {gettext("Shared generation defaults")}
            </summary>
            <p class="mt-2 text-xs text-base-content/70">
              {gettext(
                "Optional request parameters shared by every model. Unsupported parameters are filtered by the provider at request time."
              )}
            </p>
            <.generation_fields prefix="generation" fields={value(@fields, "generation", %{})} />
          </details>
        </div>
      </details>

      <.form_footer cancel_event="cancel_edit_provider_profile" save_label={gettext("Save account")} />
    </form>
    """
  end

  attr :model, :map, required: true
  attr :index, :any, required: true
  attr :provider, :map, required: true

  defp model_fields(assigns) do
    override? =
      value(assigns.model, "override_reasoning", Map.has_key?(assigns.model, "reasoning_efforts")) in [
        true,
        "true"
      ]

    assigns =
      assigns
      |> assign(:prefix, "models[#{assigns.index}]")
      |> assign(:override?, override?)

    ~H"""
    <fieldset class="min-w-0 space-y-2 rounded-lg border border-base-300 bg-base-200/30 p-3">
      <legend class="px-1 text-xs font-semibold">
        {gettext("Model %{number}", number: index_number(@index))}
      </legend>
      <div class="flex items-end gap-2">
        <div class="min-w-0 flex-1">
          <.profile_field
            name={@prefix <> "[model]"}
            label={gettext("Model name")}
            value={value(@model, "model")}
            required
          />
        </div>
        <button
          type="button"
          phx-click="remove_provider_model"
          phx-value-index={@index}
          class="btn btn-ghost btn-sm shrink-0 text-error"
          aria-label={gettext("Remove model %{number}", number: index_number(@index))}
          title={gettext("Remove model")}
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </div>
      <details id={"provider-model-details-#{@index}"} class="min-w-0">
        <summary class="cursor-pointer rounded-md text-xs font-medium text-base-content/70 focus-visible:outline-2 focus-visible:outline-primary-standalone">
          {gettext("Model details")}
        </summary>
        <div class="mt-3 space-y-3">
          <.profile_field
            name={@prefix <> "[context_window]"}
            label={gettext("Context window (optional)")}
            value={value(@model, "context_window")}
            type="number"
            min={1024}
            help={gettext("Leave blank to inherit the shared context window or runtime default.")}
          />
          <label class="flex items-center gap-2 text-xs font-medium text-base-content/80">
            <input type="hidden" name={@prefix <> "[override_reasoning]"} value="false" />
            <input
              type="checkbox"
              name={@prefix <> "[override_reasoning]"}
              value="true"
              checked={@override?}
              class="checkbox checkbox-sm"
            />
            {gettext("Override reasoning levels for this model")}
          </label>
          <.reasoning_fields
            :if={@override?}
            prefix={@prefix}
            fields={@model}
            suggestions={reasoning_suggestions(@provider, value(@model, "model"))}
            model_override
          />
          <div :if={not @override?} class="space-y-2">
            <p class="text-xs text-base-content/70">
              {gettext("Supported levels are inherited from the provider profile.")}
            </p>
            <.reasoning_default
              prefix={@prefix}
              fields={@model}
              efforts={efforts(value(@provider, "reasoning_efforts", []))}
              inherit
            />
          </div>
          <details
            id={"provider-model-generation-#{@index}"}
            class="rounded-md border border-base-300 bg-base-100 p-3"
          >
            <summary class="cursor-pointer rounded-md text-xs font-medium focus-visible:outline-2 focus-visible:outline-primary-standalone">
              {gettext("Generation overrides")}
            </summary>
            <p class="mt-2 text-xs text-base-content/70">
              {gettext("Blank values inherit the shared generation defaults.")}
            </p>
            <.generation_fields
              prefix={@prefix <> "[generation]"}
              fields={value(@model, "generation", %{})}
            />
          </details>
        </div>
      </details>
    </fieldset>
    """
  end

  # `nil` is the automatic rule (closed); the owner supplies an explicit
  # boolean once the user has toggled the disclosure, and that choice wins.
  defp advanced_open?(nil), do: false
  defp advanced_open?(value), do: value in [true, "true"]

  # Retain the current default even outside the override rows. The UI-only
  # default-only name is also an option; the owner synchronizes the selection
  # on change/save and strips the helper rather than inventing an override row.
  defp default_models(fields, models) do
    helper_names = if models == [], do: [value(fields, "default_model_name")], else: []

    ([value(fields, "default_model")] ++
       helper_names ++ Enum.map(models, fn {model, _} -> value(model, "model") end))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp index_number(index) when is_integer(index), do: index + 1

  defp index_number(index) do
    case Integer.parse(to_string(index)) do
      {number, ""} -> number + 1
      _ -> index
    end
  end
end
