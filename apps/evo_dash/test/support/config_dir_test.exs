defmodule EvoDash.Test.ConfigDirTest.Fixture do
  @moduledoc false

  alias EvoDash.Test.ConfigDir

  # Only ever present in this test's temp config dir.
  @probe_provider_id "config-dir-seam-probe"

  def setup(context) do
    # The negative-control test wants NO active override (it proves the fallback
    # branch), so it opts out of the temp dir entirely.
    if context[:no_override] do
      :ok
    else
      dir = ConfigDir.isolate!("config_dir_seam")
      genesis_dir = Path.join(dir, "genesis")
      File.mkdir_p!(genesis_dir)

      # The version-state file suppresses the first-run redirect to /welcome.
      File.write!(Path.join(genesis_dir, "version_state.toml"), "version = \"0.0.0-seam\"\n")

      # A valid canonical provider config whose id exists NOWHERE else:
      # whichever process resolves the config dir surfaces this id through
      # `EvoGit.Config.resolve/0` (no legacy-profile migration involved).
      File.write!(Path.join(genesis_dir, "config.toml"), """
      [llm]
      default_provider_profile = "#{@probe_provider_id}"

      [[llm.providers]]
      id = "#{@probe_provider_id}"
      name = "Config directory seam probe"
      provider = "anthropic"
      api_key_env_var = "EVOGIT_CONFIG_DIR_SEAM_API_KEY"
      models = ["claude-sonnet-5"]
      default_model = "claude-sonnet-5"
      concurrency = 3
      """)

      {:ok, config_dir: genesis_dir, probe_provider_id: @probe_provider_id}
    end
  end

  # Runs `fun` with this process' config-dir override temporarily removed,
  # restoring the exact prior value afterwards (nothing to restore when absent).
  def without_override(fun) do
    override = Process.get(:evogit_config_dir)
    Process.delete(:evogit_config_dir)

    try do
      fun.()
    after
      if override, do: Process.put(:evogit_config_dir, override)
    end
  end
end

