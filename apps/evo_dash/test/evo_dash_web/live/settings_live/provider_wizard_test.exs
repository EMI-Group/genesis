# Settings → provider-account WIZARD suite (`/settings?category=llm`).
#
# Companion to `provider_panel_live_test.exs`: that module seeds canonical
# accounts on disk and pins the list / expanded-editor surface, while this
# module drives the ACCOUNT-CREATION wizard and the per-account model and
# schedule editors end to end. Every pin asserts what the flow PERSISTS
# (`EvoGit.Config.user_config/0`) as well as what it renders.
#
# Regression pins:
#   1. the deleted "Quick Setup" shortcut and its six events are gone;
#   2. account identity is PROVIDER-derived, never the model string;
#   3. one expanded account detail at a time (accordion);
#   4. "Add model" appends to ONE account and leaves the other untouched;
#   5. a schedule preset applies, saves and undoes (incl. the "modified" hint);
#   6. `off_peak_holidays` round-trips, and stays ABSENT while blank;
#   7. the wizard gates Next/Back and clamps at both ends;
#   8. the reasoning chips carry `xhigh` exactly once and NEVER `max`
#      (the phantom-second-effort regression), at the wizard step AND in the
#      expanded detail of the account it created.
#
# ASYNC: every test touches only per-process state — the config directory comes
# from the `:config_dir_fun` seam (`EvoDash.Test.ConfigDir.isolate!/1`,
# installed by `test_helper.exs`), never from a BEAM-global `XDG_CONFIG_HOME`
# write.
# A per-test stand-in for `EvoDash.ChatGPTLogin` (the SIWC flow module) lives in
# `test/support/chatgpt_login_stub.ex` (`EvoDash.Test.ChatGPTLoginStub`), injected
# through `EvoDashWeb.LLMSetup.ChatGPTSignIn.login_module/0`'s CALL-TIME
# `$callers` seam: `Phoenix.LiveViewTest` puts the test pid in the mounted view's
# `$callers`, so `install!/1` seeds the test's OWN process dictionary and nothing
# here is BEAM-global.

# A minimal fake connection manager registered in
# `EvoGit.RemoteConnection.Registry` under a saved target id, so
# `LiveHooks.NodeAware` resolves `?node=<id>` to a REMOTE BEAM node atom (an
# unreachable fake node, exactly like the other settings suites). Definition
# order is load-bearing: the async module below starts running as soon as it is
# registered, so this must be defined FIRST.
defmodule EvoDashWeb.SettingsLive.ProviderWizardTest.ConnectionManager do
  use GenServer

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({target_id, status}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)
    {:ok, status}
  end

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}
end

