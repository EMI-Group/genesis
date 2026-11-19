# Settings → provider-account panel (`/settings?category=llm`) suite.
#
# Split out of `settings_live_test.exs` so both files stay reviewable: this
# module owns the provider-account list + expanded editor pins, and NOTHING
# here drives the deleted `add_model_profile` → `editing_profile_id: :new`
# shortcut (the new panel never renders that state). An account is either
# SEEDED on disk as a canonical `[[llm.providers]]` block and opened through
# `edit_provider_profile`, or created through the real wizard
# (`provider_wizard_test.exs` covers that flow end to end).
#
# ASYNC: every test touches only per-process state — the config directory comes
# from the `:config_dir_fun` seam (`EvoDash.Test.ConfigDir.isolate!/1`,
# installed by `test_helper.exs`), never from a BEAM-global `XDG_CONFIG_HOME`
# write.
defmodule EvoDashWeb.SettingsLive.ProviderPanelLiveTest do
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias EvoDashWeb.SettingsComponents.ProviderProfiles.Row

  # Load-tolerant budgets for waits on ASYNC settings work (mount load chain,
  # owned config-save receipt). That work runs in supervised tasks on a shared
  # host whose scheduling swings 10-30x (test/CONTEXT.md), so the waits stay
  # bounded but must not expire spuriously.
  @async_wait_budget_ms 30_000
  @assigns_timeout_ms 30_000

  # Local copies of the mount/settle/save helpers: this module must COMPILE and
  # run on its own (`mix test .../provider_panel_live_test.exs`), and the
  # shared `EvoDashWeb.SettingsLiveTest.Helpers` module only exists once
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
    dir = EvoDash.Test.ConfigDir.isolate!("evogit_settings_provider_panel_test")
    on_exit(fn -> File.rm_rf!(dir) end)
    # ActiveTasks is a process-less public ETS table shared by the whole run;
    # clear ONLY the local context so a concurrent module keeps its snapshot.
    EvoDash.ActiveTasks.invalidate(nil, node())
    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────
  defp current_providers(view), do: get_in(assigns(view).file_config, [:llm, :providers]) || []
  defp stored_providers, do: get_in(EvoGit.Config.user_config(), ["llm", "providers"]) || []
  defp row_id(id), do: "#provider-profile-" <> Row.slug(id)
  defp detail_id(id), do: "#provider-profile-detail-" <> Row.slug(id)
  # Counts the rendered expanded account forms in the WHOLE document, so the
  # "exactly one detail at a time" (accordion) contract is asserted without
  # depending on any single slug.
  defp detail_form_count(view),
    do: length(Regex.scan(~r/id="provider-profile-detail-/, render(view)))

  defp open_account(view, id),
    do: settings_hook(view, "edit_provider_profile", %{"profile_id" => id})

  defp account_params(id, overrides) do
    Map.merge(
      %{
        "profile_id" => id,
        "profile_id_new" => id,
        "provider" => "openai",
        "default_model" => "example",
        "models" => %{"0" => %{"model" => "example"}},
        "concurrency" => "3"
      },
      overrides
    )
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

  # A REAL form submit of the expanded account (the browser's own payload plus
  # the overrides), so the form's id, field names and submit wiring are pinned.
  defp submit_detail_form(view, id, overrides) do
    view |> form(detail_id(id), overrides) |> render_submit()
    await_config_save(view)
  end

  describe "account list & expanded editor" do
    test "an empty list offers account creation and the wizard cancels without persisting", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      assert has_element?(view, "#provider-profiles-panel")
      assert has_element?(view, ~s(button[phx-click="add_provider_profile"]))
      assert detail_form_count(view) == 0
      before = assigns(view).file_config
      disk = EvoGit.Config.user_config()
      view |> element(~s(button[phx-click="add_provider_profile"])) |> render_click()
      # The creation affordance is the WIZARD — no account form and no :new draft.
      assert has_element?(view, "#provider-wizard")
      assert detail_form_count(view) == 0
      refute assigns(view).editing_profile_id == :new
      assert assigns(view).file_config == before
      assert EvoGit.Config.user_config() == disk
      settings_hook(view, "provider_wizard_cancel", %{})
      refute has_element?(view, "#provider-wizard")
      assert detail_form_count(view) == 0
      assert assigns(view).file_config == before
      assert EvoGit.Config.user_config() == disk
    end

    test "a saved account renders its own row, expands in place and keeps Advanced closed", %{
      conn: conn
    } do
      seed_provider_profiles([{"default", "anthropic", "claude-sonnet-5-5"}])
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      assert has_element?(view, row_id("default"))
      assert has_element?(view, ~s(#{row_id("default")}[data-expanded="false"]))
      assert detail_form_count(view) == 0
      open_account(view, "default")
      assert assigns(view).editing_profile_id == "default"
      assert detail_form_count(view) == 1
      assert has_element?(view, ~s(#{row_id("default")}[data-expanded="true"]))
      # The form keeps the OLD, canonical field names — the owner parses them.
      assert has_element?(
               view,
               ~s(#{detail_id("default")}[phx-submit="save_provider_profile"][phx-change="provider_profile_form_change"])
             )

      assert has_element?(
               view,
               ~s(#{detail_id("default")} input[name="profile_id"][value="default"])
             )

      assert has_element?(view, ~s(input[name="profile_id_new"][value="default"]))
      assert has_element?(view, ~s(input[name="models[0][model]"][value="claude-sonnet-5-5"]))

      assert has_element?(
               view,
               ~s(select[name="default_model"] option[selected][value="claude-sonnet-5-5"])
             )

      # Optional settings live in the CLOSED Advanced disclosure.
      assert has_element?(view, "details#provider-profile-advanced:not([open])")
      assert has_element?(view, ~s(input[name="concurrency"][value="3"]))
      settings_hook(view, "cancel_edit_provider_profile", %{})
      assert assigns(view).editing_profile_id == nil
      assert assigns(view).profile_form_draft == nil
      assert detail_form_count(view) == 0
      assert has_element?(view, ~s(#{row_id("default")}[data-expanded="false"]))
    end

    test "opening a second account collapses the first (exactly one expanded detail)", %{
      conn: conn
    } do
      seed_provider_profiles([
        {"first", "openai", "gpt-5"},
        {"second", "anthropic", "claude-sonnet-5-5"}
      ])

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, "first")
      assert has_element?(view, detail_id("first"))
      open_account(view, "second")
      assert assigns(view).editing_profile_id == "second"
      assert detail_form_count(view) == 1
      assert has_element?(view, detail_id("second"))
      refute has_element?(view, detail_id("first"))
      assert has_element?(view, ~s(#{row_id("first")}[data-expanded="false"]))
    end

    test "the expanded editor saves identity, models, generation and concurrency", %{conn: conn} do
      seed_provider_profiles([{"default", "anthropic", "claude-sonnet-5-5"}])
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, "default")

      html =
        submit_detail_form(view, "default", %{
          "profile_id" => "default",
          "profile_id_new" => "default",
          "name" => "Primary account",
          "provider" => "anthropic",
          "default_model" => "claude-sonnet-5-5",
          "concurrency" => "5",
          "generation" => %{"temperature" => "0.7", "max_tokens" => "4096"},
          "models" => %{"0" => %{"model" => "claude-sonnet-5-5"}}
        })

      assert html =~ "Provider profile saved."
      assert assigns(view).editing_profile_id == nil
      assert assigns(view).profile_form_draft == nil
      assert [profile] = current_providers(view)
      assert profile["id"] == "default"
      assert profile["name"] == "Primary account"
      assert profile["provider"] == "anthropic"
      assert profile["default_model"] == "claude-sonnet-5-5"
      assert profile["concurrency"] == 5
      # Generation values are TYPED (float / integer) on the way out.
      assert profile["temperature"] == 0.7
      assert profile["max_tokens"] == 4096
      assert profile["models"] == [%{"model" => "claude-sonnet-5-5"}]
      assert stored_providers() == [profile]
      # The canonical save never writes a legacy `[[llm.models]]` shadow block.
      refute Map.has_key?(EvoGit.Config.user_config()["llm"], "models")
    end

    test "rename, default toggle and delete use the rendered account actions", %{conn: conn} do
      seed_provider_profiles(
        [{"first", "openai", "gpt-5"}, {"second", "anthropic", "claude-sonnet-5-5"}],
        "second"
      )

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, "second")

      settings_hook(
        view,
        "save_provider_profile",
        account_params("second", %{
          "profile_id_new" => "renamed",
          "provider" => "anthropic",
          "default_model" => "claude-sonnet-5-5",
          "models" => %{"0" => %{"model" => "claude-sonnet-5-5"}}
        })
      )

      assert EvoGit.Config.user_config()["llm"]["default_provider_profile"] == "renamed"
      assert Enum.map(stored_providers(), & &1["id"]) == ["first", "renamed"]
      # The renamed account keeps its models (a rename is not a reset).
      assert hd(stored_providers() |> Enum.at(1) |> Map.get("models"))["model"] ==
               "claude-sonnet-5-5"

      view
      |> element(
        ~s(button[phx-click="set_default_provider_profile"][phx-value-profile_id="first"])
      )
      |> render_click()

      await_config_save(view)
      assert EvoGit.Config.user_config()["llm"]["default_provider_profile"] == "first"

      view
      |> element(~s(button[phx-click="delete_provider_profile"][phx-value-profile_id="renamed"]))
      |> render_click()

      html = await_config_save(view)
      assert html =~ "Provider profile deleted."
      assert Enum.map(stored_providers(), & &1["id"]) == ["first"]
      assert EvoGit.Config.user_config()["llm"]["default_provider_profile"] == "first"
    end

    test "model row actions preserve unsaved nested input and reject an emptied collection", %{
      conn: conn
    } do
      seed_provider_profiles([{"default", "anthropic", "claude-sonnet-5-5"}])
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, "default")

      settings_hook(
        view,
        "provider_profile_form_change",
        account_params("default", %{
          "name" => "Typed name",
          "generation" => %{"temperature" => "0.7"},
          "models" => %{"0" => %{"model" => "typed", "generation" => %{"max_tokens" => "42"}}}
        })
      )

      view |> element(~s(button[phx-click="add_provider_model"])) |> render_click()
      assert has_element?(view, ~s(input[name="models[0][model]"][value="typed"]))
      assert has_element?(view, ~s(input[name="models[0][generation][max_tokens]"][value="42"]))
      assert has_element?(view, ~s(input[name="models[1][model]"][value=""]))
      # Account-level inputs survive the row insertion untouched.
      assert has_element?(view, ~s(input[name="generation[temperature]"][value="0.7"]))
      assert has_element?(view, ~s(input[name="name"][value="Typed name"]))
      draft = assigns(view).profile_form_draft
      # Out-of-range / non-integer indexes are inert (the draft is unchanged).
      for index <- ["-1", "garbage", "999"] do
        settings_hook(view, "remove_provider_model", %{"index" => index})
        assert assigns(view).profile_form_draft == draft
      end

      view
      |> element(~s(button[phx-click="remove_provider_model"][phx-value-index="1"]))
      |> render_click()

      assert assigns(view).profile_form_draft["models"] == [hd(draft["models"])]

      view
      |> element(~s(button[phx-click="remove_provider_model"][phx-value-index="0"]))
      |> render_click()

      assert assigns(view).profile_form_draft["models"] == []
      refute has_element?(view, ~s(input[name="models[0][model]"]))
      # The browser omits `models` entirely after the last removal; the draft's
      # authoritative [] must be rejected instead of inventing a model row.
      before_config = assigns(view).file_config
      before_disk = EvoGit.Config.user_config()

      emptied_input =
        account_params("default", %{
          "name" => "Typed name",
          "generation" => %{"temperature" => "0.7"}
        })
        |> Map.delete("models")

      html = settings_hook(view, "save_provider_profile", emptied_input)
      refute html =~ "Provider profile saved."

      assert assigns(view).flash["error"] =~
               ~s(default_model must be one of [], got \\"example\\")

      assert assigns(view).editing_profile_id == "default"
      assert assigns(view).profile_form_draft["models"] == []
      assert assigns(view).profile_form_draft["name"] == "Typed name"
      assert assigns(view).file_config == before_config
      assert EvoGit.Config.user_config() == before_disk
      # Correction: add the row back and save.
      settings_hook(view, "add_provider_model", %{})
      assert has_element?(view, ~s(input[name="models[0][model]"][value=""]))

      html =
        settings_hook(
          view,
          "save_provider_profile",
          Map.put(emptied_input, "models", %{"0" => %{"model" => "example"}})
        )

      assert html =~ "Provider profile saved."
      [saved] = stored_providers()
      assert saved["models"] == [%{"model" => "example"}]
      assert saved["name"] == "Typed name"
      assert saved["temperature"] == 0.7
      assert assigns(view).editing_profile_id == nil
      assert assigns(view).profile_form_draft == nil
    end

    test "two distinct models survive save, reload and remount, including the id new", %{
      conn: conn
    } do
      seed_provider_profiles([{"default", "anthropic", "claude-sonnet-5-5"}])
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, "default")

      input =
        account_params("default", %{
          "profile_id_new" => "new",
          "provider" => "anthropic",
          "default_model" => "first-model",
          "generation" => %{"temperature" => "0.7", "max_tokens" => "4096"},
          "models" => %{
            "0" => %{"model" => "first-model"},
            "1" => %{
              "model" => "second-model",
              "generation" => %{"temperature" => "0", "max_tokens" => "2048"}
            }
          }
        })

      settings_hook(view, "provider_profile_form_change", input)
      view |> form(detail_id("default"), input) |> render_submit()
      html = await_config_save(view)
      assert html =~ "Provider profile saved."
      [saved] = stored_providers()
      assert saved["id"] == "new"
      assert saved["default_model"] == "first-model"
      assert saved["temperature"] == 0.7
      assert saved["max_tokens"] == 4096

      assert saved["models"] == [
               %{"model" => "first-model"},
               %{"model" => "second-model", "temperature" => 0.0, "max_tokens" => 2048}
             ]

      # A page reload reads DISK, not the editor's candidate.
      render_patch(view, ~p"/settings?category=llm")
      await_mount_async_loads(view)
      assert current_providers(view) == [saved]
      open_account(view, "new")
      assert assigns(view).editing_profile_id == "new"
      assert has_element?(view, ~s(input[name="models[1][model]"][value="second-model"]))
      assert has_element?(view, ~s(input[name="models[1][generation][max_tokens]"][value="2048"]))
      GenServer.stop(view.pid)
      {:ok, remounted, _html} = mount_settings(conn, ~p"/settings")
      assert current_providers(remounted) == [saved]
      open_account(remounted, "new")
      assert assigns(remounted).editing_profile_id == "new"
      assert has_element?(remounted, ~s(input[name="models[0][model]"][value="first-model"]))

      assert has_element?(
               remounted,
               ~s(input[name="models[1][generation][temperature]"][value="0.0"])
             )
    end

    test "opening another account replaces the draft and cancel discards it", %{conn: conn} do
      seed_provider_profiles([
        {"first", "openai", "gpt-5"},
        {"second", "anthropic", "claude-sonnet-5-5"}
      ])

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, "first")

      settings_hook(
        view,
        "provider_profile_form_change",
        account_params("first", %{"name" => "Unsaved"})
      )

      open_account(view, "second")
      assert assigns(view).profile_form_draft["id"] == "second"
      refute assigns(view).profile_form_draft["name"] == "Unsaved"
      settings_hook(view, "cancel_edit_provider_profile", %{})
      assert assigns(view).editing_profile_id == nil
      assert assigns(view).profile_form_draft == nil
      assert assigns(view).profile_advanced_open == nil
      assert detail_form_count(view) == 0
    end

    test "off_peak_days and per-window days round-trip, including single-checked strings", %{
      conn: conn
    } do
      seed_provider_profiles([{"default", "anthropic", "claude-sonnet-5-5"}])
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, "default")

      html =
        settings_hook(
          view,
          "save_provider_profile",
          account_params("default", %{
            "provider" => "anthropic",
            "default_model" => "claude-sonnet-5-5",
            "models" => [%{"model" => "claude-sonnet-5-5"}],
            # Defensive normalization: trim + downcase + vocabulary whitelist +
            # order-preserving uniq; "funday" and the "" seed entry are dropped.
            "off_peak_days" => ["", " MON ", "fri", "mon", "funday"],
            "peak_hours" => %{
              "0" => %{"start" => "09:00", "end" => "12:00", "days" => ["", "mon", "Tue", "mon"]}
            }
          })
        )

      assert html =~ "Provider profile saved."
      [profile] = current_providers(view)
      assert profile["off_peak_days"] == ["mon", "fri"]
      [window] = profile["peak_hours"]
      assert (Map.get(window, "days") || Map.get(window, :days)) == ["mon", "tue"]
      file_profile = get_in(EvoGit.Config.user_config(), ["llm", "providers"]) |> hd()
      assert file_profile["off_peak_days"] == ["mon", "fri"]
      assert hd(file_profile["peak_hours"])["days"] == ["mon", "tue"]
      # Plug collapses a SINGLE checked chip to a bare string — must be wrapped.
      open_account(view, "default")

      html =
        settings_hook(
          view,
          "save_provider_profile",
          account_params("default", %{
            "provider" => "anthropic",
            "default_model" => "claude-sonnet-5-5",
            "models" => [%{"model" => "claude-sonnet-5-5"}],
            "off_peak_days" => "weekends",
            "peak_hours" => %{"0" => %{"start" => "09:00", "end" => "12:00", "days" => "mon"}}
          })
        )

      assert html =~ "Provider profile saved."
      file_profile = get_in(EvoGit.Config.user_config(), ["llm", "providers"]) |> hd()
      assert file_profile["off_peak_days"] == ["weekends"]
      assert hd(file_profile["peak_hours"])["days"] == ["mon"]
    end

    test "empty day selections are OMITTED from the saved account", %{conn: conn} do
      seed_provider_profiles([{"default", "anthropic", "claude-sonnet-5-5"}])
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, "default")

      html =
        settings_hook(
          view,
          "save_provider_profile",
          account_params("default", %{
            "provider" => "anthropic",
            "default_model" => "claude-sonnet-5-5",
            "models" => [%{"model" => "claude-sonnet-5-5"}],
            # All chips off → only the hidden-seed "" entry is submitted.
            "off_peak_days" => [""],
            "peak_hours" => %{"0" => %{"start" => "09:00", "end" => "12:00"}}
          })
        )

      assert html =~ "Provider profile saved."
      [profile] = current_providers(view)
      refute Map.has_key?(profile, :off_peak_days) or Map.has_key?(profile, "off_peak_days")
      # A no-days window stays EXACTLY %{start:, end:} (backward compatible).
      [window] = profile["peak_hours"]
      refute Map.has_key?(window, "days") or Map.has_key?(window, :days)
      assert Map.get(window, "start") == "09:00"
      assert Map.get(window, "end") == "12:00"
      file_profile = get_in(EvoGit.Config.user_config(), ["llm", "providers"]) |> hd()
      refute Map.has_key?(file_profile, "off_peak_days")
      assert hd(file_profile["peak_hours"]) == %{"start" => "09:00", "end" => "12:00"}
    end

    test "context_window is persisted as an integer and omitted when blank", %{conn: conn} do
      seed_provider_profiles([{"default", "anthropic", "claude-sonnet-5-5"}])
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, "default")

      html =
        settings_hook(
          view,
          "save_provider_profile",
          account_params("default", %{
            "provider" => "anthropic",
            "default_model" => "claude-sonnet-5-5",
            "concurrency" => "3",
            "generation" => %{"temperature" => "0.7"},
            "models" => [%{"model" => "claude-sonnet-5-5", "context_window" => "128000"}]
          })
        )

      assert html =~ "Provider profile saved."
      [profile] = current_providers(view)
      assert hd(profile["models"])["context_window"] == 128_000
      file_profile = get_in(EvoGit.Config.user_config(), ["llm", "providers"]) |> hd()
      assert hd(file_profile["models"])["context_window"] == 128_000
      # Re-save with a blank value: the key must be OMITTED (never nil), so the
      # core's default applies, while every other key survives.
      open_account(view, "default")

      html =
        settings_hook(
          view,
          "save_provider_profile",
          account_params("default", %{
            "provider" => "anthropic",
            "default_model" => "claude-sonnet-5-5",
            "concurrency" => "3",
            "generation" => %{"temperature" => "0.7"},
            "models" => [%{"model" => "claude-sonnet-5-5", "context_window" => ""}]
          })
        )

      assert html =~ "Provider profile saved."
      file_profile = get_in(EvoGit.Config.user_config(), ["llm", "providers"]) |> hd()
      refute Map.has_key?(hd(file_profile["models"]), "context_window")
      assert file_profile["default_model"] == "claude-sonnet-5-5"
      assert hd(file_profile["models"])["model"] == "claude-sonnet-5-5"
      assert file_profile["concurrency"] == 3
      assert file_profile["temperature"] == 0.7
    end

    test "off_peak_holidays round-trips through the real form (selected and blank)", %{
      conn: conn
    } do
      seed_provider_profiles([{"default", "anthropic", "claude-sonnet-5-5"}])
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      open_account(view, "default")
      # The holiday calendar is a real select inside the expanded form.
      assert has_element?(
               view,
               ~s(#{detail_id("default")} select#provider-off-peak-holidays[name="off_peak_holidays"])
             )

      html = submit_detail_form(view, "default", %{"off_peak_holidays" => "CN"})
      assert html =~ "Provider profile saved."
      file_profile = get_in(EvoGit.Config.user_config(), ["llm", "providers"]) |> hd()
      assert file_profile["off_peak_holidays"] == "CN"
      # Blank selection OMITS the key entirely.
      open_account(view, "default")
      html = submit_detail_form(view, "default", %{"off_peak_holidays" => ""})
      assert html =~ "Provider profile saved."
      file_profile = get_in(EvoGit.Config.user_config(), ["llm", "providers"]) |> hd()
      refute Map.has_key?(file_profile, "off_peak_holidays")
    end
  end
end
