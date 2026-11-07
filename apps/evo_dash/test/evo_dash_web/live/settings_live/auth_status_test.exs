# Settings page (`/settings`) — OAuth / subscription LLM auth suite.
#
# Covers the parts of the dashboard auth flow that are NOT pure data
# transformations (those live in `settings_live/model_profile_helpers_test.exs`):
#
#   * the per-profile credential-status line rendered by the model-profiles
#     editor (`EvoDashWeb.SettingsLive.AuthStatus` → `:auth_statuses`),
#     including that the page actually FORWARDS the map to the editor (verdict
#     text, login guidance and managed-file path on the rendered page);
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

  alias EvoDashWeb.SettingsLive.AuthStatus

  # Seeded profile ids. `profile-1` is anthropic WITH `auth_mode = "oauth"`,
  # `profile-2` is the OAuth-only `openai_codex`, `profile-3` is a plain
  # anthropic API-key profile and `profile-4` a plain deepseek API-key profile
  # (both of the last two must render NO status line).
  @oauth_profile "profile-1"
  @oauth_only_profile "profile-2"
  @api_key_profile "profile-3"
  @deepseek_profile "profile-4"

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
    dir = EvoDash.Test.ConfigDir.isolate!("evogit_settings_auth_status_test-#{System.pid()}")
    on_exit(fn -> File.rm_rf!(dir) end)

    # Process-less public ETS table shared by the whole run — clear ONLY the
    # local context (a whole-table reset would delete a concurrent module's
    # per-test snapshot).
    EvoDash.ActiveTasks.invalidate(nil, node())

    {:ok, config_root: dir}
  end

  describe "credential status apply (injected result)" do
    # These tests pin the LiveView-level ASSIGN the editor consumes; the
    # page-level RENDER of a verdict (the `auth_statuses` threading through
    # `SettingsComponents.category_section/1` into the editor) is covered by the
    # "credential status render" describe below.
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

  # The page must FORWARD `@auth_statuses` into the editor
  # (`category_section/1` → `model_profiles_editor/1`); an assign that never
  # reaches the render is a silent regression (every line falls back to the
  # neutral "Subscription login" text).
  describe "credential status render (injected result)" do
    test "an :ok status renders the login-detected line, its expiry and the managed path",
         %{conn: conn, config_root: dir} do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      # Open the profile's edit form: the summary row only carries the label,
      # the managed-file path lives in the (details: true) form line.
      render_hook(view, "edit_model_profile", %{"profile_id" => @oauth_profile})

      html = inject_statuses(view, %{@oauth_profile => @ok_entry})

      # `@ok_entry.expires` is 2100-01-01T00:00:00Z, rendered by
      # `EvoDashWeb.Helpers.format_datetime/1`.
      assert html =~ "Login detected (expires 2100-01-01 00:00)"
      assert html =~ "Managed credential file: /tmp/genesis/auth.json"
    end

    test "a :missing status renders the no-login guidance, the provider instructions and the path",
         %{conn: conn, config_root: dir} do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      render_hook(view, "edit_model_profile", %{"profile_id" => @oauth_profile})

      # `login_instructions: nil` exercises the canonical editor's own
      # node-aware fallback before the supplied-instructions assertion below.
      entry = %{
        state: :missing,
        expires: nil,
        account_id: nil,
        login_instructions: nil,
        oauth_file: "/tmp/genesis/missing-auth.json"
      }

      html = inject_statuses(view, %{@oauth_profile => entry})

      assert html =~ "No subscription login found"
      # A nil instruction uses the canonical editor's node-aware fallback.
      assert html =~
               "Run claude to sign in on the selected node, or use claude setup-token, then recheck."

      # A real loader supplies the core's full vendor instructions; pin every
      # word of that guidance too, normalizing serialized HTML whitespace only.
      instructions = EvoGit.Auth.login_instructions(:anthropic)

      html =
        inject_statuses(view, %{@oauth_profile => %{entry | login_instructions: instructions}})

      text = html |> Floki.parse_fragment!() |> Floki.text() |> normalize_whitespace()
      assert text =~ normalize_whitespace(instructions)
      # The injected managed path is the proof the payload reached the render:
      # the pre-injection baseline reports a different (per-test) path.
      assert html =~ "Managed credential file: /tmp/genesis/missing-auth.json"
      assert html =~ "Genesis imports the vendor login automatically on the next run."
    end

    test "an applied verdict replaces the profile's own baseline line", %{
      conn: conn,
      config_root: dir
    } do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      # Baseline: the blocked managed file makes the OAuth profiles :missing, so
      # the neutral "Subscription login" text is NOT what the page shows either.
      baseline_row = profile_row(render(view), @oauth_profile)
      assert baseline_row =~ "No subscription login found"
      refute baseline_row =~ "Login detected"

      html = inject_statuses(view, %{@oauth_profile => @ok_entry})
      row = profile_row(html, @oauth_profile)
      assert row =~ "Login detected"
      refute row =~ "No subscription login found"
    end

    test "an API-key-only profile renders no credential status line on the same page", %{
      conn: conn,
      config_root: dir
    } do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html = inject_statuses(view, %{@oauth_profile => @ok_entry})

      # Exactly the two OAuth-enabled profiles carry a status line.
      assert count_status_lines(html) == 2

      # The deepseek API-key profile renders no status line of any kind.
      row = profile_row(html, @deepseek_profile)
      assert row =~ "profile-4 · deepseek"
      assert row =~ "deepseek-v4-pro"
      refute row =~ "Recheck"
      refute row =~ "Login detected"
      refute row =~ "No subscription login found"
      refute row =~ "Subscription login"
    end

    # "The vendor login WAS found and parsed, but Genesis could not write its
    # managed copy" is its own state: the page must show the actionable
    # warning + managed path + writable-path remedy, and must NOT show the
    # one-time login guidance (the login is not the problem).
    test "an :unwritable status renders the actionable warning, never login guidance", %{
      conn: conn,
      config_root: dir
    } do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      render_hook(view, "edit_model_profile", %{"profile_id" => @oauth_profile})

      entry = %{
        state: :unwritable,
        expires: nil,
        account_id: nil,
        login_instructions: "SHOULD-NOT-RENDER-LOGIN-GUIDANCE",
        oauth_file: "/ro/genesis/auth.json"
      }

      html = inject_statuses(view, %{@oauth_profile => entry})

      assert html =~ "Login found, managed credential file not writable"
      assert html =~ "Managed credential file: /ro/genesis/auth.json"

      assert html =~
               "Set oauth_file on this profile to a writable location, then recheck."

      refute html =~ "Set [llm] oauth_file"

      # No login guidance of any kind, and no "we import it next run" note.
      refute html =~ "SHOULD-NOT-RENDER-LOGIN-GUIDANCE"
      refute html =~ "claude setup-token"
      refute html =~ "Genesis imports the vendor login automatically on the next run."
      refute html =~ "No subscription login found"
      refute html =~ "Login detected"
    end

    # Regression pin: the neutral state still renders neutral guidance with NO
    # verdict — the new state must not have swallowed it.
    test "an :unknown status keeps the neutral no-verdict line", %{
      conn: conn,
      config_root: dir
    } do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html = inject_statuses(view, %{@oauth_profile => %{state: :unknown}})

      assert html =~ "Subscription login"
      refute html =~ "Login detected"
      refute html =~ "No subscription login found"
      refute html =~ "Login found, managed credential file not writable"
    end
  end

  # The core's credential-status result → `:auth_statuses` state mapping, pinned
  # directly so the new outcome's shape contract cannot drift (the core end of
  # it lands in parallel; an older remote daemon never sends this atom at all).
  describe "credential status classification (pure)" do
    test "an unwritable managed file is its own state, never :unknown" do
      assert AuthStatus.classify({:error, {:managed_file_unwritable, :eacces}}, "/x/auth.json") ==
               {:unwritable, "/x/auth.json"}
    end

    test "the remote (erpc) shape classifies identically" do
      assert AuthStatus.classify_remote(
               {:ok, {:error, {:managed_file_unwritable, :eacces}}},
               {:ok, "/x/auth.json"}
             ) == {:unwritable, "/x/auth.json"}

      # A failed path lookup only drops the path; the state survives.
      assert AuthStatus.classify_remote(
               {:ok, {:error, {:managed_file_unwritable, :eacces}}},
               {:error, :badrpc}
             ) == {:unwritable, nil}
    end

    test "every other shape keeps its existing classification" do
      assert AuthStatus.classify({:ok, %{expires: 1, account_id: "a"}}, "/x") ==
               {:ok, %{expires: 1, account_id: "a"}, "/x"}

      assert AuthStatus.classify({:error, :no_credentials}, "/x") == {:missing, "/x"}
      assert AuthStatus.classify({:error, :invalid_credentials}, "/x") == {:missing, "/x"}

      # Atom-precise: a differently-named error tuple, a non-map verdict, a bare
      # term and a transport failure all stay neutral (neutral guidance, no
      # verdict) exactly as before.
      assert AuthStatus.classify({:error, {:managed_file_unwritable_reason, :x}}, "/x") ==
               :unknown

      assert AuthStatus.classify({:error, {:some_other_problem, :x}}, "/x") == :unknown
      assert AuthStatus.classify({:ok, "bogus"}, "/x") == :unknown
      assert AuthStatus.classify(:something_else, "/x") == :unknown
      assert AuthStatus.classify_remote({:error, :undef}, {:ok, "/x"}) == :unknown
      assert AuthStatus.classify_remote({:error, {:badrpc, :nodedown}}, {:ok, "/x"}) == :unknown
      assert AuthStatus.classify_remote({:ok, {:ok, "bogus"}}, {:ok, "/x"}) == :unknown
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

      # An older result and an unrequested future result are both stale: only
      # the exact active load sequence may replace a credential verdict.
      for stale_seq <- [seq - 1, seq + 5] do
        send(
          view.pid,
          {:settings_auth_status_loaded, node(), stale_seq, %{@oauth_profile => @ok_entry}}
        )

        html = render(view)

        assert assigns(view).auth_statuses == baseline
        refute html =~ "/tmp/genesis/auth.json"
        refute html =~ "Login detected"
      end
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
    test "editing a legacy OAuth row writes providers and removes the legacy shadow", %{
      conn: conn,
      config_root: dir
    } do
      seed_oauth_profiles(dir)
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      render_hook(view, "edit_model_profile", %{"profile_id" => @oauth_profile})
      draft = assigns(view).profile_form_draft
      assert draft["provider"] == "anthropic"
      assert draft["default_model"] == "claude-opus-5-5"
      assert draft["auth_mode"] == "oauth"

      render_hook(view, "save_model_profile", %{
        "profile_id" => @oauth_profile,
        "profile_id_new" => "renamed",
        "name" => "Edited subscription"
      })

      html = await_profile_save(view)
      assert assigns(view).flash == %{"info" => "Provider profile saved."}
      assert html =~ "Provider profile saved."
      assert assigns(view).editing_profile_id == nil
      assert length(current_models(view)) == 4
      persisted = persisted_models()
      assert Enum.map(persisted, & &1["id"]) == ["renamed", "profile-2", "profile-3", "profile-4"]
      edited = hd(persisted)
      assert edited["provider"] == "anthropic"
      assert edited["default_model"] == "claude-opus-5-5"
      assert edited["models"] == [%{"model" => "claude-opus-5-5"}]
      assert edited["name"] == "Edited subscription"
      assert edited["auth_mode"] == "oauth"
      assert edited["oauth_file"] == draft["oauth_file"]
      refute Map.has_key?(edited, "model")
    end

    test "an OAuth anthropic profile persists both keys to config.toml", %{
      conn: conn,
      config_root: dir
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")
      creds = Path.join(dir, "claude-creds.json")

      html =
        save_new_profile(view, %{
          "provider" => "anthropic",
          "default_model" => "claude-opus-5-5",
          "models" => %{"0" => %{"model" => "claude-opus-5-5"}},
          "auth_mode" => "oauth",
          "oauth_file" => creds
        })

      assert assigns(view).flash == %{"info" => "Provider profile saved."}
      assert html =~ "Provider profile saved."

      [profile] = current_models(view)
      assert profile["models"] == [%{"model" => "claude-opus-5-5"}]
      assert profile["provider"] == "anthropic"
      assert profile["default_model"] == "claude-opus-5-5"
      assert profile["auth_mode"] == "oauth"
      assert profile["oauth_file"] == creds

      assert [persisted] = persisted_models()
      assert persisted["models"] == profile["models"]
      assert persisted["auth_mode"] == "oauth"
      assert persisted["oauth_file"] == creds
    end

    test "the API-key default is explicit and drops a stale OAuth path", %{
      conn: conn,
      config_root: dir
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html =
        save_new_profile(view, %{
          "provider" => "anthropic",
          "default_model" => "claude-opus-5-5",
          "models" => %{"0" => %{"model" => "claude-opus-5-5"}},
          "auth_mode" => "api_key",
          "oauth_file" => Path.join(dir, "claude-creds.json")
        })

      assert assigns(view).flash == %{"info" => "Provider profile saved."}
      assert html =~ "Provider profile saved."

      [profile] = current_models(view)
      assert profile["models"] == [%{"model" => "claude-opus-5-5"}]
      assert profile["auth_mode"] == "api_key"
      refute Map.has_key?(profile, "oauth_file")

      assert [persisted] = persisted_models()
      assert persisted["models"] == profile["models"]
      assert persisted["auth_mode"] == "api_key"
      refute Map.has_key?(persisted, "oauth_file")
    end

    test "an OAuth-unsupported provider rejects the invalid mode without persisting", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html =
        save_new_profile(view, %{
          "provider" => "deepseek",
          "default_model" => "deepseek-v4-pro",
          "auth_mode" => "oauth",
          "oauth_file" => "/tmp/genesis/auth.json"
        })

      assert html =~ "Select a supported authentication mode for this provider."
      refute html =~ "Provider profile saved."
      assert current_models(view) == []
      assert persisted_models() == []
      assert assigns(view).editing_profile_id == :new
      assert assigns(view).profile_form_draft["auth_mode"] == "oauth"
    end

    test "a blank oauth_file keeps auth_mode and omits only the path", %{conn: conn} do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html =
        save_new_profile(view, %{
          "provider" => "anthropic",
          "default_model" => "claude-opus-5-5",
          "models" => %{"0" => %{"model" => "claude-opus-5-5"}},
          "auth_mode" => "oauth",
          "oauth_file" => "   "
        })

      assert assigns(view).flash == %{"info" => "Provider profile saved."}
      assert html =~ "Provider profile saved."

      [profile] = current_models(view)
      assert profile["models"] == [%{"model" => "claude-opus-5-5"}]
      assert profile["auth_mode"] == "oauth"
      refute Map.has_key?(profile, "oauth_file")

      assert [persisted] = persisted_models()
      assert persisted["models"] == profile["models"]
      assert persisted["auth_mode"] == "oauth"
      refute Map.has_key?(persisted, "oauth_file")
    end

    test "an OAuth-only provider is self-describing without any auth_mode form value", %{
      conn: conn
    } do
      {:ok, view, _html} = mount_settings(conn, ~p"/settings")

      html =
        save_new_profile(view, %{
          "provider" => "openai_codex",
          "default_model" => "gpt-5.6-terra",
          "models" => %{"0" => %{"model" => "gpt-5.6-terra"}}
        })

      assert assigns(view).flash == %{"info" => "Provider profile saved."}
      assert html =~ "Provider profile saved."

      [profile] = current_models(view)
      assert profile["models"] == [%{"model" => "gpt-5.6-terra"}]
      assert profile["provider"] == "openai_codex"
      assert profile["default_model"] == "gpt-5.6-terra"
      assert profile["auth_mode"] == "oauth"

      assert [persisted] = persisted_models()
      assert persisted["models"] == profile["models"]
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

  defp settle_mount_loads(view) do
    settle_mount_loads(view, System.monotonic_time(:millisecond) + 5_000)
  end

  defp settle_mount_loads(view, deadline) do
    # Drain applies BEFORE enumerating: an applied node-data result can spawn
    # the OAuth load, which must also finish before a test injects a verdict.
    _ = render(view)
    pids = mount_async_task_pids(view.pid)

    if pids != [] do
      Enum.each(pids, fn pid ->
        ref = Process.monitor(pid)
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          remaining -> flunk("Settings async loader did not settle")
        end
      end)

      assert System.monotonic_time(:millisecond) < deadline,
             "Settings async load chain did not settle"

      settle_mount_loads(view, deadline)
    end
  end

  defp mount_async_task_pids(view_pid) do
    EvoDash.TaskSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) ->
        callers = task_callers(pid)
        if is_nil(callers) or view_pid in callers, do: [pid], else: []

      _ ->
        []
    end)
  end

  defp task_callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$callers")
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
    settle_mount_loads(view)
    state = assigns(view)

    send(
      view.pid,
      {:settings_auth_status_loaded, target_node || state.current_node, state.auth_status_seq,
       statuses}
    )

    render(view)
  end

  defp current_models(view), do: get_in(assigns(view).file_config, [:llm, :providers]) || []

  # The persisted canonical config, not the read-side migration projection:
  # saving must remove the legacy shadow rather than merely prefer providers.
  defp persisted_models do
    llm = EvoGit.Config.user_config()["llm"] || %{}
    refute Map.has_key?(llm, "models")
    llm["providers"] || []
  end

  # Add creates a detached draft; only Save may put it in file_config.
  defp save_new_profile(view, params) do
    before = assigns(view).file_config
    render_hook(view, "add_model_profile", %{})
    assert assigns(view).file_config == before
    assert assigns(view).editing_profile_id == :new
    draft = assigns(view).profile_form_draft

    render_hook(
      view,
      "save_model_profile",
      Map.merge(%{"profile_id" => draft["id"], "profile_id_new" => draft["id"]}, params)
    )

    await_profile_save(view)
  end

  # Save dispatch is not persistence: wait for the owned writer receipt to
  # clear its marker, then drain the receipt's OAuth refresh before assertions
  # (and before teardown removes the config directory).
  defp await_profile_save(view) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_profile_save(view, deadline)
    settle_mount_loads(view)
    render(view)
  end

  defp await_profile_save(view, deadline) do
    state = assigns(view)

    if state.config_saving or state.config_save_request != nil do
      assert System.monotonic_time(:millisecond) < deadline,
             "provider save did not receive its authoritative completion"

      receive do
      after
        2 -> await_profile_save(view, deadline)
      end
    end
  end

  defp select_quick_setup_model(view, provider_id, model_string) do
    render_hook(view, "select_llm_provider", %{"provider_id" => provider_id})
    render_hook(view, "select_llm_model", %{"model_string" => model_string})
  end

  defp normalize_whitespace(text), do: text |> String.split() |> Enum.join(" ")

  # One "Recheck" trigger per rendered credential status line.
  defp count_status_lines(html) do
    html |> String.split(~s(phx-click="refresh_auth_status")) |> length() |> Kernel.-(1)
  end

  # Select the actual canonical account article by its Edit control, never by
  # legacy row classes or a substring spanning neighbouring accounts.
  defp profile_row(html, profile_id) do
    rows =
      html
      |> Floki.parse_fragment!()
      |> Floki.find("article")
      |> Enum.filter(fn article ->
        article
        |> Floki.find(~s(button[phx-click="edit_provider_profile"]))
        |> Floki.attribute("phx-value-profile_id")
        |> Enum.member?(profile_id)
      end)

    assert [row] = rows, "expected one canonical provider row for #{profile_id}"
    Floki.raw_html(row)
  end

  # The pre-injection baseline must be the REAL load's map for both seeded OAuth
  # profiles (never `%{}`): its verdict text is deterministic — see
  # `blocked_oauth_file/1` — so the stale-guard tests can refute a verdict.
  defp assert_oauth_baseline(baseline) do
    assert Enum.sort(Map.keys(baseline)) == [@oauth_profile, @oauth_only_profile]
  end

  # Seeds the four-profile fixture: an anthropic profile explicitly on OAuth,
  # the OAuth-only `openai_codex` profile, plus an anthropic and a deepseek
  # API-key profile (both must stay status-line-free).
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
      %{id: @api_key_profile, provider: "anthropic", model_id: "claude-sonnet-5-5"},
      %{id: @deepseek_profile, provider: "deepseek", model_id: "deepseek-v4-pro"}
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
