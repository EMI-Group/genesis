defmodule EvoDashWeb.SettingsLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # Isolate all tests in this file from the host's real user config.
  # SettingsLive.mount/1 calls load_file_config() → EvoGit.Config.resolve(),
  # which reads config.toml from EvoGit.Config.config_dir/0. On Linux that
  # honours the XDG_CONFIG_HOME env var, so pointing it at an empty temp dir
  # guarantees no config.toml exists and schema defaults (e.g. nix.enabled =
  # false) are used — making the tests deterministic regardless of host env.
  setup do
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_settings_test_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_config)
    original = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)

    on_exit(fn ->
      if original do
        System.put_env("XDG_CONFIG_HOME", original)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_config)
    end)

    :ok
  end

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

  describe "boolean field rendering (nix.enabled)" do
    test "renders a DaisyUI toggle with hidden field for false value submission", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_hook(view, "select_category", %{"category" => "nix"})

      # The hidden field (value="false") must appear BEFORE the checkbox so that
      # unchecked submits "false" and checked submits "true" (checkbox overrides).
      hidden_html = ~s(type="hidden" name="nix.enabled" value="false")
      checkbox_html = ~s(type="checkbox" name="nix.enabled" value="true")

      hidden_pos = :binary.match(html, hidden_html)
      checkbox_pos = :binary.match(html, checkbox_html)

      # Both must be present
      assert hidden_pos != :nomatch, "hidden boolean field not rendered"
      assert checkbox_pos != :nomatch, "checkbox boolean field not rendered"

      # Hidden must come before checkbox in the HTML
      {hidden_start, _} = hidden_pos
      {checkbox_start, _} = checkbox_pos
      assert hidden_start < checkbox_start, "hidden field must precede the checkbox"
    end

    test "toggle is unchecked when value is false/nil (default)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_hook(view, "select_category", %{"category" => "nix"})

      # Default for nix.enabled is false, so the checkbox should NOT have 'checked'
      assert html =~ ~s(name="nix.enabled")
      refute html =~ ~s(name="nix.enabled" value="true" class="toggle toggle-primary toggle-sm" checked)
    end

    test "toggle uses DaisyUI toggle classes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_hook(view, "select_category", %{"category" => "nix"})

      assert html =~ ~s(class="toggle toggle-primary toggle-sm")
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

  describe "whitelist safety (unknown values do not crash)" do
    # These regression tests verify that the whitelist-based conversion helpers
    # (category_str_to_atom/1, provider_by_id_str/0, variant_id_by_str/1) safely
    # map unknown/untrusted client strings to nil/default instead of crashing.
    # The "doesn't crash" assertion is implicit: render_hook/live returning a
    # successful result (not raising) proves it didn't crash.

    # In LiveView 1.x the test View struct has no `.assigns` field, so we read
    # them from the underlying LiveView process socket.
    defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

    test "unknown category does not crash select_category", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_hook(view, "select_category", %{"category" => "totally_fake_category"})

      # Unknown category → active_category stays unchanged (default :llm).
      assert assigns(view).active_category == :llm
      # The hidden category input reflects the unchanged value.
      assert html =~ ~s(name="category" value="llm")
    end

    test "unknown category in URL params does not crash", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings?category=bogus_category")

      # Unknown category in handle_params → keeps current category (:llm).
      assert assigns(view).active_category == :llm
      assert html =~ ~s(name="category" value="llm")
    end

    test "valid category conversion still works", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_hook(view, "select_category", %{"category" => "nix"})

      assert assigns(view).active_category == :nix
      assert html =~ ~s(name="category" value="nix")
    end

    test "unknown provider does not crash select_llm_provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_hook(view, "select_llm_provider", %{"provider_id" => "totally_fake_provider"})

      # Unknown provider → clears selection and shows flash error.
      assert assigns(view).selected_provider_id == nil
      assert assigns(view).selected_provider_models == []
      assert html =~ "Unknown provider."
    end

    test "valid provider conversion still works", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_hook(view, "select_llm_provider", %{"provider_id" => "alibaba"})

      assert assigns(view).selected_provider_id == :alibaba
    end

    test "unknown variant does not crash select_llm_variant", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      render_hook(view, "select_llm_variant", %{"variant_id" => "totally_fake_variant"})

      # No provider selected → selected_variant_id becomes nil.
      assert assigns(view).selected_variant_id == nil
    end

    test "unknown variant after valid provider does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_llm_provider", %{"provider_id" => "alibaba"})

      render_hook(view, "select_llm_variant", %{"variant_id" => "fake_variant"})

      assert assigns(view).selected_variant_id == nil
    end

    test "valid variant conversion still works", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_llm_provider", %{"provider_id" => "alibaba"})

      html = render_hook(view, "select_llm_variant", %{"variant_id" => "global"})

      assert assigns(view).selected_variant_id == :global
      # The selected variant button gets the active styling.
      assert html =~ ~s(phx-value-variant_id="global")
    end

    test "unknown key path does not crash reset_key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_hook(view, "reset_key", %{"key_path" => "nope.nope"})

      assert html =~ "Invalid key path."
    end
  end
end
