defmodule EvoDashWeb.RedirectController do
  use EvoDashWeb, :controller

  @moduledoc """
  Legacy route aliases.

  The Genesis Assistant page moved from `/help` to `/assistant`; `/help` is kept
  as a permanent-feeling alias that 302-redirects to the canonical route while
  PRESERVING the raw query string, so bookmarks such as `/help?session=7` or
  `/help?node=abc` keep working (`/assistant?session=7`, `/assistant?node=abc`).
  """

  @doc """
  Redirects the legacy `/help` route to `/assistant`, keeping the query string.
  """
  @spec assistant(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def assistant(conn, _params) do
    redirect(conn, to: assistant_path(conn.query_string))
  end

  defp assistant_path(""), do: "/assistant"
  defp assistant_path(query_string), do: "/assistant?" <> query_string
end
