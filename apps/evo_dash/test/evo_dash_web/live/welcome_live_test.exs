defmodule EvoDashWeb.WelcomeLiveTest do
  # Config files are per-process isolated (`EvoDash.Test.ConfigDir`), and the
  # connection-test runner seam is owned exclusively by this module and never
  # calls a provider. The global "tasks" publisher lives in the sync module at
  # the bottom of this file.
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias EvoGit.Config.LLMCatalog, as: Catalog
  alias EvoDashWeb.LLMSetup.Reasoning
  alias EvoDashWeb.SettingsLive.ChatGPTSignInState
  alias EvoDashWeb.WelcomeLive.Presentation

  # Canonical resolution can cold-load the model catalog before reaching the
  # stub; keep that startup budget separate from the blocked runner's reply.
  @runner_start_timeout 30_000
  # Load-tolerant budget for the bounded poll that waits for an async result to
  # reach the LiveView. The wait stays bounded and still fails loudly.
  # EVERY cross-process stub notification in this file is asserted on this
  # budget, `begin` and `cancel` included: they are emitted from inside the
  # flow call's own `Task.async` (bounded by the product's 15 s call timeout,
  # NOT by the event handler that awaits it), so a second-scale budget here
  # would be a latency assumption rather than a correctness bound.
  @async_wait_budget_ms 30_000
  # `:sys.get_state/2` timeout for `assigns/1`: the LiveView can be starved for
  # seconds on a loaded host, where the 5 s default exits the test.
  @assigns_timeout_ms 30_000
  @anthropic_key "sk-ant-welcome-test-123"
  @custom_base_url "https://api.example.test/v1"
  @custom_key "sk-openai-compatible-test-123"
  # The authorization URL the sign-in stub mints (see the stub module below).
  @sign_in_url "https://auth.example.test/authorize"

  setup do
    EvoDash.Test.ConfigDir.isolate!("evogit_welcome_test_config")
    File.mkdir_p!(EvoGit.Config.config_dir())
    owner = self()
    previous_runner = Application.fetch_env(:evo_dash, :welcome_llm_test_runner)

    # Block until the test explicitly releases the call: the spinner, the
    # options and the stale-result assertions stay deterministic, with no real
    # HTTP request and no ambient credential use.
    Application.put_env(:evo_dash, :welcome_llm_test_runner, fn model, opts ->
      send(owner, {:welcome_test_started, self(), model, opts})

      receive do
        {:finish, :raise} -> raise "provider unreachable"
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

    # A save writes the credential file, which mirrors the key into ReqLLM's
    # application env; restore every key this suite can touch.
    for key <- [:anthropic_api_key, :deepseek_api_key, :openai_api_key, :zai_api_key] do
      preserve_key(key)
    end

    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────
  defp assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns
  defp provider(id), do: Enum.find(Catalog.providers(), &(&1.id == id))
  defp model_id(id, index \\ 0), do: Enum.at(provider(id).models, index).id

  defp model_display_name(id, index \\ 0),
    do: Enum.at(provider(id).models, index).display_name

  defp stored_credentials do
    path = EvoGit.Config.credentials_path()
    if File.exists?(path), do: File.read!(path), else: ""
  end

  defp model_string(id, variant_id \\ nil, index \\ 0),
    do: "#{Catalog.resolve_provider_atom(id, variant_id)}:#{model_id(id, index)}"

  defp start(conn), do: live(conn, ~p"/welcome")

  # Event helpers act on the view and hand it BACK, because `render_click/3`
  # answers the rendered HTML (not the view).
  defp pick(view, provider_id) do
    render_click(view, "select_wizard_provider", %{"provider" => provider_id})
    view
  end

  defp next(view) do
    render_click(view, "wizard_next")
    view
  end

  defp back(view) do
    render_click(view, "wizard_back")
    view
  end

  defp click(view, event, params \\ %{}) do
    render_click(view, event, params)
    view
  end

  defp change(view, event, params) do
    render_change(view, event, params)
    view
  end

  defp choose_model(view, id, index \\ 0) do
    render_click(view, "select_wizard_model", %{"model" => model_string(id, nil, index)})
    view
  end

  # DeepSeek declares a single auth mode, so its run has no auth step; an
  # existing credential satisfies the save's key gate.
  defp deepseek_to_reasoning(view, index \\ 0) do
    pick(view, "deepseek")
    choose_model(view, :deepseek, index)
    next(view)
  end

  # Anthropic offers API key and subscription, so its run has the auth step.
  defp anthropic_to_reasoning(view, key \\ @anthropic_key) do
    pick(view, "anthropic")
    render_change(view, "wizard_api_key", %{"api_key" => key})
    next(view)
    choose_model(view, :anthropic, 0)
    next(view)
  end

  defp custom_to_model(view) do
    pick(view, Presentation.custom_value())
    view |> form("#wizard-provider-form", base_url: @custom_base_url) |> render_change()
    next(view)
    view |> form("#wizard-auth-key-form", api_key: @custom_key) |> render_change()
    view
  end

  defp read_config do
    {:ok, config} =
      EvoGit.Config.config_path() |> File.read!() |> TomlElixir.decode()

    config
  end

  defp accounts, do: get_in(read_config(), ["llm", "providers"]) |> List.wrap()
  defp account(id), do: Enum.find(accounts(), &(&1["id"] == id))

  defp seed_config(config) do
    case EvoGit.Config.save_user_config(config) do
      :ok -> :ok
      {:error, errors} -> flunk("seeded config failed validation: #{inspect(errors)}")
    end
  end

  defp seed_credential(key, value), do: EvoGit.Config.save_credentials(%{key => value})

  defp preserve_key(key) do
    previous = Application.fetch_env(:req_llm, key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:req_llm, key, value)
        :error -> Application.delete_env(:req_llm, key)
      end
    end)
  end

  # The page keeps the provider's OWN answer (`{:ok, detail}` / `{:error, reason}`)
  # and the test step projects it through `Presentation.test_status/1`, so the
  # awaited value is the RENDERED status — `{:ok, "<model> · <response>"}`.
  defp await_status(view, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @async_wait_budget_ms

    if Presentation.test_status(assigns(view).llm_test_status) != expected do
      assert System.monotonic_time(:millisecond) < deadline,
             "connection result did not reach the LiveView"

      Process.sleep(2)
      await_status(view, expected, deadline)
    end
  end

  # A deadline-bounded wait for an ASYNC result to reach the LiveView. The
  # condition is re-evaluated against fresh state, and the wait fails loudly
  # instead of asserting on a state that simply has not arrived yet.
  defp await(fun, deadline \\ nil) when is_function(fun, 0) do
    deadline = deadline || System.monotonic_time(:millisecond) + @async_wait_budget_ms

    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "the expected page state did not arrive"

      Process.sleep(2)
      await(fun, deadline)
    end
  end

  # Bounded wait for an APPLIED *terminal* phase (`:error`).
  #
  # NEVER use this for `:waiting`: the page assigns it SYNCHRONOUSLY inside the
  # `chatgpt_sign_in` handler (`ChatGPTSignIn.begin/1` is a bounded call the
  # handler awaits before the assign), so the triggering click's OWN render
  # already carries the waiting markup — pin that render instead. Awaiting an
  # INTERMEDIATE phase is a racy barrier by construction: any later poll tick
  # that settles the phase (including a flow call that fails under load) makes
  # it unobservable. `Map.get/2` keeps the read total for the initial `%{}` state.
  defp await_sign_in_phase(view, phase) do
    await(fn -> Map.get(assigns(view).chatgpt_sign_in, :phase) == phase end)
    view
  end

  # Selector membership on a CAPTURED render (`render_click/1` answers the whole
  # view): the ONE instrument for a state pinned at event time instead of read
  # later. Same helper the settings sign-in surface suite uses.
  defp rendered?(html, selector),
    do: html |> Floki.parse_fragment!() |> Floki.find(selector) != []

  # Drains the poll notifications the stub already sent, so a following
  # `assert_receive` proves a status call made AFTER the test changed its mind.
  # Each notification carries the answer that call READ.
  defp flush_signin_status do
    receive do
      {:signin_stub, {:status, _flow_id, _answer}} -> flush_signin_status()
    after
      0 -> :ok
    end
  end

  # The reasoning step's chip and select inventories, read off the RENDERED DOM
  # (the wizard's view assigns are prepared in `render/1`, not the socket).
  # Attribute matching is done in Elixir, so the `reasoning_efforts[]` name never
  # has to survive a CSS selector parser.
  defp doc(view), do: view |> render() |> Floki.parse_document!()

  defp chip_inputs(view) do
    view
    |> doc()
    |> Floki.find("input")
    |> Enum.filter(fn input ->
      Floki.attribute(input, "name") == ["reasoning_efforts[]"] and
        Floki.attribute(input, "type") == ["checkbox"]
    end)
  end

  defp chip_values(view) do
    view |> chip_inputs() |> Enum.map(&Floki.attribute(&1, "value")) |> List.flatten()
  end

  defp checked_chip_values(view) do
    view
    |> chip_inputs()
    |> Enum.filter(&(Floki.attribute(&1, "checked") != []))
    |> Enum.map(&Floki.attribute(&1, "value"))
    |> List.flatten()
  end

  defp select_values(view) do
    view
    |> doc()
    |> Floki.find("select#default-reasoning-effort option")
    |> Enum.map(&Floki.attribute(&1, "value"))
    |> List.flatten()
  end

  # ── mount ──────────────────────────────────────────────────────────────────
  describe "wizard shell" do
    test "mounts the rebuilt wizard showing only the provider step", %{conn: conn} do
      {:ok, view, html} = start(conn)

      assert html =~ "Welcome to Genesis"
      assert html =~ "Genesis #{Application.spec(:evo_git, :vsn)}"
      assert has_element?(view, ~s(.wizard-progress[aria-label="Setup progress"]))
      assert html =~ "Step 1 of 6"
      assert has_element?(view, "#wizard-step-provider")
      assert html =~ "Choose a provider"
      assert html =~ "Where should Genesis send its requests?"

      # Only the current step body renders.
      refute has_element?(view, "#wizard-step-auth")
      refute has_element?(view, "#wizard-step-model")
      refute has_element?(view, "#wizard-step-reasoning_schedule")

      # Provider cards come from the catalog (custom-model rows excluded), plus
      # the shared OpenAI-compatible endpoint card.
      for option <- Presentation.provider_options(Catalog.providers()) do
        assert has_element?(view, ~s([phx-value-provider="#{option["id"]}"]))
      end

      assert has_element?(
               view,
               ~s([phx-value-provider="#{Presentation.custom_value()}"])
             )

      assert html =~ "Custom / OpenAI-compatible endpoint"
      # The endpoint URL field belongs to the SELECTED custom card, so the
      # catalog view never renders it.
      refute has_element?(view, "#base-url-input")

      # Footer: Back is clamped on the first step; Skip leaves the wizard.
      assert has_element?(view, ~s(button[phx-click="wizard_back"][disabled]))
      assert has_element?(view, ~s(button[phx-click="wizard_next"]))
      assert has_element?(view, ~s(button[phx-click="skip"]))
      refute has_element?(view, "#welcome-save")
      refute has_element?(view, "#welcome-defaults")
    end

    test "clamps the rail and Back on the first step", %{conn: conn} do
      {:ok, view, _html} = start(conn)

      back(view)

      html = render(view)
      assert html =~ "Step 1 of 6"
      assert has_element?(view, "#wizard-step-provider")
    end

    test "skip and get_started both reach /welcome/complete", %{conn: conn} do
      {:ok, view, _html} = start(conn)
      render_click(view, "skip")
      assert_redirect(view, "/welcome/complete")
    end
  end

  # ── gated navigation ───────────────────────────────────────────────────────
  describe "step order and gated navigation" do
    test "cannot leave the provider step without a provider", %{conn: conn} do
      {:ok, view, _html} = start(conn)

      next(view)

      html = render(view)
      assert html =~ "Choose a provider before continuing."
      assert has_element?(view, "#wizard-step-provider")
      # A refused gate writes nothing.
      refute File.exists?(EvoGit.Config.config_path())
    end

    test "a custom endpoint needs its URL before the model step", %{conn: conn} do
      {:ok, view, _html} = start(conn)

      pick(view, Presentation.custom_value())

      html = render(view)
      assert html =~ "Step 1 of 5"
      assert has_element?(view, "#wizard-step-provider")

      next(view)

      html = render(view)
      assert html =~ "Enter the endpoint URL for this provider."
      assert has_element?(view, "#wizard-step-provider")
    end

    test "walks provider → auth → model → reasoning → test and back with the draft intact",
         %{conn: conn} do
      {:ok, view, _html} = start(conn)

      pick(view, "anthropic")

      html = render(view)
      assert html =~ "Step 2 of 6"
      assert html =~ "Choose authentication"
      assert has_element?(view, "#wizard-step-auth")

      change(view, "wizard_api_key", %{"api_key" => @anthropic_key})
      next(view)
      html = render(view)
      assert html =~ "Step 3 of 6"
      assert html =~ "Pick a model"

      # The model gate refuses an empty selection.
      next(view)
      html = render(view)
      assert html =~ "Pick a model or enter a custom model name."
      assert has_element?(view, "#wizard-step-model")

      view = choose_model(view, :anthropic)
      next(view)
      html = render(view)
      assert html =~ "Step 4 of 6"
      assert html =~ "Reasoning &amp; schedule"

      next(view)

      html = render(view)
      assert html =~ "Step 5 of 6"
      assert html =~ "Test the connection"
      assert has_element?(view, ~s(button[phx-click="test_connection"]))
      assert has_element?(view, ~s(button[phx-click="skip_test"]))
      assert has_element?(view, ~s(button[phx-click="wizard_next"]))
      assert html =~ "Save and finish"

      # Back walks the same run, keeping the draft.
      back(view)
      html = render(view)
      assert html =~ "Step 4 of 6"

      back(view)

      html = render(view)
      assert html =~ "Step 3 of 6"

      assert has_element?(
               view,
               ~s([phx-value-model="#{model_string(:anthropic)}"][aria-current="true"])
             )

      back(view)

      html = render(view)
      assert html =~ "Step 2 of 6"
      assert assigns(view).draft["api_key"] == @anthropic_key

      back(view)

      html = render(view)
      assert html =~ "Step 1 of 6"
      assert has_element?(view, ~s([phx-value-provider="anthropic"][aria-pressed="true"]))
    end

    test "ChatGPT signs in, selects a registration and tests its available model", %{conn: conn} do
      {:ok, view, _html} = start(conn)
      pick(view, "openai_codex")

      assert has_element?(view, "#wizard-step-auth")
      assert has_element?(view, ~s(button[phx-click="wizard_next"][disabled]))
      refute has_element?(view, "#wizard-api-key")

      EvoGit.TestSupport.ChatGPTFixture.seed!("default")

      EvoGit.TestSupport.ChatGPTFixture.seed!("work", %{
        "models" => [%{"slug" => "work-model", "display_name" => "Work model"}]
      })

      view |> element("#welcome-chatgpt-refresh") |> render_click()
      view |> form("#welcome-chatgpt-form", %{"siwc_account" => "work"}) |> render_change()
      next(view)

      assert has_element?(view, "#wizard-step-model")
      assert has_element?(view, ~s(button[phx-value-model="openai_codex:work-model"]))
      refute has_element?(view, ~s(button[phx-value-model="openai_codex:gpt-5.6-terra"]))
      refute has_element?(view, "#wizard-custom-model-form")

      view
      |> element(~s(button[phx-value-model="openai_codex:work-model"]))
      |> render_click()

      next(next(view))
      render_click(view, "test_connection")

      assert_receive {:welcome_test_started, worker, "openai_codex:work-model", opts},
                     @runner_start_timeout

      assert opts[:provider_options][:siwc_account] == "work"
      refute Keyword.has_key?(opts[:provider_options], :access_token)
      send(worker, {:finish, {:ok, %{response: "Hello"}}})

      assert render_click(view, "skip_test") =~ "Provider and models saved."
      entry = account("openai-codex")
      assert entry["provider"] == "openai_codex"
      assert entry["auth_mode"] == "oauth"
      assert entry["siwc_account"] == "work"
      assert entry["default_model"] == "work-model"
      assert stored_credentials() == ""
    end

    test "add_another_provider restarts at the provider step", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)
      view = next(deepseek_to_reasoning(view))
      html = render_click(view, "skip_test")
      assert html =~ "You&#39;re all set"
      assert has_element?(view, ~s(button[phx-click="add_another_provider"]))

      html = render_click(view, "add_another_provider")
      assert html =~ "Step 1 of 6"
      assert has_element?(view, "#wizard-step-provider")
      assert has_element?(view, ~s(button[phx-click="wizard_back"][disabled]))
    end
  end

  # ── in-browser ChatGPT sign-in ─────────────────────────────────────────────
  describe "ChatGPT in-browser sign-in" do
    setup do
      # `EvoDashWeb.LLMSetup.ChatGPTSignIn.login_module/0` resolves the flow
      # module per process (this pid, then `$callers`, then app env) and
      # `Phoenix.LiveViewTest` puts the test pid in the mounted view's
      # `$callers`, so a module-local stub needs no BEAM-global mutation.
      Process.put(:chatgpt_login_module, __MODULE__.SignInStub)
      # A short poll keeps the test cheap. The stub answers `:pending` until a
      # test flips its result, so the WAITING state is deterministic instead of
      # racing the poll.
      Process.put(:chatgpt_signin_poll_interval_ms, 5)
      :ok
    end

    test "signs in from the browser and selects the connected account", %{conn: conn} do
      EvoGit.TestSupport.ChatGPTFixture.seed!("work")

      {:ok, view, _html} = start(conn)
      pick(view, "openai_codex")

      assert has_element?(view, "#wizard-step-auth")
      assert has_element?(view, "#welcome-chatgpt-sign-in")
      # Local view: the real in-browser flow, never the CLI instruction.
      refute has_element?(view, "#welcome-chatgpt-manual-hint")
      refute assigns(view).chatgpt_sign_in_manual
      # Nothing is connected yet, so the step gate holds.
      assert has_element?(view, ~s(button[phx-click="wizard_next"][disabled]))

      # The page assigns `:waiting` SYNCHRONOUSLY inside the click handler
      # (`ChatGPTSignIn.begin/1` is a bounded call the handler awaits before the
      # assign), so the click's OWN render is the one snapshot atomic with that
      # phase — every waiting-state read (markup, authorization link) is taken
      # from it. Awaiting `:waiting` on the live page would race the poll's
      # first tick, which can already have settled the phase.
      click_html = view |> element("#welcome-chatgpt-sign-in") |> render_click()
      assert rendered?(click_html, "#welcome-chatgpt-waiting")
      assert has_element?(view, "#welcome-chatgpt-waiting")
      # The draft has no pick yet, so the store default is signed in.
      assert_receive {:signin_stub, {:begin, "default"}}, @async_wait_budget_ms
      refute has_element?(view, "#welcome-chatgpt-sign-in")

      link =
        click_html
        |> Floki.parse_document!()
        |> Floki.find("#welcome-chatgpt-sign-in-url")
        |> List.first()

      assert Floki.attribute(link, "href") == [@sign_in_url]
      assert Floki.attribute(link, "target") == ["_blank"]
      assert Floki.attribute(link, "rel") |> List.first() =~ "noopener"

      # The browser grants the registration: wait for the poll tick that READ
      # the terminal result (an async tick, hence the load-tolerant budget).
      Process.put(:signin_stub_statuses, %{"welcome-flow" => {:ok, %{account: "work"}}})

      assert_receive {:signin_stub, {:status, "welcome-flow", {:ok, %{account: "work"}}}},
                     @async_wait_budget_ms

      await(fn ->
        has_element?(view, ~s(#welcome-chatgpt-account option[value="work"][selected]))
      end)

      assert assigns(view).draft["siwc_account"] == "work"
      assert assigns(view).chatgpt_sign_in == %{phase: :ok}
      refute has_element?(view, "#welcome-chatgpt-waiting")
      refute has_element?(view, "#welcome-chatgpt-sign-in-error")
      assert has_element?(view, ~s(#welcome-chatgpt-account option[value="work"][selected]))
      refute has_element?(view, ~s(button[phx-click="wizard_next"][disabled]))

      next(view)
      assert has_element?(view, "#wizard-step-model")
    end

    test "cancelling returns to the sign-in button and stops the flow", %{conn: conn} do
      {:ok, view, _html} = start(conn)
      pick(view, "openai_codex")
      click_html = view |> element("#welcome-chatgpt-sign-in") |> render_click()
      # `:waiting` is assigned SYNCHRONOUSLY by the click, so it is pinned on the
      # click's own render and never awaited (`await_sign_in_phase/2`).
      assert rendered?(click_html, "#welcome-chatgpt-waiting")

      assert has_element?(view, "#welcome-chatgpt-waiting")
      assert_receive {:signin_stub, {:begin, "default"}}, @async_wait_budget_ms

      view |> element("#welcome-chatgpt-sign-in-cancel") |> render_click()

      # The return to the sign-in button is the observable half of the cancel;
      # the stub's notification rides the flow call's own task, so it is
      # asserted after that state, on the load-tolerant budget.
      assert assigns(view).chatgpt_sign_in == %{phase: :idle}
      assert has_element?(view, "#welcome-chatgpt-sign-in")
      assert_receive {:signin_stub, {:cancel, "welcome-flow"}}, @async_wait_budget_ms
      refute has_element?(view, "#welcome-chatgpt-waiting")
      refute has_element?(view, "#welcome-chatgpt-sign-in-error")

      # The flow's own terminal result is now stale and must not resurrect the
      # waiting or error state. Wait for the tick that READ it: delivery of that
      # result races the two refutes below, and the flow-id stale guard itself is
      # pinned by "ignores a result for a flow it is not waiting for".
      flush_signin_status()
      Process.put(:signin_stub_statuses, %{"welcome-flow" => {:error, :cancelled}})

      assert_receive {:signin_stub, {:status, "welcome-flow", {:error, :cancelled}}},
                     @async_wait_budget_ms

      refute has_element?(view, "#welcome-chatgpt-waiting")
      refute has_element?(view, "#welcome-chatgpt-sign-in-error")
    end

    test "unmounting the page cancels a flow that is still waiting", %{conn: conn} do
      {:ok, view, _html} = start(conn)
      pick(view, "openai_codex")
      click_html = view |> element("#welcome-chatgpt-sign-in") |> render_click()
      assert rendered?(click_html, "#welcome-chatgpt-waiting")

      assert has_element?(view, "#welcome-chatgpt-waiting")
      assert_receive {:signin_stub, {:begin, "default"}}, @async_wait_budget_ms
      state = assigns(view).chatgpt_sign_in

      # Navigating away must close the loopback listener NOW, not leave it to the
      # flow's own ten-minute timeout: the state the page holds is exactly the
      # one the shared cancel entry point (the same one `/settings` uses) closes.
      assert %{phase: :waiting, flow_id: "welcome-flow"} = state
      assert ChatGPTSignInState.waiting?(state)
      assert ChatGPTSignInState.flow_id(state) == "welcome-flow"

      GenServer.stop(view.pid)

      # `GenServer.stop/1` is synchronous: `terminate/2` has already run, so the
      # waiting flow is gone. The cancel call itself rides the flow call's own
      # task, so its notification is asserted on the load-tolerant budget.
      assert_receive {:signin_stub, {:cancel, "welcome-flow"}}, @async_wait_budget_ms

      # The other phases this page assigns are never treated as waiting, so a
      # terminate after them closes nothing.
      refute ChatGPTSignInState.waiting?(%{phase: :ok})
      refute ChatGPTSignInState.waiting?(%{phase: :idle})
      refute ChatGPTSignInState.waiting?(%{})
    end

    test "unmounting the page with no waiting sign-in cancels nothing", %{conn: conn} do
      EvoGit.TestSupport.ChatGPTFixture.seed!("work")
      {:ok, view, _html} = start(conn)

      # (a) idle: no flow was ever started.
      GenServer.stop(view.pid)
      refute_receive {:signin_stub, {:cancel, _flow_id}}, 0

      # (b) the flow already reached its terminal `:ok` phase.
      {:ok, view, _html} = start(conn)
      pick(view, "openai_codex")
      click_html = view |> element("#welcome-chatgpt-sign-in") |> render_click()
      assert rendered?(click_html, "#welcome-chatgpt-waiting")
      assert has_element?(view, "#welcome-chatgpt-waiting")
      assert_receive {:signin_stub, {:begin, "default"}}, @async_wait_budget_ms

      Process.put(:signin_stub_statuses, %{"welcome-flow" => {:ok, %{account: "work"}}})
      await(fn -> assigns(view).chatgpt_sign_in == %{phase: :ok} end)

      GenServer.stop(view.pid)
      refute_receive {:signin_stub, {:cancel, _flow_id}}, 0
    end

    test "a refused or denied sign-in shows friendly text, never a raw reason", %{conn: conn} do
      Process.put(:signin_stub_begin, {:error, :loopback_listener_unavailable})

      {:ok, view, _html} = start(conn)
      pick(view, "openai_codex")
      view |> element("#welcome-chatgpt-sign-in") |> render_click()
      await_sign_in_phase(view, :error)

      html = render(view)
      assert has_element?(view, "#welcome-chatgpt-sign-in-error")
      assert html =~ "Genesis could not start a local sign-in"
      refute html =~ "loopback_listener_unavailable"
      refute has_element?(view, "#welcome-chatgpt-waiting")

      # A flow that starts and is then denied in the browser reports its own
      # friendly sentence in the same line.
      Process.put(:signin_stub_begin, {:ok, %{id: "welcome-flow-2", url: @sign_in_url}})

      click_html = view |> element("#welcome-chatgpt-sign-in") |> render_click()
      assert rendered?(click_html, "#welcome-chatgpt-waiting")
      assert has_element?(view, "#welcome-chatgpt-waiting")

      Process.put(:signin_stub_statuses, %{"welcome-flow-2" => {:error, :authorization_denied}})
      await(fn -> render(view) =~ "Sign-in was cancelled in the browser." end)

      html = render(view)
      assert has_element?(view, "#welcome-chatgpt-sign-in-error")
      refute html =~ "authorization_denied"
      refute has_element?(view, "#welcome-chatgpt-waiting")
    end

    test "ignores a result for a flow it is not waiting for", %{conn: conn} do
      EvoGit.TestSupport.ChatGPTFixture.seed!("work")

      {:ok, view, _html} = start(conn)
      pick(view, "openai_codex")

      send(view.pid, {:chatgpt_signin_result, "other-flow", {:ok, %{account: "work"}}})

      # Messages are handled in mailbox order, so the page rendered here is the
      # state AFTER the stale result was dropped.
      assert assigns(view).chatgpt_sign_in == %{}
      assert assigns(view).draft["siwc_account"] == nil
      refute has_element?(view, ~s(#welcome-chatgpt-account option[value="work"][selected]))
      refute has_element?(view, "#welcome-chatgpt-sign-in-error")
      assert has_element?(view, ~s(button[phx-click="wizard_next"][disabled]))
    end

    test "switching provider drops a waiting sign-in", %{conn: conn} do
      {:ok, view, _html} = start(conn)
      pick(view, "openai_codex")
      click_html = view |> element("#welcome-chatgpt-sign-in") |> render_click()
      assert rendered?(click_html, "#welcome-chatgpt-waiting")
      assert has_element?(view, "#welcome-chatgpt-waiting")

      pick(view, "anthropic")

      assert assigns(view).chatgpt_sign_in == %{}
      refute has_element?(view, "#welcome-chatgpt")
    end

    test "a provider without a ChatGPT sign-in never renders the control", %{conn: conn} do
      {:ok, view, _html} = start(conn)
      pick(view, "anthropic")

      assert has_element?(view, "#wizard-step-auth")
      refute has_element?(view, "#welcome-chatgpt")
      refute has_element?(view, "#welcome-chatgpt-sign-in")
      refute has_element?(view, "#welcome-chatgpt-manual-hint")
    end
  end

  # ── identity ───────────────────────────────────────────────────────────────
  describe "provider-derived account identity" do
    test "names the account after the provider and records the canonical entry", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)

      view = deepseek_to_reasoning(view)
      view = next(view)
      html = render_click(view, "skip_test")

      assert html =~ "Provider and models saved."
      entry = account("deepseek")
      assert entry["name"] == "DeepSeek"
      assert entry["provider"] == "deepseek"
      assert entry["auth_mode"] == "api_key"
      # The account default is the MODEL id, never the model's display name.
      assert entry["default_model"] == model_id(:deepseek)
      assert [%{"model" => model}] = entry["models"]
      assert model == model_id(:deepseek)
      assert read_config()["llm"]["default_provider_profile"] == "deepseek"
      # The credential rides the credentials file, never config.toml.
      assert File.read!(EvoGit.Config.credentials_path()) =~ "sk-deepseek-test"
      refute File.read!(EvoGit.Config.config_path()) =~ "sk-deepseek-test"
    end

    test "collision-proofs the id and name of a second account of one provider", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")

      seed_config(%{
        "llm" => %{
          "providers" => [
            %{
              "id" => "deepseek",
              "name" => "DeepSeek",
              "provider" => "deepseek",
              "auth_mode" => "api_key",
              "default_model" => model_id(:deepseek),
              "models" => [%{"model" => model_id(:deepseek)}]
            }
          ],
          "default_provider_profile" => "deepseek"
        }
      })

      {:ok, view, _html} = start(conn)
      view = next(deepseek_to_reasoning(view))
      render_click(view, "skip_test")

      entry = account("deepseek-2")
      assert entry["name"] == "DeepSeek-2"
      assert entry["provider"] == "deepseek"
      # The first account keeps its identity.
      assert account("deepseek")["name"] == "DeepSeek"
    end

    test "an OpenAI-compatible endpoint keeps its own identity, URL and custom model",
         %{conn: conn} do
      {:ok, view, _html} = start(conn)

      view = custom_to_model(view)
      change(view, "wizard_custom_model", %{"custom_model" => "my-model-x"})
      view = next(view)

      change(view, "wizard_reasoning", %{
        "reasoning_efforts" => ["low", "medium"],
        "default_reasoning_effort" => "medium"
      })

      view = next(view)
      html = render_click(view, "skip_test")
      assert html =~ "Provider and models saved."

      entry = account("openai-compatible")
      assert entry["name"] == "OpenAI-Compatible API"
      assert entry["provider"] == "openai_compatible"
      assert entry["base_url"] == @custom_base_url
      assert entry["default_model"] == "my-model-x"

      assert [model] = entry["models"]
      assert model["model"] == "my-model-x"
      assert model["reasoning_efforts"] == ["low", "medium"]
      assert model["default_reasoning_effort"] == "medium"

      # The credential key belongs to the OpenAI-compatible wire provider.
      assert File.read!(EvoGit.Config.credentials_path()) =~ "openai_api_key"
    end

    test "Z.ai does not collapse to the openai provider", %{conn: conn} do
      seed_credential("zai_api_key", "sk-zai-test")
      {:ok, view, _html} = start(conn)

      view = pick(view, "zai")
      # Z.ai publishes two variants, so the model has to be picked INSIDE the
      # variant that owns it (the model step scopes its rows to the draft's
      # variant); "Normal API" is the variant of `zai_api_key` and of the model
      # string the catalog exposes for it.
      view = click(view, "select_wizard_variant", %{"variant" => "normal"})
      view = choose_model(view, :zai, 0)
      view = next(next(view))
      assert render_click(view, "skip_test") =~ "Provider and models saved."

      [entry | _rest] = accounts()
      assert entry["provider"] == "zai"
      assert String.starts_with?(entry["id"], "zai")
      assert String.starts_with?(entry["name"], "Z.ai")
      refute entry["id"] =~ "openai"
    end
  end

  # ── multiple models ────────────────────────────────────────────────────────
  describe "multi-model capability" do
    test "saves a second model row that keeps its own inventory", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)

      view = pick(view, "deepseek")
      view = choose_model(view, :deepseek, 0)

      second = model_string(:deepseek, nil, 1)
      click(view, "toggle_wizard_model", %{"model" => second})
      assert has_element?(view, ~s(input[phx-value-model="#{second}"][checked]))

      view = next(next(view))
      render_click(view, "skip_test")

      entry = account("deepseek")
      assert length(entry["models"]) == 2

      assert Enum.map(entry["models"], & &1["model"]) |> Enum.sort() ==
               Enum.sort([model_id(:deepseek, 0), model_id(:deepseek, 1)])

      for row <- entry["models"] do
        assert row["reasoning_efforts"] == Reasoning.efforts()
      end

      assert entry["default_model"] == model_id(:deepseek, 0)
    end
  end

  # ── reasoning vocabulary ───────────────────────────────────────────────────
  describe "reasoning vocabulary" do
    test "offers the canonical ladder for a catalog model plus a separate default select",
         %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)

      # The NORMAL user path: a catalog provider and one of ITS OWN models (the
      # free-text custom name is the exception, not the way in).
      view = deepseek_to_reasoning(view)
      model = model_string(:deepseek)

      assert Reasoning.efforts() == ["none", "minimal", "low", "medium", "high", "xhigh"]

      # A catalog model declares no `reasoning_efforts`, so the step offers
      # exactly the canonical ladder: one chip per level, `xhigh` included and
      # `max` never (it is an alias of `xhigh`, not a level).
      assert chip_values(view) == Reasoning.efforts()
      assert has_element?(view, ~s(input[name="reasoning_efforts[]"][value="xhigh"]))
      refute has_element?(view, ~s(input[name="reasoning_efforts[]"][value="max"]))
      refute has_element?(view, ~s([value="max"]))

      # The unrestricted empty inventory is DISPLAYED as the full ladder (all six
      # checked); the persisted draft inventory stays empty until the user picks.
      assert checked_chip_values(view) == Reasoning.efforts()
      assert assigns(view).draft["reasoning_efforts"] == []

      # The SEPARATE default select is present and offers that same ladder.
      assert has_element?(view, "select#default-reasoning-effort")
      assert select_values(view) == ["" | Reasoning.efforts()]
      assert has_element?(view, ~s(select#default-reasoning-effort option[value=""]))
      refute has_element?(view, ~s(select#default-reasoning-effort option[value="max"]))

      # Picking ONE level REPLACES the selection: the draft records exactly that
      # one level and that one default (the historical bug left two chips
      # selected), and no chip value is ever rendered twice.
      change(view, "wizard_reasoning", %{
        "reasoning_efforts" => ["xhigh"],
        "default_reasoning_effort" => "xhigh"
      })

      assert assigns(view).draft["model_reasoning"][model] == %{
               "efforts" => ["xhigh"],
               "default" => "xhigh"
             }

      # The chips keep rendering the catalog model's DISPLAY ladder (one chip per
      # level, no duplicate), while the draft is the authoritative selection.
      assert Enum.uniq(chip_values(view)) == Reasoning.efforts()

      # A later pick does not accumulate on top of the previous one either.
      change(view, "wizard_reasoning", %{
        "reasoning_efforts" => ["high"],
        "default_reasoning_effort" => "high"
      })

      assert assigns(view).draft["model_reasoning"][model]["efforts"] == ["high"]
      assert assigns(view).draft["model_reasoning"][model]["default"] == "high"
      assert Enum.uniq(chip_values(view)) == Reasoning.efforts()

      # The save writes the canonical account and its model row, and the picked
      # level ROUND-TRIPS into that row — the same value the select shows.
      click(next(view), "skip_test")

      entry = account("deepseek")
      assert [row] = entry["models"]
      assert row["model"] == model_id(:deepseek, 0)
      assert row["reasoning_efforts"] == Reasoning.efforts()
      assert row["default_reasoning_effort"] == "high"
    end

    test "resetting to Provider default omits the saved reasoning key", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)
      view = deepseek_to_reasoning(view)
      model = model_string(:deepseek)

      change(view, "wizard_reasoning", %{
        "reasoning_efforts" => ["high"],
        "default_reasoning_effort" => "high"
      })

      assert assigns(view).draft["model_reasoning"][model]["default"] == "high"

      # The select's blank row IS "Provider default": it records no level, so
      # the persisted row carries no `default_reasoning_effort` key at all.
      change(view, "wizard_reasoning", %{
        "reasoning_efforts" => ["high"],
        "default_reasoning_effort" => ""
      })

      click(next(view), "skip_test")

      assert [row] = account("deepseek")["models"]
      assert row["model"] == model_id(:deepseek, 0)
      assert row["reasoning_efforts"] == Reasoning.efforts()
      refute Map.has_key?(row, "default_reasoning_effort")
    end
  end

  # ── schedule presets ───────────────────────────────────────────────────────
  describe "schedule presets" do
    test "applies the recommended DeepSeek preset explicitly and persists it", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)
      view = deepseek_to_reasoning(view)

      refute render(view) =~ "Recommended schedule applied"

      html = render_click(view, "apply_schedule_preset", %{"preset_id" => "deepseek-standard"})
      assert html =~ "Recommended schedule applied"
      assert html =~ "DeepSeek standard"
      assert has_element?(view, ~s(button[phx-click="undo_schedule_preset"]))
      assert has_element?(view, ~s(button[phx-click="dismiss_schedule_preset"]))
      assert assigns(view).draft["schedule"]["off_peak_holidays"] == "CN"
      assert has_element?(view, ~s(select#off-peak-holidays option[value="CN"][selected]))

      view = click(next(view), "skip_test")
      assert render(view) =~ "Provider and models saved."

      entry = account("deepseek")
      assert entry["concurrency"] == 4
      assert entry["peak_concurrency"] == 2
      assert entry["timezone"] == "UTC"
      assert entry["off_peak_days"] == ["sat", "sun"]
      assert entry["off_peak_holidays"] == "CN"

      assert entry["peak_hours"] == [
               %{"start" => "01:00", "end" => "04:00", "days" => ["weekdays"]},
               %{"start" => "06:00", "end" => "10:00", "days" => ["weekdays"]}
             ]
    end

    test "undo restores the pre-preset schedule and a later save persists it", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)
      view = deepseek_to_reasoning(view)

      click(view, "apply_schedule_preset", %{"preset_id" => "deepseek-standard"})
      html = render_click(view, "undo_schedule_preset")
      refute html =~ "Recommended schedule applied"
      assert assigns(view).draft["schedule"] == %{}

      view = click(next(view), "skip_test")
      assert render(view) =~ "Provider and models saved."

      entry = account("deepseek")

      for key <- EvoDashWeb.LLMSetup.Schedule.schedule_keys() do
        refute Map.has_key?(entry, key)
      end
    end

    test "a manual holiday edit is never silently re-applied", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)
      view = deepseek_to_reasoning(view)

      click(view, "apply_schedule_preset", %{"preset_id" => "deepseek-standard"})
      change(view, "wizard_schedule_changed", %{"off_peak_holidays" => ""})
      refute has_element?(view, ~s(select#off-peak-holidays option[value="CN"][selected]))
      assert assigns(view).draft["schedule"]["off_peak_holidays"] == nil

      click(next(view), "skip_test")
      entry = account("deepseek")
      refute Map.has_key?(entry, "off_peak_holidays")
      # The rest of the applied preset survives the manual edit.
      assert entry["concurrency"] == 4
    end

    test "dismissing the strip does not discard the applied schedule", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)
      view = deepseek_to_reasoning(view)

      click(view, "apply_schedule_preset", %{"preset_id" => "deepseek-standard"})
      html = render_click(view, "dismiss_schedule_preset")
      refute html =~ "Recommended schedule applied"

      click(next(view), "skip_test")
      assert account("deepseek")["off_peak_holidays"] == "CN"
    end

    test "a provider without a published preset renders no preset affordance", %{conn: conn} do
      {:ok, view, _html} = start(conn)
      view = anthropic_to_reasoning(view)

      refute render(view) =~ "Published schedule presets"
      refute has_element?(view, ~s(button[phx-click="apply_schedule_preset"]))
      refute has_element?(view, ~s(button[phx-click="undo_schedule_preset"]))
    end
  end

  # ── connection test ────────────────────────────────────────────────────────
  describe "connection test" do
    test "runs through the scoped worker and renders success", %{conn: conn} do
      {:ok, view, _html} = start(conn)
      view = next(anthropic_to_reasoning(view))

      render_click(view, "test_connection")

      assert_receive {:welcome_test_started, pid, model, opts}, @runner_start_timeout
      assert is_binary(model) and model =~ model_id(:anthropic)
      assert is_list(opts)
      assert render(view) =~ "Testing the connection…"
      seq = assigns(view).llm_test_seq

      # `SafeCall` wraps the provider's own answer, and the page unwraps exactly
      # that ONE wrapper, so the status carries the provider's detail map and
      # the step renders it as "<model> · <response>".
      result = {:ok, %{model: model, response: "pong"}}
      send(pid, {:finish, result})
      await_status(view, {:ok, "#{model} · pong"})
      assert assigns(view).llm_test_status == {:ok, %{model: model, response: "pong"}}
      assert assigns(view).llm_test_seq == seq
      assert render(view) =~ "Connection succeeded."

      html = render_click(view, "skip_test")
      assert html =~ "Provider and models saved."
      assert account("anthropic")["default_model"] == model_id(:anthropic)
    end

    test "renders a failed connection test", %{conn: conn} do
      {:ok, view, _html} = start(conn)
      view = next(anthropic_to_reasoning(view))

      render_click(view, "test_connection")
      assert_receive {:welcome_test_started, pid, _model, _opts}, @runner_start_timeout

      send(pid, {:finish, :raise})

      deadline = System.monotonic_time(:millisecond) + @async_wait_budget_ms
      html = await_render(view, "Connection failed.", deadline)
      assert html =~ "provider unreachable"
      refute html =~ "Connection succeeded."
    end

    test "ignores a stale or legacy unscoped result", %{conn: conn} do
      {:ok, view, _html} = start(conn)
      view = next(anthropic_to_reasoning(view))

      render_click(view, "test_connection")
      assert_receive {:welcome_test_started, pid, _model, _opts}, @runner_start_timeout
      assert assigns(view).llm_test_status == :testing

      # A legacy unscoped message and an out-of-date sequence are both inert.
      send(view.pid, {:llm_test_result, {:ok, "legacy"}})
      send(view.pid, {{:welcome_llm_test_result, 0}, {:ok, "stale"}})
      assert assigns(view).llm_test_status == :testing
      refute render(view) =~ "Connection succeeded."

      send(pid, {:finish, {:ok, %{model: model_string(:anthropic), response: "pong"}}})
      await_status(view, {:ok, "#{model_string(:anthropic)} · pong"})
      assert render(view) =~ "Connection succeeded."
    end

    test "a provider-side error never renders as success", %{conn: conn} do
      {:ok, view, _html} = start(conn)
      view = next(anthropic_to_reasoning(view))

      render_click(view, "test_connection")
      assert_receive {:welcome_test_started, pid, _model, _opts}, @runner_start_timeout

      # The provider answered with its OWN `{:error, message}` (the `SafeCall`
      # envelope around it is an `{:ok, …}`), so the page must render a failure
      # instead of an empty success line.
      send(pid, {:finish, {:error, "boom"}})
      await_status(view, {:error, "boom"})

      html = render(view)
      assert html =~ "Connection failed."
      assert html =~ "boom"
      refute html =~ "Connection succeeded."
    end

    test "sends the picked reasoning level for the tested model, and none after a reset",
         %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)
      view = deepseek_to_reasoning(view)

      change(view, "wizard_reasoning", %{
        "reasoning_efforts" => Reasoning.efforts(),
        "default_reasoning_effort" => "high"
      })

      view = next(view)
      render_click(view, "test_connection")

      # The request carries the SAME per-model level the save path persists, so
      # "Test connection" exercises the configuration about to be written.
      assert_receive {:welcome_test_started, pid, model, opts}, @runner_start_timeout
      assert model =~ model_id(:deepseek)
      assert opts[:reasoning_effort] == :high
      send(pid, {:finish, {:ok, %{model: model, response: "pong"}}})
      await_status(view, {:ok, "#{model} · pong"})

      # Back on the reasoning step, "Provider default" records no level, so the
      # next request sends no `reasoning_effort` at all.
      back(view)

      change(view, "wizard_reasoning", %{
        "reasoning_efforts" => Reasoning.efforts(),
        "default_reasoning_effort" => ""
      })

      view = next(view)
      render_click(view, "test_connection")

      assert_receive {:welcome_test_started, pid, _model, opts}, @runner_start_timeout
      refute Keyword.has_key?(opts, :reasoning_effort)
      send(pid, {:finish, {:ok, %{model: model_string(:deepseek), response: "pong"}}})
    end

    test "sends the free-text custom model's own reasoning level", %{conn: conn} do
      {:ok, view, _html} = start(conn)

      view = custom_to_model(view)
      change(view, "wizard_custom_model", %{"custom_model" => "my-model-x"})
      view = next(view)

      change(view, "wizard_reasoning", %{
        "reasoning_efforts" => ["low", "medium"],
        "default_reasoning_effort" => "medium"
      })

      view = next(view)
      render_click(view, "test_connection")

      assert_receive {:welcome_test_started, _pid, model, opts}, @runner_start_timeout
      # An OpenAI-compatible custom model resolves to its own struct, not a
      # catalog spec string, so the id is read off its representation.
      assert {:ok, %LLMDB.Model{id: "my-model-x"} = model} = ReqLLM.model(model)

      assert model.base_url == @custom_base_url

      assert {:ok, :openai_chat_completions, ReqLLM.Providers.OpenAI.ChatAPI, []} =
               ReqLLM.RequestPlan.openai_surface(model)

      assert opts[:reasoning_effort] == :medium
    end
  end

  defp await_render(view, needle, deadline) do
    html = render(view)

    if html =~ needle do
      html
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "expected the page to render #{inspect(needle)}"

      Process.sleep(2)
      await_render(view, needle, deadline)
    end
  end

  # ── done step ──────────────────────────────────────────────────────────────
  describe "done step" do
    test "renders the summary rows and the dashboard path", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)

      view = next(deepseek_to_reasoning(view))
      html = render_click(view, "wizard_next")

      assert html =~ "Provider and models saved."
      assert html =~ "You&#39;re all set"
      assert html =~ "Provider"
      assert html =~ "DeepSeek"
      assert html =~ "Model"
      assert html =~ model_display_name(:deepseek)
      assert has_element?(view, ~s(a[href="/welcome/complete"]))
      assert has_element?(view, ~s(a[href="/settings"]))
      assert has_element?(view, ~s(button[phx-click="add_another_provider"]))
    end

    test "a configured install offers Go to Dashboard and redirects", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)
      view = next(deepseek_to_reasoning(view))
      render_click(view, "skip_test")

      {:ok, done, html} = start(conn)
      assert html =~ "Ready to build!"
      assert has_element?(done, ~s(button[phx-click="get_started"]))
      refute has_element?(done, "#wizard-step-provider")

      render_click(done, "get_started")
      assert_redirect(done, "/welcome/complete")
    end
  end

  # ── persistence pins ───────────────────────────────────────────────────────
  describe "persistence and local-only pins" do
    test "preserves unrelated raw config while appending the canonical account", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")

      seed_config(%{
        "sandbox" => %{"backend" => "bwrap"},
        "llm" => %{"compression_threshold_tokens" => 12_345}
      })

      {:ok, view, _html} = start(conn)
      view = next(deepseek_to_reasoning(view))
      render_click(view, "skip_test")

      config = read_config()
      assert get_in(config, ["sandbox", "backend"]) == "bwrap"
      assert get_in(config, ["llm", "compression_threshold_tokens"]) == 12_345
      assert account("deepseek")
    end

    test "never renders the API key and never writes it into config.toml", %{conn: conn} do
      {:ok, view, _html} = start(conn)

      pick(view, "anthropic")

      html = render(view)
      assert has_element?(view, "#wizard-api-key")
      assert html =~ "Paste your Anthropic API key"

      change(view, "wizard_api_key", %{"api_key" => @anthropic_key})
      # The draft holds the key transiently (it rides the password field's
      # value, which the page echoes back — see the defect report), and the
      # auth body is gone once the wizard advances.
      assert assigns(view).draft["api_key"] == @anthropic_key
      next(view)
      refute render(view) =~ @anthropic_key
      back(view)

      view = next(next(choose_model(next(view), :anthropic)))
      html = render_click(view, "skip_test")
      refute html =~ @anthropic_key

      assert File.read!(EvoGit.Config.credentials_path()) =~ @anthropic_key
      refute File.read!(EvoGit.Config.config_path()) =~ @anthropic_key
      refute read_config() |> inspect() =~ @anthropic_key
    end

    test "debounces the API key field so typing never round-trips per keystroke", %{conn: conn} do
      {:ok, view, _html} = start(conn)

      pick(view, "anthropic")

      assert has_element?(view, "#wizard-api-key[phx-debounce='300']")
    end

    test "rejects every mutation on a remote node", %{conn: conn} do
      {:ok, view, _html} = start(conn)

      # Reuse the LIVE socket and only override the node binding: the events are
      # answered by the real handlers, and change tracking stays intact.
      socket = :sys.get_state(view.pid, @assigns_timeout_ms).socket
      socket = %{socket | assigns: Map.put(socket.assigns, :current_node_id, "remote-target")}

      for event <- [
            "select_wizard_provider",
            "select_wizard_model",
            "wizard_api_key",
            "wizard_reasoning",
            "apply_schedule_preset",
            "test_connection",
            "skip_test",
            "chatgpt_sign_in",
            "chatgpt_sign_in_cancel"
          ] do
        assert {:noreply, guarded} =
                 EvoDashWeb.WelcomeLive.handle_event(event, %{"provider" => "deepseek"}, socket)

        assert Phoenix.Flash.get(guarded.assigns.flash, :error) ==
                 "Use Settings to configure the remote node."
      end

      # Navigation stays available on a remote view.
      for event <- ["wizard_back", "wizard_next", "skip", "get_started", "noop"] do
        assert {:noreply, passed} = EvoDashWeb.WelcomeLive.handle_event(event, %{}, socket)

        refute Phoenix.Flash.get(passed.assigns.flash, :error) ==
                 "Use Settings to configure the remote node."
      end

      refute File.exists?(EvoGit.Config.config_path())
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

defmodule EvoDashWeb.WelcomeLiveTest.SignInStub do
  @moduledoc false
  # The Sign in with ChatGPT (SIWC) flow stand-in for the `/welcome` sign-in
  # tests.
  #
  # `EvoDashWeb.LLMSetup.ChatGPTSignIn.login_module/0` resolves the flow module
  # per process (this pid, then `$callers`, then the app env), and
  # `Phoenix.LiveViewTest` puts the test pid in the mounted view's `$callers`, so
  # a test selects this module with `Process.put(:chatgpt_login_module, ...)` in
  # its OWN process. This module reads its behaviour, and reports its calls,
  # through that same dictionary — it touches no BEAM-global state, which keeps
  # the suite `async: true`.
  #
  # `status/1` is called from the `ChatGPTSignIn` poll task, which inherits the
  # caller chain, so it resolves the same owner and answers the SAME result every
  # time (one terminal result, then the poll exits). Its notification carries the
  # answer the poll READ, because the tick is asynchronous: a test waits for the
  # tick that saw its terminal answer, not merely for any tick.

  @default_begin {:ok, %{id: "welcome-flow", url: "https://auth.example.test/authorize"}}
  # `:pending` until a test flips the result it wants the poll to see, which
  # makes the WAITING state deterministic (no race against the poll).
  @default_statuses %{}

  @doc "Starts a flow: the configured `{:ok, %{id:, url:}}` result, else its error."
  def begin(account, _opts \\ []) do
    notify({:begin, account})
    config(:signin_stub_begin, @default_begin)
  end

  @doc """
  The configured terminal result for `flow_id`, else `:pending` (waiting).

  The notification carries the answer this call READ, so a test can wait for the
  exact tick that saw its terminal result instead of a merely earlier `:pending`
  one.
  """
  def status(flow_id) do
    answer = :signin_stub_statuses |> config(@default_statuses) |> Map.get(flow_id, :pending)
    notify({:status, flow_id, answer})
    answer
  end

  @doc "Cancels a flow, reporting the call to the owning test."
  def cancel(flow_id) do
    notify({:cancel, flow_id})
    :ok
  end

  defp notify(message) do
    case owner() do
      nil -> :ok
      pid -> send(pid, {:signin_stub, message})
    end

    :ok
  end

  # The process that selected this module — the test — found exactly the way
  # `ChatGPTSignIn.login_module/0` finds the selection.
  defp owner do
    :"$callers"
    |> Process.get([])
    |> List.wrap()
    |> Enum.find(fn pid -> dictionary(pid, :chatgpt_login_module) == __MODULE__ end)
  end

  defp dictionary(pid, key) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, key)
      _unavailable -> nil
    end
  end

  defp config(key, default) do
    case owner() do
      nil -> default
      pid -> dictionary(pid, key) || default
    end
  end
end
