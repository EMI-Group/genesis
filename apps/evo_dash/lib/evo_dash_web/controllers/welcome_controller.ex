defmodule EvoDashWeb.WelcomeController do
  use EvoDashWeb, :controller

  def complete(conn, _params) do
    conn
    |> put_session(:onboarding_completed, true)
    |> redirect(to: "/")
  end
end
