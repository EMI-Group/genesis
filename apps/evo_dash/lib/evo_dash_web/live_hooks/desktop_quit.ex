defmodule EvoDashWeb.LiveHooks.DesktopQuit do
  @moduledoc """
  On-mount hook for the desktop tray "Quit Genesis" confirm dialog.

  When the user picks "Quit Genesis" from the Tauri desktop shell's tray menu,
  Rust emits a `"quit-requested"` Tauri event. The `DesktopQuit` JS hook
  (`assets/js/app.js`) listens for it and forwards it to the server as a
  `"desktop_quit_requested"` LiveView event. This hook intercepts that event
  (attached hooks run BEFORE the LiveView's own `handle_event/3`) and sets the
  `@desktop_quit_confirm` assign, which the shared app layout
  (`EvoDashWeb.Layouts.app`) renders as a warning confirm dialog — so the dialog
  can appear on ANY page, including Welcome/WelcomeComplete.

  Cancelling pushes `"desktop_quit_cancelled"` (closes the dialog). Confirming
  pushes `"desktop_quit_confirmed"` — the dialog's Quit button is a
  `DesktopQuitConfirm` JS hook that first invokes the Tauri `begin_quit`
  command (the shell sets its intentional-shutdown flag so its watchdog won't
  restart the backend) and then pushes the event. The handler gracefully stops
  the VM the same way the System page's local Stop button does.

  The actual stop is routed through the `:evo_dash, :desktop_quit_stop_fun`
  config seam (`Application.get_env/3`, default `default_stop/0`) so tests can
  inject a fake and the REAL `System.stop/0` never runs in the test VM.

  No remote-node branch: the tray event only comes from the desktop shell,
  whose webview serves the LOCAL dashboard VM. Outside the Tauri shell (normal
  browsers) the JS listener never fires and this hook stays dormant.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  @doc """
  Seeds the `@desktop_quit_confirm` assign (false) and attaches the event
  interceptor so the tray-quit events are handled on every LiveView.
  """
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:desktop_quit_confirm, false)
      |> attach_hook(:desktop_quit, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  @doc false
  # Attached `:handle_event` hook — runs BEFORE the LiveView's own callback.
  # `{:halt, socket}` consumes the event so the page module never sees it.
  def handle_event("desktop_quit_requested", _params, socket) do
    {:halt, assign(socket, :desktop_quit_confirm, true)}
  end

  def handle_event("desktop_quit_cancelled", _params, socket) do
    {:halt, assign(socket, :desktop_quit_confirm, false)}
  end

  def handle_event("desktop_quit_confirmed", _params, socket) do
    stop_fun().()

    {:halt, assign(socket, :desktop_quit_confirm, false)}
  end

  # Any other event flows through to the LiveView untouched.
  def handle_event(_event, _params, socket) do
    {:cont, socket}
  end

  @doc """
  Default graceful stop — mirrors the local branch of SystemLive's
  `confirm_stop`: a short-lived process delays the VM shutdown so the LiveView
  can finish replying (and the browser can close the dialog) before the BEAM
  runtime tears down. `System.stop/0` gracefully shuts down all applications
  and exits the VM — it does NOT affect the host OS.
  """
  def default_stop do
    spawn(fn ->
      Process.sleep(150)
      System.stop()
    end)
  end

  # Testability seam: tests inject a fake stop function via
  # `Application.put_env(:evo_dash, :desktop_quit_stop_fun, ...)` so the REAL
  # `System.stop/0` (which would kill the test VM) is never invoked.
  defp stop_fun do
    Application.get_env(:evo_dash, :desktop_quit_stop_fun, &__MODULE__.default_stop/0)
  end
end
