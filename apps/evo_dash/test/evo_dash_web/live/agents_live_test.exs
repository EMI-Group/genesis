defmodule EvoDashWeb.AgentsLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  describe "agents page" do
    test "renders the agents page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "Agent Tree"
    end

    test "shows empty state when no agents are running", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "No agents currently registered"
    end
  end
end
