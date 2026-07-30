defmodule EvoDashWeb.SettingsLive.ModelProfileEvents do
  @moduledoc """
  Event handlers for LLM model profile management (CRUD + quick setup).

  Extracted from SettingsLive to keep the main module focused on category-based
  config editing and remote-connection management.
  """

  use Gettext, backend: EvoDashWeb.Gettext
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias EvoDashWeb.SettingsLive.{ConfigIO, ModelProfileHelpers}

  # ───────────────────────────────────────────────────────────────────────────
  # Quick Setup handlers
  # ───────────────────────────────────────────────────────────────────────────

  def select_llm_model_shortcut(socket, %{"model_string" => model_string}) do
    # Add a new model profile using the selected model string.
    file_config =
      socket.assigns.file_config
      |> ModelProfileHelpers.add_model_profile(model_string)

    EvoDashWeb.SettingsLive.persist_file_config(file_config, socket, gettext("Model selected and saved."))
  end

  def save_custom_model(socket, params) do
    model_name = params["model_name"]
    base_url = params["base_url"]
    provider_id_str = params["provider_id"]

    # Build a whitelist map keyed by the string form of each provider's atom id,
    # so untrusted POST data is matched without String.to_existing_atom.
    provider = Map.get(ConfigIO.provider_by_id_str(), provider_id_str)

    result =
      cond do
        is_nil(provider) ->
          {:error, gettext("Unknown provider.")}

        String.trim(model_name || "") == "" ->
          {:error, gettext("Model name cannot be empty.")}

        true ->
          # Resolve the canonical provider atom from the catalog entry's
          # provider_atoms list directly (e.g. :openai_compatible entry → :openai
          # atom, :openrouter → :openrouter). We use hd/1 on provider_atoms
          # because resolve_provider_atom/1 looks up by membership, NOT by
          # catalog id — it would leave :openai_compatible unchanged (the bug).
          provider_atom = hd(provider.provider_atoms)

          # Validate base_url requirement using the catalog function (NOT the
          # dead provider[:requires_base_url] struct field).
          requires_base_url = EvoGit.Config.LLMCatalog.requires_base_url?(provider.id)

          if requires_base_url and String.trim(base_url || "") == "" do
            {:error, gettext("Base URL cannot be empty.")}
          else
            # Build the map spec via resolve_model_spec/3 — it omits nil/empty
            # base_url and resolves model shortcuts/variants. Produces a MAP for
            # ALL providers (including OpenRouter), not a legacy string.
            opts =
              if String.trim(base_url || "") == "",
                do: [],
                else: [base_url: String.trim(base_url)]

            {:ok, EvoGit.Config.LLMCatalog.resolve_model_spec(provider_atom, model_name, opts)}
          end
      end

    case result do
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:ok, model_value} ->
        file_config =
          socket.assigns.file_config
          |> ModelProfileHelpers.add_model_profile(model_value)

        EvoDashWeb.SettingsLive.persist_file_config(file_config, socket, gettext("Custom model saved."))
    end
  end

  def save_quick_setup(socket, params) do
    model_string = params["model_string"]
    base_url = params["base_url"]
    provider_id_str = params["provider_id"]
    variant_id_str = params["variant_id"]

    provider = Map.get(ConfigIO.provider_by_id_str(), provider_id_str)

    result =
      cond do
        is_nil(provider) ->
          {:error, gettext("Unknown provider.")}

        String.trim(model_string || "") == "" ->
          {:error, gettext("Model name cannot be empty.")}

        true ->
          # Resolve the canonical provider atom. Start from hd(provider_atoms)
          # then apply variant resolution if a variant was selected.
          provider_atom = hd(provider.provider_atoms)

          resolved_atom =
            if variant_id_str != nil and variant_id_str != "" do
              # Whitelist variant lookup via variant_id_by_str (safe Map.get,
              # no String.to_existing_atom on untrusted input). Falls back
              # to the canonical provider atom for unknown/empty values.
              variant_atom = Map.get(ConfigIO.variant_id_by_str(provider_atom), variant_id_str)
              EvoGit.Config.LLMCatalog.resolve_provider_atom(provider_atom, variant_atom)
            else
              EvoGit.Config.LLMCatalog.resolve_provider_atom(provider_atom)
            end

          # The model_string from shortcut buttons is in "provider:model"
          # format (e.g. "openai:gpt-5.5"). resolve_model_spec expects
          # just the model id portion, so we strip the provider prefix.
          model_name =
            if String.contains?(model_string, ":") do
              [_provider_prefix, name] = :binary.split(model_string, ":")
              name
            else
              model_string
            end

          # Validate base_url requirement
          requires_base_url = EvoGit.Config.LLMCatalog.requires_base_url?(provider.id)

          if requires_base_url and String.trim(base_url || "") == "" do
            {:error, gettext("Base URL cannot be empty.")}
          else
            opts =
              if String.trim(base_url || "") == "",
                do: [],
                else: [base_url: String.trim(base_url)]

            {:ok,
             EvoGit.Config.LLMCatalog.resolve_model_spec(resolved_atom, model_name, opts)}
          end
      end

    case result do
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:ok, model_value} ->
        file_config =
          socket.assigns.file_config
          |> ModelProfileHelpers.add_model_profile(model_value)

        EvoDashWeb.SettingsLive.persist_file_config(file_config, socket, gettext("Model selected and saved."))
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Model Profiles editor events
  # ───────────────────────────────────────────────────────────────────────────

  def add_model_profile(socket, _params) do
    # Add the profile to the in-memory file_config (not persisted yet — the
    # profile has no model until the user fills in the edit form, and persisting
    # now would fail schema validation). Enter edit mode immediately so the
    # user can complete the profile, then save.
    file_config =
      socket.assigns.file_config
      |> ModelProfileHelpers.add_model_profile(nil)

    models = get_in(file_config, [:llm, :models]) || []
    new_id = models |> List.last() |> ModelProfileHelpers.profile_id()

    socket =
      socket
      |> assign(:file_config, file_config)
      |> assign(:editing_profile_id, new_id)
      |> put_flash(:info, gettext("New profile added — fill in the details and save."))

    {:noreply, socket}
  end

  def edit_model_profile(socket, %{"profile_id" => id}) do
    {:noreply,
     assign(socket,
       editing_profile_id: if(socket.assigns.editing_profile_id == id, do: nil, else: id)
     )}
  end

  def cancel_edit_model_profile(socket, _params) do
    {:noreply, assign(socket, :editing_profile_id, nil)}
  end

  def save_model_profile(socket, params) do
    old_id = params["profile_id"]
    new_id = String.trim(params["profile_id_new"] || "")

    models = get_in(socket.assigns.file_config, [:llm, :models]) || []

    cond do
      new_id == "" ->
        {:noreply, put_flash(socket, :error, gettext("Profile id cannot be empty."))}

      # Duplicate id check: another profile (with a different old id) already
      # uses the requested id.
      ModelProfileHelpers.id_collision?(models, old_id, new_id) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("A profile with id \"%{id}\" already exists.", id: new_id)
         )}

      true ->
        case ModelProfileHelpers.parse_model_profile_params(params, new_id) do
          {:ok, updated_profile} ->
            file_config =
              socket.assigns.file_config
              |> ModelProfileHelpers.update_model_profile(old_id, updated_profile)

            socket = socket |> assign(:editing_profile_id, nil)

            EvoDashWeb.SettingsLive.persist_file_config(file_config, socket, gettext("Model profile saved."))

          {:error, "model_id_empty"} ->
            {:noreply, put_flash(socket, :error, gettext("Model ID cannot be empty."))}

          {:error, "invalid_extra_json"} ->
            {:noreply, put_flash(socket, :error, gettext("Extra Config must be valid JSON."))}

          {:error, "extra_must_be_object"} ->
            {:noreply, put_flash(socket, :error, gettext("Extra Config must be a JSON object (map)."))}

          {:error, "invalid_provider_options_json"} ->
            {:noreply, put_flash(socket, :error, gettext("Provider Options must be valid JSON."))}

          {:error, "provider_options_must_be_object"} ->
            {:noreply, put_flash(socket, :error, gettext("Provider Options must be a JSON object (map)."))}
        end
    end
  end

  def delete_model_profile(socket, %{"profile_id" => id}) do
    models = get_in(socket.assigns.file_config, [:llm, :models]) || []
    new_models = Enum.reject(models, fn p -> ModelProfileHelpers.profile_id(p) == id end)

    file_config =
      socket.assigns.file_config
      |> ModelProfileHelpers.put_in_model_profiles(new_models)

    socket = socket |> assign(:editing_profile_id, nil)

    EvoDashWeb.SettingsLive.persist_file_config(file_config, socket, gettext("Model profile deleted."))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Generation params
  # ───────────────────────────────────────────────────────────────────────────

  # Conditionally adds a generation param from a profile map to a keyword list.
  # Skips keys whose value is nil or absent in the profile.
  def maybe_put_gen_opt(opts, key, profile) do
    value = Map.get(profile, key) || Map.get(profile, to_string(key))
    if value != nil, do: Keyword.put(opts, key, value), else: opts
  end
end
