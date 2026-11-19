defmodule EvoDashWeb.WelcomeLiveTest do
  # Config files are per-process isolated (`EvoDash.Test.ConfigDir`), and the
  # connection-test runner seam is owned exclusively by this module and never
  # calls a provider. The global "tasks" publisher lives in the sync module at
  # the bottom of this file.
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias EvoGit.Config.LLMCatalog, as: Catalog
  alias EvoDashWeb.LLMSetup.Reasoning
  alias EvoDashWeb.WelcomeLive.Presentation

  # Canonical resolution can cold-load the model catalog before reaching the
  # stub; keep that startup budget separate from the blocked runner's reply.
  @runner_start_timeout 30_000
  # Load-tolerant budget for the bounded poll that waits for an async result to
  # reach the LiveView. The wait stays bounded and still fails loudly.
  @async_wait_budget_ms 30_000
  # `:sys.get_state/2` timeout for `assigns/1`: the LiveView can be starved for
  # seconds on a loaded host, where the 5 s default exits the test.
  @assigns_timeout_ms 30_000
  @anthropic_key "sk-ant-welcome-test-123"
  @custom_base_url "https://api.example.test/v1"

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
    render_change(view, "wizard_field_changed", %{"base_url" => @custom_base_url})
    next(view)
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

  defp await_status(view, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @async_wait_budget_ms

    if assigns(view).llm_test_status != expected do
      assert System.monotonic_time(:millisecond) < deadline,
             "connection result did not reach the LiveView"

      Process.sleep(2)
      await_status(view, expected, deadline)
    end
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
      assert has_element?(view, ~s([phx-value-model="#{model_string(:anthropic)}"][aria-current="true"]))

      back(view)

      html = render(view)
      assert html =~ "Step 2 of 6"
      assert assigns(view).draft["api_key"] == @anthropic_key

      back(view)

      html = render(view)
      assert html =~ "Step 1 of 6"
      assert has_element?(view, ~s([phx-value-provider="anthropic"][aria-pressed="true"]))
    end

    test "an OAuth-only provider short-circuits to the subscription mode", %{conn: conn} do
      {:ok, view, _html} = start(conn)

      pick(view, "openai_codex")

      html = render(view)
      # No auth choice: the run is provider → model → reasoning → test → done.
      assert html =~ "Step 2 of 5"
      assert html =~ "Pick a model"
      refute has_element?(view, "#wizard-step-auth")
      refute has_element?(view, "#wizard-api-key")

      view = choose_model(view, :openai_codex)
      view = next(next(view))
      html = render_click(view, "skip_test")

      assert html =~ "Provider and models saved."
      entry = account("openai-codex")
      assert entry["provider"] == "openai_codex"
      assert entry["auth_mode"] == "oauth"
      assert stored_credentials() =~ "auth_mode" or stored_credentials() == ""
      refute stored_credentials() =~ "openai_api_key"
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
    test "exposes only the canonical ladder plus a separate default select", %{conn: conn} do
      seed_credential("deepseek_api_key", "sk-deepseek-test")
      {:ok, view, _html} = start(conn)
      _view = deepseek_to_reasoning(view)

      for effort <- Reasoning.efforts() do
        assert has_element?(view, ~s(input[name="reasoning_efforts[]"][value="#{effort}"]))
      end

      assert Reasoning.efforts() == ["none", "minimal", "low", "medium", "high", "xhigh"]
      refute has_element?(view, ~s([value="max"]))

      # The default select renders over the model's chosen inventory.
      change(view, "wizard_reasoning", %{
        "reasoning_efforts" => ["low", "medium", "high"],
        "default_reasoning_effort" => "medium"
      })

      assert has_element?(view, "select#default-reasoning-effort")
      assert has_element?(view, ~s(select#default-reasoning-effort option[value=""]))
      assert has_element?(view, ~s(select#default-reasoning-effort option[value="medium"][selected]))
      refute has_element?(view, ~s(select#default-reasoning-effort option[value="max"]))
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

      view = click(next(view), "skip_test")
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

      view = click(next(view), "skip_test")
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

      # The worker envelope wraps the provider's own answer, so the page's
      # status is `{:ok, {:ok, detail}}` (the detail itself is never unwrapped
      # into the rendered copy — see the defect report).
      result = {:ok, %{model: model, response: "pong"}}
      send(pid, {:finish, result})
      await_status(view, {:ok, {:ok, %{model: model, response: "pong"}}})
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
      await_status(view, {:ok, {:ok, %{model: model_string(:anthropic), response: "pong"}}})
      assert render(view) =~ "Connection succeeded." 
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

    test "rejects every mutation on a remote node", %{conn: conn} do
      {:ok, view, _html} = start(conn)
      socket =
        :sys.get_state(view.pid, @assigns_timeout_ms)
        |> Phoenix.Component.assign(:current_node_id, "remote-target")

      for event <- [
            "select_wizard_provider",
            "select_wizard_model",
            "wizard_api_key",
            "wizard_reasoning",
            "apply_schedule_preset",
            "test_connection",
            "skip_test"
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
