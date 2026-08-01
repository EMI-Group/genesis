defmodule EvoDashWeb.SettingsComponents.ModelProfilesEditor do
  @moduledoc """
  `model_profiles_editor/1` — List editor for [[llm.models]] profiles.
  """

  # zh_CN: Provider → "服务商", Concurrency → "并发", Token → "词元"

  use EvoDashWeb, :html

  import EvoDashWeb.SettingsComponents.SettingCard, only: [model_display: 1]

  # ───────────────────────────────────────────────────────────────────────────
  # model_profiles_editor/1 — List editor for [[llm.models]] profiles
  # ───────────────────────────────────────────────────────────────────────────

  attr(:profiles, :list, default: [])
  attr(:editing_profile_id, :any, default: nil)

  def model_profiles_editor(assigns) do
    ~H"""
    <div class="mb-6 rounded-lg border border-base-200 bg-base-100 p-5">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h3 class="text-lg font-bold text-base-content mb-0.5">{gettext("Model Profiles")}</h3>

          <p class="text-sm text-base-content/80">
            <%!-- zh_CN: concurrency → "并发" --%>{gettext(
              "Configure one or more LLM models. Each profile can have its own concurrency and generation parameters."
            )}
          </p>
        </div>

        <button
          type="button"
          phx-click="add_model_profile"
          class="btn btn-primary btn-sm gap-2 shrink-0"
        >
          <.icon name="hero-plus" class="size-4" /> {gettext("Add Model")}
        </button>
      </div>

      <%= if @profiles == [] do %>
        <div class="flex flex-col items-center justify-center py-10 text-center border-2 border-dashed border-base-300 rounded-lg">
          <div class="text-base-content/30 mb-3">
            <.icon name="hero-cpu-chip" class="size-8" />
          </div>

          <p class="text-sm text-base-content/70 font-medium mb-1">
            {gettext("No model profiles configured")}
          </p>

          <p class="text-xs text-base-content/60">
            {gettext("Add a profile to get started, or use Quick Setup above.")}
          </p>
        </div>
      <% else %>
        <div class="space-y-3">
          <%= for profile <- @profiles do %>
            <% id = profile_id_string(profile) %>
            <%= if @editing_profile_id == id do %>
              <.model_profile_edit_form profile={profile} />
            <% else %>
              <.model_profile_row profile={profile} />
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Read-only summary row for a single profile ──

  attr(:profile, :map, required: true)

  defp model_profile_row(assigns) do
    ~H"""
    <div class="flex items-start gap-4 p-4 rounded-lg border border-base-200 bg-base-100 hover:bg-base-200/30 transition-colors">
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 mb-1.5">
          <.icon name="hero-cpu-chip" class="size-4 text-primary shrink-0" />
          <code class="font-mono text-sm font-bold text-base-content">{profile_id_string(@profile)}</code>
          <%= if profile_concurrency(@profile) do %>
            <span class="badge badge-ghost badge-sm gap-1 font-mono text-xs">
              <.icon name="hero-arrows-right-left" class="size-3" /> {gettext("%{n} slots",
                n: profile_concurrency(@profile)
              )}
            </span>
          <% end %>
        </div>

        <div class="flex items-center gap-2 mb-1.5">
          <code class="font-mono text-xs text-primary/80 break-all">{model_display(
            @profile[:model] || @profile["model"]
          )}</code>
        </div>

        <%= if summary = profile_params_summary(@profile) do %>
          <p class="text-xs text-base-content/60 font-mono mt-1">{summary}</p>
        <% end %>
      </div>

      <div class="flex items-center gap-1 shrink-0">
        <button
          type="button"
          phx-click="edit_model_profile"
          phx-value-profile_id={profile_id_string(@profile)}
          class="btn btn-ghost btn-sm gap-1"
        >
          <.icon name="hero-pencil-square" class="size-4" /> {gettext("Edit")}
        </button>

        <button
          type="button"
          phx-click="delete_model_profile"
          phx-value-profile_id={profile_id_string(@profile)}
          class="btn btn-ghost btn-sm text-error gap-1"
          data-confirm={gettext("Delete this model profile?")}
        >
          <.icon name="hero-trash" class="size-4" /> {gettext("Delete")}
        </button>
      </div>
    </div>
    """
  end

  # ── Editable form for a single profile ──

  attr(:profile, :map, required: true)

  defp model_profile_edit_form(assigns) do
    ~H"""
    <form
      phx-submit="save_model_profile"
      class="p-4 rounded-lg border-2 border-primary/40 bg-base-100 space-y-4"
    >
      <input type="hidden" name="profile_id" value={profile_id_string(@profile)} />
      <div class="flex items-center gap-2 mb-1">
        <.icon name="hero-pencil-square" class="size-5 text-primary" />
        <h4 class="font-bold text-sm text-base-content">{gettext("Edit Profile")}</h4>
      </div>

      <%!-- id + provider/model-id/base-url (required fields) ── ── --%> <% {provider_val,
       model_id_val, base_url_val, extra_val} = profile_model_fields(@profile) %> <% provider_options_val =
        profile_provider_options(@profile) %>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-semibold text-xs">{gettext("Profile ID")}
            <span class="text-error">*</span></span>
          </label>

          <input
            type="text"
            name="profile_id_new"
            value={profile_id_string(@profile)}
            placeholder="default"
            class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            required
          />
          <p class="text-[11px] text-base-content/60 mt-1">
            {gettext("A unique identifier for this profile")}
          </p>
        </div>

        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-semibold text-xs"><%!-- zh_CN: Provider → "服务商" --%>{gettext(
              "Provider"
            )}</span>
          </label>

          <input
            type="text"
            name="provider"
            value={provider_val}
            placeholder={gettext("e.g. anthropic, openai")}
            class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
          />
          <p class="text-[11px] text-base-content/60 mt-1">
            <%!-- zh_CN: provider → "服务商" --%>{gettext("The LLM provider name")}
          </p>
        </div>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-semibold text-xs">{gettext("Model ID")}
            <span class="text-error">*</span></span>
          </label>

          <input
            type="text"
            name="model_id"
            value={model_id_val}
            placeholder={gettext("e.g. claude-sonnet-4-6")}
            class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            required
          />
          <p class="text-[11px] text-base-content/60 mt-1">
            {gettext("The model name")}
          </p>
        </div>

        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-semibold text-xs">{gettext("Base URL")}</span>
          </label>

          <input
            type="text"
            name="base_url"
            value={base_url_val}
            placeholder={gettext("https://api.my-provider.com/v1")}
            class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
          />
          <p class="text-[11px] text-base-content/60 mt-1">
            <%!-- zh_CN: provider → "服务商" --%>{gettext(
              "For proxy/aggregator endpoints; leave empty for standard providers."
            )}
          </p>
        </div>
      </div>
      <%!-- concurrency ── --%>
      <div class="form-control">
        <label class="label pb-1">
          <span class="label-text font-semibold text-xs"><%!-- zh_CN: Concurrency → "并发" --%>{gettext(
            "Concurrency"
          )}</span>
        </label>

        <input
          type="number"
          name="concurrency"
          value={profile_concurrency(@profile) || 3}
          min="1"
          class="input input-bordered input-sm rounded-md w-full sm:w-44 font-mono text-sm"
        />
        <p class="text-[11px] text-base-content/60 mt-1">
          {gettext("Number of parallel LLM request slots")}
        </p>
      </div>
      <%!-- Generation params ── collapsible-ish section ── --%>
      <div class="pt-2">
        <div class="flex items-center gap-3 mb-3">
          <div class="h-px bg-base-200 flex-1"></div>

          <span class="text-xs font-bold uppercase tracking-widest text-base-content/60">{gettext(
            "Generation Parameters"
          )}</span> <span class="text-[11px] text-base-content/50">{gettext("optional")}</span>
          <div class="h-px bg-base-200 flex-1"></div>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          <%!-- Temperature ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Temperature")}</span>
            </label>

            <input
              type="number"
              step="0.01"
              name="temperature"
              value={profile_param(@profile, :temperature)}
              min="0"
              max="2"
              placeholder={gettext("empty")}
              class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            />
          </div>
          <%!-- Reasoning effort ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Reasoning Effort")}</span>
            </label>

            <div class="relative">
              <select
                name="reasoning_effort"
                class="select select-bordered select-sm rounded-md w-full font-mono text-sm appearance-none pr-8"
              >
                <option value="" selected={is_nil(profile_param(@profile, :reasoning_effort))}>
                  {gettext("(provider default)")}
                </option>

                <%= for opt <- ~w(none minimal low medium high xhigh default) do %>
                  <option
                    value={opt}
                    selected={to_string(profile_param(@profile, :reasoning_effort)) == opt}
                  >
                    {opt}
                  </option>
                <% end %>
              </select>

              <div class="pointer-events-none absolute inset-y-0 right-0 flex items-center px-2 text-base-content/70">
                <.icon name="hero-chevron-down" class="size-4" />
              </div>
            </div>
          </div>
          <%!-- Max tokens ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs"><%!-- zh_CN: Token → "词元" --%>{gettext(
                "Max Tokens"
              )}</span>
            </label>

            <input
              type="number"
              name="max_tokens"
              value={profile_param(@profile, :max_tokens)}
              min="1"
              placeholder={gettext("empty")}
              class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            />
          </div>
          <%!-- Top P ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Top P")}</span>
            </label>

            <input
              type="number"
              step="0.01"
              name="top_p"
              value={profile_param(@profile, :top_p)}
              min="0"
              max="1"
              placeholder={gettext("empty")}
              class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            />
          </div>
          <%!-- Top K ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Top K")}</span>
            </label>

            <input
              type="number"
              name="top_k"
              value={profile_param(@profile, :top_k)}
              min="1"
              placeholder={gettext("empty")}
              class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            />
          </div>
          <%!-- Frequency penalty ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Frequency Penalty")}</span>
            </label>

            <input
              type="number"
              step="0.01"
              name="frequency_penalty"
              value={profile_param(@profile, :frequency_penalty)}
              min="-2"
              max="2"
              placeholder={gettext("empty")}
              class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            />
          </div>
          <%!-- Presence penalty ── --%>
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-semibold text-xs">{gettext("Presence Penalty")}</span>
            </label>

            <input
              type="number"
              step="0.01"
              name="presence_penalty"
              value={profile_param(@profile, :presence_penalty)}
              min="-2"
              max="2"
              placeholder={gettext("empty")}
              class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            />
          </div>
        </div>
      </div>
      <%!-- Extra config ── --%>
      <div class="form-control pt-2">
        <label class="label pb-1">
          <span class="label-text font-semibold text-xs">{gettext("Extra Config (JSON)")}</span>
        </label>
        <textarea
          name="extra"
          placeholder='{"wire": {"protocol": "openai_responses"}}'
          class="textarea textarea-bordered textarea-sm rounded-md w-full font-mono text-sm h-20 resize-y"
          rows="3"
        ><%= extra_val %></textarea>
        <p class="text-[11px] text-base-content/60 mt-1">
          {gettext("Advanced provider-specific options merged into the model spec map.")}
        </p>
      </div>
      <%!-- Provider Options config ── --%>
      <div class="form-control pt-2">
        <label class="label pb-1">
          <span class="label-text font-semibold text-xs">{gettext("Provider Options (JSON)")}</span>
        </label>
        <textarea
          name="provider_options"
          placeholder='{"store": false}'
          class="textarea textarea-bordered textarea-sm rounded-md w-full font-mono text-sm h-20 resize-y"
          rows="3"
        ><%= provider_options_val %></textarea>
        <p class="text-[11px] text-base-content/60 mt-1">
          {gettext(
            "Provider-specific options passed to the LLM API. For OpenAI, 'store' defaults to false automatically."
          )}
        </p>
      </div>
      <%!-- Action buttons ── --%>
      <div class="flex items-center justify-end gap-2 pt-2 border-t border-base-200">
        <button type="button" phx-click="cancel_edit_model_profile" class="btn btn-ghost btn-sm">
          {gettext("Cancel")}
        </button>

        <button type="submit" class="btn btn-primary btn-sm gap-1">
          <.icon name="hero-check" class="size-4" /> {gettext("Save Profile")}
        </button>
      </div>
    </form>
    """
  end

  # ── Model profile helpers ──
  # These safely read from profile maps that may have atom OR string keys
  # (TOML-parsed profiles can arrive with string keys before normalization).

  defp profile_id_string(profile) when is_map(profile) do
    case Map.get(profile, :id) || Map.get(profile, "id") do
      nil -> ""
      id -> to_string(id)
    end
  end

  defp profile_id_string(_), do: ""

  defp profile_concurrency(profile) when is_map(profile) do
    Map.get(profile, :concurrency) || Map.get(profile, "concurrency")
  end

  defp profile_concurrency(_), do: nil

  defp profile_param(profile, key) when is_map(profile) and is_atom(key) do
    Map.get(profile, key) || Map.get(profile, Atom.to_string(key))
  end

  defp profile_param(_, _), do: nil

  # Extracts {provider_str, model_id_str, base_url_str} from a profile's model
  # value for pre-filling the edit form. Handles ALL three shapes the model can
  # arrive in (after config resolution, map specs have atom keys + atom provider):
  #
  #   * MAP %{provider: p, id: i, base_url: b} (current format) — pre-fills
  #     provider=to_string(p), model_id=i, base_url=b (or ""). Handles both
  #     atom and string keys.
  #   * STRING "provider:id" (legacy) — splits on the FIRST colon only; model
  #     ids may themselves contain colons. base_url empty.
  #   * nil → all empty.
  defp profile_model_fields(profile) when is_map(profile) do
    model = Map.get(profile, :model) || Map.get(profile, "model")
    model_model_fields(model)
  end

  defp profile_model_fields(_), do: {"", "", "", ""}

  # Extracts the profile-level provider_options value (a sibling of temperature,
  # max_tokens, etc.) and JSON-encodes it for pre-filling the edit form.
  # Returns "" if nil/absent.
  defp profile_provider_options(profile) when is_map(profile) do
    case Map.get(profile, :provider_options) || Map.get(profile, "provider_options") do
      nil ->
        ""

      options ->
        case Jason.encode(options) do
          {:ok, json} -> json
          {:error, _} -> ""
        end
    end
  end

  defp profile_provider_options(_), do: ""

  defp model_model_fields(nil), do: {"", "", "", ""}

  defp model_model_fields(model) when is_map(model) do
    provider = model[:provider] || model["provider"]
    id = model[:id] || model["id"]
    base_url = model[:base_url] || model["base_url"]
    extra = model[:extra] || model["extra"]

    provider_str = if is_nil(provider), do: "", else: to_string(provider)
    id_str = if is_nil(id), do: "", else: to_string(id)
    base_url_str = if is_nil(base_url), do: "", else: to_string(base_url)

    extra_str =
      cond do
        is_nil(extra) ->
          ""

        true ->
          case Jason.encode(extra) do
            {:ok, json} -> json
            {:error, _} -> ""
          end
      end

    {provider_str, id_str, base_url_str, extra_str}
  end

  defp model_model_fields(model) when is_binary(model) do
    case :binary.split(model, ":") do
      [provider, id] ->
        {provider, id, "", ""}

      [_no_colon] ->
        {"", model, "", ""}
    end
  end

  defp model_model_fields({provider, opts}) when is_atom(provider) and is_list(opts) do
    provider_str = to_string(provider)
    id_str = Keyword.get(opts, :id, "") |> to_string()
    base_url_str = Keyword.get(opts, :base_url, "") |> to_string()
    {provider_str, id_str, base_url_str, ""}
  end

  # Builds a compact summary string of generation params, e.g.
  # "temp: 0.7, max_tokens: 4096". Returns nil if no params are set.
  defp profile_params_summary(profile) when is_map(profile) do
    parts =
      [
        {:temperature, gettext("temp")},
        {:max_tokens, gettext("max_tokens")},
        {:reasoning_effort, gettext("reasoning")},
        {:top_p, gettext("top_p")},
        {:top_k, gettext("top_k")},
        {:frequency_penalty, gettext("freq_penalty")},
        {:presence_penalty, gettext("pres_penalty")}
      ]
      |> Enum.map(fn {key, label} ->
        value = profile_param(profile, key)
        if is_nil(value), do: nil, else: "#{label}: #{value}"
      end)
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Enum.join(parts, ", ")
  end

  defp profile_params_summary(_), do: nil
end
