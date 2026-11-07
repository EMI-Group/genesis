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

  The tests prove supervised-task inheritance (including transitivity), the raw
  spawn escape boundary, and the fallback directory's first-run redirect.
  The positive mounted proof lives in ConfigDirMountedTest below because its
  real Projects loader also reads a BEAM-global runner seam.

  Each test's config directory is unique, so the path-keyed config caches are
  safe and no process-wide environment write is needed.
  """

  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EvoDash.Test.ConfigDir
  alias EvoDash.Test.ConfigDirTest.Fixture

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

    # A raw spawn does NOT propagate `$callers`; document the escaping process
    # class rather than pretending that the seam reaches boot-time singletons.
    parent = self()
    spawn(fn -> send(parent, {:raw_spawn_config_dir, EvoGit.Platform.config_dir()}) end)
    assert_receive {:raw_spawn_config_dir, raw_spawn_dir}, 5_000
    assert raw_spawn_dir == Fixture.without_override(fn -> ConfigDir.config_dir() end)
    assert raw_spawn_dir != config_dir
  end
end

defmodule EvoDash.Test.ConfigDirMountedTest do
  @moduledoc """
  Proves the config-directory override reaches both real mounted pages and the
  Projects page's supervised canonical selection load, not just the test pid.
  """

  # The async ProjectsLiveTest replaces the process-global
  # :evo_dash, :projects_async_load_runner with its own gated/empty picker
  # fixture. This proof must exercise the DEFAULT loader, not that foreign
  # fixture, so only the positive mounted test runs after the async cohort.
  # Per-process config isolation itself remains async-safe (proved above).
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EvoDash.Test.ConfigDir
  alias EvoDash.Test.ConfigDirTest.Fixture

  setup context, do: Fixture.setup(context)

  test "the mounted LiveView resolves the per-process config dir",
       %{conn: conn, config_dir: config_dir, probe_provider_id: probe_provider_id} do
    # Pin fixture ownership: the mounted proof must use the production batch,
    # never a runner installed by a different test module.
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
             ~s(#provider-profiles-editor [phx-click="edit_provider_profile"][phx-value-profile_id="#{probe_provider_id}"])
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
