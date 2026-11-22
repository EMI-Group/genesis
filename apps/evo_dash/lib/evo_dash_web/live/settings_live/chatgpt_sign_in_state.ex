defmodule EvoDashWeb.SettingsLive.ChatGPTSignInState do
  @moduledoc """
  The `/settings` page's ONE in-browser Sign in with ChatGPT (SIWC) state.

  One page renders up to THREE sign-in surfaces — the add-account wizard's auth
  step, an expanded account's detail form and an account's auth-status row — so
  the state is PAGE-LEVEL, not wizard-scoped: `EvoDashWeb.SettingsLive` keeps it
  in the `:chatgpt_sign_in` assign (plus the local/remote verdict in
  `:chatgpt_sign_in_manual`) and every surface reads it through
  `EvoDashWeb.SettingsComponents.ChatGPTSignInPanel.surface_state/2`, the ONE
  surface-isolation rule (see `surface_state/2` below, which only delegates).

  The page state shape is fixed:

      %{
        surface: nil | :wizard | {:detail, profile_id} | {:status, profile_id},
        flow_id: nil | binary,
        url: nil | binary,
        phase: :idle | :waiting | :ok | :error,
        reason: nil | atom,
        port: nil | pos_integer,
        mode: nil | :loopback | :manual,
        paste: String.t(),
        paste_error: nil | atom
      }

  Only ONE flow can be live at a time (`begin/4` closes whatever was waiting
  first), and the `flow_id` is the ONLY stale guard a poll result needs: a
  superseded, cancelled or closed flow no longer matches the state, so its late
  result is dropped (`apply_result/3`).

  `port`/`mode` are the flow's redirect identity (`mode: :manual` means no
  local listener could be bound), and `paste`/`paste_error` carry the manual
  "paste the redirect URL" fallback: the text the user typed and the retryable
  inline rejection of the last submit.

  The SOCKET glue belongs to this module too, so the whole feature lives in ONE
  place: `chatgpt_sign_in/2`, `chatgpt_sign_in_cancel/2`,
  `chatgpt_sign_in_paste/2`, `chatgpt_sign_in_submit/2` and
  `chatgpt_signin_result/3` are the page's handlers (they take and answer a
  socket, exactly like the page's other event handlers), and `close_surface/2`,
  `detail_surface/1` and `ensure_wizard_keys/2` are the helpers every close site
  and every wizard build already calls.

  The state functions are pure plumbing around
  `EvoDashWeb.LLMSetup.ChatGPTSignIn` (which owns the flow, the bounded poll
  and the friendly vocabulary): the poll owner is an explicit argument (never
  `self/0`), and every call into the flow module degrades to a value instead of
  raising. The socket functions add only the page's assigns and side effects;
  `accounts/1` and `manual?/1` are the two node-context reads.
  """

  import Phoenix.Component, only: [assign: 3]

  alias EvoDashWeb.LLMSetup.ChatGPT
  alias EvoDashWeb.LLMSetup.ChatGPTSignIn
  alias EvoDashWeb.SettingsComponents.ChatGPTSignInPanel
  alias EvoDashWeb.SettingsLive.LlmTestEvents
  alias EvoDashWeb.SettingsLive.ProviderProfiles

  @typedoc "The surfaces sharing the page state (`nil` = no surface owns it)."
  @type surface :: nil | :wizard | {:detail, String.t()} | {:status, String.t()}

  @typedoc "How a sign-in is presented on its surface."
  @type phase :: :idle | :waiting | :ok | :error

  @type t :: %{
          surface: surface(),
          flow_id: nil | String.t(),
          url: nil | String.t(),
          phase: phase(),
          reason: nil | atom(),
          port: nil | pos_integer(),
          mode: nil | :loopback | :manual,
          paste: String.t(),
          paste_error: nil | atom()
        }

  # A paste rejection that keeps the attempt PENDING: the user simply pastes
  # again, so these never leave the waiting panel.
  @retryable_paste_errors [:invalid_callback, :no_code, :already_finished]

  @doc """
  The idle state with NO owning surface — the page's initial value.
  """
  @spec new() :: t()
  def new do
    %{
      surface: nil,
      flow_id: nil,
      url: nil,
      phase: :idle,
      reason: nil,
      port: nil,
      mode: nil,
      paste: "",
      paste_error: nil
    }
  end

  @doc "Alias of `new/0` (the idle page state)."
  @spec defaults() :: t()
  def defaults, do: new()

  # ── Surfaces ───────────────────────────────────────────────────────────────

  @doc """
  The surface a `chatgpt_sign_in` / `chatgpt_sign_in_cancel` payload names —
  TOTAL.

  Reads `params["surface"]` (`"wizard"`, `"detail"`, `"status"`) and
  `params["profile_id"]` (`:surface` / `:profile_id` atom keys are tolerated).
  `"detail"`/`"status"` need a usable id; everything else — `"wizard"`, an
  absent value, an unknown value, a blank id — is `:wizard`, so the wizard DOM
  (which sends its surface but never needs to) keeps working unchanged.
  """
  @spec surface_from_params(term()) :: surface()
  def surface_from_params(params) when is_map(params) do
    kind = Map.get(params, "surface", Map.get(params, :surface))
    id = Map.get(params, "profile_id", Map.get(params, :profile_id))

    normalize_surface({kind, id})
  end

  def surface_from_params(_params), do: :wizard

  @doc "The surface currently owning the state (`nil` when none does)."
  @spec surface(term()) :: surface()
  def surface(state), do: stored_surface(state)

  @doc """
  Whether `surface` is the one the state belongs to — profile ids compare as
  strings and a blank/absent id never matches.
  """
  @spec owned_by?(term(), term()) :: boolean()
  def owned_by?(state, surface) when is_map(state) do
    same_surface?(stored_surface(state), normalize_surface(surface))
  end

  def owned_by?(_state, _surface), do: false

  @doc """
  The sign-in state ONE surface may render — the delegated
  `ChatGPTSignInPanel.surface_state/2` (the ONE isolation rule).

  Answers the normalized `%{flow_id:, url:, phase:, reason:}` when that surface
  owns the state (the canonical idle map when it is idle) and `%{}` otherwise.
  """
  @spec surface_state(term(), term()) :: map()
  def surface_state(state, surface), do: ChatGPTSignInPanel.surface_state(state, surface)

  @doc "Whether a flow is still waiting for its browser round-trip."
  @spec waiting?(term()) :: boolean()
  def waiting?(state) when is_map(state) do
    Map.get(state, :phase) == :waiting and is_binary(flow_id(state))
  end

  def waiting?(_state), do: false

  @doc "The live flow id of the state (`nil` when no flow is recorded)."
  @spec flow_id(term()) :: nil | String.t()
  def flow_id(state) when is_map(state) do
    case Map.get(state, :flow_id) do
      id when is_binary(id) and id != "" -> id
      _id -> nil
    end
  end

  def flow_id(_state), do: nil

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  @doc """
  Starts ONE in-browser sign-in for `account` on `surface`.

  A still-waiting flow on ANY surface is cancelled first, so two live flows can
  never race for the page state. `owner` is the process the poll reports to (the
  LiveView passes `self()`, this module never does), and the poll runs
  off-process through `ChatGPTSignIn.start_poll/2`.

  Answers the new state: `:waiting` with the flow id, authorization URL and the
  flow's redirect identity (`port`, `mode`), or `:error` with the flow module's
  reason and NO poll.
  """
  @spec begin(t(), term(), term(), pid()) :: t()
  def begin(state, account, surface, owner) when is_pid(owner) do
    surface = normalize_surface(surface)
    _state = close_waiting(state)

    case ChatGPTSignIn.begin(account) do
      {:ok, %{id: id, url: url} = flow} ->
        # Total: an unavailable supervisor delivers the error result
        # immediately instead of leaving the surface waiting forever.
        ChatGPTSignIn.start_poll(id, owner)

        %{
          new()
          | surface: surface,
            flow_id: id,
            url: url,
            phase: :waiting,
            port: Map.get(flow, :port),
            mode: Map.get(flow, :mode)
        }

      {:error, reason} ->
        %{new() | surface: surface, phase: :error, reason: reason}
    end
  end

  # Without a poll owner nothing could ever resolve the flow, so it is reported
  # as unavailable instead of waiting forever.
  def begin(state, _account, surface, _owner) do
    _state = close_waiting(state)
    %{new() | surface: normalize_surface(surface), phase: :error, reason: :sign_in_unavailable}
  end

  @doc """
  Applies the ONE poll result for `flow_id` — the ONLY stale guard.

  A result whose flow id is not the current one (a newer click superseded it, it
  was cancelled, or its surface was closed) leaves the state UNCHANGED and
  answers `{:stale, state}`. The current flow's `{:ok, %{account: account}}`
  answers `{:ok, state, account}` with the `:ok` phase (the surface is kept so
  it renders its post-sign-in state), `{:error, reason}` answers
  `{:error, state, reason}`, and anything unexpected degrades to the `:error`
  phase with `:sign_in_unavailable` — never a crash.
  """
  @spec apply_result(term(), term(), term()) ::
          {:ok, t(), String.t()} | {:error, t(), term()} | {:stale, term()}
  def apply_result(state, result_flow_id, result) when is_map(state) do
    if is_binary(result_flow_id) and result_flow_id == flow_id(state) do
      case result do
        {:ok, %{account: account}} when is_binary(account) and account != "" ->
          {:ok, put_phase(state, :ok, nil), account}

        {:error, reason} ->
          {:error, put_phase(state, :error, reason), reason}

        _unexpected ->
          {:error, put_phase(state, :error, :sign_in_unavailable), :sign_in_unavailable}
      end
    else
      {:stale, state}
    end
  end

  def apply_result(state, _result_flow_id, _result), do: {:stale, state}

  @doc """
  Closes the live flow (guarded, quiet on failure) and answers the IDLE state of
  the SAME surface, so that surface renders a fresh sign-in button again.

  The flow id is cleared, so a late poll result can never resurface in a later,
  unrelated surface.
  """
  @spec cancel(term()) :: t()
  def cancel(state) when is_map(state) do
    _state = close_waiting(state)
    %{new() | surface: stored_surface(state)}
  end

  def cancel(_state), do: new()

  @doc """
  Cancels + resets ONLY when the state belongs to `surface`.

  This is the close-path rule: dismissing the surface that OWNS a waiting flow
  abandons that flow, while a flow owned by another surface is left untouched.
  """
  @spec cancel_owned_by(term(), term()) :: term()
  def cancel_owned_by(state, surface) when is_map(state) do
    if owned_by?(state, surface), do: cancel(state), else: state
  end

  def cancel_owned_by(state, _surface), do: state

  # ── Presentation verdict ───────────────────────────────────────────────────

  @doc """
  Whether this page must offer the `genesis chatgpt login` HINT instead of a
  sign-in button — TRUE for a remote viewed node.

  The in-browser flow binds a loopback listener on the BEAM running THIS page, so
  it can only serve a sign-in when that BEAM is the execution node; a viewed
  remote target (`?node=<id>`, connected or still pending) cannot be reached by
  another machine's browser. Total for an assigns map (a socket is accepted too).
  """
  @spec manual?(term()) :: boolean()
  def manual?(%{assigns: assigns}) when is_map(assigns), do: manual?(assigns)

  def manual?(assigns) when is_map(assigns) do
    current = Map.get(assigns, :current_node) || node()
    current != node() or Map.get(assigns, :current_node_id) != nil
  end

  def manual?(_assigns), do: false

  @doc """
  The viewed node's in-browser ChatGPT registrations (its OWN account list).
  """
  @spec accounts(term()) :: map()
  def accounts(socket) do
    ChatGPT.accounts(Map.get(socket.assigns, :current_node) || node())
  end

  # ── Manual paste fallback (the ONE transition set) ─────────────────────────
  #
  # `/settings` (three surfaces) and `/welcome` (the wizard surface) both offer
  # the "paste the redirect URL" disclosure while a flow waits. These four
  # functions are the WHOLE transition logic, so no page re-derives how a paste
  # is recorded or how the flow's answer maps onto the state.
  @doc """
  The paste fallback applies to ONE surface: the one that currently OWNS a
  WAITING flow.
  Everything else — closed, superseded, idle, error — is not a paste target, so
  a late payload never resurrects a waiting panel.
  """
  @spec paste_target?(term(), term()) :: boolean()
  def paste_target?(state, surface) do
    owned_by?(state, surface) and Map.get(state, :phase) == :waiting
  end

  @doc """
  Whether an EVENT payload should act on the page's current sign-in state.
  The paste input is the awkward case: an input-level `phx-change` makes
  LiveView serialize the enclosing form's field VALUES (so the payload does
  carry `"paste"`) but read `phx-value-*` from the FORM, never the input —
  hence a keystroke in the paste input arrives with NO `surface` and NO
  `profile_id` at all. A surface-less payload therefore targets the ONE state
  that is WAITING (there is exactly one `:chatgpt_sign_in` state per page, and
  `paste_target?/2` has nothing to match against); a payload that DOES name a
  surface keeps the strict `paste_target?/2` guard, so a superseded/closed
  attempt, or a paste addressed to another surface, still never mutates the
  waiting state.
  """
  @spec paste_payload_target?(term(), term()) :: boolean()
  def paste_payload_target?(state, params) do
    case payload_surface(params) do
      nil -> is_map(state) and Map.get(state, :phase) == :waiting
      surface -> paste_target?(state, surface)
    end
  end

  @doc """
  The redirect URL / code text a payload carries — TOTAL.
  The paste input is `name="paste"`, so a real `phx-change` payload carries
  `"paste"` and never `"value"`; `"value"` stays accepted as the fallback of a
  form-style submit (a `<button>`'s own value is `""`) and of hand-built
  payloads. Atom-keyed payloads are tolerated, and anything else answers `""`.
  """
  @spec paste_text(term()) :: String.t()
  def paste_text(params) when is_map(params) do
    case raw_text(param_value(params, :paste)) do
      "" -> raw_text(param_value(params, :value))
      text -> text
    end
  end

  def paste_text(_params), do: ""

  @doc """
  Records the text typed into a waiting surface's "paste the redirect URL"
  input: verbatim in `:paste` (the user may still be typing) with a cleared
  inline `:paste_error`.
  Pure and cheap — it never touches the flow. A non-map state answers the idle
  state holding that text.
  """
  @spec put_paste(term(), term()) :: t()
  def put_paste(state, text) do
    state = if is_map(state), do: state, else: new()
    Map.merge(state, %{paste: raw_text(text), paste_error: nil})
  end

  @doc """
  Hands the recorded paste back to the OWNING waiting flow — the manual
  (remote-host) completion of the same attempt.
  `params` is the surface's payload: the text is `:paste` when the user typed
  something, else the payload's own paste text via `paste_text/1` (a bare
  button click carries none). A blank text answers the
  inline, retryable `:no_code` error WITHOUT touching the flow; a state with no
  flow degrades to the `:error` phase; otherwise
  `EvoDashWeb.LLMSetup.ChatGPTSignIn.submit/2` acknowledges the paste and the
  terminal outcome still arrives through the poll.
  """
  @spec submit_paste(term(), term()) :: t()
  def submit_paste(state, params) do
    state = if is_map(state), do: state, else: new()

    case paste_input(state, params) do
      "" ->
        # Nothing to hand the flow: an inline, retryable hint only.
        Map.merge(state, %{paste: "", paste_error: :no_code})

      text ->
        case flow_id(state) do
          nil ->
            Map.merge(state, %{phase: :error, reason: :sign_in_unavailable, paste_error: nil})

          flow_id ->
            apply_submit_result(state, ChatGPTSignIn.submit(flow_id, text))
        end
    end
  end

  @doc """
  Maps ONE flow acknowledgement onto the state:
    * `:ok` keeps `:waiting` and clears the paste (the poll resolves the flow);
    * `:invalid_callback` / `:no_code` / `:already_finished` keep `:waiting`
      with an inline, retryable `:paste_error`, so the waiting panel stays
      visible and the user can paste again;
    * any other failure becomes the `:error` phase.
  """
  @spec apply_submit_result(term(), term()) :: t()
  def apply_submit_result(state, result) do
    if is_map(state), do: apply_paste(state, result), else: new()
  end

  # ── Socket glue (the `/settings` page's handlers) ──────────────────────────

  @doc """
  Starts ONE in-browser Sign in with ChatGPT for the surface the payload names.

  The surface is `surface_from_params/1` (`:wizard` when the payload carries
  none, which is what the wizard's DOM sends) and the account is that surface's
  OWN selection — the wizard draft's current pick, or the `siwc_account` of the
  expanded/status account — each falling back to the registration the store
  treats as default. `EvoDashWeb.LLMSetup.ChatGPTSignIn` owns the flow id, the
  authorization URL and the bounded poll; `begin/1` is bounded and degrades to
  `{:error, reason}`, so this handler never blocks the page and never raises.
  """
  @spec chatgpt_sign_in(term(), term()) :: {:noreply, term()}
  def chatgpt_sign_in(socket, params) do
    surface = surface_from_params(params)
    account = surface_account(socket, surface)
    state = begin(page_sign_in(socket), account, surface, self())

    {:noreply, socket |> assign(:chatgpt_sign_in, state) |> sync_sign_in_state()}
  end

  @doc """
  Abandons the waiting in-browser sign-in of the surface the payload names.

  The flow is cancelled only when it belongs to THAT surface (a flow owned by
  another surface is not the one being dismissed); a failure to cancel is
  deliberately quiet — the surface just returns to the idle button, and there is
  nothing the user could do about a flow that already ended.
  """
  @spec chatgpt_sign_in_cancel(term(), term()) :: {:noreply, term()}
  def chatgpt_sign_in_cancel(socket, params) do
    surface = surface_from_params(params)
    state = cancel_owned_by(page_sign_in(socket), surface)

    {:noreply, socket |> assign(:chatgpt_sign_in, state) |> sync_sign_in_state()}
  end

  @doc """
  Records the text typed into a waiting surface's "paste the redirect URL" input.

  A `phx-change`, so it is CHEAP and never touches the flow: it only stores the
  payload's paste text (`paste_text/1` — the input's own `"paste"` field, so the
  real browser payload works) in `:paste` and clears the previous inline
  `:paste_error`.
  The payload is judged by `paste_payload_target?/2`, so a surface-less keystroke
  lands on the ONE waiting attempt, while a payload naming another surface — or a
  surface that is not waiting any more — changes NOTHING (a closed or superseded
  attempt never resurfaces).
  """
  @spec chatgpt_sign_in_paste(term(), term()) :: {:noreply, term()}
  def chatgpt_sign_in_paste(socket, params) do
    state = page_sign_in(socket)

    state =
      if paste_payload_target?(state, params) do
        put_paste(state, paste_text(params))
      else
        state
      end

    {:noreply, socket |> assign(:chatgpt_sign_in, state) |> sync_sign_in_state()}
  end

  @doc """
  Hands the recorded paste back to the OWNING waiting flow — the manual
  (remote-host) completion of the same attempt.

  A blank paste answers the inline, retryable `:no_code` error WITHOUT touching
  the flow. Otherwise `EvoDashWeb.LLMSetup.ChatGPTSignIn.submit/2` acknowledges
  the paste and the terminal outcome still arrives through the poll, so:

    * `:ok` keeps `:waiting` and clears the paste (the poll resolves it);
    * `:invalid_callback` / `:no_code` / `:already_finished` keep `:waiting`
      with an inline, retryable `:paste_error` — the waiting panel must stay
      visible so the user can paste again;
    * any other failure becomes the `:error` phase.

  A submit for a surface that no longer owns a waiting flow (superseded, closed,
  cancelled) is dropped before the flow is called at all; the payload is judged
  by `paste_payload_target?/2`, so a click's own `phx-value-*` still win and a
  surface-less payload only lands on the ONE waiting attempt.
  """
  @spec chatgpt_sign_in_submit(term(), term()) :: {:noreply, term()}
  def chatgpt_sign_in_submit(socket, params) do
    state = page_sign_in(socket)

    state =
      if paste_payload_target?(state, params), do: submit_paste(state, params), else: state

    {:noreply, socket |> assign(:chatgpt_sign_in, state) |> sync_sign_in_state()}
  end

  @doc """
  Applies the ONE `{:chatgpt_signin_result, flow_id, result}` a poll delivers.

  `apply_result/3` is the ONLY stale guard: a result for a flow the page no
  longer waits on — a newer click superseded it, it was cancelled, or its
  surface was closed — changes NOTHING (no phase, no side effect). A successful
  sign-in writes the connected registration into the OWNING surface's selection
  (the wizard draft, or the expanded account's detached form draft), reloads the
  node's registrations, invalidates any pending connection test, refreshes the
  credential-status rows (their credentials just changed) and clears the pending
  save token. Failures become the `:error` phase; the friendly wording belongs
  to the presentation component.
  """
  @spec chatgpt_signin_result(term(), term(), term()) :: {:noreply, term()}
  def chatgpt_signin_result(socket, flow_id, result) do
    case apply_result(page_sign_in(socket), flow_id, result) do
      {:ok, state, account} ->
        {:noreply,
         socket
         |> assign(:chatgpt_sign_in, state)
         |> apply_signed_in_account(surface(state), account)
         |> reload_accounts()
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

  @doc """
  Closes the flow a dismissed or replaced surface owns — the shared close-path
  helper (`nil` = no surface to close, a no-op).

  Dismissing a surface abandons ONLY the flow that surface owns, so a late poll
  result can never resurface in a later, unrelated surface.
  """
  @spec close_surface(term(), surface()) :: term()
  def close_surface(socket, nil), do: socket

  def close_surface(socket, surface) do
    assign(socket, :chatgpt_sign_in, cancel_owned_by(page_sign_in(socket), surface))
  end

  @doc "The `{:detail, id}` surface of an expanded account (`nil` when none)."
  @spec detail_surface(nil | String.t()) :: nil | surface()
  def detail_surface(nil), do: nil
  def detail_surface(id), do: {:detail, id}

  @doc """
  Projects the page state onto a wizard map.

  Both sign-in keys exist on EVERY wizard map, so the frozen form never sees
  `nil`: `:chatgpt_sign_in` is the WIZARD-surface projection of the page-level
  state (`surface_state/2`, `%{}` when another surface owns it) and
  `:chatgpt_sign_in_manual` is the page's local/remote verdict (`manual?/1`) —
  the in-browser flow binds a loopback listener on the BEAM running THIS page, so
  a viewed remote target gets the CLI hint instead.
  """
  @spec ensure_wizard_keys(map(), term()) :: map()
  def ensure_wizard_keys(wizard, socket) when is_map(wizard) do
    wizard
    |> Map.put(:chatgpt_sign_in, surface_state(page_sign_in(socket), :wizard))
    |> Map.put(:chatgpt_sign_in_manual, manual?(socket))
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  # The page-level state is the SOURCE OF TRUTH; the wizard map carries its own
  # surface projection plus the page's local/remote verdict.
  defp sync_sign_in_state(socket) do
    socket = assign(socket, :chatgpt_sign_in_manual, manual?(socket))

    case socket.assigns[:provider_wizard] do
      %{} = wizard -> assign(socket, :provider_wizard, ensure_wizard_keys(wizard, socket))
      _wizard -> socket
    end
  end

  # TOTAL: a missing/garbage assign — or no socket — reads as the idle state.
  defp page_sign_in(%{assigns: assigns}) when is_map(assigns) do
    case Map.get(assigns, :chatgpt_sign_in) do
      %{} = state -> state
      _state -> new()
    end
  end

  defp page_sign_in(_socket), do: new()

  defp apply_paste(state, :ok) do
    # The flow ACKED the paste; the poll delivers the terminal result, so the
    # surface stays waiting (with the paste cleared) until then.
    Map.merge(state, %{phase: :waiting, paste: "", paste_error: nil})
  end

  defp apply_paste(state, {:error, reason}) when reason in @retryable_paste_errors do
    Map.merge(state, %{phase: :waiting, paste_error: reason})
  end

  defp apply_paste(state, {:error, reason}) do
    Map.merge(state, %{phase: :error, reason: reason, paste_error: nil})
  end

  # The typed text wins; the payload's own paste text (`paste_text/1`, which
  # also accepts a form-style `value`) is the fallback for a submit.
  defp paste_input(state, params) do
    case text_value(Map.get(state, :paste)) do
      "" -> text_value(paste_text(params))
      text -> text
    end
  end

  defp param_value(params, key) when is_map(params) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> other_key(params, key)
    end
  end

  defp param_value(_params, _key), do: nil

  # Both spellings are tolerated: the panel sends string keys, a hand-built
  # payload may use atoms.
  defp other_key(_params, key) when is_binary(key), do: nil
  defp other_key(params, key), do: Map.get(params, Atom.to_string(key))

  # The surface a PAYLOAD names, or `nil` when it names none at all — the
  # input-level `phx-change` shape, which carries only the input's own field.
  defp payload_surface(params) when is_map(params) do
    if named_param?(params, :surface) or named_param?(params, :profile_id),
      do: surface_from_params(params),
      else: nil
  end

  defp payload_surface(_params), do: nil

  defp named_param?(params, key) do
    case param_value(params, key) do
      value when is_binary(value) -> String.trim(value) != ""
      value -> not is_nil(value)
    end
  end

  defp raw_text(value) when is_binary(value), do: value
  defp raw_text(_value), do: ""

  defp text_value(value) when is_binary(value), do: String.trim(value)
  defp text_value(_value), do: ""

  # The account a surface signs in: its own selection, else the registration the
  # store treats as default (`ChatGPT.account_name(nil)`).
  defp surface_account(socket, {_kind, id}) do
    socket.assigns[:file_config]
    |> ProviderProfiles.profiles()
    |> Enum.find(&(ProviderProfiles.field(&1, "id") == id))
    |> case do
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

  defp reload_accounts(socket) do
    case socket.assigns[:provider_wizard] do
      %{draft: draft} = wizard when is_map(draft) ->
        assign(socket, :provider_wizard, Map.put(wizard, :chatgpt_accounts, accounts(socket)))

      _wizard ->
        socket
    end
  end

  # ONE flow at a time: a waiting flow is abandoned before a new one starts and
  # quiet on failure (there is nothing the user could do about a flow that has
  # already ended).
  defp close_waiting(state) do
    if waiting?(state), do: _ = ChatGPTSignIn.cancel(flow_id(state))
    state
  end

  defp put_phase(state, phase, reason),
    do: Map.merge(state, %{phase: phase, reason: reason})

  defp stored_surface(state) when is_map(state) do
    case Map.get(state, :surface) do
      :wizard -> :wizard
      "wizard" -> :wizard
      {:detail, id} -> kind_surface(:detail, id)
      {:status, id} -> kind_surface(:status, id)
      _other -> nil
    end
  end

  defp stored_surface(_state), do: nil

  defp normalize_surface({kind, id}) when kind in [:detail, "detail"],
    do: kind_surface(:detail, id)

  defp normalize_surface({kind, id}) when kind in [:status, "status"],
    do: kind_surface(:status, id)

  defp normalize_surface(_surface), do: :wizard

  # A detail/status surface needs a usable id; a blank/absent one falls back to
  # the wizard surface (which is what an unsurfaced payload means).
  defp kind_surface(kind, id) do
    case string_id(id) do
      nil -> :wizard
      id -> {kind, id}
    end
  end

  defp same_surface?(nil, _requested), do: false

  # The atoms (`:wizard`) and byte-identical ids compare structurally; the
  # clause below only normalizes atom/string spellings of one id.
  defp same_surface?(same, same), do: true

  defp same_surface?({kind, stored_id}, {kind, requested_id}),
    do: string_id(stored_id) == string_id(requested_id) and not is_nil(string_id(requested_id))

  defp same_surface?(_stored, _requested), do: false

  defp string_id(id) when is_binary(id) do
    if String.trim(id) == "", do: nil, else: id
  end

  defp string_id(id) when is_atom(id) and not is_nil(id), do: Atom.to_string(id)
  defp string_id(id) when is_integer(id), do: Integer.to_string(id)
  defp string_id(_id), do: nil
end
