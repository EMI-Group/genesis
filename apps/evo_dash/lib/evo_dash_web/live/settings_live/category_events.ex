defmodule EvoDashWeb.SettingsLive.CategoryEvents do
  @moduledoc """
  The generic category/config event vocabulary of `/settings` plus the ONE
  config-persistence entry point.

  Events routed here by `EvoDashWeb.SettingsLive`:
    * `save_category` / `save_search` — validate the submitted form against the
      node's platform-filtered schemas and persist through
      `persist_file_config/4`;
    * `reset_key` — delegates to `EvoDashWeb.SettingsLive.SearchEvents` and
      clears a pending appearance draft;
    * `select_appearance_accent`, `add_list_entry`, `remove_list_entry` —
      in-memory only (`file_config` edits; nothing is written until the
      enclosing save form is submitted);
    * `save_api_key` — the provider-account credential write (local: synchronous
      but exit-safe; remote: supervised task + `config_saving` indicator).

  It also owns the save-receipt application (`apply_config_receipt/2`), the
  credential re-fetch application (`apply_saved_credentials/2`) and the shared
  failure flashes, so `AsyncResults` only decides WHICH envelope arrived.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias EvoDash.SettingsUtils
  alias EvoGit.Config.Schema
  alias EvoDashWeb.SettingsLive.ConfigIO
  alias EvoDashWeb.SettingsLive.ConfigSave
  alias EvoDashWeb.SettingsLive.LlmTestEvents
  alias EvoDashWeb.SettingsLive.ModelProfileEvents
  alias EvoDashWeb.SettingsLive.NodeData
  alias EvoDashWeb.SettingsLive.PageState
  alias EvoDashWeb.SettingsLive.SearchEvents

  @events [
    "save_category",
    "save_search",
    "reset_key",
    "select_appearance_accent",
    "add_list_entry",
    "remove_list_entry",
    "save_api_key"
  ]

  @doc """
  The event names this module owns.
  """
  @spec events() :: [String.t()]
  def events, do: @events

  @doc """
  Routes one of `events/0` to its handler.

  Called from `SettingsLive.handle_event/3` (one-line delegation).
  """
  def handle_event(event, params, socket) when event in @events do
    case event do
      "save_category" -> save_category(socket, params)
      "save_search" -> save_search(socket, params)
      "reset_key" -> reset_key(socket, params)
      "select_appearance_accent" -> select_appearance_accent(socket, params)
      "add_list_entry" -> add_list_entry(socket, params)
      "remove_list_entry" -> remove_list_entry(socket, params)
      "save_api_key" -> save_api_key(socket, params)
    end
  end

  defp save_category(socket, params) do
    # Whitelist lookup: validate the category string against known schema atoms.
    # Unknown value → nil → fall back to the current active_category.
    category =
      case params["category"] do
        cat_str when is_binary(cat_str) ->
          Map.get(ConfigIO.category_str_to_atom(socket.assigns.schemas_by_category), cat_str)

        _ ->
          nil
      end

    category = category || socket.assigns.active_category

    schemas =
      socket.assigns.schemas_by_category
      |> Map.get(category, [])
      |> Enum.filter(&ConfigIO.generic_schema?/1)

    # Build config from params and merge into full file_config
    config =
      ConfigIO.build_config_from_category_params(
        params,
        category,
        schemas,
        socket.assigns.file_config
      )

    case Schema.validate(config) do
      {:ok, _validated} ->
        # ConfigSave owns asynchronous writes for both local and remote nodes.
        # Apply config only after its token/scope-matched receipt arrives;
        # runtime? also pushes changed local LLM / scheduler keys.
        persist_config(
          socket,
          config,
          gettext("Configuration saved successfully."),
          category in [:scheduler, :llm]
        )

      {:error, errors} ->
        category_errors = Enum.filter(errors, fn e -> List.first(e.key_path) == category end)

        {:noreply,
         socket
         |> assign(
           :per_category_errors,
           Map.put(socket.assigns.per_category_errors, category, category_errors)
         )
         |> put_flash(:error, gettext("Validation failed. Please fix the errors below."))}
    end
  end

  defp save_search(socket, params) do
    search_text = socket.assigns.search_text

    all_matching_schemas =
      socket.assigns.schemas_by_category
      |> Enum.flat_map(fn {_cat, schemas} -> schemas end)
      |> Enum.filter(&ConfigIO.generic_schema?/1)
      |> Enum.filter(&EvoDashWeb.SettingsComponents.schema_matches?(&1, search_text))

    config =
      ConfigIO.build_config_from_category_params(
        params,
        nil,
        all_matching_schemas,
        socket.assigns.file_config
      )

    case Schema.validate(config) do
      {:ok, _validated} ->
        # Same persistence path as save_category/2 (see persist_file_config/4).
        persist_config(
          socket,
          config,
          gettext("Configuration saved successfully."),
          Enum.any?(all_matching_schemas, &(List.first(&1.key_path) in [:scheduler, :llm]))
        )

      {:error, errors} ->
        # Group errors by category for display
        per_category_errors =
          Enum.reduce(errors, %{}, fn e, acc ->
            cat = List.first(e.key_path)
            Map.update(acc, cat, [e], fn existing -> existing ++ [e] end)
          end)

        {:noreply,
         socket
         |> assign(:per_category_errors, per_category_errors)
         |> put_flash(:error, gettext("Validation failed. Please fix the errors below."))}
    end
  end

  defp reset_key(socket, params) do
    {:noreply, socket} = SearchEvents.handle_reset_key(socket, params)
    # A successful reset persists + reloads file_config (authoritative) — clear
    # any pending appearance accent draft so the stale draft can never override
    # the reset value on re-render. Harmless on the invalid-key error branch.
    {:noreply, assign(socket, :appearance_accent_draft, nil)}
  end

  # ── Appearance category: accent-color swatch picker ───────────────────────
  #
  # `select_appearance_accent` updates ONLY the pending `:appearance_accent_draft`
  # assign (NOT file_config). The swatch buttons in SettingCard are type="button"
  # so the enclosing save_category form is never submitted and unsaved edits in
  # sibling cards of the same category are never wiped. The draft is threaded
  # into the accent card's value by category_section (via
  # `card_value/3` in components/settings_components.ex) so the active ring +
  # hidden input re-render immediately. The draft is cleared whenever file_config
  # is replaced by an authoritative load (mount, save/reset success, node-data
  # reload) so the card always reflects the persisted state after any reload.

  defp select_appearance_accent(socket, %{"accent" => accent}) do
    # Whitelist: accept only the ten palette names from
    # SettingCard.accent_palette/0 (untrusted client payload — never trust it
    # blindly, never String.to_atom on it).
    if EvoDashWeb.SettingsComponents.SettingCard.accent_name?(accent) do
      {:noreply, assign(socket, :appearance_accent_draft, accent)}
    else
      {:noreply, put_flash(socket, :error, gettext("Unknown accent color."))}
    end
  end

  # ── :list_of_strings list editor (e.g. [sandbox] write_paths) ─────────────
  #
  # add_list_entry / remove_list_entry mutate the IN-MEMORY file_config only —
  # nothing is persisted until the enclosing save_category / save_search form
  # is submitted (the existing save path). The key_path arrives as a
  # dot-separated string and is whitelist-validated via parse_key_path (never
  # String.to_existing_atom on untrusted input); only :list_of_strings schemas
  # are accepted.

  defp add_list_entry(socket, %{"key_path" => key_path_str}) do
    key_path = ConfigIO.parse_key_path(key_path_str, socket.assigns.schemas_by_category)
    schema = ConfigIO.find_schema(key_path, socket.assigns.schemas_by_category)

    if is_nil(key_path) or is_nil(schema) or schema.type != :list_of_strings do
      {:noreply, put_flash(socket, :error, gettext("Invalid key path."))}
    else
      entries = get_in(socket.assigns.file_config, key_path)
      entries = if is_list(entries), do: entries, else: []
      file_config = SettingsUtils.deep_put(socket.assigns.file_config, key_path, entries ++ [""])
      {:noreply, assign(socket, :file_config, file_config)}
    end
  end

  defp remove_list_entry(socket, %{"key_path" => key_path_str, "index" => index_str}) do
    key_path = ConfigIO.parse_key_path(key_path_str, socket.assigns.schemas_by_category)
    schema = ConfigIO.find_schema(key_path, socket.assigns.schemas_by_category)

    if is_nil(key_path) or is_nil(schema) or schema.type != :list_of_strings do
      {:noreply, put_flash(socket, :error, gettext("Invalid key path."))}
    else
      entries = get_in(socket.assigns.file_config, key_path)
      entries = if is_list(entries), do: entries, else: []

      # phx-value-* arrives as a string; Integer.parse (not a bare
      # String.to_integer) so a malformed index can never crash the LiveView.
      index =
        case Integer.parse(index_str) do
          {int, ""} -> int
          _ -> -1
        end

      if index >= 0 and index < length(entries) do
        file_config =
          SettingsUtils.deep_put(
            socket.assigns.file_config,
            key_path,
            List.delete_at(entries, index)
          )

        {:noreply, assign(socket, :file_config, file_config)}
      else
        {:noreply, socket}
      end
    end
  end

  defp save_api_key(socket, %{"credential_key" => credential_key, "api_key" => api_key}) do
    if String.trim(api_key) == "" do
      {:noreply, put_flash(socket, :error, gettext("API key cannot be empty."))}
    else
      socket = LlmTestEvents.invalidate_llm_test(socket)
      node = socket.assigns.current_node
      credentials = %{credential_key => String.trim(api_key)}

      if node == node() do
        save_api_key_local(socket, credentials)
      else
        save_api_key_remote(socket, node, credential_key, credentials)
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Config persistence
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  The single config persistence entry point (public: the parent's
  `persist_file_config/3,4`, `ModelProfileEvents` and `ProviderPanelEvents`
  call it).

  Never constructs a new target's whole-file write from another scope's
  snapshot; ConfigSave additionally guards pending targets and live writers.
  """
  def persist_file_config(file_config, socket, success_msg),
    do: persist_file_config(file_config, socket, success_msg, [])

  @doc false
  def persist_file_config(file_config, socket, success_msg, opts) when is_list(opts) do
    # Never construct a new target's whole-file write from another scope's
    # snapshot. ConfigSave additionally guards pending targets and live writers.
    if socket.assigns[:config_loaded_scope] == ConfigSave.scope(socket) do
      case ConfigSave.start(socket, file_config, success_msg, opts) do
        {:started, socket} ->
          {:noreply, PageState.invalidate_config_load(socket)}

        {:rejected, reason, socket} ->
          {:noreply, save_failed_flash(socket, reason)}

        {:failed, reason, socket} ->
          {:noreply, save_failed_flash(socket, reason)}
      end
    else
      socket = ModelProfileEvents.persistence_failed(socket, Keyword.get(opts, :editor_token))
      {:noreply, save_failed_flash(socket, :configuration_not_loaded)}
    end
  end

  defp persist_config(socket, config, success_msg, runtime?),
    do: persist_file_config(config, socket, success_msg, runtime?: runtime?)

  @doc """
  Applies a confirmed save receipt: the authoritative config/test-selection
  boundary, the persisted-scope marker, the success flash, the one runtime
  push (local LLM/scheduler keys), every warning flash, then the config-status
  and OAuth refreshes.
  """
  def apply_config_receipt(socket, receipt) do
    reload_warning = Keyword.get(receipt.warnings, :config_reload)

    socket =
      socket
      |> LlmTestEvents.assign_test_config(receipt.file_config)
      |> assign(
        config_loaded_scope: receipt.scope,
        config_file_exists: true,
        per_category_errors: %{},
        appearance_accent_draft: nil,
        remote_config_error: remote_config_error_message(reload_warning)
      )
      |> put_flash(:info, receipt.success_msg)

    socket =
      if receipt.runtime? and socket.assigns.current_node == node(),
        do: ConfigIO.update_runtime_from_file_config(receipt.file_config, socket),
        else: socket

    socket = Enum.reduce(receipt.warnings, socket, &saved_warning_flash(&2, &1))
    socket |> refresh_saved_config_status() |> EvoDashWeb.SettingsLive.start_auth_status_load()
  end

  defp refresh_saved_config_status(socket) do
    target_node = socket.assigns.current_node

    if target_node == node() do
      assign(socket, :config_status, PageState.safe_config_status())
    else
      token = make_ref()
      scope = ConfigSave.scope(socket)

      socket =
        assign(socket,
          config_status_token: token,
          config_status: NodeData.degraded_config_status()
        )

      case EvoDash.SafeCall.start(self(), {:settings_saved_status, token, scope}, fn ->
             EvoDash.NodeContext.get_remote_config_status(target_node)
           end) do
        {:ok, _pid} -> socket
        {:error, reason} -> saved_warning_flash(socket, {:config_status, reason})
      end
    end
  end

  @doc """
  Puts the "saved, but refresh failed" warning flash for one receipt warning.
  """
  def saved_warning_flash(socket, warning) do
    put_flash(
      socket,
      :warning,
      gettext("Configuration saved, but refresh failed: %{reason}", reason: inspect(warning))
    )
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers: Credentials
  # ───────────────────────────────────────────────────────────────────────────

  # LOCAL credential save — deliberately SYNCHRONOUS (a plain file write, so the
  # success flash renders in the submit reply) but exit-safe: a dead config
  # store / scheduler surfaces as a value instead of crashing the page.
  defp save_api_key_local(socket, credentials) do
    case EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.save_credentials(node(), credentials) end) do
      {:ok, :ok} ->
        {:noreply,
         socket
         |> assign(:config_status, PageState.safe_config_status())
         |> assign(
           :credentials,
           EvoDash.SafeCall.run(fn -> EvoGit.Config.credentials() end, socket.assigns.credentials)
         )
         |> put_flash(:info, gettext("API key saved successfully."))}

      {:ok, {:error, reason}} ->
        {:noreply, credentials_failed_flash(socket, reason)}

      {:error, reason} ->
        {:noreply, credentials_failed_flash(socket, reason)}

      {:ok, other} ->
        {:noreply, credentials_failed_flash(socket, {:unexpected_save_result, other})}
    end
  end

  # REMOTE credential save in a supervised task — the write, the scheduler
  # reload and the config-status / credentials re-fetch all cross the node
  # boundary, so the LiveView process never blocks on them. `config_saving`
  # drives the shared in-page indicator and the result handler
  # ({:credentials_saved, ...}) clears it on EVERY branch.
  defp save_api_key_remote(socket, node, credential_key, credentials) do
    case EvoDash.SafeCall.start(self(), {:credentials_saved, node, credential_key}, fn ->
           remote_credentials_save(node, credentials)
         end) do
      {:ok, _pid} ->
        {:noreply, assign(socket, :config_saving, true)}

      # The supervisor is gone — no result will ever arrive, so the indicator
      # must stay off and the user gets the failure right away.
      {:error, _reason} ->
        {:noreply, credentials_failed_flash(socket, :task_supervisor_unavailable)}
    end
  end

  # The remote credential-save body (runs in the supervised task). Returns
  # `{:ok, %{config_status: map | nil, credentials: map | nil}}` or
  # `{:error, reason}`.
  #
  # Only the WRITE failure is an error: once the credentials file is written, a
  # failing reload/re-fetch degrades (nil config status → the conservative
  # degraded status; nil credentials → the handler keeps the current assign) so
  # a saved key is never misreported as a failed save.
  defp remote_credentials_save(node, credentials) do
    case EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.save_credentials(node, credentials) end) do
      {:ok, :ok} ->
        # Make the new key take effect on the remote scheduler immediately.
        # Best-effort — the re-fetch below surfaces a reload problem.
        EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.reload_remote_config(node) end)

        config_status =
          EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.get_remote_config_status(node) end, nil)

        credentials =
          case EvoDash.SafeCall.run(fn ->
                 EvoDash.NodeContext.call_remote(node, EvoGit.Config, :credentials, [])
               end) do
            {:ok, %{} = creds} -> creds
            _failed_or_unexpected -> nil
          end

        {:ok, %{config_status: config_status, credentials: credentials}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:unexpected_save_result, other}}
    end
  end

  @doc """
  The failed-credential-save flash (shared with `AsyncResults`).
  """
  def credentials_failed_flash(socket, reason) do
    put_flash(
      socket,
      :error,
      gettext("Failed to save API key: %{reason}", reason: inspect(reason))
    )
  end

  @doc """
  The failed-config-save flash (shared with the saved-receipt handler).
  """
  def save_failed_flash(socket, reason) do
    put_flash(
      socket,
      :error,
      gettext("Failed to save configuration: %{reason}", reason: inspect(reason))
    )
  end

  # Applies the config-status / credentials re-fetch of a saved credential write:
  # the status always (a nil value degrades to the conservative "degraded"
  # status), the credentials map only when the re-fetch produced one.
  @doc false
  def apply_saved_credentials(socket, %{} = saved) do
    socket
    |> assign(:config_status, saved_config_status(saved))
    |> maybe_assign_credentials(Map.get(saved, :credentials))
  end

  defp saved_config_status(%{config_status: %{} = config_status}), do: config_status
  defp saved_config_status(_saved), do: NodeData.degraded_config_status()

  defp maybe_assign_credentials(socket, %{} = credentials),
    do: assign(socket, :credentials, credentials)

  defp maybe_assign_credentials(socket, _credentials), do: socket

  # The user-facing banner text for a failed remote config re-fetch (the save
  # itself succeeded) — same message/shape the synchronous path always used.
  defp remote_config_error_message(nil), do: nil

  defp remote_config_error_message(reason) do
    gettext(
      "Could not load configuration from the remote node: %{reason} — the node may be unreachable.",
      reason: inspect(reason)
    )
  end
end
