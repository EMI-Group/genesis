defmodule EvoDashWeb.WelcomeLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # Isolate all tests in this file from the host's real user config.
  # WelcomeLive.mount/1 calls ConfigIO.load_file_config() → EvoGit.Config.resolve(),
  # which reads config.toml from EvoGit.Config.config_dir/0. On Linux that
  # honours the XDG_CONFIG_HOME env var, so pointing it at an empty temp dir
  # guarantees no config.toml exists and schema defaults are used — making the
  # tests deterministic regardless of host env.
  setup do
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_welcome_test_config_#{System.unique_integer([:positive])}"
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

  defp config_file, do: EvoGit.Config.config_path()
  defp creds_file, do: EvoGit.Config.credentials_path()

  # Phoenix.LiveViewTest assigns/1 is not available in this version; read the
  # live view socket assigns directly via the process dictionary state.
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  describe "welcome page rendering" do
    test "renders welcome message and version display", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome")

      assert html =~ "Welcome to Genesis"
      # Version display in footer
      version = Application.spec(:evo_git, :vsn) |> to_string()
      assert html =~ version
    end

    test "flat model list shows models from multiple providers", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome")

      # Anthropic model
      assert html =~ "Claude Sonnet 5"
      assert html =~ "Anthropic"
      # Google model
      assert html =~ "Gemini 3.5 Flash"
      assert html =~ "Google"
      # OpenAI model
      assert html =~ "GPT-5.5"
      assert html =~ "OpenAI"
    end

    test "flat list shows provider+model together in single grid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      # Each model button carries the model_string in the format provider:model
      # so save_welcome_setup can be driven from it.
      html = element(view, "[phx-click='select_welcome_model']", "Gemini 3.5 Flash") |> render()
      assert html =~ "google:gemini-3.5-flash"
    end

    test "variants are expanded as separate entries", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome")

      # Alibaba has Global and CN variants; both should appear with their variant suffix
      assert html =~ "Global"
      assert html =~ "CN"
      # Alibaba models appear (twice — once per variant)
      assert html =~ "Qwen 3.7 Max"
    end

    test "providers are sorted alphabetically (case-insensitive)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      html = render(view)

      # Find the position of provider header names in the rendered HTML.
      # "Alibaba" should appear before "Anthropic" (alphabetical sort).
      alibaba_pos = String.split(html, "Alibaba Cloud") |> List.first() |> String.length()
      anthropic_pos = String.split(html, "Anthropic") |> List.first() |> String.length()

      assert alibaba_pos < anthropic_pos,
             "expected \"Alibaba\" to appear before \"Anthropic\" in the model grid"

      # DeepSeek before Google before OpenAI
      deepseek_pos = String.split(html, "DeepSeek") |> List.first() |> String.length()
      google_pos = String.split(html, "Google") |> List.first() |> String.length()
      openai_pos = String.split(html, "OpenAI") |> List.first() |> String.length()

      assert deepseek_pos < google_pos, "expected \"DeepSeek\" before \"Google\""
      assert google_pos < openai_pos, "expected \"Google\" before \"OpenAI\""
    end
  end

  describe "model selection + merged save flow" do
    test "selecting a model shows the API key field with correct credential key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      html =
        render_click(view, "select_welcome_model", %{
          "model_string" => "anthropic:claude-sonnet-5"
        })

      # The credential_key label appears (mirrors settings_components pattern)
      assert html =~ "anthropic_api_key"
      assert html =~ "Enter your API key"
    end

    test "merged save persists API key and model profile, then shows success", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      # Initially in setup state (no model profiles)
      refute assigns(view).has_model?

      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})

      html =
        render_submit(view, "save_welcome_setup", %{
          "credential_key" => "anthropic_api_key",
          "api_key" => "sk-ant-test-123",
          "model_string" => "anthropic:claude-sonnet-5",
          "provider_id" => "anthropic",
          "variant_id" => ""
        })

      # Combined success flash
      assert html =~ "Model and API key saved."

      # The credential is persisted to credentials.toml
      creds = EvoGit.Config.credentials()
      assert Map.get(creds, "anthropic_api_key") == "sk-ant-test-123"

      # After saving, a model profile exists
      models = get_in(assigns(view).file_config, [:llm, :models]) || []
      assert length(models) == 1

      # The page transitions to the "all set" state
      assert assigns(view).has_model? == true
      # HEEx escapes the apostrophe in "You're" to &#39;
      assert html =~ "You&#39;re All Set!"
    end

    test "merged save with variant resolves correct provider atom", %{conn: conn} do
      # Write a pre-existing credential BEFORE mounting so the socket's cached
      # credentials contain the key (the save proceeds without needing a new key).
      creds = creds_file()
      File.mkdir_p!(Path.dirname(creds))
      File.write!(creds, ~s(alibaba_cn_api_key = "sk-test-cn"\n))
      on_exit(fn -> File.rm(creds_file()) end)

      {:ok, view, _html} = live(conn, ~p"/welcome")

      html =
        render_click(view, "save_welcome_setup", %{
          "credential_key" => "alibaba_cn_api_key",
          "api_key" => "",
          "model_string" => "alibaba:qwen-3.7-max",
          "provider_id" => "alibaba",
          "variant_id" => "cn"
        })

      assert html =~ "Model and API key saved."

      models = get_in(assigns(view).file_config, [:llm, :models]) || []
      assert length(models) == 1
      # The CN variant resolves to the :alibaba_cn provider atom
      model = hd(models).model
      assert model == "alibaba_cn:qwen-3.7-max"
    end

    test "merged save button is disabled when no key entered and no key set", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})

      html = render(view)

      # The submit button should be disabled (no key typed, no existing key)
      assert html =~ ~s(disabled="")
    end

    test "merged save button is enabled when a key is typed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})

      # Type a key via phx-change
      render_change(view, "api_key_changed", %{"api_key" => "sk-ant-typed"})

      html = render(view)

      # The submit button should NOT be disabled now
      assert html =~ "Save &amp; Use this model"
      refute html =~ ~s(disabled="")
    end

    test "server-side guard: empty key with no existing key shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})

      html =
        render_submit(view, "save_welcome_setup", %{
          "credential_key" => "anthropic_api_key",
          "api_key" => "   ",
          "model_string" => "anthropic:claude-sonnet-5",
          "provider_id" => "anthropic",
          "variant_id" => ""
        })

      assert html =~ "Please enter your API key first."
    end

    test "selecting different models updates the credential key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      # Anthropic uses anthropic_api_key
      html1 =
        render_click(view, "select_welcome_model", %{
          "model_string" => "anthropic:claude-sonnet-5"
        })

      assert html1 =~ "anthropic_api_key"

      # Google uses google_api_key
      html2 =
        render_click(view, "select_welcome_model", %{"model_string" => "google:gemini-3.5-flash"})

      assert html2 =~ "google_api_key"
      refute html2 =~ "anthropic_api_key"
    end
  end

  describe "search filtering" do
    test "search filters models by model display name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      # Type a search query for a specific model
      render_change(view, "search_models", %{"search_query" => "Gemini"})

      html = render(view)

      # Gemini should still be visible
      assert html =~ "Gemini 3.5 Flash"
      # A model that doesn't match should be hidden
      refute html =~ "Claude Sonnet 5"
    end

    test "search filters models by provider display name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_change(view, "search_models", %{"search_query" => "Anthropic"})

      html = render(view)

      # Anthropic's model visible
      assert html =~ "Claude Sonnet 5"
      assert html =~ "Anthropic"
      # Google model hidden
      refute html =~ "Gemini 3.5 Flash"
    end

    test "search filters by variant display name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_change(view, "search_models", %{"search_query" => "Global"})

      html = render(view)

      # Alibaba Global variant visible
      assert html =~ "Global"
      assert html =~ "Qwen 3.7 Max"
      # CN variant model is in a separate group — "CN" suffix should not appear
      # when filtering for "Global". (The variant suffix " · CN" is part of the
      # button text, so filtering it out confirms group-level filtering.)
      refute html =~ "· CN"
    end

    test "search is case-insensitive", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_change(view, "search_models", %{"search_query" => "anthropic"})

      html = render(view)

      assert html =~ "Claude Sonnet 5"
    end

    test "search with no matches shows zero-results message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_change(view, "search_models", %{"search_query" => "zzznonexistentzzz"})

      html = render(view)

      assert html =~ "No models match your search."
    end

    test "clearing search restores all models", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_change(view, "search_models", %{"search_query" => "Gemini"})
      render_change(view, "search_models", %{"search_query" => ""})

      html = render(view)

      # Both Gemini and Claude are back
      assert html =~ "Gemini 3.5 Flash"
      assert html =~ "Claude Sonnet 5"
    end
  end

  describe "end-of-list guidance" do
    test "shows Settings link guidance at end of model list", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome")

      assert html =~ "Settings page"
      assert html =~ ~p"/settings"
    end

    test "zero-results still shows Settings guidance", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_change(view, "search_models", %{"search_query" => "zzznonexistentzzz"})

      html = render(view)

      assert html =~ "No models match your search."
      assert html =~ "Settings page"
    end
  end

  describe "already configured state" do
    test "shows all-set state when a model profile already exists", %{conn: conn} do
      # Write a minimal config.toml with a model profile
      config_path = config_file()
      File.mkdir_p!(Path.dirname(config_path))

      File.write!(config_path, """
      [[llm.models]]
      id = "profile-1"
      model = {provider = "anthropic", id = "claude-sonnet-5"}
      concurrency = 3
      """)

      on_exit(fn -> File.rm(config_path) end)

      {:ok, _view, html} = live(conn, ~p"/welcome")

      # Shows the all-set state (HEEx escapes the apostrophe in "You're")
      assert html =~ "You&#39;re All Set!"
      assert html =~ "Go to Dashboard"
      # Does NOT show the setup grid
      refute html =~ "Add your first LLM"
      refute html =~ "Choose a model:"
    end

    test "all-set state shows Get Started button", %{conn: conn} do
      config_path = config_file()
      File.mkdir_p!(Path.dirname(config_path))

      File.write!(config_path, """
      [[llm.models]]
      id = "profile-1"
      model = {provider = "google", id = "gemini-3.5-flash"}
      concurrency = 3
      """)

      on_exit(fn -> File.rm(config_path) end)

      {:ok, view, _html} = live(conn, ~p"/welcome")

      assert has_element?(view, "button", "Go to Dashboard")
    end
  end

  describe "skip and get started" do
    test "skip redirects to welcome complete", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "skip", %{})
      assert_redirect(view, "/welcome/complete")
    end

    test "get_started redirects to welcome complete", %{conn: conn} do
      config_path = config_file()
      File.mkdir_p!(Path.dirname(config_path))

      File.write!(config_path, """
      [[llm.models]]
      id = "profile-1"
      model = {provider = "anthropic", id = "claude-sonnet-5"}
      concurrency = 3
      """)

      on_exit(fn -> File.rm(config_path) end)

      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "get_started", %{})
      assert_redirect(view, "/welcome/complete")
    end
  end

  describe "API key detection (credentials.toml)" do
    test "shows key already set when credential exists", %{conn: conn} do
      creds = creds_file()
      File.mkdir_p!(Path.dirname(creds))
      File.write!(creds, ~s(anthropic_api_key = "sk-test-existing"\n))

      on_exit(fn -> File.rm(creds_file()) end)

      {:ok, view, _html} = live(conn, ~p"/welcome")

      html =
        render_click(view, "select_welcome_model", %{
          "model_string" => "anthropic:claude-sonnet-5"
        })

      assert html =~ "API key is already set"
      assert html =~ "Set"
    end

    test "button enabled when existing key is set (no new key needed)", %{conn: conn} do
      creds = creds_file()
      File.mkdir_p!(Path.dirname(creds))
      File.write!(creds, ~s(anthropic_api_key = "sk-test-existing"\n))

      on_exit(fn -> File.rm(creds_file()) end)

      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})

      html = render(view)

      # Button should be enabled since key is already set
      refute html =~ ~s(disabled="")
      assert html =~ "Save &amp; Use this model"
    end
  end

  describe "back navigation" do
    test "renders a Back button with browser-history fallback", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome")
      assert html =~ "Back"
      assert html =~ "hero-arrow-left"
      assert html =~ "history.back()"
      # Single quotes inside the onclick attribute are HTML-escaped (&#39;)
      assert html =~ "window.location.href = &#39;/&#39;;"
    end

    test "Back button renders in the all-set state too", %{conn: conn} do
      config_path = config_file()
      File.mkdir_p!(Path.dirname(config_path))

      File.write!(config_path, """
      [[llm.models]]
      id = "profile-1"
      model = {provider = "anthropic", id = "claude-sonnet-5"}
      concurrency = 3
      """)

      on_exit(fn -> File.rm(config_path) end)
      {:ok, _view, html} = live(conn, ~p"/welcome")
      assert html =~ "Back"
      assert html =~ "history.back()"
    end
  end

  describe "LLM connection test" do
    test "test connection button renders only when a model is selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")
      refute render(view) =~ "Test Connection"
      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})
      html = render(view)
      assert html =~ "Test Connection"
      assert html =~ "hero-signal"
    end

    test "testing state renders the spinner", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")
      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})
      # The event render (status :testing) is produced before the spawned task's
      # result message is processed (FIFO mailbox), so the returned HTML is
      # deterministic — the spinner, not a raced error state.
      html = render_click(view, "test_llm", %{})
      assert html =~ "Testing LLM connection..."
      assert html =~ "loading loading-spinner"
    end

    test "ok result renders Connected with the model name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")
      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})

      send(
        view.pid,
        {:llm_test_result, {:ok, %{model: "anthropic:claude-sonnet-5", response: "hello"}}}
      )

      html = render(view)
      assert html =~ "Connected"
      assert html =~ "Claude Sonnet 5"
    end

    test "error result renders the reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")
      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})
      send(view.pid, {:llm_test_result, {:error, "Invalid API key"}})
      html = render(view)
      assert html =~ "Invalid API key"
      assert html =~ "hero-x-circle"
    end

    test "selecting a different model resets the connection test status", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")
      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})

      send(
        view.pid,
        {:llm_test_result, {:ok, %{model: "anthropic:claude-sonnet-5", response: "hi"}}}
      )

      assert render(view) =~ "Connected"
      render_click(view, "select_welcome_model", %{"model_string" => "google:gemini-3.5-flash"})
      html = render(view)
      refute html =~ "Connected"
      assert html =~ "Test Connection"
    end

    test "test_llm handler starts the test (unit-style)", %{conn: _conn} do
      alias EvoDashWeb.WelcomeLive
      # No typed key — the spawned task fails fast without a real network call.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          flash: %{},
          selected_entry: %{
            provider_id: :anthropic,
            model_string: "anthropic:claude-sonnet-5",
            variant_id: nil,
            credential_key: "anthropic_api_key",
            model_display_name: "Claude Sonnet 5"
          },
          credentials: %{},
          api_key_input: "",
          llm_test_status: :idle
        }
      }

      assert {:noreply, result_socket} = WelcomeLive.handle_event("test_llm", %{}, socket)
      assert result_socket.assigns.llm_test_status == :testing
    end

    test "typed API key is saved before the connection test runs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")
      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})
      render_change(view, "api_key_changed", %{"api_key" => "sk-ant-typed"})
      render_click(view, "test_llm", %{})
      assert Map.get(EvoGit.Config.credentials(), "anthropic_api_key") == "sk-ant-typed"
      assert assigns(view).api_key_input == ""
      assert assigns(view).llm_test_status == :testing
    end
  end
end
