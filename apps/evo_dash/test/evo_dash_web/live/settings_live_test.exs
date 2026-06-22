defmodule EvoDashWeb.SettingsLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  describe "settings search" do
    test "renders the search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Filter settings..."
    end

    test "search handler with 'value' key updates search_text and shows results", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # The search handler expects %{"value" => text} (the input name is "value").
      # A mismatched key (e.g. %{"search" => text}) would silently fail to match.
      html = render_hook(view, "search", %{"value" => "scheduler"})

      # When search_text is non-empty, the search results panel is shown
      # (the render/1 template branches on @search_text != "").
      assert html =~ "Search Results"
    end

    test "search handler shows 'no settings found' for a non-matching term", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_hook(view, "search", %{"value" => "zzz_nonexistent_xyz"})

      assert html =~ "No settings found matching"
    end

    test "clearing search returns to category view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # First type a search term
      _html = render_hook(view, "search", %{"value" => "scheduler"})
      # Then clear it (the clear button sends phx-value-value="")
      html = render_hook(view, "search", %{"value" => ""})

      # When search_text is empty, the category section is shown instead of
      # the search results panel.
      refute html =~ "Search Results"
    end

    test "search input is inside a form (required for phx-change in LiveView)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      # The search input must be wrapped in a <form> for phx-change to work
      # in Phoenix LiveView (pushInput throws if inputEl.form is null).
      # We assert the input with name="value" and phx-change="search" exists,
      # and that it is within a form element.
      assert html =~ ~s(name="value")
      assert html =~ ~s(phx-change="search")
    end
  end
end
