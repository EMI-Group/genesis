defmodule EvoDashWeb.WelcomeController do
  use EvoDashWeb, :controller

  def complete(conn, _params) do
    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end

    conn
    |> redirect(to: "/")
  end
end
