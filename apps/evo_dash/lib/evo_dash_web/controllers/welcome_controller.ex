defmodule EvoDashWeb.WelcomeController do
  use EvoDashWeb, :controller

  def complete(conn, _params) do
    # Preserve the query string (e.g. ?art=constructivism style previews)
    # across the onboarding redirect.
    target = if conn.query_string == "", do: "/", else: "/?" <> conn.query_string

    conn
    |> put_session(:onboarding_completed, true)
    |> redirect(to: target)
  end
end
