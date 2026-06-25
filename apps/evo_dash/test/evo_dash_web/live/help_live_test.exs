defmodule EvoDashWeb.HelpLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  describe "help page" do
    test "renders the help page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help")

      assert html =~ "Help"
    end

    test "shows configuration guidance section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help")

      assert html =~ "Example Configuration"
      assert html =~ "config.toml"
    end

    test "shows CLI usage examples", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help")

      assert html =~ "Example Usage"
      assert html =~ "genesis"
      assert html =~ "evolve"
    end

    test "shows FAQ section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help")

      assert html =~ "Frequently Asked Questions"
      assert html =~ "How do I set my API key?"
    end

    test "shows credentials reference", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/help")

      assert html =~ "Credentials Reference"
      assert html =~ "credentials.toml"
    end
  end
end
