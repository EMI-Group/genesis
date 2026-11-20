defmodule EvoDashWeb.SettingsComponents.ProviderProfiles.Row do
  @moduledoc """
  One compact summary row of the `/settings` provider-account list.

  The row is the ONLY place an account appears in the collapsed list: provider
  display name, account name + mono id, the configured model chips, the shared
  slot count, a schedule badge and the authentication badge. Clicking the row
  (or its Edit action) expands the account in place.

  `schedule_badge/1` and `model_chips/1` are PURE, total derivations over the
  string-keyed `provider_editor_fields/1` profile shape and are pinned by
  `test/evo_dash_web/components/provider_profiles/row_test.exs`.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.LLMSetup.Identity

  import EvoDashWeb.SettingsComponents.ProviderProfileFields,
    only: [indexed_rows: 1, oauth?: 1, provider_auth_status: 1, value: 2, value: 3]

  @doc """
  Renders one account row of the provider-account list.

  The account id is never invented here — it comes from the profile's own
  `id` (an account is identified by its provider-derived identity, never by
  one of its models).
  """
  attr :profile, :map, required: true
  attr :default?, :boolean, default: false
  attr :expanded?, :boolean, default: false
  attr :auth_status, :any, default: nil
  attr :disabled, :boolean, default: false
  # Page-owned in-browser ChatGPT sign-in state + the local/remote verdict.
  # The collapsed row never renders the sign-in control (`details: false`), so
  # these only have to exist for the shared auth-status component.
  attr :chatgpt_sign_in, :map, default: %{}
  attr :chatgpt_sign_in_manual, :boolean, default: false

  def profile_row(assigns) do
    id = value(assigns.profile, "id")

    assigns =
      assigns
      |> assign(:id, id)
      |> assign(:slug, slug(id))
      |> assign(
        :provider_name,
        Identity.provider_display_name(value(assigns.profile, "provider"))
      )
      |> assign(:account_name, value(assigns.profile, "name"))
      |> assign(:auth_label, auth_label(assigns.profile))
      |> assign(:oauth?, oauth?(assigns.profile))
      |> assign(:chips, model_chips(assigns.profile))
      |> assign(:slots, slots_text(assigns.profile))
      |> assign(:schedule, schedule_badge(assigns.profile))

    ~H"""
    <div id={"provider-profile-" <> @slug} class="px-4 py-3" data-expanded={to_string(@expanded?)}>
      <div class="flex flex-wrap items-start justify-between gap-x-3 gap-y-2">
        <button
          type="button"
          phx-click="edit_provider_profile"
          phx-value-profile_id={@id}
          aria-expanded={to_string(@expanded?)}
          class="min-w-0 flex-1 rounded-md text-left focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-standalone"
        >
          <span class="flex flex-wrap items-center gap-2">
            <span class="truncate text-sm font-semibold text-base-content">{@provider_name}</span>
            <span :if={@default?} class="badge badge-primary badge-sm">{gettext("Default")}</span>
            <span class="badge badge-ghost badge-sm">{@auth_label}</span>
          </span>
          <span class="mt-1 flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
            <span
              :if={@account_name not in [nil, ""]}
              class="text-xs font-medium text-base-content/80"
            >
              {@account_name}
            </span>
            <code class="font-mono text-[11px] text-base-content/60">{@id}</code>
          </span>
          <span class="mt-2 flex flex-wrap items-center gap-1.5">
            <span :for={chip <- @chips} class={chip_class(chip)}>
              {chip.model}<span :if={chip.default?} class="ml-1 text-base-content/50">*</span>
            </span>
            <span class="text-[11px] text-base-content/60">{@slots}</span>
            <span class="text-[11px] text-base-content/40" aria-hidden="true">·</span>
            <span class="text-[11px] text-base-content/60">{@schedule}</span>
          </span>
        </button>
        <div class="flex flex-wrap items-center gap-1">
          <button
            :if={not @default?}
            type="button"
            phx-click="set_default_provider_profile"
            phx-value-profile_id={@id}
            disabled={@disabled}
            class="btn btn-ghost btn-xs"
          >
            {gettext("Make default")}
          </button>
          <button
            type="button"
            phx-click="start_add_provider_model"
            phx-value-profile_id={@id}
            disabled={@disabled}
            class="btn btn-ghost btn-xs"
          >
            {gettext("Add model")}
          </button>
          <button
            type="button"
            phx-click="edit_provider_profile"
            phx-value-profile_id={@id}
            disabled={@disabled}
            class="btn btn-ghost btn-xs gap-1"
          >
            <.icon name="hero-pencil-square" class="size-3.5" />{gettext("Edit")}
          </button>
          <button
            type="button"
            phx-click="delete_provider_profile"
            phx-value-profile_id={@id}
            disabled={@disabled}
            data-confirm={gettext("Delete this provider account?")}
            aria-label={gettext("Delete account %{name}", name: @provider_name)}
            class="btn btn-ghost btn-xs text-error"
          >
            <.icon name="hero-trash" class="size-3.5" />
          </button>
        </div>
      </div>
      <.provider_auth_status
        :if={@oauth?}
        profile={@profile}
        status={@auth_status}
        details={false}
        chatgpt_sign_in={@chatgpt_sign_in}
        chatgpt_sign_in_manual={@chatgpt_sign_in_manual}
      />
    </div>
    """
  end

  @doc """
  One-line schedule summary: `"Peak 2/4 · CN holidays"` when the account runs a
  peak schedule with a public-holiday calendar, `"Peak 2/4"` with only a peak
  concurrency, `"No schedule"` otherwise.
  """
  def schedule_badge(profile) do
    case peak_concurrency(profile) do
      nil ->
        gettext("No schedule")

      peak ->
        # zh_CN: 高峰并发（按 provider 账户共享的槽位）
        badge =
          gettext("Peak %{peak}/%{base}",
            peak: to_string(peak),
            base: to_string(base_concurrency(profile))
          )

        case holiday(profile) do
          "" -> badge
          calendar -> badge <> " · " <> gettext("%{calendar} holidays", calendar: calendar)
        end
    end
  end

  @doc """
  The account's configured model chips: the default model first, then every
  other configured model, deduplicated. Each chip is `%{model: id, default?: bool}`.
  """
  def model_chips(profile) do
    default_model = profile |> value("default_model", nil) |> text()

    configured =
      profile
      |> value("models", [])
      |> indexed_rows()
      |> Enum.map(fn {row, _index} -> row |> value("model", nil) |> text() end)

    models = Enum.uniq([default_model | configured]) |> Enum.reject(&(&1 == ""))

    Enum.map(models, &%{model: &1, default?: &1 == default_model and default_model != ""})
  end

  @doc """
  The account id of a profile/draft map (`nil` when blank).

  The account is identified by its provider-derived identity, never by one of
  its models, so `model_chips/1` can never be mistaken for the account name.
  """
  def profile_id(profile) do
    case text(value(profile, "id", nil)) do
      "" -> nil
      id -> id
    end
  end

  @doc "The URL-safe, nonempty anchor segment derived from an account id."
  def slug(id) do
    slug =
      id
      |> text()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    if slug == "", do: "account", else: slug
  end

  defp chip_class(%{default?: true}), do: "badge badge-primary badge-sm font-mono"
  defp chip_class(_chip), do: "badge badge-ghost badge-sm font-mono"

  defp auth_label(profile) do
    if oauth?(profile) do
      gettext("Subscription (OAuth)")
    else
      gettext("API key")
    end
  end

  defp slots_text(profile) do
    # zh_CN: 槽位（该账户所有模型共享的并发数）
    gettext("%{count} slots", count: to_string(base_concurrency(profile)))
  end

  defp base_concurrency(profile) do
    case integer(profile |> value("concurrency", nil)) do
      nil -> 3
      count -> count
    end
  end

  defp peak_concurrency(profile) do
    integer(profile |> value("peak_concurrency", nil))
  end

  defp holiday(profile), do: profile |> value("off_peak_holidays", nil) |> text()

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp integer(_value), do: nil

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_atom(value), do: value |> Atom.to_string() |> text()
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_value), do: ""
end
