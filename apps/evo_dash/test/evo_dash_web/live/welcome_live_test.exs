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
      # so save_quick_setup can be driven from it.
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
  end

  describe "model selection + API key save flow" do
    test "selecting a model shows the API key field with correct credential key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      html = render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})

      # The credential_key label appears (mirrors settings_components pattern)
      assert html =~ "anthropic_api_key"
      assert html =~ "Enter your API key"
    end

    test "saving an API key persists it and shows success flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})

      html =
        render_submit(view, "save_api_key", %{
          "credential_key" => "anthropic_api_key",
          "api_key" => "sk-ant-test-123"
        })

      assert html =~ "API key saved successfully."

      # The credential is persisted to credentials.toml
      creds = EvoGit.Config.credentials()
      assert Map.get(creds, "anthropic_api_key") == "sk-ant-test-123"
    end

    test "rejects empty API key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})

      html =
        render_submit(view, "save_api_key", %{
          "credential_key" => "anthropic_api_key",
          "api_key" => "   "
        })

      assert html =~ "API key cannot be empty."
    end

    test "save_quick_setup adds a model profile and transitions to all-set state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      # Initially in setup state (no model profiles)
      refute assigns(view).has_model?

      html =
        render_click(view, "save_quick_setup", %{
          "model_string" => "anthropic:claude-sonnet-5",
          "provider_id" => "anthropic",
          "variant_id" => ""
        })

      assert html =~ "Model selected and saved."

      # After saving, a model profile exists
      models = get_in(assigns(view).file_config, [:llm, :models]) || []
      assert length(models) == 1

      # The page transitions to the "all set" state
      assert assigns(view).has_model? == true
      # HEEx escapes the apostrophe in "You're" to &#39;
      assert html =~ "You&#39;re All Set!"
    end

    test "save_quick_setup with variant resolves correct provider atom", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      html =
        render_click(view, "save_quick_setup", %{
          "model_string" => "alibaba:qwen-3.7-max",
          "provider_id" => "alibaba",
          "variant_id" => "cn"
        })

      assert html =~ "Model selected and saved."

      models = get_in(assigns(view).file_config, [:llm, :models]) || []
      assert length(models) == 1
      # The CN variant resolves to the :alibaba_cn provider atom
      model = hd(models).model
      assert model == "alibaba_cn:qwen-3.7-max"
    end

    test "selecting different models updates the credential key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      # Anthropic uses anthropic_api_key
      html1 = render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})
      assert html1 =~ "anthropic_api_key"

      # Google uses google_api_key
      html2 = render_click(view, "select_welcome_model", %{"model_string" => "google:gemini-3.5-flash"})
      assert html2 =~ "google_api_key"
      refute html2 =~ "anthropic_api_key"
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

      html = render_click(view, "select_welcome_model", %{"model_string" => "anthropic:claude-sonnet-5"})

      assert html =~ "API key is already set"
      assert html =~ "Set"
    end
  end
end
