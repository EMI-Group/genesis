defmodule EvoDashWeb.LiveHooks.SetLocale do
  @moduledoc """
  On-mount hook that restores the Gettext locale in LiveView processes.

  The Locale plug sets Gettext.put_locale during HTTP requests, but LiveView
  runs in a separate process where the process dictionary is empty. This hook
  reads the locale from the session (set by the Locale plug) and restores it
  on every LiveView mount.
  """

  import Phoenix.LiveView

  def on_mount(:default, _params, session, socket) do
    locale = session["locale"] || "en"
    Gettext.put_locale(EvoDashWeb.Gettext, locale)
    {:cont, socket}
  end
end
