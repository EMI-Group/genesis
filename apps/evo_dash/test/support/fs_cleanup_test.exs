defmodule EvoDash.Test.FsCleanupTest do
  @moduledoc """
  Proves `EvoDash.Test.FsCleanup`'s teardown contract: a LIVE writer that keeps
  re-creating entries must never make removal raise, while a tree that
  genuinely cannot be removed must still fail loudly.

  `File.rm_rf/1` lists a directory, deletes what it listed and only then
  `rmdir`s the parent, so a writer that (re)creates an entry in between makes
  the final `rmdir` answer `{:error, :eexist, _}` (this host's filesystem;
  `:enotempty` elsewhere) — which `File.rm_rf!/1` turns into the `File.Error`
  that ExUnit blames on whichever test's `on_exit` lost the race.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias EvoDash.Test.FsCleanup

  setup do
    dir = Path.join(System.tmp_dir!(), unique_name("fs_cleanup"))
    File.mkdir_p!(Path.join(dir, "genesis"))
    File.write!(Path.join([dir, "genesis", "config.toml"]), "")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "a live writer that keeps re-creating the tree never makes removal raise", %{dir: dir} do
    test_pid = self()

    # The production shape of the race: a supervised process that resolves the
    # config directory and writes into it (an async page load's
    # `EvoGit.RemoteConnections.list/0` skeleton), here re-creating the tree in
    # a tight loop so at least one removal attempt meets a re-created entry.
    # Its writes are deliberately NON-raising: losing the mkdir to the removal
    # is the race under test, not an error in the writer.
    {:ok, writer} =
      Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
        write_until(dir, System.monotonic_time(:millisecond) + 100)
        send(test_pid, {:writer_done, self()})
      end)

    # The writer is alive for ~100 ms, so this removal meets re-created entries
    # and must retry until the writer stops instead of raising.
    assert :ok = FsCleanup.rm_rf!(dir, budget_ms: 10_000, retry_delay_ms: 2)

    # Once the writer is gone the tree is removable and STAYS removed — the
    # `:ok` above may legitimately predate the writer's last re-creation.
    assert_receive {:writer_done, ^writer}, 30_000
    assert :ok = FsCleanup.rm_rf!(dir, budget_ms: 10_000, retry_delay_ms: 2)
    refute File.exists?(dir)
  end

  # POSIX mode bits are what make the tree unremovable; Windows has no
  # equivalent, and there the loud-failure path is reached only through an
  # exhausted transient window.
  unless match?({:win32, _}, :os.type()) do
    test "a tree that genuinely cannot be removed raises File.Error with its residual entries" do
      parent = Path.join(System.tmp_dir!(), unique_name("fs_cleanup_locked"))
      dir = Path.join(parent, "target")
      File.mkdir_p!(Path.join(dir, "genesis"))
      File.write!(Path.join([dir, "genesis", "config.toml"]), "")

      # The tree's own contents are removable; removing the tree itself needs
      # write permission on the PARENT, which is denied — a non-transient
      # `:eacces`, i.e. a real failure that must not be retried into silence.
      File.chmod!(parent, 0o500)

      on_exit(fn ->
        File.chmod(parent, 0o700)
        File.rm_rf(parent)
      end)

      log =
        capture_log(fn ->
          assert_raise File.Error,
                       ~r/could not remove files and directories recursively from/,
                       fn ->
                         FsCleanup.rm_rf!(dir, budget_ms: 200, retry_delay_ms: 2)
                       end
        end)

      assert log =~ "EvoDash.Test.FsCleanup: could not remove"
      assert log =~ ":eacces"
      assert log =~ "residual: "
    end
  end

  # A live writer's shape: keep re-creating what the teardown removes.
  defp write_until(dir, stop_at) do
    if System.monotonic_time(:millisecond) < stop_at do
      File.mkdir_p(Path.join(dir, "genesis"))
      File.write(Path.join([dir, "genesis", "remote_connections.toml"]), "")
      write_until(dir, stop_at)
    end
  end

  defp unique_name(prefix) do
    random = String.downcase(Integer.to_string(:rand.uniform(4_294_967_296) - 1, 16))
    "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}-#{random}"
  end
end
