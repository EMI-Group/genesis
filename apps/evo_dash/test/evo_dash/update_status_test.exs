defmodule EvoDash.UpdateStatusTest do
  use ExUnit.Case, async: false

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
    test "is :idle with notify_only computed from the override seam" do
      Application.put_env(:evo_dash, :update_notify_only_override, true)
      UpdateStatus.reset()
      state = UpdateStatus.get()

      assert state.phase == :idle
      assert state.notify_only == true
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
    end

    test "notify_only?/0 reads the override seam" do
      Application.put_env(:evo_dash, :update_notify_only_override, true)
      assert UpdateStatus.notify_only?() == true

      Application.put_env(:evo_dash, :update_notify_only_override, false)
      assert UpdateStatus.notify_only?() == false
    end

    test "phase/0 is a shorthand for get().phase" do
      assert UpdateStatus.phase() == :idle
      assert UpdateStatus.phase() == UpdateStatus.get().phase
    end
  end

  describe "check_started/0" do
    test "transitions to :checking from :idle" do
      UpdateStatus.check_started()
      assert UpdateStatus.get().phase == :checking
    end

    test "transitions to :checking from :error (retryable)" do
      UpdateStatus.check_failed("boom")
      assert UpdateStatus.get().phase == :error

      UpdateStatus.check_started()
      assert UpdateStatus.get().phase == :checking
    end

    test "transitions to :checking from :ready" do
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      UpdateStatus.handle_download_result(%{"status" => "ready", "version" => "1.0.0"})
      assert UpdateStatus.get().phase == :ready

      UpdateStatus.check_started()
      assert UpdateStatus.get().phase == :checking
    end
  end

  describe "handle_check_result/1" do
    test "\"available\" populates all fields and sets last_checked_at" do
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
    end

    test "\"available\" recomputes notify_only from the seam" do
      Application.put_env(:evo_dash, :update_notify_only_override, true)
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      assert UpdateStatus.get().notify_only == true

      Application.put_env(:evo_dash, :update_notify_only_override, false)
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      assert UpdateStatus.get().notify_only == false
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

    test "\"not_configured\" sets the error sentinel" do
      UpdateStatus.handle_check_result(%{"status" => "not_configured"})
      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "not_configured"
    end

    test "\"not_available\" sets the error sentinel and stores current_version" do
      UpdateStatus.handle_check_result(%{
        "status" => "not_available",
        "current_version" => "0.1.0"
      })

      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "not_available"
      assert state.current_version == "0.1.0"
    end

    test "error paths store current_version so the version stays populated" do
      # not_configured
      UpdateStatus.handle_check_result(%{
        "status" => "not_configured",
        "current_version" => "0.2.0"
      })

      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "not_configured"
      assert state.current_version == "0.2.0"

      # not_available
      UpdateStatus.handle_check_result(%{
        "status" => "not_available",
        "current_version" => "0.2.0"
      })

      assert UpdateStatus.get().current_version == "0.2.0"

      # generic error
      UpdateStatus.handle_check_result(%{
        "status" => "error",
        "error" => "boom",
        "current_version" => "0.2.0"
      })

      assert UpdateStatus.get().current_version == "0.2.0"
    end

    test "error paths without current_version keep the seeded version" do
      UpdateStatus.handle_check_result(%{"status" => "not_configured"})
      assert UpdateStatus.get().current_version == app_version()

      UpdateStatus.handle_check_result(%{"status" => "not_available"})
      assert UpdateStatus.get().current_version == app_version()

      UpdateStatus.handle_check_result(%{"status" => "error", "error" => "boom"})
      assert UpdateStatus.get().current_version == app_version()
    end

    test "\"error\" uses the payload error" do
      UpdateStatus.handle_check_result(%{"status" => "error", "error" => "network down"})
      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "network down"
    end

    test "\"error\" with no error key falls back to check_failed" do
      UpdateStatus.handle_check_result(%{"status" => "error"})
      assert UpdateStatus.get().phase == :error
      assert UpdateStatus.get().error == "check_failed"
    end

    test "missing or unknown status normalizes to :error check_failed" do
      UpdateStatus.handle_check_result(%{})
      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "check_failed"

      UpdateStatus.handle_check_result(%{"status" => "weird_status"})
      assert UpdateStatus.get().phase == :error
      assert UpdateStatus.get().error == "check_failed"
    end

    test "garbage payloads never raise and normalize to :error check_failed" do
      for payload <- [:not_a_map, nil, "string", 42, [1, 2]] do
        UpdateStatus.handle_check_result(payload)
        state = UpdateStatus.get()
        assert state.phase == :error
        assert state.error == "check_failed"
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

    test "works from :error (retryable)" do
      UpdateStatus.check_failed("boom")
      assert UpdateStatus.get().phase == :error

      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      assert UpdateStatus.get().phase == :available
      assert UpdateStatus.get().error == nil
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

    test "false when the phase is not :available" do
      refute UpdateStatus.request_download?()

      UpdateStatus.handle_check_result(%{"status" => "up_to_date"})
      refute UpdateStatus.request_download?()

      UpdateStatus.check_started()
      refute UpdateStatus.request_download?()
    end

    test "false when notify_only is true" do
      Application.put_env(:evo_dash, :update_notify_only_override, true)
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      assert UpdateStatus.get().notify_only == true
      refute UpdateStatus.request_download?()
    end

    test "false when latest_version is nil" do
      UpdateStatus.handle_check_result(%{"status" => "available"})
      assert UpdateStatus.get().phase == :available
      assert UpdateStatus.get().latest_version == nil
      refute UpdateStatus.request_download?()
    end
  end

  describe "handle_download_result/1" do
    test "\"ready\" transitions to :ready with the version" do
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      UpdateStatus.handle_download_result(%{"status" => "ready", "version" => "1.0.0"})

      state = UpdateStatus.get()
      assert state.phase == :ready
      assert state.latest_version == "1.0.0"
      assert state.error == nil
    end

    test "\"ready\" without a version keeps the existing latest_version" do
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      UpdateStatus.handle_download_result(%{"status" => "ready"})
      assert UpdateStatus.get().phase == :ready
      assert UpdateStatus.get().latest_version == "1.0.0"
    end

    test "\"error\" from :available returns to :available with the error set" do
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      UpdateStatus.handle_download_result(%{"status" => "error", "error" => "disk full"})

      state = UpdateStatus.get()
      assert state.phase == :available
      assert state.error == "disk full"
    end

    test "\"error\" from :checking and :ready returns to :available" do
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})

      UpdateStatus.check_started()
      UpdateStatus.handle_download_result(%{"status" => "error", "error" => "boom"})
      assert UpdateStatus.get().phase == :available

      UpdateStatus.handle_download_result(%{"status" => "ready"})
      assert UpdateStatus.get().phase == :ready
      UpdateStatus.handle_download_result(%{"status" => "error", "error" => "boom"})
      assert UpdateStatus.get().phase == :available
      assert UpdateStatus.get().error == "boom"
    end

    test "\"error\" from :idle transitions to :error" do
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
    test "applying transitions to :applying from :ready" do
      UpdateStatus.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      UpdateStatus.handle_download_result(%{"status" => "ready"})
      UpdateStatus.applying()
      assert UpdateStatus.get().phase == :applying
    end

    test "apply_failed reverts :applying to :error with the message (never wedge)" do
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
    test "terminates :checking (never wedge) with the given message" do
      UpdateStatus.check_started()
      assert UpdateStatus.get().phase == :checking
      UpdateStatus.check_failed("timeout")
      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "timeout"
    end

    test "defaults the message to check_failed" do
      UpdateStatus.check_failed(nil)
      assert UpdateStatus.get().phase == :error
      assert UpdateStatus.get().error == "check_failed"
    end
  end

  describe "desktop?/0 and visible?/1" do
    test "desktop? reflects the :desktop_release env and EVOGIT_DESKTOP" do
      original_app_env = Application.get_env(:evo_dash, :desktop_release)
      original_sys_env = System.get_env("EVOGIT_DESKTOP")

      on_exit(fn ->
        restore_env_value(:desktop_release, original_app_env)
        restore_sys_env("EVOGIT_DESKTOP", original_sys_env)
      end)

      Application.delete_env(:evo_dash, :desktop_release)
      System.delete_env("EVOGIT_DESKTOP")
      refute UpdateStatus.desktop?()

      Application.put_env(:evo_dash, :desktop_release, true)
      assert UpdateStatus.desktop?()

      Application.delete_env(:evo_dash, :desktop_release)
      System.put_env("EVOGIT_DESKTOP", "1")
      assert UpdateStatus.desktop?()

      System.put_env("EVOGIT_DESKTOP", "0")
      refute UpdateStatus.desktop?()
    end

    test "visible? is true only on the local node in desktop mode" do
      original_app_env = Application.get_env(:evo_dash, :desktop_release)
      original_sys_env = System.get_env("EVOGIT_DESKTOP")

      on_exit(fn ->
        restore_env_value(:desktop_release, original_app_env)
        restore_sys_env("EVOGIT_DESKTOP", original_sys_env)
      end)

      Application.delete_env(:evo_dash, :desktop_release)
      System.delete_env("EVOGIT_DESKTOP")
      refute UpdateStatus.visible?(nil)
      refute UpdateStatus.visible?(node())

      Application.put_env(:evo_dash, :desktop_release, true)
      assert UpdateStatus.visible?(nil)
      assert UpdateStatus.visible?(node())
      refute UpdateStatus.visible?(:some_remote_node)
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
