defmodule EvoGit.TestSupport.FsCleanupTest do
  @moduledoc """
  Proves `EvoGit.TestSupport.FsCleanup`'s teardown contract: a LIVE writer that
  keeps re-creating entries must never make removal raise, while a tree that
  genuinely cannot be removed must still fail loudly.

  `File.rm_rf/1` lists a directory, deletes what it listed and only then
  `rmdir`s the parent, so a writer that (re)creates an entry in between makes
  the final `rmdir` answer `{:error, :eexist, _}` (this host's filesystem;
  `:enotempty` elsewhere) — which `File.rm_rf!/1` turns into the `File.Error`
  that ExUnit blames on whichever test's `on_exit` lost the race.

  `async: true` is safe here: every tree is a unique per-test directory and the
  module mutates no BEAM-global state.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.TestSupport.FsCleanup

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
    # config directory and writes into it, here re-creating the tree in a tight
    # loop so at least one removal attempt meets a re-created entry. Its writes
    # are deliberately NON-raising: losing the mkdir to the removal is the race
    # under test, not an error in the writer.
    {:ok, writer} =
      Task.Supervisor.start_child(EvoGit.TaskSupervisor, fn ->
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

  test "the :before_attempt hook runs before EVERY attempt with the remaining window",
       %{dir: dir} do
    test_pid = self()

    assert :ok =
             FsCleanup.rm_rf!(dir,
               budget_ms: 5_000,
               retry_delay_ms: 2,
               before_attempt: fn remaining_ms -> send(test_pid, {:attempt, remaining_ms}) end
             )

    # The FIRST attempt is preceded by the hook too (the config-dir seam drains
    # its supervised writers there), and the budget it receives is the
    # caller's deadline minus whatever has already been spent.
    assert_receive {:attempt, remaining_ms}
    assert remaining_ms <= 5_000 and remaining_ms > 0
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

      assert log =~ "EvoGit.TestSupport.FsCleanup: could not remove"
      assert log =~ ":eacces"
      assert log =~ "residual: "
    end
  end

  # A live writer's shape: keep re-creating what the teardown removes.
  defp write_until(dir, stop_at) do
    if System.monotonic_time(:millisecond) < stop_at do
      File.mkdir_p(Path.join(dir, "genesis"))
      File.write(Path.join([dir, "genesis", "config.toml"]), "")
      write_until(dir, stop_at)
    end
  end

  defp unique_name(prefix) do
    random = String.downcase(Integer.to_string(:rand.uniform(4_294_967_296) - 1, 16))
    "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}-#{random}"
  end
end

defmodule EvoGit.TestSupport.ConfigDirTest do
  @moduledoc """
  Proves the two invariants `EvoGit.TestSupport.ConfigDir` adds on top of the
  per-process resolution seam: a directory name that is unique across BEAMs,
  and a teardown that DRAINS `EvoGit.TaskSupervisor` children writing into the
  directory before it removes it.

  `async: true` is safe here: each test owns a unique temporary directory, and
  the only BEAM-global it touches is the shared `EvoGit.TaskSupervisor`, to
  which it starts its own short-lived children (children never stopped per
  test) and always joins before the test ends.
  """

  use ExUnit.Case, async: true

  alias EvoGit.TestSupport.ConfigDir
  alias EvoGit.TestSupport.FsCleanup

  defmodule Probe do
    @moduledoc false
    # A plain `proc_lib` child, i.e. the shape of ReqLLM's `StreamServer`.
    use GenServer

    def start_link(_opts \\ nil), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(:chain, _from, state),
      do: {:reply, {Process.get(:"$callers"), Process.get(:"$ancestors")}, state}

    def handle_call(:resolve, _from, state),
      do: {:reply, EvoGit.TestSupport.ConfigDir.resolve(), state}
  end

  describe "directory naming (unique across BEAMs, not merely within one)" do
    test "the name carries the OS pid and a random component, and two calls differ" do
      dir = ConfigDir.isolate!("config_dir_unique")
      basename = Path.basename(dir)

      # `System.unique_integer/1` alone restarts at the same offset in EVERY VM,
      # so a `<prefix>-<int>` name is reproduced by a second `mix test` run that
      # shares this host's TMPDIR — and that run's cleanup would delete THIS
      # run's live directory (`File.Error` on config.toml). The OS pid separates
      # concurrent VMs and the random suffix also covers OS-pid reuse and a stale
      # directory from an interrupted run.
      assert basename =~ ~r/\Aconfig_dir_unique-#{System.pid()}-\d+-[0-9a-f]+\z/

      # Two directories created back to back never share a name (asserted on the
      # full path, so a lost pid/random component fails this too).
      assert ConfigDir.isolate!("config_dir_unique") != dir

      # Module-level directories get the same cross-BEAM-unique name.
      module_dir = ConfigDir.isolate_module!("config_dir_unique")
      assert module_dir != dir
      assert Path.basename(module_dir) =~ ~r/\Aconfig_dir_unique-#{System.pid()}-\d+-[0-9a-f]+\z/
    end
  end

  describe "resolution (unchanged contract)" do
    test "isolate!/1 activates the override and children inherit it" do
      dir = ConfigDir.isolate!("config_dir_resolve")

      assert ConfigDir.resolve() == dir

      # A child started by the test inherits the override through `$callers`.
      assert Task.async(fn -> ConfigDir.resolve() end) |> Task.await(5_000) == dir

      # `activate/1` is the setup_all-shaped entry point and keeps the same key.
      other = ConfigDir.isolate_module!("config_dir_resolve_other")
      assert ConfigDir.activate(other) == other
      assert ConfigDir.resolve() == other
      assert Process.get(:evogit_config_dir) == other
    end

    test "a GenServer child inherits the override through `$ancestors`, not `$callers`" do
      dir = ConfigDir.isolate!("config_dir_resolve_genserver")

      # The production shape: ReqLLM's `StreamServer` is a plain
      # `GenServer.start_link/3` child, and that is where a provider adapter's
      # `attach_stream/4` (hence the ChatGPT credential lookup) runs. Elixir's
      # `Task` writes `$callers` itself; `proc_lib` only writes `$ancestors`, so a
      # `$callers`-only resolution answers the DEVELOPER's real config dir here
      # and a credential test silently reads a real registration.
      {:ok, probe} = Probe.start_link()

      {callers, ancestors} = GenServer.call(probe, :chain)
      # The premise: `GenServer.start_link/3` writes `$ancestors` and NOT
      # `$callers`, which is why the `$ancestors` arm is required at all.
      refute self() in List.wrap(callers)
      assert self() in ancestors
      assert GenServer.call(probe, :resolve) == dir
    end
  end

  describe "cleanup ordering (supervised writers)" do
    test "the drain waits for a live writer, and removal then succeeds without raising" do
      dir = ConfigDir.isolate!("config_dir_drain")
      writer_file = Path.join([dir, "genesis", "config.toml"])
      writer = start_writer!(dir)

      on_exit(fn -> send(writer, :stop) end)

      # The production shape of the cleanup race: a supervised child resolves
      # `<override>/genesis` while the test is alive and keeps (re)creating it,
      # so a removal that runs while it is in flight can fail with
      # `{:error, :eexist, _}` or silently leave a re-created directory behind.
      assert Process.alive?(writer)
      assert File.exists?(writer_file)

      # The drain is a WAIT, not a pass-through: with the writer still running
      # it cannot answer `:ok` inside a tiny window.
      assert :timeout = ConfigDir.await_dir_writers(self(), dir, 25)
      assert Process.alive?(writer)

      # Deterministic release: a plain `spawn/1` (no `:"$callers"`, so it is not
      # itself a drain candidate) tells the writer to stop shortly after the
      # removal has begun. The removal's drain hook holds until the writer is
      # gone, which is exactly what makes the removal race-free.
      spawn(fn ->
        Process.sleep(50)
        send(writer, :stop)
      end)

      assert :ok =
               FsCleanup.rm_rf!(dir,
                 budget_ms: 5_000,
                 retry_delay_ms: 2,
                 before_attempt: fn remaining ->
                   ConfigDir.await_dir_writers(self(), dir, remaining)
                 end
               )

      # The drain returned only once the writer had exited, so the tree is gone
      # and STAYS gone (nothing can recreate it any more).
      assert_receive {:writer_stopped, ^writer}, 5_000
      refute Process.alive?(writer)
      refute File.exists?(dir)
    end

    test "a writer whose caller chain never names the registrar is found through the owner marker" do
      # Module-level shape: the directory is created for `setup_all`, so its
      # cleanup registrar appears in no child's `:"$callers"` chain.
      dir = ConfigDir.isolate_module!("config_dir_owner_drain")
      parent = self()

      # A helper from another ownership class ACTIVATES the directory (as a
      # `setup` block does for a `setup_all`-created one), starts a supervised
      # writer and then EXITS: by drain time its pid is dead, so its dictionary
      # (which held the override) is unreadable. Only the on-disk owner marker
      # can still tie the writer to `dir`.
      helper =
        spawn(fn ->
          ConfigDir.activate(dir)

          {:ok, writer} =
            Task.Supervisor.start_child(EvoGit.TaskSupervisor, fn ->
              write_config!(dir)
              send(parent, {:writer_ready, self()})
              writer_loop(dir, parent)
            end)

          send(parent, {:owner_writer, writer})
        end)

      helper_ref = Process.monitor(helper)
      assert_receive {:owner_writer, writer}, 5_000
      assert_receive {:writer_ready, ^writer}, 5_000
      assert_receive {:DOWN, ^helper_ref, :process, ^helper, _reason}, 5_000

      on_exit(fn -> send(writer, :stop) end)

      # Prove the dead-owner case: neither the registrar predicate nor a
      # dictionary read of a (dead) caller can see this writer.
      assert Process.alive?(writer)
      assert :ok = ConfigDir.await_supervised_writers(self(), 25)

      # The destination predicate (the owner marker) does see it, and it is a
      # WAIT, not a pass.
      assert :timeout = ConfigDir.await_dir_writers(self(), dir, 25)

      send(writer, :stop)
      assert :ok = ConfigDir.await_dir_writers(self(), dir, 5_000)
      assert_receive {:writer_stopped, ^writer}, 5_000
      refute Process.alive?(writer)

      # With every writer drained, the removal succeeds and STAYS removed (the
      # owner markers live inside `dir`, so they go with it).
      assert :ok = FsCleanup.rm_rf!(dir, budget_ms: 5_000, retry_delay_ms: 2)
      refute File.exists?(dir)
    end
  end

  describe "owner registry (what makes a module-level directory drainable)" do
    test "activate/1 records the pid on disk; isolate!/1 stays file-I/O free" do
      module_dir = ConfigDir.isolate_module!("config_dir_owner_module")
      owners_dir = Path.join(module_dir, ".evogit-owners")

      assert ConfigDir.activate(module_dir) == module_dir
      assert ConfigDir.resolve() == module_dir, "activate/1 must keep the override"
      assert [owner] = File.ls!(owners_dir)

      # The marker names the ACTIVATING pid in a form that survives the process
      # (`:erlang.list_to_pid/1` never needs it to be alive) — a dead pid's
      # dictionary, by contrast, cannot be read any more.
      assert owner =~ ~r/\A\d+\.\d+\.\d+\z/
      assert :erlang.list_to_pid(String.to_charlist("<#{owner}>")) == self()

      # The per-test path is the HOT path: it must stay free of file I/O, and it
      # needs no marker because its registrar is the test pid itself.
      per_test_dir = ConfigDir.isolate!("config_dir_owner_per_test")
      assert ConfigDir.resolve() == per_test_dir
      refute File.exists?(Path.join(per_test_dir, ".evogit-owners"))

      # No marker was recorded anywhere by `isolate!/1`.
      assert File.ls!(owners_dir) == [owner]
    end
  end

  # ── writer helpers ──────────────────────────────────────────────────────
  #
  # A writer is a supervised child that ACTIVATES the directory and keeps
  # (re)creating `<dir>/genesis/config.toml` until it is told to stop. Stopping
  # is MESSAGE-driven, never a fixed sleep-as-synchronization; the 2 ms
  # `receive` cadence only paces the writes.

  defp start_writer!(dir) do
    parent = self()

    {:ok, writer} =
      Task.Supervisor.start_child(EvoGit.TaskSupervisor, fn ->
        ConfigDir.activate(dir)
        write_config!(dir)
        send(parent, {:writer_ready, self()})
        writer_loop(dir, parent)
      end)

    assert_receive {:writer_ready, ^writer}, 5_000
    writer
  end

  defp writer_loop(dir, parent) do
    receive do
      :stop ->
        send(parent, {:writer_stopped, self()})
        :ok
    after
      2 ->
        write_config!(dir)
        writer_loop(dir, parent)
    end
  end

  defp write_config!(dir) do
    File.mkdir_p(Path.join(dir, "genesis"))
    File.write(Path.join([dir, "genesis", "config.toml"]), "")
  end
end
