defmodule EvoDash.UpdateStatusTest do
  # async: true — no async module WRITES the hub or these seams. The only other
  # writers (live_hooks/update_status_test, system_live_test, node_aware_test)
  # are async: false, so ExUnit never runs them concurrently with this module.
  # Async peers only READ the hub through the global LiveHooks.UpdateStatus
  # on-mount hook (a navigation-dot seed that no async suite asserts on) while
  # `desktop?/0` is transiently true. Every seam and env var this module mutates
  # is snapshot-restored in on_exit below.
  use ExUnit.Case, async: true

  alias EvoDash.UpdateStatus

  setup do
    # The hub is a shared global GenServer; reset it so tests are independent.
    # The notify-only override seam defaults to false so the full download flow
    # is testable regardless of the host platform (Linux CI without APPIMAGE
    # would otherwise be notify-only). Restored on exit.
    original_override = Application.get_env(:evo_dash, :update_notify_only_override)
    Application.put_env(:evo_dash, :update_notify_only_override, false)
    UpdateStatus.reset()

    on_exit(fn ->
      restore_env_value(:update_notify_only_override, original_override)
    end)

    :ok
  end

  describe "initial state" do
    test "is :idle with the documented field defaults, notify_only from the override seam" do
      Application.put_env(:evo_dash, :update_notify_only_override, true)
      UpdateStatus.reset()
      state = UpdateStatus.get()

      assert state.phase == :idle
      assert state.notify_only == true
      assert UpdateStatus.notify_only?() == true
      assert state.current_version == app_version()
      assert state.latest_version == nil
      assert state.notes == nil
      assert state.date == nil
      assert state.error == nil
      assert state.last_checked_at == nil
      assert state.download_requested_version == nil

      Application.put_env(:evo_dash, :update_notify_only_override, false)
      UpdateStatus.reset()
      assert UpdateStatus.get().notify_only == false
      assert UpdateStatus.notify_only?() == false
    end

    test "phase/0 is a shorthand for get().phase" do
      assert UpdateStatus.phase() == :idle
      assert UpdateStatus.phase() == UpdateStatus.get().phase
    end
  end

  describe "check_started/0" do
    test "transitions to :checking from :idle, :error (retryable) and :ready" do
      UpdateStatus.check_started()
      assert UpdateStatus.get().phase == :checking
      # A successful result from the :error phase really re-arms the machine.
      UpdateStatus.check_failed("boom")
      assert UpdateStatus.get().phase == :error

      UpdateStatus.check_started()
      assert UpdateStatus.get().phase == :checking
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      assert UpdateStatus.get().phase == :available
      assert UpdateStatus.get().error == nil

      UpdateStatus.handle_download_result(%{"status" => "ready", "version" => "1.0.0"})
      assert UpdateStatus.get().phase == :ready

      UpdateStatus.check_started()
      assert UpdateStatus.get().phase == :checking
    end
  end

  describe "handle_check_result/1" do
    test "\"available\" populates all fields, stamps last_checked_at and recomputes notify_only" do
      UpdateStatus.handle_check_result(%{
        "status" => "available",
        "current_version" => "0.1.0",
        "version" => "1.0.0",
        "body" => "Changelog body",
        "date" => "2026-08-01T00:00:00Z"
      })

      state = UpdateStatus.get()
      assert state.phase == :available
      assert state.current_version == "0.1.0"
      assert state.latest_version == "1.0.0"
      assert state.notes == "Changelog body"
      assert state.date == "2026-08-01T00:00:00Z"
      assert state.error == nil
      assert %DateTime{} = state.last_checked_at
      assert state.notify_only == false

      # notify_only is recomputed from the seam on every check result.
      Application.put_env(:evo_dash, :update_notify_only_override, true)
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      assert UpdateStatus.get().notify_only == true
    end

    test "\"up_to_date\" sets current_version, keeps versions/notes/date" do
      UpdateStatus.handle_check_result(%{
        "status" => "available",
        "current_version" => "0.1.0",
        "version" => "1.0.0",
        "body" => "body",
        "date" => "2026-08-01T00:00:00Z"
      })

      UpdateStatus.handle_check_result(%{"status" => "up_to_date", "current_version" => "1.0.0"})

      state = UpdateStatus.get()
      assert state.phase == :up_to_date
      assert state.current_version == "1.0.0"
      assert state.error == nil
      assert %DateTime{} = state.last_checked_at
      assert state.latest_version == "1.0.0"
      assert state.notes == "body"
      assert state.date == "2026-08-01T00:00:00Z"
    end

    test "\"not_configured\"/\"not_available\" set the error sentinel while keeping the feed data" do
      UpdateStatus.handle_check_result(%{"status" => "not_configured"})
      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "not_configured"

      UpdateStatus.reset()

      UpdateStatus.handle_check_result(%{
        "status" => "not_available",
        "current_version" => "0.1.0",
        "version" => "1.2.3",
        "body" => "Release notes",
        "date" => "2026-08-01T00:00:00Z"
      })

      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "not_available"
      assert state.current_version == "0.1.0"
      # Keep the feed's version/body/date so the card can show them.
      assert state.latest_version == "1.2.3"
      assert state.notes == "Release notes"
      assert state.date == "2026-08-01T00:00:00Z"

      # Without a version the previous latest_version is preserved.
      UpdateStatus.handle_check_result(%{"status" => "not_available"})
      assert UpdateStatus.get().latest_version == "1.2.3"
    end

    test "error paths store current_version when present and keep the seeded one otherwise" do
      for payload <- [
            %{"status" => "not_configured", "current_version" => "0.2.0"},
            %{"status" => "not_available", "current_version" => "0.2.0"},
            %{"status" => "error", "error" => "boom", "current_version" => "0.2.0"}
          ] do
        UpdateStatus.reset()
        UpdateStatus.handle_check_result(payload)
        assert UpdateStatus.get().current_version == "0.2.0", inspect(payload)
      end

      # Without current_version the seeded version survives every error path.
      for payload <- [
            %{"status" => "not_configured"},
            %{"status" => "not_available"},
            %{"status" => "error", "error" => "boom"}
          ] do
        UpdateStatus.reset()
        UpdateStatus.handle_check_result(payload)
        assert UpdateStatus.get().current_version == app_version(), inspect(payload)
      end
    end

    test "\"error\" uses the payload error, falls back to check_failed, and tracks versions" do
      UpdateStatus.handle_check_result(%{"status" => "error", "error" => "network down"})
      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "network down"

      UpdateStatus.reset()

      # No error key → the check_failed default.
      UpdateStatus.handle_check_result(%{"status" => "error"})
      assert UpdateStatus.get().phase == :error
      assert UpdateStatus.get().error == "check_failed"

      UpdateStatus.reset()

      # A version in the payload becomes latest_version; a later error without
      # one keeps the previous value.
      UpdateStatus.handle_check_result(%{
        "status" => "error",
        "error" => "Update check failed: network unreachable",
        "version" => "1.2.3"
      })

      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "Update check failed: network unreachable"
      assert state.latest_version == "1.2.3"

      UpdateStatus.handle_check_result(%{"status" => "error", "error" => "boom"})
      assert UpdateStatus.get().error == "boom"
      assert UpdateStatus.get().latest_version == "1.2.3"
    end

    test "unknown or garbage payloads normalize to :error check_failed without raising" do
      for payload <- [
            %{},
            %{"status" => "weird_status"},
            :not_a_map,
            nil,
            "string",
            42,
            [1, 2]
          ] do
        UpdateStatus.handle_check_result(payload)
        state = UpdateStatus.get()
        assert state.phase == :error, inspect(payload)
        assert state.error == "check_failed", inspect(payload)
      end
    end

    test "every check-result path terminates :checking (never wedge)" do
      results = [
        %{"status" => "available", "version" => "1.0.0"},
        %{"status" => "up_to_date"},
        %{"status" => "error", "error" => "boom"},
        %{"status" => "not_configured"},
        %{"status" => "not_available"},
        %{"status" => "weird"},
        %{},
        nil
      ]

      for payload <- results do
        UpdateStatus.check_started()
        assert UpdateStatus.get().phase == :checking
        UpdateStatus.handle_check_result(payload)
        refute UpdateStatus.get().phase == :checking
      end
    end
  end

  describe "request_download?/0" do
    test "true once per version, false for the same version, true again for a new version" do
      UpdateStatus.handle_check_result(%{
        "status" => "available",
        "version" => "1.0.0",
        "current_version" => "0.1.0"
      })

      assert UpdateStatus.request_download?() == true
      assert UpdateStatus.request_download?() == false
      assert UpdateStatus.get().download_requested_version == "1.0.0"

      # A fresh check for the SAME version does not re-arm the guard.
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      assert UpdateStatus.request_download?() == false

      # A NEW version resets the guard and triggers a fresh download.
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "2.0.0"})
      assert UpdateStatus.request_download?() == true
      assert UpdateStatus.get().download_requested_version == "2.0.0"
    end

    test "false outside :available, when notify_only, and when latest_version is nil" do
      refute UpdateStatus.request_download?()

      UpdateStatus.handle_check_result(%{"status" => "up_to_date"})
      refute UpdateStatus.request_download?()

      UpdateStatus.check_started()
      refute UpdateStatus.request_download?()

      Application.put_env(:evo_dash, :update_notify_only_override, true)
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      assert UpdateStatus.get().notify_only == true
      refute UpdateStatus.request_download?()

      Application.put_env(:evo_dash, :update_notify_only_override, false)
      UpdateStatus.reset()
      UpdateStatus.handle_check_result(%{"status" => "available"})
      assert UpdateStatus.get().phase == :available
      assert UpdateStatus.get().latest_version == nil
      refute UpdateStatus.request_download?()
    end
  end

  describe "handle_download_result/1" do
    test "\"ready\" transitions to :ready, keeping the existing latest_version when absent" do
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      UpdateStatus.handle_download_result(%{"status" => "ready", "version" => "1.0.0"})

      state = UpdateStatus.get()
      assert state.phase == :ready
      assert state.latest_version == "1.0.0"
      assert state.error == nil

      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      UpdateStatus.handle_download_result(%{"status" => "ready"})
      assert UpdateStatus.get().phase == :ready
      assert UpdateStatus.get().latest_version == "1.0.0"
    end

    test "\"error\" returns to :available from :available/:checking/:ready and to :error from :idle" do
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      UpdateStatus.handle_download_result(%{"status" => "error", "error" => "disk full"})

      assert UpdateStatus.get().phase == :available
      assert UpdateStatus.get().error == "disk full"

      UpdateStatus.check_started()
      UpdateStatus.handle_download_result(%{"status" => "error", "error" => "boom"})
      assert UpdateStatus.get().phase == :available

      UpdateStatus.handle_download_result(%{"status" => "ready"})
      assert UpdateStatus.get().phase == :ready
      UpdateStatus.handle_download_result(%{"status" => "error", "error" => "boom"})
      assert UpdateStatus.get().phase == :available
      assert UpdateStatus.get().error == "boom"

      # From :idle there is nothing to return to → :error.
      UpdateStatus.reset()
      UpdateStatus.handle_download_result(%{"status" => "error", "error" => "boom"})
      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "boom"
    end

    test "garbage payloads normalize to :error check_failed" do
      for payload <- [:not_a_map, nil, %{}, %{"status" => "weird"}] do
        UpdateStatus.handle_download_result(payload)
        state = UpdateStatus.get()
        assert state.phase == :error
        assert state.error == "check_failed"
      end
    end
  end

  describe "applying/0 and apply_failed/1" do
    test "applying transitions from :ready; apply_failed reverts to :error (never wedge)" do
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      UpdateStatus.handle_download_result(%{"status" => "ready"})
      UpdateStatus.applying()
      assert UpdateStatus.get().phase == :applying

      UpdateStatus.apply_failed("installer crashed")
      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "installer crashed"

      # apply_failed also works from other phases, and defaults the message.
      UpdateStatus.applying()
      UpdateStatus.apply_failed(nil)
      assert UpdateStatus.get().phase == :error
      assert UpdateStatus.get().error == "apply_failed"
    end
  end

  describe "check_failed/1" do
    test "terminates :checking with the given message, defaulting to check_failed" do
      UpdateStatus.check_started()
      assert UpdateStatus.get().phase == :checking
      UpdateStatus.check_failed("timeout")
      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "timeout"

      UpdateStatus.check_failed(nil)
      assert UpdateStatus.get().phase == :error
      assert UpdateStatus.get().error == "check_failed"
    end
  end

  describe "desktop?/0 and visible?/1" do
    test "desktop? reflects the :desktop_release env and EVOGIT_DESKTOP; visible? is local-only" do
      original_app_env = Application.get_env(:evo_dash, :desktop_release)
      original_sys_env = System.get_env("EVOGIT_DESKTOP")

      on_exit(fn ->
        restore_env_value(:desktop_release, original_app_env)
        restore_sys_env("EVOGIT_DESKTOP", original_sys_env)
      end)

      Application.delete_env(:evo_dash, :desktop_release)
      System.delete_env("EVOGIT_DESKTOP")
      refute UpdateStatus.desktop?()
      refute UpdateStatus.visible?(nil)
      refute UpdateStatus.visible?(node())

      Application.put_env(:evo_dash, :desktop_release, true)
      assert UpdateStatus.desktop?()
      assert UpdateStatus.visible?(nil)
      assert UpdateStatus.visible?(node())
      refute UpdateStatus.visible?(:some_remote_node)

      Application.delete_env(:evo_dash, :desktop_release)
      System.put_env("EVOGIT_DESKTOP", "1")
      assert UpdateStatus.desktop?()

      System.put_env("EVOGIT_DESKTOP", "0")
      refute UpdateStatus.desktop?()
    end
  end

  describe "broadcast" do
    test "every transition broadcasts {:update_status, state} on the updates topic" do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "updates")

      UpdateStatus.check_started()
      assert_receive {:update_status, %{phase: :checking} = state}, 1000
      assert state.phase == :checking

      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      assert_receive {:update_status, %{phase: :available} = state}, 1000
      assert state.latest_version == "1.0.0"

      UpdateStatus.handle_download_result(%{"status" => "ready"})
      assert_receive {:update_status, %{phase: :ready}}, 1000

      UpdateStatus.applying()
      assert_receive {:update_status, %{phase: :applying}}, 1000

      UpdateStatus.apply_failed("boom")
      assert_receive {:update_status, %{phase: :error, error: "boom"}}, 1000

      UpdateStatus.reset()
      assert_receive {:update_status, %{phase: :idle}}, 1000
    end
  end

  # Restores an Application env (handles a stored `false` value correctly —
  # `if value` would wrongly delete it).
  defp restore_env_value(key, original) do
    if original != nil do
      Application.put_env(:evo_dash, key, original)
    else
      Application.delete_env(:evo_dash, key)
    end
  end

  # The seeded current_version: the :evo_git app version (nil when not loaded).
  # Mirrors EvoDash.UpdateStatus.app_version/0.
  defp app_version do
    case Application.spec(:evo_git, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp restore_sys_env(key, original) do
    if original != nil do
      System.put_env(key, original)
    else
      System.delete_env(key)
    end
  end
end
