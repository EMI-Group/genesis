# Settings page (`/settings`) — OAuth / subscription LLM auth suite.
#
# Covers the parts of the dashboard auth flow that are NOT pure data
# transformations (those live in `settings_live/model_profile_helpers_test.exs`):
#
#   * the per-profile credential-status line rendered by the model-profiles
#     editor (`EvoDashWeb.SettingsLive.AuthStatus` → `:auth_statuses`);
#   * the node + seq stale guards of `{:settings_auth_status_loaded, ...}`;
#   * the `refresh_auth_status` event that re-requests the load;
#   * profile persistence of `auth_mode` / `oauth_file` through the real
#     editor events (`add_model_profile` → `save_model_profile`);
#   * the Quick Setup card's OAuth-only branch (login guidance instead of an
#     API-key form).
#
# ASYNC by default (`test/CONTEXT.md`): every test touches only per-process
# state — the config directory comes from the `:config_dir_fun` seam
# (`EvoDash.Test.ConfigDir.isolate!/1`) and this module clears ONLY the local
# `{nil, node()}` `EvoDash.ActiveTasks` context.
defmodule EvoDashWeb.SettingsLive.AuthStatusTest do
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  # Seeded profile ids. `profile-1` is anthropic WITH `auth_mode = "oauth"`,
  # `profile-2` is the OAuth-only `openai_codex`, and `profile-3` is a plain
  # anthropic API-key profile (which must render NO status line).
  @oauth_profile "profile-1"
  @oauth_only_profile "profile-2"
  @api_key_profile "profile-3"

  # An injected `:ok` status. The managed path is a fixed literal so a test can
  # prove the payload was NOT applied by refuting it (nothing else in the page
  # ever renders that path: the default managed file lives inside the per-test
  # temp config dir).
  @ok_entry %{
    state: :ok,
    expires: 4_102_444_800_000,
    account_id: "acct",
    login_instructions: nil,
    oauth_file: "/tmp/genesis/auth.json"
  }

  @claude_instructions "Run `claude` and log in once"

  setup do
    # Per-process config isolation through the `:config_dir_fun` seam (installed
    # by `test/test_helper.exs`): every mount + load task inherits it via
    # `$callers`, so nothing is BEAM-global and no env restore is needed.
    dir = EvoDash.Test.ConfigDir.isolate!("evogit_settings_auth_status_test")
    on_exit(fn -> File.rm_rf!(dir) end)

    # Process-less public ETS table shared by the whole run — clear ONLY the
    # local context (a whole-table reset would delete a concurrent module's
    # per-test snapshot).
    EvoDash.ActiveTasks.invalidate(nil, node())

    {:ok, config_root: dir}
  end

  describe "credential status apply (injected result)" do
    # KNOWN PRODUCTION GAP (reported, not fixed here): `settings_live.ex` never
    # passes `auth_statuses={@auth_statuses}` to
    # `SettingsComponents.category_section/1`, so the model-profiles editor
    # always receives `%{}` and every credential line renders NEUTRAL
    # ("Subscription login") even though `@auth_statuses` on the LiveView holds
    # the real map. These tests therefore pin the LiveView-level contract (the
    # assign the editor consumes); the verdict/guidance text is covered
    # component-side.
    test "an :ok status is applied to :auth_statuses", %{conn: conn, config_root: dir} do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      inject_statuses(view, %{@oauth_profile => @ok_entry})
      assert assigns(view).auth_statuses == %{@oauth_profile => @ok_entry}
    end

    test "a :missing status keeps its login instructions on the assign", %{
      conn: conn,
      config_root: dir
    } do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      entry = %{
        state: :missing,
        expires: nil,
        account_id: nil,
        login_instructions: @claude_instructions,
        oauth_file: "/tmp/genesis/auth.json"
      }

      inject_statuses(view, %{@oauth_profile => entry})
      assert assigns(view).auth_statuses == %{@oauth_profile => entry}
    end

    test "an :unknown status is applied without a verdict", %{conn: conn, config_root: dir} do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      entry = %{
        state: :unknown,
        expires: nil,
        account_id: nil,
        login_instructions: nil,
        oauth_file: nil
      }

      inject_statuses(view, %{@oauth_profile => entry})
      assert assigns(view).auth_statuses == %{@oauth_profile => entry}
      assert Map.get(assigns(view).auth_statuses, @oauth_profile).state == :unknown
    end

    test "an entry keyed by a DIFFERENT profile id never lands under the OAuth profile", %{
      conn: conn,
      config_root: dir
    } do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      # The apply REPLACES the map wholesale; a status describing some other
      # profile must not be projected onto a seeded one (the editor looks the
      # entry up by SAVED profile id).
      inject_statuses(view, %{"some-other-profile" => @ok_entry})
      statuses = assigns(view).auth_statuses
      refute Map.has_key?(statuses, @oauth_profile)
      refute Map.has_key?(statuses, @oauth_only_profile)
      assert statuses == %{"some-other-profile" => @ok_entry}
    end

    test "only OAuth-enabled profiles render a credential status line at all", %{
      conn: conn,
      config_root: dir
    } do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      # One status line each for the anthropic-oauth and openai_codex profiles;
      # the anthropic API-key profile renders none (and its badge stays "API key").
      html = render(view)
      assert count_status_lines(html) == 2
      assert html =~ "API key"
    end

    test "an API-key-only configuration renders no credential status line", %{conn: conn} do
      seed_model_profiles([
        %{id: @api_key_profile, provider: "anthropic", model_id: "claude-sonnet-5-5"}
      ])

      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html = render(view)
      assert count_status_lines(html) == 0
      refute html =~ "Recheck"
    end
  end

  describe "stale guards on {:settings_auth_status_loaded, ...}" do
    test "a foreign-node result is dropped (assign and rendered status unchanged)", %{
      conn: conn,
      config_root: dir
    } do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      render_hook(view, "edit_model_profile", %{"profile_id" => @oauth_profile})

      baseline = assigns(view).auth_statuses
      assert_oauth_baseline(baseline)
      assert render(view) =~ "Recheck"

      html =
        inject_statuses(view, %{@oauth_profile => @ok_entry}, :other@nonexistent)

      assert assigns(view).auth_statuses == baseline
      # The injected payload never reached the render: its managed path would
      # only ever appear from an applied :ok entry.
      refute html =~ "/tmp/genesis/auth.json"
      refute html =~ "Login detected"
    end

    test "a superseded seq is dropped (assign and rendered status unchanged)", %{
      conn: conn,
      config_root: dir
    } do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      render_hook(view, "edit_model_profile", %{"profile_id" => @oauth_profile})

      baseline = assigns(view).auth_statuses
      assert_oauth_baseline(baseline)

      seq = assigns(view).auth_status_seq

      send(
        view.pid,
        {:settings_auth_status_loaded, node(), seq + 5, %{@oauth_profile => @ok_entry}}
      )

      html = render(view)

      assert assigns(view).auth_statuses == baseline
      refute html =~ "/tmp/genesis/auth.json"
      refute html =~ "Login detected"
    end

    test "the matching node + seq DOES apply (positive control)", %{
      conn: conn,
      config_root: dir
    } do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      html = inject_statuses(view, %{@oauth_profile => @ok_entry})
      assert assigns(view).auth_statuses == %{@oauth_profile => @ok_entry}
      # The editor renders one "Recheck" trigger per OAuth-enabled profile.
      assert count_status_lines(html) == 2
    end
  end

  describe "refresh_auth_status event" do
    test "bumps the sequence (a new async load is requested) and the editor exposes the trigger",
         %{conn: conn, config_root: dir} do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      assert render(view) =~ ~s(phx-click="refresh_auth_status")

      before_seq = assigns(view).auth_status_seq
      render_hook(view, "refresh_auth_status", %{})
      assert assigns(view).auth_status_seq == before_seq + 1

      # Every click requests its own load — the result of the first one may land
      # in between, which never moves the sequence backwards.
      render_hook(view, "refresh_auth_status", %{})
      assert assigns(view).auth_status_seq == before_seq + 2
    end
  end

  describe "profile save round-trip (auth_mode / oauth_file persistence)" do
    test "an OAuth anthropic profile persists both keys to config.toml", %{
      conn: conn,
      config_root: dir
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      creds = Path.join(dir, "claude-creds.json")

      html =
        save_new_profile(view, %{
          "provider" => "anthropic",
          "model_id" => "claude-opus-5-5",
          "auth_mode" => "oauth",
          "oauth_file" => creds
        })

      assert html =~ "Model profile saved."

      [profile] = current_models(view)
      assert profile.model == "anthropic:claude-opus-5-5"
      assert profile.auth_mode == "oauth"
      assert profile.oauth_file == creds

      assert [persisted] = persisted_models()
      assert persisted["auth_mode"] == "oauth"
      assert persisted["oauth_file"] == creds
    end

    test "the API-key default persists NEITHER key (clean TOML)", %{
      conn: conn,
      config_root: dir
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html =
        save_new_profile(view, %{
          "provider" => "anthropic",
          "model_id" => "claude-opus-5-5",
          "auth_mode" => "api_key",
          "oauth_file" => Path.join(dir, "claude-creds.json")
        })

      assert html =~ "Model profile saved."

      [profile] = current_models(view)
      refute Map.has_key?(profile, :auth_mode)
      refute Map.has_key?(profile, :oauth_file)

      assert [persisted] = persisted_models()
      refute Map.has_key?(persisted, "auth_mode")
      refute Map.has_key?(persisted, "oauth_file")
    end

    test "an OAuth-unsupported provider persists NEITHER key", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html =
        save_new_profile(view, %{
          "provider" => "deepseek",
          "model_id" => "deepseek-v4-pro",
          "auth_mode" => "oauth",
          "oauth_file" => "/tmp/genesis/auth.json"
        })

      assert html =~ "Model profile saved."

      [profile] = current_models(view)
      refute Map.has_key?(profile, :auth_mode)
      refute Map.has_key?(profile, :oauth_file)

      assert [persisted] = persisted_models()
      refute Map.has_key?(persisted, "auth_mode")
      refute Map.has_key?(persisted, "oauth_file")
    end

    test "a blank oauth_file keeps auth_mode and omits only the path", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html =
        save_new_profile(view, %{
          "provider" => "anthropic",
          "model_id" => "claude-opus-5-5",
          "auth_mode" => "oauth",
          "oauth_file" => "   "
        })

      assert html =~ "Model profile saved."

      [profile] = current_models(view)
      assert profile.auth_mode == "oauth"
      refute Map.has_key?(profile, :oauth_file)

      assert [persisted] = persisted_models()
      assert persisted["auth_mode"] == "oauth"
      refute Map.has_key?(persisted, "oauth_file")
    end

    test "an OAuth-only provider is self-describing without any auth_mode form value", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html =
        save_new_profile(view, %{"provider" => "openai_codex", "model_id" => "gpt-5.6-terra"})

      assert html =~ "Model profile saved."

      [profile] = current_models(view)
      assert profile.model == "openai_codex:gpt-5.6-terra"
      assert profile.auth_mode == "oauth"

      assert [persisted] = persisted_models()
      assert persisted["auth_mode"] == "oauth"
      refute Map.has_key?(persisted, "oauth_file")
    end
  end

  describe "Quick Setup OAuth-only provider" do
    test "openai_codex replaces the API-key form with the subscription login guidance", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html = select_quick_setup_model(view, "openai_codex", "openai_codex:gpt-5.6-terra")

      assert html =~
               "This provider uses a subscription login. No API key needs to be pasted here."

      assert html =~ "Run `codex login` once"
      assert html =~ "Managed credential file: "
      refute html =~ ~s(phx-submit="save_api_key")
      refute html =~ ~s(name="api_key")
    end

    test "an OAuth-capable provider keeps the API-key form (API key is the default)", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html = select_quick_setup_model(view, "anthropic", "anthropic:claude-opus-5-5")

      assert html =~ ~s(phx-submit="save_api_key")
      assert html =~ ~s(name="api_key")
      refute html =~ "This provider uses a subscription login."
    end

    test "API-key-only providers keep the API-key form", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      for {provider_id, model_string} <- [
            {"deepseek", "deepseek:deepseek-v4-pro"},
            {"openai", "openai:gpt-5.6-terra"}
          ] do
        html = select_quick_setup_model(view, provider_id, model_string)

        assert html =~ ~s(phx-submit="save_api_key"),
               "expected an API-key form for #{provider_id}"

        assert html =~ ~s(name="api_key")
        refute html =~ "This provider uses a subscription login."
      end
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Helpers
  # ───────────────────────────────────────────────────────────────────────────

  # Mount funnel: every `/settings` mount kicks off async loads on
  # `EvoDash.TaskSupervisor` (the node-data read, and — spawned BY that load's
  # apply — the real `AuthStatus` load). A single wait round can therefore leave
  # the auth load in flight, and a result landing after the test's own injected
  # status would overwrite it. Wait + drain until a round finds no task.
  defp mount_settings(conn, path) do
    {:ok, view, html} = live(conn, path)
    settle_mount_loads(view)
    {:ok, view, html}
  end

  defp settle_mount_loads(view, rounds \\ 4) do
    pids = mount_async_task_pids(view.pid)
    Enum.each(Enum.map(pids, &Process.monitor/1), &await_task_down/1)

    # `render/1` is a synchronous round-trip: everything queued before it (the
    # tasks' result messages) is processed first, and that apply is what may
    # spawn the NEXT load.
    _ = render(view)

    if pids == [] or rounds == 0, do: :ok, else: settle_mount_loads(view, rounds - 1)
  end

  # A task that already exited delivers its :DOWN immediately (`:noproc`); the
  # send/2 carrying its result always happens BEFORE the process exits.
  defp await_task_down(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      5_000 -> :ok
    end
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

  # In LiveView 1.x the test View struct has no `.assigns` field, so we read
  # them from the underlying LiveView process socket.
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Delivers one `{:settings_auth_status_loaded, ...}` result for THIS node and
  # the CURRENT seq (both stale guards pass), then drains the mailbox via
  # render — the established direct-send pattern for async-loaded content.
  defp inject_statuses(view, statuses, target_node \\ nil) do
    seq = assigns(view).auth_status_seq
    send(view.pid, {:settings_auth_status_loaded, target_node || node(), seq, statuses})
    render(view)
  end

  defp current_models(view), do: get_in(assigns(view).file_config, [:llm, :models]) || []

  # The persisted config.toml, string-keyed (a TOML decode — what the next boot
  # reads back).
  defp persisted_models do
    get_in(EvoGit.Config.user_config(), ["llm", "models"]) || []
  end

  # Drives the REAL editor flow: add a draft profile, then submit its edit form.
  defp save_new_profile(view, params) do
    render_hook(view, "add_model_profile", %{})
    [draft] = current_models(view)

    render_hook(
      view,
      "save_model_profile",
      Map.merge(%{"profile_id" => draft.id, "profile_id_new" => draft.id}, params)
    )
  end

  defp select_quick_setup_model(view, provider_id, model_string) do
    render_hook(view, "select_llm_provider", %{"provider_id" => provider_id})
    render_hook(view, "select_llm_model", %{"model_string" => model_string})
  end

  # One "Recheck" trigger per rendered credential status line.
  defp count_status_lines(html) do
    html |> String.split(~s(phx-click="refresh_auth_status")) |> length() |> Kernel.-(1)
  end

  # The pre-injection baseline must be the REAL load's map for both seeded OAuth
  # profiles (never `%{}`): its verdict text is deterministic — see
  # `blocked_oauth_file/1` — so the stale-guard tests can refute a verdict.
  defp assert_oauth_baseline(baseline) do
    assert Enum.sort(Map.keys(baseline)) == [@oauth_profile, @oauth_only_profile]
  end

  # Seeds the three-profile fixture: an anthropic profile explicitly on OAuth,
  # the OAuth-only `openai_codex` profile, and an anthropic API-key profile.
  defp seed_oauth_profiles(dir) do
    blocked = blocked_oauth_file(dir)

    seed_model_profiles([
      %{
        id: @oauth_profile,
        provider: "anthropic",
        model_id: "claude-opus-5-5",
        auth_mode: "oauth",
        oauth_file: blocked
      },
      %{
        id: @oauth_only_profile,
        provider: "openai_codex",
        model_id: "gpt-5.6-terra",
        oauth_file: blocked
      },
      %{id: @api_key_profile, provider: "anthropic", model_id: "claude-sonnet-5-5"}
    ])
  end

  # A credential path the auth-status load can neither read nor create: its
  # parent is a regular FILE, so the managed-file read is `:invalid_credentials`
  # ("no subscription login") and the vendor import cannot write it — on ANY
  # host. That keeps the baseline verdict deterministic; in particular an
  # `openai_codex` profile never reports :ok just because the developer has
  # `~/.codex/auth.json`.
  defp blocked_oauth_file(dir) do
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "not a directory")
    Path.join(blocker, "auth.json")
  end

  # Writes `[[llm.models]]` blocks to this test's config.toml BEFORE the mount
  # (the per-test config dir makes the path unique, and the path-keyed config
  # cache is mtime+size validated). Optional keys are written only when present,
  # exactly like `save_model_profile` persists them.
  defp seed_model_profiles(profiles) do
    path = EvoGit.Config.config_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(profiles, "", &profile_toml/1))

    on_exit(fn ->
      # Teardown cleanup must not mask test failures.
      File.rm(path)
    end)
  end

  defp profile_toml(profile) do
    # The fixtures are ATOM-keyed, the TOML keys are strings — map explicitly.
    optional =
      for {key, toml_key} <- [auth_mode: "auth_mode", oauth_file: "oauth_file"],
          Map.has_key?(profile, key) do
        ~s(#{toml_key} = "#{Map.fetch!(profile, key)}"\n)
      end

    """
    [[llm.models]]
    id = "#{profile.id}"
    model = "#{profile.provider}:#{profile.model_id}"
    concurrency = 3
    #{Enum.join(optional, "")}
    """
  end
end