defmodule EvoDash.Test.ConfigDirTest do
  @moduledoc """
  Empirical proof of the per-process config-dir seam installed by
  `test/test_helper.exs` (`:evo_git, :config_dir_fun` →
  `EvoDash.Test.ConfigDir.resolve/0`).

  The tests prove supervised-task inheritance (including transitivity), the
  `$ancestors` arm a plain `GenServer` child needs (it never gets `$callers`),
  the raw spawn escape boundary, and the fallback directory's first-run
  redirect.
  The positive mounted proof lives in ConfigDirMountedTest below because its
  real Projects loader also reads a BEAM-global runner seam.

  Each test's config directory is unique, so the path-keyed config caches are
  safe and no process-wide environment write is needed.
  """

  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EvoDash.Test.ConfigDir
  alias EvoDash.Test.ConfigDirTest.Fixture

  defmodule Probe do
    @moduledoc false
    # A plain `proc_lib` child: `GenServer.start_link/3` is the shape that gets
    # NO `$callers` inheritance from its starter.
    use GenServer

    def start_link(_opts \\ nil), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(:chain, _from, state),
      do: {:reply, {Process.get(:"$callers"), Process.get(:"$ancestors")}, state}

    def handle_call(:resolve, _from, state),
      do: {:reply, EvoDash.Test.ConfigDir.resolve(), state}
  end

  setup context, do: Fixture.setup(context)

  @tag no_override: true
  test "without an active override the same mount takes the fallback and redirects to /welcome",
       %{conn: conn} do
    # No `setup`-time `isolate!/1` in this test: the process dictionary is
    # empty, so the dead render falls through to the run-unique EMPTY fallback
    # config dir. It redirects BEFORE any Projects async batch is spawned.
    assert Process.get(:evogit_config_dir) == nil

    fallback = ConfigDir.config_dir()

    refute File.exists?(Path.join(fallback, "version_state.toml")),
           "the fallback config dir #{fallback} carries a version_state.toml — " <>
             "a first-run redirect cannot be observed on this host"

    assert {:error, {:live_redirect, %{to: "/welcome"}}} = live(conn, "/projects")
  end

  test "Task.Supervisor children inherit the override", %{config_dir: config_dir} do
    # The production async-load spawn path: test pid → supervised child.
    assert {:ok, _pid} =
             EvoDash.SafeCall.start(self(), :config_dir_seam_probe, fn ->
               EvoGit.Platform.config_dir()
             end)

    assert_receive {:config_dir_seam_probe, {:ok, ^config_dir}}, 5_000

    task =
      Task.Supervisor.async_nolink(EvoDash.TaskSupervisor, fn ->
        EvoGit.Platform.config_dir()
      end)

    assert Task.await(task, 5_000) == config_dir

    # Transitivity: test pid → task → grandchild, just like a mounted view's
    # supervised load task inheriting the test pid through its caller chain.
    task =
      Task.Supervisor.async_nolink(EvoDash.TaskSupervisor, fn ->
        Task.async(fn -> EvoGit.Platform.config_dir() end) |> Task.await(5_000)
      end)

    assert Task.await(task, 5_000) == config_dir

    # A raw spawn inherits NEITHER `$callers` NOR `$ancestors`; document the
    # escaping process class rather than pretending that the seam reaches
    # boot-time singletons.
    parent = self()
    spawn(fn -> send(parent, {:raw_spawn_config_dir, EvoGit.Platform.config_dir()}) end)
    assert_receive {:raw_spawn_config_dir, raw_spawn_dir}, 5_000
    assert raw_spawn_dir == Fixture.without_override(fn -> ConfigDir.config_dir() end)
    assert raw_spawn_dir != config_dir
  end

  describe "resolution (spawn chain)" do
    test "a GenServer child inherits the override through `$ancestors`, not `$callers`" do
      dir = ConfigDir.isolate!("config_dir_resolve_genserver")

      # The production shape: a `GenServer.start_link/3` child is where a config
      # or credential read runs with NO `$callers` chain. Elixir's `Task` writes
      # `$callers` itself; `proc_lib` only writes `$ancestors`, so a
      # `$callers`-only resolution answers the DEVELOPER's real config dir here
      # and the test silently reads a real registration / real credentials.
      {:ok, probe} = Probe.start_link()

      {callers, ancestors} = GenServer.call(probe, :chain)

      # The premise: `GenServer.start_link/3` writes `$ancestors` and NOT
      # `$callers`, which is why the `$ancestors` arm is required at all.
      refute self() in List.wrap(callers)
      assert self() in ancestors
      assert GenServer.call(probe, :resolve) == dir
    end

    @tag no_override: true
    test "without an override a GenServer child resolves nothing, so the platform dir is used" do
      # No `setup`-time `isolate!/1` in this test: neither the test process nor
      # a plain `GenServer` child below it carries an override, and `nil` means
      # "use the real platform directory".
      assert ConfigDir.resolve() == nil

      {:ok, probe} = Probe.start_link()
      assert GenServer.call(probe, :resolve) == nil

      # The convenience accessor still answers the concrete fallback directory.
      assert ConfigDir.config_dir() == EvoGit.Platform.config_dir()
    end
  end

  describe "cleanup ordering (supervised writers)" do
    # Long enough that a writer is provably still in flight when the drain
    # starts, short enough to keep the suite fast.
    @writer_delay_ms 60

    test "the drain waits for a supervised writer that still holds the test pid" do
      test_pid = self()
      config_dir = ConfigDir.config_dir()
      writer_file = Path.join(config_dir, "remote_connections.toml")

      # The production shape of the cleanup race: an async load task resolves
      # `<override>/genesis` while the test is alive (its `:"$callers"` chain is
      # view -> test pid) and only writes later, when the test process is
      # already gone. `File.mkdir_p/1` recreates the whole tree, so a removal
      # that runs before this child exits can fail with `{:error, :eexist, _}`
      # — or silently leave a re-created directory behind.
      {:ok, writer} =
        Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
          dir = EvoGit.Config.config_dir()
          Process.sleep(@writer_delay_ms)
          File.mkdir_p!(dir)
          File.write!(Path.join(dir, "remote_connections.toml"), "")
          send(test_pid, {:late_write, self()})
        end)

      assert Process.alive?(writer)
      started = System.monotonic_time(:millisecond)

      assert :ok = ConfigDir.await_supervised_writers(test_pid)

      # The drain is a WAIT, not a pass-through: the child ran to completion
      # (its sleep elapsed) before the drain returned. The lower bound can only
      # be exceeded on a busy host, never shortened.
      assert System.monotonic_time(:millisecond) - started >= @writer_delay_ms - 10
      assert_received {:late_write, ^writer}
      refute Process.alive?(writer)
      assert File.exists?(writer_file)

      # The invariant `on_exit` relies on: with every writer drained, removing
      # the tree succeeds and STAYS removed (nothing can recreate it any more).
      assert {:ok, _removed} = File.rm_rf(config_dir)
      refute File.exists?(config_dir)
    end

    test "the drain ignores a writer whose caller chain is not the test's" do
      test_pid = self()

      # A raw `spawn/1` carries no `:"$callers"`, so this child's chain is
      # `[helper_pid]` — a writer from another ownership class, which the drain
      # must NOT wait for (an unbounded drain would serialise an isolated test
      # behind unrelated long-lived tasks on the shared supervisor).
      spawn(fn ->
        {:ok, pid} =
          Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn -> Process.sleep(3_000) end)

        send(test_pid, {:foreign_writer, pid})
      end)

      assert_receive {:foreign_writer, foreign_writer}, 5_000
      on_exit(fn -> Task.Supervisor.terminate_child(EvoDash.TaskSupervisor, foreign_writer) end)
      assert Process.alive?(foreign_writer)

      assert :ok = ConfigDir.await_supervised_writers(test_pid)
      assert Process.alive?(foreign_writer)
    end

    test "the DESTINATION drain waits for a writer whose chain never names the registrar" do
      test_pid = self()
      # `dir` is about to be removed by `on_exit`, whose REGISTRAR is this test
      # pid — the shape a per-test `isolate!/1` produces.
      dir = ConfigDir.isolate!("config_dir_dest_drain")
      writer_file = Path.join(Path.join(dir, "genesis"), "remote_connections.toml")

      # The module-level (`setup_all`) shape: the child's `:"$callers"` chain is
      # `[helper_pid]` — the registrar appears NOWHERE in it. The helper ACTIVATES
      # the directory (as a `setup` block does for a `setup_all`-created one) and
      # then EXITS, so by drain time its pid is dead and its dictionary (which
      # held the override) is gone. Only the on-disk owner marker can still tie
      # this writer to `dir` — exactly the case that used to make a module-level
      # directory merely "backstopped".
      helper =
        spawn(fn ->
          ConfigDir.activate(dir)

          {:ok, pid} =
            Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
              Process.sleep(@writer_delay_ms)
              File.mkdir_p!(Path.dirname(writer_file))
              File.write!(writer_file, "")
              send(test_pid, {:dest_late_write, self()})
            end)

          send(test_pid, {:dest_writer, pid})
        end)

      ref = Process.monitor(helper)
      assert_receive {:dest_writer, dest_writer}, 5_000
      on_exit(fn -> Task.Supervisor.terminate_child(EvoDash.TaskSupervisor, dest_writer) end)

      # Prove the dead-owner case before draining: the activator is DOWN, so
      # neither `registrar in callers` nor a dictionary read of a caller can
      # match.
      assert_receive {:DOWN, ^ref, :process, ^helper, _reason}, 5_000
      assert Process.alive?(dest_writer)

      # The registrar-based predicate alone does NOT see it.
      assert :ok = ConfigDir.await_supervised_writers(test_pid)
      assert Process.alive?(dest_writer)

      # The destination predicate (owner marker) does, and it is a WAIT, not a
      # pass.
      started = System.monotonic_time(:millisecond)
      assert :ok = ConfigDir.await_dir_writers(test_pid, dir)
      assert System.monotonic_time(:millisecond) - started >= @writer_delay_ms - 10
      assert_received {:dest_late_write, ^dest_writer}
      refute Process.alive?(dest_writer)
      assert File.exists?(writer_file)

      # With every writer drained, the removal succeeds and STAYS removed (the
      # owner markers live inside `dir`, so they go with it).
      assert {:ok, _removed} = File.rm_rf(dir)
      refute File.exists?(dir)
    end
  end

  describe "owner registry (what makes a module-level directory drainable)" do
    test "activate/1 records the pid on disk; isolate!/1 stays file-I/O free" do
      # Module-level shape: the directory is created for `setup_all`, so its
      # cleanup registrar appears in no child's `:"$callers"` chain.
      module_dir = ConfigDir.isolate_module!("config_dir_owner_module")
      owners_dir = Path.join(module_dir, ".evodash-owners")

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
      refute File.exists?(Path.join(per_test_dir, ".evodash-owners"))
    end
  end

  describe "directory naming (unique across BEAMs, not merely within one)" do
    test "the name carries the OS pid and a random component" do
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
    end
  end
