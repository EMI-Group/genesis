defmodule EvoDashWeb.SettingsLive.ProviderPanelEvents do
  @moduledoc """
  The state machine + save paths of the `/settings` provider-account panel.

  The presentation modules (`SettingsComponents.ProviderProfiles.{Panel,Row,
  Detail,ScheduleEditor,WizardForm}`) are FROZEN: they render what they are
  given and emit the panel's event vocabulary. THIS module owns the assigns
  behind that vocabulary and the two write paths, and `EvoDashWeb.SettingsLive`
  only routes events here.

  ## Assigns it owns

    * `:provider_wizard` — `nil` or
      `%{mode: :account | {:model, profile_id}, step: atom,
         draft: string-keyed map, errors: %{field => translated message},
         schedule: %{preset_id:, snapshot:, applied?:, modified?:}}`;
    * `:provider_schedule` — the recommended-schedule strip state of the
      currently EXPANDED account (`empty_schedule/0`);
    * the expanded-account editor state itself (`:editing_profile_id`,
      `:profile_form_draft`, `:profile_form_errors`, `:profile_save_token`,
      `:profile_advanced_open`) is delegated to
      `EvoDashWeb.SettingsLive.ModelProfileEvents`, which stays the CRUD and
      detached-draft boundary.

  The in-browser Sign in with ChatGPT state is PAGE-level
  (`EvoDashWeb.SettingsLive.ChatGPTSignInState` owns it in the
  `:chatgpt_sign_in` / `:chatgpt_sign_in_manual` assigns): the wizard, an
  expanded account's detail form and an account's auth-status row are three
  surfaces over ONE flow, and this module only routes their events, projects the
  wizard's own surface view into `:provider_wizard` and cancels the flow when the
  surface that owns it is dismissed.

  Nothing here reads the clock, the catalog cache or disk: identity, parsing
  and persistence all go through `EvoDashWeb.SettingsLive.ProviderProfiles`
  and the parent's `persist_file_config/3`.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias EvoDashWeb.LLMSetup.ChatGPT
  alias EvoDashWeb.LLMSetup.Schedule
  alias EvoDashWeb.LLMSetup.Wizard
  alias EvoDashWeb.SettingsComponents.ProviderProfiles.WizardForm
  alias EvoDashWeb.SettingsLive.ChatGPTSignInState
  alias EvoDashWeb.SettingsLive.LlmTestEvents
  alias EvoDashWeb.SettingsLive.ModelProfileEvents
  alias EvoDashWeb.SettingsLive.ModelProfileHelpers
  alias EvoDashWeb.SettingsLive.ProviderProfiles

  # The wizard's own schedule strip state (never rendered by `/settings` today,
  # kept so a preset click inside the wizard can be undone from it).
  @empty_wizard_schedule %{preset_id: nil, snapshot: nil, applied?: false, modified?: false}

  @doc """
  The expanded account's recommended-schedule strip state.

  `%{preset_id: nil, applied: false, modified: false, can_undo: false, snapshot: nil}`
  — inert until the user clicks a published preset.
  """
  @spec empty_schedule() :: map()
  def empty_schedule,
    do: %{preset_id: nil, applied: false, modified: false, can_undo: false, snapshot: nil}

  @doc "The wizard's inert schedule state."
  @spec empty_wizard_schedule() :: map()
  def empty_wizard_schedule, do: @empty_wizard_schedule

  # The panel's whole event vocabulary in ONE place, so the LiveView routes a
  # single `when event in [...]` clause instead of 20 pass-through clauses.
  @panel_events %{
    "add_provider_profile" => :add_provider_profile,
    "provider_wizard_change" => :provider_wizard_change,
    "provider_wizard_next" => :provider_wizard_next,
    "provider_wizard_back" => :provider_wizard_back,
    "provider_wizard_cancel" => :provider_wizard_cancel,
    "provider_wizard_save" => :provider_wizard_save,
    "start_add_provider_model" => :start_add_provider_model,
    "provider_model_change" => :provider_model_change,
    "provider_model_cancel" => :provider_model_cancel,
    "provider_model_save" => :provider_model_save,
    "edit_provider_profile" => :edit_provider_profile,
    "cancel_edit_provider_profile" => :cancel_edit_provider_profile,
    "save_provider_profile" => :save_provider_profile,
    "provider_profile_form_change" => :provider_profile_form_change,
    "set_default_provider_profile" => :set_default_provider_profile,
    "delete_provider_profile" => :delete_provider_profile,
    "add_provider_peak_hours_row" => :add_provider_peak_hours_row,
    "remove_provider_peak_hours_row" => :remove_provider_peak_hours_row,
    "apply_provider_schedule" => :apply_provider_schedule,
    "undo_provider_schedule" => :undo_provider_schedule,
    "dismiss_schedule_applied" => :dismiss_schedule_applied,
    "chatgpt_sign_in" => :chatgpt_sign_in,
    "chatgpt_sign_in_cancel" => :chatgpt_sign_in_cancel
  }

  @doc """
  Routes one panel event name to its handler.

  Whitelist dispatch (`Map.fetch/2`) — an unknown name is a no-op rather than
  an atom conversion, and the name set is the FROZEN panel's event vocabulary.
  """
  @spec dispatch(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def dispatch(event, params, socket) do
    case Map.fetch(@panel_events, event) do
      {:ok, fun} -> apply(__MODULE__, fun, [socket, params])
      :error -> {:noreply, socket}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # add account (wizard)
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Opens the add-account wizard: collapses any expanded account, resets the
  schedule strip and starts a fresh provider-derived draft.
  """
  def add_provider_profile(socket, _params) do
    {:noreply,
     socket
     |> close_editor()
     |> assign(provider_schedule: empty_schedule())
     |> assign(provider_wizard: new_account_wizard(socket))}
  end

  @doc """
  Merges one wizard submission into the wizard draft.

  A `preset_id` payload applies a published schedule preset instead of merging
  form fields; a `provider` change re-derives the account's id/name from the
  provider (a model must never drive identity).
  """
  def provider_wizard_change(socket, %{"preset_id" => preset_id})
      when is_binary(preset_id) do
    case socket.assigns[:provider_wizard] do
      %{draft: draft} = wizard when is_map(draft) ->
        {draft, snapshot} = Schedule.apply(preset_id, draft)

        schedule =
          (wizard[:schedule] || @empty_wizard_schedule)
          |> Map.merge(%{
            preset_id: preset_id,
            snapshot: snapshot,
            applied?: true,
            modified?: false
          })

        {:noreply,
         assign(socket,
           provider_wizard: Map.merge(wizard, %{draft: draft, schedule: schedule})
         )}

      _wizard ->
        {:noreply, socket}
    end
  end

  def provider_wizard_change(socket, %{"refresh_chatgpt" => "true"}) do
    case socket.assigns[:provider_wizard] do
      %{mode: :account, draft: %{"provider" => "openai_codex"}} = wizard ->
        {:noreply, assign(socket, :provider_wizard, load_chatgpt_accounts(wizard, socket))}

      _wizard ->
        {:noreply, socket}
    end
  end

  def provider_wizard_change(socket, params) when is_map(params) do
    case socket.assigns[:provider_wizard] do
      %{draft: draft} = wizard when is_map(draft) ->
        previous = draft

        draft =
          params
          |> ProviderProfiles.submission(draft)
          |> derive_identity(params, socket.assigns[:file_config])
          |> reset_chatgpt_selection(previous)

        schedule = recompute_wizard_modified(wizard[:schedule], draft)
        wizard = Map.merge(wizard, %{draft: draft, errors: %{}, schedule: schedule})

        wizard =
          if draft["provider"] == "openai_codex" and previous["provider"] != draft["provider"],
            do: load_chatgpt_accounts(wizard, socket),
            else: wizard

        {:noreply, assign(socket, provider_wizard: ensure_sign_in_keys(wizard, socket))}

      _wizard ->
        {:noreply, socket}
    end
  end

  def provider_wizard_change(socket, _params), do: {:noreply, socket}

  @doc "Advances one RENDERED step, clamped to the last step."
  def provider_wizard_next(socket, _params) do
    case socket.assigns[:provider_wizard] do
      %{step: :auth, draft: draft} = wizard ->
        if WizardForm.chatgpt_auth_ready?(draft, Map.get(wizard, :chatgpt_accounts, %{})),
          do: {:noreply, move_wizard_step(socket, &Wizard.next/2)},
          else: wizard_errors(socket, %{"siwc_account" => "chatgpt_login_required"})

      _wizard ->
        {:noreply, move_wizard_step(socket, &Wizard.next/2)}
    end
  end

  @doc "Goes back one RENDERED step, clamped to the first step."
  def provider_wizard_back(socket, _params) do
    {:noreply, move_wizard_step(socket, &Wizard.back/2)}
  end

  @doc "Closes the add-account wizard without writing anything."
  def provider_wizard_cancel(socket, _params) do
    {:noreply, socket |> close_surface(:wizard) |> assign(:provider_wizard, nil)}
  end

  @doc """
  Saves the wizard as a canonical provider account.

  The chosen model becomes the account's single `models[]` entry and its
  `default_model`; identity is provider-derived (never model-derived) and a
  duplicate id is refused exactly like the expanded editor's Save.
  """
  def provider_wizard_save(socket, _params) do
    case socket.assigns[:provider_wizard] do
      %{draft: draft} = wizard when is_map(draft) ->
        with :ok <- Wizard.validate(:model, draft),
             model when is_binary(model) and model != "" <- model_value(draft),
             :ok <- chatgpt_model_available(socket, draft, model) do
          params =
            draft
            |> Map.put("models", [%{"model" => model}])
            |> Map.put("default_model", model)
            |> ProviderProfiles.editor_identity(
              socket.assigns[:file_config],
              :new,
              draft["id"]
            )

          save_new_account(socket, parameters(wizard, params))
        else
          {:error, :chatgpt_model_unavailable} ->
            wizard_errors(socket, %{"model" => "chatgpt_model_unavailable"})

          {:error, _reason} ->
            wizard_errors(socket, %{"model" => "missing_model"})

          _ ->
            wizard_errors(socket, %{"model" => "model_id_empty"})
        end

      _wizard ->
        {:noreply, socket}
    end
  end

  defp save_new_account(socket, params) do
    id = text(params["profile_id_new"])
    profiles = ProviderProfiles.profiles(socket.assigns[:file_config])

    cond do
      id == "" ->
        wizard_errors(socket, %{"profile_id_new" => "profile_id_empty"})

      ModelProfileHelpers.id_collision?(profiles, nil, id) ->
        wizard_errors(socket, %{"profile_id_new" => "profile_id_collision"})

      true ->
        case ProviderProfiles.parse_editor(params, id, %{}) do
          {:ok, profile} ->
            config = ProviderProfiles.update(socket.assigns[:file_config], nil, profile)

            persist(config, expand_saved(socket, profile), gettext("Provider account saved."))

          {:error, errors} ->
            wizard_errors(socket, errors)
        end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # in-browser ChatGPT sign-in (PAGE-level state, three surfaces)
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Starts ONE in-browser Sign in with ChatGPT for the surface the payload names.

  The surface is `ChatGPTSignInState.surface_from_params/1` (`"wizard"` when the
  payload carries none, which is what the wizard's DOM sends) and the account is
  that surface's OWN selection — the wizard draft's current pick, or the
  `siwc_account` of the expanded/status account — each falling back to the
  registration the store treats as default. `ChatGPTSignIn` owns the flow id,
  the authorization URL and the bounded poll; `begin/1` is bounded and degrades
  to `{:error, reason}`, so this handler never blocks the page and never raises.
  """
  def chatgpt_sign_in(socket, params) do
    surface = ChatGPTSignInState.surface_from_params(params)
    account = surface_account(socket, surface)
    state = ChatGPTSignInState.begin(page_sign_in(socket), account, surface, self())

    {:noreply, socket |> assign(:chatgpt_sign_in, state) |> sync_sign_in_state()}
  end

  @doc """
  Abandons the waiting in-browser sign-in of the surface the payload names.

  The flow is cancelled only when it belongs to THAT surface (a flow owned by
  another surface is not the one being dismissed); a failure to cancel is
  deliberately quiet — the surface just returns to the idle button, and there is
  nothing the user could do about a flow that already ended.
  """
  def chatgpt_sign_in_cancel(socket, params) do
    surface = ChatGPTSignInState.surface_from_params(params)
    state = ChatGPTSignInState.cancel_owned_by(page_sign_in(socket), surface)

    {:noreply, socket |> assign(:chatgpt_sign_in, state) |> sync_sign_in_state()}
  end

  @doc """
  Applies the ONE `{:chatgpt_signin_result, flow_id, result}` a poll delivers.

  `ChatGPTSignInState.apply_result/3` is the ONLY stale guard: a result for a
  flow the page no longer waits on — a newer click superseded it, it was
  cancelled, or its surface was closed — changes NOTHING (no phase, no side
  effect). A successful sign-in writes the connected registration into the
  OWNING surface's selection (the wizard draft, or the expanded account's
  detached form draft), reloads the node's registrations, invalidates any
  pending connection test, refreshes the credential-status rows (their
  credentials just changed) and clears the pending save token. Failures become
  the `:error` phase; the friendly wording belongs to the presentation
  component.
  """
  def chatgpt_signin_result(socket, flow_id, result) do
    case ChatGPTSignInState.apply_result(page_sign_in(socket), flow_id, result) do
      {:ok, state, account} ->
        {:noreply,
         socket
         |> assign(:chatgpt_sign_in, state)
         |> apply_signed_in_account(ChatGPTSignInState.surface(state), account)
         |> reload_chatgpt_accounts()
         |> LlmTestEvents.invalidate_llm_test()
         |> EvoDashWeb.SettingsLive.start_auth_status_load()
         |> assign(:profile_save_token, nil)
         |> sync_sign_in_state()}

      {:error, state, _reason} ->
        {:noreply, socket |> assign(:chatgpt_sign_in, state) |> sync_sign_in_state()}

      {:stale, _state} ->
        {:noreply, socket}
    end
  end

  # The page-level `:chatgpt_sign_in` state is the SOURCE OF TRUTH; the wizard map
  # carries its own surface PROJECTION (`surface_state/2`) plus the page's
  # local/remote verdict, so the frozen wizard form keeps reading
  # `wizard.chatgpt_sign_in` / `wizard.chatgpt_sign_in_manual`.
  defp sync_sign_in_state(socket) do
    socket = assign(socket, :chatgpt_sign_in_manual, ChatGPTSignInState.manual?(socket.assigns))

    case socket.assigns[:provider_wizard] do
      %{} = wizard -> assign(socket, :provider_wizard, ensure_sign_in_keys(wizard, socket))
      _wizard -> socket
    end
  end

  # The page state's value — TOTAL: a missing/garbage assign reads as idle.
  defp page_sign_in(socket) do
    case socket.assigns[:chatgpt_sign_in] do
      %{} = state -> state
      _state -> ChatGPTSignInState.new()
    end
  end

  # Dismissing a surface abandons ONLY the flow that surface owns, so a late poll
  # result can never resurface in a later, unrelated surface.
  defp close_surface(socket, nil), do: socket

  defp close_surface(socket, surface) do
    assign(
      socket,
      :chatgpt_sign_in,
      ChatGPTSignInState.cancel_owned_by(page_sign_in(socket), surface)
    )
  end

  defp detail_surface(nil), do: nil
  defp detail_surface(id), do: {:detail, id}

  # The account a surface signs in: its own selection, else the registration the
  # store treats as default (`ChatGPT.account_name(nil)`).
  defp surface_account(socket, {_kind, id}) do
    case find_profile(socket, id) do
      nil -> ChatGPT.account_name(nil)
      profile -> ChatGPT.account_name(ProviderProfiles.field(profile, "siwc_account"))
    end
  end

  defp surface_account(socket, _surface) do
    case socket.assigns[:provider_wizard] do
      %{draft: draft} when is_map(draft) -> ChatGPT.account_name(draft["siwc_account"])
      _wizard -> ChatGPT.account_name(nil)
    end
  end

  defp apply_signed_in_account(socket, :wizard, account) do
    case socket.assigns[:provider_wizard] do
      %{draft: draft} = wizard when is_map(draft) ->
        wizard =
          wizard
          |> Map.put(:draft, Map.put(draft, "siwc_account", account))
          |> Map.put(:errors, %{})

        assign(socket, :provider_wizard, wizard)

      _wizard ->
        socket
    end
  end

  # The connected registration belongs to the account whose detail/status surface
  # owns the flow — the EXPANDED profile's detached draft, never the wizard's.
  defp apply_signed_in_account(socket, {_kind, id}, account) do
    draft = socket.assigns[:profile_form_draft]

    if socket.assigns[:editing_profile_id] == id and is_map(draft) do
      assign(socket, :profile_form_draft, Map.put(draft, "siwc_account", account))
    else
      socket
    end
  end

  defp apply_signed_in_account(socket, _surface, _account), do: socket

  defp reload_chatgpt_accounts(socket) do
    case socket.assigns[:provider_wizard] do
      %{draft: draft} = wizard when is_map(draft) ->
        assign(socket, :provider_wizard, load_chatgpt_accounts(wizard, socket))

      _wizard ->
        socket
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # add model (inline, under one saved account)
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Opens the add-model step under a SAVED account and collapses the expanded
  editor (one form at a time).
  """
  def start_add_provider_model(socket, %{"profile_id" => profile_id}) do
    case find_profile(socket, profile_id) do
      nil ->
        {:noreply, socket}

      profile ->
        wizard = %{
          mode: {:model, profile["id"]},
          step: :model,
          draft: %{},
          errors: %{},
          schedule: @empty_wizard_schedule
        }

        wizard =
          wizard
          |> ensure_sign_in_keys(socket)
          |> maybe_load_chatgpt_accounts(profile, socket)

        {:noreply,
         socket
         |> close_editor()
         |> assign(provider_schedule: empty_schedule(), provider_wizard: wizard)}
    end
  end

  def start_add_provider_model(socket, _params), do: {:noreply, socket}

  @doc "Merges one add-model submission into the model-step draft."
  def provider_model_change(socket, params) when is_map(params) do
    case socket.assigns[:provider_wizard] do
      %{draft: draft} = wizard when is_map(draft) ->
        {:noreply,
         assign(socket,
           provider_wizard:
             Map.merge(wizard, %{draft: ProviderProfiles.submission(params, draft), errors: %{}})
         )}

      _wizard ->
        {:noreply, socket}
    end
  end

  def provider_model_change(socket, _params), do: {:noreply, socket}

  @doc "Closes the add-model step without writing anything."
  def provider_model_cancel(socket, _params) do
    {:noreply, socket |> close_surface(:wizard) |> assign(:provider_wizard, nil)}
  end

  @doc """
  Appends the chosen model to the saved account's `models[]` and persists the
  whole account through the same canonical parser.
  """
  def provider_model_save(socket, _params) do
    case socket.assigns[:provider_wizard] do
      %{mode: {:model, profile_id}, draft: draft} when is_map(draft) ->
        with model when is_binary(model) and model != "" <- model_value(draft),
             %{} = profile <- find_profile(socket, profile_id),
             :ok <- chatgpt_model_available(socket, profile, model) do
          base = ProviderProfiles.draft(profile)

          full_draft =
            base
            |> Map.put(
              "models",
              ProviderProfiles.rows(base["models"]) ++ [model_row(model, draft)]
            )

          case ProviderProfiles.parse_editor(full_draft, profile["id"], profile) do
            {:ok, updated} ->
              config =
                ProviderProfiles.update(socket.assigns[:file_config], profile["id"], updated)

              persist(
                config,
                expand_saved(socket, updated),
                gettext("Model added to the provider account.")
              )

            {:error, errors} ->
              wizard_errors(socket, errors)
          end
        else
          {:error, :chatgpt_model_unavailable} ->
            wizard_errors(socket, %{"model" => "chatgpt_model_unavailable"})

          _ ->
            wizard_errors(socket, %{"model" => "model_id_empty"})
        end

      _wizard ->
        {:noreply, socket}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # expanded account editor (delegated, with schedule bookkeeping)
  # ═══════════════════════════════════════════════════════════════════════════

  @doc "Expands one account in place (collapses it again when it is already open)."
  def edit_provider_profile(socket, params) do
    previous = socket.assigns[:editing_profile_id]
    {:noreply, updated} = ModelProfileEvents.edit_model_profile(socket, params)
    expanded = updated.assigns[:editing_profile_id]

    cond do
      is_nil(expanded) ->
        # Clicking the OPEN account closes it (the toggle path), so its detail
        # surface — and any flow it was waiting on — goes with it.
        {:noreply,
         updated
         |> close_surface(detail_surface(previous))
         |> assign(provider_schedule: empty_schedule())}

      expanded == previous ->
        {:noreply, updated}

      true ->
        {:noreply,
         updated
         |> close_surface(:wizard)
         |> assign(provider_wizard: nil)
         |> assign(provider_schedule: empty_schedule())}
    end
  end

  @doc "Closes the expanded account and its schedule strip."
  def cancel_edit_provider_profile(socket, params) do
    surface = detail_surface(socket.assigns[:editing_profile_id])
    {:noreply, socket} = ModelProfileEvents.cancel_edit_model_profile(socket, params)
    {:noreply, socket |> close_surface(surface) |> assign(provider_schedule: empty_schedule())}
  end

  @doc """
  Saves the expanded account.

  The raw nested UI submission is preserved for rerendering; only the parse
  input is flattened (`ModelProfileEvents.save_model_profile/3` keeps the
  detached draft authoritative).
  """
  def save_provider_profile(socket, params) do
    submitted = ProviderProfiles.submission(params, socket.assigns[:profile_form_draft])

    ModelProfileEvents.save_model_profile(
      socket,
      provider_form_params(submitted),
      submitted
    )
  end

  @doc "Snapshots one form change over the detached draft and refreshes the schedule hint."
  def provider_profile_form_change(socket, params),
    do: refresh_schedule(ModelProfileEvents.model_profile_form_change(socket, params))

  @doc "Makes one account the default (never re-saves the editor draft)."
  def set_default_provider_profile(socket, params),
    do: ModelProfileEvents.set_default_provider_profile(socket, params)

  @doc "Deletes one account; deletes the expanded editor with it."
  def delete_provider_profile(socket, %{"profile_id" => id} = params) do
    {:noreply, updated} = ModelProfileEvents.delete_model_profile(socket, params)

    if socket.assigns[:editing_profile_id] == id do
      {:noreply,
       updated
       |> close_surface(detail_surface(id))
       |> assign(provider_wizard: nil)
       |> assign(provider_schedule: empty_schedule())}
    else
      {:noreply, updated}
    end
  end

  def delete_provider_profile(socket, params),
    do: ModelProfileEvents.delete_model_profile(socket, params)

  @doc "Appends an empty model override row to the expanded draft."
  def add_provider_model(socket, params),
    do: refresh_schedule(ModelProfileEvents.add_profile_model(socket, params))

  @doc "Removes one model override row from the expanded draft."
  def remove_provider_model(socket, params),
    do: refresh_schedule(ModelProfileEvents.remove_profile_model(socket, params))

  @doc "Appends an empty peak window to the expanded draft."
  def add_provider_peak_hours_row(socket, params),
    do: refresh_schedule(ModelProfileEvents.add_peak_hours_row(socket, params))

  @doc "Removes one peak window from the expanded draft."
  def remove_provider_peak_hours_row(socket, params),
    do: refresh_schedule(ModelProfileEvents.remove_peak_hours_row(socket, params))

  @doc "Toggles the expanded editor's Advanced disclosure (a nil rule = automatic)."
  def toggle_profile_advanced(socket, params),
    do: ModelProfileEvents.toggle_profile_advanced(socket, params)

  @doc "Re-reads the viewed node's OAuth credential state asynchronously."
  def refresh_auth_status(socket, _params),
    do: {:noreply, EvoDashWeb.SettingsLive.start_auth_status_load(socket)}

  # ═══════════════════════════════════════════════════════════════════════════
  # recommended schedule (expanded account)
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Applies one published schedule preset to the expanded draft.

  Writes ONLY the preset's schedule keys, keeps the pre-apply snapshot for
  `undo_provider_schedule/2` and invalidates any pending editor save token (the
  draft changed). Never prefills on render.
  """
  def apply_provider_schedule(socket, %{"preset_id" => preset_id}) when is_binary(preset_id) do
    case socket.assigns[:profile_form_draft] do
      draft when is_map(draft) and map_size(draft) > 0 ->
        if socket.assigns[:editing_profile_id] do
          {draft, snapshot} = Schedule.apply(preset_id, draft)

          {:noreply,
           assign(socket,
             profile_form_draft: draft,
             profile_save_token: nil,
             provider_schedule: %{
               preset_id: preset_id,
               applied: true,
               modified: false,
               can_undo: true,
               snapshot: snapshot
             }
           )}
        else
          {:noreply, socket}
        end

      _draft ->
        {:noreply, socket}
    end
  end

  def apply_provider_schedule(socket, _params), do: {:noreply, socket}

  @doc "Restores the pre-preset schedule of the expanded draft."
  def undo_provider_schedule(socket, _params) do
    schedule = socket.assigns[:provider_schedule] || empty_schedule()

    case {socket.assigns[:profile_form_draft], Map.get(schedule, :snapshot)} do
      {draft, snapshot} when is_map(draft) and is_map(snapshot) ->
        {:noreply,
         assign(socket,
           profile_form_draft: Schedule.undo(draft, snapshot),
           profile_save_token: nil,
           provider_schedule: empty_schedule()
         )}

      _other ->
        {:noreply, socket}
    end
  end

  @doc "Dismisses the schedule strip without touching the draft's schedule fields."
  def dismiss_schedule_applied(socket, _params),
    do: {:noreply, assign(socket, provider_schedule: empty_schedule())}

  # ═══════════════════════════════════════════════════════════════════════════
  # save-path helpers
  # ═══════════════════════════════════════════════════════════════════════════

  # The new presentation nests generation inputs while the canonical parser
  # deliberately accepts flat request fields. Keep UI sentinels out of storage.
  defp provider_form_params(params) do
    params
    |> flatten_generation_params()
    |> Map.update("models", [], fn rows ->
      rows
      |> ProviderProfiles.rows()
      |> Enum.map(fn row ->
        row = flatten_generation_params(row)

        row =
          case row["override_reasoning"] do
            value when value in [false, "false"] ->
              # Absence means inherit; [] would explicitly override inventory.
              Map.delete(row, "reasoning_efforts")

            value when value in [true, "true"] ->
              if ProviderProfiles.string_list(row["reasoning_efforts"]) == [] do
                row
                |> Map.put("reasoning_efforts", [])
                |> Map.delete("default_reasoning_effort")
              else
                row
              end

            _ ->
              row
          end

        Map.delete(row, "override_reasoning")
      end)
    end)
  end

  defp flatten_generation_params(params) do
    generation = Map.get(params, "generation", %{})

    keys =
      ~w(temperature max_tokens top_p top_k frequency_penalty presence_penalty provider_options extra)

    params
    |> Map.delete("generation")
    |> Map.merge(Map.take(generation, keys))
  end

  defp persist(config, socket, message),
    do: EvoDashWeb.SettingsLive.persist_file_config(config, socket, message)

  # ═══════════════════════════════════════════════════════════════════════════
  # state helpers
  # ═══════════════════════════════════════════════════════════════════════════

  defp new_account_wizard(socket) do
    ensure_sign_in_keys(
      %{
        mode: :account,
        step: :provider,
        draft: ProviderProfiles.new_draft(socket.assigns[:file_config] || %{}),
        errors: %{},
        schedule: @empty_wizard_schedule
      },
      socket
    )
  end

  # Both sign-in keys exist on EVERY wizard map, so the frozen form never sees
  # `nil` (`WizardForm.normalize_wizard/1` tolerates absence, but the page owns
  # the truth). `chatgpt_sign_in` is the WIZARD-SURFACE PROJECTION of the
  # page-level state (`ChatGPTSignInState.surface_state/2`, `%{}` when another
  # surface owns it) and `chatgpt_sign_in_manual` is the page's local/remote
  # verdict (`ChatGPTSignInState.manual?/1`) — the in-browser flow binds a
  # loopback listener on the BEAM running THIS page, so a viewed remote target
  # (`?node=<id>`, connected or still pending) gets the CLI hint instead.
  defp ensure_sign_in_keys(wizard, socket) when is_map(wizard) do
    wizard
    |> Map.put(
      :chatgpt_sign_in,
      ChatGPTSignInState.surface_state(page_sign_in(socket), :wizard)
    )
    |> Map.put(:chatgpt_sign_in_manual, ChatGPTSignInState.manual?(socket.assigns))
  end

  defp close_editor(socket) do
    socket
    |> close_surface(detail_surface(socket.assigns[:editing_profile_id]))
    |> assign(
      editing_profile_id: nil,
      profile_form_draft: nil,
      profile_generated_id: nil,
      profile_form_errors: %{},
      profile_save_token: nil,
      profile_advanced_open: nil
    )
  end

  # The saved account is expanded optimistically with its fresh detached draft;
  # the authoritative file_config arrives with the confirmed write. Expanding it
  # dismisses the wizard, so the wizard surface's waiting flow goes with it.
  defp expand_saved(socket, profile) do
    socket
    |> close_surface(:wizard)
    |> assign(
      editing_profile_id: profile["id"],
      profile_form_draft: ProviderProfiles.draft(profile),
      profile_generated_id: nil,
      profile_form_errors: %{},
      profile_save_token: nil,
      profile_advanced_open: nil,
      provider_wizard: nil,
      provider_schedule: empty_schedule()
    )
  end

  defp move_wizard_step(socket, fun) do
    case socket.assigns[:provider_wizard] do
      %{draft: draft, step: step} = wizard when is_map(draft) ->
        steps = WizardForm.rendered_steps(draft)
        next = fun.(steps, step) || step
        wizard = wizard |> Map.put(:step, next) |> ensure_sign_in_keys(socket)
        assign(socket, provider_wizard: wizard)

      _wizard ->
        socket
    end
  end

  defp load_chatgpt_accounts(wizard, socket) do
    Map.put(wizard, :chatgpt_accounts, ChatGPT.accounts(socket.assigns[:current_node] || node()))
  end

  defp maybe_load_chatgpt_accounts(wizard, profile, socket) do
    if ChatGPT.provider?(profile["provider"]),
      do: load_chatgpt_accounts(wizard, socket),
      else: wizard
  end

  defp reset_chatgpt_selection(draft, previous) do
    if ChatGPT.provider?(draft["provider"]) and
         (draft["provider"] != previous["provider"] or
            draft["siwc_account"] != previous["siwc_account"]) do
      Map.drop(draft, ~w(model custom_model))
    else
      draft
    end
  end

  defp chatgpt_model_available(socket, %{"provider" => "openai_codex"} = profile, model) do
    accounts = ChatGPT.accounts(socket.assigns[:current_node] || node())

    if ChatGPT.available_model?(accounts, profile["siwc_account"], model),
      do: :ok,
      else: {:error, :chatgpt_model_unavailable}
  end

  defp chatgpt_model_available(_socket, _profile, _model), do: :ok

  defp derive_identity(draft, params, config) do
    if is_binary(params["provider"]) do
      draft = draft |> Map.drop(["profile_id_new"]) |> Map.put("name", "")

      ProviderProfiles.editor_identity(draft, config || %{}, :new, draft["id"])
    else
      draft
    end
  end

  defp recompute_wizard_modified(schedule, draft) when is_map(schedule) do
    if Map.get(schedule, :applied?) do
      Map.put(schedule, :modified?, Schedule.changed?(draft, Map.get(schedule, :snapshot, %{})))
    else
      schedule
    end
  end

  defp recompute_wizard_modified(_schedule, _draft), do: @empty_wizard_schedule

  # Recompute "modified after applying" after ANY draft mutation, but only while
  # a pre-apply snapshot exists (nothing to compare against otherwise).
  defp refresh_schedule({:noreply, socket}) do
    schedule = socket.assigns[:provider_schedule] || empty_schedule()

    schedule =
      case {Map.get(schedule, :applied), Map.get(schedule, :snapshot)} do
        {true, snapshot} when is_map(snapshot) ->
          Map.put(
            schedule,
            :modified,
            Schedule.changed?(socket.assigns[:profile_form_draft], snapshot)
          )

        _other ->
          schedule
      end

    {:noreply, assign(socket, provider_schedule: schedule)}
  end

  defp wizard_errors(socket, errors) when is_map(errors) do
    translated =
      Map.new(errors, fn {key, reason} ->
        {key, wizard_error_message(reason)}
      end)

    wizard = socket.assigns[:provider_wizard] || %{}

    socket =
      assign(
        socket,
        :provider_wizard,
        wizard |> Map.put(:errors, translated) |> ensure_sign_in_keys(socket)
      )

    message =
      translated |> Map.values() |> List.first() ||
        gettext("Could not save the provider account.")

    {:noreply, put_flash(socket, :error, message)}
  end

  defp wizard_error_message("chatgpt_login_required"),
    do: gettext("Connect a ChatGPT account before continuing.")

  defp wizard_error_message("chatgpt_model_unavailable"),
    do: gettext("Choose a model available to this ChatGPT account.")

  defp wizard_error_message(reason), do: ModelProfileEvents.error_message(reason)

  defp parameters(wizard, params), do: Map.merge(wizard[:draft] || %{}, params)

  # `model` wins over `custom_model`; both trimmed, "" when neither is usable.
  defp model_value(draft) do
    case text(draft["model"]) do
      "" -> text(draft["custom_model"])
      model -> model
    end
  end

  defp model_row(model, draft) do
    extra =
      Enum.reduce(["reasoning_efforts", "default_reasoning_effort", "context_window"], %{}, fn
        key, acc ->
          case Map.get(draft, key) do
            nil ->
              acc

            "" ->
              acc

            [] ->
              acc

            value when key == "reasoning_efforts" ->
              Map.put(acc, key, ProviderProfiles.string_list(value))

            value ->
              Map.put(acc, key, value)
          end
      end)

    Map.merge(%{"model" => model}, extra)
  end

  defp find_profile(socket, id) do
    Enum.find(
      ProviderProfiles.profiles(socket.assigns[:file_config] || %{}),
      &(ProviderProfiles.field(&1, "id") == id)
    )
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
