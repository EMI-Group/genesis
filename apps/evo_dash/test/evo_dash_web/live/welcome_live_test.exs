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

  # ───────────────────────────────────────────────────────────────────────────
  # Catalog-derived fixtures — NEVER hardcode model ids/display names. The
  # LLMCatalog is maintained by a parallel effort and model ids/names WILL
  # change (e.g. gemini-3.5-flash may disappear). Provider ids are stable.
  # ───────────────────────────────────────────────────────────────────────────

  defp provider(id), do: Enum.find(EvoGit.Config.LLMCatalog.providers(), &(&1.id == id))

  defp model_string(id, variant_id \\ nil) do
    p = provider(id)
    atom = EvoGit.Config.LLMCatalog.resolve_provider_atom(id, variant_id)
    "#{atom}:#{hd(p.models).id}"
  end

  defp model_string_at(id, variant_id, index) do
    p = provider(id)
    atom = EvoGit.Config.LLMCatalog.resolve_provider_atom(id, variant_id)
    "#{atom}:#{Enum.at(p.models, index).id}"
  end

  # Finds a search needle that matches exactly one of the models' display
  # names (case-insensitive), plus the matching and a non-matching model —
  # for provider-scoped filtering tests. Falls back to the first model's full
  # display name when no unique word exists.
  defp filter_triple(models) do
    lower = Enum.map(models, &String.downcase(&1.display_name))

    needle =
      Enum.find_value(models, fn m ->
        Enum.find_value(String.split(m.display_name), fn word ->
          w = String.downcase(word)

          if Enum.count(lower, &String.contains?(&1, w)) == 1, do: word
        end)
      end) || hd(models).display_name

    needle_lower = String.downcase(needle)

    matched =
      Enum.find(models, &String.contains?(String.downcase(&1.display_name), needle_lower))

    unmatched =
      Enum.find(models, &(not String.contains?(String.downcase(&1.display_name), needle_lower)))

    {needle, matched, unmatched}
  end

  describe "welcome page rendering" do
    test "renders welcome message and version display", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome")

      assert html =~ "Welcome to Genesis"
      # Version display in footer
      version = Application.spec(:evo_git, :vsn) |> to_string()
      assert html =~ version
    end

    test "provider grid shows all preset providers alphabetically", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome")

      preset =
        EvoGit.Config.LLMCatalog.providers()
        |> Enum.reject(&(&1[:custom_model] == true))
        |> Enum.sort_by(fn p -> String.downcase(p.display_name) end)

      assert length(preset) >= 3

      # Every preset provider renders as a card
      for p <- preset do
        assert html =~ p.display_name
      end

      # Sorted case-insensitively: each provider appears before the next one
      positions =
        Enum.map(preset, fn p ->
          html |> String.split(p.display_name) |> List.first() |> String.length()
        end)

      positions
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert a < b, "provider cards out of alphabetical order"
      end)
    end

    test "custom-model providers are not in the grid", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome")

      custom =
        Enum.filter(EvoGit.Config.LLMCatalog.providers(), &(&1[:custom_model] == true))

      assert custom != []

      for p <- custom do
        refute html =~ p.display_name
      end
    end

    test "initial mount shows only the provider step", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome")

      assert html =~ "Add your first LLM"
      assert html =~ "Choose a provider:"

      assert html =~
               "Pick a provider, choose a model, then enter your API key. Keys are stored locally, never sent anywhere."

      # Credentials placeholder (no model selected yet)
      assert html =~ "Select a provider and a model above to enter your API key."

      # Model step is hidden until a provider is selected
      refute html =~ "Choose a model:"
      refute html =~ "Search models"
      refute html =~ "Select a variant:"
      # No API key form
      refute html =~ ~s(name="api_key")
      refute html =~ "Enter your API key"
    end

    test "renders the example task teaching section with copy button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome")

      assert html =~ "Try an example task"
      assert html =~ "Build a simulated, web-based Windows desktop environment"
      assert html =~ "Taskbar containing a Start button"
      assert html =~ "welcome-example-copy"
    end
  end

  describe "provider selection" do
    test "selecting a provider shows its models and the search box", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      g = provider(:google)
      assert g.models != []
      assert provider(:anthropic).models != []

      html = render_click(view, "select_welcome_provider", %{"provider_id" => "google"})

      # Model step + search box appear
      assert html =~ "Choose a model:"
      assert html =~ "Search models"
      assert html =~ ~s(phx-change="search_models")
      assert html =~ ~s(name="search_query")

      for m <- g.models do
        assert html =~ m.display_name
      end

      # Other providers' models are absent
      refute html =~ hd(provider(:anthropic).models).display_name

      # Credentials still placeholder-only — no API key form until a model is
      # selected
      assert html =~ "Select a provider and a model above to enter your API key."
      refute html =~ ~s(name="api_key")
      refute html =~ "Enter your API key"
    end

    test "selecting a different provider switches the model list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      g = provider(:google)
      a = provider(:anthropic)
      assert g.models != []
      assert a.models != []

      html = render_click(view, "select_welcome_provider", %{"provider_id" => "google"})
      assert html =~ hd(g.models).display_name
      refute html =~ hd(a.models).display_name

      html = render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      assert html =~ hd(a.models).display_name
      refute html =~ hd(g.models).display_name
    end
  end

  describe "model selection + merged save flow" do
    test "selecting a model shows the API key form with the credential key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      a = provider(:anthropic)
      assert a.models != []

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})

      html =
        render_click(view, "select_welcome_model", %{
          "model_string" => model_string(:anthropic)
        })

      # The credential_key label appears (mirrors settings_components pattern)
      assert html =~ a.credential_key
      assert html =~ "Enter your API key"
      assert html =~ "Enter your API key for #{a.display_name}."
      assert html =~ "Save &amp; Use this model"

      # Hidden form fields carry the selection through the merged save
      assert html =~ ~s(name="credential_key")
      assert html =~ ~s(name="model_string")
      assert html =~ ~s(name="provider_id")
      assert html =~ ~s(name="variant_id")
    end

    test "merged save persists API key and model profile, then shows success", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      # Initially in setup state (no model profiles)
      refute assigns(view).has_model?
      a = provider(:anthropic)
      ms = model_string(:anthropic)

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => ms})

      html =
        render_submit(view, "save_welcome_setup", %{
          "credential_key" => a.credential_key,
          "api_key" => "sk-ant-test-123",
          "model_string" => ms,
          "provider_id" => "anthropic",
          "variant_id" => ""
        })

      # Combined success flash
      assert html =~ "Model and API key saved."

      # The credential is persisted to credentials.toml
      creds = EvoGit.Config.credentials()
      assert Map.get(creds, a.credential_key) == "sk-ant-test-123"

      # After saving, a model profile exists
      models = get_in(assigns(view).file_config, [:llm, :models]) || []
      assert length(models) == 1

      # The page transitions to the "all set" state
      assert assigns(view).has_model? == true
      # HEEx escapes the apostrophe in "You're" to &#39;
      assert html =~ "You&#39;re All Set!"
      assert html =~ "Go to Dashboard"
      assert html =~ "Open Settings"
      refute html =~ "Add your first LLM"
    end

    test "merged save button is disabled when no key entered and no key set", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => model_string(:anthropic)})

      # The submit button should be disabled (no key typed, no existing key)
      assert render(view) =~ ~s(disabled="")
    end

    test "merged save button is enabled when a key is typed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => model_string(:anthropic)})

      # Type a key via phx-change
      render_change(view, "api_key_changed", %{"api_key" => "sk-ant-typed"})

      html = render(view)

      # The submit button should NOT be disabled now
      assert html =~ "Save &amp; Use this model"
      refute html =~ ~s(disabled="")
    end

    test "server-side guard: blank key with no existing key shows an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      a = provider(:anthropic)
      ms = model_string(:anthropic)

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => ms})

      html =
        render_submit(view, "save_welcome_setup", %{
          "credential_key" => a.credential_key,
          "api_key" => "   ",
          "model_string" => ms,
          "provider_id" => "anthropic",
          "variant_id" => ""
        })

      assert html =~ "Please enter your API key first."
    end
  end

  describe "variant flow" do
    test "variant providers show chips and default to the first variant", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      a = provider(:alibaba)
      assert a.models != []
      assert a.variants != []

      html = render_click(view, "select_welcome_provider", %{"provider_id" => "alibaba"})

      assert html =~ "Select a variant:"

      for v <- a.variants do
        assert html =~ ~s(phx-value-variant_id="#{v.id}")
      end

      # Default variant is the FIRST one (global) — canonical atom model strings
      assert html =~ model_string(:alibaba)
      refute html =~ "alibaba_cn:"
    end

    test "selecting a variant changes the model strings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      a = provider(:alibaba)
      assert a.models != []
      assert a.variants != []

      render_click(view, "select_welcome_provider", %{"provider_id" => "alibaba"})

      html = render_click(view, "select_welcome_variant", %{"variant_id" => "cn"})

      assert html =~ "alibaba_cn:#{hd(a.models).id}"
      assert html =~ " · CN"
      refute html =~ "alibaba:#{hd(a.models).id}"
    end

    test "merged save with the CN variant resolves the correct provider atom", %{conn: conn} do
      # Write a pre-existing credential BEFORE mounting so the socket's cached
      # credentials contain the key (the save proceeds without needing a new key).
      creds = creds_file()
      File.mkdir_p!(Path.dirname(creds))
      File.write!(creds, ~s(alibaba_cn_api_key = "sk-test-cn"\n))
      on_exit(fn -> File.rm(creds_file()) end)

      {:ok, view, _html} = live(conn, ~p"/welcome")

      a = provider(:alibaba)
      assert a.models != []
      cn_model_string = model_string(:alibaba, :cn)

      render_click(view, "select_welcome_provider", %{"provider_id" => "alibaba"})
      render_click(view, "select_welcome_variant", %{"variant_id" => "cn"})
      render_click(view, "select_welcome_model", %{"model_string" => cn_model_string})

      html =
        render_submit(view, "save_welcome_setup", %{
          "credential_key" => "alibaba_cn_api_key",
          "api_key" => "",
          "model_string" => cn_model_string,
          "provider_id" => "alibaba",
          "variant_id" => "cn"
        })

      assert html =~ "Model and API key saved."

      models = get_in(assigns(view).file_config, [:llm, :models]) || []
      assert length(models) == 1
      # The CN variant resolves to the :alibaba_cn provider atom (round-tripped
      # through TOML normalization to the "provider:model" string form)
      assert hd(models).model == cn_model_string
    end
  end

  describe "search scoped to selected provider" do
    test "search is scoped to the selected provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      g = provider(:google)
      a = provider(:anthropic)
      assert g.models != []
      assert a.models != []

      render_click(view, "select_welcome_provider", %{"provider_id" => "google"})

      # A model of ANOTHER provider matches nothing
      html = render_change(view, "search_models", %{"search_query" => hd(a.models).display_name})
      assert html =~ "No models match your search."

      # Clearing restores the selected provider's models
      html = render_change(view, "search_models", %{"search_query" => ""})
      assert html =~ hd(g.models).display_name
      refute html =~ "No models match your search."
    end

    test "search filters models within the provider", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      g = provider(:google)
      a = provider(:anthropic)

      provider_id =
        if length(g.models) >= 2 do
          :google
        else
          assert a.models != []
          :anthropic
        end

      p = provider(provider_id)
      {needle, matched, unmatched} = filter_triple(p.models)

      render_click(view, "select_welcome_provider", %{
        "provider_id" => Atom.to_string(provider_id)
      })

      html = render_change(view, "search_models", %{"search_query" => needle})

      assert html =~ matched.display_name
      refute html =~ unmatched.display_name
    end

    test "search is case-insensitive", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      g = provider(:google)
      assert g.models != []

      render_click(view, "select_welcome_provider", %{"provider_id" => "google"})

      html = render_change(view, "search_models", %{"search_query" => "gemini"})

      for m <- g.models do
        assert html =~ m.display_name
      end
    end

    test "search with no matches shows the zero-results message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_provider", %{"provider_id" => "google"})

      html = render_change(view, "search_models", %{"search_query" => "zzznonexistentzzz"})

      assert html =~ "No models match your search."
    end

    test "clearing search restores all of the provider's models", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      g = provider(:google)
      assert g.models != []
      assert length(g.models) >= 2

      render_click(view, "select_welcome_provider", %{"provider_id" => "google"})

      render_change(view, "search_models", %{"search_query" => hd(g.models).display_name})
      html = render_change(view, "search_models", %{"search_query" => ""})

      for m <- g.models do
        assert html =~ m.display_name
      end
    end

    test "search matches the variant display name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      a = provider(:alibaba)
      assert a.models != []
      assert a.variants != []

      render_click(view, "select_welcome_provider", %{"provider_id" => "alibaba"})

      html =
        render_change(view, "search_models", %{
          "search_query" => hd(a.variants).display_name
        })

      assert html =~ hd(a.models).display_name
    end
  end

  describe "end-of-list guidance" do
    test "shows Settings link guidance when a provider is selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      html = render_click(view, "select_welcome_provider", %{"provider_id" => "google"})

      assert html =~ "Settings page"
      assert html =~ ~p"/settings"
    end

    test "guidance is not rendered at initial mount", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome")
      refute html =~ "Settings page"
    end

    test "zero-results still shows Settings guidance", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_provider", %{"provider_id" => "google"})

      html = render_change(view, "search_models", %{"search_query" => "zzznonexistentzzz"})

      assert html =~ "No models match your search."
      assert html =~ "Settings page"
    end
  end

  describe "base_url handling" do
    test "normal preset providers render only a hidden base_url input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      a = provider(:anthropic)
      assert a.models != []

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})

      html =
        render_click(view, "select_welcome_model", %{
          "model_string" => model_string(:anthropic)
        })

      # No VISIBLE Base URL field for a provider that doesn't require one —
      # the label, required marker, and hint only render in the
      # requires_base_url? branch. (The literal "Base URL" text appears in an
      # HTML comment in the template, so assert on the field markers instead.)
      refute html =~ "Required for this provider."
      refute html =~ ~s(placeholder="https://...")
      # ...but the hidden input is always submitted with the form
      assert html =~ ~s(type="hidden" name="base_url")
    end

    test "save_welcome_setup accepts an extra base_url param without breaking", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      a = provider(:anthropic)
      ms = model_string(:anthropic)

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => ms})

      html =
        render_submit(view, "save_welcome_setup", %{
          "credential_key" => a.credential_key,
          "api_key" => "sk-ant-test-123",
          "model_string" => ms,
          "provider_id" => "anthropic",
          "variant_id" => "",
          "base_url" => "https://x/v1"
        })

      assert html =~ "Model and API key saved."

      models = get_in(assigns(view).file_config, [:llm, :models]) || []
      assert length(models) == 1
      assert assigns(view).has_model?
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
      assert html =~ "Open Settings"
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

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})

      html =
        render_click(view, "select_welcome_model", %{
          "model_string" => model_string(:anthropic)
        })

      assert html =~ "API key is already set"
      assert html =~ "✓ Set"
    end

    test "button enabled when existing key is set (no new key needed)", %{conn: conn} do
      creds = creds_file()
      File.mkdir_p!(Path.dirname(creds))
      File.write!(creds, ~s(anthropic_api_key = "sk-test-existing"\n))

      on_exit(fn -> File.rm(creds_file()) end)

      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => model_string(:anthropic)})

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

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => model_string(:anthropic)})

      html = render(view)
      assert html =~ "Test Connection"
      assert html =~ "hero-signal"
    end

    test "testing state renders the spinner", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => model_string(:anthropic)})

      # The event render (status :testing) is produced before the spawned task's
      # result message is processed (FIFO mailbox), so the returned HTML is
      # deterministic — the spinner, not a raced error state.
      html = render_click(view, "test_llm", %{})
      assert html =~ "Testing LLM connection..."
      assert html =~ "loading loading-spinner"
    end

    test "ok result renders Connected with the model name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      a = provider(:anthropic)
      assert a.models != []

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => model_string(:anthropic)})

      send(view.pid, {:llm_test_result, {:ok, %{model: "x", response: "hello"}}})

      html = render(view)
      assert html =~ "Connected"
      assert html =~ hd(a.models).display_name
      assert html =~ "Retest"
    end

    test "error result renders the reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => model_string(:anthropic)})

      send(view.pid, {:llm_test_result, {:error, "Invalid API key"}})

      html = render(view)
      assert html =~ "Invalid API key"
      assert html =~ "hero-x-circle"
      assert html =~ "Retry"
    end

    test "selecting a different model resets the connection test status", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      a = provider(:anthropic)
      assert length(a.models) >= 2

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => model_string(:anthropic)})

      send(view.pid, {:llm_test_result, {:ok, %{model: "x", response: "hi"}}})

      assert render(view) =~ "Connected"

      html =
        render_click(view, "select_welcome_model", %{
          "model_string" => model_string_at(:anthropic, nil, 1)
        })

      refute html =~ "Connected"
      assert html =~ "Test Connection"
    end

    test "switching provider also resets the connection test status", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => model_string(:anthropic)})

      send(view.pid, {:llm_test_result, {:ok, %{model: "x", response: "hi"}}})

      assert render(view) =~ "Connected"

      # Provider switch resets ALL downstream state: the connection-test status
      # AND the selected model, so the credentials section reverts to the
      # no-model placeholder (no "Test Connection" button at all).
      html = render_click(view, "select_welcome_provider", %{"provider_id" => "google"})
      refute html =~ "Connected"
      refute html =~ "Test Connection"
      assert html =~ "Select a provider and a model above to enter your API key."
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
            model_string: model_string(:anthropic),
            variant_id: nil,
            credential_key: "anthropic_api_key",
            model_display_name: hd(provider(:anthropic).models).display_name
          },
          credentials: %{},
          api_key_input: "",
          base_url_input: "",
          llm_test_status: :idle
        }
      }

      assert {:noreply, result_socket} = WelcomeLive.handle_event("test_llm", %{}, socket)
      assert result_socket.assigns.llm_test_status == :testing
    end

    test "typed API key is saved before the connection test runs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome")

      render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      render_click(view, "select_welcome_model", %{"model_string" => model_string(:anthropic)})
      render_change(view, "api_key_changed", %{"api_key" => "sk-ant-typed"})
      render_click(view, "test_llm", %{})

      assert Map.get(EvoGit.Config.credentials(), "anthropic_api_key") == "sk-ant-typed"
      assert assigns(view).api_key_input == ""
      assert assigns(view).llm_test_status == :testing
    end
  end
end
