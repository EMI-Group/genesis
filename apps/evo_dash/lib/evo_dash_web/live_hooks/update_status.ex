defmodule EvoDashWeb.LiveHooks.UpdateStatus do
  @moduledoc """
  Global on-mount hook bridging the Tauri updater to the dashboard.

  The `UpdateStatus` JS hook (`assets/js/app.js`) runs the Tauri `check_update`
  / `download_update` / `begin_update` commands — on a startup check (30s after
  mount), a periodic check (every 6h), and whenever the server pushes
  `"update_check_requested"` / `"update_download_requested"` /
  `"update_apply_requested"` (dispatched by LiveSocket as `phx:` CustomEvents on
  `window`; workstream C's SystemLive card pushes them). The JS results come
  back as LiveView events (`"update_check_result"`, `"update_download_result"`,
  `"update_apply_confirmed"`, `"update_apply_failed"`), which THIS hook
  intercepts on EVERY page — attached hooks run before the LiveView's own
  `handle_event/3` — so no page ever sees an unhandled-pushEvent warning, and
  the shared `EvoDash.UpdateStatus` hub stays the single source of truth.

  The `:handle_info` interceptor keeps the `@update_status` assign live from the
  hub's `"updates"` topic broadcasts (the hub broadcasts every transition), and
  the shared app layout (`EvoDashWeb.Layouts.app`) renders the notification dot
  on the System sidebar item from it.

  The seed heuristic hides the dot while viewing a remote `genesis_remote` node:
  `@update_status` is only seeded from the hub when `params["node"] == nil`
  (remote-viewing heuristic). Outside the Tauri shell (normal browsers) the
  assign is always `nil`, so every page template stays safe.

  The apply step's backend stop is routed through the `:evo_dash,
  :desktop_quit_stop_fun` config seam (shared with `DesktopQuit`, default
  `EvoDashWeb.LiveHooks.DesktopQuit.default_stop/0` — a delayed `System.stop/0`,
  NEVER `bin/genesis_desktop stop`, which is broken under
  `RELEASE_DISTRIBUTION=none`) so tests can inject a fake and the REAL
  `System.stop/0` never runs in the test VM.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3]

  alias EvoDash.UpdateStatus

  @doc """
  Seeds the `@update_status` assign and attaches the update-status
  interceptors (PubSub `:handle_info` + event `:handle_event`) when running in
  the Tauri desktop shell. The interceptors are attached on EVERY page, so the
  JS hook's pushed events are always consumed.
  """
  def on_mount(:default, params, _session, socket) do
    desktop? = UpdateStatus.desktop?()

    socket =
      socket
      |> assign(:update_status, initial_assign(desktop?, params["node"] != nil))
      |> maybe_attach(desktop?)

    {:cont, socket}
  end

  @doc false
  # Seed decision for @update_status, extracted as a pure helper for unit
  # testing: the full hub state map on desktop+local views, nil otherwise
  # (non-desktop, or remote-node viewing).
  def initial_assign(desktop?, remote_view?)
      when is_boolean(desktop?) and is_boolean(remote_view?) do
    if desktop? and not remote_view?, do: UpdateStatus.get(), else: nil
  end

  @doc false
  # Applies a check result to the hub and reports whether an auto-download
  # should be requested (the hub's atomic once-per-version guard decides).
  def handle_check_result(payload) do
    UpdateStatus.handle_check_result(payload)

    if UpdateStatus.request_download?(), do: :request_download, else: :no_download
  end

  @doc false
  # Applies a download result to the hub.
  def handle_download_result(payload) do
    UpdateStatus.handle_download_result(payload)
    :ok
  end

  @doc false
  # Apply confirmed: gracefully stop the backend (through the testable seam).
  def handle_apply_confirmed do
    stop_backend()
    :ok
  end

  @doc false
  # Apply failed: revert the hub from :applying to :error with the payload's
  # message (never wedges). Non-map payloads default to "apply_failed".
  def handle_apply_failed(payload) when is_map(payload) do
    UpdateStatus.apply_failed(payload["error"])
    :ok
  end

  def handle_apply_failed(_payload) do
    UpdateStatus.apply_failed("apply_failed")
    :ok
  end

  @doc false
  # Stops the backend via the `:evo_dash, :desktop_quit_stop_fun` config seam
  # (shared with DesktopQuit; default is DesktopQuit's delayed System.stop/0).
  def stop_backend do
    Application.get_env(
      :evo_dash,
      :desktop_quit_stop_fun,
      &EvoDashWeb.LiveHooks.DesktopQuit.default_stop/0
    ).()

    :ok
  end

  # Attached `:handle_info` hook — keeps @update_status in sync with hub
  # broadcasts. `{:halt, socket}` consumes the matching message.
  def handle_info({:update_status, state}, socket) do
    {:halt, assign(socket, :update_status, state)}
  end

  # Any other message flows through to the LiveView untouched.
  def handle_info(_message, socket) do
    {:cont, socket}
  end

  # Attached `:handle_event` hook — runs BEFORE the LiveView's own callback.
  def handle_event("update_check_result", payload, socket) do
    case handle_check_result(payload) do
      :request_download -> {:halt, push_event(socket, "update_download_requested", %{})}
      :no_download -> {:halt, socket}
    end
  end

  def handle_event("update_download_result", payload, socket) do
    handle_download_result(payload)

    {:halt, socket}
  end

  def handle_event("update_apply_confirmed", _payload, socket) do
    handle_apply_confirmed()

    {:halt, socket}
  end

  def handle_event("update_apply_failed", payload, socket) do
    handle_apply_failed(payload)

    {:halt, socket}
  end

  # Any other event flows through to the LiveView untouched.
  def handle_event(_event, _payload, socket) do
    {:cont, socket}
  end

  # Subscribes to the hub's "updates" topic and attaches both interceptors on
  # the connected mount only (dead-render skip, mirroring NodeAware). When not
  # in desktop mode this is a no-op and the hook stays dormant.
  defp maybe_attach(socket, true) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "updates")

      socket
      |> attach_hook(:update_status, :handle_info, &handle_info/2)
      |> attach_hook(:update_status, :handle_event, &handle_event/3)
    else
      socket
    end
  end

  defp maybe_attach(socket, false), do: socket
end
