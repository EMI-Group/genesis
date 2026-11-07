defmodule EvoDashWeb.WelcomeLiveTest do
  # Config files are per-process isolated; the connection runner seam is owned
  # exclusively by this module and never calls a provider. The global "tasks"
  # publisher remains in a separate sync module below.
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias EvoDashWeb.WelcomeLive.Setup
  alias EvoGit.Config.LLMCatalog, as: Catalog

  # Canonical resolution can cold-load the model catalog before reaching the
  # stub; keep that startup budget separate from the blocked runner's reply.
  @runner_start_timeout 15_000

  setup do
    EvoDash.Test.ConfigDir.isolate!("evogit_welcome_test_config")
    File.mkdir_p!(EvoGit.Config.config_dir())
    owner = self()
    previous_runner = Application.fetch_env(:evo_dash, :welcome_llm_test_runner)

    # Block until the test explicitly replies: spinner, options and stale-result
    # assertions are deterministic, with no real HTTP or ambient credential use.
    Application.put_env(:evo_dash, :welcome_llm_test_runner, fn model, opts ->
      send(owner, {:welcome_test_started, self(), model, opts})

      receive do
        {:finish, result} -> result
      after
        5_000 -> {:error, "Test runner was not released"}
      end
    end)

    on_exit(fn ->
      case previous_runner do
        {:ok, runner} -> Application.put_env(:evo_dash, :welcome_llm_test_runner, runner)
        :error -> Application.delete_env(:evo_dash, :welcome_llm_test_runner)
      end
    end)

    :ok
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
  defp provider(id), do: Enum.find(Catalog.providers(), &(&1.id == id))

  defp model_string(id, variant_id \\ nil, index \\ 0) do
    model = Enum.at(provider(id).models, index)
    "#{Catalog.resolve_provider_atom(id, variant_id)}:#{model.id}"
  end

  defp choose(view, id \\ :anthropic, variant \\ nil) do
    render_click(view, "select_welcome_provider", %{"provider_id" => to_string(id)})

    if variant do
      render_click(view, "select_welcome_variant", %{"variant_id" => to_string(variant)})
    end

    render_click(view, "select_welcome_model", %{"model_string" => model_string(id, variant)})
  end

  defp read_config do
    {:ok, config} = EvoGit.Config.config_path() |> File.read!() |> TomlElixir.decode()
    config
  end

  defp seed_config(text), do: File.write!(EvoGit.Config.config_path(), text)

  defp seed_credentials(text) do
    {:ok, credentials} = TomlElixir.decode(text)

    for key <- Map.keys(credentials) do
      preserve_key(EvoGit.Config.credential_key_to_reqllm_key(key))
    end

    File.write!(EvoGit.Config.credentials_path(), text)
  end

  defp preserve_key(key) do
    previous = Application.fetch_env(:req_llm, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:req_llm, key, value)
        :error -> Application.delete_env(:req_llm, key)
      end
    end)
  end

  defp save(view, key \\ "sk-ant-test-123") do
    preserve_key(:anthropic_api_key)
    view |> form("#welcome-save", %{"api_key" => key}) |> render_submit()
  end

  defp success_flash(html), do: assert(html =~ "Provider and models saved. You&#39;re all set!")

  defp finish_test(view, pid, result) do
    seq = assigns(view).llm_test_seq
    send(pid, {:finish, result})
    await_status(view, result)
    assert assigns(view).llm_test_seq == seq
    render(view)
  end

  defp await_status(view, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    if assigns(view).llm_test_status != expected do
      assert System.monotonic_time(:millisecond) < deadline,
             "connection result did not reach the LiveView"

      Process.sleep(2)
      await_status(view, expected, deadline)
    end
  end

  defp filter_triple(models) do
    lower = Enum.map(models, &String.downcase(&1.display_name))

    needle =
      Enum.find_value(models, fn m ->
        Enum.find(String.split(m.display_name), fn word ->
          Enum.count(lower, &String.contains?(&1, String.downcase(word))) == 1
        end)
      end) || hd(models).display_name

    matched =
      Enum.find(
        models,
        &String.contains?(String.downcase(&1.display_name), String.downcase(needle))
      )

    unmatched =
      Enum.find(
        models,
        &(not String.contains?(String.downcase(&1.display_name), String.downcase(needle)))
      )

    assert unmatched
    {needle, matched, unmatched}
  end

  describe "welcome page rendering" do
    test "mount renders the version, sorted preset providers and only the provider step", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/welcome")
      assert html =~ "Welcome to Genesis"
      assert html =~ to_string(Application.spec(:evo_git, :vsn))

      preset =
        Catalog.providers()
        |> Enum.reject(&(&1[:custom_model] == true))
        |> Enum.sort_by(&String.downcase(&1.display_name))

      assert length(preset) >= 3

      buttons =
        html |> Floki.parse_document!() |> Floki.find("button[phx-click=select_welcome_provider]")

      assert Enum.map(buttons, &Floki.attribute(&1, "phx-value-provider_id")) ==
               Enum.map(preset, &[to_string(&1.id)])

      for p <- preset, do: assert(html =~ p.display_name)

      for p <- Enum.filter(Catalog.providers(), &(&1[:custom_model] == true)),
          do: refute(html =~ p.display_name)

      assert html =~ "Add your first LLM"
      assert html =~ "Choose a provider:"

      assert html =~
               "Pick a provider, select one or more models, then choose API key or subscription authentication."

      assert html =~ "Select a provider and models above to configure authentication."
      refute has_element?(view, "#welcome-save")
      refute html =~ "Choose a model:"
      refute html =~ "Search models"
      refute html =~ "Select a variant:"
      refute html =~ "Try an example task"
      refute html =~ "welcome-example-copy"
    end

    test "selecting a provider scopes the models and search without selecting authentication", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/welcome")
      html = render_click(view, "select_welcome_provider", %{"provider_id" => "google"})
      assert html =~ "Choose a model:"
      assert has_element?(view, "input[name=search_query][phx-change=search_models]")
      for m <- provider(:google).models, do: assert(html =~ m.display_name)
      refute html =~ hd(provider(:anthropic).models).display_name
      assert html =~ "Select a provider and models above to configure authentication."
      refute has_element?(view, "#welcome-save")
      assert assigns(view).selected_models == []

      html = render_click(view, "select_welcome_provider", %{"provider_id" => "anthropic"})
      assert html =~ hd(provider(:anthropic).models).display_name
      refute html =~ hd(provider(:google).models).display_name
    end

    test "model selection renders authentication and defaults, not client-controlled selection fields",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome")
      html = choose(view)
      assert html =~ provider(:anthropic).credential_key
      assert html =~ "Enter your API key for #{provider(:anthropic).display_name}."
      assert has_element?(view, "#welcome-save button[type=submit]", "Save provider and models")

      assert has_element?(
               view,
               "#welcome-default-model option[selected][value='#{model_string(:anthropic)}']"
             )

      assert has_element?(view, "#welcome-auth-mode")

      for field <- ~w(credential_key model_string provider_id variant_id) do
        refute has_element?(view, "#welcome-save input[name=#{field}]")
      end
    end
  end

  describe "provider-profile save" do
    test "save persists one provider with its model, key and defaults, then shows all-set", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/welcome")
      refute assigns(view).has_model?
      choose(view)
      html = save(view)
      success_flash(html)
      assert EvoGit.Config.credentials()[provider(:anthropic).credential_key] == "sk-ant-test-123"

      llm = read_config()["llm"]
      assert [profile] = llm["providers"]
      assert profile["provider"] == "anthropic"
      assert profile["auth_mode"] == "api_key"
      assert llm["default_provider_profile"] == profile["id"]
      assert profile["default_model"] == hd(provider(:anthropic).models).id
      assert [model] = profile["models"]
      assert model["model"] == profile["default_model"]
      assert model["reasoning_efforts"] == Setup.reasoning_efforts(assigns(view).selected_entry)
      refute Map.has_key?(model, "default_reasoning_effort")
      refute Map.has_key?(llm, "models")
      assert assigns(view).has_model?
      assert html =~ "You&#39;re All Set!"
      assert html =~ "Go to Dashboard"
      assert html =~ "Open Settings"
      refute html =~ "Add your first LLM"
    end

    test "multiple models keep distinct reasoning defaults and the selected default model", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/welcome")
      choose(view)
      first = model_string(:anthropic)
      second = model_string(:anthropic, nil, 1)
      render_click(view, "select_welcome_model", %{"model_string" => second})
      assert assigns(view).selected_models == [first, second]
      assert assigns(view).default_model == first
      entries = Enum.filter(assigns(view).flat_models, &(&1.model_string in [first, second]))
      [entry1, entry2] = entries
      effort1 = List.last(Setup.reasoning_efforts(entry1))
      effort2 = hd(Setup.reasoning_efforts(entry2))
      reasoning = %{first => effort1, second => effort2}

      view
      |> form("#welcome-defaults", %{"default_model" => second, "reasoning" => reasoning})
      |> render_change()

      assert assigns(view).selected_entry.model_string == second
      assert has_element?(view, "#welcome-default-model option[selected][value='#{second}']")
      success_flash(save(view))
      assert [profile] = read_config()["llm"]["providers"]
      assert profile["default_model"] == entry2.model_id
      assert Enum.map(profile["models"], & &1["model"]) == Enum.map(entries, & &1.model_id)

      for entry <- entries do
        model = Enum.find(profile["models"], &(&1["model"] == entry.model_id))
        assert model["default_reasoning_effort"] == reasoning[entry.model_string]
        # A chosen default must not reduce the later task-picker inventory.
        assert model["reasoning_efforts"] == Setup.reasoning_efforts(entry)
      end
    end

    test "toggling models removes their defaults and deselecting the last disables setup", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/welcome")
      choose(view)
      first = model_string(:anthropic)
      second = model_string(:anthropic, nil, 1)
      render_click(view, "select_welcome_model", %{"model_string" => second})

      render_change(view, "welcome_defaults_changed", %{
        "default_model" => first,
        "reasoning" => %{first => "high"}
      })

      render_click(view, "select_welcome_model", %{"model_string" => first})
      assert assigns(view).selected_models == [second]
      assert assigns(view).default_model == second
      assert assigns(view).model_reasoning == %{}
      assert has_element?(view, "button[phx-value-model_string='#{first}'][aria-pressed=false]")
      assert has_element?(view, "button[phx-value-model_string='#{second}'][aria-pressed=true]")
      render_click(view, "select_welcome_model", %{"model_string" => second})
      assert assigns(view).selected_models == []
      assert assigns(view).default_model == nil
      assert assigns(view).selected_entry == nil
      refute has_element?(view, "#welcome-save")
      html = render_submit(view, "save_welcome_setup", %{"api_key" => "must-not-save"})
      assert html =~ "Choose models and a default model from the selected provider."
      refute File.exists?(EvoGit.Config.config_path())
      refute File.exists?(EvoGit.Config.credentials_path())
    end

    test "save availability follows a typed key and blank-key guard writes nothing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome")
      choose(view)
      assert has_element?(view, "#welcome-save button[disabled]")
      assert has_element?(view, "button[phx-click=test_llm][disabled]")
      render_change(view, "api_key_changed", %{"api_key" => "sk-typed"})
      refute has_element?(view, "#welcome-save button[disabled]")
      refute has_element?(view, "button[phx-click=test_llm][disabled]")
      html = view |> form("#welcome-save", %{"api_key" => "   "}) |> render_submit()
      assert html =~ "Please enter your API key first."
      refute assigns(view).has_model?
      refute File.exists?(EvoGit.Config.credentials_path())
      refute File.exists?(EvoGit.Config.config_path())
    end

    test "existing credentials enable saving without replacing the key", %{conn: conn} do
      seed_credentials(~s(anthropic_api_key = "sk-existing"\n))
      {:ok, view, _} = live(conn, ~p"/welcome")
      html = choose(view)
      assert html =~ "API key is already set"
      assert html =~ "✓ Set"
      refute has_element?(view, "#welcome-save button[disabled]")
      success_flash(save(view, ""))
      assert EvoGit.Config.credentials()["anthropic_api_key"] == "sk-existing"
    end

    test "forged selection/default/reasoning events cannot escape the catalog", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome")
      choose(view)

      original =
        Map.take(assigns(view), [
          :selected_models,
          :default_model,
          :selected_entry,
          :model_reasoning
        ])

      render_click(view, "select_welcome_model", %{"model_string" => model_string(:google)})
      render_click(view, "select_welcome_variant", %{"variant_id" => "not-a-variant"})
      render_change(view, "welcome_defaults_changed", %{"default_model" => model_string(:google)})

      render_change(view, "welcome_defaults_changed", %{
        "reasoning" => %{model_string(:anthropic) => "invented"}
      })

      render_change(view, "welcome_defaults_changed", %{
        "reasoning" => %{model_string(:google) => "high"}
      })

      assert Map.take(assigns(view), Map.keys(original)) == original
      html = render_click(view, "select_welcome_provider", %{"provider_id" => "not-a-provider"})
      assert html =~ "Unknown provider."
      assert assigns(view).selected_provider_id == :anthropic
    end

    test "save rereads the file and preserves unrelated settings and newly added profiles", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/welcome")
      choose(view)
      # A concurrent edit after mount must survive, including the id collision.
      seed_config("""
      [user]
      github_username = "keep-me"
      [llm]
      default_provider_profile = "anthropic-onboarding"
      [[llm.providers]]
      id = "anthropic-onboarding"
      provider = "anthropic"
      default_model = "#{hd(provider(:anthropic).models).id}"
      [[llm.providers.models]]
      model = "#{hd(provider(:anthropic).models).id}"
      """)

      success_flash(save(view))
      config = read_config()
      assert config["user"]["github_username"] == "keep-me"
      assert [existing, added] = config["llm"]["providers"]
      assert existing["id"] == "anthropic-onboarding"
      assert added["id"] == "anthropic-onboarding-2"
      assert config["llm"]["default_provider_profile"] == added["id"]
      refute Map.has_key?(config["llm"], "models")
    end

    test "a malformed concurrent file is not overwritten and credentials are not written", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/welcome")
      choose(view)
      seed_config("[broken")
      html = view |> form("#welcome-save", %{"api_key" => "must-not-save"}) |> render_submit()
      assert html =~ "Cannot read configuration:"
      assert File.read!(EvoGit.Config.config_path()) == "[broken"
      refute File.exists?(EvoGit.Config.credentials_path())
      refute assigns(view).has_model?
    end
  end

  describe "OAuth authentication" do
    test "Anthropic subscription saves a provider without creating credentials", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome")
      choose(view)
      render_change(view, "api_key_changed", %{"api_key" => "discard-me"})
      html = view |> form("#welcome-auth", %{"auth_mode" => "oauth"}) |> render_change()
      assert assigns(view).api_key_input == ""
      assert html =~ "No API key is required."
      assert html =~ EvoGit.Auth.login_instructions(:anthropic)
      refute has_element?(view, "input[name=api_key]")
      refute has_element?(view, "#welcome-save button[disabled]")
      success_flash(view |> form("#welcome-save") |> render_submit())
      assert [profile] = read_config()["llm"]["providers"]
      assert profile["auth_mode"] == "oauth"
      assert profile["provider"] == "anthropic"
      refute File.exists?(EvoGit.Config.credentials_path())
    end

    test "OAuth-only Codex offers no key mode and tests the selected default through OAuth options",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome")
      html = choose(view, :openai_codex)
      assert assigns(view).auth_mode == "oauth"
      assert html =~ "Subscription (OAuth)"
      assert html =~ EvoGit.Auth.login_instructions(:openai_codex)
      refute has_element?(view, "#welcome-auth-mode")
      refute has_element?(view, "input[name=api_key]")
      render_change(view, "welcome_auth_changed", %{"auth_mode" => "api_key"})
      assert assigns(view).auth_mode == "oauth"
      render_click(view, "test_llm")
      assert_receive {:welcome_test_started, pid, model, opts}, @runner_start_timeout
      assert model == model_string(:openai_codex)
      assert opts[:provider_options][:auth_mode] == :oauth
      assert opts[:provider_options][:oauth_file] == EvoGit.Auth.default_oauth_file()
      finish_test(view, pid, {:ok, %{response: "hello"}})
      success_flash(view |> form("#welcome-save") |> render_submit())
      assert [profile] = read_config()["llm"]["providers"]
      assert profile["auth_mode"] == "oauth"
      assert profile["provider"] == "openai_codex"
      refute File.exists?(EvoGit.Config.credentials_path())
    end

    test "auth switching clears key drafts and non-OAuth providers reject forged OAuth", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/welcome")
      choose(view)
      render_change(view, "welcome_auth_changed", %{"auth_mode" => "oauth"})
      render_change(view, "welcome_auth_changed", %{"auth_mode" => "api_key"})
      assert assigns(view).auth_mode == "api_key"
      assert has_element?(view, "#welcome-save button[disabled]")
      choose(view, :google)
      render_change(view, "welcome_auth_changed", %{"auth_mode" => "oauth"})
      assert assigns(view).auth_mode == "api_key"
      refute has_element?(view, "#welcome-auth-mode")
    end
  end

  describe "variants and search" do
    test "variants default to first and switching resets the whole draft", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome")
      a = provider(:alibaba)
      assert a.variants != []
      html = render_click(view, "select_welcome_provider", %{"provider_id" => "alibaba"})
      assert html =~ "Select a variant:"
      for v <- a.variants, do: assert(has_element?(view, "button[phx-value-variant_id=#{v.id}]"))
      assert assigns(view).selected_variant_id == hd(a.variants).id
      assert html =~ model_string(:alibaba)
      refute html =~ "alibaba_cn:"
      render_click(view, "select_welcome_model", %{"model_string" => model_string(:alibaba)})
      render_change(view, "api_key_changed", %{"api_key" => "discard-me"})
      render_change(view, "search_models", %{"search_query" => "qwen"})
      html = render_click(view, "select_welcome_variant", %{"variant_id" => "cn"})
      assert html =~ model_string(:alibaba, :cn)
      assert html =~ " · CN"
      refute html =~ model_string(:alibaba)
      assert assigns(view).selected_models == []
      assert assigns(view).model_reasoning == %{}
      assert assigns(view).api_key_input == ""
      assert assigns(view).search_query == ""
      assert assigns(view).llm_test_status == :idle
    end

    test "CN save uses the variant's provider and credential, not hidden submitted selectors", %{
      conn: conn
    } do
      seed_credentials(~s(alibaba_cn_api_key = "sk-test-cn"\n))
      {:ok, view, _} = live(conn, ~p"/welcome")
      choose(view, :alibaba, :cn)

      html =
        render_submit(view, "save_welcome_setup", %{
          "api_key" => "",
          "provider_id" => "anthropic",
          "model_string" => model_string(:anthropic),
          "credential_key" => "anthropic_api_key",
          "variant_id" => ""
        })

      success_flash(html)
      assert [profile] = read_config()["llm"]["providers"]
      assert profile["provider"] == "alibaba_cn"
      assert profile["default_model"] == hd(provider(:alibaba).models).id
      assert EvoGit.Config.credentials()["alibaba_cn_api_key"] == "sk-test-cn"
      refute Map.has_key?(EvoGit.Config.credentials(), "anthropic_api_key")
    end

    test "search is scoped to the provider, case insensitive and clearing restores all models", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/welcome")
      render_click(view, "select_welcome_provider", %{"provider_id" => "google"})

      html =
        render_change(view, "search_models", %{
          "search_query" => hd(provider(:anthropic).models).display_name
        })

      assert html =~ "No models match your search."
      assert html =~ "Settings page"
      {needle, matched, unmatched} = filter_triple(provider(:google).models)
      html = render_change(view, "search_models", %{"search_query" => String.downcase(needle)})
      assert html =~ matched.display_name
      refute html =~ unmatched.display_name
      html = render_change(view, "search_models", %{"search_query" => ""})
      for m <- provider(:google).models, do: assert(html =~ m.display_name)
      refute html =~ "No models match your search."
    end

    test "search matches variant name and Settings guidance begins only after provider selection",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/welcome")
      refute html =~ "Settings page"
      render_click(view, "select_welcome_provider", %{"provider_id" => "alibaba"})

      html =
        render_change(view, "search_models", %{
          "search_query" => hd(provider(:alibaba).variants).display_name
        })

      assert html =~ hd(provider(:alibaba).models).display_name
      assert has_element?(view, "a[href='/settings']", "Settings page")
    end

    test "normal providers submit only a hidden base URL", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome")
      html = choose(view)
      refute html =~ "Required for this provider."
      refute has_element?(view, "input[type=url]")
      assert has_element?(view, "#welcome-save input[type=hidden][name=base_url]")
    end
  end

  describe "navigation and configured state" do
    for kind <- [:provider, :legacy] do
      @kind kind
      test "#{kind} configuration shows all-set and get_started redirects to completion", %{
        conn: conn
      } do
        text =
          case @kind do
            :provider ->
              """
              [llm]
              default_provider_profile = "configured"
              [[llm.providers]]
              id = "configured"
              provider = "anthropic"
              default_model = "#{hd(provider(:anthropic).models).id}"
              [[llm.providers.models]]
              model = "#{hd(provider(:anthropic).models).id}"
              """

            :legacy ->
              """
              [[llm.models]]
              id = "configured"
              model = "#{model_string(:anthropic)}"
              concurrency = 3
              """
          end

        seed_config(text)
        {:ok, view, html} = live(conn, ~p"/welcome")
        assert html =~ "You&#39;re All Set!"
        assert has_element?(view, "button", "Go to Dashboard")
        assert html =~ "Open Settings"
        assert html =~ "history.back()"
        refute html =~ "Add your first LLM"
        refute has_element?(view, "#welcome-save")
        render_click(view, "get_started")
        assert_redirect(view, "/welcome/complete")
        # Merely visiting onboarding must not persist resolved/migrated defaults.
        assert File.read!(EvoGit.Config.config_path()) == text
      end
    end

    test "remote contexts show local-only guidance and refuse draft changes, writes and tests", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, ~p"/welcome")
      choose(view)

      socket =
        :sys.get_state(view.pid).socket
        |> Phoenix.Component.assign(:current_node_id, "remote-target")

      html = render_component(&EvoDashWeb.WelcomeLive.render/1, socket.assigns)
      assert html =~ "Welcome setup configures this machine only."
      refute html =~ "Add your first LLM"
      refute html =~ "Save provider and models"

      original =
        Map.take(socket.assigns, [
          :selected_models,
          :selected_provider_id,
          :auth_mode,
          :api_key_input
        ])

      for {event, params} <- [
            {"select_welcome_provider", %{"provider_id" => "google"}},
            {"welcome_auth_changed", %{"auth_mode" => "oauth"}},
            {"api_key_changed", %{"api_key" => "must-not-save"}},
            {"save_welcome_setup", %{"api_key" => "must-not-save"}},
            {"test_llm", %{}}
          ] do
        assert {:noreply, guarded} = EvoDashWeb.WelcomeLive.handle_event(event, params, socket)
        assert guarded.assigns.flash["error"] == "Use Settings to configure the remote node."
        assert Map.take(guarded.assigns, Map.keys(original)) == original
      end

      seq = socket.assigns.llm_test_seq

      # SafeCall wraps the worker result; even a current sequence cannot apply
      # a local onboarding result after the viewed target changes to remote.
      assert {:noreply, unchanged} =
               EvoDashWeb.WelcomeLive.handle_info(
                 {{:welcome_llm_test_result, seq}, {:ok, {:ok, %{}}}},
                 socket
               )

      assert unchanged.assigns.llm_test_status == :idle
      refute File.exists?(EvoGit.Config.config_path())
      refute File.exists?(EvoGit.Config.credentials_path())
      refute_receive {:welcome_test_started, _, _, _}, 0
    end

    test "skip reaches completion and Back retains browser-history fallback", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/welcome")
      assert html =~ "Back"
      assert html =~ "hero-arrow-left"
      assert html =~ "history.back()"
      assert html =~ "window.location.href = &#39;/&#39;;"
      render_click(view, "skip")
      assert_redirect(view, "/welcome/complete")
    end
  end

  describe "connection test contract" do
    test "no selection or key cannot start a connection test", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome")
      refute has_element?(view, "button[phx-click=test_llm]")
      html = render_click(view, "test_llm")
      assert html =~ "Choose models and a default model from the selected provider."
      choose(view)
      assert has_element?(view, "button[phx-click=test_llm][disabled]")
      html = render_click(view, "test_llm")
      assert html =~ "Please enter your API key first."
      assert assigns(view).llm_test_status == :idle
      refute_receive {:welcome_test_started, _, _, _}, 0
    end

    test "typed key is saved before the runner; spinner, success and retry failure render", %{
      conn: conn
    } do
      preserve_key(:anthropic_api_key)
      {:ok, view, _} = live(conn, ~p"/welcome")
      choose(view)
      render_change(view, "api_key_changed", %{"api_key" => "sk-ant-typed"})
      html = render_click(view, "test_llm")
      assert html =~ "Testing LLM connection..."
      assert html =~ "loading loading-spinner"
      assert has_element?(view, "button[phx-click=test_llm][disabled]")
      assert_receive {:welcome_test_started, pid, model, opts}, @runner_start_timeout
      assert model == model_string(:anthropic)
      assert is_list(opts)
      assert EvoGit.Config.credentials()["anthropic_api_key"] == "sk-ant-typed"
      assert assigns(view).api_key_input == ""
      refute File.exists?(EvoGit.Config.config_path())
      result = {:ok, %{model: model, response: "hello"}}
      html = finish_test(view, pid, result)
      assert html =~ "Connected"
      assert html =~ hd(provider(:anthropic).models).display_name
      refute has_element?(view, "button[phx-click=test_llm][disabled]")

      render_click(view, "test_llm")
      assert_receive {:welcome_test_started, retry_pid, ^model, _}, @runner_start_timeout
      html = finish_test(view, retry_pid, {:error, "Invalid API key"})
      assert html =~ "Invalid API key"
      refute html =~ "Connected"
      assert has_element?(view, "button[phx-click=test_llm]", "Test Connection")
    end

    test "tests the default model and reasoning, ignores obsolete results and invalidates changed drafts",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/welcome")
      choose(view)
      render_change(view, "welcome_auth_changed", %{"auth_mode" => "oauth"})
      second = model_string(:anthropic, nil, 1)
      render_click(view, "select_welcome_model", %{"model_string" => second})
      entry = Enum.find(assigns(view).flat_models, &(&1.model_string == second))
      effort = List.last(Setup.reasoning_efforts(entry))

      render_change(view, "welcome_defaults_changed", %{
        "default_model" => second,
        "reasoning" => %{second => effort}
      })

      render_click(view, "test_llm")
      assert_receive {:welcome_test_started, pid, ^second, opts}, @runner_start_timeout
      assert opts[:reasoning_effort] == String.to_existing_atom(effort)
      assert opts[:provider_options][:auth_mode] == :oauth
      seq = assigns(view).llm_test_seq
      success = {:ok, %{response: "hello"}}
      send(view.pid, {:llm_test_result, success})
      send(view.pid, {{:welcome_llm_test_result, seq - 1}, {:ok, success}})
      assert assigns(view).llm_test_status == :testing
      finish_test(view, pid, success)

      render_click(view, "select_welcome_model", %{"model_string" => model_string(:anthropic)})
      assert assigns(view).llm_test_status == :idle
      render_click(view, "select_welcome_model", %{"model_string" => model_string(:anthropic)})
      send(view.pid, {{:welcome_llm_test_result, assigns(view).llm_test_seq}, {:ok, success}})
      assert render(view) =~ "Connected"

      render_change(view, "welcome_defaults_changed", %{
        "default_model" => model_string(:anthropic)
      })

      assert assigns(view).llm_test_status == :idle
      send(view.pid, {{:welcome_llm_test_result, seq}, {:ok, success}})
      assert assigns(view).llm_test_status == :idle
      send(view.pid, {{:welcome_llm_test_result, assigns(view).llm_test_seq}, {:ok, success}})
      assert render(view) =~ "Connected"
      render_click(view, "select_welcome_provider", %{"provider_id" => "google"})
      assert assigns(view).llm_test_status == :idle
      assert assigns(view).selected_models == []
      assert assigns(view).default_model == nil
      assert assigns(view).model_reasoning == %{}
      assert assigns(view).auth_mode == "api_key"
      refute has_element?(view, "button[phx-click=test_llm]")
    end
  end
end

defmodule EvoDashWeb.WelcomeLiveTest.TaskBroadcast do
  # This module publishes on the global "tasks" PubSub topic, arming every
  # mounted page's NodeAware debounce; it must run after async suites drain.
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    EvoDash.Test.ConfigDir.isolate!("evogit_welcome_test_config")
    :ok
  end

  test "task finalizing broadcast does not crash the LiveView", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/welcome")

    Phoenix.PubSub.broadcast(
      EvoGit.PubSub,
      "tasks",
      {:task_updated, "test-finalizing", :finalizing, node()}
    )

    assert render(view) =~ "Welcome to Genesis"
  end
end
