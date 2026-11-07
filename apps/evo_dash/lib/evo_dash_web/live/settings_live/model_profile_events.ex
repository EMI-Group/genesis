defmodule EvoDashWeb.SettingsLive.ModelProfileEvents do
  @moduledoc """
  Provider-profile CRUD and detached editor drafts for SettingsLive.

  Existing model-profile event names remain the routing surface. The editing
  id refers to a PROVIDER profile. Only atom `:new` denotes creation; the string
  `"new"` is an ordinary saved id. Drafts survive until persistence is confirmed.

  `profile_form_errors` maps string input names (or collection names for section
  errors) to translated messages. Save accepts raw nested UI params as its third
  argument when the parent adapts parser params separately.
  Provider Save and deletion of the open editor call the parent contract
  `persist_file_config(config, socket, message, editor_token: token)`; all other
  mutations call `/3` without an editor token. The parent must forward the
  explicit options to `ConfigSave.start/4`, never infer a token from assigns.
  The persistence boundary must capture that token with its own
  target/node/request scope and call `persistence_succeeded/2` only after a
  confirmed write, or `persistence_failed/3` on failure (including startup
  failure). Neither flash messages nor optimistic file_config imply success.
  Draft changes invalidate the token so an old save cannot close a newer edit.
  """
  use Gettext, backend: EvoDashWeb.Gettext
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias EvoDashWeb.SettingsLive.{ConfigIO, ModelProfileHelpers, ProviderProfiles}

  def select_llm_model_shortcut(socket, %{"model_string" => model}) do
    save_quick_model(socket, model, gettext("Model selected and saved."))
  end

  def save_custom_model(socket, params) do
    quick_setup(socket, params["provider_id"], params["model_name"], params["base_url"], nil)
  end

  def save_quick_setup(socket, params) do
    quick_setup(
      socket,
      params["provider_id"],
      params["model_string"],
      params["base_url"],
      params["variant_id"]
    )
  end

  defp quick_setup(socket, provider_id, model, base_url, variant_id) do
    provider = Map.get(ConfigIO.provider_by_id_str(), provider_id)
    model = text(model)
    base_url = text(base_url)

    cond do
      is_nil(provider) ->
        error(socket, gettext("Unknown provider."))

      model == "" ->
        error(socket, gettext("Model name cannot be empty."))

      EvoGit.Config.LLMCatalog.requires_base_url?(provider.id) and base_url == "" ->
        error(socket, gettext("Base URL cannot be empty."))

      true ->
        provider_atom = hd(provider.provider_atoms)
        variant = Map.get(ConfigIO.variant_id_by_str(provider_atom), variant_id)
        resolved = EvoGit.Config.LLMCatalog.resolve_provider_atom(provider_atom, variant)
        model = model |> String.split(":", parts: 2) |> List.last()
        opts = if base_url == "", do: [], else: [base_url: base_url]
        model = EvoGit.Config.LLMCatalog.resolve_model_spec(resolved, model, opts)
        save_quick_model(socket, model, gettext("Model selected and saved."))
    end
  end

  defp save_quick_model(socket, model, message) do
    case ProviderProfiles.add_model(socket.assigns.file_config, model) do
      {:ok, config} -> persist(config, socket, message)
      {:error, reason} -> error(socket, error_message(reason))
    end
  end

  def add_model_profile(socket, _params) do
    {:noreply,
     socket
     |> assign(
       editing_profile_id: :new,
       profile_form_draft: ProviderProfiles.new_draft(socket.assigns.file_config),
       profile_form_errors: %{},
       profile_save_token: nil,
       profile_advanced_open: nil
     )}
  end

  def edit_model_profile(socket, %{"profile_id" => id}) do
    cond do
      socket.assigns[:editing_profile_id] == id ->
        cancel_edit_model_profile(socket, %{})

      true ->
        case find_profile(socket, id) do
          nil ->
            {:noreply, socket}

          profile ->
            {:noreply,
             assign(socket,
               editing_profile_id: id,
               profile_form_draft: ProviderProfiles.draft(profile),
               profile_form_errors: %{},
               profile_save_token: nil,
               profile_advanced_open: nil
             )}
        end
    end
  end

  def cancel_edit_model_profile(socket, _params), do: {:noreply, clear_editor(socket)}

  @doc "Snapshot of the entire form. Nested models are numerically ordered string-keyed maps."
  def model_profile_form_change(socket, params) when is_map(params) do
    if socket.assigns[:editing_profile_id] do
      {:noreply,
       assign(socket,
         profile_form_draft: ProviderProfiles.normalize_draft(params),
         profile_form_errors: %{},
         profile_save_token: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def model_profile_form_change(socket, _), do: {:noreply, socket}

  @doc "Save parsed params, optionally retaining the unadapted nested UI submission."
  def save_model_profile(socket, params, submitted_draft \\ nil) do
    editing_id = socket.assigns[:editing_profile_id]
    old_id = if editing_id == :new, do: nil, else: editing_id
    params = ProviderProfiles.submission(params, socket.assigns[:profile_form_draft])
    id = text(params["profile_id_new"] || params["id"])
    profiles = ProviderProfiles.profiles(socket.assigns.file_config)
    original = if is_nil(old_id), do: %{}, else: find_profile(socket, old_id) || %{}

    if is_nil(editing_id) do
      {:noreply, socket}
    else
      # Snapshot BEFORE all validation, including identity failures and persistence
      # initiation. The parent must pass raw UI params when it flattens generation.
      socket =
        assign(socket,
          profile_form_draft:
            ProviderProfiles.normalize_draft(
              ProviderProfiles.submission(
                submitted_draft || params,
                socket.assigns[:profile_form_draft]
              )
            ),
          profile_form_errors: %{},
          profile_save_token: nil
        )

      cond do
        id == "" ->
          field_errors(socket, %{"profile_id_new" => gettext("Profile id cannot be empty.")})

        ModelProfileHelpers.id_collision?(profiles, old_id, id) ->
          field_errors(socket, %{
            "profile_id_new" => gettext("A profile with id \"%{id}\" already exists.", id: id)
          })

        true ->
          case ProviderProfiles.parse_editor(params, id, original) do
            {:ok, profile} ->
              config = ProviderProfiles.update(socket.assigns.file_config, old_id, profile)
              token = make_ref()
              socket = assign(socket, :profile_save_token, token)
              persist(config, socket, gettext("Provider profile saved."), editor_token: token)

            {:error, errors} ->
              field_errors(
                socket,
                Map.new(errors, fn {key, reason} -> {key, error_message(reason)} end)
              )
          end
      end
    end
  end

  @doc "Clear only the editor submission whose authoritative write succeeded."
  def persistence_succeeded(socket, token) when is_reference(token) do
    if socket.assigns[:profile_save_token] == token, do: clear_editor(socket), else: socket
  end

  def persistence_succeeded(socket, _token), do: socket

  @doc "Retain a failed submission; errors are translated string-name/message pairs."
  def persistence_failed(socket, token, errors \\ %{}) do
    if is_reference(token) and socket.assigns[:profile_save_token] == token do
      assign(socket, profile_save_token: nil, profile_form_errors: errors)
    else
      socket
    end
  end

  def delete_model_profile(socket, %{"profile_id" => id}) do
    config = ProviderProfiles.delete(socket.assigns.file_config, id)

    if socket.assigns[:editing_profile_id] == id do
      token = make_ref()
      socket = assign(socket, :profile_save_token, token)
      persist(config, socket, gettext("Provider profile deleted."), editor_token: token)
    else
      persist(config, socket, gettext("Provider profile deleted."))
    end
  end

  def move_model_profile(socket, %{"direction" => direction, "id" => id}) do
    config = ProviderProfiles.move(socket.assigns.file_config, id, direction)

    if config == socket.assigns.file_config,
      do: {:noreply, socket},
      else: persist(config, socket, gettext("Provider profile moved."))
  end

  def set_default_provider_profile(socket, params) do
    config =
      ProviderProfiles.set_default(
        socket.assigns.file_config,
        params["profile_id"] || params["id"]
      )

    persist(config, socket, gettext("Default provider profile saved."))
  end

  @doc "Appends an unsaved model override row (`models[index][model]`)."
  def add_profile_model(socket, _params) do
    update_rows(socket, "models", fn rows -> rows ++ [%{"model" => ""}] end)
  end

  def remove_profile_model(socket, params), do: remove_row(socket, "models", params["index"])

  def add_peak_hours_row(socket, _params) do
    update_rows(socket, "peak_hours", fn rows -> rows ++ [%{"start" => "", "end" => ""}] end)
  end

  def remove_peak_hours_row(socket, params), do: remove_row(socket, "peak_hours", params["index"])

  def toggle_profile_advanced(socket, _params) do
    if socket.assigns[:editing_profile_id] do
      draft = current_draft(socket)

      open =
        case socket.assigns[:profile_advanced_open] do
          value when is_boolean(value) -> value
          _ -> advanced_open?(draft)
        end

      {:noreply, assign(socket, :profile_advanced_open, not open)}
    else
      {:noreply, socket}
    end
  end

  @doc "Shared auto-open rule for the editor component; an explicit boolean overrides it."
  def advanced_open?(draft) when is_map(draft) do
    keys =
      ~w(temperature max_tokens top_p top_k frequency_penalty presence_penalty extra provider_options)

    Enum.any?(keys, &(draft[&1] not in [nil, "", %{}])) or
      advanced_open?(draft["generation"]) or
      Enum.any?(ProviderProfiles.rows(draft["models"]), &advanced_open?/1)
  end

  def advanced_open?(_), do: false

  defp remove_row(socket, key, raw_index) do
    index =
      case raw_index do
        value when is_binary(value) ->
          case Integer.parse(value) do
            {n, ""} when n >= 0 -> n
            _ -> nil
          end

        _ ->
          nil
      end

    if is_integer(index),
      do: update_rows(socket, key, &List.delete_at(&1, index)),
      else: {:noreply, socket}
  end

  defp update_rows(socket, key, fun) do
    if socket.assigns[:editing_profile_id] do
      draft = current_draft(socket)
      current_rows = ProviderProfiles.rows(draft[key])
      rows = fun.(current_rows)

      if rows == current_rows do
        {:noreply, socket}
      else
        {:noreply,
         assign(socket,
           profile_form_draft: Map.put(draft, key, rows),
           profile_form_errors: %{},
           profile_save_token: nil
         )}
      end
    else
      {:noreply, socket}
    end
  end

  defp current_draft(socket) do
    case socket.assigns[:profile_form_draft] do
      %{} = draft ->
        draft

      _ ->
        ProviderProfiles.draft(find_profile(socket, socket.assigns[:editing_profile_id]) || %{})
    end
  end

  defp find_profile(socket, id) do
    Enum.find(
      ProviderProfiles.profiles(socket.assigns.file_config),
      &(ModelProfileHelpers.profile_id(&1) == id)
    )
  end

  defp clear_editor(socket),
    do:
      assign(socket,
        editing_profile_id: nil,
        profile_form_draft: nil,
        profile_form_errors: %{},
        profile_save_token: nil,
        profile_advanced_open: nil
      )

  defp field_errors(socket, errors) do
    socket = assign(socket, :profile_form_errors, errors)
    error(socket, errors |> Map.values() |> hd())
  end

  defp persist(config, socket, message),
    do: EvoDashWeb.SettingsLive.persist_file_config(config, socket, message)

  defp persist(config, socket, message, opts),
    do: EvoDashWeb.SettingsLive.persist_file_config(config, socket, message, opts)

  defp error(socket, message), do: {:noreply, put_flash(socket, :error, message)}
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_), do: ""

  defp error_message("provider_empty"), do: gettext("Provider cannot be empty.")

  defp error_message("auth_mode_invalid"),
    do: gettext("Select a supported authentication mode for this provider.")

  defp error_message("numeric_invalid"), do: gettext("Numeric fields must contain valid numbers.")

  defp error_message("duplicate_model"),
    do: gettext("Model IDs must be unique within a provider profile.")

  defp error_message("default_model_invalid"),
    do: gettext("Enter a default model or add a model override.")

  defp error_message("reasoning_default_invalid"),
    do: gettext("Default reasoning effort must be one of the configured reasoning efforts.")

  defp error_message("models_invalid"),
    do: gettext("Each model entry must be a model configuration.")

  defp error_message("model_id_empty"), do: gettext("Model ID cannot be empty.")
  defp error_message("invalid_extra_json"), do: gettext("Extra Config must be valid JSON.")

  defp error_message("extra_must_be_object"),
    do: gettext("Extra Config must be a JSON object (map).")

  defp error_message("invalid_provider_options_json"),
    do: gettext("Provider Options must be valid JSON.")

  defp error_message("provider_options_must_be_object"),
    do: gettext("Provider Options must be a JSON object (map).")

  # 高峰并发为 0 时暂停请求；时间字段是每日 24 小时制时段。
  defp error_message("peak_concurrency_invalid"),
    do: gettext("Peak concurrency must be a non-negative integer.")

  defp error_message("peak_hours_invalid_time"),
    do: gettext("Peak hours must use HH:MM 24-hour format.")

  defp error_message("peak_hours_start_equals_end"),
    do: gettext("Peak hour window start and end must differ.")

  defp error_message("peak_hours_overlap"), do: gettext("Peak hour windows must not overlap.")

  def maybe_put_gen_opt(opts, key, profile) do
    value = Map.get(profile, key) || Map.get(profile, to_string(key))
    if value != nil, do: Keyword.put(opts, key, value), else: opts
  end
end
