defmodule EvoDashWeb.PageControllerTest do
  use EvoDashWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{onboarding_completed: true})
      |> get(~p"/")

    assert html_response(conn, 200) =~ "Genesis"
  end
end
