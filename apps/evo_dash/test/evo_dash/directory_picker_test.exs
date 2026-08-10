defmodule EvoDash.DirectoryPickerTest do
  use ExUnit.Case, async: false

  alias EvoDash.DirectoryPicker
  alias EvoDash.DirectoryPicker.Wx.Fake, as: FakeWx

  setup do
    # Reset the fake's mode/gate (the fake server pid is deliberately kept —
    # the app-started picker GenServer caches its wx env across tests and the
    # fake server must stay consistent with it).
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
      assert_receive {:directory_picker_result, "picker-1", {:ok, "/fake/picked/dir"}}, 1000
    end

    test "re-uses the wx connection between picks (server stays alive)" do
      assert DirectoryPicker.pick(self(), "picker-1") == :ok
      assert_receive {:directory_picker_result, "picker-1", {:ok, _}}, 1000

      wait_until_pick_ok("picker-2")
      assert_receive {:directory_picker_result, "picker-2", {:ok, _}}, 1000
    end

    test "self-heals when the wxe_server died between picks" do
      assert DirectoryPicker.pick(self(), "picker-1") == :ok
      assert_receive {:directory_picker_result, "picker-1", {:ok, _}}, 1000

      # Simulate OTP's wxe_server stopping itself when its last registered user
      # exits (the exact bug: the server is not a permanent singleton).
      FakeWx.kill_server()

      # The picker's Process.alive?/1 check detects the dead server, re-runs
      # :wx.new/0, and recovers — no crash, no stuck busy.
      wait_until_pick_ok("picker-2")
      assert_receive {:directory_picker_result, "picker-2", {:ok, "/fake/picked/dir"}}, 1000
    end

    test "a pick whose wx server dies mid-pick degrades to :unavailable and clears busy" do
      assert DirectoryPicker.pick(self(), "picker-1") == :ok
      assert_receive {:directory_picker_result, "picker-1", {:ok, _}}, 1000

      # Server dies between the picker's alive-check and the pick Task's
      # :wx.set_env/1 — the Task's register_me gen_server:call exits with
      # {:noproc, ...}, which must NOT crash the picker.
      FakeWx.set_mode(:server_dead)

      assert DirectoryPicker.pick(self(), "picker-2") == :ok
      # Exactly one result message, degraded to :unavailable.
      assert_receive {:directory_picker_result, "picker-2", :unavailable}, 1000
      refute_receive {:directory_picker_result, "picker-2", _}, 50

      # Busy cleared: a subsequent pick works again.
      FakeWx.set_mode(:normal)
      wait_until_pick_ok("picker-3")
      assert_receive {:directory_picker_result, "picker-3", {:ok, _}}, 1000
    end

    test "wx init failure returns {:error, :unavailable} and does not wedge the picker" do
      # Force the picker to re-initialize (its cached env's server is dead) and
      # make :wx.new/0 fail like on a headless machine.
      FakeWx.kill_server()
      FakeWx.set_mode(:init_fails)

      assert DirectoryPicker.pick(self(), "picker-1") == {:error, :unavailable}
      # No async result message for a synchronous failure.
      refute_receive {:directory_picker_result, _, _}, 50

      # The picker is NOT stuck busy: once wx recovers, picks work again.
      FakeWx.set_mode(:normal)
      wait_until_pick_ok("picker-2")
      assert_receive {:directory_picker_result, "picker-2", {:ok, _}}, 1000
    end

    test "concurrent picks are serialized (busy)" do
      # Gate the dialog: show_modal/1 blocks until the test releases it, so the
      # busy window is deterministic.
      FakeWx.set_gate(self())

      assert DirectoryPicker.pick(self(), "picker-1") == :ok
      assert_receive {:dialog_open, task_pid}, 1000

      # Second pick while busy → synchronous unavailable, no result message.
      assert DirectoryPicker.pick(self(), "picker-2") == {:error, :unavailable}
      refute_receive {:directory_picker_result, "picker-2", _}, 50

      # Release the dialog; the first pick completes and busy clears.
      send(task_pid, :release_dialog)
      assert_receive {:directory_picker_result, "picker-1", {:ok, "/fake/picked/dir"}}, 1000

      wait_until_pick_ok("picker-3")
      assert_receive {:directory_picker_result, "picker-3", {:ok, _}}, 1000
    end

    test "returns {:error, :unavailable} when disabled by config" do
      Application.put_env(:evo_dash, :directory_picker, enabled: false)
      assert DirectoryPicker.pick(self(), "picker-1") == {:error, :unavailable}
      refute_receive {:directory_picker_result, _, _}, 50
    end
  end

  # Picks are accepted asynchronously: after a pick completes, the Task sends
  # the result to the test process and THEN `:pick_done` to the GenServer. The
  # result arriving does not guarantee the GenServer has processed `:pick_done`
  # yet, so a follow-up pick can briefly see `busy: true`. Poll until the pick
  # is accepted (deterministic — no fixed sleeps).
  defp wait_until_pick_ok(picker_id, attempts \\ 50) do
    case DirectoryPicker.pick(self(), picker_id) do
      :ok ->
        :ok

      {:error, :unavailable} when attempts > 0 ->
        Process.sleep(20)
        wait_until_pick_ok(picker_id, attempts - 1)

      {:error, :unavailable} ->
        flunk("picker stayed busy for pick #{inspect(picker_id)}")
    end
  end
end
