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

    EvoDashWeb.SettingsLive.persist_file_config(
      file_config,
      socket,
      gettext("Model selected and saved.")
    )
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

        EvoDashWeb.SettingsLive.persist_file_config(
          file_config,
          socket,
          gettext("Custom model saved.")
        )
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

            {:ok, EvoGit.Config.LLMCatalog.resolve_model_spec(resolved_atom, model_name, opts)}
          end
      end

    case result do
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}

      {:ok, model_value} ->
        file_config =
          socket.assigns.file_config
          |> ModelProfileHelpers.add_model_profile(model_value)

        EvoDashWeb.SettingsLive.persist_file_config(
          file_config,
          socket,
          gettext("Model selected and saved.")
        )
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
      |> assign(:profile_form_draft, nil)
      |> put_flash(:info, gettext("New profile added — fill in the details and save."))

    {:noreply, socket}
  end

  def edit_model_profile(socket, %{"profile_id" => id}) do
    # Opening a (different) profile's edit form starts a fresh edit session:
    # clear any draft from a previous session.
    {:noreply,
     assign(socket,
       editing_profile_id: if(socket.assigns.editing_profile_id == id, do: nil, else: id),
       profile_form_draft: nil
     )}
  end

  def cancel_edit_model_profile(socket, _params) do
    {:noreply,
     assign(socket,
       editing_profile_id: nil,
       profile_form_draft: nil
     )}
  end

  def save_model_profile(socket, params) do
    old_id = params["profile_id"]
    new_id = String.trim(params["profile_id_new"] || "")

    models = get_in(socket.assigns.file_config, [:llm, :models]) || []

    result =
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

              EvoDashWeb.SettingsLive.persist_file_config(
                file_config,
                socket,
                gettext("Model profile saved.")
              )

            {:error, "model_id_empty"} ->
              {:noreply, put_flash(socket, :error, gettext("Model ID cannot be empty."))}

            {:error, "invalid_extra_json"} ->
              {:noreply, put_flash(socket, :error, gettext("Extra Config must be valid JSON."))}

            {:error, "extra_must_be_object"} ->
              {:noreply,
               put_flash(socket, :error, gettext("Extra Config must be a JSON object (map)."))}

            {:error, "invalid_provider_options_json"} ->
              {:noreply,
               put_flash(socket, :error, gettext("Provider Options must be valid JSON."))}

            {:error, "provider_options_must_be_object"} ->
              {:noreply,
               put_flash(socket, :error, gettext("Provider Options must be a JSON object (map)."))}

            {:error, "peak_concurrency_invalid"} ->
              # 峰值并发必须为非负整数（0 表示高峰时段完全暂停该模型 — 0 个并发槽位）
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 gettext("Peak concurrency must be a non-negative integer.")
               )}

            {:error, "peak_hours_invalid_time"} ->
              # 峰值时段必须使用 HH:MM 24 小时制格式（如 09:00、18:30），且开始与结束时间必须都填写
              {:noreply,
               put_flash(socket, :error, gettext("Peak hours must use HH:MM 24-hour format."))}

            {:error, "peak_hours_start_equals_end"} ->
              # 峰值时段窗口的开始与结束时间不能相同
              {:noreply,
               put_flash(socket, :error, gettext("Peak hour window start and end must differ."))}

            {:error, "peak_hours_overlap"} ->
              # 峰值时段窗口之间不能重叠（首尾相接的相邻时段是允许的）
              {:noreply,
               put_flash(socket, :error, gettext("Peak hour windows must not overlap."))}
          end
      end

    # The edit session is over either way (saved or rejected): drop the
    # unsaved-typing draft so the next edit session starts from the profile's
    # saved values (a rejected save re-renders the row list from file_config).
    case result do
      {:noreply, socket} -> {:noreply, assign(socket, :profile_form_draft, nil)}
    end
  end

  def delete_model_profile(socket, %{"profile_id" => id}) do
    models = get_in(socket.assigns.file_config, [:llm, :models]) || []
    new_models = Enum.reject(models, fn p -> ModelProfileHelpers.profile_id(p) == id end)

    file_config =
      socket.assigns.file_config
      |> ModelProfileHelpers.put_in_model_profiles(new_models)

    socket = socket |> assign(:editing_profile_id, nil) |> assign(:profile_form_draft, nil)

    EvoDashWeb.SettingsLive.persist_file_config(
      file_config,
      socket,
      gettext("Model profile deleted.")
    )
  end

  def move_model_profile(socket, %{"direction" => direction, "id" => id}) do
    file_config =
      socket.assigns.file_config
      |> ModelProfileHelpers.move_model_profile(id, direction)

    # 模型配置档已成功上移/下移（"moved" = 已移动）
    EvoDashWeb.SettingsLive.persist_file_config(
      file_config,
      socket,
      gettext("Model profile moved.")
    )
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Peak-hours row editor (in-memory only, mirroring the add_list_entry /
  # remove_list_entry pattern in settings_live.ex — nothing is persisted until
  # the enclosing save_model_profile form is submitted)
  # ───────────────────────────────────────────────────────────────────────────

  # phx-change snapshot of the whole edit form. Stored as :profile_form_draft
  # so the edit form re-renders with every typed value preserved — phx-click
  # (add/remove row) does NOT send the enclosing form's data, so without the
  # draft the row buttons would re-render the form from file_config and wipe
  # all unsaved typing. The nested peak_hours is normalized to the canonical
  # list form defensively (total — never crashes on partial/odd params), and
  # off_peak_days is normalized to a day-vocabulary list: Plug collapses a
  # repeated form param to a BARE STRING when exactly one checkbox is checked
  # (e.g. `off_peak_days=weekends` → "weekends"), and the template's day-chip
  # membership test would crash on that binary (Enumerable protocol error) if
  # the raw value were stored verbatim. Empty/absent → [] (all chips render
  # unchecked); the seed-filtering + vocabulary whitelist live in
  # ModelProfileHelpers.normalize_days/1.
  def model_profile_form_change(socket, params) when is_map(params) do
    draft =
      params
      |> Map.put(
        "peak_hours",
        ModelProfileHelpers.normalize_peak_hours_draft(params["peak_hours"])
      )
      |> normalize_draft_off_peak_days()

    {:noreply, assign(socket, :profile_form_draft, draft)}
  end

  def model_profile_form_change(socket, _params), do: {:noreply, socket}

  # The real edit form ALWAYS submits off_peak_days (the hidden seed input
  # guarantees at least a `""` entry), so the key is present whenever the
  # change originates from this form. When present it is stored as a NORMALIZED
  # day list (never a bare string — the crash trigger); when genuinely absent
  # (synthetic/partial params) the key stays missing so the template's
  # draft_or_profile/3 falls back to the profile's saved days, as before.
  defp normalize_draft_off_peak_days(%{"off_peak_days" => raw} = draft) do
    Map.put(draft, "off_peak_days", ModelProfileHelpers.normalize_days(raw))
  end

  defp normalize_draft_off_peak_days(draft), do: draft

  def add_peak_hours_row(socket, _params) do
    file_config = socket.assigns.file_config
    editing_id = socket.assigns.editing_profile_id

    case find_editing_profile(file_config, editing_id) do
      nil ->
        {:noreply, socket}

      profile ->
        peak_hours = current_peak_hours(socket, profile)
        peak_hours = peak_hours ++ [%{start: "", end: ""}]

        file_config =
          update_editing_profile(file_config, editing_id, fn p ->
            p
            |> Map.delete("peak_hours")
            |> Map.put(:peak_hours, peak_hours)
          end)

        draft = maybe_update_draft_peak_hours(socket, peak_hours)

        {:noreply,
         socket |> assign(:file_config, file_config) |> assign(:profile_form_draft, draft)}
    end
  end

  def remove_peak_hours_row(socket, %{"index" => index_str}) do
    file_config = socket.assigns.file_config
    editing_id = socket.assigns.editing_profile_id

    # phx-value-* arrives as a string; Integer.parse (not a bare
    # String.to_integer) so a malformed index can never crash the LiveView.
    index =
      case Integer.parse(index_str) do
        {int, ""} -> int
        _ -> -1
      end

    case find_editing_profile(file_config, editing_id) do
      nil ->
        {:noreply, socket}

      profile ->
        peak_hours = current_peak_hours(socket, profile)

        if index >= 0 and index < length(peak_hours) do
          new_hours = List.delete_at(peak_hours, index)

          file_config =
            update_editing_profile(file_config, editing_id, fn p ->
              p =
                p
                |> Map.delete(:peak_hours)
                |> Map.delete("peak_hours")

              # Empty list → remove the key entirely (absent = disabled, per
              # the serialization contract).
              if new_hours == [], do: p, else: Map.put(p, :peak_hours, new_hours)
            end)

          draft = maybe_update_draft_peak_hours(socket, new_hours)

          {:noreply,
           socket |> assign(:file_config, file_config) |> assign(:profile_form_draft, draft)}
        else
          {:noreply, socket}
        end
    end
  end

  # The current peak-hours window list for the edited profile. When a form
  # draft exists (any input has been typed), the draft's peak_hours are
  # authoritative — they carry the user's typed window values that phx-click
  # did NOT send. Without a draft, fall back to the profile's saved peak_hours
  # (the legacy behavior).
  defp current_peak_hours(socket, profile) do
    case socket.assigns[:profile_form_draft] do
      %{} = draft when map_size(draft) > 0 ->
        case Map.get(draft, "peak_hours") do
          nil -> profile_peak_hours(profile)
          hours -> ModelProfileHelpers.normalize_peak_hours_draft(hours)
        end

      _ ->
        profile_peak_hours(profile)
    end
  end

  defp profile_peak_hours(profile) do
    case Map.get(profile, :peak_hours) || Map.get(profile, "peak_hours") do
      hours when is_list(hours) -> hours
      _ -> []
    end
  end

  # Mirrors the updated peak_hours list into the draft when one exists, so the
  # re-render (which prefers the draft) shows the new row set. Returns nil when
  # there is no draft — the render falls back to the updated profile instead.
  defp maybe_update_draft_peak_hours(socket, peak_hours) do
    case socket.assigns[:profile_form_draft] do
      %{} = draft when map_size(draft) > 0 -> Map.put(draft, "peak_hours", peak_hours)
      _ -> nil
    end
  end

  # Finds the profile currently being edited by id (atom-or-string key safe),
  # or nil when none.
  defp find_editing_profile(file_config, editing_id) do
    models = get_in(file_config, [:llm, :models]) || []
    Enum.find(models, fn p -> ModelProfileHelpers.profile_id(p) == editing_id end)
  end

  # Applies `fun` to the profile whose id matches `editing_id`, returning the
  # updated file_config (unchanged when no profile matches).
  defp update_editing_profile(file_config, editing_id, fun) do
    models = get_in(file_config, [:llm, :models]) || []

    new_models =
      Enum.map(models, fn p ->
        if ModelProfileHelpers.profile_id(p) == editing_id, do: fun.(p), else: p
      end)

    ModelProfileHelpers.put_in_model_profiles(file_config, new_models)
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
