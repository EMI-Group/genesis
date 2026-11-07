defmodule EvoDashWeb.SettingsComponents.ProviderProfilesEditor do
  @moduledoc """
  Presentation-only editor for canonical string-keyed `[[llm.providers]]` maps.

  The owning LiveView supplies `provider_profiles`, `default_provider_profile`,
  `editing_profile_id`, a string-keyed `profile_form_draft`, `auth_statuses`, and
  optional `errors` (field-name => message). Drafts have the same shape as the
  form: flat provider fields, indexed `models`/`peak_hours` maps, nested
  `generation` maps. They are shallow-merged over the saved provider, so an
  explicit blank or empty collection remains authoritative.
  `editing_profile_id: :new` opens the creation form; string ids (including
  `"new"`) identify saved profiles, so creation never also opens a saved row.

  Events: `add_provider_profile`, `edit_provider_profile` / `delete_provider_profile`
  (`profile_id`), `set_default_provider_profile` (`profile_id`),
  `provider_profile_form_change`, `save_provider_profile`,
  `cancel_edit_provider_profile`, `add_provider_model`, `remove_provider_model`
  (`index`), `add_provider_peak_hours_row`, `remove_provider_peak_hours_row`
  (`index`), and the existing `refresh_auth_status` (`profile_id`).

  Save/change payload: `profile_id` is the original id; `profile_id_new` is the
  editable id. Other names mirror canonical keys except `reasoning_efforts`
  is a comma-separated ordered string and model `override_reasoning` is a UI
  boolean sentinel. A false model override omits its reasoning inventory but
  may still set a default from the inherited inventory; true plus a blank
  inventory persists `[]` (unsupported reasoning) and omits its default.
  `generation[provider_options]` is JSON text, not a persisted string.
  The owner validates and parses all numeric, JSON, list and boolean values.
  Empty optional fields inherit defaults; blank model generation overrides
  should be omitted, not saved as nil. No credential values enter this UI.

  Auth statuses use the existing node-scoped status shape keyed by provider
  profile id. Missing/unknown status never claims that login is missing, and
  managed paths come ONLY from that status or the explicitly configured path.
  """

  use EvoDashWeb, :html

  import EvoDashWeb.SettingsComponents.FormFooter, only: [form_footer: 1]
  import EvoDashWeb.SettingsComponents.ProviderProfileFields

  attr(:provider_profiles, :list, default: [])
  attr(:default_provider_profile, :string, default: nil)
  attr(:editing_profile_id, :any, default: nil)
  attr(:profile_form_draft, :any, default: nil)
  attr(:auth_statuses, :map, default: %{})
  attr(:errors, :map, default: %{})

  def provider_profiles_editor(assigns) do
    assigns = assign(assigns, :profiles, Enum.filter(assigns.provider_profiles, &is_map/1))

    ~H"""
    <section
      id="provider-profiles-editor"
      class="mb-6 min-w-0 space-y-4"
      aria-labelledby="provider-profiles-title"
    >
      <header class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <%!-- zh_CN: 提供商配置共享认证、连接和并发设置，下面可包含多个模型。 --%>
          <h3 id="provider-profiles-title" class="text-base font-semibold">
            {gettext("Provider profiles")}
          </h3>
          <p class="mt-1 text-sm text-base-content/70">
            {gettext(
              "Share connection, authentication and capacity across multiple models. Override only what each model needs."
            )}
          </p>
        </div>
        <button type="button" phx-click="add_provider_profile" class="btn btn-primary btn-sm gap-2">
          <.icon name="hero-plus" class="size-4" />{gettext("Add provider profile")}
        </button>
      </header>

      <div
        :if={@profiles == []}
        class="rounded-lg border border-dashed border-base-300 p-6 text-center"
      >
        <.icon name="hero-server-stack" class="mb-2 size-7 text-primary-standalone" />
        <p class="text-sm font-medium">{gettext("No provider profiles configured")}</p>
        <p class="mt-1 text-xs text-base-content/70">
          {gettext("Add a provider profile, then choose its models and defaults.")}
        </p>
      </div>

      <p
        :if={
          @default_provider_profile not in [nil, ""] and
            not Enum.any?(@profiles, &(value(&1, "id") == @default_provider_profile))
        }
        role="status"
        class="rounded-lg border border-warning/30 bg-warning/10 p-3 text-sm text-warning"
      >
        {gettext("The default provider profile is unavailable: %{id}", id: @default_provider_profile)}
      </p>

      <.edit_form
        :if={@editing_profile_id == :new and is_map(@profile_form_draft)}
        profile={%{}}
        draft={@profile_form_draft}
        errors={@errors}
      />
      <%= for {profile, index} <- Enum.with_index(@profiles) do %>
        <.edit_form
          :if={@editing_profile_id == value(profile, "id")}
          profile={profile}
          draft={@profile_form_draft}
          auth_status={Map.get(@auth_statuses, value(profile, "id"))}
          errors={@errors}
        />
        <.profile_row
          :if={@editing_profile_id != value(profile, "id")}
          profile={profile}
          index={index}
          default?={@default_provider_profile == value(profile, "id")}
          auth_status={Map.get(@auth_statuses, value(profile, "id"))}
        />
      <% end %>
    </section>
    """
  end

  attr(:profile, :map, required: true)
  attr(:index, :integer, required: true)
  attr(:default?, :boolean, required: true)
  attr(:auth_status, :any, default: nil)

  defp profile_row(assigns) do
    assigns = assign(assigns, :models, indexed_rows(value(assigns.profile, "models", [])))

    ~H"""
    <article
      class="min-w-0 rounded-lg border border-base-300 bg-base-100 p-4"
      aria-labelledby={"provider-profile-#{@index}-title"}
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <.icon name="hero-server-stack" class="size-4 shrink-0 text-primary-standalone" />
            <h4 id={"provider-profile-#{@index}-title"} class="break-words text-sm font-semibold">
              {value(@profile, "name", value(@profile, "id"))}
            </h4>
            <span :if={@default?} class="badge badge-primary badge-sm">{gettext("Default")}</span>
            <span class="badge badge-ghost badge-sm">{if oauth?(@profile),
              do: gettext("Subscription (OAuth)"),
              else: gettext("API key")}</span>
          </div>
          <p class="mt-1 break-all font-mono text-xs text-base-content/70">
            {value(@profile, "id")} · {value(@profile, "provider")}
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-1">
          <button
            :if={not @default?}
            type="button"
            phx-click="set_default_provider_profile"
            phx-value-profile_id={value(@profile, "id")}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Make default")}
          </button>
          <button
            type="button"
            phx-click="edit_provider_profile"
            phx-value-profile_id={value(@profile, "id")}
            class="btn btn-ghost btn-sm gap-1"
            aria-label={gettext("Edit %{name}", name: value(@profile, "id"))}
          >
            <.icon name="hero-pencil-square" class="size-4" />{gettext("Edit")}
          </button>
          <button
            type="button"
            phx-click="delete_provider_profile"
            phx-value-profile_id={value(@profile, "id")}
            data-confirm={gettext("Delete this provider profile and its models?")}
            class="btn btn-ghost btn-sm text-error"
            aria-label={gettext("Delete %{name}", name: value(@profile, "id"))}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </div>
      <dl class="mt-3 grid grid-cols-1 gap-2 text-xs sm:grid-cols-3">
        <div>
          <dt class="text-base-content/70">{gettext("Shared concurrency")}</dt><dd class="mt-1 font-mono">
            {value(@profile, "concurrency", 3)}
          </dd>
        </div>
        <div>
          <dt class="text-base-content/70">{gettext("Default model")}</dt><dd class="mt-1 break-all font-mono">
            {value(@profile, "default_model", gettext("Not set"))}
          </dd>
        </div>
        <div>
          <dt class="text-base-content/70">{gettext("Peak concurrency")}</dt><dd class="mt-1 font-mono">
            {value(@profile, "peak_concurrency", gettext("Not set"))}
          </dd>
        </div>
      </dl>
      <ul
        :if={@models != []}
        class="mt-3 flex flex-wrap gap-2"
        aria-label={gettext("Configured models")}
      >
        <li
          :for={{model, _} <- @models}
          class="min-w-0 max-w-full rounded-md border border-base-300 bg-base-200/40 px-2 py-1 text-xs"
        >
          <code class="break-all">{value(model, "model")}</code>
          <span
            :if={value(model, "model") == value(@profile, "default_model")}
            class="ml-1 text-primary-standalone"
          >{gettext("Default")}</span>
        </li>
      </ul>
      <.provider_auth_status
        :if={oauth?(@profile)}
        status={@auth_status}
        profile={@profile}
        details={false}
      />
    </article>
    """
  end

  attr(:profile, :map, required: true)
  attr(:draft, :any, default: nil)
  attr(:auth_status, :any, default: nil)
  attr(:errors, :map, default: %{})

  defp edit_form(assigns) do
    fields = Map.merge(assigns.profile, if(is_map(assigns.draft), do: assigns.draft, else: %{}))
    models = indexed_rows(value(fields, "models", []))

    same_credential_scope? =
      Enum.all?(["provider", "oauth_file"], &(value(fields, &1) == value(assigns.profile, &1))) and
        oauth?(fields) == oauth?(assigns.profile)

    assigns =
      assigns
      |> assign(:auth_status, if(same_credential_scope?, do: assigns.auth_status, else: nil))
      |> assign(:fields, fields)
      |> assign(:models, models)

    ~H"""
    <form
      id="provider-profile-edit-form"
      phx-submit="save_provider_profile"
      phx-change="provider_profile_form_change"
      aria-labelledby="provider-profile-settings-title"
      aria-describedby={map_size(@errors) > 0 && "provider-profile-errors"}
      class="min-w-0 space-y-5 rounded-lg border border-primary-standalone/50 bg-base-100 p-4"
    >
      <input type="hidden" name="profile_id" value={value(@profile, "id")} />
      <h4 id="provider-profile-settings-title" class="text-sm font-semibold">
        {gettext("Provider profile settings")}
      </h4>
      <div
        :if={map_size(@errors) > 0}
        id="provider-profile-errors"
        role="alert"
        class="rounded-lg border border-error/30 bg-error/10 p-3 text-sm text-error"
      >
        <p class="font-medium">{gettext("Check the profile settings before saving.")}</p>
        <ul class="mt-1 list-inside list-disc">
          <li :for={{field, message} <- Enum.sort(@errors)}><code>{field}</code>: {message}</li>
        </ul>
      </div>
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.profile_field
          name="profile_id_new"
          label={gettext("Profile ID")}
          value={value(@fields, "profile_id_new", value(@fields, "id"))}
          required
          help={gettext("Stable identifier used by task selections and model rules.")}
        />
        <.profile_field name="name" label={gettext("Display name")} value={value(@fields, "name")} />
        <.profile_field
          name="provider"
          label={gettext("Provider")}
          value={value(@fields, "provider")}
          required
          help={gettext("Provider identifier, such as openai, anthropic or openai_codex.")}
        />
        <.profile_field
          name="base_url"
          label={gettext("Base URL (optional)")}
          value={value(@fields, "base_url")}
          type="url"
          help={
            gettext(
              "Shared endpoint for every model in this profile. Leave blank for the provider default."
            )
          }
        />
      </div>

      <fieldset class="min-w-0 space-y-3 rounded-lg border border-base-300 p-3">
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
              <span class="badge badge-secondary badge-sm">{gettext("Subscription (OAuth)")}</span>
            </div>
          </div>
          <.profile_field
            :if={oauth?(@fields)}
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
            "Configure the provider's API key in the selected node's credentials file or environment. Keys are never displayed or copied into this profile form."
          )}
        </p>
      </fieldset>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <.profile_field
          name="concurrency"
          label={gettext("Shared concurrency")}
          value={value(@fields, "concurrency", 3)}
          type="number"
          min={1}
          required
          help={gettext("All models in this provider profile share this capacity.")}
        />
        <.profile_field
          name="default_model"
          label={gettext("Default model")}
          value={value(@fields, "default_model")}
          required
          help={gettext("Any model served by this provider; override rows below are optional.")}
        />
        <.profile_field
          name="context_window"
          label={gettext("Shared context window (optional)")}
          value={value(@fields, "context_window")}
          type="number"
          min={1024}
          help={gettext("Leave blank for the runtime default. Models may override this value.")}
        />
      </div>
      <.reasoning_fields prefix="" fields={@fields} />
      <.provider_schedule fields={@fields} />

      <section class="space-y-3" aria-labelledby="provider-models-title">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h5 id="provider-models-title" class="text-sm font-semibold">{gettext("Models")}</h5>
            <p class="mt-1 text-xs text-base-content/70">
              {gettext("Models inherit provider defaults unless an override is set.")}
            </p>
          </div>
          <button type="button" phx-click="add_provider_model" class="btn btn-outline btn-sm gap-1"><.icon
            name="hero-plus"
            class="size-4"
          />{gettext("Add model")}</button>
        </div>
        <p
          :if={@models == []}
          class="rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/70"
        >
          {gettext("Model overrides are optional. Enter a default model above to save this profile.")}
        </p>
        <.model_fields
          :for={{model, index} <- @models}
          model={model}
          index={index}
          provider={@fields}
        />
      </section>

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
      <.form_footer
        cancel_event="cancel_edit_provider_profile"
        save_label={gettext("Save provider profile")}
      />
    </form>
    """
  end

  attr(:model, :map, required: true)
  attr(:index, :any, required: true)
  attr(:provider, :map, required: true)

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
    <fieldset class="min-w-0 space-y-3 rounded-lg border border-base-300 bg-base-200/30 p-3">
      <legend class="px-1 text-xs font-semibold">
        {gettext("Model %{number}", number: index_number(@index))}
      </legend>
      <div class="grid grid-cols-1 items-start gap-3 sm:grid-cols-2">
        <.profile_field
          name={@prefix <> "[model]"}
          label={gettext("Model ID")}
          value={value(@model, "model")}
          required
        />
        <.profile_field
          name={@prefix <> "[context_window]"}
          label={gettext("Context window (optional)")}
          value={value(@model, "context_window")}
          type="number"
          min={1024}
          help={gettext("Leave blank to inherit the shared context window or runtime default.")}
        />
      </div>
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
      <.reasoning_fields :if={@override?} prefix={@prefix} fields={@model} model_override />
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
      <div class="flex justify-end">
        <button
          type="button"
          phx-click="remove_provider_model"
          phx-value-index={@index}
          class="btn btn-ghost btn-xs gap-1 text-error"
          aria-label={gettext("Remove model %{number}", number: index_number(@index))}
        >
          <.icon name="hero-trash" class="size-3.5" />{gettext("Remove model")}
        </button>
      </div>
    </fieldset>
    """
  end

  defp index_number(index) when is_integer(index), do: index + 1

  defp index_number(index) do
    case Integer.parse(to_string(index)) do
      {number, ""} -> number + 1
      _ -> index
    end
  end
end