end

defmodule EvoDash.Test.ConfigDirMountedTest do
  @moduledoc """
  Proves the config-directory override reaches both real mounted pages and the
  Projects page's supervised canonical selection load, not just the test pid.
  """

  # `async: true` — this proof exercises the DEFAULT Projects batch, and a
  # runner seam a concurrently running module installs cannot reach it:
  # `:projects_async_load_runner` resolves through `EvoDash.Seam.get/2` on the
  # caller's spawn chain, so only a page descended from that other test sees its
  # fixture. Config-directory isolation is per process for the same reason.
  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EvoDash.Test.ConfigDir
  alias EvoDash.Test.ConfigDirTest.Fixture

  setup context, do: Fixture.setup(context)

  test "the mounted LiveView resolves the per-process config dir",
       %{conn: conn, config_dir: config_dir, probe_provider_id: probe_provider_id} do
    # Pin fixture ownership: the mounted proof uses the production batch. No
    # runner is installed in app env at all (a test's runner override is
    # chain-scoped), so a foreign fixture cannot reach this page.
    assert Application.fetch_env(:evo_dash, :projects_async_load_runner) == :error

    # Level 1: the TEST process resolves the activated override.
    assert ConfigDir.config_dir() == config_dir
    assert EvoGit.Config.config_path() == Path.join(config_dir, "config.toml")
    assert EvoGit.Config.VersionState.path() == Path.join(config_dir, "version_state.toml")

    # Negative control before mounting: a live view resolves through this
    # test pid, so temporarily removing the override afterwards would affect it.
    fallback = Fixture.without_override(fn -> ConfigDir.config_dir() end)
    assert fallback != config_dir

    refute File.exists?(Path.join(fallback, "version_state.toml")),
           "the fallback config dir #{fallback} carries a version_state.toml — " <>
             "the onboarding redirect the temp marker suppresses cannot be observed here"

    # Level 2: the LIVEVIEW process. Without the isolated version-state marker
    # even the dead render would redirect to /welcome, as proved above.
    {:ok, view, _html} = live(conn, "/projects")

    assert {:dictionary, view_dict} = Process.info(view.pid, :dictionary)
    assert self() in Keyword.get(view_dict, :"$callers", [])
    refute Keyword.has_key?(view_dict, :evogit_config_dir)

    # The canonical picker bundle is loaded by a supervised task spawned by
    # the view. Wait for that real result, not an injected snapshot.
    page_assigns = await_model_selection(view)
    assert Enum.map(page_assigns.provider_profiles, & &1["id"]) == [probe_provider_id]
    assert page_assigns.selected_model_spec["provider_profile_id"] == probe_provider_id

    # A second real page resolves the isolated path and renders its provider.
    {:ok, settings_view, _html} = live(build_conn(), "/settings")
    assert assigns(settings_view).config_path == Path.join(config_dir, "config.toml")

    assert has_element?(
             settings_view,
             ~s(#provider-profiles-panel [phx-click="edit_provider_profile"][phx-value-profile_id="#{probe_provider_id}"])
           )
  end

  # A synchronous state read drains queued results; bounded polling waits for
  # the supervised picker load without a fixed sleep or a forged result.
  defp await_model_selection(view) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_model_selection(view, deadline)
  end

  defp await_model_selection(view, deadline) do
    page_assigns = assigns(view)

    cond do
      page_assigns[:model_selection_ready?] ->
        page_assigns

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Timed out waiting for the mounted page's canonical model selection")

      true ->
        Process.sleep(2)
        await_model_selection(view, deadline)
    end
  end

  # LiveViewTest's View exposes no assigns accessor; use the same synchronous
  # state read as the Projects and Settings page suites.
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
