defmodule EvoDash.DirectoryPickerTest do
  # async: true — tests inside one module always run serially, so the shared
  # EvoDash.DirectoryPicker GenServer's global "busy" gate is never contended
  # within this file. No async: true module ever calls DirectoryPicker.pick
  # (the only other caller, projects_live_test.exs, is async: false), so the
  # :directory_picker / :directory_picker_wx app-env overrides below are safe.
  use ExUnit.Case, async: true

  alias EvoDash.DirectoryPicker
  alias EvoDash.DirectoryPicker.Wx.Fake, as: FakeWx

  setup do
    # Reset the fake's mode/gate. The fake server pid is deliberately kept —
    # picks now init wx fresh in each Task, so the cached server pid is stale
    # but harmless (FakeWx.new/0 retires it).
    FakeWx.reset()

    original_enabled = Application.get_env(:evo_dash, :directory_picker)
    original_wx = Application.get_env(:evo_dash, :directory_picker_wx)

    # test_helper.exs sets `enabled: false` by default — enable the picker for
    # these tests and inject the deterministic wx fake.
    Application.put_env(:evo_dash, :directory_picker, enabled: true)
    Application.put_env(:evo_dash, :directory_picker_wx, FakeWx)

    on_exit(fn ->
      if original_enabled do
        Application.put_env(:evo_dash, :directory_picker, original_enabled)
      else
        Application.delete_env(:evo_dash, :directory_picker)
      end

      if original_wx do
        Application.put_env(:evo_dash, :directory_picker_wx, original_wx)
      else
        Application.delete_env(:evo_dash, :directory_picker_wx)
      end
    end)

    :ok
  end

  describe "pick/2" do
    test "first pick opens the dialog and delivers the picked path" do
      assert DirectoryPicker.pick(self(), "picker-1") == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-1", {:ok, "/fake/picked/dir"}}, 1000
    end

    test "subsequent picks after first pick work correctly" do
      assert DirectoryPicker.pick(self(), "picker-1") == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-1", {:ok, _}}, 1000

      assert DirectoryPicker.pick(self(), "picker-2") == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-2", {:ok, _}}, 1000
    end

    test "picks work even after the wx server was killed between picks" do
      assert DirectoryPicker.pick(self(), "picker-1") == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-1", {:ok, _}}, 1000

      # Simulate OTP's wxe_server stopping itself when its last registered user
      # exits. Since each pick now inits wx fresh in its Task, the next pick
      # creates a brand-new server and works without issue.
      FakeWx.kill_server()

      assert DirectoryPicker.pick(self(), "picker-2") == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-2", {:ok, "/fake/picked/dir"}}, 1000
    end

    test "a pick whose wx server dies mid-pick degrades to :unavailable and clears busy" do
      assert DirectoryPicker.pick(self(), "picker-1") == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-1", {:ok, _}}, 1000

      # Server dies between wx init and set_env/1 in the pick Task — the Task's
      # wx call exits with {:noproc, ...}, which must NOT crash the picker.
      FakeWx.set_mode(:server_dead)

      assert DirectoryPicker.pick(self(), "picker-2") == :ok
      # Exactly one result message, degraded to :unavailable.
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-2", :unavailable}, 1000
      refute_receive {:directory_picker_result, "picker-2", _}, 50

      # Busy cleared: a subsequent pick works again.
      FakeWx.set_mode(:normal)
      assert DirectoryPicker.pick(self(), "picker-3") == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-3", {:ok, _}}, 1000
    end

    test "wx init failure in Task degrades to :unavailable and clears busy" do
      # Make :wx.new/0 fail like on a headless machine.
      FakeWx.set_mode(:init_fails)

      # With wx init in the Task, the failure is ASYNCHRONOUS — pick/2 returns
      # :ok because the Task was spawned successfully.
      assert DirectoryPicker.pick(self(), "picker-1") == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-1", :unavailable}, 1000
      refute_receive {:directory_picker_result, "picker-1", _}, 50

      # The picker is NOT stuck busy: once wx recovers, picks work again.
      FakeWx.set_mode(:normal)
      assert DirectoryPicker.pick(self(), "picker-2") == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-2", {:ok, _}}, 1000
    end

    test "concurrent picks are serialized (busy)" do
      # Gate the dialog: show_modal/1 blocks until the test releases it, so the
      # busy window is deterministic.
      FakeWx.set_gate(self())

      assert DirectoryPicker.pick(self(), "picker-1") == :ok
      assert_receive {:dialog_open, task_pid}, 5_000

      # Second pick while busy → synchronous unavailable, no result message.
      assert DirectoryPicker.pick(self(), "picker-2") == {:error, :unavailable}
      refute_receive {:directory_picker_result, "picker-2", _}, 50

      # Release the dialog; the first pick completes and busy clears.
      send(task_pid, :release_dialog)
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-1", {:ok, "/fake/picked/dir"}}, 1000

      assert DirectoryPicker.pick(self(), "picker-3") == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-3", {:ok, _}}, 1000
    end

    test "returns {:error, :unavailable} when disabled by config" do
      Application.put_env(:evo_dash, :directory_picker, enabled: false)
      assert DirectoryPicker.pick(self(), "picker-1") == {:error, :unavailable}
      refute_receive {:directory_picker_result, _, _}, 50
    end
  end

  describe "pick/3 (file mode)" do
    test "file pick opens the file dialog and delivers the picked file path" do
      assert DirectoryPicker.pick(self(), "file-1", :file) == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "file-1", {:ok, "/fake/picked/file.txt"}}, 1000
    end

    test "pick/2 behaves exactly like pick/3 :directory" do
      assert DirectoryPicker.pick(self(), "picker-1") == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-1", {:ok, "/fake/picked/dir"}}, 1000

      # pick/2 delegates to pick/3 with :directory — identical result protocol.
      assert DirectoryPicker.pick(self(), "picker-2", :directory) == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "picker-2", {:ok, "/fake/picked/dir"}}, 1000
    end

    test "concurrent file picks are serialized (busy)" do
      # Gate the dialog: show_modal/1 blocks until the test releases it, so the
      # busy window is deterministic (the gate is kind-agnostic).
      FakeWx.set_gate(self())

      assert DirectoryPicker.pick(self(), "file-1", :file) == :ok
      assert_receive {:dialog_open, task_pid}, 5_000

      # Second file pick while busy → synchronous unavailable, no result message.
      assert DirectoryPicker.pick(self(), "file-2", :file) == {:error, :unavailable}
      refute_receive {:directory_picker_result, "file-2", _}, 50

      # The busy flag is kind-agnostic: a :directory pick is rejected the same way.
      assert DirectoryPicker.pick(self(), "dir-1", :directory) == {:error, :unavailable}
      refute_receive {:directory_picker_result, "dir-1", _}, 50

      # Release the dialog; the first pick completes and busy clears.
      send(task_pid, :release_dialog)
      await_pick_idle()
      assert_receive {:directory_picker_result, "file-1", {:ok, "/fake/picked/file.txt"}}, 1000

      assert DirectoryPicker.pick(self(), "file-3", :file) == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "file-3", {:ok, _}}, 1000
    end

    test "file pick wx init failure degrades to :unavailable and clears busy" do
      # Make :wx.new/0 fail like on a headless machine.
      FakeWx.set_mode(:init_fails)

      # With wx init in the Task, the failure is ASYNCHRONOUS — pick/3 returns
      # :ok because the Task was spawned successfully.
      assert DirectoryPicker.pick(self(), "file-1", :file) == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "file-1", :unavailable}, 1000
      refute_receive {:directory_picker_result, "file-1", _}, 50

      # The picker is NOT stuck busy: once wx recovers, picks work again.
      FakeWx.set_mode(:normal)
      assert DirectoryPicker.pick(self(), "file-2", :file) == :ok
      await_pick_idle()
      assert_receive {:directory_picker_result, "file-2", {:ok, _}}, 1000
    end

    test "returns {:error, :unavailable} when disabled by config (file mode)" do
      Application.put_env(:evo_dash, :directory_picker, enabled: false)
      assert DirectoryPicker.pick(self(), "file-1", :file) == {:error, :unavailable}
      refute_receive {:directory_picker_result, _, _}, 50
    end
  end

  # Synchronizes on the picker's OWN state instead of racing a wall-clock
  # timeout. `run_pick/4` sends the caller's result BEFORE the completion
  # signal (`send(reply_to, ...)` then `send(gen_server, {:pick_done, ...})`),
  # and a local `send/2` enqueues the message synchronously — so once the
  # GenServer is observed IDLE, the caller's result is already in its mailbox
  # and the following `assert_receive` cannot time out. `:sys.get_state/1` is a
  # FIFO fence: it returns only after every message sent earlier (including
  # `:pick_done`) has been processed.
  #
  # This replaces the previous approach (retry `pick/2` while `{:error,
  # :unavailable}` and then hope the async result lands within a fixed
  # timeout), which reproducibly flaked under CPU load: the pick Task's
  # completion is scheduler-bound, so a fixed wall-clock window is not a state
  # race the result can be "waited out" of.
  defp await_pick_idle(timeout \\ 10_000) do
    do_await_pick_idle(System.monotonic_time(:millisecond) + timeout)
  end

  defp do_await_pick_idle(deadline) do
    if :sys.get_state(DirectoryPicker).busy do
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("picker GenServer stayed busy past the await-pick-idle deadline")
      else
        Process.sleep(10)
        do_await_pick_idle(deadline)
      end
    else
      :ok
    end
  end
end
