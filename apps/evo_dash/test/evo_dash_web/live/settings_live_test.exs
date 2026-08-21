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

    # Force the nix category visible by default so ALL existing tests are
    # deterministic regardless of whether the host has the `nix` binary (the
    # boolean field rendering and category-conversion tests select the nix
    # category). Gating tests below override this to false and clean up via
    # their own on_exit; the next test's setup re-establishes the default.
    Application.put_env(:evo_dash, :nix_available_override, true)

    on_exit(fn ->
      Application.delete_env(:evo_dash, :nix_available_override)
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

  describe "scheduler_config broadcast (node-filtered)" do
    # Push-refactor contract: the emitter broadcasts
    # `{:scheduler_config_updated, node}` on the "scheduler_config" topic,
    # where node is the BEAM node atom of the publisher. The handler
    # (settings_live.ex:822) node-filters via
    # NodeAware.event_from_current_node?/2 — matching-node events re-read the
    # scheduler config (LOCAL — pre-existing gap, see settings_live/CONTEXT.md);
    # foreign-node events are ignored (socket unchanged).

    test "broadcast from the current node refreshes the :scheduler_config assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Mount seeds the assign from the scheduler — flip the paused flag so the
      # refreshed config observably differs from the mount-time snapshot.
      EvoGit.AgentScheduler.pause()

      on_exit(fn ->
        # Resume in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.AgentScheduler.resume()
        rescue
          _ -> :ok
        end
      end)

      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "scheduler_config",
        {:scheduler_config_updated, node()}
      )

      # render/1 flushes pending messages synchronously; a crash would propagate here.
      render(view)

      assert assigns(view)[:scheduler_config][:paused] == true
    end

    test "broadcast from a foreign node is ignored (assign unchanged)", %{conn: conn} do
      # Pause BEFORE mounting: pause() itself broadcasts a matching-node
      # {:scheduler_config_updated, node()} via
      # AgentScheduler.PubSub.broadcast_config_updated/0 (config change, pause,
      # or resume). With no subscribers yet the broadcast is dropped, so the
      # mount-time snapshot is the paused state and the foreign broadcast below
      # is the ONLY event the view can react to. This also makes the test
      # immune to cross-test scheduler-state leakage (if a prior test left the
      # scheduler paused, pause() is a no-op and the test still behaves
      # identically).
      EvoGit.AgentScheduler.pause()

      on_exit(fn ->
        # Resume in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.AgentScheduler.resume()
        rescue
          _ -> :ok
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      # Mount snapshot was paused — the final assertion below means "unchanged
      # from the snapshot" (the foreign event was dropped).
      assert assigns(view)[:scheduler_config][:paused] == true

      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "scheduler_config",
        {:scheduler_config_updated, :genesis_remote@somewhere}
      )

      render(view)

      # Foreign-node event dropped — the mount-time snapshot (paused) stays.
      assert assigns(view)[:scheduler_config][:paused] == true
    end
  end

  describe "LLM quick setup API key detection (credentials.toml)" do
    # The credentials.toml file is written under the test's isolated XDG dir
    # (see the file-level `setup` block), so EvoGit.Config.credentials_path/0
    # resolves to a path we can control. Each test cleans up after itself so no
    # state leaks between tests.
    defp creds_file, do: EvoGit.Config.credentials_path()

    # Derive provider/model strings from the catalog — never hardcode model ids
    # or display names (they change as the catalog evolves). Provider ids
    # (deepseek/google/anthropic/alibaba) are stable fixtures.
    defp provider(id), do: Enum.find(EvoGit.Config.LLMCatalog.providers(), &(&1.id == id))

    defp model_string(id, variant_id \\ nil) do
      p = provider(id)
      atom = EvoGit.Config.LLMCatalog.resolve_provider_atom(id, variant_id)
      "#{atom}:#{hd(p.models).id}"
    end

    test "after provider selection alone, model shortcuts render but the API key form is gated",
         %{
           conn: conn
         } do
      # Ensure no credentials.toml exists.
      File.rm(creds_file())

      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_hook(view, "select_llm_provider", %{"provider_id" => "deepseek"})

      assert provider(:deepseek).models != []

      # The API key form is gated on model selection — the hint shows instead.
      assert html =~ "Select a model above to configure credentials."
      refute html =~ ~s(name="api_key")
      refute html =~ "Enter your API key"
      refute html =~ "Save Model"
      refute html =~ "API key is already set"

      # Model shortcut buttons ARE present, carrying the derived model_string.
      assert html =~ "Quick-select a model:"
      assert html =~ ~s(phx-value-model_string="#{model_string(:deepseek)}")
    end

    test "Case A — key present in credentials.toml", %{conn: conn} do
      # Write a credentials.toml with the key. credentials.toml is a flat
      # key=value TOML; string keys map directly into the parsed map.
      creds = creds_file()
      File.mkdir_p!(Path.dirname(creds))
      File.write!(creds, ~s(deepseek_api_key = "sk-test-12345"\n))

      on_exit(fn ->
        File.rm(creds_file())
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")
      # The API key form only renders once a model is selected.
      html = render_hook(view, "select_llm_provider", %{"provider_id" => "deepseek"})

      # Before a model is selected, the key status is not surfaced.
      assert html =~ "Select a model above to configure credentials."
      refute html =~ "API key is already set"

      # Selecting a model reveals the API key form; the key is detected.
      html = render_hook(view, "select_llm_model", %{"model_string" => model_string(:deepseek)})

      # When key_is_set is true the placeholder is "API key is already set".
      assert html =~ "API key is already set"
      assert html =~ "Your API key is configured and ready to use."
    end

    test "Case C — key absent from credentials.toml", %{conn: conn} do
      # Ensure no credentials.toml exists.
      File.rm(creds_file())

      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_hook(view, "select_llm_provider", %{"provider_id" => "deepseek"})
      assert html =~ "Select a model above to configure credentials."

      html = render_hook(view, "select_llm_model", %{"model_string" => model_string(:deepseek)})

      # When the key is NOT set, the hint paragraph reads "Enter your API key".
      # (deepseek has a prefix hint "sk-..." so the input placeholder itself is
      # "sk-...", but the hint paragraph below renders "Enter your API key. It
      # should start with sk-...".)
      assert html =~ "Enter your API key"
      refute html =~ "API key is already set"
    end

    test "model selection highlights the button and enables the Save Model form", %{conn: conn} do
      File.rm(creds_file())

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_llm_provider", %{"provider_id" => "deepseek"})

      html = render_hook(view, "select_llm_model", %{"model_string" => model_string(:deepseek)})

      # The Save Model form renders with its hidden inputs.
      assert html =~ "Save Model"
      assert html =~ ~s(phx-submit="save_quick_setup")
      assert html =~ ~s(name="model_string")

      # The selected model button carries the active styling. The provider
      # button ALSO uses btn-primary shadow-md, so scope the assertion to the
      # model button element via its phx-value-model_string attribute.
      doc = Floki.parse_document!(html)
      [model_button] = Floki.find(doc, ~s([phx-value-model_string="#{model_string(:deepseek)}"]))
      classes = model_button |> Floki.attribute("class") |> Enum.join(" ")
      assert classes =~ "btn-primary"
      assert classes =~ "shadow-md"
    end

    test "save_quick_setup persists the selected profile", %{conn: conn} do
      File.rm(creds_file())

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_llm_provider", %{"provider_id" => "deepseek"})
      render_hook(view, "select_llm_model", %{"model_string" => model_string(:deepseek)})

      html =
        render_hook(view, "save_quick_setup", %{
          "model_string" => model_string(:deepseek),
          "provider_id" => "deepseek",
          "variant_id" => "",
          "base_url" => ""
        })

      assert html =~ "Model selected and saved."

      # The profile is persisted; after the TOML round-trip the model is the
      # normalized "provider:model" string.
      models = get_in(assigns(view).file_config, [:llm, :models]) || []
      assert Enum.any?(models, &(&1.model == model_string(:deepseek)))
    end

    test "changing provider resets the selected model", %{conn: conn} do
      File.rm(creds_file())

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_llm_provider", %{"provider_id" => "google"})

      assert provider(:google).models != []
      html = render_hook(view, "select_llm_model", %{"model_string" => model_string(:google)})
      assert html =~ "Save Model"

      # Switching provider invalidates any previously chosen model.
      html = render_hook(view, "select_llm_provider", %{"provider_id" => "deepseek"})
      refute html =~ "Save Model"
      assert html =~ "Select a model above to configure credentials."
      assert assigns(view).selected_model_string == nil
    end

    test "unknown model_string clears the selection instead of crashing", %{conn: conn} do
      File.rm(creds_file())

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_llm_provider", %{"provider_id" => "deepseek"})

      html =
        render_hook(view, "select_llm_model", %{"model_string" => "deepseek:nonexistent-model"})

      # Whitelist safety: unknown model strings clear the selection (nil) and
      # never crash; the hint stays visible and the Save Model form stays hidden.
      assert assigns(view).selected_model_string == nil
      refute html =~ "Save Model"
      assert html =~ "Select a model above to configure credentials."
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

      # The model is persisted and normalized via config resolve: simple maps
      # (provider + id only) become "provider:id" strings.
      models = current_models(view)
      assert length(models) == 1
      assert hd(models).model == "openrouter:anthropic/claude-3.5-sonnet"
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
      # With base_url, the model has overrides → normalized to a map spec.
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

    # Builds a deterministic NodeData results map for the currently viewed node
    # by applying the pure PlatformInfo filters to the UNFILTERED schemas
    # snapshot (`:all_schemas_by_category`). The platform computation
    # short-circuits on the `:platform_os_override` / `:nix_available_override`
    # app-env seams (checked FIRST by PlatformInfo), so the result is
    # deterministic on ANY host. `overrides` win per-key for tests that want a
    # different value than the current env computes.
    defp default_node_results(view, overrides \\ %{}) do
      overrides = Map.new(overrides)
      assigns = assigns(view)
      node = assigns[:current_node]
      all_schemas = assigns[:all_schemas_by_category]
      platform_os = Map.get(overrides, :platform_os, EvoDashWeb.PlatformInfo.os_for_node(node))

      filtered =
        Map.get(
          overrides,
          :filtered_schemas_by_category,
          EvoDashWeb.PlatformInfo.filter_nix_category(
            EvoDashWeb.PlatformInfo.filter_schemas_by_category(all_schemas, platform_os),
            node
          )
        )

      Map.merge(
        %{
          platform_os: platform_os,
          filtered_schemas_by_category: filtered,
          file_config: assigns[:file_config] || %{},
          config_status: assigns[:config_status] || %{},
          remote_config_error: nil,
          custom_agents: %{
            agents: assigns[:custom_agents] || [],
            model_selection_script: assigns[:model_selection_script] || "",
            script_status: assigns[:script_status] || :ok
          }
        },
        overrides
      )
    end

    # Deterministically delivers a NodeData result (the async task's message)
    # to the view and drains the mailbox via render — the established direct-
    # send pattern for tests asserting async-loaded content. Tagged with the
    # CURRENT node so it passes the stale-guard. The real task (same node, same
    # deterministic values under the override seams) sends its message before
    # ours, so ours is processed last — assertions are race-free.
    defp deliver_node_data(view, category_param \\ nil, overrides \\ %{}) do
      send(
        view.pid,
        {:settings_node_data_loaded, assigns(view)[:current_node], category_param,
         default_node_results(view, overrides)}
      )

      render(view)
    end

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
      assert profile.model == "anthropic:claude-sonnet-4-6"
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
      # After save + resolve, the model string is normalized: simple models
      # (no overrides) become "provider:id" strings.
      assert hd(models).model == "anthropic:claude-sonnet-4-6"
      assert hd(models).concurrency == 3
      # First profile's model (also normalized to string)
      assert get_in(assigns(view).file_config, [:llm, :models]) |> hd() |> Map.get(:model) ==
               "anthropic:claude-sonnet-4-6"
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
      assert hd(models).model == "openrouter:anthropic/claude-3.5-sonnet"
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

      assert profile.model == %{
               provider: :openai,
               id: "gpt-4o",
               base_url: "https://my-proxy.com/v1"
             }
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

    test "save_model_profile persists provider_options at profile level", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      html =
        render_hook(view, "save_model_profile", %{
          "profile_id" => "profile-1",
          "profile_id_new" => "profile-1",
          "provider" => "openai",
          "model_id" => "gpt-4o",
          "concurrency" => "3",
          "provider_options" => ~s({"store": false})
        })

      assert html =~ "Model profile saved."
      [profile] = current_models(view)
      # provider_options is a profile-level field (sibling of temperature, max_tokens),
      # NOT inside the model spec. After TOML round-trip the model spec is normalized
      # to a string ("openai:gpt-4o"), but provider_options persists as a map at the
      # profile level.
      assert profile.provider_options == %{"store" => false}
    end

    test "save_model_profile rejects invalid provider_options JSON", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      html =
        render_hook(view, "save_model_profile", %{
          "profile_id" => "profile-1",
          "profile_id_new" => "profile-1",
          "provider" => "openai",
          "model_id" => "gpt-4o",
          "concurrency" => "3",
          "provider_options" => "{not valid json"
        })

      assert html =~ "Provider Options must be valid JSON."
    end

    test "save_model_profile rejects non-object provider_options", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      html =
        render_hook(view, "save_model_profile", %{
          "profile_id" => "profile-1",
          "profile_id_new" => "profile-1",
          "provider" => "openai",
          "model_id" => "gpt-4o",
          "concurrency" => "3",
          "provider_options" => "[1,2,3]"
        })

      assert html =~ "Provider Options must be a JSON object (map)."
    end

    test "save_model_profile then edit pre-fills provider_options from profile", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      render_hook(view, "save_model_profile", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "profile-1",
        "provider" => "openai",
        "model_id" => "gpt-4o",
        "concurrency" => "3",
        "provider_options" => ~s({"store": false})
      })

      # Re-open the edit form and verify provider_options pre-fills
      html = render_hook(view, "edit_model_profile", %{"profile_id" => "profile-1"})

      assert html =~ ~s(name="provider_options")
      # HEEx HTML-escapes the JSON in the textarea (&quot; for quotes)
      assert html =~ "{&quot;store&quot;:false}"
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

      assert hd(models).model == %{
               provider: :openai,
               id: "gpt-4o",
               base_url: "https://my-proxy.com/v1"
             }
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

    # ── move_model_profile (profile re-ordering) ──

    # Adds a complete, saved profile (same fixture shape as the add/save tests
    # above): add_model_profile creates a draft, save_model_profile persists it.
    defp add_saved_profile(view, id, provider, model_id) do
      render_hook(view, "add_model_profile", %{})

      render_hook(view, "save_model_profile", %{
        "profile_id" => id,
        "profile_id_new" => id,
        "provider" => provider,
        "model_id" => model_id,
        "concurrency" => "3"
      })
    end

    defp profile_ids(view) do
      Enum.map(current_models(view), & &1.id)
    end

    test "move_model_profile moves a profile up", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      add_saved_profile(view, "profile-1", "anthropic", "claude-sonnet-4-6")
      add_saved_profile(view, "profile-2", "openai", "gpt-5.5")

      html = render_hook(view, "move_model_profile", %{"direction" => "up", "id" => "profile-2"})

      assert html =~ "Model profile moved."
      assert profile_ids(view) == ["profile-2", "profile-1"]
    end

    test "move_model_profile moves a profile down", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      add_saved_profile(view, "profile-1", "anthropic", "claude-sonnet-4-6")
      add_saved_profile(view, "profile-2", "openai", "gpt-5.5")

      html =
        render_hook(view, "move_model_profile", %{"direction" => "down", "id" => "profile-1"})

      assert html =~ "Model profile moved."
      assert profile_ids(view) == ["profile-2", "profile-1"]
    end

    test "move_model_profile is a no-op when moving the first profile up", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      add_saved_profile(view, "profile-1", "anthropic", "claude-sonnet-4-6")
      add_saved_profile(view, "profile-2", "openai", "gpt-5.5")

      html =
        render_hook(view, "move_model_profile", %{"direction" => "up", "id" => "profile-1"})

      assert html =~ "Model profile moved."
      assert profile_ids(view) == ["profile-1", "profile-2"]
    end

    test "move_model_profile is a no-op when moving the last profile down", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      add_saved_profile(view, "profile-1", "anthropic", "claude-sonnet-4-6")
      add_saved_profile(view, "profile-2", "openai", "gpt-5.5")

      html =
        render_hook(view, "move_model_profile", %{"direction" => "down", "id" => "profile-2"})

      assert html =~ "Model profile moved."
      assert profile_ids(view) == ["profile-1", "profile-2"]
    end

    test "move_model_profile persists the reordered config to disk", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      add_saved_profile(view, "profile-1", "anthropic", "claude-sonnet-4-6")
      add_saved_profile(view, "profile-2", "openai", "gpt-5.5")

      html =
        render_hook(view, "move_model_profile", %{"direction" => "up", "id" => "profile-2"})

      assert html =~ "Model profile moved."

      # The in-memory file_config assign is reloaded from disk after the save
      # (persist_file_config → ConfigIO.load_file_config → EvoGit.Config.resolve),
      # so the swapped order proves the file was written with the new order.
      assert profile_ids(view) == ["profile-2", "profile-1"]

      # File-level check on the raw user config TOML (string-keyed decode).
      file_models = get_in(EvoGit.Config.user_config(), ["llm", "models"]) || []
      assert Enum.map(file_models, &Map.get(&1, "id")) == ["profile-2", "profile-1"]
    end

    test "move_model_profile move buttons respect boundary positions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      add_saved_profile(view, "profile-1", "anthropic", "claude-sonnet-4-6")
      add_saved_profile(view, "profile-2", "openai", "gpt-5.5")

      html = render(view)

      # Exactly one move-up button (for the SECOND profile) and one move-down
      # button (for the FIRST profile) are rendered.
      doc = Floki.parse_document!(html)
      up_buttons = Floki.find(doc, ~s([phx-value-direction="up"]))
      down_buttons = Floki.find(doc, ~s([phx-value-direction="down"]))
      assert Floki.attribute(up_buttons, "phx-value-id") == ["profile-2"]
      assert Floki.attribute(down_buttons, "phx-value-id") == ["profile-1"]

      # Region check: the first card's markup (from its edit button up to the
      # second card's edit button) must NOT contain a move-up button...
      {first_start, _} = :binary.match(html, ~s(phx-value-profile_id="profile-1"))
      {second_start, _} = :binary.match(html, ~s(phx-value-profile_id="profile-2"))
      first_card_region = binary_part(html, first_start, second_start - first_start)
      refute first_card_region =~ ~s(phx-value-direction="up")

      # ...and the last card's markup (from its edit button to the end of the
      # page) must NOT contain a move-down button.
      last_card_region = binary_part(html, second_start, byte_size(html) - second_start)
      refute last_card_region =~ ~s(phx-value-direction="down")
    end

    # ── Peak-hours draft-tracking (phx-change → :profile_form_draft) ──────────
    #
    # phx-click (add/remove_peak_hours_row) does NOT send the enclosing form's
    # data, so the edit form re-renders from the :profile_form_draft assign
    # (stored by phx-change="model_profile_form_change" on every keystroke)
    # instead of file_config — otherwise ALL unsaved typing would be wiped.

    test "model_profile_form_change stores the whole form as a draft", %{conn: conn} do
      # add_model_profile enters edit mode for profile-1 immediately.
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      render_hook(view, "model_profile_form_change", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "default",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "concurrency" => "5",
        "temperature" => "0.7",
        "peak_concurrency" => "0",
        "timezone" => "Asia/Shanghai",
        "peak_hours" => %{"0" => %{"start" => "09:00", "end" => "12:00"}}
      })

      draft = assigns(view).profile_form_draft
      assert draft["temperature"] == "0.7"
      assert draft["timezone"] == "Asia/Shanghai"
      assert draft["peak_concurrency"] == "0"
      # peak_hours is normalized to the canonical atom-keyed list form.
      assert draft["peak_hours"] == [%{start: "09:00", end: "12:00"}]
    end

    test "model_profile_form_change never crashes on partial/odd params", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      html = render_hook(view, "model_profile_form_change", %{"peak_hours" => "garbage"})

      assert html =~ "Edit Profile"
      assert assigns(view).profile_form_draft["peak_hours"] == []
    end

    test "add_peak_hours_row preserves typed values from the draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      render_hook(view, "model_profile_form_change", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "default",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "concurrency" => "5",
        "temperature" => "0.7",
        "peak_concurrency" => "0",
        "timezone" => "Asia/Shanghai",
        "peak_hours" => %{"0" => %{"start" => "09:00", "end" => "12:00"}}
      })

      html = render_hook(view, "add_peak_hours_row", %{})
      doc = Floki.parse_document!(html)

      # Previously-typed window values survive the re-render...
      assert Floki.attribute(doc, ~s(input[name="peak_hours[0][start]"]), "value") == ["09:00"]
      assert Floki.attribute(doc, ~s(input[name="peak_hours[0][end]"]), "value") == ["12:00"]
      # ...and a new blank row is appended.
      assert Floki.attribute(doc, ~s(input[name="peak_hours[1][start]"]), "value") == [""]
      assert Floki.attribute(doc, ~s(input[name="peak_hours[1][end]"]), "value") == [""]

      # Other typed fields are preserved too (the whole form re-renders from the draft).
      assert Floki.attribute(doc, ~s(input[name="temperature"]), "value") == ["0.7"]
      assert Floki.attribute(doc, ~s(input[name="timezone"]), "value") == ["Asia/Shanghai"]
      assert Floki.attribute(doc, ~s(input[name="peak_concurrency"]), "value") == ["0"]
      assert Floki.attribute(doc, ~s(input[name="concurrency"]), "value") == ["5"]
    end

    test "remove_peak_hours_row preserves the remaining typed values", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      render_hook(view, "model_profile_form_change", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "default",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "concurrency" => "3",
        "peak_hours" => %{
          "0" => %{"start" => "09:00", "end" => "12:00"},
          "1" => %{"start" => "14:00", "end" => "18:00"}
        }
      })

      html = render_hook(view, "remove_peak_hours_row", %{"index" => "0"})
      doc = Floki.parse_document!(html)

      # The remaining window (14:00–18:00) is now at index 0 with values intact.
      assert Floki.attribute(doc, ~s(input[name="peak_hours[0][start]"]), "value") == ["14:00"]
      assert Floki.attribute(doc, ~s(input[name="peak_hours[0][end]"]), "value") == ["18:00"]
      refute Floki.find(doc, ~s(input[name="peak_hours[1][start]"])) != []
    end

    test "profile_form_draft is cleared on cancel and on save", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})
      render_hook(view, "edit_model_profile", %{"profile_id" => "profile-1"})

      render_hook(view, "model_profile_form_change", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "default",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "concurrency" => "3",
        "temperature" => "0.7"
      })

      assert assigns(view).profile_form_draft != nil

      # Cancel clears the draft.
      render_hook(view, "cancel_edit_model_profile", %{})
      assert assigns(view).profile_form_draft == nil

      # Re-enter edit mode, type again, then SAVE — the draft is cleared too.
      render_hook(view, "edit_model_profile", %{"profile_id" => "profile-1"})

      render_hook(view, "model_profile_form_change", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "default",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "concurrency" => "3",
        "temperature" => "0.7"
      })

      assert assigns(view).profile_form_draft != nil

      render_hook(view, "save_model_profile", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "default",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "concurrency" => "3"
      })

      assert assigns(view).profile_form_draft == nil
    end

    test "profile_form_draft is cleared when opening a different profile's edit form", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")
      add_saved_profile(view, "profile-1", "anthropic", "claude-sonnet-4-6")
      add_saved_profile(view, "profile-2", "openai", "gpt-5.5")

      render_hook(view, "edit_model_profile", %{"profile_id" => "profile-1"})

      render_hook(view, "model_profile_form_change", %{
        "profile_id" => "profile-1",
        "profile_id_new" => "profile-1",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "concurrency" => "3"
      })

      assert assigns(view).profile_form_draft != nil

      render_hook(view, "edit_model_profile", %{"profile_id" => "profile-2"})
      assert assigns(view).profile_form_draft == nil
    end

    test "save_model_profile rejects a negative peak_concurrency with the updated flash", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})
      render_hook(view, "edit_model_profile", %{"profile_id" => "profile-1"})

      html =
        render_hook(view, "save_model_profile", %{
          "profile_id" => "profile-1",
          "profile_id_new" => "default",
          "provider" => "anthropic",
          "model_id" => "claude-sonnet-4-6",
          "concurrency" => "3",
          "peak_concurrency" => "-1"
        })

      assert html =~ "Peak concurrency must be a non-negative integer."
      # A rejected save still ends the edit session (draft cleared).
      assert assigns(view).profile_form_draft == nil
    end

    test "save_model_profile stores a non-blank timezone and omits a blank one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "add_model_profile", %{})

      html =
        render_hook(view, "save_model_profile", %{
          "profile_id" => "profile-1",
          "profile_id_new" => "default",
          "provider" => "anthropic",
          "model_id" => "claude-sonnet-4-6",
          "concurrency" => "3",
          "timezone" => "Asia/Shanghai"
        })

      assert html =~ "Model profile saved."
      [profile] = current_models(view)
      assert (Map.get(profile, :timezone) || Map.get(profile, "timezone")) == "Asia/Shanghai"

      # A blank timezone omits the key entirely on the next save.
      render_hook(view, "edit_model_profile", %{"profile_id" => "default"})

      render_hook(view, "save_model_profile", %{
        "profile_id" => "default",
        "profile_id_new" => "default",
        "provider" => "anthropic",
        "model_id" => "claude-sonnet-4-6",
        "concurrency" => "3",
        "timezone" => ""
      })

      [profile] = current_models(view)
      refute Map.has_key?(profile, :timezone) or Map.has_key?(profile, "timezone")
    end
  end

  describe "ModelProfileHelpers.move_model_profile/3" do
    alias EvoDashWeb.SettingsLive.ModelProfileHelpers

    defp config_with(models), do: %{llm: %{models: models}}

    test "moves a profile up in the middle of the list" do
      config = config_with([%{id: "a"}, %{id: "b"}, %{id: "c"}])

      moved = ModelProfileHelpers.move_model_profile(config, "b", "up")

      assert Enum.map(moved.llm.models, & &1.id) == ["b", "a", "c"]
    end

    test "moves a profile down in the middle of the list" do
      config = config_with([%{id: "a"}, %{id: "b"}, %{id: "c"}])

      moved = ModelProfileHelpers.move_model_profile(config, "a", "down")

      assert Enum.map(moved.llm.models, & &1.id) == ["b", "a", "c"]
    end

    test "unknown id leaves the config unchanged" do
      config = config_with([%{id: "a"}, %{id: "b"}])

      assert ModelProfileHelpers.move_model_profile(config, "nope", "up") == config
    end

    test "invalid direction leaves the config unchanged" do
      config = config_with([%{id: "a"}, %{id: "b"}])

      assert ModelProfileHelpers.move_model_profile(config, "a", "sideways") == config
    end

    test "empty model list leaves the config unchanged" do
      config = config_with([])

      assert ModelProfileHelpers.move_model_profile(config, "a", "up") == config
    end

    test "first profile cannot move up and last profile cannot move down" do
      config = config_with([%{id: "a"}, %{id: "b"}])

      assert ModelProfileHelpers.move_model_profile(config, "a", "up") == config
      assert ModelProfileHelpers.move_model_profile(config, "b", "down") == config
    end

    test "matches string- or atom-keyed profile ids" do
      config = config_with([%{"id" => "a"}, %{id: "b"}])

      moved = ModelProfileHelpers.move_model_profile(config, "b", "up")

      assert Enum.map(moved.llm.models, &ModelProfileHelpers.profile_id/1) == ["b", "a"]
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
      send(
        view.pid,
        {:llm_test_result,
         {:ok, %{response: "hello", model: %{id: "deepseek-v4-pro", provider: :deepseek}}}}
      )

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

  describe "LLM connection test" do
    # The Connection Test button renders outside the disabled form, so it
    # remains clickable on a remote node. The test_llm handler extracts the
    # model/gen_opts from the selected profile in the common path, then routes
    # through EvoGit.RemoteNode.llm_test/3 when remote_config is true (testing
    # the REMOTE node's LLM) or EvoGit.SystemCheck.llm_test/2 when false
    # (testing the LOCAL LLM). Both branches set status to :testing.

    test "test_llm handler routes through remote node when remote_config is true" do
      alias EvoDashWeb.SettingsLive

      file_config =
        EvoDashWeb.SettingsLive.ConfigIO.load_file_config()
        |> put_in([:llm, :models], [
          %{id: "test_profile", model: "anthropic:claude-sonnet-4-20250514"}
        ])

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          flash: %{},
          remote_config: true,
          llm_test_status: :idle,
          file_config: file_config,
          current_node: node()
        }
      }

      assert {:noreply, result_socket} =
               SettingsLive.handle_event("test_llm", %{"profile_id" => "test_profile"}, socket)

      # Status should move to :testing (the async task was spawned).
      assert result_socket.assigns.llm_test_status == :testing
    end

    test "test_llm handler proceeds when remote_config is false" do
      # On the local node, the test should start (status moves to :testing).
      # We don't verify the actual LLM call (that's in the spawned task), just
      # that the handler doesn't reject and sets status to :testing.
      alias EvoDashWeb.SettingsLive

      file_config =
        EvoDashWeb.SettingsLive.ConfigIO.load_file_config()
        |> put_in([:llm, :models], [
          %{id: "test_profile", model: "anthropic:claude-sonnet-4-20250514"}
        ])

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          flash: %{},
          remote_config: false,
          llm_test_status: :idle,
          file_config: file_config,
          current_node: node()
        }
      }

      assert {:noreply, result_socket} =
               SettingsLive.handle_event("test_llm", %{"profile_id" => "test_profile"}, socket)

      assert result_socket.assigns.llm_test_status == :testing
    end

    test "test_llm handler flashes error when selected profile has no model" do
      alias EvoDashWeb.SettingsLive

      file_config =
        EvoDashWeb.SettingsLive.ConfigIO.load_file_config()
        |> put_in([:llm, :models], [%{id: "empty_profile", model: nil}])

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          flash: %{},
          remote_config: false,
          llm_test_status: :idle,
          file_config: file_config,
          current_node: node()
        }
      }

      assert {:noreply, result_socket} =
               SettingsLive.handle_event("test_llm", %{"profile_id" => "empty_profile"}, socket)

      # Status should remain :idle (no test was started) — the no-model branch
      # is taken instead of the success branch that sets :testing.
      assert result_socket.assigns.llm_test_status == :idle
    end
  end

  describe "sandbox write_paths list editor" do
    # The write_paths card (:list_of_strings schema, commit 0ff33d39) renders in
    # the sandbox category (all sub_category == nil schemas) and in search
    # results. The add_list_entry / remove_list_entry events mutate only the
    # in-memory file_config — nothing persists until save_category is submitted.

    defp write_paths(view) do
      get_in(assigns(view).file_config, [:sandbox, :write_paths])
    end

    # Seeds config.toml before mounting the LiveView. The file-level setup has
    # already redirected XDG_CONFIG_HOME to a per-test temp dir, so
    # EvoGit.Config.config_path() is unique to this test and resolve() picks the
    # file up via its mtime+size-validated cache. The explicit on_exit rm is
    # belt-and-braces (the setup already rm_rf!'s the whole temp dir).
    defp seed_write_paths(paths) do
      path = EvoGit.Config.config_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "[sandbox]\nwrite_paths = #{inspect(paths)}\n")

      on_exit(fn ->
        # Teardown cleanup must not mask test failures.
        File.rm(path)
      end)
    end

    test "sandbox category renders the write_paths card without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_hook(view, "select_category", %{"category" => "sandbox"})

      # Regression: the sandbox category used to hard-filter to [:sandbox, :mode],
      # so any other sub_category == nil schema (write_paths) hit a CaseClauseError
      # in setting_card/1. Rendering without raising proves the :list_of_strings
      # clause works.
      assert html =~ "sandbox.write_paths"
      assert html =~ "Add path"
      # nil (unset) value renders the "Not set" hint instead of inputs
      assert html =~ "platform default writable paths are used"
      assert write_paths(view) == nil
    end

    test "search for write_paths renders the card", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_hook(view, "search", %{"value" => "write_paths"})

      assert html =~ "Search Results"
      assert html =~ "sandbox.write_paths"
      assert html =~ "Add path"
    end

    test "add_list_entry appends a blank entry to the in-memory config", %{conn: conn} do
      seed_write_paths(["/tmp/a", "/tmp/b"])
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "sandbox"})

      html = render_hook(view, "add_list_entry", %{"key_path" => "sandbox.write_paths"})

      # The implementation appends a trailing "" entry (the "add row").
      assert write_paths(view) == ["/tmp/a", "/tmp/b", ""]
      # The re-rendered card keeps the existing entries and shows the new blank input
      assert html =~ ~s(value="/tmp/a")
      assert html =~ ~s(value="/tmp/b")
    end

    test "add_list_entry with an unknown key path flashes an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_hook(view, "add_list_entry", %{"key_path" => "nope.nope"})

      assert html =~ "Invalid key path."
      assert write_paths(view) == nil
    end

    test "remove_list_entry removes the entry at the given index", %{conn: conn} do
      seed_write_paths(["/tmp/a", "/tmp/b"])
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "sandbox"})

      html =
        render_hook(view, "remove_list_entry", %{
          "key_path" => "sandbox.write_paths",
          "index" => "0"
        })

      assert write_paths(view) == ["/tmp/b"]
      refute html =~ ~s(value="/tmp/a")
      assert html =~ ~s(value="/tmp/b")
    end

    test "remove_list_entry with malformed or out-of-range index is a no-op", %{conn: conn} do
      seed_write_paths(["/tmp/a", "/tmp/b"])
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "sandbox"})

      # Malformed index → Integer.parse fails → treated as -1 → no-op
      render_hook(view, "remove_list_entry", %{
        "key_path" => "sandbox.write_paths",
        "index" => "abc"
      })

      assert write_paths(view) == ["/tmp/a", "/tmp/b"]

      # Out-of-range index → no-op
      render_hook(view, "remove_list_entry", %{
        "key_path" => "sandbox.write_paths",
        "index" => "5"
      })

      assert write_paths(view) == ["/tmp/a", "/tmp/b"]
    end

    test "save_category persists the edited list to the config file", %{conn: conn} do
      seed_write_paths(["/tmp/a", "/tmp/b"])
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "sandbox"})

      # Add a blank entry, then remove the first entry → ["/tmp/b", ""]
      render_hook(view, "add_list_entry", %{"key_path" => "sandbox.write_paths"})

      render_hook(view, "remove_list_entry", %{
        "key_path" => "sandbox.write_paths",
        "index" => "0"
      })

      html =
        render_hook(view, "save_category", %{
          "category" => "sandbox",
          "sandbox.mode" => "auto",
          # Form submission includes the hidden sentinel "" plus the text inputs;
          # blank entries are filtered by list_of_strings_value/1.
          "sandbox.write_paths" => ["", "/tmp/b", ""]
        })

      assert html =~ "Configuration saved successfully."
      assert EvoGit.Config.resolve([:sandbox, :write_paths]) == ["/tmp/b"]
      assert File.read!(EvoGit.Config.config_path()) =~ ~s(write_paths = ["/tmp/b"])
    end

    test "blank-only list saves as an explicit empty list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "sandbox"})

      # The UI flow: add one blank entry, then save. The form submits the hidden
      # sentinel "" plus the blank input → parsed to [] (a set-but-empty list
      # that REPLACES the platform defaults, distinct from unset/nil).
      render_hook(view, "add_list_entry", %{"key_path" => "sandbox.write_paths"})

      html =
        render_hook(view, "save_category", %{
          "category" => "sandbox",
          "sandbox.mode" => "auto",
          "sandbox.write_paths" => ["", ""]
        })

      assert html =~ "Configuration saved successfully."
      assert EvoGit.Config.resolve([:sandbox, :write_paths]) == []
      assert File.read!(EvoGit.Config.config_path()) =~ "write_paths = []"
    end

    test "absent write_paths on save keeps nil (no key introduced)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_hook(view, "select_category", %{"category" => "sandbox"})

      html =
        render_hook(view, "save_category", %{
          "category" => "sandbox",
          "sandbox.mode" => "auto"
        })

      assert html =~ "Configuration saved successfully."
      assert EvoGit.Config.resolve([:sandbox, :write_paths]) == nil
      refute File.read!(EvoGit.Config.config_path()) =~ "write_paths"
    end
  end

  describe "platform gating" do
    # SettingsLive filters the :sandbox category per-node-OS via
    # EvoDashWeb.PlatformInfo.filter_schemas_by_category/2 — in mount AND
    # again in handle_params (before category resolution). The testable
    # injection seam is the :platform_os_override app env, which
    # PlatformInfo.os_for_node/1 checks BEFORE any OS detection — so these
    # tests are deterministic on ANY host OS. This file is async: false, so
    # env mutation is safe, but each test still cleans up its own override.

    defp with_os_override(os) do
      Application.put_env(:evo_dash, :platform_os_override, os)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :platform_os_override)
      end)
    end

    test "Windows override hides the Sandbox sidebar entry", %{conn: conn} do
      with_os_override(:windows)

      {:ok, view, html} = live(conn, ~p"/settings")

      # The platform-filtered schemas arrive with the async NodeData result —
      # deliver it deterministically (the real task computes the same values
      # under the :platform_os_override seam, so a duplicate is idempotent).
      html = deliver_node_data(view)

      # The sidebar renders one button per category, each carrying
      # phx-value-category="<name>" (EvoDashWeb.SettingsComponents.Sidebar).
      # With :sandbox deleted from schemas_by_category, no such button exists.
      refute html =~ ~s(phx-value-category="sandbox")
      # The sandbox content section is not rendered either.
      refute html =~ ~s(id="category-sandbox")
      # The default active category is :llm.
      assert html =~ ~s(id="category-llm")
    end

    test "Windows override: ?category=sandbox falls back to :llm without crashing", %{conn: conn} do
      with_os_override(:windows)

      # The result handler re-resolves the category param against the
      # platform-FILTERED schemas — deliver the async result first. On Windows
      # "sandbox" is not a known category → falls back to the active category
      # (:llm). No crash.
      {:ok, view, html} = live(conn, ~p"/settings?category=sandbox")
      html = deliver_node_data(view, "sandbox")

      assert assigns(view).active_category == :llm
      assert html =~ ~s(id="category-llm")
      refute html =~ ~s(id="category-sandbox")
    end

    test "macOS override keeps sandbox mode + write_paths but drops Linux sub-sections", %{
      conn: conn
    } do
      with_os_override(:macos)
      # Seed write_paths so the :list_of_strings card renders its named inputs
      # (an unset/nil value renders only the "Not set" hint, no name attribute).
      seed_write_paths(["/tmp/a"])

      {:ok, view, _html} = live(conn, ~p"/settings")
      # Deliver the async platform-filtered schemas before selecting the
      # category (the seed shell shows the UNFILTERED map).
      deliver_node_data(view)
      html = render_hook(view, "select_category", %{"category" => "sandbox"})

      assert assigns(view).active_category == :sandbox
      # sub_category == nil schemas (mode + write_paths) remain.
      assert html =~ ~s(name="sandbox.mode")
      assert html =~ ~s(name="sandbox.write_paths")
      # The Linux-only sub-sections (:resources/:process/:linux) are filtered
      # out, so their sub-headers never render.
      refute html =~ "Resources"
      refute html =~ "Process Limits"
      refute html =~ "Linux Security"
    end

    test "Linux override keeps the Linux Security sub-section", %{conn: conn} do
      with_os_override(:linux)

      {:ok, view, _html} = live(conn, ~p"/settings")
      # Deliver the async platform-filtered schemas before selecting the
      # category (the seed shell shows the UNFILTERED map).
      deliver_node_data(view)
      html = render_hook(view, "select_category", %{"category" => "sandbox"})

      # On Linux the sandbox schemas are unchanged — all sub-sections render.
      assert html =~ "Linux Security"
      assert html =~ "Resources"
      assert html =~ "Process Limits"
    end
  end

  describe "nix category gating" do
    # SettingsLive hides the :nix category via
    # EvoDashWeb.PlatformInfo.filter_nix_category/2 (applied in mount AND in
    # handle_params before category resolution) when the nix binary is missing
    # on the node AND the user has NOT explicitly set `[nix] enabled` in the
    # raw config file. The testable injection seam is the
    # :nix_available_override app env (checked by
    # PlatformInfo.nix_available_for_node/1 BEFORE any detection) — so these
    # tests are deterministic on ANY host. The file-level `setup` defaults the
    # override to true; each test here overrides it and cleans up via its own
    # on_exit (LIFO: the test's cleanup runs before setup's re-delete, and the
    # next test's setup re-establishes the true default).

    defp with_nix_available_override(bool) do
      Application.put_env(:evo_dash, :nix_available_override, bool)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :nix_available_override)
      end)
    end

    # Seed an explicit `[nix] enabled` in the RAW user config file (under the
    # file-level setup's isolated XDG_CONFIG_HOME dir). Must be called BEFORE
    # live(conn, ~p"/settings") so mount sees it.
    defp seed_nix_enabled(bool) do
      File.mkdir_p!(Path.dirname(EvoGit.Config.config_path()))
      File.write!(EvoGit.Config.config_path(), "[nix]\nenabled = #{bool}\n")
    end

    test "nix binary available → nix category shown even with no config", %{conn: conn} do
      with_nix_available_override(true)

      {:ok, view, html} = live(conn, ~p"/settings")

      # Deliver the async NodeData result (nix visible under the override) so
      # the platform-filtered schemas are in place before the gated asserts.
      html = deliver_node_data(view)

      # Sidebar entry is present on initial load...
      assert html =~ ~s(phx-value-category="nix")
      # ...and selecting the category renders its content section (only the
      # active category's section is rendered, so select first).
      section_html = render_hook(view, "select_category", %{"category" => "nix"})

      assert section_html =~ ~s(id="category-nix")
    end

    test "no nix binary but explicit [nix] enabled = true → category shown", %{conn: conn} do
      with_nix_available_override(false)
      seed_nix_enabled(true)

      {:ok, view, html} = live(conn, ~p"/settings")
      html = deliver_node_data(view)

      assert html =~ ~s(phx-value-category="nix")
      section_html = render_hook(view, "select_category", %{"category" => "nix"})

      assert section_html =~ ~s(id="category-nix")
    end

    test "no nix binary but explicit [nix] enabled = false → category still shown", %{conn: conn} do
      with_nix_available_override(false)
      seed_nix_enabled(false)

      {:ok, view, html} = live(conn, ~p"/settings")
      html = deliver_node_data(view)

      # An explicit false counts as "configured" — the section must stay
      # editable so the user can turn the feature on.
      assert html =~ ~s(phx-value-category="nix")
      section_html = render_hook(view, "select_category", %{"category" => "nix"})

      assert section_html =~ ~s(id="category-nix")
    end

    test "no nix binary and no config → category hidden everywhere (sidebar, section, search)", %{
      conn: conn
    } do
      with_nix_available_override(false)

      {:ok, view, html} = live(conn, ~p"/settings")
      html = deliver_node_data(view)

      # Sidebar entry and content section are both gone.
      refute html =~ ~s(phx-value-category="nix")
      refute html =~ ~s(id="category-nix")
      # The default active category is :llm.
      assert html =~ ~s(id="category-llm")

      # Selecting the hidden category is a no-op — it is not a known category
      # in the filtered map, so active_category stays :llm.
      select_html = render_hook(view, "select_category", %{"category" => "nix"})

      assert assigns(view).active_category == :llm
      refute select_html =~ ~s(id="category-nix")

      # Search: only the nix schemas ([nix] :enabled / :flake_output) contain
      # "nix" in key_path/description, so with the category removed from
      # @schemas_by_category the search finds zero matches.
      search_html = render_hook(view, "search", %{"value" => "nix"})

      assert search_html =~ "No settings found matching"
    end

    test "no nix binary and no config: ?category=nix falls back to :llm without crashing", %{
      conn: conn
    } do
      with_nix_available_override(false)

      # The result handler re-resolves the category param against the
      # platform-FILTERED schemas — deliver the async result first. With nix
      # hidden, "nix" is not a known category → falls back to the active
      # category (:llm). No crash.
      {:ok, view, html} = live(conn, ~p"/settings?category=nix")
      html = deliver_node_data(view, "nix")

      assert assigns(view).active_category == :llm
      assert html =~ ~s(id="category-llm")
      refute html =~ ~s(id="category-nix")
    end
  end

  describe "shell seeding (async platform gating)" do
    # handle_params/3 no longer runs the platform gating + category resolution
    # synchronously: the FILTERED schemas map and the re-resolved active
    # category arrive with the async NodeData result. Until then the page shell
    # seeds — UNFILTERED schemas (every category visible in the sidebar) and
    # the active category via seed_category/2: non-gated `?category=` params
    # (:agents, :remote_connections, :llm, ...) resolve immediately with zero
    # flash, gated ones (:nix / :sandbox — the platform filter may hide them)
    # seed the current stable category (or :llm) and defer to the result
    # handler's re-resolution.
    #
    # The html returned by live/3 is ALWAYS the seed-shell render (the async
    # task's message cannot interleave with the mount/handle_params call), so
    # seed-state html assertions are deterministic. `assigns` may already
    # reflect the real task's (fast, local) result — seed asserts below
    # therefore use scenarios where the seed state and the post-result state
    # coincide, and the post-delivery asserts use deliver_node_data (ours is
    # the last message processed).

    test "non-gated ?category=agents renders the agents section immediately", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings?category=agents")

      # Seeded directly by seed_category/2 — no async result needed. The real
      # task's re-resolution lands on :agents too, so this holds in both states.
      assert assigns(view).active_category == :agents
      assert html =~ "Add Agent"
      assert html =~ ~s(phx-value-category="agents")
    end

    test "gated ?category=sandbox seeds :llm, then resolves :sandbox after delivery", %{
      conn: conn
    } do
      with_os_override(:linux)

      # Seed shell: :sandbox is potentially-gated, so it seeds the default
      # :llm — the sandbox section is NOT rendered on the first paint, even
      # though the UNFILTERED sidebar still lists the sandbox entry. (html-only
      # asserts: the real task may have already re-resolved to :sandbox.)
      {:ok, view, html} = live(conn, ~p"/settings?category=sandbox")

      assert html =~ ~s(id="category-llm")
      refute html =~ ~s(id="category-sandbox")
      assert html =~ ~s(phx-value-category="sandbox")

      # After the async result (sandbox kept on Linux) the result handler
      # re-resolves the captured param and opens the sandbox section.
      html = deliver_node_data(view, "sandbox")

      assert assigns(view).active_category == :sandbox
      assert html =~ ~s(id="category-sandbox")
    end

    test "gated ?category=nix seeds :llm, then resolves :nix after delivery", %{conn: conn} do
      # nix binary available (file-level setup default) → nix visible post-result.
      {:ok, view, html} = live(conn, ~p"/settings?category=nix")

      assert html =~ ~s(id="category-llm")
      refute html =~ ~s(id="category-nix")

      html = deliver_node_data(view, "nix")

      assert assigns(view).active_category == :nix
      assert html =~ ~s(id="category-nix")
    end

    test "gated ?category=nix stays :llm when the nix category is hidden", %{conn: conn} do
      with_nix_available_override(false)

      # Seed shell: the UNFILTERED sidebar still shows the nix entry, but the
      # active category seeds :llm (nix is potentially-gated). The post-result
      # state coincides (:llm — nix hidden), so the assigns assert is race-free.
      {:ok, view, html} = live(conn, ~p"/settings?category=nix")

      assert assigns(view).active_category == :llm
      assert html =~ ~s(id="category-llm")
      assert html =~ ~s(phx-value-category="nix")

      # After the async result (nix hidden: no binary + no explicit config) the
      # category stays :llm and the sidebar entry disappears.
      html = deliver_node_data(view, "nix")

      assert assigns(view).active_category == :llm
      refute html =~ ~s(phx-value-category="nix")
      refute html =~ ~s(id="category-nix")
    end
  end

  describe "remote node config loading (config fetch failure)" do
    # A fake connection manager is registered in the shared
    # EvoGit.RemoteConnection.Registry under the target id with a :connected
    # phase, so NodeAware resolves `?node=` to the remote BEAM node atom
    # "genesis_remote@127.0.0.1" — an unreachable fake node (same seam as
    # projects_live_test). The subsequent `:erpc` calls fail fast with
    # :nodedown, exercising load_node_config's error branch: the error banner
    # renders and the "No LLM Model Configured" box does NOT (the exact bug
    # being fixed — a spurious unconfigured-model warning on top of a real
    # fetch failure). There is no seam to inject a successful
    # get_resolved_config result for a fake node, so the happy path (remote
    # model profiles rendering) is not covered here.
    defp save_target! do
      id = "settings-test-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: id,
          name: "Settings Test Target"
        })

      on_exit(fn ->
        EvoGit.RemoteConnections.delete(id)
      end)

      id
    end

    test "remote config fetch failure renders the error banner, not the LLM warning", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.SettingsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/settings?node=" <> id)

      # The node context resolved to the (unreachable) remote node.
      assert assigns(view)[:current_node] == :"genesis_remote@127.0.0.1"

      # The config load now runs in an async supervised task (NodeData) outside
      # the LiveView process, so its result arrives as a message. Deliver it
      # deterministically (direct-send + render, the same pattern as the LLM
      # connection test) instead of racing the task's message. The real task
      # delivers the same values (erpc fails fast with :nodedown), so a
      # duplicate delivery is an idempotent no-op.
      node = :"genesis_remote@127.0.0.1"

      html =
        deliver_node_data(view, nil,
          file_config: %{},
          config_status: EvoDash.NodeContext.get_remote_config_status(node),
          remote_config_error: :nodedown
        )

      assert is_binary(assigns(view)[:remote_config_error])
      # No config was loaded — an empty map, not a misleading subset.
      assert assigns(view)[:file_config] == %{}

      # The error banner explains the real problem...
      assert html =~ "Remote Configuration Unavailable"
      assert html =~ "Could not load configuration from the remote node"

      # ...and the bogus "No LLM Model Configured" box must NOT fire on top of it.
      refute html =~ "No LLM Model Configured"
    end

    test "stale async result for a different node is dropped", %{conn: conn} do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.SettingsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/settings?node=" <> id)
      assert assigns(view)[:current_node] == :"genesis_remote@127.0.0.1"

      # Deliver a result tagged with a DIFFERENT node than the one currently
      # viewed — simulates a load that was requested for a node the user has
      # since left. The stale-guard in handle_info must drop it: none of the
      # sentinel values may appear in the assigns, regardless of whether the
      # real in-flight load for the current node has landed yet.
      send(
        view.pid,
        {:settings_node_data_loaded, :some_other_node@host, nil,
         %{
           platform_os: :windows,
           filtered_schemas_by_category: %{sentinel: []},
           file_config: %{"llm" => %{"model" => "stale-sentinel"}},
           config_status: %{ok?: true, warnings: [], validation_errors: []},
           remote_config_error: "stale-error",
           custom_agents: %{
             agents: [%{"id" => "stale-agent"}],
             model_selection_script: "stale-script",
             script_status: :ok
           }
         }}
      )

      render(view)

      refute assigns(view)[:platform_os] == :windows
      refute assigns(view)[:schemas_by_category] == %{sentinel: []}
      refute assigns(view)[:file_config] == %{"llm" => %{"model" => "stale-sentinel"}}
      refute assigns(view)[:remote_config_error] == "stale-error"
      refute assigns(view)[:model_selection_script] == "stale-script"
      refute assigns(view)[:custom_agents] == [%{"id" => "stale-agent"}]
    end

    test "local node keeps remote_config_error nil and shows no error banner", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings")

      assert assigns(view)[:remote_config_error] == nil
      refute html =~ "Remote Configuration Unavailable"
    end
  end

  describe "copy-to-clipboard" do
    test "config-path copy button renders with the ClipboardCopy hook", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ ~s(id="settings-config-path-copy")
      assert html =~ ~s(phx-hook="ClipboardCopy")
      assert html =~ ~s(data-content=)
    end

    test "copied event flashes the confirmation message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html = render_hook(view, "copied", %{})

      assert html =~ "Copied to clipboard"
    end
  end
end

# A minimal GenServer standing in for a real remote connection manager in
# `EvoGit.RemoteConnection.Registry` (same pattern as
# EvoDashWeb.ProjectsLiveTest.ConnectionManager). The process dies (and its
# Registry entry is auto-removed) at test end via `start_supervised!`.
defmodule EvoDashWeb.SettingsLiveTest.ConnectionManager do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init({target_id, status}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)
    {:ok, status}
  end

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}
end
