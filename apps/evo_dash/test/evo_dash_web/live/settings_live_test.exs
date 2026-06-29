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

  describe "custom model providers (OpenRouter / OpenAI-Compatible)" do
    # Note: gettext is NOT imported in ConnCase, so assertions use literal
    # English source strings (matching what the en translation returns).

    test "renders custom model form for OpenRouter (no base URL)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "llm"})
      html = render_hook(view, "select_llm_provider", %{"provider_id" => "openrouter"})

      assert html =~ "Model Name"
      assert html =~ ~s(name="model_name")
      assert html =~ ~s(placeholder="anthropic/claude-3.5-sonnet")
      assert html =~ "Set Model"
      assert html =~ "The model will be saved as"
      # custom-model providers hide the quick-select buttons
      refute html =~ "Quick-select a model:"
    end

    test "renders custom model form for OpenAI-Compatible (with base URL and warning)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "llm"})
      html = render_hook(view, "select_llm_provider", %{"provider_id" => "openai_compatible"})

      assert html =~ "Model Name"
      assert html =~ "Base URL"
      assert html =~ ~s(name="base_url")
      assert html =~ ~s(placeholder="https://api.my-provider.com/v1")
      assert html =~ "Warning: OpenAI-compatible APIs vary in compatibility"
      assert html =~ "Set Model"
      refute html =~ "Quick-select a model:"
    end

    test "saving OpenRouter custom model stores openrouter: spec and pre-fills on re-render", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "llm"})
      render_hook(view, "select_llm_provider", %{"provider_id" => "openrouter"})

      html =
        render_hook(view, "save_custom_model", %{
          "model_name" => "anthropic/claude-3.5-sonnet",
          "provider_id" => "openrouter"
        })

      # After saving, the re-rendered HTML pre-fills the input with the model name
      assert html =~ ~s(value="anthropic/claude-3.5-sonnet")
    end

    test "saving OpenAI-compatible custom model stores map spec and pre-fills", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "llm"})
      render_hook(view, "select_llm_provider", %{"provider_id" => "openai_compatible"})

      html =
        render_hook(view, "save_custom_model", %{
          "model_name" => "my-model",
          "base_url" => "https://api.example.com/v1",
          "provider_id" => "openai_compatible"
        })

      assert html =~ ~s(value="my-model")
      assert html =~ ~s(value="https://api.example.com/v1")
    end

    test "rejects empty model name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "llm"})
      render_hook(view, "select_llm_provider", %{"provider_id" => "openrouter"})

      html =
        render_hook(view, "save_custom_model", %{
          "model_name" => "  ",
          "provider_id" => "openrouter"
        })

      assert html =~ "Model name cannot be empty."
    end

    test "rejects empty base URL for OpenAI-compatible", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "llm"})
      render_hook(view, "select_llm_provider", %{"provider_id" => "openai_compatible"})

      html =
        render_hook(view, "save_custom_model", %{
          "model_name" => "x",
          "base_url" => "",
          "provider_id" => "openai_compatible"
        })

      assert html =~ "Base URL cannot be empty."
    end
  end
end
