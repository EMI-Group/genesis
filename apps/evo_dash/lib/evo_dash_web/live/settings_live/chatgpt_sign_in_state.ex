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
        reason: nil | atom
      }

  Only ONE flow can be live at a time (`begin/4` closes whatever was waiting
  first), and the `flow_id` is the ONLY stale guard a poll result needs: a
  superseded, cancelled or closed flow no longer matches the state, so its late
  result is dropped (`apply_result/3`).

  Every function is pure plumbing around
  `EvoDashWeb.LLMSetup.ChatGPTSignIn` (which owns the flow, the bounded poll
  and the friendly vocabulary): no LiveView imports, no `self()` (the poll owner
  is an explicit argument), no I/O, and every call into the flow module degrades
  to a value instead of raising.
  """

  alias EvoDashWeb.LLMSetup.ChatGPTSignIn
  alias EvoDashWeb.SettingsComponents.ChatGPTSignInPanel

  @typedoc "The surfaces sharing the page state (`nil` = no surface owns it)."
  @type surface :: nil | :wizard | {:detail, String.t()} | {:status, String.t()}

  @typedoc "How a sign-in is presented on its surface."
  @type phase :: :idle | :waiting | :ok | :error

  @type t :: %{
          surface: surface(),
          flow_id: nil | String.t(),
          url: nil | String.t(),
          phase: phase(),
          reason: nil | atom()
        }

  @doc """
  The idle state with NO owning surface — the page's initial value.
  """
  @spec new() :: t()
  def new, do: %{surface: nil, flow_id: nil, url: nil, phase: :idle, reason: nil}

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

  Answers the new state: `:waiting` with the flow id and authorization URL, or
  `:error` with the flow module's reason and NO poll.
  """
  @spec begin(t(), term(), term(), pid()) :: t()
  def begin(state, account, surface, owner) when is_pid(owner) do
    surface = normalize_surface(surface)
    _state = close_waiting(state)

    case ChatGPTSignIn.begin(account) do
      {:ok, %{id: id, url: url}} ->
        # Total: an unavailable supervisor delivers the error result
        # immediately instead of leaving the surface waiting forever.
        ChatGPTSignIn.start_poll(id, owner)
        %{new() | surface: surface, flow_id: id, url: url, phase: :waiting}

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

  # ── Internals ──────────────────────────────────────────────────────────────

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