defmodule EvoDashWeb.SettingsLive.ProviderWizardTest do
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias EvoDashWeb.SettingsComponents.ProviderProfiles.Row
  alias EvoDash.Test.ChatGPTLoginStub, as: ChatGPTStub
  # Load-tolerant budgets for waits on ASYNC settings work (mount load chain,
  # owned config-save receipt). That work runs in supervised tasks on a shared
  # host whose scheduling swings 10-30x (test/CONTEXT.md), so the waits stay
  # bounded but must not expire spuriously.
  @async_wait_budget_ms 30_000
  @assigns_timeout_ms 30_000
  # Local copies of the mount/settle/save helpers: this module must COMPILE and
  # run on its own (`mix test .../provider_wizard_test.exs`), and the shared
  # `EvoDashWeb.SettingsLiveTest.Helpers` module only exists once
  # `settings_live_test.exs` is loaded, which the loader does not guarantee in
  # alphabetical order.
  defp mount_settings(conn, path) do
    {:ok, view, html} = Phoenix.LiveViewTest.live(conn, path)
    await_mount_async_loads(view)
    {:ok, view, html}
  end

  defp await_mount_async_loads(view) do
    view.pid
    |> mount_async_task_pids()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref ->
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        @async_wait_budget_ms -> :ok
      end
    end)

    :ok
  end

  defp mount_async_task_pids(view_pid) do
    EvoDash.TaskSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) ->
        if view_pid in task_callers(pid), do: [pid], else: []

      _ ->
        []
    end)
  end

  defp task_callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$callers", [])
      _ -> []
    end
  end

  # Mutations acknowledge dispatch before the off-process write completes:
  # always assert the authoritative completion, not the dispatch render.
  defp settings_hook(view, event, params) do
    Phoenix.LiveViewTest.render_hook(view, event, params)
    await_config_save(view)
  end

  defp await_config_save(view) do
    wait_settings(view, &(not &1[:config_saving]))
    render(view)
  end

  defp wait_settings(view, predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @async_wait_budget_ms
    current = assigns(view)

    if predicate.(current) do
      current
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "Settings did not reach the expected authoritative state"

      receive do
      after
        2 -> wait_settings(view, predicate, deadline)
      end
    end
  end

  defp assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns

  setup do
    EvoDash.Test.ConfigDir.isolate!("evogit_settings_provider_wizard_test")
    # ActiveTasks is a process-less public ETS table shared by the whole run;
    # clear ONLY the local context so a concurrent module keeps its snapshot.
    EvoDash.ActiveTasks.invalidate(nil, node())
    # The stub notifies from INSIDE the boundary's `Task.async` call, so the
    # product's call budget also bounds a stub notification: on a starved host
    # the task can be killed before it runs and the notification is lost
    # forever. Inject the suite's load-tolerant budget so the product can never
    # kill a stub call (production keeps its own 15 s default).
    Process.put(:chatgpt_signin_call_timeout_ms, @async_wait_budget_ms)
    :ok
  end

  # ── wizard helpers ─────────────────────────────────────────────────────────
  defp start_wizard(view) do
    view |> element(~s(button[phx-click="add_provider_profile"])) |> render_click()
    assert has_element?(view, "#provider-wizard")
    :ok
  end

  defp wizard_button(event), do: ~s(#provider-wizard button[phx-click="#{event}"])

  defp wizard_next(view),
    do: view |> element(wizard_button("provider_wizard_next")) |> render_click()

  defp pick_provider(view, provider),
    do:
      view
      |> element(~s(#provider-wizard button[phx-value-provider="#{provider}"]))
      |> render_click()

  # The step form's own change event. It is the only UI path that reaches a
  # catalog ENTRY id sharing another provider's atom (`openai_compatible`
  # resolves to :openai, so the card grid has no card for it).
  defp provider_form_change(view, params) do
    view |> element("#provider-wizard-provider-form") |> render_change(params)
  end

  defp choose_custom_model(view, model) do
    view |> form("#wizard-custom-model-form", %{custom_model: model}) |> render_change()
  end

  defp save_wizard(view) do
    view |> element(wizard_button("provider_wizard_save")) |> render_click()
    await_config_save(view)
  end

  # provider card → auth → model (custom) → reasoning/schedule → Save.
  defp create_account(view, provider, model) do
    start_wizard(view)
    pick_provider(view, provider)
    wizard_next(view)
    wizard_next(view)
    choose_custom_model(view, model)
    wizard_next(view)
    save_wizard(view)
  end

  # Provider → auth for the ChatGPT provider: the ONLY step that owns the
  # in-browser sign-in.
  defp open_chatgpt_auth_step(view) do
    start_wizard(view)
    pick_provider(view, "openai_codex")
    wizard_next(view)
    assert has_element?(view, "#wizard-step-auth")
  end

  # Bounded wait for the sign-in poll's ONE result to be APPLIED by the
  # LiveView (the poll runs off-process in a supervised task). `receive after
  # 2` is the suite's poll cadence, never a fixed wait.
  defp await_sign_in(view, phase) do
    await_sign_in(view, phase, System.monotonic_time(:millisecond) + @async_wait_budget_ms)
  end

  defp await_sign_in(view, phase, deadline) do
    state = assigns(view)
    sign_in = (state[:provider_wizard] || %{})[:chatgpt_sign_in] || %{}

    if Map.get(sign_in, :phase) == phase do
      render(view)
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "ChatGPT sign-in never reached #{inspect(phase)}"

      receive do
      after
        2 -> :ok
      end

      await_sign_in(view, phase, deadline)
    end
  end

  # ── account helpers ────────────────────────────────────────────────────────
  defp current_providers(view), do: get_in(assigns(view).file_config, [:llm, :providers]) || []
  defp stored_providers, do: get_in(EvoGit.Config.user_config(), ["llm", "providers"]) || []
  defp stored_profile(id), do: Enum.find(stored_providers(), &(&1["id"] == id))
  defp row_id(id), do: "#provider-profile-" <> Row.slug(id)
  defp detail_id(id), do: "#provider-profile-detail-" <> Row.slug(id)
  # Counts the rendered expanded account forms in the WHOLE document, so the
  # "exactly one detail at a time" (accordion) contract is asserted without
  # depending on any single slug.
  defp detail_form_count(view),
    do: length(Regex.scan(~r/id="provider-profile-detail-/, render(view)))

  defp open_account(view, id),
    do: settings_hook(view, "edit_provider_profile", %{"profile_id" => id})

  # `edit_provider_profile` TOGGLES, and a save/add-model already expands the
  # account it touched — collapse would hide the very editor under test.
  defp ensure_open(view, id) do
    if assigns(view).editing_profile_id == id,
      do: render(view),
      else: open_account(view, id)
  end

  # Writes a canonical `[[llm.providers]]` file for THIS test's config dir,
  # exactly as the panel persists it (string keys, one nested model row).
  defp seed_provider_profiles(profiles, default_provider_profile \\ nil) do
    path = EvoGit.Config.config_path()
    File.mkdir_p!(Path.dirname(path))

    default =
      if default_provider_profile,
        do: "[llm]\ndefault_provider_profile = #{inspect(default_provider_profile)}\n\n",
        else: ""

    File.write!(
      path,
      default <>
        Enum.map_join(profiles, "", fn {id, provider, model} ->
          """
          [[llm.providers]]
          id = "#{id}"
          provider = "#{provider}"
          default_model = "#{model}"
          concurrency = 3
          [[llm.providers.models]]
          model = "#{model}"
          """
        end)
    )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp submit_detail_form(view, id, overrides) do
    view |> form(detail_id(id), overrides) |> render_submit()
    await_config_save(view)
  end

  defp count_occurrences(html, needle),
    do: length(String.split(html, needle)) - 1

  # The effort CHIPS of a reasoning fieldset, in document order. Counting the
  # chip inputs (not every `value="…"`) is what pins the phantom-second-effort
  # regression: a selected effort legitimately reappears as a `default-reasoning`
  # <option> value, but it must never be offered as a SECOND chip.
  defp checkbox_values(html) do
    html
    |> String.split(~s(type="checkbox"))
    |> Enum.drop(1)
    |> Enum.map(fn segment ->
      case Regex.run(~r/value="([^"]*)"/, segment) do
        [_, value] -> value
        _ -> ""
      end
    end)
  end

  describe "the removed Quick Setup shortcut" do
    test "the LLM category renders the account panel and none of the deleted events", %{
      conn: conn
    } do
      {:ok, view, html} = mount_settings(conn, ~p"/settings")
      assert assigns(view).active_category == :llm
      assert has_element?(view, "#provider-profiles-panel")
      assert has_element?(view, ~s(button[phx-click="add_provider_profile"]))
      refute html =~ "Quick Setup"

      for removed <- ~w(save_quick_setup select_llm_provider select_llm_variant
                         select_llm_model save_custom_model select_llm_model_shortcut) do
        refute html =~ removed
      end
    end
  end

  describe "the add-account wizard derives identity from the provider" do
    test "zai, a second zai and openai_compatible get provider ids and names, never the model", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      # The wizard PREVIEWS the derived identity before any write.
      start_wizard(view)
      pick_provider(view, "zai")
      draft = assigns(view).provider_wizard.draft
      assert draft["profile_id_new"] == "zai"
      assert draft["name"] == "Z.ai (Zhipu AI)"
      wizard_next(view)
      wizard_next(view)
      choose_custom_model(view, "glm-4.6")
      wizard_next(view)
      html = save_wizard(view)
      assert html =~ "Provider account saved."
      refute has_element?(view, "#provider-wizard")
      first = stored_profile("zai")
      assert first["id"] == "zai"
      assert first["name"] == "Z.ai (Zhipu AI)"
      assert first["provider"] == "zai"
      assert first["default_model"] == "glm-4.6"
      assert first["models"] == [%{"model" => "glm-4.6"}]
      # The MODEL never becomes the identity.
      refute first["id"] == "glm-4.6"
      refute first["name"] =~ "glm"
      refute first["name"] =~ "4.6"
      # The first account becomes the default profile, and the saved account
      # is the expanded one (the wizard hands its successor a closed state).
      assert EvoGit.Config.user_config()["llm"]["default_provider_profile"] == "zai"
      assert assigns(view).editing_profile_id == "zai"
      assert has_element?(view, detail_id("zai"))
      # A SECOND account of the same provider gets a suffixed id AND name.
      create_account(view, "zai", "glm-5.3")
      second = stored_profile("zai-2")
      assert second["name"] == "Z.ai (Zhipu AI)-2"
      assert second["default_model"] == "glm-5.3"
      refute second["id"] == "glm-5.3"
      assert has_element?(view, row_id("zai"))
      assert has_element?(view, row_id("zai-2"))
      # A catalog ENTRY with its own identity slug, reached through the step
      # form (it shares :openai's provider atom, so it has no card).
      start_wizard(view)

      provider_form_change(view, %{
        "provider" => "openai_compatible",
        "base_url" => "https://proxy.example.test/v1"
      })

      assert assigns(view).provider_wizard.draft["profile_id_new"] == "openai-compatible"
      assert assigns(view).provider_wizard.draft["name"] == "OpenAI-Compatible API"
      wizard_next(view)
      wizard_next(view)
      choose_custom_model(view, "proxy-large")
      wizard_next(view)
      save_wizard(view)
      third = stored_profile("openai-compatible")
      assert third["name"] == "OpenAI-Compatible API"
      assert third["provider"] in ["openai_compatible", "openai"]
      assert third["base_url"] == "https://proxy.example.test/v1"
      refute third["id"] == "proxy-large"
      refute third["name"] =~ "proxy"
      assert has_element?(view, row_id("openai-compatible"))
      # Identity is stable per account: the earlier two did not move.
      assert stored_profile("zai")["name"] == "Z.ai (Zhipu AI)"
      assert stored_profile("zai-2")["name"] == "Z.ai (Zhipu AI)-2"
    end

    test "the wizard gates Next/Back and clamps at both ends", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      start_wizard(view)
      assert has_element?(view, "#wizard-step-provider")
      # Step 1: Back is disabled, and Next is disabled until a provider is chosen.
      assert has_element?(view, ~s|#{wizard_button("provider_wizard_back")}[disabled]|)
      assert has_element?(view, ~s|#{wizard_button("provider_wizard_next")}[disabled]|)
      # Repeated Back at the FIRST step clamps instead of crashing (the
      # control is disabled, so the event is dispatched directly).
      render_click(view, "provider_wizard_back", %{})
      render_click(view, "provider_wizard_back", %{})
      assert assigns(view).provider_wizard.step == :provider
      assert has_element?(view, "#wizard-step-provider")
      pick_provider(view, "zai")
      refute has_element?(view, ~s|#{wizard_button("provider_wizard_next")}[disabled]|)
      wizard_next(view)
      assert has_element?(view, "#wizard-step-auth")
      wizard_next(view)
      assert has_element?(view, "#wizard-step-model")
      # Step 3 gates on an actual model choice.
      assert has_element?(view, ~s|#{wizard_button("provider_wizard_next")}[disabled]|)
      choose_custom_model(view, "glm-4.6")
      refute has_element?(view, ~s|#{wizard_button("provider_wizard_next")}[disabled]|)
      wizard_next(view)
      assert has_element?(view, "#wizard-step-reasoning_schedule")
      assert has_element?(view, wizard_button("provider_wizard_save"))
      # Repeated Next at the LAST rendered step clamps (the last step saves).
      render_click(view, "provider_wizard_next", %{})
      render_click(view, "provider_wizard_next", %{})
      assert assigns(view).provider_wizard.step == :reasoning_schedule
      assert has_element?(view, "#wizard-step-reasoning_schedule")
      assert has_element?(view, "#provider-wizard")
      # Nothing was persisted by any of the navigation.
      assert stored_providers() == []
      settings_hook(view, "provider_wizard_cancel", %{})
      refute has_element?(view, "#provider-wizard")
      assert stored_providers() == []
    end

    test "the reasoning chips offer xhigh exactly once (never max) and persist it once", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      start_wizard(view)
      pick_provider(view, "zai")
      wizard_next(view)
      wizard_next(view)
      choose_custom_model(view, "glm-4.6")
      wizard_next(view)
      assert has_element?(view, "#wizard-step-reasoning_schedule")
      # Regression pin: the chip list is ONE keyed list, so `xhigh` exists once
      # and the core wire alias `max` is never offered as a second effort.
      chips = checkbox_values(render(view))
      assert Enum.count(chips, &(&1 == "xhigh")) == 1
      refute "max" in chips
      assert count_occurrences(render(view), ~s(value="max")) == 0
      # Clicking the chip is a form change carrying the browser's payload (the
      # hidden empty seed plus the checked effort).
      view
      |> form("#provider-wizard-reasoning-form", %{reasoning_efforts: ["", "xhigh"]})
      |> render_change()

      chips = checkbox_values(render(view))
      assert Enum.count(chips, &(&1 == "xhigh")) == 1
      refute "max" in chips
      save_wizard(view)
      account = stored_profile("zai")
      assert account["reasoning_efforts"] == ["xhigh"]
      assert Enum.count(account["reasoning_efforts"], &(&1 == "xhigh")) == 1
      refute "max" in account["reasoning_efforts"]
      # The same ONE-list contract holds in the EXPANDED detail of the account
      # the wizard created (a second, independent chip render site).
      ensure_open(view, "zai")
      html = render(view)
      detail_chips = checkbox_values(html)
      assert Enum.count(detail_chips, &(&1 == "xhigh")) == 1
      refute "max" in detail_chips
      assert count_occurrences(html, ~s(value="max")) == 0
      assert has_element?(view, ~s(#{detail_id("zai")} input[value="xhigh"]))
    end
  end

  describe "the account panel accordion" do
    test "opening a second account collapses the first — exactly one detail in the document", %{
      conn: conn
    } do
      seed_provider_profiles([
        {"first", "openai", "gpt-5"},
        {"second", "deepseek", "deepseek-v4-pro"}
      ])

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      assert detail_form_count(view) == 0
      open_account(view, "first")
      assert assigns(view).editing_profile_id == "first"
      assert detail_form_count(view) == 1
      assert has_element?(view, detail_id("first"))
      open_account(view, "second")
      assert assigns(view).editing_profile_id == "second"
      assert detail_form_count(view) == 1
      assert has_element?(view, ~s(#{row_id("first")}[data-expanded="false"]))
      assert has_element?(view, ~s(#{row_id("second")}[data-expanded="true"]))
      refute has_element?(view, detail_id("first"))
      assert has_element?(view, detail_id("second"))
      # The wizard-created account obeys the same rule.
      create_account(view, "zai", "glm-4.6")
      assert detail_form_count(view) == 1
      assert has_element?(view, detail_id("zai"))
      refute has_element?(view, detail_id("second"))
    end
  end

  describe "per-account model editing" do
    test "adding a model appends to THAT account and leaves the other untouched", %{conn: conn} do
      seed_provider_profiles([
        {"first", "openai", "gpt-5"},
        {"second", "deepseek", "deepseek-v4-pro"}
      ])

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      first_models_before = stored_profile("first")["models"]
      assert first_models_before == [%{"model" => "gpt-5"}]

      view
      |> element(~s(#{row_id("second")} button[phx-click="start_add_provider_model"]))
      |> render_click()

      # The inline model form is scoped to the account it was started from.
      assert has_element?(view, "#provider-model-form-second")
      refute has_element?(view, "#provider-model-form-first")

      view
      |> form("#wizard-custom-model-form", %{custom_model: "deepseek-lite"})
      |> render_change()

      assert has_element?(
               view,
               ~s|#provider-model-form-second button[phx-click="provider_model_save"]:not([disabled])|
             )

      view
      |> element(~s(#provider-model-form-second button[phx-click="provider_model_save"]))
      |> render_click()

      html = await_config_save(view)

      assert html =~ "Model added to the provider account."
      second = stored_profile("second")
      assert second["models"] == [%{"model" => "deepseek-v4-pro"}, %{"model" => "deepseek-lite"}]
      # The default model is not silently re-pointed at the new row.
      assert second["default_model"] == "deepseek-v4-pro"
      # Byte-identical: the OTHER account was not rewritten by this edit.
      assert stored_profile("first")["models"] == first_models_before
      refute has_element?(view, "#provider-model-form-second")
      # The new row renders in THAT account's editor.
      assert has_element?(
               view,
               ~s(#{detail_id("second")} input[name="models[1][model]"][value="deepseek-lite"])
             )

      # The panel's own canonical config agrees with the disk write.
      assert length(current_providers(view)) == 2
    end
  end

  describe "the per-account schedule editor" do
    test "applying a preset writes its schedule keys on Save", %{conn: conn} do
      seed_provider_profiles([
        {"first", "openai", "gpt-5"},
        {"second", "deepseek", "deepseek-v4-pro"}
      ])

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      ensure_open(view, "second")
      assert has_element?(view, "#provider-schedule-editor")
      refute has_element?(view, "#provider-schedule-applied")
      # The preset buttons come from the real per-provider preset list.
      presets = EvoDashWeb.LLMSetup.Schedule.presets_for_provider("deepseek")
      assert Enum.any?(presets, &(&1.id == "deepseek-standard"))

      for preset <- presets do
        assert has_element?(
                 view,
                 ~s|#provider-schedule-editor button[phx-click="apply_provider_schedule"][phx-value-preset_id="#{preset.id}"]|
               )
      end

      view
      |> element(~s(#provider-schedule-editor button[phx-value-preset_id="deepseek-standard"]))
      |> render_click()

      assert has_element?(view, "#provider-schedule-applied")
      draft = assigns(view).profile_form_draft
      assert draft["concurrency"] == 4
      assert draft["peak_concurrency"] == 2
      html = submit_detail_form(view, "second", %{})
      assert html =~ "Provider profile saved."
      second = stored_profile("second")
      assert second["concurrency"] == 4
      assert second["peak_concurrency"] == 2
      assert second["timezone"] == "UTC"
      assert Enum.sort(second["off_peak_days"]) == ["sat", "sun"]
      assert second["off_peak_holidays"] == "CN"
      assert length(second["peak_hours"]) == 2
      assert Enum.all?(second["peak_hours"], &(&1["days"] == ["weekdays"]))

      assert second["peak_hours"] |> Enum.map(&{&1["start"], &1["end"]}) |> Enum.sort() ==
               [{"01:00", "04:00"}, {"06:00", "10:00"}]

      # No fan-out: the sibling account kept its own (absent) schedule.
      first = stored_profile("first")
      assert first["concurrency"] == 3
      refute Map.has_key?(first, "peak_hours")
      refute Map.has_key?(first, "peak_concurrency")
      refute Map.has_key?(first, "off_peak_days")
      assert first["models"] == [%{"model" => "gpt-5"}]
    end

    test "Undo restores the pre-apply values and clears the modified hint", %{conn: conn} do
      seed_provider_profiles([{"second", "deepseek", "deepseek-v4-pro"}], "second")
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      ensure_open(view, "second")
      pre_apply_draft = assigns(view).profile_form_draft
      assert pre_apply_draft["concurrency"] == 3
      refute Map.has_key?(pre_apply_draft, "peak_hours")

      preset_click = fn ->
        view
        |> element(~s(#provider-schedule-editor button[phx-value-preset_id="deepseek-standard"]))
        |> render_click()
      end

      preset_click.()
      assert has_element?(view, "#provider-schedule-applied")
      assert assigns(view).profile_form_draft["concurrency"] == 4
      # A later form edit makes the applied recommendation stale.
      html = settings_hook(view, "provider_profile_form_change", %{"concurrency" => "9"})
      assert html =~ "modified after applying"
      assert assigns(view).profile_form_draft["concurrency"] == "9"
      # Undo is still offered and restores the PRE-APPLY schedule verbatim.
      view |> element(~s(button[phx-click="undo_provider_schedule"])) |> render_click()
      refute render(view) =~ "modified after applying"
      refute has_element?(view, "#provider-schedule-applied")
      assert assigns(view).profile_form_draft == pre_apply_draft
      # Saving the undone draft persists the pre-apply values, not the preset.
      submit_detail_form(view, "second", %{})
      saved = stored_profile("second")
      assert saved["concurrency"] == 3
      refute Map.has_key?(saved, "peak_hours")
      refute Map.has_key?(saved, "peak_concurrency")
      refute Map.has_key?(saved, "timezone")
      refute Map.has_key?(saved, "off_peak_days")
      refute Map.has_key?(saved, "off_peak_holidays")
      assert saved["models"] == [%{"model" => "deepseek-v4-pro"}]
    end

    test "off_peak_holidays round-trips and is omitted while blank", %{conn: conn} do
      seed_provider_profiles([{"second", "deepseek", "deepseek-v4-pro"}], "second")
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      ensure_open(view, "second")

      assert has_element?(
               view,
               ~s(#{detail_id("second")} select#provider-off-peak-holidays[name="off_peak_holidays"])
             )

      submit_detail_form(view, "second", %{"off_peak_holidays" => "CN"})
      assert stored_profile("second")["off_peak_holidays"] == "CN"
      # Blank selection drops the key instead of persisting "".
      ensure_open(view, "second")
      submit_detail_form(view, "second", %{"off_peak_holidays" => ""})
      refute Map.has_key?(stored_profile("second"), "off_peak_holidays")
    end
  end

  # ── in-browser Sign in with ChatGPT (the wizard's auth step) ───────────────
  #
  # Hermetic: the flow module is the per-test `ChatGPTStub` injected through the
  # sign-in boundary's CALL-TIME seam, so no loopback listener is bound, no
  # network is touched and nothing BEAM-global is mutated.
  describe "in-browser ChatGPT sign-in" do
    test "a local sign-in waits on a real link and continues with the connected account", %{
      conn: conn
    } do
      ChatGPTStub.install!(
        begin: {:ok, %{id: "flow-1", url: "https://auth.openai.com/x", port: 48_123}},
        statuses: [:pending, {:ok, %{account: "work"}}]
      )

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_chatgpt_auth_step(view)

      # LOCAL page: the in-browser button, never the terminal command.
      assert has_element?(view, "#settings-chatgpt-sign-in")
      refute has_element?(view, "#settings-chatgpt-manual-hint")
      assert has_element?(view, ~s|#{wizard_button("provider_wizard_next")}[disabled]|)

      # The registration the browser flow installs lands in the store while the
      # page waits; the poll's success is what reloads the account list.
      EvoGit.TestSupport.ChatGPTFixture.seed!("work")

      click_html = view |> element("#settings-chatgpt-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, account}
      # No explicit selection yet -> the account the picker resolves to.
      assert account == "default"

      # The WAITING state and its authorization link are read from the CLICK's
      # OWN render. The stub resolves the flow on its SECOND poll tick, which the
      # LiveView may apply the instant this event returns, so a further client
      # call (`has_element?` and then `element(...)` are two separate renders)
      # could already see the connected state and lose the link. The click reply
      # is the one snapshot atomic with the state it pins.
      assert [waiting] =
               Floki.find(Floki.parse_fragment!(click_html), "#settings-chatgpt-waiting")

      assert [link] = Floki.find(waiting, "#settings-chatgpt-sign-in-url")
      assert Floki.attribute(link, "href") == ["https://auth.openai.com/x"]
      assert Floki.attribute(link, "target") == ["_blank"]

      html = await_sign_in(view, :ok)

      assert assigns(view).provider_wizard.draft["siwc_account"] == "work"
      assert Map.has_key?(assigns(view).provider_wizard.chatgpt_accounts, "work")
      assert html =~ "ChatGPT connected"
      # The panel is back to its idle button and the step can be left.
      assert has_element?(view, "#settings-chatgpt-sign-in")
      refute has_element?(view, "#settings-chatgpt-waiting")
      refute has_element?(view, ~s|#{wizard_button("provider_wizard_next")}[disabled]|)

      # ...and the wizard continues with THAT account's model inventory.
      wizard_next(view)
      assert has_element?(view, "#wizard-step-model")
      assert has_element?(view, ~s(button[phx-value-model="gpt-5.6-terra"]))
    end

    test "cancel abandons the flow and brings the sign-in button back", %{conn: conn} do
      ChatGPTStub.install!(
        begin: {:ok, %{id: "flow-1", url: "https://auth.openai.com/x", port: 48_123}}
      )

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_chatgpt_auth_step(view)

      view |> element("#settings-chatgpt-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}
      # The flow call is an async RPC, so await the APPLIED phase first.
      await_sign_in(view, :waiting)
      assert has_element?(view, "#settings-chatgpt-waiting")

      view |> element("#settings-chatgpt-sign-in-cancel") |> render_click()
      # The flow module really was cancelled, and the panel is quiet again.
      assert_receive {:chatgpt_stub, :cancel, "flow-1"}
      refute has_element?(view, "#settings-chatgpt-waiting")
      refute has_element?(view, "#settings-chatgpt-sign-in-error")
      assert has_element?(view, "#settings-chatgpt-sign-in")
      assert assigns(view).provider_wizard.chatgpt_sign_in.phase == :idle
    end

    test "a sign-in that cannot start shows a friendly line, never the raw reason", %{
      conn: conn
    } do
      ChatGPTStub.install!(begin: {:error, :loopback_listener_unavailable})

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_chatgpt_auth_step(view)

      html = view |> element("#settings-chatgpt-sign-in") |> render_click()
      await_sign_in(view, :error)

      refute has_element?(view, "#settings-chatgpt-waiting")
      assert has_element?(view, "#settings-chatgpt-sign-in-error")
      error = view |> element("#settings-chatgpt-sign-in-error") |> render()
      assert error =~ "Genesis could not start a local sign-in"
      refute error =~ "loopback_listener_unavailable"
      refute html =~ "loopback_listener_unavailable"
      # The button stays available for a retry.
      assert has_element?(view, "#settings-chatgpt-sign-in")
    end

    test "a denied authorization in the browser maps to the friendly denial line", %{
      conn: conn
    } do
      ChatGPTStub.install!(
        begin: {:ok, %{id: "flow-1", url: "https://auth.openai.com/x", port: 48_123}},
        statuses: [{:error, :authorization_denied}]
      )

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_chatgpt_auth_step(view)
      view |> element("#settings-chatgpt-sign-in") |> render_click()
      assert_receive {:chatgpt_stub, :begin, _account}

      html = await_sign_in(view, :error)

      assert has_element?(view, "#settings-chatgpt-sign-in-error")
      error = view |> element("#settings-chatgpt-sign-in-error") |> render()
      assert error =~ "Sign-in was cancelled in the browser."
      refute error =~ "authorization_denied"
      refute html =~ "authorization_denied"
    end

    test "a result for a superseded flow changes nothing", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_chatgpt_auth_step(view)
      before = assigns(view).provider_wizard

      send(view.pid, {:chatgpt_signin_result, "other-flow", {:ok, %{account: "x"}}})
      render(view)

      after_state = assigns(view).provider_wizard
      assert after_state.draft == before.draft
      assert after_state.chatgpt_accounts == before.chatgpt_accounts
      assert after_state.chatgpt_sign_in == before.chatgpt_sign_in
      refute Map.has_key?(after_state.chatgpt_accounts, "x")
      refute has_element?(view, "#settings-chatgpt-account")
    end

    test "a remote node gets the CLI hint instead of a sign-in button", %{conn: conn} do
      id = "wizard-remote-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: id,
          name: "Wizard Remote"
        })

      on_exit(fn -> EvoGit.RemoteConnections.delete(id) end)

      start_supervised!(
        {EvoDashWeb.SettingsLive.ProviderWizardTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote_wizard@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = mount_settings(conn, "/settings?node=" <> id)
      assert assigns(view).current_node != node()

      open_chatgpt_auth_step(view)

      # The in-browser flow binds a loopback listener on THIS BEAM, so a remote
      # execution node can only be connected through the CLI.
      refute has_element?(view, "#settings-chatgpt-sign-in")
      assert has_element?(view, "#settings-chatgpt-manual-hint")
      hint = view |> element("#settings-chatgpt-manual-hint") |> render()
      assert hint =~ "genesis chatgpt login"
      assert hint =~ "same machine as the execution node"
    end
  end
end
