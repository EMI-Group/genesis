defmodule EvoDash.UpdateStatus do
  @moduledoc """
  Dashboard-side state hub for the Tauri updater integration.

  This GenServer holds the single source of truth for the auto-update UI state
  (phase, versions, changelog, error, timestamps) and broadcasts every
  transition on the `"updates"` topic of `EvoGit.PubSub` (the same PubSub
  `EvoDashWeb.LiveHooks.NodeAware` subscribes to) so LiveViews — including the
  notification dot on the System sidebar item — react without polling.

  All payloads from the JS hook arrive as maps with STRING keys (e.g.
  `%{"status" => "available", "version" => "1.2.3", "body" => "...", ...}`).
  Every public function is non-crashing on malformed input: `nil`, non-maps,
  and unknown statuses normalize to `:error` instead of raising.

  ## State machine

      :idle ──check_started──▶ :checking ──handle_check_result──▶ :up_to_date
          ▲                         │  │  │                       :available
          │                         │  │  └──check_failed──▶      :error
          │                         │  └─not_configured──▶        :error
          │                         └─not_available──▶            :error
          │                         └─"error"/malformed──▶        :error
          │
          :available ──handle_download_result("ready")──▶ :ready
          :available ──request_download?──▶ (auto-download in flight)
          :ready ──applying──▶ :applying ──apply_failed──▶ :error
          :error ──check_started──▶ :checking (retry)

  `reset/0` returns to `:idle` from any phase.

  ## Never-wedge invariants

  1. Every check-result path (`"available"`, `"up_to_date"`, `"not_configured"`,
     `"not_available"`, `"error"`, malformed) and `check_failed/1` terminates
     `:checking` — the UI can never stick on a spinner.
  2. `:error` is always retryable: `check_started/0` and `handle_check_result/1`
     work from `:error`.
  3. `:applying` is reversible via `apply_failed/1` — if the Rust
     `begin_update` invoke fails, the hub returns to `:error` instead of
     wedging.
  4. Malformed payloads (`nil`, non-map, unknown status) never raise; they
     normalize to `:error` with the error `"check_failed"`.

  All mutating API functions are casts whose transition broadcasts inside
  `handle_cast`, so callers are never blocked on the broadcast; `get/0`,
  `phase/0`, and `request_download?/0` are calls.

  ## Platform gating

  The update UI only exists in the Tauri desktop shell: `desktop?/0` checks
  `config :evo_dash, :desktop_release` or the `EVOGIT_DESKTOP=1` env var, and
  `visible?/1` further hides the UI on remote `genesis_remote` nodes and the
  dev server. `notify_only?/0` — recomputed on every `"available"` check
  result — is true for Linux non-AppImage installs (deb/rpm/portable, which
  have no `APPIMAGE` env var): those get package-manager info only, never a
  self-download. macOS, Windows, and AppImage get the full flow. A test seam
  (`config :evo_dash, :update_notify_only_override`) takes precedence over
  platform detection.
  """

  use GenServer

  @doc """
  Starts the hub, registered as `EvoDash.UpdateStatus`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current state map."
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc "Returns the current phase (shorthand for `get().phase`)."
  def phase do
    get().phase
  end

  @doc """
  Marks a check as started: transitions to `:checking` from ANY phase and
  broadcasts. (Used by SystemLive when it triggers a check.)
  """
  def check_started do
    GenServer.cast(__MODULE__, :check_started)
  end

  @doc """
  Applies a check result reported by the JS hook.

  The payload is a map with STRING keys: `"status"`, `"current_version"`,
  `"version"`, `"body"`, `"date"`, `"error"`. Missing keys, unknown statuses,
  and non-map payloads are tolerated and normalize to `:error` (never raise).
  """
  def handle_check_result(payload) do
    GenServer.cast(__MODULE__, {:check_result, payload})
  end

  @doc """
  Applies a download result reported by the JS hook (string-keyed
  `"status"` / `"version"` / `"error"`).
  """
  def handle_download_result(payload) do
    GenServer.cast(__MODULE__, {:download_result, payload})
  end

  @doc """
  Atomic once-per-version auto-download guard.

  Returns `true` only when the phase is `:available`, `notify_only` is false,
  `latest_version` is a non-empty binary, and `download_requested_version`
  differs from `latest_version` — in which case it records the requested
  version so a subsequent call for the same version returns `false`. A new
  version (reported by a fresh `"available"` check) resets the guard and can
  trigger a new auto-download. No broadcast.
  """
  def request_download? do
    GenServer.call(__MODULE__, :request_download)
  end

  @doc "Transitions to `:applying` (from any phase, typically `:ready`); broadcasts."
  def applying do
    GenServer.cast(__MODULE__, :applying)
  end

  @doc """
  Reverts from `:applying` to `:error` with the given message (or
  `"apply_failed"`); broadcasts. The apply step can never wedge.
  """
  def apply_failed(message) do
    GenServer.cast(__MODULE__, {:apply_failed, message})
  end

  @doc """
  Transitions to `:error` with the given message (or `"check_failed"`);
  broadcasts. Never-wedge watchdog path: callable from `:checking` or any
  other phase.
  """
  def check_failed(message) do
    GenServer.cast(__MODULE__, {:check_failed, message})
  end

  @doc """
  Resets to the initial `:idle` state (recomputing `notify_only`); broadcasts.
  Test support + defensive.
  """
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  @doc "True when running inside the Tauri desktop shell."
  def desktop? do
    Application.get_env(:evo_dash, :desktop_release, false) or
      System.get_env("EVOGIT_DESKTOP") == "1"
  end

  @doc """
  Whether the update UI is visible for the given node context. Hidden on
  remote `genesis_remote` nodes and the dev server (non-desktop).
  """
  def visible?(current_node) do
    desktop?() and current_node in [nil, node()]
  end

  @doc """
  Whether the hub is in notify-only mode (Linux non-AppImage installs:
  package-manager info only, no self-download).

  Test seam first — `config :evo_dash, :update_notify_only_override` — then
  platform detection: Linux without the `APPIMAGE` env var is notify-only
  (deb/rpm/portable installs); macOS/Windows/AppImage get the full flow.
  """
  def notify_only? do
    case Application.get_env(:evo_dash, :update_notify_only_override) do
      nil -> :os.type() == {:unix, :linux} and System.get_env("APPIMAGE") == nil
      value -> value
    end
  end

  @impl true
  def init(_opts) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:request_download, _from, state) do
    cond do
      state.phase == :available and
        not state.notify_only and
        is_binary(state.latest_version) and
        state.latest_version != "" and
          state.download_requested_version != state.latest_version ->
        {:reply, true, %{state | download_requested_version: state.latest_version}}

      true ->
        {:reply, false, state}
    end
  end

  @impl true
  def handle_cast(:check_started, state) do
    {:noreply, transition(%{state | phase: :checking})}
  end

  def handle_cast({:check_result, payload}, state) do
    {:noreply, transition(apply_check_result(state, payload))}
  end

  def handle_cast({:download_result, payload}, state) do
    {:noreply, transition(apply_download_result(state, payload))}
  end

  def handle_cast(:applying, state) do
    {:noreply, transition(%{state | phase: :applying})}
  end

  def handle_cast({:apply_failed, message}, state) do
    {:noreply, transition(%{state | phase: :error, error: message || "apply_failed"})}
  end

  def handle_cast({:check_failed, message}, state) do
    {:noreply, transition(%{state | phase: :error, error: message || "check_failed"})}
  end

  def handle_cast(:reset, _state) do
    {:noreply, transition(initial_state())}
  end

  # Broadcasts the new state on the "updates" topic and returns it. Runs inside
  # handle_cast, so the caller of a cast is never blocked on the broadcast.
  defp transition(state) do
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "updates", {:update_status, state})
    state
  end

  defp initial_state do
    %{
      phase: :idle,
      current_version: app_version(),
      latest_version: nil,
      notes: nil,
      date: nil,
      error: nil,
      last_checked_at: nil,
      notify_only: notify_only?(),
      download_requested_version: nil
    }
  end

  # Seeds the current version from the :evo_git app spec so the card shows it
  # even before the first check; nil when the app is not loaded. The Rust
  # command's `current_version` overwrites it after a check.
  defp app_version do
    case Application.spec(:evo_git, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  # Non-map payloads (nil, atoms, lists, ...) are treated as a failed check.
  defp apply_check_result(state, payload) when not is_map(payload) do
    %{state | phase: :error, error: "check_failed"}
  end

  defp apply_check_result(state, payload) do
    case payload["status"] do
      "available" ->
        latest_version = payload["version"]

        %{
          state
          | phase: :available,
            current_version: payload["current_version"],
            latest_version: latest_version,
            notes: payload["body"],
            date: payload["date"],
            error: nil,
            last_checked_at: DateTime.utc_now(),
            notify_only: notify_only?(),
            # A NEW version resets the once-per-version auto-download guard so
            # it can trigger a fresh download.
            download_requested_version:
              if(latest_version != state.latest_version,
                do: nil,
                else: state.download_requested_version
              )
        }

      "up_to_date" ->
        %{
          state
          | phase: :up_to_date,
            current_version: payload["current_version"],
            error: nil,
            last_checked_at: DateTime.utc_now()
        }

      "not_available" ->
        # Sentinel error: latest.json was fetched, but this platform has no
        # auto-update payload (mirrors the not_configured handling). Keep the
        # reported current_version so the card stays populated, and mirror the
        # "available" arm by keeping the feed's version/body/date when present
        # so the card can still show what the latest release is.
        %{
          state
          | phase: :error,
            error: "not_available",
            current_version: payload["current_version"] || state.current_version,
            latest_version: payload["version"] || state.latest_version,
            notes: payload["body"],
            date: payload["date"]
        }

      "not_configured" ->
        # Sentinel error: the UI renders a friendly pre-key message for it.
        %{
          state
          | phase: :error,
            error: "not_configured",
            current_version: payload["current_version"] || state.current_version
        }

      "error" ->
        # Real check failure with a descriptive backend error string. The
        # payload may also carry the feed's version (when the feed was
        # fetchable) — surface it as latest_version so the card can show it.
        %{
          state
          | phase: :error,
            error: payload["error"] || "check_failed",
            current_version: payload["current_version"] || state.current_version,
            latest_version: payload["version"] || state.latest_version
        }

      _ ->
        %{
          state
          | phase: :error,
            error: payload["error"] || "check_failed",
            current_version: payload["current_version"] || state.current_version
        }
    end
  end

  defp apply_download_result(state, payload) when not is_map(payload) do
    %{state | phase: :error, error: "check_failed"}
  end

  defp apply_download_result(state, payload) do
    case payload["status"] do
      "ready" ->
        %{
          state
          | phase: :ready,
            latest_version: payload["version"] || state.latest_version,
            error: nil
        }

      "error" ->
        if state.phase in [:available, :checking, :ready] do
          # Back to :available with the error shown — the Download button can
          # be retried.
          %{state | phase: :available, error: payload["error"]}
        else
          %{state | phase: :error, error: payload["error"]}
        end

      _ ->
        %{state | phase: :error, error: "check_failed"}
    end
  end
end
