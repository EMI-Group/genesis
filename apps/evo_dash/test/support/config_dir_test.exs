defmodule EvoDash.Test.ConfigDirTest do
  @moduledoc """
  Empirical proof of the per-process config-dir seam installed by
  `test/test_helper.exs` (`:evo_git, :config_dir_fun` →
  `EvoDash.Test.ConfigDir.resolve/0`).

  The suite depends on three inheritance levels, and this module PROVES rather
  than assumes each one:

    1. the TEST process resolves the override it activated (`setup`);
    2. the LIVEVIEW process (and therefore a real page render) resolves it —
       `Phoenix.LiveViewTest` sets the mounted view's `:"$callers"` to the test
       pid explicitly;
    3. `EvoDash.TaskSupervisor` children spawned along the suite's real async
       load path (`EvoDash.SafeCall.start/4`) resolve it too, including a task
       spawned by another task (transitivity).

  Each test's config directory is a unique temp dir, so the path-keyed
  `:persistent_term` caches in `EvoGit.Config`/`EvoGit.Config.VersionState` are
  cache-safe and no `XDG_CONFIG_HOME` write is needed — which is exactly the
  point of the seam (a per-process override instead of a BEAM-global env var).

  `async: true` — nothing here mutates process-wide state.
  """

  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EvoDash.Test.ConfigDir

  # Only ever present in this test's temp config dir.
  @probe_model_id "config-dir-seam-probe"

  setup context do
    # The negative-control test wants NO active override (it proves the fallback
    # branch), so it opts out of the temp dir entirely.
    if context[:no_override] do
      :ok
    else
      dir = ConfigDir.isolate!("config_dir_seam")
      genesis_dir = Path.join(dir, "genesis")
      File.mkdir_p!(genesis_dir)

      # The version-state file flips
      # `EvoGit.Config.VersionState.onboarding_needed?/0` to false, so
      # `/projects` renders instead of `push_navigate`-ing to `/welcome` (see
      # the negative control in the first test).
      File.write!(Path.join(genesis_dir, "version_state.toml"), "version = \"0.0.0-seam\"\n")

      # A valid single-profile config whose id exists NOWHERE else: whichever
      # process resolves the config dir surfaces this id through
      # `EvoGit.Config.resolve/0`.
      File.write!(Path.join(genesis_dir, "config.toml"), """
      [[llm.models]]
      id = "#{@probe_model_id}"
      model = {provider = "anthropic", id = "claude-sonnet-5"}
      concurrency = 3
      """)

      {:ok, config_dir: genesis_dir}
    end
  end

  test "the mounted LiveView resolves the per-process config dir",
       %{conn: conn, config_dir: config_dir} do
    # --- Level 1: the TEST process ---------------------------------------
    # `isolate!/1` wrote the override into this process' dictionary, so the
    # concrete config dir is the temp dir's `genesis` subdirectory.
    assert ConfigDir.config_dir() == config_dir
    assert EvoGit.Config.config_path() == Path.join(config_dir, "config.toml")
    assert EvoGit.Config.VersionState.path() == Path.join(config_dir, "version_state.toml")

    # --- Negative control (no page involved) ------------------------------
    # With the override removed, the very same call resolves a DIFFERENT
    # directory that carries no version-state file — so "the page rendered" in
    # the positive path below is caused by the temp dir being resolved, not by
    # ambient state. (Probe before mounting: while a view is alive, the test
    # pid is part of its `$callers` chain and would see the deleted override.)
    fallback = without_override(fn -> ConfigDir.config_dir() end)
    assert fallback != config_dir

    refute File.exists?(Path.join(fallback, "version_state.toml")),
           "the fallback config dir #{fallback} carries a version_state.toml — " <>
             "the onboarding redirect the temp marker suppresses cannot be observed here"

    # --- Level 2: the LIVEVIEW process ------------------------------------
    # The dead render resolved the temp dir too: without the version-state file
    # this mount would have answered `{:error, {:live_redirect, to: "/welcome"}}`
    # (see the negative-control test), so reaching the page proves the marker in
    # the temp config dir was read.
    {:ok, view, _html} = live(conn, "/projects")

    # Structural: the view process carries the test pid in `$callers` (the
    # chain `resolve/0` walks) and no override of its own.
    assert {:dictionary, view_dict} = Process.info(view.pid, :dictionary)
    assert self() in Keyword.get(view_dict, :"$callers", [])
    refute Keyword.has_key?(view_dict, :evogit_config_dir)

    # State: `ProjectsLive.mount/3` resolves the config INSIDE the view process
    # (`EvoGit.Config.resolve/0` → `@model_profiles`), whose only profile is the
    # one in this test's temp config dir.
    assert @probe_model_id in Enum.map(assigns(view)[:model_profiles], & &1.id)

    # Render: the Settings page resolves the config file in ITS view process on
    # mount (`SettingsLive.mount/3` → `ConfigIO.load_file_config/0` →
    # `EvoGit.Config.resolve/0`) and the LLM category renders one editable
    # profile-id input per profile — so the probe id reaches a real page render.
    {:ok, settings_view, _html} = live(build_conn(), "/settings")
    assert render(settings_view) =~ ~s(value="#{@probe_model_id}")
  end

  @tag no_override: true
  test "without an active override the same mount takes the fallback and redirects to /welcome",
       %{conn: conn} do
    # No `setup`-time `isolate!/1` in this test: the process dictionary is
    # empty, so both the dead render and the view fall through to the
    # BEAM-global XDG config dir — the run-unique EMPTY dir the test helper
    # redirects to — and `onboarding_needed?/0` is true again.
    assert Process.get(:evogit_config_dir) == nil

    fallback = ConfigDir.config_dir()

    refute File.exists?(Path.join(fallback, "version_state.toml")),
           "the fallback config dir #{fallback} carries a version_state.toml — " <>
             "a first-run redirect cannot be observed on this host"

    assert {:error, {:live_redirect, %{to: "/welcome"}}} = live(conn, "/projects")
  end

  test "Task.Supervisor children inherit the override", %{config_dir: config_dir} do
    # --- The production async-load spawn path ------------------------------
    # `EvoDash.SafeCall.start/4` starts the child with
    # `Task.Supervisor.start_child/2`, i.e. the exact mechanism every LiveView
    # async load uses. Chain covered: test pid → child (the child's `$callers`
    # is `[test pid]`).
    assert {:ok, _pid} =
             EvoDash.SafeCall.start(self(), :config_dir_seam_probe, fn ->
               EvoGit.Platform.config_dir()
             end)

    assert_receive {:config_dir_seam_probe, {:ok, ^config_dir}}, 5_000

    # --- `Task.Supervisor.async_nolink/2` ----------------------------------
    # Chain covered: test pid → task.
    task =
      Task.Supervisor.async_nolink(EvoDash.TaskSupervisor, fn ->
        EvoGit.Platform.config_dir()
      end)

    assert Task.await(task, 5_000) == config_dir

    # --- Transitivity ------------------------------------------------------
    # Chain covered: test pid → task → grandchild, which is the shape a mounted
    # view produces (view `$callers` = [test pid] → load task `$callers` =
    # [view pid, test pid] → anything that task spawns).
    task =
      Task.Supervisor.async_nolink(EvoDash.TaskSupervisor, fn ->
        Task.async(fn -> EvoGit.Platform.config_dir() end) |> Task.await(5_000)
      end)

    assert Task.await(task, 5_000) == config_dir

    # --- The escaping process class (documented, not ignored) --------------
    # A raw `spawn/1` is NOT a `proc_lib` child, so nothing propagates
    # `:"$callers"` and it falls through to the BEAM-global fallback. This is
    # the boundary the seam cannot cross: a module whose config read happens in
    # such a process (typically a boot-time app-global singleton) must stay
    # `async: false`.
    parent = self()
    spawn(fn -> send(parent, {:raw_spawn_config_dir, EvoGit.Platform.config_dir()}) end)
    assert_receive {:raw_spawn_config_dir, raw_spawn_dir}, 5_000
    assert raw_spawn_dir == without_override(fn -> ConfigDir.config_dir() end)
    assert raw_spawn_dir != config_dir
  end

  # Runs `fun` with this process' config-dir override temporarily removed,
  # restoring the exact prior value afterwards (nothing to restore when it was
  # absent).
  defp without_override(fun) do
    override = Process.get(:evogit_config_dir)
    Process.delete(:evogit_config_dir)

    try do
      fun.()
    after
      if override, do: Process.put(:evogit_config_dir, override)
    end
  end

  # The Phoenix.LiveViewTest View struct exposes no assigns accessor in this
  # version, so read the LiveView socket assigns directly from the process
  # state (same pattern as projects_live_test.exs / settings_live_test.exs).
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
