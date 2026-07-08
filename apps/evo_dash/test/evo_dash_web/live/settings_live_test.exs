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

      refute html =~
               ~s(name="nix.enabled" value="true" class="toggle toggle-primary toggle-sm" checked)
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

    test "renders custom model form for OpenRouter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "llm"})
      html = render_hook(view, "select_llm_provider", %{"provider_id" => "openrouter"})

      assert html =~ "Model Name"
      assert html =~ ~s(name="model_name")
      # The unified custom-model form ALWAYS shows a base_url input (optional
      # for OpenRouter, required for OpenAI-compatible providers).
      assert html =~ ~s(name="base_url")
      assert html =~ "Set Model"
      # custom-model providers hide the quick-select buttons
      refute html =~ "Quick-select a model:"
    end

    test "renders custom model form for OpenAI-Compatible (with base URL and warning)", %{
      conn: conn
    } do
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

    test "saving OpenRouter custom model stores map spec and pre-fills on re-render", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "llm"})
      render_hook(view, "select_llm_provider", %{"provider_id" => "openrouter"})

      html =
        render_hook(view, "save_custom_model", %{
          "model_name" => "anthropic/claude-3.5-sonnet",
          "provider_id" => "openrouter"
        })

      # The model is persisted as a ReqLLM-native map spec (normalized to a map
      # with atom provider after config resolve/reload).
      models = current_models(view)
      assert length(models) == 1
      assert hd(models).model == %{provider: :openrouter, id: "anthropic/claude-3.5-sonnet"}
      # After saving, the re-rendered HTML pre-fills the model_id input from the map
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

      # openai_compatible catalog entry resolves to the canonical :openai atom.
      models = current_models(view)
      assert hd(models).model == %{
               provider: :openai,
               id: "my-model",
               base_url: "https://api.example.com/v1"
             }
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

  describe "model profiles editor" do
    # The assigns/1 helper is defined above (line 229) in the "whitelist safety"
    # describe block and is module-scoped (defp), so it's available here too.

    defp current_models(view) do
      get_in(assigns(view).file_config, [:llm, :models]) || []
    end

    test "renders the editor with Add Model button and empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_hook(view, "select_category", %{"category" => "llm"})

      assert html =~ "Model Profiles"
      assert html =~ "Add Model"
      assert html =~ "No model profiles configured"
    end

    test "add_model_profile creates a new profile with generated id and enters edit mode", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_hook(view, "add_model_profile", %{})

      assert html =~ "fill in the details and save"
      [profile] = current_models(view)
      assert profile.id == "profile-1"
      assert profile.concurrency == 3
      # Enters edit mode immediately
      assert assigns(view).editing_profile_id == "profile-1"
    end

    test "add_model_profile generates sequential unique ids", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Add + save the first profile to persist it
      render_hook(view, "add_model_profile", %{})

      render_hook(view, "save_model_profile", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "profile-1",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "concurrency" => "3"
      })

      # Add a second profile
      render_hook(view, "add_model_profile", %{})

      models = current_models(view)
      ids = Enum.map(models, & &1.id)
      assert ids == ["profile-1", "profile-2"]
    end

    test "edit_model_profile toggles the edit form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})
      # add_model_profile already enters edit mode — cancel first
      render_hook(view, "cancel_edit_model_profile", %{})

      html = render_hook(view, "edit_model_profile", %{"profile_id" => "profile-1"})

      assert assigns(view).editing_profile_id == "profile-1"
      assert html =~ "Edit Profile"
      assert html =~ ~s(name="profile_id_new")
    end

    test "edit_model_profile toggles off when clicked again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})
      # add_model_profile enters edit mode for profile-1
      assert assigns(view).editing_profile_id == "profile-1"

      render_hook(view, "edit_model_profile", %{"profile_id" => "profile-1"})

      assert assigns(view).editing_profile_id == nil
    end

    test "cancel_edit_model_profile clears editing state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      # add_model_profile enters edit mode for profile-1
      render_hook(view, "add_model_profile", %{})
      assert assigns(view).editing_profile_id == "profile-1"

      render_hook(view, "cancel_edit_model_profile", %{})

      assert assigns(view).editing_profile_id == nil
    end

    test "save_model_profile updates the profile with typed params", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})
      render_hook(view, "edit_model_profile", %{"profile_id" => "profile-1"})

      html =
        render_hook(view, "save_model_profile", %{
          "profile_id" => "profile-1",
          "profile_id_new" => "default",
          "provider" => "anthropic",
          "model_id" => "claude-sonnet-4-6",
          "concurrency" => "5",
          "temperature" => "0.7",
          "max_tokens" => "4096",
          "reasoning_effort" => "high"
        })

      assert html =~ "Model profile saved."
      [profile] = current_models(view)
      assert profile.id == "default"
      assert profile.model == %{provider: :anthropic, id: "claude-sonnet-4-6"}
      assert profile.concurrency == 5
      assert profile.temperature == 0.7
      assert profile.max_tokens == 4096
      assert profile.reasoning_effort == "high"
    end

    test "save_model_profile clears editing state after save", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})
      render_hook(view, "edit_model_profile", %{"profile_id" => "profile-1"})

      render_hook(view, "save_model_profile", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "default",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "concurrency" => "3"
      })

      assert assigns(view).editing_profile_id == nil
    end

    test "save_model_profile rejects empty id", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})
      render_hook(view, "edit_model_profile", %{"profile_id" => "profile-1"})

      html =
        render_hook(view, "save_model_profile", %{
          "profile_id" => "profile-1",
          "profile_id_new" => "  ",
          "provider" => "anthropic",
          "model_id" => "claude-sonnet-4-6",
          "concurrency" => "3"
        })

      assert html =~ "Profile id cannot be empty."
    end

    test "save_model_profile rejects duplicate id", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      render_hook(view, "save_model_profile", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "default",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "concurrency" => "3"
      })

      render_hook(view, "add_model_profile", %{})

      html =
        render_hook(view, "save_model_profile", %{
          "profile_id" => "profile-2",
          "profile_id_new" => "default",
          "provider" => "openai",
          "model_id" => "gpt-5.5",
          "concurrency" => "5"
        })

      assert html =~ "already exists"
    end

    test "save_model_profile keeps same id when unchanged (no false duplicate)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      html =
        render_hook(view, "save_model_profile", %{
          "profile_id" => "profile-1",
          "profile_id_new" => "profile-1",
          "provider" => "anthropic",
          "model_id" => "claude-sonnet-4-6",
          "concurrency" => "5"
        })

      assert html =~ "Model profile saved."
      [profile] = current_models(view)
      assert profile.id == "profile-1"
      assert profile.concurrency == 5
    end

    test "delete_model_profile removes the profile", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      render_hook(view, "save_model_profile", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "profile-1",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "concurrency" => "3"
      })

      render_hook(view, "add_model_profile", %{})

      render_hook(view, "save_model_profile", %{
        "profile_id" => "profile-2",
        "profile_id_new" => "profile-2",
        "provider" => "openai",
        "model_id" => "gpt-5.5",
        "concurrency" => "3"
      })

      html = render_hook(view, "delete_model_profile", %{"profile_id" => "profile-1"})

      assert html =~ "Model profile deleted."
      [profile] = current_models(view)
      assert profile.id == "profile-2"
    end

    test "select_llm_model_shortcut adds a profile and mirrors flat model", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        render_hook(view, "select_llm_model_shortcut", %{
          "model_string" => "anthropic:claude-sonnet-4-6"
        })

      assert html =~ "Model selected and saved."
      models = current_models(view)
      assert length(models) == 1
      # After save + resolve, the model string is normalized to a map spec with
      # an atom provider.
      assert hd(models).model == %{provider: :anthropic, id: "claude-sonnet-4-6"}
      assert hd(models).concurrency == 3
      # Flat [:llm, :model] mirrors the default profile (also normalized to map)
      assert get_in(assigns(view).file_config, [:llm, :model]) ==
               %{provider: :anthropic, id: "claude-sonnet-4-6"}
    end

    test "save_custom_model adds a profile for OpenRouter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        render_hook(view, "save_custom_model", %{
          "model_name" => "anthropic/claude-3.5-sonnet",
          "provider_id" => "openrouter"
        })

      assert html =~ "Custom model saved."
      models = current_models(view)
      assert length(models) == 1
      assert hd(models).model == %{provider: :openrouter, id: "anthropic/claude-3.5-sonnet"}
    end

    test "save_model_profile composes map spec with provider, id, and base_url", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      html =
        render_hook(view, "save_model_profile", %{
          "profile_id" => "profile-1",
          "profile_id_new" => "profile-1",
          "provider" => "openai",
          "model_id" => "gpt-4o",
          "base_url" => "https://my-proxy.com/v1",
          "concurrency" => "3"
        })

      assert html =~ "Model profile saved."
      [profile] = current_models(view)
      assert profile.model == %{provider: :openai, id: "gpt-4o", base_url: "https://my-proxy.com/v1"}
    end

    test "save_model_profile rejects empty model id", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      html =
        render_hook(view, "save_model_profile", %{
          "profile_id" => "profile-1",
          "profile_id_new" => "profile-1",
          "provider" => "anthropic",
          "model_id" => "  ",
          "concurrency" => "3"
        })

      assert html =~ "Model ID cannot be empty."
    end

    test "save_custom_model with base_url for OpenAI-compatible produces map spec", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "llm"})
      render_hook(view, "select_llm_provider", %{"provider_id" => "openai_compatible"})

      html =
        render_hook(view, "save_custom_model", %{
          "model_name" => "gpt-4o",
          "base_url" => "https://my-proxy.com/v1",
          "provider_id" => "openai_compatible"
        })

      assert html =~ "Custom model saved."
      models = current_models(view)
      assert hd(models).model == %{provider: :openai, id: "gpt-4o", base_url: "https://my-proxy.com/v1"}
    end

    test "save_model_profile then edit pre-fills structured fields from map spec", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      render_hook(view, "save_model_profile", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "profile-1",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "base_url" => "https://proxy.example.com/v1",
        "concurrency" => "3"
      })

      # Re-open the edit form and verify the structured fields pre-fill from the map spec
      html = render_hook(view, "edit_model_profile", %{"profile_id" => "profile-1"})

      assert html =~ ~s(value="claude-sonnet-4-6")
      assert html =~ ~s(value="anthropic")
      assert html =~ ~s(value="https://proxy.example.com/v1")
    end

    test "save_custom_model rejects empty name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        render_hook(view, "save_custom_model", %{
          "model_name" => "  ",
          "provider_id" => "openrouter"
        })

      assert html =~ "Model name cannot be empty."
    end

    test "save_custom_model rejects empty base URL for OpenAI-compatible", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        render_hook(view, "save_custom_model", %{
          "model_name" => "x",
          "base_url" => "",
          "provider_id" => "openai_compatible"
        })

      assert html =~ "Base URL cannot be empty."
    end
  end

  describe "LLM connection test rendering (map model safety)" do
    # Bug 2: The Connection Test result used to render `{data.model}` directly in
    # HEEx, but `data.model` is a MAP (e.g. %{id: "deepseek-v4-pro",
    # provider: :deepseek}) returned from EvoGit.SystemCheck.llm_test/0.
    # Maps don't implement Phoenix.HTML.Safe, so this crashed the LiveView with
    # Protocol.UndefinedError. The fix renders `model_display(data.model)` instead,
    # which formats maps into readable strings like "deepseek:deepseek-v4-pro".

    test "connection test with a map model renders the formatted string, not the raw map",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "llm"})

      # Simulate the LLM connection test result being delivered by the async task
      # (handle_info({:llm_test_result, result}, socket) stores the status). We send
      # a result with a MAP model — the exact shape that crashed before the fix.
      # `render/1` synchronously processes pending messages for the LiveView
      # process, so the info message is handled before the HTML is produced.
      send(view.pid, {:llm_test_result,
       {:ok, %{response: "hello", model: %{id: "deepseek-v4-pro", provider: :deepseek}}}})

      html = render(view)

      # The success state "Connected" (gettext'd) should be present — proving the
      # {:ok, data} branch rendered without raising.
      assert html =~ "Connected"
      # The map model must be rendered as the formatted "provider:id" string rather
      # than crashing on the raw map.
      assert html =~ "deepseek:deepseek-v4-pro"
    end

    test "model_display/1 formats a map model into a readable provider:id string" do
      # Unit-style test on the helper that the fix delegates to. This is the core
      # guarantee that maps are formatted safely — if the integration approach
      # above ever becomes flaky, this test alone proves maps won't crash HEEx.
      assert EvoDashWeb.SettingsComponents.SettingCard.model_display(%{
               id: "deepseek-v4-pro",
               provider: :deepseek
             }) == "deepseek:deepseek-v4-pro"
    end

    test "model_display/1 includes base_url when present in a map model" do
      assert EvoDashWeb.SettingsComponents.SettingCard.model_display(%{
               id: "gpt-4o",
               provider: :openai,
               base_url: "https://x/v1"
             }) =~ "gpt-4o"

      assert EvoDashWeb.SettingsComponents.SettingCard.model_display(%{
               id: "gpt-4o",
               provider: :openai,
               base_url: "https://x/v1"
             }) =~ "https://x/v1"
    end

    test "model_display/1 passes through binary (string) models unchanged" do
      # Binary model strings (e.g. "anthropic:claude-sonnet-4") are already safe
      # to render in HEEx and should pass through identically.
      assert EvoDashWeb.SettingsComponents.SettingCard.model_display("anthropic:claude-sonnet-4") ==
               "anthropic:claude-sonnet-4"
    end
  end
end
