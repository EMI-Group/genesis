defmodule EvoDashWeb.LiveHooks.UpdateStatusTest do
  # Unit tests for the global UpdateStatus on-mount hook
  # (EvoDashWeb.LiveHooks.UpdateStatus): the exported handlers that bridge the
  # JS updater hook to the EvoDash.UpdateStatus hub, the stop seam, and the
  # @update_status seeding decision. No LiveView needed — the hub runs in the
  # test app's supervision tree.
  #
  # async: false — the hub is a shared global GenServer and every test injects
  # global Application env values.
  use ExUnit.Case, async: false

  alias EvoDash.UpdateStatus
  alias EvoDashWeb.LiveHooks.UpdateStatus, as: UpdateStatusHook

  setup do
    # Same isolation as test/evo_dash/update_status_test.exs: reset the shared
    # hub and force notify_only off so the full download flow is testable
    # regardless of host platform (Linux CI without APPIMAGE would otherwise be
    # notify-only). Restored on exit.
    original_override = Application.get_env(:evo_dash, :update_notify_only_override)
    Application.put_env(:evo_dash, :update_notify_only_override, false)
    UpdateStatus.reset()

    on_exit(fn ->
      restore_env_value(:update_notify_only_override, original_override)
    end)

    :ok
  end

  describe "handle_check_result/1" do
    test "available + notify_only false → :request_download and the hub records the version" do
      assert UpdateStatusHook.handle_check_result(%{
               "status" => "available",
               "version" => "1.0.0",
               "current_version" => "0.1.0"
             }) == :request_download

      state = UpdateStatus.get()
      assert state.phase == :available
      assert state.download_requested_version == "1.0.0"
    end

    test "second call for the same version → :no_download (once-per-version guard)" do
      UpdateStatusHook.handle_check_result(%{"status" => "available", "version" => "1.0.0"})

      assert UpdateStatusHook.handle_check_result(%{
               "status" => "available",
               "version" => "1.0.0"
             }) == :no_download
    end

    test "up_to_date → :no_download" do
      assert UpdateStatusHook.handle_check_result(%{"status" => "up_to_date"}) == :no_download
    end

    test "notify_only true → :no_download (Linux non-AppImage: info only, no self-download)" do
      Application.put_env(:evo_dash, :update_notify_only_override, true)
      UpdateStatus.reset()

      assert UpdateStatusHook.handle_check_result(%{
               "status" => "available",
               "version" => "1.0.0"
             }) == :no_download

      state = UpdateStatus.get()
      assert state.phase == :available
      assert state.notify_only == true
      assert state.download_requested_version == nil
    end
  end

  describe "handle_download_result/1" do
    test "ready → hub phase :ready with the version recorded" do
      UpdateStatusHook.handle_check_result(%{"status" => "available", "version" => "1.0.0"})

      assert UpdateStatusHook.handle_download_result(%{"status" => "ready", "version" => "1.0.0"}) ==
               :ok

      state = UpdateStatus.get()
      assert state.phase == :ready
      assert state.latest_version == "1.0.0"
    end
  end

  describe "handle_apply_failed/1" do
    test "reverts the hub from :applying to :error with the payload message (never wedges)" do
      UpdateStatusHook.handle_check_result(%{"status" => "available", "version" => "1.0.0"})
      UpdateStatusHook.handle_download_result(%{"status" => "ready"})
      UpdateStatus.applying()
      assert UpdateStatus.get().phase == :applying

      assert UpdateStatusHook.handle_apply_failed(%{"error" => "installer crashed"}) == :ok

      state = UpdateStatus.get()
      assert state.phase == :error
      assert state.error == "installer crashed"
    end

    test "non-map payload defaults to apply_failed" do
      UpdateStatus.applying()
      UpdateStatusHook.handle_apply_failed(nil)
      assert UpdateStatus.get().phase == :error
      assert UpdateStatus.get().error == "apply_failed"
    end
  end

  describe "stop_backend/0" do
    test "calls the :desktop_quit_stop_fun seam (the REAL System.stop/0 never runs)" do
      test_pid = self()

      Application.put_env(:evo_dash, :desktop_quit_stop_fun, fn ->
        send(test_pid, :backend_stopped)
      end)

      on_exit(fn ->
        Application.delete_env(:evo_dash, :desktop_quit_stop_fun)
      end)

      assert UpdateStatusHook.stop_backend() == :ok
      assert_received :backend_stopped
    end
  end

  describe "initial_assign/2 (the @update_status seeding decision)" do
    test "desktop + local view → the full hub state map" do
      state = UpdateStatusHook.initial_assign(true, false)
      assert is_map(state)
      assert state.phase == :idle
      assert Map.has_key?(state, :latest_version)
      assert Map.has_key?(state, :notify_only)
    end

    test "desktop + remote view (?node= param) → nil (dot hidden on remote nodes)" do
      assert UpdateStatusHook.initial_assign(true, true) == nil
    end

    test "non-desktop → nil regardless of node" do
      assert UpdateStatusHook.initial_assign(false, false) == nil
      assert UpdateStatusHook.initial_assign(false, true) == nil
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
end
