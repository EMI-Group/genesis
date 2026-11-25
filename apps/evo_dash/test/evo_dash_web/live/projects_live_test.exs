# Dashboard LiveView test suite.
#
# NOTE: this file is intentionally long — it is the comprehensive test suite
# for the full dashboard UX, including the remote-node contexts (node-aware
# render gate, palette, per-node state persistence) from the `aa4605cc`
# workstream.

# ---------------------------------------------------------------------------
# The suite is split across three modules for one reason: everything that
# touches a MUTABLE process-wide global shared with another `async: true`
# module lives in the sync module at the bottom of this file, so the bulk of
# the suite can run async. Precedent: review_live_test.exs (async modules
# first, sync module last, shared helpers hoisted into a Helpers module).
#
# `EvoDashWeb.ProjectsLiveTest.Helpers` owns the fixtures, the bounded-poll
# waits and the per-test setup callbacks; bodies are unchanged apart from
# `defp` -> `def` (one module imports them, they are no longer file-private).
#
# ORDER MATTERS: every helper module (Helpers, and the fake
# `ConnectionManager` GenServer) is defined BEFORE the first test module.
# A module defined AFTER a test module is not guaranteed to be loaded when
# that module's tests run (`start_supervised!` would raise "…was given as a
# child to a supervisor but it does not exist"), so the trailing fake module
# was moved to the top of this file.
#
# Config isolation is the per-process `:config_dir_fun` seam
# (`EvoDash.Test.ConfigDir.isolate!/1` in `set_onboarding_completed/1`), NOT
# the BEAM-global `XDG_CONFIG_HOME`: the config dir is unique per test, so
# the path-keyed `EvoGit.Config` / `VersionState` caches stay cache-safe, and
# the mounted view + its supervised load tasks inherit the override through
# `$callers`.
# The PROJECT REGISTRY is isolated the same way and for the same reason
# (`EvoDash.Test.IsolatedVCT.isolate!/1`, also in `set_onboarding_completed/1`):
# `EvoGit.VCT` is a run-wide store-backed singleton, so every module here gets
# a private instance designated through `:evogit_vct_server` and inherited by
# the view + its load tasks through `EvoDash.VCTScope`'s spawn-chain walk.

# A minimal GenServer standing in for a real remote connection manager in
# `EvoGit.RemoteConnection.Registry` (same pattern as
# EvoDashWeb.NodeAwareTest.ConnectionManager). `connect/1` on the real manager
# resolves the registered pid via the Registry and calls `:connect`; the fake
# answers with a configurable result so `retry_remote_connection` /
# `select_node` never start real SSH machinery. The process dies (and its
# Registry entry is auto-removed) at test end via `start_supervised!`.
#
# Startup shapes (preserving the original 2-tuple for existing call sites):
#   * `{target_id, status}` — `:connect` answers `{:ok, :connecting}`
#   * `{target_id, status, opts}` — `opts` may set `:connect_result` (the
#     `:connect` reply, default `{:ok, :connecting}`) and an optional
#     `:connect_delay_ms` (sleep before replying). NOTE: the off-process property
#     is proven by the recorded caller pid (see `:callers` below), NOT by any
#     delay — the caller-pid assertion is delay-independent.
#
# Extra calls used by the event-driven async-connect tests:
#   * `{:set_status, status}` — test-driven phase mutation (the broadcast →
#     gate reconciliation path re-reads the LIVE manager, so the stored status
#     must flip before the broadcast is sent)
#   * `:calls` / `:callers` — recorded `:connect` invocation count / caller
#     pids (a caller that is neither the LiveView process nor the test process
#     proves the connect ran on `EvoDash.TaskSupervisor`).
defmodule EvoDashWeb.ProjectsLiveTest.ConnectionManager do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init({target_id, status}) do
    init({target_id, status, []})
  end

  def init({target_id, status, opts}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)

    {:ok,
     %{
       status: status,
       connect_result: Keyword.get(opts, :connect_result, {:ok, :connecting}),
       connect_delay_ms: Keyword.get(opts, :connect_delay_ms),
       connect_callers: []
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_call(:connect, from, state) do
    # The delay sleeps INSIDE the fake (a GenServer handle_call) so any caller
    # that blocks on the connect synchronously would stall; recording the
    # caller pid lets the test prove the connect ran on a separate process.
    if delay = state.connect_delay_ms, do: Process.sleep(delay)

    {:reply, state.connect_result,
     %{state | connect_callers: [elem(from, 0) | state.connect_callers]}}
  end

  @impl true
  def handle_call({:set_status, status}, _from, state),
    do: {:reply, :ok, %{state | status: status}}

  @impl true
  def handle_call(:calls, _from, state), do: {:reply, length(state.connect_callers), state}

  @impl true
  def handle_call(:callers, _from, state), do: {:reply, state.connect_callers, state}
end

defmodule EvoDashWeb.ProjectsLiveTest.Helpers do
  @moduledoc false
  # Fixtures + helpers shared by the async and the sync ProjectsLive modules below.
  # Public instead of private because the suite is split across modules; bodies are
  # unchanged apart from `defp` -> `def`. `use EvoDashWeb, :verified_routes` is
  # needed for the `~p` sigil in any helper body, and the `Phoenix.ConnTest` /
  # `Phoenix.LiveViewTest` imports cover `live/2`, `render/1` and `render_click/3
  # (the helper bodies call them).

  use EvoDashWeb, :verified_routes
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskInfo

  # Load-tolerant budgets for waits on ASYNC page work (the mount load batch,
  # remote activation/resume reads, GitHub runners). That work runs in
  # supervised tasks on a shared host whose scheduling swings 10-30x
  # (test/CONTEXT.md), so the previous 2-5 s budgets intermittently expired.
  # The waits stay bounded and still fail loudly — only the deadlines moved.
  @async_wait_budget_ms 30_000
  # `:sys.get_state/2` timeout for `assigns/1`: the LiveView can be starved for
  # seconds on a loaded host, where the 5 s default exits the test.
  @assigns_timeout_ms 30_000

  # The same load-tolerant budget for `assert_receive` handshakes in the test
  # modules below (module attributes are not importable across modules).
  def async_wait_budget, do: @async_wait_budget_ms

  # Builds the module-wide git fixture template ONCE per suite module (called
  # from each module's `setup_all`) and copies it per test. Every git fixture
  # needs a real repository with one (empty) commit, and `git init` +
  # `git commit` cost ~13ms of subprocess time per fixture (~28 fixtures per
  # run). Build that repository ONCE and copy it per test instead
  # (`File.cp_r!` is ~3.5ms).
  #
  # Each copy stays a REAL, INDEPENDENT repository: it is a plain recursive
  # BYTE copy — never `cp -l`/hard links and never `git clone --shared` into
  # the template's object store — so a test may freely commit into or mutate
  # its copy (one does: a second commit feeding an updated base_sha). The
  # template is quiescent when copied (no index.lock, no in-flight process)
  # and its `.git/hooks` sample scripts are dropped: they are inert samples
  # and the biggest part of the copy cost.
  def install_git_template(_context) do
    {template, sha} = build_git_template!()
    key = {__MODULE__, :git_template}
    :persistent_term.put(key, {template, sha})

    on_exit(fn ->
      # Guarded erase: both suite modules build a template, so never erase a key
      # that has already been replaced by the other module's value.
      if :persistent_term.get(key, nil) == {template, sha} do
        :persistent_term.erase(key)
      end
    end)

    :ok
  end

  # The module-OWNED variant of `install_git_template/1`: the template rides the
  # test context (`context.git_template`) instead of the BEAM-global
  # `:persistent_term` slot.
  #
  # The shared slot belongs to whichever module installed it LAST and is erased
  # by THAT module's `on_exit`, so a THIRD module running concurrently with the
  # two shared-key modules loses the template mid-run (observed as
  # `ArgumentError ... no persistent term stored with this key` raised from
  # `git_template!/0` in whichever of the two shared-key modules was still
  # running). An owned template is built once per module, is unreachable from
  # any other module and is removed by this module's own `on_exit` only.
  def install_owned_git_template(_context) do
    {:ok, git_template: build_git_template!()}
  end

  # Builds ONE real git fixture template (a repository carrying one empty
  # commit) in a fresh temp dir, registers its removal on exit and returns
  # `{template_path, head_sha}`. The CALLER owns the reference: the shared
  # `install_git_template/1` stores it in `:persistent_term`, the owned variant
  # keeps it in the test context.
  def build_git_template! do
    template = Path.join(System.tmp_dir!(), "evogit_git_template_#{System.unique_integer()}")
    File.mkdir_p!(template)
    {_, 0} = System.cmd("git", ["init", template], stderr_to_stdout: true)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.email=t@example.com",
          "-c",
          "user.name=t",
          "commit",
          "--allow-empty",
          "-m",
          "init"
        ],
        cd: template,
        stderr_to_stdout: true
      )

    File.rm_rf!(Path.join(template, ".git/hooks"))
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: template)

    on_exit(fn ->
      # Teardown-only rescue: a cleanup failure must never mask a test failure.
      try do
        File.rm_rf!(template)
      rescue
        _ -> :ok
      end
    end)

    {template, String.trim(sha)}
  end

  def git_template!, do: :persistent_term.get({__MODULE__, :git_template})

  def setup_temp_dir(%{} = context) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit_test_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.VCT.forget(tmp_dir)
      rescue
        _ -> :ok
      end

      EvoDash.Test.FsCleanup.rm_rf!(tmp_dir)
    end)

    {:ok, Map.put(context, :tmp_dir, tmp_dir)}
  end

  # The ProjectsLive mount redirects first-time users to /welcome via
  # server-based detection (EvoGit.Config.VersionState.onboarding_needed?/0,
  # which is true when no version-state file exists). To keep the dashboard
  # tests deterministic regardless of host state, isolate the config dir to a
  # per-test temp directory through the `:config_dir_fun` seam
  # (`EvoDash.Test.ConfigDir.isolate!/1` -> `EvoGit.Platform.config_dir/0`,
  # inherited by the mounted view and its supervised load tasks through
  # `$callers`) and mark onboarding complete by writing a version-state file
  # there. The layout is `<dir>/genesis/...` (what `EvoGit.Platform.config_dir/0`
  # expects); the mechanism is per-process, never a BEAM-global env var.
  def set_onboarding_completed(%{conn: conn} = _context) do
    EvoDash.Test.ConfigDir.isolate!("evogit_dashboard_test_config")

    # The project registry is a run-wide, store-backed SINGLETON (`EvoGit.VCT`):
    # without this, every mount ANY concurrently running test makes is visible
    # to this test's page (which then auto-activates a stranger's project) and
    # this test's `clear_projects/0` destroys other tests' fixtures. This boots
    # a private instance and designates it through `:evogit_vct_server`, which
    # `EvoDash.VCTScope` resolves for the mounted view and its load tasks.
    EvoDash.Test.IsolatedVCT.isolate!()

    # Create the version-state file so onboarding_needed?/0 returns false.
    EvoGit.Config.VersionState.complete_onboarding()

    # `isolate!/1` registers the directory's ONLY cleanup (drain-backed, then
    # deadline-bounded removal); registering a second raw `File.rm_rf!/1` here
    # would run FIRST (LIFO) with no drain and race a supervised page-load
    # writer — the `File.Error ... file already exists` teardown flake.
    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  # ActiveTasks is a process-less public ETS table shared by the whole run and
  # NOT terminated by the per-test isolation above — clear it so one test's
  # sidebar snapshot never leaks into the next. Scoped to the LOCAL
  # `{nil, node()}` context because this callback also runs in the `async: true`
  # module, where a whole-table `reset/0` would delete a concurrent module's
  # per-test snapshot between its put and its get; the sync module's hub
  # assertions are local-context only, so one clear serves both.
  def reset_active_tasks_hub(_context) do
    EvoDash.ActiveTasks.invalidate(nil, node())
    :ok
  end

  # Forgets every mount of THIS test's own, already-isolated VCT instance
  # (`EvoDash.Test.IsolatedVCT`), so the palette is provably empty for tests
  # that assert on list CONTENT — several call it right after mounting, or
  # after `seed_project/2` seeded a fixture they want gone.
  #
  # It cannot destroy a concurrent test's fixtures: the table it sweeps belongs
  # to this test alone. (It USED to be a run-wide wipe, which is exactly the
  # class of interference the instance isolation removes.)
  def clear_projects do
    for project <- EvoGit.VCT.projects() do
      _ = EvoGit.VCT.forget(project.point)
    end

    :ok
  end

  # Opens `path` as the active project in ONE event turn.
  #
  # This is the SAME handler the palette's open-path form submits to
  # (`open_project_palette` → `palette_mode "open_path"` → form submit is only
  # a way of REACHING `handle_event("open_project", %{"path" => ...})`), and
  # its render already carries the post-`push_patch` (activated) DOM, so the
  # tests that merely need an active project — so the task form renders —
  # save the two palette-opening round-trips. Tests that assert palette UI
  # (the "opening a project" / "project palette" describes) keep driving the
  # clicks themselves.
  #
  # Selecting a project now lands on the PROJECT OVERVIEW, not in the composer,
  # so this helper steps into the composer the way a user does
  # (`enter_composer/1`): the composer these callers were written for is exactly
  # what they then exercise.
  #
  # It returns a SETTLED frame: see the comment in the body for why both turns'
  # async batch is awaited before the render it hands back.
  def open_project!(view, path) do
    render_click(view, "open_project", %{"path" => path})
    _ = enter_composer(view)
    # SETTLE THE PAGE'S OWN ASYNC WORK BEFORE RETURNING. Both turns above run
    # the page's ONE async batch (`AsyncLoad.maybe_spawn/2` on the activation's
    # `handle_params` and again on `compose_task`'s patch), so the frame
    # `enter_composer/1` returns can still carry the mount defaults
    # (`custom_agents: []`, `projects: []`, `model_selection_ready?: false`).
    # Callers assert on exactly that batch-seeded state — on the assigns AND on
    # the returned HTML (`assert html =~ "Bug Hunter"`) — so wait for the batch
    # (the file's monitor-based, deadline-bounded `await_async_loads/1`) and
    # hand back a FRESH render of the settled frame. A caller that must observe
    # the transient LOADING state (`#model-selection-loading`) cannot use this
    # helper; it drives the patch itself.
    await_async_loads(view)
    render(view)
  end

  # Steps from the PROJECT OVERVIEW into the task composer through its "New
  # task" entry point (`compose_task` → `push_patch` with `wb_task=1`), exactly
  # as a user leaves the overview. Returns the resulting rendered HTML so
  # callers can assert on composer markup the way they did when the composer
  # was the landing surface.
  #
  # A page that is NOT on the overview (already composing, the idle workbench,
  # a remote gate, or a remote activation whose async result has not landed
  # yet) is left untouched — the click is only issued where the overview
  # actually owns the surface.
  def enter_composer(view) do
    if has_element?(view, "#workbench-project-overview") do
      render_click(view, "compose_task", %{})
    else
      render(view)
    end
  end

  # Mounts a project in THIS test's own VCT instance (returns the
  # `%EvoGit.VCT.Mount{}` so callers can assert its `point` instead of
  # hardcoding `vct:///projects/<name>`) and registers on_exit cleanup so the
  # row does not even outlive the test's own table. `EvoGit.VCT.mount/2` is
  # called from the TEST process, which carries the instance designation
  # (`EvoDash.Test.IsolatedVCT`), so it lands in the private table.
  def seed_project(path, name) do
    assert {:ok, mount} = EvoGit.VCT.mount(path, name: name)

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.VCT.forget(mount.point)
      rescue
        _ -> :ok
      end
    end)

    mount
  end

  # Extracts the inner HTML of the edit-mode path-suggestion datalist so
  # option ordering/uniqueness can be asserted precisely.
  def path_suggestions_datalist(html) do
    case Regex.run(~r{<datalist id="path-suggestions">(.*?)</datalist>}s, html) do
      [_, inner] -> inner
      _ -> ""
    end
  end

  # Extracts ONE palette ROW's markup from the rendered palette.
  #
  # The whole-page HTML contains every mounted project (this file's suite runs
  # concurrently with others that seed their own mounts), so a page-wide
  # `string_index/2` comparison cannot say anything about the ORDER of a single
  # row's identity lines. Each row is wrapped in `<div class="relative group">`,
  # so splitting on that wrapper yields one chunk per row; the chunk carrying
  # `phx-value-path="<path>"` is that project's row (rows are rendered
  # newest-opened first, so the chunk ends at the next row's wrapper).
  def palette_row(html, path) do
    case Enum.find(
           String.split(html, ~s(<div class="relative group">)),
           &String.contains?(&1, ~s(phx-value-path="#{path}"))
         ) do
      nil -> flunk("no palette row found for #{inspect(path)}")
      row -> row
    end
  end

  # Returns the byte index of the first occurrence of `pattern` in `string`,
  # or nil if it is not present.
  def string_index(string, pattern) do
    case :binary.match(string, pattern) do
      {idx, _len} -> idx
      :nomatch -> nil
    end
  end

  # Inserts a task directly into the shared SQLite store (bypassing the async
  # task spawn that `start_task/2` triggers) and registers on_exit cleanup so
  # the fixture never leaks into other tests in this file (the shared store
  # persists across tests). Returns the inserted %TaskInfo{}.
  def insert_task_fixture!(overrides) do
    id = "fixture_#{System.unique_integer([:positive])}"

    task =
      %TaskInfo{
        id: id,
        type: :genesis,
        status: :completed,
        opts: Keyword.merge([path: "/tmp/test"], Keyword.get(overrides, :opts, [])),
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }
      |> Map.merge(Enum.into(overrides, %{}))

    EvoGit.Store.put_task(EvoGit.Store, task)

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.Store.delete_task(EvoGit.Store, id)
      rescue
        _ -> :ok
      end
    end)

    task
  end

  # Extracts the task id from the "task started with ID: <id>" flash of a
  # task_submit render, registers on_exit cancel+delete cleanup (the shared
  # SQLite store persists across tests in this file), waits (bounded) for the
  # task to reach a terminal status, and returns the id so the test can
  # inspect the persisted task's opts. Mirrors the inline pattern used by the
  # existing launch tests.
  #
  # The wait is the load-bearing part: the wrapper's short life runs git ports
  # under tmp_dir, and if the setup on_exit File.rm_rf!(tmp_dir) fired while a
  # port was still spawning there, ERTS prints an uncatchable
  # "spawn: Could not cd to <tmp_dir>" line on stderr — test-output noise. The
  # wait returns almost immediately: on a SEEDED git repo (make_git_repo!/1)
  # the doomed wrapper runs one instant `git rev-parse` port and then dies at
  # node-path validation. Callers that call wait_for_task_terminal/2
  # themselves just wait a second time (a no-op once terminal).
  #
  # No in-body cancel_task/1: the wrapper is already terminal by the time the
  # wait returns, and cancelling a live wrapper would drag the scheduler's
  # graceful-cancel machinery (marker writes, broadcasts, grace turns) into
  # the test for zero assertion value. The on_exit cancel is a rescued safety
  # net only (on a terminal row it is a no-op {:error, :not_running}).
  def cleanup_launched_task(html) do
    [id] = Regex.run(~r/task started with ID: ([a-f0-9]{16})/, html, capture: :all_but_first)

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.TaskRegistry.cancel_task(id)
      rescue
        _ -> :ok
      end

      try do
        EvoGit.TaskRegistry.delete_task(id)
      rescue
        _ -> :ok
      end
    end)

    wait_for_task_terminal(id)

    id
  end

  # Waits (bounded) for a launched task to reach a terminal status so its
  # wrapper process has finished spawning git ports under the project's
  # directory — otherwise the setup's on_exit File.rm_rf!(tmp_dir) can race a
  # still-spawning port and ERTS prints an uncatchable "spawn: Could not cd to
  # <tmp_dir>" line on stderr. Best-effort: on timeout the test proceeds (the
  # on_exit cleanups are rescued).
  #
  # DEADLINE based, not attempt based, exactly like `wait_assigns/3`: the poll
  # cadence is 2ms, so a wrapper that has already gone terminal is seen on the
  # next tick instead of eating a fixed sleep, while the 10s budget — the part
  # that protects against a wedge — is unchanged.
  def wait_for_task_terminal(id, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    loop = fn loop ->
      case EvoGit.TaskRegistry.get_task(id) do
        nil ->
          :ok

        %TaskInfo{status: status} when status in [:completed, :failed, :cancelled] ->
          :ok

        _ ->
          if System.monotonic_time(:millisecond) < deadline do
            Process.sleep(2)
            loop.(loop)
          else
            :ok
          end
      end
    end

    loop.(loop)
  end

  # Decoded task opts are a list of mixed atom/string-key tuples (the Store
  # codec atomizes only its whitelist), so string keys must be looked up via
  # Map.new — Access.get/3 and Keyword.has_key?/2 reject non-atom keys on
  # keyword lists.
  def opt(task, key), do: Map.get(Map.new(task.opts || []), key)

  def has_opt?(task, key), do: Map.has_key?(Map.new(task.opts || []), key)

  # The speed ↔ quality opt is threaded as :quality_level with a STRING value
  # ("fast"/"high_quality"). The persisted row round-trips through
  # EvoGit.Store.Codec, which atomizes ONLY its known-opt-key whitelist (see
  # `opt(task, "agent")` above for the same shape): a key outside the whitelist
  # decodes as a STRING key. Read BOTH forms so this assertion holds whether or
  # not the key is (ever) whitelisted — no dependency on the core opt whitelist.
  def quality_level_opt(task) do
    opts = Map.new(task.opts || [])
    Map.get(opts, :quality_level) || Map.get(opts, "quality_level")
  end

  def has_quality_level_opt?(task) do
    opts = Map.new(task.opts || [])
    Map.has_key?(opts, :quality_level) or Map.has_key?(opts, "quality_level")
  end

  # The persist-agent-state opt is always sent explicitly
  # (`:persistent_state`, boolean). `:persistent_state` is not in
  # `EvoGit.Store.Codec`'s known-opt whitelist, so read BOTH the atom and the
  # string key — a `Map.get/3`-OR chain would lose `false`, hence the
  # `Map.fetch/2` + `has_key?` pair.
  def persistent_state_opt(task) do
    opts = Map.new(task.opts || [])

    case Map.fetch(opts, :persistent_state) do
      {:ok, value} -> value
      :error -> Map.get(opts, "persistent_state")
    end
  end

  def has_persistent_state_opt?(task) do
    opts = Map.new(task.opts || [])
    Map.has_key?(opts, :persistent_state) or Map.has_key?(opts, "persistent_state")
  end

  # The active segment of the speed ↔ quality control is the button whose
  # aria-pressed is "true" and whose class carries capsule-stop-active
  # (fused-capsule markup; component-side contract in
  # task_form_provider_selection_test.exs).
  def quality_step_active?(html, level) do
    [btn] = html |> Floki.parse_document!() |> Floki.find("button#quality-level-#{level}")
    class = btn |> Floki.attribute("class") |> List.first() |> to_string()
    aria_pressed = btn |> Floki.attribute("aria-pressed") |> List.first()
    class =~ "capsule-stop-active" and aria_pressed == "true"
  end

  # Saves a unique remote connection target under the test's isolated config
  # dir (set_onboarding_completed activates a per-test `:config_dir_fun`
  # override) and
  # registers cleanup. Returns the target id. Each test uses a unique id so the
  # TOML file never has colliding entries across tests.
  def save_target!(name \\ "Test Target") do
    id = "test-target-#{System.unique_integer([:positive])}"

    {:ok, _target} =
      EvoGit.RemoteConnections.save(%{ssh_target: "user@host", id: id, name: name})

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        EvoGit.RemoteConnections.delete(id)
      rescue
        _ -> :ok
      end
    end)

    id
  end

  # Creates a REAL git repo fixture at `Path.join(tmp_dir, name)` with an
  # initial commit, returning `{path, head_sha}`. The new foreign-repo
  # validation checks git-ness via `EvoGit.Adapters.Git.rev_parse/1` (runs
  # `git rev-parse HEAD`, which FAILS on an empty repo), so fixture repos MUST
  # contain at least one commit — the module-wide template in `setup_all`
  # carries that `--allow-empty` commit. Registers on_exit cleanup.
  def git_repo_fixture!(tmp_dir, name) do
    path = Path.join(tmp_dir, name)
    {template, head_sha} = git_template!()
    File.cp_r!(template, path)

    on_exit(fn ->
      # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
      try do
        File.rm_rf!(path)
      rescue
        _ -> :ok
      end
    end)

    {path, head_sha}
  end

  # Seeds `path` as a REAL git repository with an initial (empty) commit —
  # synchronously, in the test process (a byte copy of the module-wide template
  # built in `setup_all`) — before a task is launched against it.
  # This is the quiet-launch contract shared by every launch test in this file.
  #
  # The task-form launch tests submit `node_path: "./nonexistent-dir"`: the
  # spawned wrapper dies AT VALIDATION, by design, BEFORE any agent dispatch —
  # `EvoGit.Runtime.Helpers.validate_node_path/2` runs after ensure_repo and
  # starting-commit resolution but before run_mode spawns any agent — so no
  # LLM call can ever happen. That matters because the scheduler's model
  # profiles come from the boot-time ambient config, NOT the per-test
  # config-dir isolation: a VALID node path would proceed to
  # AgentScheduler.run_agent and reach the real LLM, which is exactly why the
  # invalid path is load-bearing and must stay.
  #
  # The seeded repo keeps the doomed wrapper's brief life pure validation: a
  # pre-existing .git directory short-circuits Runtime.ensure_repo/1 (no
  # `git init`/`add`/`commit` ports under tmp_dir, no repo mutation) and
  # `git rev-parse HEAD` succeeds, so the wrapper spawns a couple of instant
  # ports and then returns the node-path error. Without the seed the wrapper
  # git-inits the project itself — port spawns racing the setup's on_exit
  # rm_rf! printed uncatchable "spawn: Could not cd to <tmp_dir>" lines, and
  # the repo mutation bought no assertion anything.
  # `owned_template` is a `{template_path, head_sha}` pair from
  # `install_owned_git_template/1` — the module-local alternative to the shared
  # `:persistent_term` template (see that callback).
  def make_git_repo!(path, owned_template \\ nil) do
    {template, _head_sha} = owned_template || git_template!()
    File.cp_r!(template, path)

    path
  end

  # Stubs the async GitHub-upstream check (Project.GitHub.maybe_check/1
  # spawns it on every non-genesis_new project activation, and the default
  # runner shells out to `git remote get-url origin` in the project path).
  # Tests whose tmp_dir is non-empty (foreign-repo fixtures, staged .png
  # files) activate as genesis_existing/evolve_simple and would otherwise
  # spawn a REAL git port under tmp_dir that can still be starting when the
  # setup on_exit rm_rf! fires — ERTS prints an uncatchable
  # "spawn: Could not cd to <tmp_dir>" line. These tests assert nothing
  # GitHub-related, so the stub is pure noise elimination.
  #
  # Called per-test/per-helper at the EXPOSED activation sites only (the
  # GitHub-issue-integration describe stubs its own seams via
  # put_github_seams/1 and must not be clobbered; an empty tmp_dir
  # auto-detects genesis_new, which never checks). Conflict-free: nothing
  # else in this file reads :github_runner, the assertion surface is
  # unchanged (an :error status renders no GitHub UI), and no other suite in
  # the tree touches the key (it is this file family's own seam), so the
  # global stub cannot race a peer.
  def stub_github_upstream_check! do
    Application.put_env(:evo_dash, :github_runner, fn _node, _path ->
      {:error, :no_github_upstream}
    end)

    on_exit(fn ->
      Application.delete_env(:evo_dash, :github_runner)
    end)

    :ok
  end

  # The Phoenix.LiveViewTest View struct exposes no assigns accessor in this
  # version, so read the LiveView socket assigns directly from the process
  # state (same pattern as welcome_live_test.exs / settings_live_test.exs).
  def assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns

  # Bounded poll on the LiveView assigns (async remote-project activation runs
  # in a supervised Task and lands a frame later via handle_info). `predicate`
  # receives the assigns map; flunks after the budget (default 3s) so a wedged
  # async flow fails loudly instead of hanging.
  #
  # DEADLINE based, not attempt based: the poll cadence is 2ms (an async
  # message that has already landed is seen within one tick instead of eating a
  # 10ms sleep), while the total budget — the part that protects against a
  # wedge — is unchanged. `assigns/1` is a `:sys.get_state` round-trip, so a
  # successful poll also guarantees the view has processed every message the
  # TEST process queued before it (Erlang signal order per sender pair).
  def wait_assigns(view, predicate, timeout_ms \\ @async_wait_budget_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll = fn poll ->
      cond do
        predicate.(assigns(view)) ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("wait_assigns timed out. Last assigns: #{inspect(assigns(view))}")

        true ->
          Process.sleep(2)
          poll.(poll)
      end
    end

    poll.(poll)
  end

  # Waits until the connected mount's ASYNC load batch has applied the seeded
  # projects. `ProjectsLive.mount/3` seeds `projects: []` and the
  # real list arrives one frame later via the
  # `{:async_project_load, ...}` continuation (see
  # `EvoDashWeb.ProjectsLive.AsyncLoad`), so every test that seeds projects and
  # then asserts palette / datalist / auto-activation state MUST wait for the
  # batch first — otherwise the assertion races the continuation (seed
  # dependent). Bounded through `wait_assigns/2`, so real breakage still fails
  # loudly instead of hanging.
  def wait_for_projects(view, paths) do
    wait_assigns(view, fn assigns ->
      loaded = for %{path: path} <- assigns[:projects] || [], do: path
      Enum.all?(List.wrap(paths), &(&1 in loaded))
    end)
  end

  # Waits until the async batch has SEEDED the notified-terminal-id set.
  # Notification scanning is skipped entirely until
  # `notified_task_ids_ready?` is true (diffing against an unseeded empty set
  # would notify for every historical task), so tests that exercise the
  # notification path must wait for readiness instead of racing it.
  def wait_notified_ids_ready(view) do
    wait_assigns(view, fn assigns -> assigns[:notified_task_ids_ready?] == true end)
  end

  # Awaits the ASYNC task launch's ack (see `do_task_submit/4` + the
  # `handle_info({{:task_started, ...}, result})` continuation): the start call
  # runs in a supervised task, so until the ack lands `:task_launching` is true
  # and the flash, the reset form and the pushed `clear_prompt` event do not
  # exist yet. Polls the assigns (deadline based, through `wait_assigns/2`, no
  # fixed sleep) and then re-renders so the returned HTML carries the ack's
  # flash.
  #
  # `min_seq` makes a test that submits MORE THAN ONCE await the newer ack only:
  # pass the `:task_launch_seq` observed BEFORE the submit (the seq is
  # monotonic, so a superseded launch's ack can never satisfy the wait).
  def await_task_launch(view, min_seq \\ 0) do
    wait_assigns(view, fn assigns ->
      Map.get(assigns, :task_launch_seq, 0) > min_seq and
        Map.get(assigns, :task_launching, false) == false
    end)

    render(view)
  end

  # Installs the ProjectsLive async-batch seam, resolved AT SPAWN TIME by
  # `AsyncLoad.maybe_spawn/2`. The whole batch runs inside
  # `EvoDash.SafeCall.run/1`, so a fun that exits/raises sends NO result
  # message at all and the page keeps the defaults `mount/3` seeded.
  def install_projects_async_load_runner(fun) do
    Application.put_env(:evo_dash, :projects_async_load_runner, fun)

    on_exit(fn ->
      Application.delete_env(:evo_dash, :projects_async_load_runner)
    end)
  end

  # `install_projects_async_load_runner/1` PLUS a per-spawn report to the test
  # process (`{:batch_started, task_pid, callers}`), so a test can COUNT the
  # batches a page actually started instead of inferring a spawn from its
  # effects. `batch_fun` is the 0-arity batch body, resolved (and run) inside
  # the supervised task like the real loader.
  #
  # The report carries the child's `$callers` because the seam is BEAM-global:
  # another concurrently running async module's mounted page invokes it too, so
  # a caller-aware wait (`await_view_batch/2`) is what attributes a spawn to the
  # page under test.
  def install_reporting_async_load_runner(batch_fun) when is_function(batch_fun, 0) do
    test_pid = self()

    install_projects_async_load_runner(fn ->
      send(test_pid, {:batch_started, self(), Process.get(:"$callers") || []})
      batch_fun.()
    end)
  end

  # Bounded wait for the next async-batch spawn attributable to `view_pid`
  # (a mounted view's pid, or `self()` for a directly driven socket), returning
  # the batch task's pid. A report from another page sharing the app-env seam is
  # skipped instead of failing the wait.
  def await_view_batch(view_pid, timeout_ms \\ @async_wait_budget_ms) do
    await_view_batch_until(view_pid, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp await_view_batch_until(view_pid, deadline) do
    receive do
      {:batch_started, task_pid, callers} ->
        if view_pid in callers,
          do: task_pid,
          else: await_view_batch_until(view_pid, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("await_view_batch timed out waiting for a batch spawned by #{inspect(view_pid)}")
    end
  end

  # These URL fixtures keep a genuinely distinct BEAM identity throughout the
  # real supervised activation, resume read and batch delivery paths. No runner
  # reads local config, task storage or the filesystem on the remote's behalf.
  def install_remote_activation_fixture!(path, resume_task \\ nil) do
    id = save_target!()
    remote_node = String.to_atom("projects_url_#{id}@127.0.0.1")
    test_pid = self()

    start_supervised!(
      {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
       {id, %{phase: :connected, node: to_string(remote_node), last_error: nil}}}
    )

    bundle =
      EvoDashWeb.ProjectsLive.Project.load_model_selection_from_config(
        %{
          llm: %{
            default_provider_profile: "remote-account",
            providers: [
              %{
                "id" => "remote-account",
                "provider" => "anthropic",
                "default_model" => "remote-model",
                "models" => [%{"model" => "remote-model"}]
              }
            ]
          }
        },
        false
      )

    point = "vct:///projects/#{Path.basename(path)}"

    results = %{
      projects: [%{point: point, path: path, name: Path.basename(path)}],
      active_project: %{point: point, path: path, name: Path.basename(path)},
      active_project_path: path,
      task_mode: "genesis_new",
      task_mode_info: EvoDashWeb.Helpers.mode_info_message("genesis_new"),
      project_config: %{},
      worktree_script: "",
      commands: [],
      foreign_repos: []
    }

    runners = %{
      remote_project_load_runner: fn ^remote_node, ^path ->
        send(
          test_pid,
          {:remote_project_loaded, self(), Process.get(:"$callers"), remote_node, path}
        )

        {:ok, results}
      end,
      remote_resume_task_runner: fn ^remote_node, task_id ->
        assert resume_task != nil
        assert task_id == resume_task.id

        send(
          test_pid,
          {:remote_resume_read, self(), Process.get(:"$callers"), remote_node, task_id}
        )

        resume_task
      end,
      projects_async_load_runner: fn ->
        # AsyncLoad supplies the target/node/generation envelope itself. Omit
        # foreign_repos here so the resume test can drive its one-shot guard
        # explicitly after the real activation and patch batches settle.
        %{
          model_selection: bundle,
          custom_agents: [],
          model_selection_enabled: false,
          projects: results.projects,
          terminal_ids: nil,
          auto_activate?: false
        }
      end
    }

    for {key, runner} <- runners do
      previous = Application.fetch_env(:evo_dash, key)
      Application.put_env(:evo_dash, key, runner)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:evo_dash, key, value)
          :error -> Application.delete_env(:evo_dash, key)
        end
      end)
    end

    {id, remote_node}
  end

  def assert_remote_activation_loaded(view, id, remote_node, path) do
    view_pid = view.pid

    assert_receive {:remote_project_loaded, loader, [^view_pid | _], ^remote_node, ^path},
                   @async_wait_budget_ms

    assert loader != self()
    assert loader != view.pid
    wait_assigns(view, &(&1[:active_project_path] == path))
    await_async_loads(view)
    assert remote_node != node()
    assert assigns(view)[:current_node] == remote_node
    assert assigns(view)[:current_node_id] == id
    assert assigns(view)[:remote?] == true
    assert assigns(view)[:model_selection_ready?] == true
    assert assigns(view)[:model_selection_scope] == {id, remote_node}

    assert assigns(view)[:selected_model_spec] == %{
             "provider_profile_id" => "remote-account",
             "model" => "remote-model"
           }

    # The activation continuation `push_patch`es, and THAT `handle_params` run
    # spawns the load batch whose `projects` list the overview's selection is
    # confirmed against (`Overview.confirmed_scope?/2` requires a matching
    # `{path, point}` entry there) — a spawn the drain above can predate on a
    # loaded host. Drain once more: it is ordered after every message this view
    # has queued and waits on whatever it owns, so callers assert on a settled
    # page instead of the frame the activation result landed in.
    await_async_loads(view)
  end

  # Safety net for tests that freeze the shared, serialized task registry: a
  # failed assertion must never leave it suspended for the next suite.
  # Teardown-only rescue (the registry can already be gone at teardown time).
  def restore_registry_on_exit do
    on_exit(fn ->
      if Process.whereis(EvoGit.TaskRegistry) do
        try do
          :sys.resume(EvoGit.TaskRegistry)
        catch
          :exit, _ -> :ok
        end
      end
    end)
  end

  # Bounded poll on the fake connection manager's recorded `:connect` caller
  # list: keeps polling until `predicate` returns a truthy value over the
  # callers, then returns it. `predicate` returns nil to keep polling. Flunks
  # after the budget (default 3s) so a connect that never lands fails loudly
  # instead of hanging. Deadline + 2ms cadence for the same reasons as
  # `wait_assigns/3`.
  def wait_for_fake_callers(fake, predicate, timeout_ms \\ @async_wait_budget_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll = fn poll ->
      case predicate.(GenServer.call(fake, :callers)) do
        nil ->
          if System.monotonic_time(:millisecond) >= deadline do
            flunk(
              "wait_for_fake_callers timed out. Callers: #{inspect(GenServer.call(fake, :callers))}"
            )
          else
            Process.sleep(2)
            poll.(poll)
          end

        result ->
          result
      end
    end

    poll.(poll)
  end

  # Waits until every `EvoDash.TaskSupervisor` child started by THIS LiveView
  # process has exited, then flushes their result messages into the view.
  # Used for the mount-time load AND for a later `?node=` patch's load.
  #
  # `EvoDashWeb.ProjectsLive.AsyncLoad.maybe_spawn/2` starts ONE supervised
  # task per connected `handle_params` run. Its result
  # (`{:async_project_load, node, prev_node_id, path, results}`) is applied by
  # `handle_result/5`, whose stale-guard compares ONLY the captured node and
  # the active project path. A LOCAL mount spawns with `node = node()` and
  # `path = nil`; after a `?node=` switch to a `:connecting` target
  # `current_node` is STILL the local node and `active_project_path` is back to
  # nil — so a result that lands AFTER the switch passes the guard and
  # re-applies its captured `projects`, clobbering the just-cleared
  # assigns. (The `?node=` patch's own task is the ONLY writer of the cleared
  # `projects` for a `:connecting` target, and `render_patch/2` does not
  # wait for it either.) Draining the tasks before asserting removes that race
  # deterministically.
  #
  # `Task.Supervisor` records the spawning process in the child's `$callers`
  # process-dictionary entry, so matching it against the view pid targets
  # exactly this view's tasks — a leftover task from another test is never
  # waited on (and cannot block the mount). (Copied from
  # review_live_test.exs / settings_live_test.exs, where the same pattern fixed
  # an intermittent full-suite flake.)
  def await_async_loads(view) do
    # Synchronous mailbox drain FIRST: `:sys.get_state` is ordered after every
    # message the TEST process already sent to the view (Erlang signal order per
    # sender pair), so a `send(view.pid, :node_aware_reload_tasks)` sitting in
    # the mailbox is handled — and the supervised tasks it spawns exist — before
    # the monitor snapshot below. Without it the snapshot can race the send and
    # return an empty pid list.
    _ = assigns(view)

    view.pid
    |> mount_async_task_pids()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref ->
      # A task that already exited delivers its :DOWN immediately (reason
      # :noproc); the send/2 that carries its result always happens BEFORE the
      # process exits, so the message is queued by the time the monitor fires.
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        @async_wait_budget_ms -> :ok
      end
    end)

    _ = render(view)
    :ok
  end

  def mount_async_task_pids(view_pid) do
    EvoDash.TaskSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) ->
        if view_pid in task_callers(pid), do: [pid], else: []

      _ ->
        []
    end)
  end

  def task_callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :"$callers", [])
      _ -> []
    end
  end

  # Deterministically settles a `:node_aware_reload_tasks` turn AND the
  # notification scan it spawns, so the "no browser notification" refutes below
  # can use a ZERO timeout instead of a 100 ms observation window (8 of them
  # cost ~0.8s of pure wall clock and detect nothing new).
  #
  # Chain, each step ordered by signal order rather than by a sleep:
  #   1. `await_async_loads/1` (which starts with a `get_state` drain) processes
  #      the reload message and waits for every task it spawned — the scan
  #      sends `{:task_notifications, ...}` BEFORE it exits, so the message is
  #      queued in the view's mailbox when the monitor fires.
  #   2. `assigns/1` (`:sys.get_state`) is queued after that message, so the
  #      view handles the scan result — pushing any `task_notification` event
  #      into a render diff — before replying.
  #   3. `render(view)` round-trips the client proxy, which relays the diff's
  #      pushed events into THIS process's mailbox before the render reply.
  # A refute with timeout 0 is then conclusive: anything the scan would have
  # pushed is already here. Returns the final rendered HTML so callers do not
  # need an extra `render/1` round-trip.
  def drain_task_reload(view) do
    await_async_loads(view)
    _ = assigns(view)
    render(view)
  end

  # Installs the fake directory picker module (test/support) for the binary
  # attach flow and restores the prior app env on exit — mirrors the inline
  # per-test idiom of the text file_pick tests above.
  def install_fake_picker! do
    original = Application.get_env(:evo_dash, :directory_picker_module)
    Application.put_env(:evo_dash, :directory_picker_module, EvoDash.DirectoryPicker.Fake)

    on_exit(fn ->
      # Restore the prior config so other tests are unaffected.
      if original do
        Application.put_env(:evo_dash, :directory_picker_module, original)
      else
        Application.delete_env(:evo_dash, :directory_picker_module)
      end
    end)

    :ok
  end

  # Opens `tmp_dir` as the active project through the command palette
  # (open-path mode). The task form's launch panel + staged-attachment chip
  # row render ONLY when a project is active (@disabled == false), so the
  # staging tests that launch a task (or exercise the enabled-form flow)
  # open a project first — exactly like the existing task_submit /
  # custom-agent tests.
  #
  # Every caller writes staging files (a .png/.mp3 fixture) into tmp_dir
  # BEFORE activating, so detect_mode/1 resolves genesis_existing and the
  # activation spawns the REAL `git remote get-url origin` GitHub-upstream
  # check under tmp_dir — the spawn: "Could not cd" noise source. Stub the
  # :github_runner seam here (all 5 callers stage files; none stubs its own
  # GitHub seams) so this shared helper stays the single wiring point.
  def open_staging_project(view, tmp_dir) do
    stub_github_upstream_check!()
    clear_projects()

    open_project!(view, tmp_dir)

    assert assigns(view)[:active_project_path] == tmp_dir
    view
  end

  # Runs the native binary attach pick ("file_pick" on the given image/audio
  # picker channel) against `path`, re-setting the fake's file-mode result
  # first (the fake's default "/fake/picked/file.txt" would fail image/audio
  # extension validation).
  def pick_staged(view, picker_id, kind, path) do
    EvoDash.DirectoryPicker.Fake.set_file_result({:ok, path})
    render_hook(view, "file_pick", %{picker_id: picker_id, prompt: "", kind: kind})
    view
  end

  # Awaits the OFF-PROCESS attachment read started by a pick on `picker_id`
  # (see `EvoDashWeb.ProjectsLive.AttachFile`): `file_pick` /
  # `file_pick_manual` only snapshots the base prompt into `:file_pick_bases`
  # and records `:attach_pending` (`picker_id => base`); the file itself is
  # read in a supervised task and applied in `handle_info({{:attachment_loaded,
  # ...}, result})`. Polls the assigns (deadline based, through
  # `wait_assigns/2`) until that pick is no longer pending AND `effect` (the
  # read's expected assign/HTML consequence) holds, then re-renders so a
  # rendered-HTML assertion sees the settled frame.
  def await_attachment(view, picker_id, effect) do
    wait_assigns(view, fn assigns ->
      not Map.has_key?(Map.get(assigns, :attach_pending, %{}), picker_id) and effect.(assigns)
    end)

    render(view)
  end

  def put_github_seams(overrides) do
    defaults = [
      {:github_runner, fn _node, _path -> {:error, :no_github_upstream} end},
      {:github_issues_runner, fn _node, _path, _opts -> {:ok, []} end},
      {:github_issue_markdown_runner,
       fn _node, _path, _number ->
         {:error, :gh_not_available}
       end}
    ]

    seams = Keyword.merge(defaults, overrides)

    for {key, value} <- seams do
      Application.put_env(:evo_dash, key, value)
    end

    on_exit(fn ->
      for {key, _value} <- seams do
        Application.delete_env(:evo_dash, key)
      end
    end)

    :ok
  end

  def ok_upstream_runner do
    fn _node, _path ->
      {:ok,
       %{
         owner: "acme",
         repo: "widgets",
         gh_available: true,
         url: "https://github.com/acme/widgets"
       }}
    end
  end

  # Opens `path` through the project palette (open-path mode) — the same
  # flow as the "opening a project" tests. Activating a project with a
  # non-genesis_new mode spawns the async GitHub-upstream check.
  #
  # Driven as ONE `open_project` event: that is the exact handler the
  # open-path form submits to, and its render already carries the
  # post-`push_patch` (activated) DOM. The two palette-opening clicks only
  # exist to reach the form, and nothing here asserts on them.
  #
  # The activation lands on the PROJECT OVERVIEW, so the helper also steps into
  # the composer (`enter_composer/1`) and keeps returning the view.
  #
  # The same two turns spawn the page's async batch, so the chrome and the
  # batch-seeded assigns (`projects`, `custom_agents`, the picker bundle) settle
  # only a frame later: wait for them here (`await_async_loads/1`) instead of
  # making every caller remember to.
  def open_project(view, path) do
    render_click(view, "open_project", %{"path" => path})
    _ = enter_composer(view)
    await_async_loads(view)

    view
  end

  # Makes `tmp_dir` an evolve_simple project (a CONTEXT.md file) so the
  # GitHub-upstream check is spawned — genesis_new projects never check.
  def make_evolve_project(tmp_dir) do
    File.write!(Path.join(tmp_dir, "CONTEXT.md"), "# Test project\n")
  end

  # Polls the LiveView socket assigns until `predicate/1` is truthy. The
  # GitHub runners run in supervised Tasks and report back via self-messages
  # handled by handle_info, so polling the assigns (with a generous budget)
  # is the deterministic way to wait for an async result.
  def wait_until(view, predicate, timeout_ms \\ @async_wait_budget_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll = fn poll ->
      cond do
        predicate.(assigns(view)) ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("Timed out waiting for async GitHub state — assigns: #{inspect(assigns(view))}")

        true ->
          Process.sleep(2)
          poll.(poll)
      end
    end

    poll.(poll)
  end

  # Bounded wait for a RENDERED flash message, returning the last render.
  #
  # Only the ASYNC `task_submit` launch bumps `:task_launch_seq`, so
  # `await_task_launch/2` would time out on a path that never spawns one: the
  # unconfigured-project guard refuses the submit BEFORE the spawn, and the
  # GitHub-issue fix starts its task inside the `{:github_fix_result, ...}`
  # continuation. Those tests await the effect the server actually produces —
  # the flash it pushes — instead of a launch seq it never sets.
  def wait_for_flash(view, kind, text) do
    selector = "#flash-#{kind}"
    wait_assigns(view, fn _assigns -> has_element?(view, selector, text) end)
    render(view)
  end

  # Use the real provider-profile TOML boundary, not a forged picker bundle.
  # Two models with different effort defaults expose accidental fallback to the
  # provider default in either task-submission path.
  def write_provider_profile_config do
    config_path = EvoGit.Config.config_path()
    File.mkdir_p!(Path.dirname(config_path))

    File.write!(config_path, """
    [llm]
    default_provider_profile = "account-a"

    [[llm.providers]]
    id = "account-a"
    name = "Test account"
    provider = "anthropic"
    api_key_env_var = "EVOGIT_PROJECTS_TEST_API_KEY"
    default_model = "claude-sonnet-5"
    concurrency = 3

    [[llm.providers.models]]
    model = "claude-sonnet-5"
    reasoning_efforts = ["low", "high"]
    default_reasoning_effort = "low"

    [[llm.providers.models]]
    model = "claude-opus-5"
    reasoning_efforts = ["low", "high"]
    default_reasoning_effort = "high"
    """)
  end

  def point_registry_at_test_config! do
    # Sync launch tests own the global TaskRegistry: admission and its spawned
    # executor now resolve config there, outside the LiveView's $callers chain.
    registry = Process.whereis(EvoGit.TaskRegistry)
    config_dir = Process.get(:evogit_config_dir)
    assert is_binary(config_dir)
    {:dictionary, dictionary} = Process.info(registry, :dictionary)
    previous = Keyword.get(dictionary, :evogit_config_dir)

    :sys.replace_state(registry, fn state ->
      Process.put(:evogit_config_dir, config_dir)
      state
    end)

    on_exit(fn ->
      # Teardown-only: a failed test may have already stopped the registry.
      try do
        :sys.replace_state(registry, fn state ->
          if is_nil(previous),
            do: Process.delete(:evogit_config_dir),
            else: Process.put(:evogit_config_dir, previous)

          state
        end)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  def assert_task_model_selection(task, spec) do
    # Store.Codec may atomize known option names, but canonical spec fields
    # must remain string-keyed and contain only the exact user selection.
    assert (opt(task, :model_spec) || opt(task, "model_spec")) == spec
    assert (opt(task, :model_id_locked) || opt(task, "model_id_locked")) == true
    refute has_opt?(task, :model_id)
    refute has_opt?(task, "model_id")
    # The task row may expose a runtime-derived model id; only the submitted
    # opts define the dashboard's canonical selection/lock contract.
  end

  def assert_task_auto_selection(task) do
    for key <- [
          :model_spec,
          "model_spec",
          :model_id_locked,
          "model_id_locked",
          :model_id,
          "model_id"
        ] do
      refute has_opt?(task, key)
    end

    assert task.model_id == nil
  end

  def github_status(view, state) do
    wait_until(view, fn a -> a[:github_status] && a[:github_status].state == state end)
  end
end

defmodule EvoDashWeb.ProjectsLiveTest do
  # `async: true` — nothing in this module mutates a process-wide global that a
  # concurrently running `async: true` module also touches. The tests that DO
  # (the frozen `EvoGit.TaskRegistry` probes, the real task launches whose
  # `{:task_updated, ...}` broadcast arms every mounted page's NodeAware
  # debounce, the run-wide-store `clear_task_history` sweep, the `/help` mount
  # that writes the process-wide `EvoDash.ChatHistory`, and the app-env keys
  # shared with `directory_picker_test` / `project_flow_test`) live in
  # `EvoDashWeb.ProjectsLiveSyncTest` below. The per-test `ActiveTasks` clear is
  # node-scoped (`invalidate(nil, node())`), so it can only touch the LOCAL
  # `{nil, node()}` context — the same async-safe contract `EvoDashWeb.ConnCase`
  # uses.
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import EvoDashWeb.ProjectsLiveTest.Helpers

  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskInfo

  setup [:setup_temp_dir, :set_onboarding_completed, :reset_active_tasks_hub]
  setup_all [:install_git_template]

  describe "dashboard without active project" do
    setup do
      # Clear all projects so auto-load doesn't activate a stale project
      for project <- EvoGit.VCT.projects() do
        EvoGit.VCT.forget(project.point)
      end

      :ok
    end

    test "the empty workbench only shows its no-project message", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/projects")

      # Pass the suite's async deadline explicitly: `render_async/2`'s 100 ms default is a fixed-load assumption, while this page's async work is scheduled by the shared BEAM.
      render_async(view, async_wait_budget())

      assert has_element?(view, "#workbench-idle [data-workbench-idle-projects]", "No projects")
      assert has_element?(view, "#workbench-new-project[data-workbench-attention=true]")
      refute has_element?(view, "#project-omnibox")
      refute has_element?(view, "#task-form")
      refute html =~ "New to Genesis? Start with an example"
    end
  end

  describe "root route (GET /)" do
    setup do
      # Clear all projects so auto-load doesn't activate a stale project
      for project <- EvoGit.VCT.projects() do
        EvoGit.VCT.forget(project.point)
      end

      :ok
    end

    test "a fresh project sidebar has no project rows or server groups", %{conn: conn} do
      for path <- ["/", "/projects"] do
        {:ok, view, html} = live(conn, path)

        assert html =~ "No projects"
        refute html =~ "task-launch-button"
        refute html =~ "chat-form"
        refute html =~ "project-omnibox"

        render_async(view, async_wait_budget())
        assert has_element?(view, "#workbench-new-project[data-workbench-attention=true]")
        refute has_element?(view, "#workbench-projects [data-workbench-project-row]")
        refute has_element?(view, "#workbench-project-search")
        refute has_element?(view, ".workbench-location")
        assert has_element?(view, "#workbench-create [data-workbench-project-window=create]")
      end
    end

    test "a project row carries its location and the create actions are in the top bar", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      seed_project(tmp_dir, "Workbench project")
      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: tmp_dir, wb_home: "1"}}")
      render_async(view, async_wait_budget())
      # The recent-project sidebar can render before Projects confirms the scope.
      wait_for_projects(view, tmp_dir)

      assert has_element?(
               view,
               "#workbench-projects [data-workbench-project-name='Workbench project']"
             )

      assert has_element?(view, "#workbench-projects .workbench-project-server", "Local")
      refute has_element?(view, "#workbench-projects [data-workbench-new-task]")
      refute has_element?(view, "#workbench-projects [data-workbench-new-conversation]")
      assert has_element?(view, "#workbench-create [data-workbench-new-task]", "New task")

      assert has_element?(
               view,
               "#workbench-create [data-workbench-new-conversation]",
               "New conversation"
             )

      # The right panel is CLOSED in the server-rendered markup: the open/close
      # animation is JS+CSS only, so the initial DOM is the closed state and its
      # filters are real server-rendered controls (no collapsed search toggle).
      assert has_element?(view, "#workbench-history-toggle[aria-expanded=false]")
      assert has_element?(view, "#workbench-history[hidden][data-panel-state=closed]")
      assert has_element?(view, "#workbench-history-search[name=query]")
      refute has_element?(view, "#workbench-history-search[hidden]")
      refute has_element?(view, "#workbench-history-query[hidden]")

      # The selected option shows the current scope without a duplicate header label.
      assert has_element?(
               view,
               "#workbench-history-project-filter option[selected][value='#{tmp_dir}']"
             )

      refute has_element?(view, "#workbench-history-project")

      # The filter block is ONE labelled control row: each select sits in its
      # own `.workbench-history-field` on the dashboard control grammar.
      assert has_element?(
               view,
               "#workbench-history-filters .workbench-history-filters .workbench-history-field"
             )

      assert has_element?(view, "label[for=workbench-history-status-filter]", "Status")

      assert has_element?(
               view,
               "#workbench-idle [data-workbench-idle-window]:not([hidden])",
               "No window selected"
             )

      # The panel's first read is asynchronous — the empty flag only exists once
      # a completed load returned no rows, so await it instead of racing it.
      render_async(view, async_wait_budget())

      assert has_element?(view, "#workbench-history-content[data-workbench-history-empty=true]")
      refute has_element?(view, "#task-form")
      refute has_element?(view, "#app-layout[data-workbench-default-draft]")

      {:ok, composer, _} =
        view
        |> element("#workbench-create [data-workbench-new-task]")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(composer, "#task-form")
      refute has_element?(composer, "#workbench-idle")
    end
  end

  describe "opening a project" do
    # Keep the VCT-dependent overview check in the module that clears the project roster.
    test "Chat with Assistant links to /assistant with the project path and a draft id",
         %{conn: conn, tmp_dir: tmp_dir} do
      path = make_git_repo!(Path.join(tmp_dir, "overview assistant"))
      %{point: point} = seed_project(path, "Overview Assistant")
      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: path}}")
      wait_for_projects(view, path)

      overview = "#workbench-project-overview[data-overview-kind=project]"
      assert has_element?(view, "#{overview} [data-overview-point]", point)

      link =
        view
        |> element("#{overview} a#overview-chat-assistant", "Chat with Assistant")
        |> render()
        |> Floki.parse_fragment!()

      assert [href] = Floki.attribute(link, "a", "href")
      assert %URI{path: "/assistant", query: query} = URI.parse(href)
      assert %{"wb_draft" => draft} = params = URI.decode_query(query)
      assert params == %{"wb_project" => path, "wb_draft" => draft}
      assert draft =~ ~r/\A[0-9a-f]{24}\z/
    end

    test "can open project via palette and form submission", %{conn: conn, tmp_dir: tmp_dir} do
      # An explicit starting project prevents VCT auto-activation from resetting the palette.
      initial_path = Path.join(tmp_dir, "initial")
      File.mkdir!(initial_path)
      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: initial_path, wb_open: "1"}}")

      view |> element("#project-omnibox button[phx-value-mode=open_path]") |> render_click()

      view
      |> form("#palette-body-open_path form[phx-submit=open_project]", path: tmp_dir)
      |> render_submit()

      assert_patch(view, ~p"/projects?#{%{project: tmp_dir}}")

      enter_composer(view)

      assert has_element?(view, "#task-form #task-launch-button")
      assert has_element?(view, "#workbench-task-settings h3", "Foreign Repositories")
      refute has_element?(view, "#example-task-objective")
    end

    test "detects genesis_new mode for empty directory", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: tmp_dir})

      # Should detect mode and show flash message
      assert html =~ "genesis" or html =~ "Genesis"
    end

    test "shows project info in selector after opening", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: tmp_dir})

      # Should show the project basename
      assert html =~ Path.basename(tmp_dir)
    end

    # Settings are in the composer. Target the test's own project explicitly:
    # a bare mount may auto-activate another async test's VCT project and close
    # the palette. The rendered open-path form is exercised separately above.
    test "project settings panel shows config status", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: tmp_dir, wb_task: "1"}}")

      assert has_element?(
               view,
               "details#workbench-task-settings p",
               "No genesis.toml — using global defaults"
             )
    end

    test "project settings shows no foreign repos by default", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: tmp_dir, wb_task: "1"}}")

      assert assigns(view).active_project_path == tmp_dir

      assert has_element?(
               view,
               "details#workbench-task-settings p",
               "No foreign repositories registered"
             )
    end

    test "local project opening stays synchronous (no async loading flag)", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      view
      |> element("form[phx-submit='open_project']")
      |> render_submit(%{path: tmp_dir})

      # The local flow is unchanged: the assigns apply synchronously (via the
      # push_patch -> handle_params turn) and no remote loading flag is ever
      # set (AsyncLoad only touches node-aware loads, not local activation).
      assert assigns(view)[:remote_project_loading] == nil
      assert assigns(view)[:active_project] != nil
      assert assigns(view)[:active_project_path] == tmp_dir
    end
  end

  describe "opening project via URL params" do
    test "activates project from URL query param", %{conn: conn, tmp_dir: tmp_dir} do
      # `wb_task=1` is the explicit compose request, so this mount targets the
      # task composer (selecting a project alone lands on the overview).
      {:ok, view, html} = live(conn, ~p"/projects?#{%{project: tmp_dir, wb_task: "1"}}")

      assert html =~ Path.basename(tmp_dir)
      assert has_element?(view, "#task-form #task-launch-button")
      assert has_element?(view, "details#workbench-task-settings > summary", "Project Settings")
    end
  end

  # The task-form draft identity is `{node, EvoDashWeb.DraftScope.token(...)}`:
  # the project's VCT point when mounted, the raw OS path otherwise. The
  # `StatePersistence` JS hook reads it from `data-task-draft-scope`;
  # `data-task-draft-project` stays the LEGACY path identity it adopts an
  # old path-keyed draft from.
  describe "task form draft scope" do
    test "renders the VCT point as the draft scope for a mounted project", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      project = Path.join(tmp_dir, "draft-scope-point-#{System.unique_integer([:positive])}")
      File.mkdir_p!(project)
      mount = seed_project(project, Path.basename(project))
      {:ok, view, _html} = live(conn, ~p"/projects?project=#{URI.encode(project)}")
      wait_assigns(view, &(&1[:active_project_path] == project))
      # The point lookup is pure over the ASYNC-loaded mount list, so wait for
      # that batch instead of assuming the first frame already carries it.
      wait_for_projects(view, [project])
      assert is_binary(mount.point)
      assert String.starts_with?(mount.point, "vct:///projects/")
      html = render(view)
      assert html =~ ~s(data-task-draft-scope="#{mount.point}")
      # The legacy path identity is untouched (the hook still adopts the
      # path-keyed entry through it).
      assert html =~ ~s(data-task-draft-project="#{project}")
    end

    test "falls back to the raw OS path when the project has no mount", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      project = Path.join(tmp_dir, "draft-scope-bare-#{System.unique_integer([:positive])}")
      File.mkdir_p!(project)
      {:ok, view, _html} = live(conn, ~p"/projects?project=#{URI.encode(project)}")
      wait_assigns(view, &(&1[:active_project_path] == project))
      await_async_loads(view)
      html = render(view)
      assert html =~ ~s(data-task-draft-scope="#{project}")
      assert html =~ ~s(data-task-draft-project="#{project}")
    end

    # The render attribute and the persisted payload come from ONE computation,
    # so the browser can never store a draft under a scope the DOM disagrees
    # with. Only a VCT POINT is stamped server-side (a raw-path scope is the
    # payload's own `project` identity, which the hook stamps on its writes).
    test "persist_state carries the point as its scope token", %{conn: conn, tmp_dir: tmp_dir} do
      project = Path.join(tmp_dir, "draft-persist-#{System.unique_integer([:positive])}")
      File.mkdir_p!(project)
      point = seed_project(project, Path.basename(project)).point
      {:ok, view, _html} = live(conn, ~p"/projects?project=#{URI.encode(project)}")
      wait_assigns(view, &(&1[:active_project_path] == project))
      wait_for_projects(view, [project])

      render_click(view, "select_quality_level", %{"level" => "fast"})

      assert_push_event(view, "persist_state", %{
        project: ^project,
        scope_token: ^point,
        node: "local"
      })
    end

    # Point-wins separation, asserted at the helper boundary: the core keeps ONE
    # mount row per OS path (`EvoGit.VCT.mount/2` re-points instead of adding a
    # second row), so two points over one path cannot be seeded in the registry.
    test "different points scope the same OS path separately" do
      project =
        Path.join(System.tmp_dir!(), "draft-scope-pure-#{System.unique_integer([:positive])}")

      assigns = %{workbench_reconnect_params: %{"project" => project}, projects: []}

      one =
        EvoDashWeb.ProjectsLive.StatePersistence.draft_scope(%{
          assigns
          | projects: [%{path: project, point: "vct:///projects/one"}]
        })

      two =
        EvoDashWeb.ProjectsLive.StatePersistence.draft_scope(%{
          assigns
          | projects: [%{path: project, point: "vct:///projects/two"}]
        })

      assert one == "vct:///projects/one"
      assert two == "vct:///projects/two"
      assert one != two
      # Unmounted, the same path is its own token — never a point.
      assert EvoDashWeb.ProjectsLive.StatePersistence.draft_scope(assigns) == project
      # The active project's own point wins over the mount list …
      assert EvoDashWeb.ProjectsLive.StatePersistence.draft_scope(
               Map.put(assigns, :active_project, %{
                 path: project,
                 point: "vct:///projects/active"
               })
               |> Map.put(:projects, [%{path: project, point: "vct:///projects/stale"}])
             ) == "vct:///projects/active"

      # … and a page with no project at all has no scope at all.
      assert is_nil(
               EvoDashWeb.ProjectsLive.StatePersistence.draft_scope(%{
                 workbench_reconnect_params: %{},
                 projects: []
               })
             )
    end

    # A draft persisted under the OLD raw-path key is pushed back with `project`
    # and no `scope_token`; the restore handler must keep accepting it, and must
    # not choke on a scoped payload either.
    test "restore_state accepts a path-keyed payload without a scope token", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      project = Path.join(tmp_dir, "draft-restore-#{System.unique_integer([:positive])}")
      File.mkdir_p!(project)
      mount = seed_project(project, Path.basename(project))
      {:ok, view, _html} = live(conn, ~p"/projects?project=#{URI.encode(project)}")
      wait_assigns(view, &(&1[:active_project_path] == project))

      render_hook(view, "restore_state", %{
        "project" => project,
        "task_prompt" => "legacy path-keyed draft"
      })

      assert assigns(view)[:task_prompt] == "legacy path-keyed draft"

      # A scope-stamped payload of the same project restores identically — the
      # handler gates on node + project, never on the token.
      render_hook(view, "restore_state", %{
        "project" => project,
        "scope_token" => mount.point,
        "task_prompt" => "scoped draft"
      })

      assert assigns(view)[:task_prompt] == "scoped draft"
    end
  end

  describe "opening invalid directory" do
    setup do
      for project <- EvoGit.VCT.projects() do
        EvoGit.VCT.forget(project.point)
      end

      :ok
    end

    test "shows error for non-existent directory", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: "/nonexistent/directory/path"})

      assert html =~ "Directory does not exist"
    end
  end

  describe "removed /settings/project route" do
    test "/settings/project returns 404", %{conn: conn} do
      conn = get(conn, "/settings/project")
      assert conn.status == 404
    end
  end

  describe "settings page has no project settings link" do
    test "settings page has no Project Settings link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      refute html =~ "Project Settings"
      refute html =~ "Foreign Repos"
    end
  end

  describe "restore_state restores foreign repositories from saved session" do
    setup do
      for project <- EvoGit.VCT.projects() do
        EvoGit.VCT.forget(project.point)
      end

      :ok
    end

    test "foreign repos round-trip via restore_state event", %{conn: conn, tmp_dir: tmp_dir} do
      # `wb_task=1`: the project-settings panel asserted below lives in the
      # task composer, so this mount asks for the composer explicitly.
      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: tmp_dir, wb_task: "1"}}")

      # Simulate session restore with foreign repos (as they'd arrive from sessionStorage JSON).
      # The project must be a real directory so activate_project runs.
      render_hook(view, "restore_state", %{
        "project" => tmp_dir,
        "foreign_repos" => [
          %{
            "id" => "original",
            "path" => "/Source/original-proj",
            "description" => "The original"
          },
          %{"id" => "reference", "path" => "/Source/ref", "description" => nil}
        ]
      })

      # Native <details> already renders its content. No LiveView toggle event
      # is involved in opening the disclosure in the browser.
      for {id, path} <- [{"original", "/Source/original-proj"}, {"reference", "/Source/ref"}] do
        assert has_element?(view, "#workbench-task-settings span.badge", id)
        assert has_element?(view, "#workbench-task-settings span[title='#{path}']", path)
      end
    end

    test "restore_state with empty foreign repos does not error", %{conn: conn, tmp_dir: tmp_dir} do
      # `wb_task=1`: the project-settings panel asserted below lives in the
      # task composer, so this mount asks for the composer explicitly.
      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: tmp_dir, wb_task: "1"}}")

      render_hook(view, "restore_state", %{
        "project" => tmp_dir,
        "foreign_repos" => []
      })

      assert has_element?(
               view,
               "details#workbench-task-settings p",
               "No foreign repositories registered"
             )
    end
  end

  describe "prompt textarea with phx-update=ignore" do
    # One mount, both event paths: the three sibling tests this replaces each
    # re-mounted the page just to re-pin `phx-update="ignore"` (the attribute
    # itself is pinned component-side in
    # task_form_components_test.exs: "textarea keeps AdaptiveInput +
    # phx-update=ignore with no per-keystroke server event"). The unique
    # behaviour here is that the SERVER-side handlers leave @task_prompt alone
    # when the textarea is client-owned — asserted directly on the assign.
    test "the textarea is client-owned across select_model and task_change", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      write_provider_profile_config()
      {:ok, view, _html} = live(conn, ~p"/projects")
      await_async_loads(view)

      # Open a project so the task form renders
      open_project!(view, tmp_dir)
      await_async_loads(view)

      # Seed the prompt the way the client does, then assert the textarea is
      # client-owned: phx-update="ignore" means LiveView re-renders (on model /
      # mode switches) never clobber it.
      render_change(view, "restore_state", %{"task_prompt" => "my objective"})
      assert assigns(view)[:task_prompt] == "my objective"
      assert render(view) =~ ~s(phx-update="ignore")

      # A successful canonical picker transition must not touch the prompt.
      html = render_change(view, "select_model", %{"model" => "claude-opus-5"})
      assert assigns(view)[:selected_model_spec]["model"] == "claude-opus-5"
      assert html =~ ~s(phx-update="ignore")
      assert assigns(view)[:task_prompt] == "my objective"

      # ...and neither must task_change
      html = render_change(view, "task_change", %{"mode" => "evolve_simple"})
      assert html =~ ~s(phx-update="ignore")
      assert assigns(view)[:task_prompt] == "my objective"
    end
  end

  describe "task configuration" do
    setup do
      clear_projects()
    end

    test "the composer exposes one set of inline options without a project path selector", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, html} = live(conn, ~p"/projects?#{%{project: tmp_dir, wb_task: "1"}}")

      options =
        "#workbench-task-composer section#task-options[aria-labelledby=task-options-title]"

      settings = "details#workbench-task-settings"
      doc = Floki.parse_document!(html)

      assert [_] = Floki.find(doc, "#task-form")
      assert [_] = Floki.find(doc, "#task-options")
      assert [_] = Floki.find(doc, "#persist-agent-state-toggle")
      assert [_] = Floki.find(doc, "select[name=build_system]")
      refute has_element?(view, ".project-palette-trigger")

      assert has_element?(view, "#{options} h2#task-options-title", "Task Options")

      assert has_element?(view, "#{options} select[name=build_system][form=task-form]")

      assert has_element?(
               view,
               "#{settings}:not([open]) > summary#workbench-task-settings-title",
               "Project Settings"
             )

      refute has_element?(view, "#{settings} [form=task-form]")
      refute has_element?(view, "#task-form [aria-controls=workbench-task-settings]")
      refute has_element?(view, "dialog#workbench-task-settings")
      refute has_element?(view, "#task-form dialog")
    end
  end

  test "an unknown explicit remote target cannot activate a local path", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    target = "no-longer-configured"
    params = %{node: target, project: tmp_dir}
    {:ok, view, _html} = live(conn, ~p"/projects?#{params}")
    await_async_loads(view)

    assert assigns(view)[:current_node_id] == target
    assert assigns(view)[:active_project_path] == nil
    refute has_element?(view, "#workbench-task-composer")
    refute has_element?(view, "#workbench-git-toggle")
    refute Enum.any?(EvoGit.VCT.projects(), &(&1.path == tmp_dir))
  end

  describe "project palette" do
    setup do
      clear_projects()
    end

    test "open_project_palette opens and close_project_palette closes it", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/projects")

      # Closed: the search input and backdrop are not rendered
      assert html =~ "No projects"
      refute html =~ ~s(id="palette-search-input")

      html = render_click(view, "open_project_palette", %{})
      assert html =~ ~s(id="palette-search-input")
      assert html =~ ~s(phx-click="close_project_palette")

      html = render_click(view, "close_project_palette", %{})
      refute html =~ ~s(id="palette-search-input")
      assert html =~ "No projects"
    end

    test "palette_mode switches to open_path mode showing the path input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})

      html = render_click(view, "palette_mode", %{"mode" => "open_path"})
      assert html =~ ~s(id="project-path-input")
      assert html =~ ~s(<datalist id="path-suggestions">)
    end

    test "entering open_path mode seeds the datalist with project paths", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      project_a = Path.join(tmp_dir, "project-alpha")
      project_b = Path.join(tmp_dir, "project-beta")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)
      seed_project(project_a, "project-alpha")
      seed_project(project_b, "project-beta")

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_a, project_b])

      render_click(view, "open_project_palette", %{})
      html = render_click(view, "palette_mode", %{"mode" => "open_path"})

      datalist = path_suggestions_datalist(html)
      assert datalist =~ ~s(<option value="#{project_a}"></option>)
      assert datalist =~ ~s(<option value="#{project_b}"></option>)
    end

    test "open_path mode keeps UNC/WSL project paths in the datalist", %{conn: conn} do
      # UNC/WSL paths are absolute and must survive the projects absolute-path
      # filter (never dropped as relative). They do NOT exist on the test host
      # — seed them via the public TaskRegistry API and assert the filtered
      # palette datalist renders them (the same surface the POSIX/Windows
      # projects use; the mount's auto-load silently skips non-existent paths).
      wsl_path = "//wsl.localhost/Ubuntu-22.04/home/user/proj"
      unc_path = "\\\\server\\share\\proj"
      seed_project(wsl_path, "wsl-proj")
      seed_project(unc_path, "unc-proj")

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [wsl_path, unc_path])

      render_click(view, "open_project_palette", %{})
      html = render_click(view, "palette_mode", %{"mode" => "open_path"})

      datalist = path_suggestions_datalist(html)
      assert datalist =~ ~s(<option value="#{wsl_path}"></option>)
      assert datalist =~ ~s(<option value="#{unc_path}"></option>)
    end

    test "palette_menu shows VCT projects as clickable items", %{conn: conn, tmp_dir: tmp_dir} do
      project_a = Path.join(tmp_dir, "my-alpha")
      File.mkdir_p!(project_a)
      seed_project(project_a, "my-alpha")

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_a])

      html = render_click(view, "open_project_palette", %{})
      assert html =~ "my-alpha"
      assert html =~ ~s(phx-click="select_project")
      assert html =~ ~s(phx-value-path="#{project_a}")
    end

    # A project's DISPLAY identity is the mount's friendly `name` (the basename
    # it was registered with), with the OS path as the secondary line; the VCT
    # `point` stays the registry/search/forget identity. Row EVENTS stay
    # OS-path-keyed. Unique basenames keep the VCT's `-N` dedup suffix out of
    # the picture, and the expected point is derived from the registry (never
    # hardcoded).
    test "palette_menu shows the project name as the identity with the OS path secondary", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      project_a = Path.join(tmp_dir, "vct-identity-#{System.unique_integer([:positive])}")
      File.mkdir_p!(project_a)
      mount = seed_project(project_a, Path.basename(project_a))

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_a])

      assert is_binary(mount.point)
      assert String.starts_with?(mount.point, "vct:///projects/")

      # The point is DERIVED from the registry, never hardcoded.
      entry = Enum.find(EvoGit.VCT.projects(), &(&1.path == project_a))
      assert entry.point == mount.point
      assert entry.name == Path.basename(project_a)

      html = render_click(view, "open_project_palette", %{})

      # SCOPED to this project's own row: the page also renders other suites'
      # mounts, so a page-wide index comparison would compare unrelated rows.
      row = palette_row(html, project_a)

      # The row's PRIMARY identity line is the mount display name and the
      # SECONDARY line is the OS path: the name is the content of the row
      # button's first line div, immediately followed by the path line (whose
      # `title` attribute is the OS path and whose text is the OS path).
      assert row =~
               ~r{>\s*#{Regex.escape(entry.name)}\s*</div>\s*<div[^>]*title="#{Regex.escape(project_a)}"[^>]*>\s*#{Regex.escape(project_a)}\s*</div>}

      # The VCT point is never rendered as ELEMENT TEXT (its only appearance is
      # the Forget sibling's `phx-value-point` below).
      refute row =~ ~r{>\s*#{Regex.escape(entry.point)}\s*</div>}

      # Row EVENTS stay OS-path-keyed while the Forget sibling carries the VCT
      # point — the point is the registry/forget identity, the path the handle.
      assert row =~ ~s(phx-value-path="#{project_a}")
      assert row =~ ~s(phx-click="forget_project")
      assert row =~ ~s(phx-value-point="#{entry.point}")
    end

    # Newest-opened first: `EvoGit.VCT.projects/1` sorts by `last_opened_at`
    # DESC, so the row seeded LAST must render ABOVE the earlier one. Other
    # suites may have mounted their own projects concurrently, so the
    # assertion compares the RELATIVE positions of this test's own two rows.
    test "palette_menu lists the newest VCT project first", %{conn: conn, tmp_dir: tmp_dir} do
      unique = System.unique_integer([:positive])
      project_a = Path.join(tmp_dir, "order-alpha-#{unique}")
      project_b = Path.join(tmp_dir, "order-bravo-#{unique}")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)

      seed_project(project_a, Path.basename(project_a))
      # Seed b LAST so it is the newest-opened mount.
      seed_project(project_b, Path.basename(project_b))

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_a, project_b])

      html = render_click(view, "open_project_palette", %{})

      index_a = string_index(html, ~s(phx-value-path="#{project_a}"))
      index_b = string_index(html, ~s(phx-value-path="#{project_b}"))
      assert is_integer(index_a)
      assert is_integer(index_b)
      assert index_b < index_a
    end

    test "palette_search matches the VCT point", %{conn: conn, tmp_dir: tmp_dir} do
      unique = System.unique_integer([:positive])
      # Neither basename can be a substring of the other, so the query below
      # matches exactly one row.
      project_a = Path.join(tmp_dir, "vct-search-alpha-#{unique}")
      project_b = Path.join(tmp_dir, "vct-search-bravo-#{unique}")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)
      mount_a = seed_project(project_a, Path.basename(project_a))
      seed_project(project_b, Path.basename(project_b))

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_a, project_b])

      assert is_binary(mount_a.point)

      render_click(view, "open_project_palette", %{})

      html =
        render_change(view, "palette_search", %{
          "palette_search" => mount_a.point,
          "_target" => ["palette_search"]
        })

      assert html =~ ~s(phx-value-path="#{project_a}")
      refute html =~ ~s(phx-value-path="#{project_b}")

      # Exactly ONE project row is rendered (the filter did not fall back to
      # the full list); each row button carries exactly one select event.
      assert length(String.split(html, ~s(phx-click="select_project"))) == 2
    end

    test "palette_search matches the project name", %{conn: conn, tmp_dir: tmp_dir} do
      unique = System.unique_integer([:positive])
      project_a = Path.join(tmp_dir, "name-alpha-#{unique}")
      project_b = Path.join(tmp_dir, "name-bravo-#{unique}")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)
      seed_project(project_a, Path.basename(project_a))
      seed_project(project_b, Path.basename(project_b))

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_a, project_b])

      render_click(view, "open_project_palette", %{})

      html =
        render_change(view, "palette_search", %{
          "palette_search" => Path.basename(project_a),
          "_target" => ["palette_search"]
        })

      assert html =~ ~s(phx-value-path="#{project_a}")
      refute html =~ ~s(phx-value-path="#{project_b}")
      assert length(String.split(html, ~s(phx-click="select_project"))) == 2
    end

    test "palette_search matches the OS path", %{conn: conn, tmp_dir: tmp_dir} do
      unique = System.unique_integer([:positive])
      project_a = Path.join(tmp_dir, "ospath-alpha-#{unique}")
      project_b = Path.join(tmp_dir, "ospath-bravo-#{unique}")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)
      seed_project(project_a, Path.basename(project_a))
      seed_project(project_b, Path.basename(project_b))

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_a, project_b])

      render_click(view, "open_project_palette", %{})

      html =
        render_change(view, "palette_search", %{
          "palette_search" => "ospath-alpha-#{unique}",
          "_target" => ["palette_search"]
        })

      assert html =~ ~s(phx-value-path="#{project_a}")
      refute html =~ ~s(phx-value-path="#{project_b}")
      assert length(String.split(html, ~s(phx-click="select_project"))) == 2
    end

    test "selecting a project shows its name and OS path in the top bar", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      project_a = Path.join(tmp_dir, "vct-topbar-#{System.unique_integer([:positive])}")
      File.mkdir_p!(project_a)
      mount = seed_project(project_a, Path.basename(project_a))

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_a])

      assert is_binary(mount.point)

      render_click(view, "open_project_palette", %{})
      _ = render_click(view, "select_project", %{"path" => project_a})

      # The data identity is unchanged (the VCT point still keys the registry).
      assert assigns(view)[:active_project_path] == project_a
      assert assigns(view)[:active_project].point == mount.point

      # Step into the composer: the top-bar/omnibox identity assertions below
      # describe the COMPOSER chrome (the overview deliberately names the VCT
      # point among the selection's own facts).
      html = enter_composer(view)

      # The palette is closed, so the project identity shown in the omnibox
      # trigger is the mount's display name (bold label) beside the OS path
      # (mono secondary span) — the VCT point is not rendered as the identity.
      refute html =~ ~s(id="palette-search-input")
      assert html =~ Path.basename(project_a)
      assert html =~ project_a
      # The point appears ONLY as the draft-scope data attribute (its one
      # legitimate rendering), never as element text.
      refute html =~ ~r{>\s*#{Regex.escape(mount.point)}\s*<}
      assert html =~ ~s(data-task-draft-scope="#{mount.point}")
    end

    test "palette_menu renders a per-entry forget button wired to the VCT point", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      project_a = Path.join(tmp_dir, "my-alpha-#{System.unique_integer([:positive])}")
      File.mkdir_p!(project_a)
      mount = seed_project(project_a, Path.basename(project_a))

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_a])

      html = render_click(view, "open_project_palette", %{})

      # The forget button is a SIBLING of the row button (never nested) and
      # stops propagation, so clicking it can never trigger select_project.
      # It carries the VCT POINT, not the OS path.
      assert html =~ ~s(phx-click="forget_project")
      assert html =~ ~s(phx-value-point="#{mount.point}")
      assert html =~ ~s(phx-stop-propagation)
      assert html =~ "hero-trash"
      assert html =~ "Forget project"
      assert html =~ ~s(aria-label="Forget #{Path.basename(project_a)}")
    end

    test "forget_project drops the entry without activating the project", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      unique = System.unique_integer([:positive])
      project_a = Path.join(tmp_dir, "my-alpha-#{unique}")
      project_b = Path.join(tmp_dir, "my-beta-#{unique}")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)
      mount_a = seed_project(project_a, Path.basename(project_a))
      # Seed b LAST so the mount auto-load activates project_b, not project_a
      seed_project(project_b, Path.basename(project_b))

      {:ok, view, _html} = live(conn, ~p"/projects")
      # The project list AND the most-recent-project auto-activation both arrive
      # in the connected mount's async batch (ProjectsLive.AsyncLoad), so wait
      # for that continuation before asserting which project is active.
      wait_assigns(view, fn assigns ->
        assigns[:active_project_path] == project_b and
          Enum.any?(assigns[:projects] || [], &(&1.path == project_a))
      end)

      render_click(view, "open_project_palette", %{})

      html = render_click(view, "forget_project", %{"point" => mount_a.point})

      # Removed from the palette UI OPTIMISTICALLY (this render)
      refute html =~ ~s(phx-value-path="#{project_a}")
      refute html =~ mount_a.point
      # The row's open-project action did NOT fire — project_b is still active
      assert assigns(view)[:active_project_path] == project_b
      # The palette stays open so more entries can be managed
      assert assigns(view)[:project_palette_open] == true
      assert assigns(view)[:palette_selected_index] == 0

      # ... and gone from the registry once the supervised forget +
      # authoritative reload settles.
      await_async_loads(view)
      refute Enum.any?(EvoGit.VCT.projects(), &(&1.path == project_a))

      wait_until(view, fn _ ->
        not has_element?(view, ~s(#workbench-projects [data-workbench-project="#{project_a}"]))
      end)
    end

    # Covers the SEED-FREE half of `palette_keydown` clamping: the index bound
    # is derived from the view's OWN loaded list (`n` rows + 3 action rows), so
    # concurrent mounts elsewhere in the BEAM cannot skew it.
    test "forget_project resets the selection index for keyboard nav", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      unique = System.unique_integer([:positive])
      project_a = Path.join(tmp_dir, "my-alpha-#{unique}")
      project_b = Path.join(tmp_dir, "my-beta-#{unique}")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)
      mount_a = seed_project(project_a, Path.basename(project_a))
      seed_project(project_b, Path.basename(project_b))

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_a, project_b])

      render_click(view, "open_project_palette", %{})
      assert assigns(view)[:palette_selected_index] == 0

      # ArrowDown/ArrowUp move the index by one and clamp at the action rows
      # (n projects + 3 actions, so the last index is n + 2).
      render_click(view, "palette_keydown", %{"key" => "ArrowDown"})
      assert assigns(view)[:palette_selected_index] == 1
      render_click(view, "palette_keydown", %{"key" => "ArrowUp"})
      assert assigns(view)[:palette_selected_index] == 0

      n = length(assigns(view)[:projects])
      for _ <- 1..(n + 5), do: render_click(view, "palette_keydown", %{"key" => "ArrowDown"})
      assert assigns(view)[:palette_selected_index] == n + 2
      render_click(view, "palette_keydown", %{"key" => "ArrowUp"})
      assert assigns(view)[:palette_selected_index] == n + 1

      html = render_click(view, "forget_project", %{"point" => mount_a.point})

      assert assigns(view)[:palette_selected_index] == 0
      refute html =~ ~s(phx-value-path="#{project_a}")
      refute html =~ mount_a.point
    end

    test "palette_menu shows Create New Project and Open by Path actions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      html = render_click(view, "open_project_palette", %{})
      assert html =~ "Open Project by Path"
      assert html =~ "Create New Project"
    end

    test "palette_mode switches to new_project mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})

      html = render_click(view, "palette_mode", %{"mode" => "new_project"})
      assert html =~ ~s(id="new-project-path-input")
    end

    test "palette_search filters projects by name", %{conn: conn, tmp_dir: tmp_dir} do
      project_a = Path.join(tmp_dir, "my-alpha")
      project_b = Path.join(tmp_dir, "my-beta")
      File.mkdir_p!(project_a)
      File.mkdir_p!(project_b)
      seed_project(project_a, "my-alpha")
      seed_project(project_b, "my-beta")

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_a, project_b])

      render_click(view, "open_project_palette", %{})

      html =
        render_change(view, "palette_search", %{
          "palette_search" => "alpha",
          "_target" => ["palette_search"]
        })

      # Filtered: alpha shows as a clickable select_project item
      assert html =~ "my-alpha"
      # beta's path should NOT appear as a select_project target in the palette
      refute html =~ ~s(phx-value-path="#{project_b}")
    end

    test "palette_keydown Escape closes the palette", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")
      render_click(view, "open_project_palette", %{})

      html = render_click(view, "palette_keydown", %{"key" => "Escape"})
      refute html =~ ~s(id="palette-search-input")
    end

    test "palette_keydown Enter activates selected project", %{conn: conn, tmp_dir: tmp_dir} do
      project = Path.join(tmp_dir, "enter-project")
      File.mkdir_p!(project)
      seed_project(project, "enter-project")

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project])
      render_click(view, "open_project_palette", %{})

      # Enter on index 0 (the only project) selects it
      html = render_click(view, "palette_keydown", %{"key" => "Enter"})
      assert html =~ "enter-project"
    end
  end

  describe "path input suggestions" do
    setup do
      clear_projects()
    end

    test "path_input lists matching projects before filesystem suggestions", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      project_path = Path.join(tmp_dir, "alpha")
      fs_only_path = Path.join(tmp_dir, "alpha-extra")
      File.mkdir_p!(project_path)
      File.mkdir_p!(fs_only_path)
      seed_project(project_path, "alpha")

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_path])
      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      html = render_change(view, "path_input", %{"path" => project_path})

      datalist = path_suggestions_datalist(html)

      # (a) the project path (which is also a real directory) is
      # suggested, and so is the filesystem-only sibling
      assert datalist =~ ~s(<option value="#{project_path}"></option>)
      assert datalist =~ ~s(<option value="#{fs_only_path}"></option>)

      # (c) exact ordering from the rendered HTML: the project match comes first
      project_idx = string_index(datalist, ~s(value="#{project_path}"))
      fs_idx = string_index(datalist, ~s(value="#{fs_only_path}"))
      assert project_idx != nil and fs_idx != nil
      assert project_idx < fs_idx
    end

    test "path_input deduplicates paths present in both projects and filesystem", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      project_path = Path.join(tmp_dir, "alpha")
      File.mkdir_p!(project_path)
      seed_project(project_path, "alpha")

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [project_path])
      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      html = render_change(view, "path_input", %{"path" => project_path})

      datalist = path_suggestions_datalist(html)

      # (b) the path exists in projects AND on disk (a filesystem suggestion),
      # but the datalist renders it exactly once
      assert datalist =~ ~s(<option value="#{project_path}"></option>)
      assert length(String.split(datalist, ~s(value="#{project_path}"))) == 2
    end

    # The page's initial project seed is ASYNC ("one frame later"), and its
    # deferred AUTO-ACTIVATION must never take the surface away from a palette
    # the user has already opened: activating the newest project CLOSES the
    # palette and resets its mode, which drops the open-path form and its
    # `path-suggestions` datalist from the render. That is exactly how the
    # dedup assertion above used to flake (a VCT broadcast reload satisfies
    # `wait_for_projects` while the mount batch is still in flight, and the
    # late batch then closed the palette).
    #
    # The ordering is FORCED, not timed: the batch body is held by the
    # `:projects_async_load_runner` seam until this test releases it AFTER
    # opening the palette, and the same `{:vct_updated, node}` broadcast a
    # concurrently running test would make populates `:projects` meanwhile.
    test "a seed landing after the palette opens keeps the open-path datalist", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      project_path = Path.join(tmp_dir, "alpha")
      File.mkdir_p!(project_path)
      seed_project(project_path, "alpha")
      test_pid = self()

      install_projects_async_load_runner(fn ->
        send(test_pid, {:batch_started, self()})

        receive do
          :release ->
            EvoDashWeb.ProjectsLive.AsyncLoad.default_batch(node(), false, nil, nil, true, true)
        after
          5_000 ->
            EvoDashWeb.ProjectsLive.AsyncLoad.default_batch(node(), false, nil, nil, true, true)
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/projects")
      assert_receive {:batch_started, batch_pid}, async_wait_budget()

      # Another test's VCT mutation (the broadcast is shared, every page reacts
      # to it) makes THIS page reload the registry, so `:projects` is already
      # populated while the mount batch is still in flight.
      Phoenix.PubSub.broadcast(EvoGit.PubSub, "vct", {:vct_updated, node()})
      wait_for_projects(view, [project_path])

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      # ORDERING PROOF: the batch is still held, so nothing can have activated a
      # project yet (a leaked batch fails HERE instead of passing silently).
      assert is_nil(assigns(view)[:active_project])

      # The held batch now lands — the deferred auto-activation's chance to
      # steal the palette. `notified_task_ids_ready?` flips when the result is
      # APPLIED (the batch carries the terminal-id seed), so the assertions
      # below run after the continuation, not before it.
      send(batch_pid, :release)
      wait_assigns(view, fn assigns -> assigns[:notified_task_ids_ready?] == true end)

      assert assigns(view)[:project_palette_open] == true
      assert assigns(view)[:palette_mode] == :open_path
      assert is_nil(assigns(view)[:active_project])

      datalist =
        path_suggestions_datalist(render_change(view, "path_input", %{"path" => project_path}))

      assert datalist =~ ~s(<option value="#{project_path}"></option>)
      assert length(String.split(datalist, ~s(value="#{project_path}"))) == 2
    end
  end

  describe "new project path input suggestions" do
    test "input carries autocomplete wiring and recomputes suggestions on change", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      # Open the palette and switch to Create New Project mode
      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "new_project"})

      # Typing into the path input fires the phx-change handler, which
      # recomputes `@path_suggestions` for the typed parent directory (the
      # create-new-project palette is local-only, so these resolve against the
      # local filesystem).
      html = render_change(view, "new_project_path_input", %{"path" => tmp_dir})

      assert html =~ ~s(id="new-project-path-input")
      assert html =~ ~s(phx-hook="PathAutocomplete")
      assert html =~ ~s(list="new-project-path-suggestions")
      assert html =~ ~s(phx-change="new_project_path_input")
      assert html =~ ~s(phx-debounce="150")
      assert html =~ ~s(<datalist id="new-project-path-suggestions">)

      # tmp_dir exists on disk, so it must appear among the recomputed suggestions
      assert Enum.member?(assigns(view)[:path_suggestions], tmp_dir)
      assert html =~ ~s(<option value="#{tmp_dir}"></option>)
    end
  end

  describe "select_project" do
    setup do
      clear_projects()
    end

    test "activates the selected project", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      html = render_click(view, "select_project", %{"path" => tmp_dir})

      # The palette trigger shows the selected project basename
      assert html =~ Path.basename(tmp_dir)
    end

    test "shows an error for a non-existent path", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      html = render_click(view, "select_project", %{"path" => "/nonexistent/select/project"})

      assert html =~ "Directory does not exist"
    end
  end

  describe "create_project" do
    setup do
      clear_projects()
    end

    test "creates and activates a new project", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "new_project"})

      full_path = Path.join(tmp_dir, "my-brand-new-project")

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.VCT.forget(full_path)
        rescue
          _ -> :ok
        end
      end)

      html =
        view
        |> element("form[phx-submit='create_project']")
        |> render_submit(%{path: full_path})

      # Flash confirms creation
      assert html =~ "Project created"
      # The project bar shows the new project name
      assert html =~ "my-brand-new-project"
      # The new project is registered in the project list
      assert Enum.any?(EvoGit.VCT.projects(), &(&1.path == full_path))
      # The palette closes after successful creation
      assert assigns(view)[:project_palette_open] == false
    end

    test "creates a fully non-existent nested path recursively", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "new_project"})

      full_path = Path.join(tmp_dir, "new/nested/project")

      # None of the intermediate directories exist yet
      assert File.dir?(full_path) == false

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.VCT.forget(full_path)
        rescue
          _ -> :ok
        end
      end)

      html =
        view
        |> element("form[phx-submit='create_project']")
        |> render_submit(%{path: full_path})

      # The whole parent chain was created
      assert File.dir?(full_path) == true
      # Flash confirms creation
      assert html =~ "Project created"
      # The new project is registered in the project list
      assert Enum.any?(EvoGit.VCT.projects(), &(&1.path == full_path))
      # The palette closes after successful creation
      assert assigns(view)[:project_palette_open] == false
    end

    test "opens and activates an existing directory", %{conn: conn, tmp_dir: tmp_dir} do
      existing = Path.join(tmp_dir, "existing-project")
      File.mkdir_p!(existing)

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.VCT.forget(existing)
        rescue
          _ -> :ok
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "new_project"})

      html =
        view
        |> element("form[phx-submit='create_project']")
        |> render_submit(%{path: existing})

      # Opening an existing directory follows the same success path
      assert html =~ "Project created"
      refute html =~ "Could not create directory"
      refute html =~ "Invalid project name"
      # The existing project is registered in the project list
      assert Enum.any?(EvoGit.VCT.projects(), &(&1.path == existing))
      # The palette closes after successful creation
      assert assigns(view)[:project_palette_open] == false
    end
  end

  describe "project path normalization regression" do
    setup do
      clear_projects()
      :ok
    end

    test "create_project rejects relative paths without creating a directory or registering the project",
         %{
           conn: conn
         } do
      # Unique bare name so the File.dir? assertions can never collide with a
      # pre-existing directory in the BEAM cwd.
      relative = "Test#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "new_project"})

      html =
        view
        |> element("form[phx-submit='create_project']")
        |> render_submit(%{path: relative})

      # Error flash: relative input is rejected with the full-path hint
      assert html =~ "Enter a full path"

      # No directory created — neither relative to the palette cwd nor
      # cwd-joined against the BEAM cwd (the old Path.expand behavior)
      refute File.dir?(relative)
      refute File.dir?(Path.join(File.cwd!(), relative))

      # No project registration for the bogus path (bare or cwd-joined)
      projects = EvoGit.VCT.projects()
      refute Enum.any?(projects, &(&1.path == relative))
      refute Enum.any?(projects, &(&1.path == Path.join(File.cwd!(), relative)))

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test
        # failures. Defensive: if the code regresses to cwd-joining, this
        # removes the created directory and project entry so they can't leak.
        try do
          EvoGit.VCT.forget(Path.join(File.cwd!(), relative))
        rescue
          _ -> :ok
        end

        File.rm_rf(Path.join(File.cwd!(), relative))
      end)
    end

    test "open_project rejects relative paths with the full-path hint", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: "Test"})

      # Relative input is REJECTED up front — never reaches the directory check
      assert html =~ "Enter a full path"
      refute html =~ "Directory does not exist"
    end

    test "select_project rejects relative paths with the full-path hint", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      html = render_click(view, "select_project", %{"path" => "Test"})

      assert html =~ "Enter a full path"
      refute html =~ "Directory does not exist"
    end

    test "open_project with an absolute-but-missing directory still flashes the not-found error",
         %{
           conn: conn
         } do
      missing =
        Path.join(System.tmp_dir!(), "genesis_nonexistent_#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: missing})

      # Absolute-but-missing is still the "Directory does not exist" path —
      # only RELATIVE input got the new full-path hint
      assert html =~ "Directory does not exist"
      refute html =~ "Enter a full path"
      refute File.dir?(missing)
    end

    test "relative ?project= URL param is silently ignored", %{conn: conn} do
      {:ok, view, html} = live(conn, "/projects?project=Test")

      # No crash; the page renders in the no-project empty state
      assert html =~ "No projects"
      refute html =~ "task-launch-button"

      # No project becomes active
      assert assigns(view)[:active_project] == nil
      assert assigns(view)[:active_project_path] == nil

      # Relative/blank params are silently ignored — no flash at all
      refute html =~ "Enter a full path"
      refute html =~ "Invalid project name"
    end

    test "create_project with a blank path still flashes Invalid project name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "new_project"})

      html =
        view
        |> element("form[phx-submit='create_project']")
        |> render_submit(%{path: "   "})

      # Blank input keeps the pre-existing "Invalid project name" behavior
      assert html =~ "Invalid project name"
      refute html =~ "Enter a full path"
    end
  end

  describe "task notifications" do
    setup do
      clear_projects()
      :ok
    end

    # The two tests LEFT in this describe are content-pinned POSITIVE
    # assertions: `assert_push_event` scans the mailbox for the exact
    # `{title, body}` pair derived from this test's OWN fixture (a unique
    # prompt / `pr_title`), so a concurrent module's notification — which
    # carries different content — cannot satisfy or break them. A zero-timeout
    # `refute_push_event` could not stay here.
    test "notification fires only for newly-terminal ids with matching content", %{conn: conn} do
      # Terminal before mount -> part of the mount seed -> never notified
      insert_task_fixture!(status: :completed, opts: [prompt: "old task"])

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_notified_ids_ready(view)

      # Becomes terminal after mount -> newly-terminal -> notification pushed
      new_task =
        insert_task_fixture!(
          status: :completed,
          opts: [prompt: "notify me"],
          result: {:ok, %{pr_title: "PR title"}}
        )

      send(view.pid, :node_aware_reload_tasks)
      drain_task_reload(view)

      {title, body} = EvoDashWeb.ProjectsLive.Project.task_notification_content(new_task)
      assert_push_event(view, "task_notification", %{title: ^title, body: ^body})
    end

    test "a newly-terminal task that carries an archive still notifies (lite read)", %{
      conn: conn
    } do
      # Terminal before mount -> part of the mount seed -> never notified
      insert_task_fixture!(status: :completed, opts: [prompt: "old task"])

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_notified_ids_ready(view)

      # The result still carries the legacy `archive_records` payload (older
      # rows), but the per-agent archive itself is no longer a task-row column.
      # The notification only needs opts/result/type, so the lite read must not
      # change the pushed content either way.
      new_task =
        insert_task_fixture!(
          status: :completed,
          opts: [prompt: "notify archived"],
          result: {:ok, %{pr_title: "Archived PR title", archive_records: [%{"agent_id" => 1}]}}
        )

      send(view.pid, :node_aware_reload_tasks)
      drain_task_reload(view)

      {title, body} = EvoDashWeb.ProjectsLive.Project.task_notification_content(new_task)
      assert title == "Archived PR title"
      assert_push_event(view, "task_notification", %{title: ^title, body: ^body})
    end

    # MOVED: "user-initiated delete_task does not notify", "user-initiated
    # clear_task_history does not notify" AND "no notification for a task
    # already terminal before mount" live in
    # `EvoDashWeb.ProjectsLiveSyncTest` below — each zero-timeout refute is a
    # claim about GLOBAL quiet (no `task_notification` at all). The scan behind
    # it (`EvoDashWeb.ProjectsLive.Notifications`) diffs terminal ids read from
    # the RUN-WIDE `EvoGit.Store`, so any `:completed` row a concurrent async
    # module inserts after this view's mount seed is "newly terminal" here and
    # pushes its own `task_notification`; the delete/clear mutations add a
    # `"tasks"` broadcast from the process-global registry (and the clear sweeps
    # every FINISHED task out of the RUN-WIDE store, which would delete another
    # async module's live fixture mid-test).
  end

  describe "async mount loads + notification scan (exit-safe)" do
    setup do
      clear_projects()
      :ok
    end

    test "the async batch really fills projects a frame after mount", %{conn: conn} do
      async_path =
        Path.join(System.tmp_dir!(), "evogit_async_projects_#{System.unique_integer()}")

      File.mkdir_p!(async_path)
      on_exit(fn -> File.rm_rf(async_path) end)

      test_pid = self()

      # Block the batch body until the test has observed the mount defaults,
      # so "not present before the message" is deterministic instead of a race.
      install_projects_async_load_runner(fn ->
        send(test_pid, {:batch_started, self()})

        receive do
          :proceed -> :ok
        after
          5_000 -> :ok
        end

        %{
          model_selection: EvoDashWeb.LLMSelection.from_config(%{}, false),
          projects: [
            %{
              point: "vct:///projects/async-project",
              path: async_path,
              name: "async-project"
            }
          ],
          terminal_ids: MapSet.new(),
          auto_activate?: false
        }
      end)

      {:ok, view, _html} = live(conn, ~p"/projects")

      assert_receive {:batch_started, task_pid}, async_wait_budget()
      # The batch runs OFF the LiveView process.
      assert task_pid != view.pid
      assert task_pid != test_pid

      # Mount defaults are still in place while the batch is blocked.
      assert assigns(view)[:projects] == []
      assert assigns(view)[:notified_task_ids_ready?] == false
      refute render(view) =~ "async-project"

      send(task_pid, :proceed)

      wait_for_projects(view, [async_path])
      # Readiness flips with the same batch (terminal_ids seeded).
      assert assigns(view)[:notified_task_ids_ready?] == true
      # The palette renders the async-loaded entry (the trigger stays closed).
      assert render_click(view, "open_project_palette", %{}) =~ "async-project"

      await_async_loads(view)
    end

    # MOVED: "the notified-id seed never notifies for pre-existing terminal
    # tasks" lives in `EvoDashWeb.ProjectsLiveSyncTest` below — its final
    # zero-timeout refute follows a real reload, whose scan diffs the RUN-WIDE
    # store, so it is the same GLOBAL-quiet claim as the other moved tests.
  end

  describe "remote node contexts" do
    setup do
      clear_projects()
      :ok
    end

    test "node switch clears local form state before rendering the remote gate", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager, {id, %{phase: :connecting, node: nil}}}
      )

      {:ok, view, _html} = live(conn, ~p"/projects")

      # Settle the MOUNT-time async load before driving events: its result
      # carries the mount-time `projects` and is dropped only when the
      # captured node/path changed — after the `?node=` switch below the
      # captured local node + nil path still match (a `:connecting` target
      # keeps `current_node` local and the switch clears the active path back
      # to nil), so a late arrival would re-populate the just-cleared
      # `projects` with the local mounts registered below. Draining it
      # first makes the cleared-state assertions deterministic.
      await_async_loads(view)

      # Open a local project and fill in form state
      open_project!(view, tmp_dir)

      # task_prompt_change no longer exists (per-keystroke server event removed);
      # restore_state is the still-supported way to set the persisted prompt.
      render_change(view, "restore_state", %{"task_prompt" => "some objective"})
      render_click(view, "toggle_advanced", %{})

      assert assigns(view)[:task_prompt] == "some objective"
      assert assigns(view)[:show_advanced] == true
      assert assigns(view)[:active_project] != nil

      # Switch to the remote node context: handle_params re-runs and clears all
      # persisted/project state (each node context owns its own session state).
      html = render_patch(view, "/projects?node=" <> id)

      # This handle_params run spawns its OWN `AsyncLoad` task. For a
      # `:connecting` target it is the ONLY thing that clears `projects`
      # to `[]` (the node-switch clearing owns the form/project assigns, not
      # projects; `AsyncLoad.load_projects/3` returns `[]` whenever
      # `current_node_id` is a binary) — and `render_patch/2` does not wait for
      # it. Wait for the spawned task and drain its queued
      # `{:async_project_load, ...}` apply before asserting, otherwise a slow
      # task leaves the pre-switch local projects (the project opened above) in
      # place.
      await_async_loads(view)

      assert assigns(view)[:current_node_id] == id
      assert assigns(view)[:task_prompt] == ""
      assert assigns(view)[:show_advanced] == false
      assert assigns(view)[:active_project] == nil
      assert assigns(view)[:active_project_path] == nil
      assert assigns(view)[:projects] == []

      # The connecting gate renders — no local form/project data leaks through
      assert html =~ ~s(data-node-id="#{id}")
      # The draft scope was cleared with the project, so the browser hook falls
      # back to its un-scoped key instead of adopting another node's draft.
      refute html =~ "data-task-draft-scope"
      assert html =~ ~s(class="loading loading-spinner loading-lg text-info")
      assert html =~ "Connecting to Test Target"
      refute html =~ ~s(id="prompt")
      refute html =~ "task-launch-button"
      refute html =~ "Recent Projects"
    end

    test "connected remote without a selected project shows the workbench empty state", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, html} = live(conn, "/projects?node=" <> id)

      # The connected view must render on the FIRST pass — `remote?` is derived
      # from the post-assign_node socket so a page load at a connected `?node=`
      # URL never falls through to the error gate.
      assert assigns(view)[:current_node_id] == id
      assert assigns(view)[:current_node] == :"genesis_remote@127.0.0.1"
      assert assigns(view)[:remote?] == true
      # erpc to the fake BEAM node fails fast — no projects, no hang risk
      assert assigns(view)[:projects] == []

      assert has_element?(view, "#workbench-idle")
      assert html =~ ~s(data-node-id="#{id}")
      refute has_element?(view, "#task-form")
      refute html =~ "Cannot connect"

      # Remote palette: Open by Path yes, Create New Project hidden. The
      # per-row Forget action renders on LOCAL and REMOTE nodes alike, so with
      # an unreachable remote node (empty project list) there is simply no row.
      html = render_click(view, "open_project_palette", %{})
      assert html =~ "Open Project by Path"
      refute has_element?(view, "button[phx-click=palette_mode][phx-value-mode=new_project]")
      assert has_element?(view, "#workbench-new-project")
      refute html =~ ~s(phx-click="forget_project")
    end

    test "forget_project renders on remote nodes and routes through the node RPC", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      project_a = Path.join(tmp_dir, "my-alpha-#{System.unique_integer([:positive])}")
      File.mkdir_p!(project_a)
      mount = seed_project(project_a, "my-alpha")

      id = save_target!()
      remote_node = :"genesis_remote@127.0.0.1"

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)
      assert assigns(view)[:remote?] == true

      # The remote project list arrives off-process (`NodeContext.projects/1`
      # degrades to [] for the fake BEAM node), so inject the remote node's
      # list as the async batch continuation would. The seq is read from the
      # VIEW (a synchronous round-trip), not assumed: the continuation is
      # stale-guarded on it.
      seq = assigns(view)[:projects_seq]

      send(
        view.pid,
        {:projects_loaded, seq, id, remote_node, {:ok, [%{mount | path: mount.path}]}}
      )

      assert [injected] = assigns(view)[:projects]

      # Open the palette — the per-row Forget action only renders inside it.
      html = render_click(view, "open_project_palette", %{})

      # The Forget action IS rendered on remote nodes now.
      assert html =~ ~s(phx-click="forget_project")
      assert html =~ ~s(phx-value-point="#{injected.point}")
      assert html =~ ~s(aria-label="Forget my-alpha")

      # Clicking it routes through the remote node RPC, which fails for the
      # fake BEAM node: the row disappears optimistically and the async
      # continuation settles with the failure flash.
      html = render_click(view, "forget_project", %{"point" => injected.point})
      refute html =~ ~s(phx-value-point="#{injected.point}")
      assert assigns(view)[:palette_selected_index] == 0

      # No local leak: forgetting on a remote node never touches the LOCAL
      # mount registry.
      assert Enum.any?(EvoGit.VCT.projects(), &(&1.point == injected.point))

      await_async_loads(view)
      html = render(view)
      assert html =~ "Failed to forget project"
      refute html =~ ~s(phx-value-point="#{injected.point}")
    end

    test "error-phase remote context renders the error gate with actions", %{conn: conn} do
      id = save_target!()

      fake =
        start_supervised!(
          {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
           {id, %{phase: :error, last_error: "boom", node: nil}}}
        )

      {:ok, view, html} = live(conn, "/projects?node=" <> id)

      assert html =~ "Cannot connect to Test Target"
      assert html =~ "boom"
      assert html =~ ~s(phx-click="retry_remote_connection")
      # Manage Connections href carries NO ?node= param (connection management
      # is a local dashboard concern)
      assert html =~ ~s(href="/settings?category=remote_connections")
      refute html =~ ~s(href="/settings?category=remote_connections?node=)
      assert html =~ ~s(phx-click="switch_to_local")

      # No local project data / task form leaks into the error state
      refute html =~ ~s(id="prompt")
      refute html =~ "task-launch-button"
      refute html =~ "Recent Projects"

      # Retry calls the (fake) connection manager and deliberately ignores the
      # result — no crash, error state stays rendered.
      #
      # The click only SPAWNS the connect (NodeAware.initiate_remote_connect/2
      # runs it on EvoDash.TaskSupervisor), so the action is wrapped in a
      # capture window and the spawned connect is AWAITED INSIDE it: without the
      # await the spawned task can outlive this test — and therefore the fake
      # ConnectionManager — after which its connect falls through to the REAL
      # EvoGit.RemoteConnection, which logs "No distribution cookie
      # configured…" and opens a real `ssh` tunnel from a process the per-test
      # capture window no longer covers (console noise in the between-test gap).
      {html, log} =
        ExUnit.CaptureLog.with_log(fn ->
          retry_html = render_click(view, "retry_remote_connection", %{})

          # Event-driven await (no sleep): poll the fake until the spawned
          # connect lands on it, proving the real core path was never entered.
          wait_for_fake_callers(fake, fn callers ->
            if callers == [], do: nil, else: :ok
          end)

          retry_html
        end)

      # The capture holds the real-connection warning: the fake answered, so the
      # real `connect` (and its SSH machinery) never ran.
      refute log =~ "No distribution cookie configured"

      assert html =~ "boom"
      assert html =~ ~s(phx-click="retry_remote_connection")
    end

    test "connecting a disconnected target in the project picker runs off-process",
         %{conn: conn} do
      id = save_target!()

      # A synchronous connect would run in the PARENT LiveView process
      # (LiveComponent events run in the parent), stalling the click. The
      # off-process property is asserted below via the recorded connect caller
      # pid: the fake records `elem(from, 0)` on every `:connect` call, and the
      # caller must be neither the LiveView process nor the test process —
      # which is exactly what a `EvoDash.TaskSupervisor` spawn produces. No
      # `:connect_delay_ms` is passed: the fake records the caller only in its
      # serialized `handle_call(:connect)` reply, so a delayed reply would just
      # make the test's `:callers` read block for the whole delay (300ms of
      # wall clock) without adding assertion power — the pid assertion is
      # delay-independent.
      fake =
        start_supervised!(
          {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
           {id, %{phase: :disconnected, node: nil, last_error: nil},
            [connect_result: {:ok, :connecting}]}}
        )

      {:ok, view, _html} = live(conn, ~p"/projects")

      refute has_element?(view, "#workbench-projects [data-workbench-node='#{id}']")

      render_hook(with_target(view, "#workbench-project-window-component"), "prepare", %{
        "mode" => "open"
      })

      render_change(element(view, "#project-location-form"), %{"location" => id})
      render_click(element(view, "#workbench-project-window [phx-click=connect_location]"))

      # The :connect call landed on the fake from a process that is NEITHER the
      # LiveView process NOR the test process — i.e. it ran on
      # EvoDash.TaskSupervisor.
      caller =
        wait_for_fake_callers(fake, fn callers ->
          Enum.find(callers, fn pid -> pid not in [view.pid, self()] end)
        end)

      refute caller in [view.pid, self()]
      assert GenServer.call(fake, :calls) >= 1
    end

    test "remote_connections broadcast reconciles the gate from connecting to error (async re-read)",
         %{conn: conn} do
      id = save_target!()

      fake =
        start_supervised!(
          {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
           {id, %{phase: :connecting, node: nil, last_error: nil}}}
        )

      {:ok, view, html} = live(conn, "/projects?node=" <> id)

      # The pending gate renders first (spinner + target name)
      assert assigns(view)[:current_node_id] == id
      assert html =~ ~s(class="loading loading-spinner loading-lg text-info")
      assert html =~ "Connecting to Test Target"

      # Mid-session phase change: the manager's STORED status flips to :error,
      # then the broadcast arrives. NodeAware.handle_connection_status
      # recomputes @remote_status from the LIVE manager (never from the
      # broadcast payload), so the gate must flip to the error state without
      # any page reload — distinct from the static-error mount tests above.
      GenServer.call(
        fake,
        {:set_status, %{phase: :error, last_error: "tunnel refused", node: nil}}
      )

      send(
        view.pid,
        {:remote_connection_status, id, %{phase: :error, last_error: "tunnel refused", node: nil}}
      )

      wait_assigns(view, fn a ->
        match?(%{phase: :error, last_error: "tunnel refused"}, a[:remote_status])
      end)

      html = render(view)

      assert html =~ "Cannot connect to Test Target"
      assert html =~ "tunnel refused"
      assert html =~ ~s(phx-click="retry_remote_connection")
      assert html =~ ~s(phx-click="switch_to_local")
      refute html =~ ~s(id="prompt")
    end

    test "retry from the gate delegates to the shared connect helper and flashes the sync error",
         %{conn: conn} do
      id = save_target!()

      fake =
        start_supervised!(
          {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
           {id, %{phase: :error, last_error: "boom", node: nil},
            [connect_result: {:error, :retry_bomb}]}}
        )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)

      # retry_remote_connection returns immediately (never blocks the LiveView):
      # it delegates to NodeAware.initiate_remote_connect/2, which spawns the
      # connect on EvoDash.TaskSupervisor. No crash, gate stays rendered.
      html = render_click(view, "retry_remote_connection", %{})
      assert html =~ "Cannot connect to Test Target"
      assert html =~ ~s(phx-click="retry_remote_connection")

      # The helper's spawned connect lands on the fake...
      wait_for_fake_callers(fake, fn callers ->
        if callers == [], do: nil, else: :ok
      end)

      # ...and its {:error, :retry_bomb} result is self-messaged back as
      # {:remote_connect_result, id, {:error, :retry_bomb}} and flashed by
      # projects_live.ex's sync-error fallback (no "remote_connections"
      # broadcast ever arrives on this arm).
      wait_assigns(view, fn a -> match?(%{"error" => _}, a[:flash]) end)

      assert assigns(view)[:flash]["error"] == "Remote connect failed: :retry_bomb"
    end

    test "saved target with no connection manager shows the generic error", %{conn: conn} do
      id = save_target!()

      {:ok, view, html} = live(conn, "/projects?node=" <> id)

      # No fake manager registered → status degrades to the disconnected default
      assert assigns(view)[:current_node_id] == id
      assert %{phase: :disconnected} = assigns(view)[:remote_status]

      assert html =~ "Connection lost or failed"
      assert html =~ ~s(phx-click="switch_to_local")
      refute html =~ ~s(id="prompt")
      refute html =~ "task-launch-button"
    end

    test "switch to local patches back to the local UI without the ?node= param", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
         {id, %{phase: :error, last_error: "boom", node: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)

      render_click(view, "switch_to_local", %{})

      # handle_node_selected push_patches to the current path WITHOUT ?node=
      # One extra render flushes the {:node_selected, _} self-message so the
      # push_patch lands before assert_patch polls.
      render(view)
      assert_patch(view, "/projects")

      html = render(view)

      assert assigns(view)[:current_node_id] == nil
      # Local UI is back: the task form renders again
      assert has_element?(view, "#workbench-idle")
      refute html =~ ~s(id="prompt")
      assert html =~ "No projects"
    end

    test "connecting-phase gate suppresses the palette trigger", %{conn: conn} do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager, {id, %{phase: :connecting, node: nil}}}
      )

      {:ok, view, html} = live(conn, "/projects?node=" <> id)

      # The pending gate is active: the target is the current node and the
      # manager's stored phase is :connecting (the spinner markup itself is
      # pinned component-side in remote_gate_components_test.exs).
      assert assigns(view)[:current_node_id] == id
      assert %{phase: :connecting} = assigns(view)[:remote_status]
      assert html =~ ~s(data-node-id="#{id}")

      refute html =~ ~s(phx-click="open_project_palette")
      refute has_element?(view, "#task-options")
      refute has_element?(view, "#workbench-task-settings")
    end

    test "open_project_palette event is ignored while the gate is active", %{conn: conn} do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager, {id, %{phase: :connecting, node: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)

      # Forged/raced event: the guard must reject it and leave the palette closed
      render_click(view, "open_project_palette", %{})

      assert assigns(view)[:project_palette_open] == false
    end

    test "open_project during the gate does not leak into the local project store", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager, {id, %{phase: :connecting, node: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)

      # Forged/raced submit: the palette is suppressed in the DOM but the event
      # can still arrive — the gate guard must reject it with a flash error and
      # must NOT register the (locally existing) path in the LOCAL projects.
      html = render_submit(view, "open_project", %{path: tmp_dir})

      assert html =~ "Cannot open project"
      assert html =~ "is not connected"
      refute Enum.any?(EvoGit.VCT.projects(), &(&1.path == tmp_dir))
    end

    test "remote open_project success path filters projects with the node first (regression)", %{
      tmp_dir: tmp_dir
    } do
      id = save_target!()

      # The remote SUCCESS branch is unreachable through a full LiveView in
      # tests: a connected fake node atom fails the dir? RPC fast (error
      # branch — see the test above), and a disconnected target is
      # gate-blocked (`gate_active?/1` gates `%{phase: :disconnected}`, so the
      # submit never reaches the activation). Call `open_project/2` directly
      # on a hand-built socket in the test-reachable remote-success state:
      # `current_node_id` set (routes into the remote activation path),
      # `remote_status` phase `:connected` (gate guard inactive), and
      # `current_node` = the LOCAL BEAM node so the spawned activation task's
      # NodeContext calls short-circuit to the real local
      # TaskRegistry/filesystem (no :erpc).
      socket =
        %Phoenix.LiveView.Socket{assigns: %{__changed__: nil}, redirected: nil}
        |> Phoenix.Component.assign(:current_node_id, id)
        |> Phoenix.Component.assign(:current_node, node())
        |> Phoenix.Component.assign(:remote_status, %{phase: :connected})
        # The mount-seeded assigns the async continuation reads (a real mounted
        # socket always carries them): the reconnect params the URL patch is
        # rebuilt from and the resume target the foreign-repo guard checks.
        |> Phoenix.Component.assign(:workbench_reconnect_params, %{})
        |> Phoenix.Component.assign(:task_resume_from, "")

      # open_project/2 now returns IMMEDIATELY: the RPC-heavy sequence runs in
      # a spawned task, so the socket only carries the loading flag + closed
      # palette; the projects/active_project assigns arrive via the async
      # continuation.
      assert {:noreply, socket} =
               EvoDashWeb.ProjectsLive.ProjectFlow.open_project(socket, %{"path" => tmp_dir})

      assert socket.assigns[:remote_project_loading] == tmp_dir
      assert socket.assigns[:project_palette_open] == false
      assert socket.assigns[:palette_mode] == :menu
      assert socket.assigns[:active_project] == nil
      assert socket.assigns[:projects] == nil
      refute socket.redirected

      # The task captured `view_pid = self()` — THIS test process — so its
      # result message lands in the test-process mailbox.
      local_node = node()

      assert_receive {:async_remote_project, ^local_node, ^tmp_dir, {:ok, results}},
                     async_wait_budget()

      # Apply the continuation directly (handle_info is a public callback).
      socket =
        EvoDashWeb.ProjectsLive.handle_info(
          {:async_remote_project, local_node, tmp_dir, {:ok, results}},
          socket
        )
        |> elem(1)

      # The node-filtered VCT projects (incl. the freshly registered tmp_dir)
      # were assigned — the exact output of the fixed filter line.
      assert Enum.any?(socket.assigns[:projects], &(&1.path == tmp_dir))

      # The active project is the display-only `%{path, name, point}` map the
      # activation continuation assigns (the VCT owns the point; never a
      # hardcoded suffix).
      active_project = socket.assigns[:active_project]
      assert active_project.path == tmp_dir
      assert active_project.name == Path.basename(tmp_dir)

      entry = Enum.find(socket.assigns[:projects], &(&1.path == tmp_dir))

      # The activation MOUNTED the project, so the assigned project list (the
      # authoritative VCT row set this continuation assigns) carries its
      # registry-owned point.
      assert is_binary(Map.get(entry, :point))
      assert String.starts_with?(entry.point, "vct:///projects/")

      # `active_project.point` is a display-only lookup whose documented
      # fallback is nil (`ProjectFlow.remote_project_load/2` renders the plain
      # OS path then). Pin both halves of that contract: whatever it holds must
      # be THIS project's point — never a stale or foreign one.
      point = active_project.point
      assert is_nil(point) or point == Map.get(entry, :point)

      assert socket.assigns[:active_project_path] == tmp_dir
      assert socket.assigns[:remote_project_loading] == nil
      assert socket.assigns[:show_add_foreign_repo_form] == false
      assert socket.assigns[:task_mode] == "genesis_new"

      # The project was registered in the LOCAL project store, proving
      # the activation task's success branch ran end-to-end.
      assert Enum.any?(EvoGit.VCT.projects(), &(&1.path == tmp_dir))

      # The URL patch preserves the remote node context (`&node=` survives).
      assert socket.redirected ==
               {:live, :patch,
                %{to: "/projects?node=#{id}&project=#{URI.encode_www_form(tmp_dir)}", kind: :push}}
    end

    test "restore_state tagged with the local node restores persisted values", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      # A payload tagged with a DIFFERENT node is ignored (folded in from the
      # former standalone "different node context" test: same handler, weaker
      # inverse — proven here on the same mount).
      render_hook(view, "restore_state", %{
        "node" => "some-remote",
        "task_prompt" => "leak",
        "task_resume_from" => "abc",
        "project" => tmp_dir
      })

      assert assigns(view)[:task_prompt] == ""
      assert assigns(view)[:task_resume_from] == ""
      assert assigns(view)[:active_project] == nil

      render_hook(view, "restore_state", %{
        "node" => "local",
        "task_prompt" => "my objective",
        "task_resume_from" => "task-123",
        "project" => tmp_dir
      })

      assert assigns(view)[:task_prompt] == "my objective"
      assert assigns(view)[:task_resume_from] == "task-123"
      assert assigns(view)[:active_project] != nil
    end

    test "restore_state tagged local never leaks into a remote pending context", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager, {id, %{phase: :connecting, node: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)

      render_hook(view, "restore_state", %{
        "node" => "local",
        "task_prompt" => "leak",
        "task_resume_from" => "abc",
        "project" => "/nonexistent"
      })

      # Gate: saved node ("local") != current node (remote id) → nothing restored
      assert assigns(view)[:task_prompt] == ""
      assert assigns(view)[:task_resume_from] == ""
      assert assigns(view)[:active_project] == nil
    end

    test "restore_state stays with the project in the explicit task draft URL", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: tmp_dir, wb_task: 1}}")

      render_hook(view, "restore_state", %{
        "node" => "local",
        "project" => Path.join(tmp_dir, "other-project"),
        "task_prompt" => "another project's draft",
        "task_starting_commit" => "foreign-commit"
      })

      assert assigns(view)[:active_project_path] == tmp_dir
      assert assigns(view)[:task_prompt] == ""
      assert assigns(view)[:task_starting_commit] == ""

      render_hook(view, "restore_state", %{
        "node" => "local",
        "project" => tmp_dir,
        "task_prompt" => "the selected project's draft"
      })

      assert assigns(view)[:task_prompt] == "the selected project's draft"
    end

    test "remote open_project accepts a POSIX absolute path (cross-OS regression)", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      # Cross-OS bug vector: `/home/user/proj` is a POSIX absolute path that
      # the pre-fix LOCAL normalization misclassified on a Windows dashboard
      # (Path.type/1 → :volumerelative → the "Enter a full path" flash). The
      # remote-aware normalization must accept it verbatim and fail ONLY at
      # the remote dir? validation (no real daemon answers the RPC in tests).
      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: "/home/user/proj"})

      refute html =~ "Enter a full path"
      # The activation is ASYNC: the event-turn html deterministically shows
      # the loading banner (the in-flight flag may already be cleared by the
      # fast task's error message — not asserted here).
      assert html =~ "Loading project"

      # Inject the deterministic error result (the real task's message is a
      # harmless duplicate — the later one is dropped by the stale-guard once
      # the loading flag clears).
      send(
        view.pid,
        {:async_remote_project, :"genesis_remote@127.0.0.1", "/home/user/proj",
         {:error, :not_a_directory}}
      )

      html = render_async(view, async_wait_budget())

      assert html =~ "Directory does not exist on the remote node: /home/user/proj"
      assert assigns(view)[:remote_project_loading] == nil

      # The failed remote validation must NOT register the path locally
      # (proves the remote branch ran, not the local one)
      refute Enum.any?(
               EvoGit.VCT.projects(),
               &(&1.path == "/home/user/proj")
             )
    end

    test "async project load drops results from a stale node", %{conn: conn} do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)

      # Wait for the real async load so the assigns are settled (the mount-
      # seeded degraded values equal the async degraded results either way).
      render_async(view, async_wait_budget())
      assert assigns(view)[:custom_agents] == []

      # Forged result from a DIFFERENT node — dropped entirely by the
      # stale-guard (AsyncLoad.handle_result/5 compares the captured node
      # against the socket's current node).
      send(
        view.pid,
        {:async_project_load, :"different_node@127.0.0.1", nil, nil,
         %{
           custom_agents: [%{id: "stale"}],
           model_selection_enabled: true,
           model_selection: EvoDashWeb.LLMSelection.from_config(%{}, false),
           projects: []
         }}
      )

      render_async(view, async_wait_budget())

      refute Enum.any?(assigns(view)[:custom_agents], &(&1.id == "stale"))
      assert assigns(view)[:custom_agents] == []
    end

    test "async remote project activation drops results for a stale path", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)

      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "open_path"})

      html =
        view
        |> element("form[phx-submit='open_project']")
        |> render_submit(%{path: tmp_dir})

      # The event-turn html deterministically shows the loading banner (the
      # in-flight flag may already be cleared by the fast task's error message
      # — not asserted here).
      assert html =~ "Loading project"

      # Forged SUCCESS result captured for a DIFFERENT path — dropped by the
      # stale-guard (the captured path must equal the in-flight
      # remote_project_loading), so the /wrong/path project never activates.
      # The real task's {:error, :not_a_directory} is processed in any order
      # and never sets active_project either.
      send(
        view.pid,
        {:async_remote_project, :"genesis_remote@127.0.0.1", "/wrong/path",
         {:ok,
          %{
            projects: [],
            active_project: %{path: "/wrong/path", name: "wrong"},
            active_project_path: "/wrong/path",
            task_mode: "genesis_new",
            task_mode_info: nil,
            project_config: nil,
            worktree_script: nil,
            commands: [],
            foreign_repos: []
          }}}
      )

      render_async(view, async_wait_budget())

      assert assigns(view)[:active_project] == nil
      assert assigns(view)[:active_project_path] == nil
    end

    test "add_foreign_repo on a remote node rejects unverifiable paths (POSIX/Windows absolute still pass the absolute check)",
         %{conn: conn} do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)
      assert assigns(view)[:remote?] == true

      # POSIX absolute — the node-aware validator passes the absolute check
      # (a Windows dashboard's local `Platform.absolute_path?/1` would reject
      # it), but the fake node's :erpc fails fast → NodeContext.dir?/2 returns
      # false → the existence check rejects with the does-not-exist flash.
      html =
        render_click(view, "add_foreign_repo", %{
          "repo_id" => "remote-posix",
          "path" => "/home/user/repo",
          "description" => ""
        })

      refute html =~ "Path must be absolute."
      assert html =~ "Foreign repo path does not exist: /home/user/repo"
      refute Enum.any?(assigns(view)[:foreign_repos], &(&1.id == "remote-posix"))

      # Windows-style absolute — same story: passes the absolute check (a
      # POSIX dashboard's local check would cwd-join it), rejected for
      # existence on the unverifiable fake node.
      html =
        render_click(view, "add_foreign_repo", %{
          "repo_id" => "remote-win",
          "path" => "D:\\stuff\\repo",
          "description" => ""
        })

      refute html =~ "Path must be absolute."
      assert html =~ "Foreign repo path does not exist: D:\\stuff\\repo"
      refute Enum.any?(assigns(view)[:foreign_repos], &(&1.id == "remote-win"))

      # Relative input is still rejected on a remote node (absolute check)
      html =
        render_click(view, "add_foreign_repo", %{
          "repo_id" => "remote-bad",
          "path" => "foo/bar",
          "description" => ""
        })

      assert html =~ "Path must be absolute."
      refute Enum.any?(assigns(view)[:foreign_repos], &(&1.id == "remote-bad"))

      # UNC / WSL absolute forms (folded in from the former standalone test):
      # the double-slash and backslash-UNC prefixes are absolute in both POSIX
      # and UNC semantics, so they pass the absolute check and fail only the
      # existence probe against the unverifiable fake node.
      html =
        render_click(view, "add_foreign_repo", %{
          "repo_id" => "remote-wsl",
          "path" => "//wsl.localhost/Ubuntu-22.04/home/user/proj",
          "description" => ""
        })

      refute html =~ "Path must be absolute."

      assert html =~
               "Foreign repo path does not exist: //wsl.localhost/Ubuntu-22.04/home/user/proj"

      refute Enum.any?(assigns(view)[:foreign_repos], &(&1.id == "remote-wsl"))

      html =
        render_click(view, "add_foreign_repo", %{
          "repo_id" => "remote-unc",
          "path" => "\\\\server\\share\\proj",
          "description" => ""
        })

      refute html =~ "Path must be absolute."
      assert html =~ "Foreign repo path does not exist: \\\\server\\share\\proj"
      refute Enum.any?(assigns(view)[:foreign_repos], &(&1.id == "remote-unc"))
    end

    test "local render carries data-node-id=local on the dashboard root", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/projects")

      assert html =~ ~s(data-node-id="local")
    end
  end

  describe "remote URL-driven project activation" do
    # Exercise the real supervised URL activation with target-owned loader,
    # resume-reader and batch fixtures, never a local BEAM posing as remote.
    test "resume landing URL activates the remote project, restores the previous task's foreign repos, and keeps the resume form state (regression)",
         %{conn: conn, tmp_dir: tmp_dir} do
      remote_path = "/remote/projects/#{Path.basename(tmp_dir)}"
      root = Path.join(remote_path, "orig-repo")

      task =
        %TaskInfo{
          id: "remote-resume-#{System.unique_integer([:positive])}",
          opts: [
            foreign_repos: [
              %{
                "id" => "orig",
                "root" => root,
                "description" => "d",
                "writable" => "true",
                "base_sha" => "abc123"
              }
            ]
          ]
        }

      {id, remote_node} = install_remote_activation_fixture!(remote_path, task)

      {:ok, view, _html} =
        live(
          conn,
          "/projects?project=" <>
            URI.encode(remote_path) <>
            "&resume_from=" <> task.id <> "&starting_commit=deadbeef&node=" <> id
        )

      assert_remote_activation_loaded(view, id, remote_node, remote_path)
      view_pid = view.pid

      assert_receive {:remote_resume_read, reader, [^view_pid | _], ^remote_node, task_id},
                     async_wait_budget()

      assert task_id == task.id
      assert reader != self()
      assert reader != view.pid

      # Remote branch routed + activation continuation applied the loader data.
      assert assigns(view)[:current_node_id] == id
      assert assigns(view)[:task_mode] == "genesis_new"

      # The active project is the display-only `%{path, name, point}` map the
      # activation continuation assigned: the remote loader's point (the VCT
      # owns the identity) is preserved alongside the OS path, never dropped.
      assert assigns(view)[:active_project] == %{
               path: remote_path,
               name: Path.basename(remote_path),
               point: "vct:///projects/#{Path.basename(remote_path)}"
             }

      # Resume params preserved — the continuation's push_patch re-runs
      # handle_params WITHOUT resume_from/starting_commit, which must NOT
      # clobber the state the initial landing assigned.
      assert assigns(view)[:task_resume_from] == task.id
      assert assigns(view)[:task_starting_commit] == "deadbeef"
      assert assigns(view)[:show_advanced] == true

      # Task foreign repos restored by the target-owned resume reader inside
      # the activation task, then converted through repos_from_task_data/2.
      repo = Enum.find(assigns(view)[:foreign_repos], &(&1.id == "orig"))

      assert %ForeignRepo{root: ^root, writable: true, base_sha: "abc123", description: "d"} =
               repo

      # The continuation flagged the one-shot guard so the AsyncLoad
      # remote_extras reload the push_patch triggers cannot clobber the
      # task-restored repos with genesis.toml values.
      assert assigns(view)[:resume_foreign_repos_guard] == true

      # Drive a target-owned remote_extras reload after the actual activation
      # and push_patch batches settle; the guard drops genesis.toml repos once.
      cur = assigns(view)
      toml_repo = %ForeignRepo{id: "toml", root: "/Source/toml-repo", description: "t"}

      send(
        view.pid,
        {:async_project_load, remote_node, id, remote_path,
         %{
           foreign_repos: [toml_repo],
           load_scope: %{
             seq: cur[:projects_load_seq],
             node_id: id,
             selection: cur[:selected_model_spec]
           }
         }}
      )

      wait_assigns(view, &(&1[:resume_foreign_repos_guard] == false))
      refute Enum.any?(assigns(view)[:foreign_repos], &(&1.id == "toml"))
      assert Enum.any?(assigns(view)[:foreign_repos], &(&1.id == "orig"))

      # A second such reload applies normally — the guard is one-shot.
      send(
        view.pid,
        {:async_project_load, remote_node, id, remote_path,
         %{
           foreign_repos: [toml_repo],
           load_scope: %{
             seq: cur[:projects_load_seq],
             node_id: id,
             selection: cur[:selected_model_spec]
           }
         }}
      )

      wait_assigns(view, &Enum.any?(&1[:foreign_repos], fn r -> r.id == "toml" end))
    end

    test "plain remote ?project= URL activates the project through the remote normalize path", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      remote_path = "/remote/projects/#{Path.basename(tmp_dir)}"
      {id, remote_node} = install_remote_activation_fixture!(remote_path)

      {:ok, view, _html} =
        live(conn, "/projects?project=" <> URI.encode(remote_path) <> "&node=" <> id)

      assert_remote_activation_loaded(view, id, remote_node, remote_path)

      assert assigns(view)[:current_node_id] == id
      # Only the supervised activation continuation assigns this detected mode.
      assert assigns(view)[:task_mode] == "genesis_new"
      assert assigns(view)[:active_project_path] == remote_path
      assert assigns(view)[:task_resume_from] == ""
    end
  end

  describe "foreign repos — read-write validation and threading" do
    setup do
      clear_projects()
      :ok
    end

    test "add_foreign_repo accepts a real git repo with writable + base_sha", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {repo_path, head_sha} = git_repo_fixture!(tmp_dir, "repo1")

      {:ok, view, _html} = live(conn, ~p"/projects")
      # The connected mount's async batch (`AsyncLoad`) assigns `:foreign_repos`
      # a frame later; adding a repo before it lands lets the late batch clobber
      # the form state below.
      await_async_loads(view)

      render_click(view, "add_foreign_repo", %{
        "repo_id" => "repo1",
        "path" => repo_path,
        "description" => "the repo",
        "writable" => "true",
        "base_sha" => head_sha
      })

      assert assigns(view)[:flash]["info"] == "Foreign repo 'repo1' registered successfully."

      repo = Enum.find(assigns(view)[:foreign_repos], &(&1.id == "repo1"))
      assert %ForeignRepo{writable: true, base_sha: ^head_sha} = repo
      assert repo.description == "the repo"
    end

    test "add_foreign_repo without writable/base_sha defaults to read-only HEAD", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {repo_path, _head_sha} = git_repo_fixture!(tmp_dir, "repo1")

      {:ok, view, _html} = live(conn, ~p"/projects")
      # Same shape as the writable/base_sha sibling above: mutate form state
      # only once the mount's async batch has landed.
      await_async_loads(view)

      render_click(view, "add_foreign_repo", %{
        "repo_id" => "repo1",
        "path" => repo_path,
        "description" => ""
      })

      assert assigns(view)[:flash]["info"] == "Foreign repo 'repo1' registered successfully."

      repo = Enum.find(assigns(view)[:foreign_repos], &(&1.id == "repo1"))
      assert %ForeignRepo{writable: false, base_sha: nil} = repo
    end

    test "add_foreign_repo rejects a missing directory", %{conn: conn, tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "nonexistent")

      {:ok, view, _html} = live(conn, ~p"/projects")
      await_async_loads(view)

      html =
        render_click(view, "add_foreign_repo", %{
          "repo_id" => "missing",
          "path" => missing,
          "description" => ""
        })

      assert html =~ "Foreign repo path does not exist: #{missing}"
      assert assigns(view)[:foreign_repos] == []
    end

    test "add_foreign_repo rejects a non-git directory", %{conn: conn, tmp_dir: tmp_dir} do
      plain = Path.join(tmp_dir, "plain")
      File.mkdir_p!(plain)

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          File.rm_rf!(plain)
        rescue
          _ -> :ok
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/projects")
      await_async_loads(view)

      html =
        render_click(view, "add_foreign_repo", %{
          "repo_id" => "plain",
          "path" => plain,
          "description" => ""
        })

      assert html =~ "Path is not a git repository: #{plain}"
      assert assigns(view)[:foreign_repos] == []
    end

    test "add_foreign_repo rejects a bogus base_sha on a real git repo", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {repo_path, _head_sha} = git_repo_fixture!(tmp_dir, "repo1")

      {:ok, view, _html} = live(conn, ~p"/projects")
      await_async_loads(view)

      html =
        render_click(view, "add_foreign_repo", %{
          "repo_id" => "repo1",
          "path" => repo_path,
          "description" => "",
          "base_sha" => "deadbeef"
        })

      assert html =~ "Base commit deadbeef not found in repository: #{repo_path}"
      assert assigns(view)[:foreign_repos] == []
    end

    test "edit_foreign_repo populates the edit form for an existing repo", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {repo_path, head_sha} = git_repo_fixture!(tmp_dir, "repo1")

      {:ok, view, _html} = live(conn, ~p"/projects")
      await_async_loads(view)

      render_click(view, "add_foreign_repo", %{
        "repo_id" => "repo1",
        "path" => repo_path,
        "description" => "the repo",
        "writable" => "true",
        "base_sha" => head_sha
      })

      render_click(view, "edit_foreign_repo", %{"repo_id" => "repo1"})

      assert assigns(view)[:editing_foreign_repo_id] == "repo1"

      assert assigns(view)[:foreign_repo_edit_form] == %{
               description: "the repo",
               writable: true,
               base_sha: head_sha
             }
    end

    test "edit_foreign_repo with an unknown id flashes not found", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")
      await_async_loads(view)

      render_click(view, "edit_foreign_repo", %{"repo_id" => "x"})

      # Exact flash contract (asserted on the flash assign — the rendered HTML
      # escapes the apostrophes to &#39;).
      assert assigns(view)[:flash]["error"] == "Repo 'x' not found."
    end

    # Both Save tests mount with an EXPLICIT primary project (plus a stubbed
    # upstream check), so the activation continuation has already made the
    # primary scope stable before the foreign-repo form state is mutated.
    test "save_foreign_repo updates writable/base_sha/description in place", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {repo_path, _head_sha} = git_repo_fixture!(tmp_dir, "repo1")

      # A second commit to use as the updated base_sha
      {_, 0} =
        System.cmd(
          "git",
          [
            "-c",
            "user.email=t@example.com",
            "-c",
            "user.name=t",
            "commit",
            "--allow-empty",
            "-m",
            "second"
          ],
          cd: repo_path,
          stderr_to_stdout: true
        )

      {new_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
      new_sha = String.trim(new_sha)

      stub_github_upstream_check!()
      {:ok, view, _html} = live(conn, ~p"/projects?#{[project: tmp_dir, wb_task: "1"]}")
      assert assigns(view)[:active_project_path] == tmp_dir

      # Add as read-only at HEAD, then save with writable + a new base_sha
      render_click(view, "add_foreign_repo", %{
        "repo_id" => "repo1",
        "path" => repo_path,
        "description" => "the repo"
      })

      render_click(view, "save_foreign_repo", %{
        "repo_id" => "repo1",
        "path" => repo_path,
        "description" => "updated desc",
        "writable" => "true",
        "base_sha" => new_sha
      })

      assert assigns(view)[:flash]["info"] == "Foreign repo 'repo1' updated successfully."

      repos = assigns(view)[:foreign_repos]
      assert length(repos) == 1
      repo = Enum.find(repos, &(&1.id == "repo1"))
      assert %ForeignRepo{writable: true, base_sha: ^new_sha, description: "updated desc"} = repo
      assert assigns(view)[:editing_foreign_repo_id] == nil
      assert assigns(view)[:foreign_repo_edit_form] == nil
    end

    test "save_foreign_repo keeps edit assigns on validation failure", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {repo_path, head_sha} = git_repo_fixture!(tmp_dir, "repo1")
      plain = Path.join(tmp_dir, "plain")
      File.mkdir_p!(plain)

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          File.rm_rf!(plain)
        rescue
          _ -> :ok
        end
      end)

      stub_github_upstream_check!()
      {:ok, view, _html} = live(conn, ~p"/projects?#{[project: tmp_dir, wb_task: "1"]}")
      assert assigns(view)[:active_project_path] == tmp_dir

      render_click(view, "add_foreign_repo", %{
        "repo_id" => "repo1",
        "path" => repo_path,
        "description" => "the repo",
        "base_sha" => head_sha
      })

      render_click(view, "edit_foreign_repo", %{"repo_id" => "repo1"})
      assert assigns(view)[:editing_foreign_repo_id] == "repo1"

      # Point the path at a non-git dir — validation fails, but the edit
      # assigns stay set so the user can fix the value without re-opening.
      html =
        render_click(view, "save_foreign_repo", %{
          "repo_id" => "repo1",
          "path" => plain,
          "description" => "the repo",
          "writable" => "true",
          "base_sha" => head_sha
        })

      assert html =~ "Path is not a git repository: #{plain}"
      assert assigns(view)[:editing_foreign_repo_id] == "repo1"

      assert assigns(view)[:foreign_repo_edit_form] == %{
               description: "the repo",
               writable: false,
               base_sha: head_sha
             }

      # The repo itself is unchanged
      repos = assigns(view)[:foreign_repos]
      assert length(repos) == 1
      assert Enum.any?(repos, &(&1.id == "repo1"))
    end

    test "cancel_edit_foreign_repo clears the edit assigns", %{conn: conn, tmp_dir: tmp_dir} do
      {repo_path, _head_sha} = git_repo_fixture!(tmp_dir, "repo1")
      stub_github_upstream_check!()

      # An explicit primary path prevents deferred VCT auto-activation from
      # replacing the foreign-repo list between Add and Edit.
      {:ok, view, _html} = live(conn, ~p"/projects?#{[project: tmp_dir, wb_task: "1"]}")
      assert assigns(view)[:active_project_path] == tmp_dir
      assert has_element?(view, "#task-form")

      render_click(view, "add_foreign_repo", %{
        "repo_id" => "repo1",
        "path" => repo_path,
        "description" => ""
      })

      render_click(view, "edit_foreign_repo", %{"repo_id" => "repo1"})
      assert assigns(view)[:editing_foreign_repo_id] == "repo1"

      render_click(view, "cancel_edit_foreign_repo", %{})

      assert assigns(view)[:editing_foreign_repo_id] == nil
      assert assigns(view)[:foreign_repo_edit_form] == nil
    end

    # Covers all three restore dimensions in ONE mount (formerly three tests):
    # writable/base_sha restoration, the STRING "true" writable form, and the
    # fact that a previous task carrying an archive still restores its repos.
    test "resume_from restores foreign repos from the previous task (writable + base_sha)", %{
      conn: conn
    } do
      task =
        insert_task_fixture!(
          opts: [
            foreign_repos: [
              %{
                "id" => "orig",
                "root" => "/Source/original-proj",
                "description" => "d",
                "writable" => "true",
                "base_sha" => "abc123"
              }
            ]
          ],
          result: {:ok, %{result: "done", archive_records: [%{"agent_id" => 1}]}}
        )

      {:ok, view, _html} = live(conn, "/projects?resume_from=" <> task.id)

      # The resume override runs in a supervised Task
      # (`start_foreign_repos_restore/2` -> `{:foreign_repos_restored, ...}`), so
      # wait for that result to be applied before reading the assign.
      wait_assigns(view, fn a -> Enum.any?(a[:foreign_repos] || [], &(&1.id == "orig")) end)

      repo = Enum.find(assigns(view)[:foreign_repos], &(&1.id == "orig"))
      assert %ForeignRepo{id: "orig", writable: true, base_sha: "abc123"} = repo
    end
  end

  describe "directory picker" do
    # wx-based directory picker flow (EvoDash.DirectoryPicker + the
    # "directory_pick" event in projects_live.ex). These tests must NEVER
    # invoke real wx — a modal dialog would hang the suite on machines with a
    # display. Safety comes from: (a) the `enabled: false` flag set in
    # test_helper.exs (checked first in pick/2), (b) wx being pruned from the
    # test code path (real picker degrades to unavailable anyway), and (c) the
    # happy path using the injectable fake module.

    test "directory_pick on a remote node pushes unavailable without any picker involvement", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)

      # Proves the remote context is active — the remote branch short-circuits
      # and never touches the picker module (real or fake).
      assert assigns(view)[:current_node] == :"genesis_remote@127.0.0.1"

      render_hook(view, "directory_pick", %{picker_id: "project"})
      assert_push_event(view, "picker_result:project", %{unavailable: true}, async_wait_budget())
    end

    test "remote render never shows the browse button even when tauri is detected", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)

      # Tauri-shell detection is orthogonal to the node context: the desktop
      # app can view a remote node, but the native picker runs on the LOCAL
      # machine, so the open-path palette must hide its browse button (the
      # manual path input stays rendered).
      render_hook(view, "tauri_detected", %{"tauri" => true})
      render_click(view, "open_project_palette", %{})
      html = render_click(view, "palette_mode", %{"mode" => "open_path"})

      assert assigns(view)[:current_node] == :"genesis_remote@127.0.0.1"
      refute html =~ "project-path-browse-button"
      assert html =~ ~s(id="project-path-input")
    end

    test "directory_pick with the fake picker module pushes the picked path", %{conn: conn} do
      original = Application.get_env(:evo_dash, :directory_picker_module)
      Application.put_env(:evo_dash, :directory_picker_module, EvoDash.DirectoryPicker.Fake)

      on_exit(fn ->
        # Restore the prior config so other tests are unaffected.
        if original do
          Application.put_env(:evo_dash, :directory_picker_module, original)
        else
          Application.delete_env(:evo_dash, :directory_picker_module)
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/projects")

      # The fake sends its result synchronously during handle_event; the
      # handle_info-driven push is delivered to the client afterwards.
      render_hook(view, "directory_pick", %{picker_id: "foreign-repo"})

      assert_push_event(
        view,
        "picker_result:foreign-repo",
        %{path: "/fake/picked/dir"},
        async_wait_budget()
      )
    end
  end

  describe "file attach" do
    # Attach-file flow for the objective editor ("file_pick" event + the
    # "objective_file" picker id in projects_live.ex). Same picker machinery as
    # "directory picker", but in :file mode: the picked file's content is read
    # with EvoDash.AttachedFile and appended to the prompt. Uses the injectable
    # fake picker module, which delivers its result synchronously during
    # render_hook so handle_info runs and the pushed event arrives.

    setup do
      on_exit(fn ->
        # Clear the fake's per-test file result so it never leaks across tests.
        EvoDash.DirectoryPicker.Fake.reset()
      end)

      :ok
    end

    test "file_pick with the fake picker appends the file content to the prompt", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      original = Application.get_env(:evo_dash, :directory_picker_module)
      Application.put_env(:evo_dash, :directory_picker_module, EvoDash.DirectoryPicker.Fake)

      on_exit(fn ->
        # Restore the prior config so other tests are unaffected.
        if original do
          Application.put_env(:evo_dash, :directory_picker_module, original)
        else
          Application.delete_env(:evo_dash, :directory_picker_module)
        end
      end)

      file_path = Path.join(tmp_dir, "note.txt")
      File.write!(file_path, "Hello file content")

      EvoDash.DirectoryPicker.Fake.set_file_result({:ok, file_path})

      {:ok, view, _html} = live(conn, ~p"/projects")

      render_hook(view, "file_pick", %{picker_id: "objective_file", prompt: "my base prompt"})

      block = "\n\n---\n## Attached file: note.txt\n\nHello file content\n"
      expected = "my base prompt" <> block

      assert_push_event(
        view,
        "picker_result:objective_file",
        %{
          prompt: ^expected,
          block: ^block,
          attached: true,
          name: "note.txt"
        },
        # The push rides `{:directory_picker_result, ...}` -> `handle_info` ->
        # an off-process read in `EvoDash.TaskSupervisor`, so its 100 ms default
        # is a load assumption, never a correctness bound.
        async_wait_budget()
      )

      assert assigns(view)[:task_prompt] == expected
      # The snapshot base is consumed after the append, proving the snapshot
      # (not the stale @task_prompt) was used as the base.
      assert assigns(view)[:file_pick_bases] == %{}
    end

    test "file_pick with a missing file shows an error flash and keeps the prompt", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      original = Application.get_env(:evo_dash, :directory_picker_module)
      Application.put_env(:evo_dash, :directory_picker_module, EvoDash.DirectoryPicker.Fake)

      on_exit(fn ->
        # Restore the prior config so other tests are unaffected.
        if original do
          Application.put_env(:evo_dash, :directory_picker_module, original)
        else
          Application.delete_env(:evo_dash, :directory_picker_module)
        end
      end)

      missing = Path.join(tmp_dir, "missing.txt")

      EvoDash.DirectoryPicker.Fake.set_file_result({:ok, missing})

      {:ok, view, _html} = live(conn, ~p"/projects")
      before = assigns(view)[:task_prompt]

      render_hook(view, "file_pick", %{picker_id: "objective_file", prompt: "my base prompt"})
      assert_push_event(view, "picker_result:objective_file", %{error: true}, async_wait_budget())

      assert render(view) =~ "Failed to attach file"
      assert assigns(view)[:task_prompt] == before
    end

    test "file_pick cancelled leaves the prompt untouched", %{conn: conn} do
      original = Application.get_env(:evo_dash, :directory_picker_module)
      Application.put_env(:evo_dash, :directory_picker_module, EvoDash.DirectoryPicker.Fake)

      on_exit(fn ->
        # Restore the prior config so other tests are unaffected.
        if original do
          Application.put_env(:evo_dash, :directory_picker_module, original)
        else
          Application.delete_env(:evo_dash, :directory_picker_module)
        end
      end)

      EvoDash.DirectoryPicker.Fake.set_file_result(:cancelled)

      {:ok, view, _html} = live(conn, ~p"/projects")
      before = assigns(view)[:task_prompt]

      render_hook(view, "file_pick", %{picker_id: "objective_file", prompt: "my base prompt"})

      assert_push_event(
        view,
        "picker_result:objective_file",
        %{cancelled: true},
        async_wait_budget()
      )

      refute render(view) =~ "Failed to attach file"
      assert assigns(view)[:task_prompt] == before
    end

    test "file_pick unavailable pushes unavailable", %{conn: conn} do
      original = Application.get_env(:evo_dash, :directory_picker_module)
      Application.put_env(:evo_dash, :directory_picker_module, EvoDash.DirectoryPicker.Fake)

      on_exit(fn ->
        # Restore the prior config so other tests are unaffected.
        if original do
          Application.put_env(:evo_dash, :directory_picker_module, original)
        else
          Application.delete_env(:evo_dash, :directory_picker_module)
        end
      end)

      EvoDash.DirectoryPicker.Fake.set_file_result(:unavailable)

      {:ok, view, _html} = live(conn, ~p"/projects")

      render_hook(view, "file_pick", %{picker_id: "objective_file", prompt: "my base prompt"})

      assert_push_event(
        view,
        "picker_result:objective_file",
        %{unavailable: true},
        async_wait_budget()
      )
    end

    test "file_pick on a remote node pushes unavailable without any picker involvement", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)

      # Proves the remote context is active — the remote branch short-circuits
      # and never touches the picker module (real or fake).
      assert assigns(view)[:current_node] == :"genesis_remote@127.0.0.1"

      render_hook(view, "file_pick", %{picker_id: "objective_file", prompt: "my base prompt"})

      assert_push_event(
        view,
        "picker_result:objective_file",
        %{unavailable: true},
        async_wait_budget()
      )
    end

    test "file_pick_manual with a valid path appends the file content to the prompt", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      file_path = Path.join(tmp_dir, "manual-note.txt")
      File.write!(file_path, "Hello manual file")

      {:ok, view, _html} = live(conn, ~p"/projects")

      render_hook(view, "file_pick_manual", %{
        picker_id: "objective_file",
        path: file_path,
        prompt: "my base prompt"
      })

      block = "\n\n---\n## Attached file: manual-note.txt\n\nHello manual file\n"
      expected = "my base prompt" <> block

      assert_push_event(
        view,
        "picker_result:objective_file",
        %{
          prompt: ^expected,
          block: ^block,
          attached: true,
          name: "manual-note.txt"
        },
        async_wait_budget()
      )

      assert assigns(view)[:task_prompt] == expected
      # The snapshot base is consumed after the append, proving the snapshot
      # (not the stale @task_prompt) was used as the base.
      assert assigns(view)[:file_pick_bases] == %{}
    end

    test "file_pick_manual with an empty path pushes an error and keeps the prompt", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")
      before = assigns(view)[:task_prompt]

      render_hook(view, "file_pick_manual", %{
        picker_id: "objective_file",
        path: "",
        prompt: "my base prompt"
      })

      assert_push_event(
        view,
        "picker_result:objective_file",
        %{
          error: true,
          reason: "Please enter a file path."
        },
        async_wait_budget()
      )

      assert render(view) =~ "Please enter a file path."
      assert assigns(view)[:task_prompt] == before
    end

    test "file_pick_manual with a nil path pushes an error without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")
      before = assigns(view)[:task_prompt]

      render_hook(view, "file_pick_manual", %{
        picker_id: "objective_file",
        path: nil,
        prompt: "my base prompt"
      })

      assert_push_event(
        view,
        "picker_result:objective_file",
        %{
          error: true,
          reason: "Please enter a file path."
        },
        async_wait_budget()
      )

      assert assigns(view)[:task_prompt] == before
    end

    test "file_pick_manual with missing params pushes an error without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      # No path and no picker_id at all — must not crash the LiveView (the
      # handler falls back to @attach_picker_id for the push channel).
      render_hook(view, "file_pick_manual", %{})
      assert_push_event(view, "picker_result:objective_file", %{error: true}, async_wait_budget())
    end

    test "file_pick_manual with a nonexistent file pushes an error and keeps the prompt", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      missing = Path.join(tmp_dir, "missing-manual.txt")

      {:ok, view, _html} = live(conn, ~p"/projects")
      before = assigns(view)[:task_prompt]

      render_hook(view, "file_pick_manual", %{
        picker_id: "objective_file",
        path: missing,
        prompt: "my base prompt"
      })

      assert_push_event(
        view,
        "picker_result:objective_file",
        %{
          error: true,
          reason: "File not found: " <> ^missing
        },
        async_wait_budget()
      )

      assert render(view) =~ "File not found"
      assert assigns(view)[:task_prompt] == before
    end

    # --- Staged image/audio attachment tests (binary attach flow) ---

    test "image pick stages a raw-bytes attachment and pushes the image channel", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      install_fake_picker!()

      png_path = Path.join(tmp_dir, "pic.png")
      png_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>
      File.write!(png_path, png_bytes)

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_staging_project(view, tmp_dir)

      pick_staged(view, "objective_file_image", "image", png_path)

      assert_push_event(
        view,
        "picker_result:objective_file_image",
        %{
          attached: true,
          name: "pic.png",
          kind: "image"
        },
        # Every `picker_result:*` push is an ASYNC handshake: the fake picker
        # sends `{:directory_picker_result, ...}`, the page starts the read in
        # `EvoDash.TaskSupervisor` from its `handle_info`, and only that read's
        # result pushes. The 100 ms default is a load assumption.
        async_wait_budget()
      )

      # Staged entries are STRING-keyed maps; "data" holds the raw binary
      # (server-side only — never rendered, so reading the written bytes back
      # for the comparison is fine).
      assert assigns(view)[:staged_attachments] == [
               %{
                 "type" => "image",
                 "name" => "pic.png",
                 "media_type" => "image/png",
                 "data" => png_bytes
               }
             ]

      # The chip row now renders in the LiveView's re-rendered HTML — both
      # task_form call sites in projects_live.ex forward @staged_attachments.
      # Assert the chip appears with its metadata (basename + one remove
      # button); the raw "data" binary must never leak into the rendered HTML
      # regardless.
      html = render(view)
      doc = Floki.parse_document!(html)

      assert [row] = Floki.find(doc, "div#staged-attachments")
      assert Floki.text(row) =~ "pic.png"

      assert [
               {"button", _, _}
             ] =
               Floki.find(
                 doc,
                 ~s(div#staged-attachments button[phx-click="remove_staged_attachment"])
               )

      refute html =~ Base.encode64(png_bytes)
      refute html =~ png_bytes
    end

    test "audio pick stages symmetric to image on the audio channel", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      install_fake_picker!()

      mp3_path = Path.join(tmp_dir, "note.mp3")
      mp3_bytes = <<255, 251, 144, 64>>
      File.write!(mp3_path, mp3_bytes)

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_staging_project(view, tmp_dir)

      pick_staged(view, "objective_file_audio", "audio", mp3_path)

      assert_push_event(
        view,
        "picker_result:objective_file_audio",
        %{
          attached: true,
          name: "note.mp3",
          kind: "audio"
        },
        async_wait_budget()
      )

      assert assigns(view)[:staged_attachments] == [
               %{
                 "type" => "audio",
                 "name" => "note.mp3",
                 "media_type" => "audio/mpeg",
                 "data" => mp3_bytes
               }
             ]

      # The staged chip row renders in the LiveView's re-rendered HTML (both
      # task_form call sites forward @staged_attachments): the audio chip shows
      # its basename + one remove button, and the raw bytes never leak.
      html = render(view)
      doc = Floki.parse_document!(html)

      assert [row] = Floki.find(doc, "div#staged-attachments")
      assert Floki.text(row) =~ "note.mp3"

      assert length(
               Floki.find(
                 doc,
                 ~s(div#staged-attachments button[phx-click="remove_staged_attachment"])
               )
             ) == 1

      refute html =~ mp3_bytes
    end

    test "remove_staged_attachment removes a staged attachment by index down to empty", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      install_fake_picker!()

      png_path = Path.join(tmp_dir, "pic.png")
      mp3_path = Path.join(tmp_dir, "note.mp3")
      mp3_bytes = <<255, 251, 144, 64>>
      File.write!(png_path, <<137, 80, 78, 71>>)
      File.write!(mp3_path, mp3_bytes)

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_staging_project(view, tmp_dir)

      pick_staged(view, "objective_file_image", "image", png_path)

      assert_push_event(
        view,
        "picker_result:objective_file_image",
        %{attached: true},
        async_wait_budget()
      )

      pick_staged(view, "objective_file_audio", "audio", mp3_path)

      assert_push_event(
        view,
        "picker_result:objective_file_audio",
        %{attached: true},
        async_wait_budget()
      )

      assert length(assigns(view)[:staged_attachments]) == 2

      # Removing index 0 drops the image and keeps the audio.
      render_hook(view, "remove_staged_attachment", %{"index" => "0"})

      assert assigns(view)[:staged_attachments] == [
               %{
                 "type" => "audio",
                 "name" => "note.mp3",
                 "media_type" => "audio/mpeg",
                 "data" => mp3_bytes
               }
             ]

      # The chip row tracks removals in the LiveView's re-rendered HTML (both
      # task_form call sites forward @staged_attachments): after dropping the
      # image, only the audio chip remains.
      html = render(view)
      doc = Floki.parse_document!(html)

      assert [row] = Floki.find(doc, "div#staged-attachments")
      assert Floki.text(row) =~ "note.mp3"
      refute Floki.text(row) =~ "pic.png"

      # Removing the remaining index 0 empties the staged list.
      render_hook(view, "remove_staged_attachment", %{"index" => "0"})
      assert assigns(view)[:staged_attachments] == []

      # With nothing staged the whole chip row disappears from the HTML.
      refute render(view) =~ "staged-attachments"
      assert Floki.find(Floki.parse_document!(render(view)), "div#staged-attachments") == []
    end

    test "staging a 5th attachment is rejected by the per-task count cap", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      install_fake_picker!()

      png_path = Path.join(tmp_dir, "pic.png")
      File.write!(png_path, <<137, 80, 78, 71>>)

      {:ok, view, _html} = live(conn, ~p"/projects")

      # Four identical valid image picks reach the cap. Each pick's push is
      # consumed so the staged assign is settled before the next pick.
      for _ <- 1..4 do
        pick_staged(view, "objective_file_image", "image", png_path)

        assert_push_event(
          view,
          "picker_result:objective_file_image",
          %{attached: true},
          async_wait_budget()
        )
      end

      assert length(assigns(view)[:staged_attachments]) == 4

      # The count-cap check runs BEFORE the file is read, so a 5th pick fails
      # fast and the staged list stays at 4.
      pick_staged(view, "objective_file_image", "image", png_path)

      assert_push_event(
        view,
        "picker_result:objective_file_image",
        %{error: true},
        async_wait_budget()
      )

      assert render(view) =~ "Maximum of 4 attachments per task"
      assert length(assigns(view)[:staged_attachments]) == 4
    end

    test "image pick with an unsupported extension shows an error flash and stages nothing", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      install_fake_picker!()

      txt_path = Path.join(tmp_dir, "notes.txt")
      File.write!(txt_path, "plain text is not an image")

      {:ok, view, _html} = live(conn, ~p"/projects")

      pick_staged(view, "objective_file_image", "image", txt_path)

      assert_push_event(
        view,
        "picker_result:objective_file_image",
        %{error: true},
        async_wait_budget()
      )

      assert render(view) =~ "Unsupported file type for attachment: .txt"
      assert assigns(view)[:staged_attachments] == []
    end

    test "image pick with an oversized file shows an error flash and stages nothing", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      install_fake_picker!()

      big_path = Path.join(tmp_dir, "huge.png")
      # SPARSE file of the same logical size: the size cap is enforced on the
      # BYTES READ, so a 15 MiB+1 hole reads back as zeros — writing 15 MiB of
      # real bytes here only cost wall clock.
      {:ok, fd} = File.open(big_path, [:write, :binary])
      {:ok, _} = :file.position(fd, 15 * 1024 * 1024)
      :ok = IO.binwrite(fd, <<0>>)
      :ok = File.close(fd)
      assert File.stat!(big_path).size == 15 * 1024 * 1024 + 1

      {:ok, view, _html} = live(conn, ~p"/projects")

      pick_staged(view, "objective_file_image", "image", big_path)

      assert_push_event(
        view,
        "picker_result:objective_file_image",
        %{error: true},
        async_wait_budget()
      )

      assert render(view) =~ "File is too large (max 15 MiB)"
      assert assigns(view)[:staged_attachments] == []
    end

    test "file_pick_manual with kind image stages the file like the native pick", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      png_path = Path.join(tmp_dir, "pic.png")
      png_bytes = <<137, 80, 78, 71>>
      File.write!(png_path, png_bytes)

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_staging_project(view, tmp_dir)

      # The manual fallback routes through the same handle_binary_attach_result
      # pipeline, so the push payload is identical to the native pick's.
      render_hook(view, "file_pick_manual", %{
        picker_id: "objective_file_image",
        path: png_path,
        prompt: "x",
        kind: "image"
      })

      assert_push_event(
        view,
        "picker_result:objective_file_image",
        %{
          attached: true,
          name: "pic.png",
          kind: "image"
        },
        # Every `picker_result:*` push is an ASYNC handshake: the fake picker
        # sends `{:directory_picker_result, ...}`, the page starts the read in
        # `EvoDash.TaskSupervisor` from its `handle_info`, and only that read's
        # result pushes. The 100 ms default is a load assumption.
        async_wait_budget()
      )

      assert assigns(view)[:staged_attachments] == [
               %{
                 "type" => "image",
                 "name" => "pic.png",
                 "media_type" => "image/png",
                 "data" => png_bytes
               }
             ]

      # The manual fallback routes through the same handle_binary_attach_result
      # pipeline, so the staged chip row renders in the LiveView's re-rendered
      # HTML too (both task_form call sites forward @staged_attachments).
      html = render(view)
      doc = Floki.parse_document!(html)

      assert [row] = Floki.find(doc, "div#staged-attachments")
      assert Floki.text(row) =~ "pic.png"

      assert length(
               Floki.find(
                 doc,
                 ~s(div#staged-attachments button[phx-click="remove_staged_attachment"])
               )
             ) == 1
    end

    test "image pick with a missing file shows the file-not-found error flash", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      install_fake_picker!()

      missing = Path.join(tmp_dir, "missing.png")

      {:ok, view, _html} = live(conn, ~p"/projects")

      pick_staged(view, "objective_file_image", "image", missing)

      assert_push_event(
        view,
        "picker_result:objective_file_image",
        %{error: true},
        async_wait_budget()
      )

      assert render(view) =~ "File not found:"
      assert assigns(view)[:staged_attachments] == []
    end
  end

  describe "custom agent selection" do
    setup do
      clear_projects()

      # The module-level set_onboarding_completed already activates a per-test
      # config-dir override, so agents.toml lands in a temp dir.
      {:ok, _agent} =
        EvoGit.CustomAgents.save(%{
          name: "Bug Hunter",
          prompt: "You hunt bugs in code.",
          id: "my-agent"
        })

      # Bust the ModelSelector persistent_term cache so the new file is seen.
      EvoGit.CustomAgents.reload()
      :ok
    end

    test "renders the agent select with Auto (recommended) + agent name", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      # No project open → controls row hidden; open one so the select renders.
      html = open_project!(view, tmp_dir)

      assert html =~ ~s(name="agent")
      assert html =~ "Auto (recommended)"
      assert html =~ "Bug Hunter"
    end

    test "select_agent updates the assign and marks the option selected", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)

      assert assigns(view)[:selected_agent_id] == nil

      html = render_change(view, "select_agent", %{"agent" => "my-agent"})

      assert assigns(view)[:selected_agent_id] == "my-agent"
      assert html =~ ~s(<option value="my-agent" selected)
    end

    test "renders the Custom Agent mode option", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)

      # 4th mode option next to genesis_new / genesis_existing / evolve_simple.
      assert render(view) =~ "Custom Agent"
    end

    test "task_change to custom_agent auto-selects the first custom agent", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)
      # `selected_agent_id == "my-agent"` below needs `@custom_agents` to have
      # been seeded by the mount's async batch — await it, exactly like the
      # `evolve_simple` sibling.
      await_async_loads(view)

      assert assigns(view)[:selected_agent_id] == nil

      html = render_change(view, "task_change", %{"mode" => "custom_agent"})

      assert assigns(view)[:task_mode] == "custom_agent"
      assert assigns(view)[:selected_agent_id] == "my-agent"
      assert html =~ ~s(<option value="my-agent" selected)

      # The Auto option is hidden in custom mode (an agent MUST be chosen).
      refute html =~ "Auto (recommended)"
    end

    test "task_change to evolve_simple keeps the previously selected agent", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)
      await_async_loads(view)

      render_change(view, "select_agent", %{"agent" => "my-agent"})
      render_change(view, "task_change", %{"mode" => "evolve_simple"})

      assert assigns(view)[:task_mode] == "evolve_simple"
      assert assigns(view)[:selected_agent_id] == "my-agent"
    end

    test "custom_agent submit without a selected agent flashes an error and starts nothing", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)

      # Submit DIRECTLY (no task_change first — it would auto-select the first
      # agent) so the selected_agent_id assign is still nil.
      html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "do it",
          mode: "custom_agent",
          node_path: "./nonexistent-dir"
        })

      assert html =~ "Custom Agent mode requires selecting a custom agent."
      refute html =~ "task started with ID:"
    end

    test "custom_agent mode persists/restores across form state", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)

      # Simulate a sessionStorage restore on reload: the node gate passes and
      # the already-active project skips activate_project's mode re-detection,
      # so the persisted custom_agent choice survives.
      render_hook(view, "restore_state", %{
        "node" => "local",
        "task_mode" => "custom_agent",
        "selected_agent_id" => "my-agent",
        "project" => tmp_dir
      })

      assert assigns(view)[:task_mode] == "custom_agent"
      assert assigns(view)[:selected_agent_id] == "my-agent"
    end
  end

  describe "task submit guards" do
    setup do
      clear_projects()
      :ok
    end

    test "repo mode submit without a project is still blocked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      refute has_element?(view, "#task-form")

      html =
        render_submit(view, "task_submit", %{
          "prompt" => "build me a thing",
          "mode" => "evolve_simple"
        })

      assert html =~ "No project selected. Please open a project first."
      refute html =~ "task started with ID:"
    end
  end

  describe "custom agents — none configured" do
    setup do
      clear_projects()
      :ok
    end

    test "agent select is absent", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      html = open_project!(view, tmp_dir)

      refute html =~ ~s(name="agent")
      refute html =~ "Auto (recommended)"
    end
  end

  describe "node-aware provider/model picker" do
    setup do
      clear_projects()
      write_provider_profile_config()
      :ok
    end

    test "a pending remote target never borrows local providers or consumes its saved picker", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager, {id, %{phase: :connecting, node: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)
      await_async_loads(view)

      assert assigns(view)[:remote?] == false
      assert assigns(view)[:current_node_id] == id
      assert assigns(view)[:model_selection] == nil
      assert assigns(view)[:provider_profiles] == []
      assert assigns(view)[:selected_model_spec] == nil

      saved = %{"provider_profile_id" => "remote-account", "model" => "remote-model"}
      render_hook(view, "restore_state", %{"node" => id, "model_spec" => saved})
      assert assigns(view)[:pending_model_selection] == saved

      # Even a current-generation local result cannot validate a remote restore
      # while the target is connecting. This must not consume or clear it.
      data = EvoDashWeb.ProjectsLive.Project.load_model_selection(node(), false)
      cur = assigns(view)

      send(
        view.pid,
        {:async_project_load, node(), id, cur[:active_project_path],
         %{
           model_selection: data,
           load_scope: %{seq: cur[:projects_load_seq], node_id: id, selection: saved}
         }}
      )

      assert assigns(view)[:pending_model_selection] == saved
      assert assigns(view)[:model_selection] == nil
      assert assigns(view)[:provider_profiles] == []
      assert assigns(view)[:selected_model_spec] == nil
    end

    test "an unreachable connected remote stays unavailable and preserves its saved selection", %{
      conn: conn
    } do
      id = save_target!()

      start_supervised!(
        {EvoDashWeb.ProjectsLiveTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      {:ok, view, _html} = live(conn, "/projects?node=" <> id)
      await_async_loads(view)

      # The fake node cannot answer :erpc. Its failed config read must not
      # silently fall back to account-a on the dashboard host.
      assert assigns(view)[:remote?] == true
      assert assigns(view)[:provider_profiles] == []
      assert assigns(view)[:model_selections] == []
      assert assigns(view)[:selected_model_spec] == nil
      assert assigns(view)[:model_selection] == nil
      assert assigns(view)[:model_selection_ready?] == false
      assert assigns(view)[:model_selection_error] != nil
      refute render(view) =~ "Auto (by rules)"

      saved = %{"provider_profile_id" => "remote-account", "model" => "remote-model"}
      render_hook(view, "restore_state", %{"node" => id, "model_spec" => saved})
      assert assigns(view)[:pending_model_selection] == saved
      assert assigns(view)[:selected_model_spec] == nil

      # A further failed read cannot consume the pending explicit choice or
      # turn it into Auto; only an owned, successful remote bundle can do that.
      cur = assigns(view)

      send(
        view.pid,
        {:async_project_load, cur[:current_node], id, cur[:active_project_path],
         %{
           model_selection: {:error, :unavailable},
           load_scope: %{seq: cur[:projects_load_seq], node_id: id, selection: saved}
         }}
      )

      assert assigns(view)[:pending_model_selection] == saved
      assert assigns(view)[:selected_model_spec] == nil
      assert assigns(view)[:model_selection_error] == :unavailable

      # Recovery must be owned by the genuine remote BEAM and target, not an
      # unstamped local bundle. The saved choice is consumed only on success.
      bundle =
        EvoDashWeb.ProjectsLive.Project.load_model_selection_from_config(
          %{
            llm: %{
              default_provider_profile: "remote-account",
              providers: [
                %{
                  "id" => "remote-account",
                  "provider" => "anthropic",
                  "default_model" => "remote-model",
                  "models" => [%{"model" => "remote-model"}]
                }
              ]
            }
          },
          false
        )

      send(
        view.pid,
        {:async_project_load, cur[:current_node], id, cur[:active_project_path],
         %{
           model_selection: bundle,
           load_scope: %{seq: cur[:projects_load_seq], node_id: id, selection: saved}
         }}
      )

      assert assigns(view)[:selected_model_spec] == saved
      assert assigns(view)[:pending_model_selection] == nil
      assert assigns(view)[:model_selection_scope] == {id, cur[:current_node]}
      assert assigns(view)[:model_selection_ready?] == true
      assert assigns(view)[:model_selection_error] == nil
      assert_push_event(view, "persist_model_selection", %{model_spec: ^saved, node: ^id})

      # A subsequent unavailable refresh must preserve the now-selected value
      # as well as the pending-restore value exercised above.
      send(
        view.pid,
        {:async_project_load, cur[:current_node], id, cur[:active_project_path],
         %{
           model_selection: {:error, :unavailable},
           load_scope: %{seq: cur[:projects_load_seq], node_id: id, selection: saved}
         }}
      )

      assert assigns(view)[:selected_model_spec] == saved
      assert assigns(view)[:model_selection_ready?] == false
      assert assigns(view)[:model_selection_error] == :unavailable
    end

    test "canonical picker events persist exact fields and restore only within their node", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")
      await_async_loads(view)
      open_project!(view, tmp_dir)
      await_async_loads(view)

      assert assigns(view)[:selected_model_spec] == %{
               "provider_profile_id" => "account-a",
               "model" => "claude-sonnet-5",
               "reasoning_effort" => "low"
             }

      render_change(view, "select_model", %{"model" => "claude-opus-5"})
      assert assigns(view)[:selected_model_spec]["reasoning_effort"] == "high"
      render_change(view, "select_reasoning_effort", %{"reasoning_effort" => "0"})

      spec = %{
        "provider_profile_id" => "account-a",
        "model" => "claude-opus-5",
        "reasoning_effort" => "low"
      }

      assert assigns(view)[:selected_model_spec] == spec

      assert_push_event(
        view,
        "persist_model_selection",
        %{model_spec: ^spec, node: "local"} = persisted
      )

      refute Map.has_key?(persisted, :selected_model_id)
      refute Map.has_key?(persisted, :model_selection)
      refute Map.has_key?(persisted, :provider_profiles)
      refute Map.has_key?(persisted, :api_key_env_var)

      # Invalid upstream/downstream values leave the current selection intact.
      for {event, params} <- [
            {"select_provider_profile", %{"provider_profile_id" => "missing"}},
            {"select_model", %{"model" => "missing"}},
            {"select_reasoning_effort", %{"reasoning_effort" => "99"}}
          ] do
        render_change(view, event, params)
        assert assigns(view)[:selected_model_spec] == spec
      end

      render_hook(view, "restore_state", %{"node" => "other-target", "model_spec" => %{}})
      assert assigns(view)[:selected_model_spec] == spec

      # Canonical state wins over a stale legacy id, including explicit Auto.
      render_hook(view, "restore_state", %{
        "node" => "local",
        "model_spec" => %{},
        "selected_model_id" => "account-a"
      })

      assert assigns(view)[:selected_model_spec] == %{}
      auto = %{}
      assert_push_event(view, "persist_model_selection", %{model_spec: ^auto, node: "local"})

      render_hook(view, "restore_state", %{"node" => "local", "model_spec" => spec})
      assert assigns(view)[:selected_model_spec] == spec
      assert_push_event(view, "persist_model_selection", %{model_spec: ^spec, node: "local"})

      # Node, target id, path and generation guards are exercised through the
      # mounted page's actual result handler, not direct socket mutations.
      cur = assigns(view)
      bundle = cur[:model_selection]
      scope = %{seq: cur[:projects_load_seq], node_id: nil, selection: spec}
      changed_bundle = Map.put(bundle, :config, %{})

      for {message_node, path, stamp} <- [
            {:"stale@127.0.0.1", tmp_dir, scope},
            {node(), tmp_dir, %{scope | node_id: "other-target"}},
            {node(), tmp_dir, %{scope | seq: scope.seq - 1}},
            {node(), tmp_dir <> "/stale", scope}
          ] do
        send(
          view.pid,
          {:async_project_load, message_node, nil, path,
           %{model_selection: changed_bundle, load_scope: stamp}}
        )

        assert assigns(view)[:model_selection] == bundle
        assert assigns(view)[:selected_model_spec] == spec
      end

      # A matching but delayed load also cannot undo a more recent Auto click.
      render_change(view, "select_provider_profile", %{"provider_profile_id" => ""})

      send(
        view.pid,
        {:async_project_load, node(), nil, tmp_dir, %{model_selection: bundle, load_scope: scope}}
      )

      assert assigns(view)[:selected_model_spec] == %{}
    end
  end

  describe "config-change driven model picker reload" do
    setup do
      clear_projects()
      :ok
    end

    # REGRESSION: a config written by Settings/CLI/MCP/another tab used to be
    # invisible to an already-mounted task form — the picker stayed in
    # "Loading models…" (`ready? == false` with no error) until a remount. The
    # page now subscribes to the core's `"config"` topic and re-runs the SAME
    # scoped batch, so the write reaches the live page.
    test "a config reload on the viewed node refreshes the picker without a remount", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      # The per-test isolated config dir holds NO provider profile yet: the
      # picker loads successfully but has nothing to offer.
      # `wb_task=1`: the composer owns the picker controls asserted below.
      {:ok, view, _html} = live(conn, ~p"/projects?#{[project: tmp_dir, wb_task: "1"]}")
      await_async_loads(view)

      assert assigns(view)[:model_selection_ready?] == true
      assert assigns(view)[:model_selection_error] == nil
      assert assigns(view)[:model_selections] == []
      assert assigns(view)[:provider_profiles] == []
      assert assigns(view)[:config_generation] == nil
      assert has_element?(view, "#task-model-setup")
      refute has_element?(view, "#model-selection-loading")

      # Write the account the way a Settings save does, then raise the SAME
      # event the core raises on a content-fingerprint change: the snapshot is
      # re-read from disk and `{:config_reloaded, node, dir, generation}` is
      # broadcast on `"config"` (the mount's read built snapshot generation 1).
      write_provider_profile_config()
      config_dir = EvoGit.Config.config_dir()
      assert %{generation: generation} = EvoGit.Config.Cache.reload()
      assert generation > 1

      # No remount: the broadcast alone re-runs the batch and re-renders.
      wait_assigns(view, fn assigns ->
        assigns[:config_generation] == {config_dir, generation}
      end)

      wait_assigns(view, fn assigns -> assigns[:model_selections] != [] end)

      assert [
               %{
                 provider_profile_id: "account-a",
                 provider: "anthropic",
                 model: "claude-sonnet-5"
               }
               | _
             ] = assigns(view)[:model_selections]

      assert [%{"id" => "account-a", "provider" => "anthropic"} | _] =
               assigns(view)[:provider_profiles]

      assert assigns(view)[:model_selection_ready?] == true
      assert assigns(view)[:model_selection_error] == nil
      assert assigns(view)[:model_selection_scope] == {nil, node()}

      # The launchable bundle the task form submits from now carries the new
      # account's inventory. The picker STATE stays the Auto snapshot the
      # mount reconciled to (there was no inventory to select from then) — a
      # refresh never overwrites a live selection.
      assert {:ok, bundle} = EvoDashWeb.ProjectsLive.ModelSelectionScope.bundle(assigns(view))
      assert [%{provider_profile_id: "account-a"} | _] = bundle.model_selections
      assert assigns(view)[:selected_model_spec] == %{}

      # The form left its "no model configured" state without a remount.
      refute has_element?(view, "#model-selection-loading")
      refute has_element?(view, "#task-model-setup")
      await_async_loads(view)
    end

    # The guards around the reload: a repeat/older generation, a foreign BEAM
    # node and a pending remote target must NOT pile up loads. Driven through
    # the public `handle_info/2` on a hand-built LOCAL socket so no other
    # mounted page can observe the message (the topic is globally broadcast, a
    # direct call is not), and proven structurally: a spawn ALWAYS bumps
    # `projects_load_seq` (and records `config_generation`), so an unchanged
    # socket is conclusive evidence that nothing was started.
    test "a config reload is ignored for a repeat or older generation and for another node" do
      config_dir = EvoGit.Config.config_dir()
      bundle = EvoDashWeb.ProjectsLive.Project.load_model_selection_from_config(%{}, false)

      test_pid = self()

      install_reporting_async_load_runner(fn ->
        if test_pid in (Process.get(:"$callers") || []) do
          send(test_pid, {:config_batch_ran, self()})
        end

        %{
          custom_agents: [],
          projects: [],
          terminal_ids: nil,
          auto_activate?: false,
          model_selection: bundle
        }
      end)

      # A load generation ALREADY in flight, taken from the same monotonic
      # counter the page allocates from: the assertion below then proves a
      # spawn happened (a fresh integer is strictly greater) without depending
      # on how many spawns earlier tests in this run happened to make.
      in_flight_seq = System.unique_integer([:positive, :monotonic])

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          current_node: node(),
          current_node_id: nil,
          active_project_path: "/repo/a",
          remote?: false,
          projects: [],
          projects_load_seq: in_flight_seq,
          notified_task_ids_ready?: true,
          auto_activate_candidate?: false,
          config_generation: {config_dir, 4},
          model_selection: bundle,
          model_selection_scope: {nil, node()},
          model_selection_ready?: true,
          model_selection_error: nil,
          selected_model_spec: %{}
        },
        transport_pid: self()
      }

      for message <- [
            # A repeat of the generation already handled.
            {:config_reloaded, node(), config_dir, 4},
            # An older generation for the same dir.
            {:config_reloaded, node(), config_dir, 3},
            # A broadcast from another BEAM (a remote target's own config).
            {:config_reloaded, :"genesis_remote@127.0.0.1", config_dir, 5}
          ] do
        assert {:noreply, ^socket} = EvoDashWeb.ProjectsLive.handle_info(message, socket)
      end

      # A strictly NEWER generation spawns exactly one batch and records it, so
      # a repeat of that same generation can never spawn again.
      assert {:noreply, updated} =
               EvoDashWeb.ProjectsLive.handle_info(
                 {:config_reloaded, node(), config_dir, 5},
                 socket
               )

      assert updated.assigns.config_generation == {config_dir, 5}
      assert updated.assigns.projects_load_seq > socket.assigns.projects_load_seq
      assert updated.assigns.model_selection_ready? == false
      assert updated.assigns.model_selection_error == nil
      assert_receive :load_config_status, async_wait_budget()
      assert is_pid(await_view_batch(self()))

      assert_receive {:async_project_load, local, nil, "/repo/a",
                      %{load_scope: %{seq: seq, node_id: nil}}},
                     async_wait_budget()

      assert local == node()
      assert seq == updated.assigns.projects_load_seq
      assert_receive {:config_batch_ran, _task}, async_wait_budget()

      # The repeat of the accepted generation is dropped by the unchanged
      # `config_generation` — no second batch starts. (`^updated` above is the
      # conclusive witness; the refute is caller-scoped so another async
      # module's page sharing the seam can never make it flake.)
      assert {:noreply, ^updated} =
               EvoDashWeb.ProjectsLive.handle_info(
                 {:config_reloaded, node(), config_dir, 5},
                 updated
               )

      refute_received {:config_batch_ran, _task}
    end

    # A connecting/disconnected remote target (and an unresolved connection
    # gate) owns its own UX: a batch spawned then would be dropped by the
    # pending guard anyway, so the reload must not consume the saved picker.
    test "a pending remote target never lets the reload consume its saved picker" do
      config_dir = EvoGit.Config.config_dir()
      bundle = EvoDashWeb.ProjectsLive.Project.load_model_selection_from_config(%{}, false)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          current_node: node(),
          current_node_id: "target-a",
          remote_status: %{phase: :connecting},
          active_project_path: "/remote/repo",
          remote?: false,
          projects: [],
          projects_load_seq: 4,
          notified_task_ids_ready?: true,
          auto_activate_candidate?: false,
          config_generation: nil,
          model_selection: bundle,
          model_selection_scope: {nil, node()},
          model_selection_ready?: true,
          model_selection_error: nil,
          selected_model_spec: %{}
        },
        transport_pid: self()
      }

      assert {:noreply, ^socket} =
               EvoDashWeb.ProjectsLive.handle_info(
                 {:config_reloaded, node(), config_dir, 2},
                 socket
               )
    end

    # `handle_params/3` skips its batch while `workbench_project_selection` is
    # set (the activation owns it), so the `{:registered, ...}` continuation
    # must spawn the batch ITSELF — and keep the selection in place for the
    # render's project fallback.
    test "an async project registration spawns the batch while its selection is pending" do
      selection = %{target: node(), requested_path: "/repo/a", path: "/repo/a"}

      install_reporting_async_load_runner(fn ->
        %{
          custom_agents: [],
          projects: [],
          terminal_ids: nil,
          auto_activate?: false,
          model_selection:
            EvoDashWeb.ProjectsLive.Project.load_model_selection_from_config(%{}, false)
        }
      end)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: nil,
          current_node: node(),
          current_node_id: nil,
          active_project_path: "/repo/a",
          remote?: false,
          projects: [],
          projects_load_seq: 4,
          notified_task_ids_ready?: true,
          auto_activate_candidate?: false,
          workbench_project_selection: selection,
          model_selection: nil,
          model_selection_ready?: true,
          model_selection_error: nil,
          selected_model_spec: nil
        },
        transport_pid: self()
      }

      assert {:noreply, updated} =
               EvoDashWeb.ProjectsLive.handle_async(
                 :workbench_project_selection,
                 {:ok, {:registered, []}},
                 socket
               )

      # The selection STAYS set: the render's workbench project fallback reads
      # its `.path`, and a later handle_params run clears it on a mismatch.
      assert updated.assigns.workbench_project_selection == selection
      assert updated.assigns.projects == []
      assert updated.assigns.projects_load_seq > socket.assigns.projects_load_seq
      assert updated.assigns.model_selection_ready? == false

      task_pid = await_view_batch(self())
      assert task_pid != self()

      assert_receive {:async_project_load, local, nil, "/repo/a", %{load_scope: scope}},
                     async_wait_budget()

      assert local == node()
      assert scope.seq == updated.assigns.projects_load_seq
      assert scope.node_id == nil
    end
  end

  describe "GitHub issue integration" do
    # All three async GitHub runners (resolved from application env at spawn
    # time by EvoDashWeb.ProjectsLive.GitHub) are stubbed for every test in
    # this block so the real gh/git adapters are NEVER reachable — a project
    # activation without a stubbed :github_runner would shell out to git/gh.
    # Individual tests override the runners they exercise via
    # put_github_seams/1.

    setup do
      clear_projects()

      put_github_seams([])

      :ok
    end

    test "hides the GitHub button when the upstream check fails", %{conn: conn, tmp_dir: tmp_dir} do
      make_evolve_project(tmp_dir)

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_project(view, tmp_dir)

      # The default :github_runner stub resolves to {:error, :no_github_upstream}.
      github_status(view, :error)

      html = render(view)

      # The status resolved to :error — no GitHub button, no owner/repo text.
      refute html =~ "open_github_issues"
      refute html =~ "acme/widgets"
    end

    test "hides the GitHub button when gh is unavailable", %{conn: conn, tmp_dir: tmp_dir} do
      make_evolve_project(tmp_dir)

      put_github_seams(
        github_runner: fn _node, _path ->
          {:ok,
           %{
             owner: "acme",
             repo: "widgets",
             gh_available: false,
             url: "https://github.com/acme/widgets"
           }}
        end
      )

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_project(view, tmp_dir)

      # A resolved upstream with gh_available: false is treated as :error.
      github_status(view, :error)

      html = render(view)

      refute html =~ "open_github_issues"
      refute html =~ "acme/widgets"
    end

    test "shows the GitHub entry point in the Git pane with owner/repo when the upstream resolves",
         %{
           conn: conn,
           tmp_dir: tmp_dir
         } do
      make_evolve_project(tmp_dir)

      put_github_seams(github_runner: ok_upstream_runner())

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_project(view, tmp_dir)

      github_status(view, :ok)

      html = render(view)

      assert html =~ "open_github_issues"
      assert html =~ "acme/widgets"
      # The issues entry point belongs to the Git pane's GitHub block — the
      # task-form toolbar no longer carries a GitHub button.
      assert has_element?(
               view,
               "#workbench-git-content [phx-click=open_github_issues]"
             )
    end

    test "opens the issues modal and renders the issue list", %{conn: conn, tmp_dir: tmp_dir} do
      make_evolve_project(tmp_dir)

      put_github_seams(
        github_runner: ok_upstream_runner(),
        github_issues_runner: fn _node, _path, _opts ->
          {:ok,
           [
             %{
               number: 42,
               title: "Fix the thing",
               state: "open",
               labels: ["bug"],
               url: "https://github.com/acme/widgets/issues/42",
               author: "octocat",
               created_at: "2026-08-01T10:00:00Z"
             }
           ]}
        end
      )

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_project(view, tmp_dir)
      github_status(view, :ok)

      html = render_click(view, "open_github_issues", %{})

      # The modal opens immediately (loading state) while the list is fetched.
      assert html =~ "github-issues-modal"

      wait_until(view, fn a -> a[:github_issues].status == :ok end)
      html = render(view)

      # Issue number, title, state badge, label badge, author + created date,
      # and the external GitHub link.
      assert html =~ "#42"
      assert html =~ "Fix the thing"
      assert html =~ ~r/class="badge badge-sm shrink-0 badge-success">\s*Open\s*<\/span>/s
      assert html =~ ~s(class="badge badge-outline badge-xs">bug</span>)
      assert html =~ "https://github.com/acme/widgets/issues/42"
      assert html =~ "octocat"
      assert html =~ "2026-08-01"
      # State filter buttons (open/closed/all) render alongside the list.
      assert html =~ "Closed"
      assert html =~ "All"
    end

    test "surfaces the gh CLI error message in the modal", %{conn: conn, tmp_dir: tmp_dir} do
      make_evolve_project(tmp_dir)

      put_github_seams(
        github_runner: ok_upstream_runner(),
        github_issues_runner: fn _node, _path, _opts ->
          {:error, {:gh, 1, "gh auth login required"}}
        end
      )

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_project(view, tmp_dir)
      github_status(view, :ok)

      render_click(view, "open_github_issues", %{})

      wait_until(view, fn a -> a[:github_issues].status == :error end)
      html = render(view)

      assert html =~ "github-issues-modal"
      assert html =~ "gh auth login required"
    end

    test "shows the empty state when there are no open issues", %{conn: conn, tmp_dir: tmp_dir} do
      make_evolve_project(tmp_dir)

      put_github_seams(github_runner: ok_upstream_runner())

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_project(view, tmp_dir)
      github_status(view, :ok)

      render_click(view, "open_github_issues", %{})

      wait_until(view, fn a -> a[:github_issues].status == :ok end)
      html = render(view)

      assert html =~ "No open issues"
    end

    test "filtering re-fetches the issue list with the new state", %{conn: conn, tmp_dir: tmp_dir} do
      make_evolve_project(tmp_dir)

      test_pid = self()

      put_github_seams(
        github_runner: ok_upstream_runner(),
        github_issues_runner: fn _node, _path, opts ->
          state = Keyword.get(opts, :state)
          send(test_pid, {:issues_runner_opts, opts})

          {:ok,
           [
             %{
               number: 1,
               title: "Issue for #{state}",
               state: "open",
               labels: [],
               url: "https://github.com/acme/widgets/issues/1",
               author: "",
               created_at: "2026-01-01T00:00:00Z"
             }
           ]}
        end
      )

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_project(view, tmp_dir)
      github_status(view, :ok)

      render_click(view, "open_github_issues", %{})
      wait_until(view, fn a -> a[:github_issues].status == :ok end)

      # The default filter is "open" — the runner receives it as an opt.
      assert_received {:issues_runner_opts, [state: "open"]}
      assert render(view) =~ "Issue for open"

      render_click(view, "github_filter_state", %{"state" => "closed"})

      wait_until(view, fn a ->
        a[:github_issues].state_filter == "closed" and a[:github_issues].status == :ok
      end)

      assert_received {:issues_runner_opts, [state: "closed"]}

      html = render(view)
      assert html =~ "Issue for closed"
      refute html =~ "Issue for open"
    end

    test "Fix failure flashes the surfaced error and keeps the modal open", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      make_evolve_project(tmp_dir)

      put_github_seams(
        github_runner: ok_upstream_runner(),
        github_issues_runner: fn _node, _path, _opts ->
          {:ok,
           [
             %{
               number: 7,
               title: "Broken issue",
               state: "open",
               labels: [],
               url: "https://github.com/acme/widgets/issues/7",
               author: "",
               created_at: "2026-01-01T00:00:00Z"
             }
           ]}
        end,
        github_issue_markdown_runner: fn _node, _path, _number -> {:error, :gh_not_available} end
      )

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_project(view, tmp_dir)
      github_status(view, :ok)

      render_click(view, "open_github_issues", %{})
      wait_until(view, fn a -> a[:github_issues].status == :ok end)

      render_click(view, "github_fix_issue", %{"number" => "7"})

      # handle_fix_result clears :github_fixing on the error path.
      wait_until(view, fn a -> a[:github_fixing] == nil end)

      html = render(view)

      # :gh_not_available falls back to the generic error message.
      assert html =~ "Could not load GitHub issues"
      # The modal stays open so the user can retry.
      assert html =~ "github-issues-modal"
      assert assigns(view)[:github_modal_open] == true
    end
  end

  # Speed ↔ quality capsule control — the 3-step control on the task form's
  # bottom toolbar (#mode-speed-capsule, component-side markup contract is
  # covered in task_form_components_test.exs). Projectslive owns the assign
  # (@quality_level, default "balanced"), the whitelisted select_quality_level
  # event, and the submit threading: do_task_submit/4 adds the :quality_level
  # task opt ONLY for "fast"/"high_quality" — "balanced" (the default) adds NO
  # key, so the untouched case keeps the task opts byte-identical to before.
  describe "speed ↔ quality control" do
    setup do
      clear_projects()
      :ok
    end

    test "select_quality_level updates the assign and moves the active step", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      html = open_project!(view, tmp_dir)

      # Default state: the middle (balanced) step is the active one.
      assert assigns(view)[:quality_level] == "balanced"
      assert quality_step_active?(html, "balanced")
      refute quality_step_active?(html, "fast")
      refute quality_step_active?(html, "high_quality")

      # Clicking the fast step (via its element → phx-value-level="fast") moves
      # the selection and the highlight.
      html = view |> element("#quality-level-fast") |> render_click()

      assert assigns(view)[:quality_level] == "fast"
      assert quality_step_active?(html, "fast")
      refute quality_step_active?(html, "balanced")

      # …and the high-quality step likewise. (The return-to-balanced cycle is
      # covered by the default-state assertion above plus the component-level
      # step tests in task_form_components_test.exs.)
      html = view |> element("#quality-level-high_quality") |> render_click()

      assert assigns(view)[:quality_level] == "high_quality"
      assert quality_step_active?(html, "high_quality")
      refute quality_step_active?(html, "fast")
    end

    test "an unknown level is ignored and the selection is unchanged", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)

      render_click(view, "select_quality_level", %{"level" => "fast"})
      assert assigns(view)[:quality_level] == "fast"

      # Not a whitelisted level → the catch-all clause returns the socket
      # unchanged (the current selection stays "fast").
      render_click(view, "select_quality_level", %{"level" => "bogus"})
      assert assigns(view)[:quality_level] == "fast"

      # A missing level param is likewise a no-op.
      render_click(view, "select_quality_level", %{})
      assert assigns(view)[:quality_level] == "fast"
    end

    # Both non-default levels thread their STRING into the task opts on ONE
    # mount (formerly one test per level — byte-identical apart from the value).
  end

  # Persist agent state (default ON) — the Task Options tab toggle
  # (#persist-agent-state-toggle). The checkbox carries NO name/form
  # association, so the assign is the single source of truth: a click that
  # leaves it CHECKED sends %{"value" => "true"}, an UNCHECKED click omits the
  # key entirely. The submit threading itself lives in `LaunchOptions` and is
  # asserted by the real launches in the sync module.
  describe "persist agent state toggle" do
    setup do
      clear_projects()
      :ok
    end

    test "the assign defaults to true on mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      assert assigns(view)[:persist_agent_state?] == true
    end

    test "a click that unchecks it clears the assign, a value=true click sets it", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      # Unchecked semantics: no "value" key in the params.
      render_click(view, "toggle_persist_agent_state", %{})
      assert assigns(view)[:persist_agent_state?] == false

      render_click(view, "toggle_persist_agent_state", %{"value" => "true"})
      assert assigns(view)[:persist_agent_state?] == true
    end

    test "restore_state applies an explicit false and leaves the default alone without the key",
         %{
           conn: conn
         } do
      {:ok, view, _html} = live(conn, ~p"/projects")

      # No persisted key → the mount-time default (ON) stays.
      render_change(view, "restore_state", %{"task_prompt" => "hello"})
      assert assigns(view)[:persist_agent_state?] == true

      render_change(view, "restore_state", %{"persist_agent_state?" => "false"})
      assert assigns(view)[:persist_agent_state?] == false
    end
  end
end

# ---------------------------------------------------------------------------
# Project overview step (the surface between selecting a project and the
# composer) — `EvoDashWeb.ProjectsLive.Overview`.
# ---------------------------------------------------------------------------
defmodule EvoDashWeb.ProjectsLiveOverviewTest do
  @moduledoc """
  Pins the PROJECT OVERVIEW step the Projects page shows before the task
  composer (`EvoDashWeb.ProjectsLive.Overview`): scope identity, the two entry
  points (New task -> composer, Chat with Assistant), the `wb_task=1` bypass,
  the restored-draft rule, workspace framing/member selection, the remote
  (viewed) node case and the recent-activity block.

  `async: true`: every test isolates its own XDG config dir, its own VCT
  registry (`EvoDash.Test.IsolatedVCT`) and temp repo, and deletes its own task
  rows, so no concurrent module sees a live fixture here.
  """

  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EvoDashWeb.ProjectsLiveTest.Helpers

  alias EvoDashWeb.ProjectsLive.Overview
  alias EvoGit.VCT

  setup [:setup_temp_dir, :set_onboarding_completed, :reset_active_tasks_hub]

  # The git fixture TEMPLATE is module-owned (`install_owned_git_template/1`)
  # rather than the suite's shared `:persistent_term` slot: this module runs
  # CONCURRENTLY with the two modules that share that slot and erase it between
  # them (a third concurrent module lost the key mid-run). The template rides
  # the test context; `repo!/1` hands it to the shared `make_git_repo!/2`.
  setup_all [:install_owned_git_template]

  setup %{git_template: git_template} do
    Process.put(:overview_git_template, git_template)
    :ok
  end

  describe "overview renders the selected project" do
    test "replaces the composer and carries the project scope identity", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      path = repo!(Path.join(tmp_dir, "overview-scope"))
      view = open_overview!(conn, path)

      assert has_element?(view, "#workbench-project-overview")
      assert has_element?(view, ~s(#workbench-project-overview[data-overview-kind="project"]))

      assert has_element?(
               view,
               ~s(h1#overview-title[data-overview-name="#{Path.basename(path)}"])
             )

      assert has_element?(view, "[data-overview-path]", path)
      assert has_element?(view, "[data-overview-node]", "Local")

      # The composer is an explicit step now, never the landing surface.
      refute has_element?(view, "#workbench-task-composer")
      refute has_element?(view, "#task-launch-button")
    end

    test "New task moves the page into the composer", %{conn: conn, tmp_dir: tmp_dir} do
      path = repo!(Path.join(tmp_dir, "overview-new-task"))
      view = open_overview!(conn, path)

      assert has_element?(view, "button#overview-new-task")
      render_click(view, "compose_task", %{})

      assert has_element?(view, "#workbench-task-composer")
      assert has_element?(view, "button#task-launch-button")
      refute has_element?(view, "#workbench-project-overview")
      assert assigns(view).compose_task? == true

      # The URL carries the explicit composer step; assert the PARAMS so the
      # test is tolerant of encoding/ordering choices.
      query = view |> assert_patch() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["project"] == path
      assert query["wb_task"] == "1"
    end

    test "wb_task=1 mounts straight into the composer", %{conn: conn, tmp_dir: tmp_dir} do
      path = repo!(Path.join(tmp_dir, "overview-wb-task"))

      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: path, wb_task: "1"}}")

      assert has_element?(view, "#workbench-task-composer")
      refute has_element?(view, "#workbench-project-overview")
    end

    test "a restored draft lands in the composer, not on the overview", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      path = repo!(Path.join(tmp_dir, "overview-restored-draft"))
      view = open_overview!(conn, path)

      assert has_element?(view, "#workbench-project-overview")

      render_click(view, "restore_state", %{
        "task_prompt" => "carry on with the saved objective",
        "node" => "local",
        "project" => path
      })

      assert has_element?(view, "#workbench-task-composer")
      refute has_element?(view, "#workbench-project-overview")
    end
  end

  describe "workspace scope" do
    test "frames the workspace, names the first resolved member and follows a member switch",
         %{conn: conn, tmp_dir: tmp_dir} do
      first = seed_member!(tmp_dir, unique("overview-ws-first"))
      second = seed_member!(tmp_dir, unique("overview-ws-second"))

      workspace =
        seed_workspace!(
          unique("overview-workspace"),
          [member_ref(first), member_ref(second)],
          "overview workspace"
        )

      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: workspace.point}}")
      wait_for_workspace(view, workspace.point)

      assert has_element?(view, "#workbench-project-overview")
      assert has_element?(view, ~s(#workbench-project-overview[data-overview-kind="workspace"]))
      assert has_element?(view, "[data-overview-point]", workspace.point)

      # The FIRST resolved member is the execution target.
      member_line = wait_for_member_line(view)
      assert member_line =~ first.path
      assert has_element?(view, "select#overview-member-select")
      assert has_element?(view, "[data-overview-member-option]")

      # A member's select VALUE is its VCT point (`member_options/1` keys on the
      # point and only falls back to the raw path for an unmounted member).
      assert has_element?(
               view,
               ~s(select#overview-member-select option[value="#{second.point}"]),
               second.name
             )

      render_change(view, "overview_select_member", %{"overview_member" => second.point})

      member_line = view |> element("[data-overview-execution-member]") |> render()
      assert member_line =~ second.path
      refute member_line =~ first.path
    end

    test "a workspace with no resolvable member refuses the New task entry point",
         %{conn: conn} do
      ghost = %{"point" => unique("vct:///projects/overview-ghost"), "path" => nil}
      workspace = seed_workspace!(unique("overview-empty-workspace"), [ghost], "empty workspace")

      {:ok, view, _html} = live(conn, ~p"/projects?#{%{project: workspace.point}}")
      wait_for_workspace(view, workspace.point)

      assert has_element?(view, "#workbench-project-overview")
      assert has_element?(view, "[data-overview-no-member]")
      assert has_element?(view, "[data-overview-missing]")
      assert has_element?(view, "button#overview-new-task[disabled]")
      # A workspace token never reaches execution: no real member, no OS path.
      refute has_element?(view, "a#overview-chat-assistant")

      html = render_click(view, "compose_task", %{})
      refute has_element?(view, "#workbench-task-composer")
      assert has_element?(view, "#workbench-project-overview")
      # The refusal is surfaced (flash) instead of navigating; the alert naming
      # the missing member stays on screen.
      assert html =~ "workspace"
      assert assigns(view).compose_task? == false
    end
  end

  describe "remote (viewed) node" do
    test "renders the overview in the remote context and never in the composer",
         %{conn: conn, tmp_dir: tmp_dir} do
      remote_path = "/remote/projects/#{Path.basename(tmp_dir)}"
      {id, remote_node} = install_remote_activation_fixture!(remote_path)

      {:ok, view, _html} =
        live(conn, "/projects?project=" <> URI.encode(remote_path) <> "&node=" <> id)

      assert_remote_activation_loaded(view, id, remote_node, remote_path)
      # The remote chrome this test asserts on is BATCH-seeded: the live
      # "Chat with Assistant" link renders only for a CONFIRMED selection (the
      # project list the async batch assigns) on a gate-free (connected)
      # target, so await the settled FRAME rather than the activation frame.
      wait_for_overview_chrome(view)

      assert has_element?(view, "#workbench-project-overview")
      assert has_element?(view, ~s(#workbench-project-overview[data-overview-kind="project"]))
      assert has_element?(view, "[data-overview-node]")
      assert has_element?(view, "[data-overview-path]", remote_path)
      # A connected node offers both entry points; the gate chrome is absent.
      assert has_element?(view, "button#overview-new-task")
      assert has_element?(view, "a#overview-chat-assistant")
      refute has_element?(view, "#workbench-task-composer")
    end
  end

  describe "recent activity" do
    test "shows a project task with an honest status", %{conn: conn, tmp_dir: tmp_dir} do
      path = repo!(Path.join(tmp_dir, "overview-activity"))

      # Path-SCOPED: the seam is app-env (process-wide), and a concurrently
      # running module that renders this project's overview must never inherit
      # this test's fake row — every other path answers an EMPTY payload.
      install_overview_runner(fn _node, candidate ->
        if candidate == path do
          %{
            git: nil,
            tasks: [
              %{
                id: 4242,
                status: :completed,
                started_at: "2026-01-02T03:04:05Z",
                opts: [objective: "Fix the build"]
              }
            ]
          }
        else
          %{git: nil, tasks: []}
        end
      end)

      view = open_overview!(conn, path)

      wait_until(view, fn assigns ->
        Enum.any?(assigns[:overview_tasks] || [], &(&1.id == 4242))
      end)

      assert has_element?(view, ~s([data-overview-task-id="4242"]))
      row = overview_row(view, 4242)
      assert row =~ "Fix the build"
      assert row =~ ~r/[Cc]omplet/
    end

    test "omits the activity block when the project has no tasks", %{conn: conn, tmp_dir: tmp_dir} do
      path = repo!(Path.join(tmp_dir, "overview-no-activity"))
      view = open_overview!(conn, path)

      # A freshly created repo has no task rows, and the block is simply absent
      # (no empty state, nothing blocking the two entry points).
      refute has_element?(view, "[data-overview-task-id]")
      assert has_element?(view, "button#overview-new-task")
    end
  end

  describe "Overview pure helpers" do
    test "draft ids are 24 hex characters" do
      draft = Overview.draft_id()
      assert String.length(draft) == 24
      assert String.match?(draft, ~r/^[0-9a-f]{24}$/)
      assert Overview.draft_id() != draft
    end

    test "member options, execution member and missing refs" do
      view = %{
        resolved: [
          %{point: "vct:///projects/alpha", path: "/tmp/alpha", name: "alpha"},
          %{point: nil, path: "/tmp/beta", name: "beta"}
        ],
        missing: [%{"point" => "vct:///projects/gone", "path" => nil}],
        nested: []
      }

      options = Overview.member_options(view)
      assert Enum.map(options, & &1.path) == ["/tmp/alpha", "/tmp/beta"]

      assert %{path: "/tmp/beta"} = Overview.execution_member(view, "/tmp/beta")
      assert %{path: "/tmp/alpha"} = Overview.execution_member(view, nil)
      assert %{path: "/tmp/alpha"} = Overview.execution_member(view, "/tmp/unknown")

      missing = Overview.missing_refs(view)
      assert length(missing) == 1
      assert is_binary(hd(missing))
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures / waits
  # ---------------------------------------------------------------------------

  # The overview is the LANDING surface, so reaching the composer explicitly
  # (what `Helpers.open_project!/2` does) cannot be reused here. The
  # `open_project` event push-patches to the project URL, so THAT patch is
  # consumed here: a later `assert_patch/1` must observe the event under test
  # (the click's own patch), never this landing navigation.
  defp open_overview!(conn, path) do
    # The open event registers this child path, not the parent tmp_dir that
    # setup_temp_dir cleans up. Forget only the mount this fixture creates.
    on_exit(fn -> forget_quietly(path) end)

    {:ok, view, _html} = live(conn, ~p"/projects")
    render_click(view, "open_project", %{"path" => path})
    assert_patch(view, async_wait_budget())
    # The landing `handle_params` run spawns the page's async batch (project
    # list, picker bundle) AND the overview read; the callers below assert on
    # the settled frame (`[data-overview-head]`, the recent-activity block, the
    # scope identity), so drain this view's supervised loads here instead of
    # making each test remember to.
    await_async_loads(view)
    view
  end

  # A REAL git repository (one empty commit) seeded from this module's OWN
  # template, built through the shared `make_git_repo!/2` fixture builder.
  defp repo!(path), do: make_git_repo!(path, Process.get(:overview_git_template))

  # The execution-member line is rendered only once the workspace VIEWS have
  # landed off-process (`{:workspaces_loaded, ...}`), so this awaits the
  # RENDERED half (bounded by `wait_assigns/2`) instead of reading one frame
  # early — no hand-rolled sleep loop.
  defp wait_for_member_line(view) do
    wait_assigns(view, fn _assigns ->
      has_element?(view, "[data-overview-execution-member]")
    end)

    view |> element("[data-overview-execution-member]") |> render()
  end

  # The remote overview chrome is derived from BATCH-seeded state: the live
  # "Chat with Assistant" link renders only for a CONFIRMED selection
  # (`Overview.confirmed_scope?/2` needs the `{path, point}` entry the async
  # project batch assigns) on a gate-free (connected) target. Reading the
  # rendered DOM through `wait_assigns/2` — the same bounded, deadline-based
  # idiom as `wait_for_member_line/1` below — settles that frame instead of
  # asserting on the one the activation result happened to land in.
  defp wait_for_overview_chrome(view) do
    wait_assigns(view, fn _assigns -> has_element?(view, "a#overview-chat-assistant") end)
  end

  # ONE recent-activity row as markup: the row's `<li>` chunk carrying the task
  # id (the id span alone excludes the objective/badge it sits beside).
  defp overview_row(view, id) do
    row =
      view
      |> render()
      |> String.split("<li")
      |> Enum.find(&String.contains?(&1, ~s(data-overview-task-id="#{id}")))

    assert row, "no recent-activity row rendered for task #{id}"
    row
  end

  defp install_overview_runner(fun) do
    previous = Application.get_env(:evo_dash, :projects_overview_runner)
    Application.put_env(:evo_dash, :projects_overview_runner, fun)

    on_exit(fn ->
      if previous do
        Application.put_env(:evo_dash, :projects_overview_runner, previous)
      else
        Application.delete_env(:evo_dash, :projects_overview_runner)
      end
    end)

    :ok
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A workspace MEMBER mounted at a RESERVED point (`vct:///<name>` — outside
  # both `vct:///projects/…` and `vct:///workspaces/…`).
  # The table this fixture writes to belongs to THIS test alone
  # (`EvoDash.Test.IsolatedVCT`), so a concurrent `clear_projects/0` can no
  # longer sweep the member away between the seed and the page's
  # `workspace_entries/1` read; the reserved point is now only a fixture
  # choice that keeps the member out of the project list this module reads,
  # and the member-resolution semantics under test (`point`-first lookup, an
  # option value = the member's point, the first resolvable member as the
  # execution target) are identical to a project mount's.
  defp seed_member!(tmp_dir, basename) do
    path = Path.join(tmp_dir, basename)
    File.mkdir_p!(path)
    point = "vct:///overview-member-" <> basename
    assert {:ok, mount} = VCT.ensure_mount(point, path, name: basename)
    mount
  end

  defp seed_workspace!(name, members, description) do
    assert {:ok, mount} = VCT.create_workspace(name, members, description: description)
    on_exit(fn -> forget_quietly(mount.point) end)
    mount
  end

  defp member_ref(%{point: point, path: path}), do: %{"point" => point, "path" => path}

  defp forget_quietly(key) do
    try do
      VCT.forget(key)
    rescue
      # Teardown-only rescue: a cleanup failure must never mask a test failure.
      _ -> :ok
    end
  end

  # The workspace VIEWS arrive off-process (`{:workspaces_loaded, seq, node,
  # result}`), one frame after the mount. Reading assigns through `:sys.get_state`
  # proves the LOAD landed, not that the resulting diff reached the test
  # process, so the DOM half is awaited too: the overview's member form (or, for
  # a workspace with nothing resolvable, its `data-overview-no-member` alert) is
  # rendered only from the loaded views.
  defp wait_for_workspace(view, point) do
    wait_assigns(view, fn assigns ->
      Enum.any?(assigns[:workspaces] || [], fn
        %{workspace: %{point: candidate}} -> candidate == point
        _other -> false
      end)
    end)

    wait_assigns(view, fn _assigns ->
      has_element?(view, "[data-overview-execution-member]") or
        has_element?(view, "[data-overview-no-member]")
    end)
  end
end

defmodule EvoDashWeb.ProjectsLiveSyncTest do
  # `async: false` — these tests depend on process-wide state or events that
  # async modules can change. ExUnit drains all async modules first:
  #
  #   * broadcasts on the global `"config"` topic can spawn a batch in the
  #     same mounted view as the Retry click, even for another test's config dir.
  #
  #   * `:sys.suspend(EvoGit.TaskRegistry)` — freezing the one serialized registry
  #     would deadlock any concurrent suite that touches it.
  #   * real task launches (`render_submit` -> `TaskRegistry.start_task`) — every
  #     task mutation broadcasts `{:task_updated, ...}` on the process-global
  #     `EvoGit.PubSub`, which arms `NodeAware`'s 300 ms reload debounce on EVERY
  #     mounted page in the BEAM (the documented `agents_live_test`
  #     `:tasks_reload_pending` canary), plus the `on_exit` cancel/delete of the
  #     launched row.
  #   * user-initiated `delete_task` — the SAME process-global `"tasks"`
  #     broadcast (`{:task_deleted, ...}`), and the test it drives asserts that
  #     NO `task_notification` is pushed at all, which is only conclusive while
  #     no concurrent module can publish one.
  #   * user-initiated `clear_task_history` — `TaskRegistry.clear_finished_tasks/0`
  #     sweeps EVERY finished task out of the RUN-WIDE `EvoGit.Store` all suites
  #     share, so under `async: true` it deletes another async module's live
  #     fixture mid-test (seen once: `ReviewLiveArchiveTest`'s task disappeared
  #     between insert and `LoadData.load/2`). Its refute is also the same
  #     GLOBAL-quiet claim as the delete test.
  #   * the store-global notification scan — `EvoDashWeb.ProjectsLive.Notifications`
  #     diffs terminal ids against the RUN-WIDE `EvoGit.Store`, so a `:completed`
  #     row a concurrent async module inserts after a view's mount seed is
  #     "newly terminal" for that view and pushes its own `task_notification`.
  #     Every zero-timeout `refute_push_event(view, "task_notification", %{}, 0)`
  #     is therefore a GLOBAL-quiet claim and belongs here.
  #   * `:directory_picker` (`enabled`) — `test/evo_dash/directory_picker_test.exs`
  #     is `async: true` and flips it to `enabled: true` for its own module; a
  #     concurrent `enabled: false` here (or a real pick there) is the conflict.
  #   * `:remote_path_expand_runner` — `projects_live/project_flow_test.exs` is
  #     `async: true` and stubs the same key.
  #   * mounting the Assistant page (`/assistant`, reached from the legacy
  #     `/help` alias via a 302) — a connected `EvoDash.HomeLive` mount calls
  #     `EvoDash.ChatHistory.current_chat_id() || new_chat()` + `put_state`,
  #     i.e. it WRITES the process-wide ChatHistory ETS table, while the
  #     `async: true` `EvoDash.ChatHistoryTest` asserts exact GLOBAL contents
  #     (`list_chats()`, `current_chat_id()`).
  #
  # The `:github_runner` / `:github_issues_runner` /
  # `:github_issue_markdown_runner` / `:projects_async_load_runner` /
  # `:directory_picker_module` seams are unique to this file family and ride the
  # async module.
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import EvoDashWeb.ProjectsLiveTest.Helpers

  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskInfo

  setup [:setup_temp_dir, :set_onboarding_completed, :reset_active_tasks_hub]
  setup_all [:install_git_template]

  # Retry must start a fresh batch even when the original is still running.
  test "the loading state offers a retry that re-runs the batch", %{conn: conn, tmp_dir: tmp_dir} do
    test_pid = self()
    release = make_ref()

    install_reporting_async_load_runner(fn ->
      owner_ref = Process.monitor(test_pid)

      receive do
        ^release ->
          Process.demonitor(owner_ref, [:flush])
          EvoDashWeb.ProjectsLive.AsyncLoad.default_batch(node(), false, nil, nil, true, false)

        {:DOWN, ^owner_ref, :process, ^test_pid, _reason} ->
          # Don't leave a blocked child or run a load after the test has failed.
          Process.exit(self(), :kill)
      end
    end)

    # `wb_task=1`: the composer owns the picker controls asserted below.
    {:ok, view, _html} = live(conn, ~p"/projects?#{[project: tmp_dir, wb_task: "1"]}")

    first_task = await_view_batch(view.pid)
    assert first_task != view.pid
    assert first_task != test_pid

    assert assigns(view)[:model_selection_ready?] == false
    assert assigns(view)[:model_selection_error] == nil

    html = render(view)
    assert html =~ ~s(id="model-selection-loading")
    assert html =~ "Loading models…"

    assert has_element?(view, "#model-selection-loading-retry[phx-click=retry_model_selection]")

    first_seq = assigns(view)[:projects_load_seq]
    render_click(element(view, "#model-selection-loading-retry"))
    retry_seq = assigns(view)[:projects_load_seq]
    assert retry_seq > first_seq

    second_task = await_view_batch(view.pid)
    assert second_task != first_task

    # Both batches are blocked; the loading state stays retryable.
    assert assigns(view)[:model_selection_ready?] == false
    assert has_element?(view, "#model-selection-loading")

    # Only Retry can make the picker ready: keep the original blocked until
    # the new generation applies, then drain the now-stale original result.
    send(second_task, release)

    wait_assigns(view, fn assigns ->
      assigns[:projects_load_seq] == retry_seq and assigns[:model_selection_ready?] == true and
        assigns[:model_selection_error] == nil
    end)

    assert Process.alive?(first_task)
    send(first_task, release)
    await_async_loads(view)
    refute Process.alive?(first_task)

    assert assigns(view)[:projects_load_seq] == retry_seq
    assert assigns(view)[:model_selection_ready?] == true
    assert assigns(view)[:model_selection_error] == nil
    refute has_element?(view, "#model-selection-loading")
    refute has_element?(view, "#model-selection-loading-retry")
    # An empty (but loaded) inventory renders the explicit setup action.
    assert has_element?(view, "#task-model-setup")
  end

  # Moved here from the async module: a connected `HomeLive` mount writes the
  # process-wide `EvoDash.ChatHistory` table, which the async
  # `EvoDash.ChatHistoryTest` asserts on by exact global contents. Sync
  # placement keeps those two from overlapping; the assertions are unchanged.
  describe "Home chat route (/assistant)" do
    test "mounts HomeLive at /assistant", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/assistant")

      heading =
        html
        |> Floki.parse_document!()
        |> Floki.find("h1")
        |> Floki.text()
        |> String.trim()

      assert heading == "Genesis Assistant"
      assert html =~ ~s(id="chat-form")
    end
  end

  describe "async mount loads + notification scan (exit-safe)" do
    setup do
      clear_projects()
      :ok
    end

    test "mount does no synchronous task-store work and survives an exiting async batch", %{
      conn: conn
    } do
      # The whole batch body is delegated to the seam; an exiting body sends NO
      # result message, so the page must keep mount/3's seeded defaults.
      install_projects_async_load_runner(fn -> exit(:boom) end)

      # FREEZE the single, serialized task registry while the page mounts: any
      # SYNCHRONOUS store call on the mount path would block here and `live/2`
      # could not return. (The injected batch exits immediately and needs no
      # store access at all.)
      :ok = :sys.suspend(EvoGit.TaskRegistry)
      restore_registry_on_exit()

      # Dead render: renders normally, zero store work.
      static = get(conn, ~p"/projects")
      assert html_response(static, 200) =~ "No projects"

      # Connected mount: renders normally, zero store work, page stays alive.
      {:ok, view, _html} = live(conn, ~p"/projects")

      assert Process.alive?(view.pid)
      assert assigns(view)[:projects] == []
      assert assigns(view)[:notified_task_ids_ready?] == false
      assert render(view) =~ "No projects"

      # A debounced reload while the id set is unseeded must not scan (and so
      # can never notify), and the handler returns while the store is still
      # frozen — no synchronous read.
      send(view.pid, :node_aware_reload_tasks)
      assert assigns(view)[:task_notifications_seq] == 0

      :ok = :sys.resume(EvoGit.TaskRegistry)
      drain_task_reload(view)

      refute_push_event(view, "task_notification", %{}, 0)
    end

    test "the notification scan runs off-process and notifies only a newly terminal task", %{
      conn: conn
    } do
      insert_task_fixture!(status: :completed, opts: [prompt: "old task"])

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_notified_ids_ready(view)

      new_task = insert_task_fixture!(status: :completed, opts: [prompt: "notify me"])

      # FREEZE the registry: the scan's store reads now block, so the handler
      # finishing synchronously (the :sys.get_state round-trip below) proves
      # the scan was handed to a supervised task instead of running inline.
      :ok = :sys.suspend(EvoGit.TaskRegistry)
      restore_registry_on_exit()

      send(view.pid, :node_aware_reload_tasks)

      assert assigns(view)[:task_notifications_seq] == 1
      # Off-process work exists: the scan (and the sidebar fetch) are live
      # supervised children owned by this view, blocked on the frozen store.
      assert mount_async_task_pids(view.pid) != []

      :ok = :sys.resume(EvoGit.TaskRegistry)
      drain_task_reload(view)

      {title, body} = EvoDashWeb.ProjectsLive.Project.task_notification_content(new_task)
      assert_push_event(view, "task_notification", %{title: ^title, body: ^body})

      # The old (seeded) task produced no second notification.
      refute_push_event(view, "task_notification", %{}, 0)
      assert MapSet.member?(assigns(view)[:notified_task_ids], new_task.id)
    end
  end

  # Moved here from the async module: this test's refute is a claim about
  # GLOBAL quiet (no `task_notification` at all), and the `delete_task` it
  # drives publishes `{:task_deleted, ...}` on the process-global `"tasks"`
  # topic — which both reaches this view through `NodeAware` and arms every
  # OTHER mounted page's reload debounce in the BEAM. `async: true` would let a
  # concurrently running module's newly-terminal task push its own
  # `task_notification` into this view between the drain and the refute. Sync
  # placement keeps the assertion (and its zero window) exactly as it was.
  describe "user-initiated task mutations do not notify" do
    setup do
      clear_projects()
      :ok
    end

    test "user-initiated delete_task does not notify", %{conn: conn} do
      task = insert_task_fixture!(status: :running)

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_notified_ids_ready(view)

      render_hook(view, "delete_task", %{"task_id" => task.id})

      # delete_task is a cast — a synchronous registry call afterwards
      # guarantees the store deletion was processed before the reload snapshot.
      EvoGit.TaskRegistry.list_tasks()

      send(view.pid, :node_aware_reload_tasks)
      drain_task_reload(view)

      refute_push_event(view, "task_notification", %{}, 0)
    end

    # Same reasoning as the delete test above, plus a second, sharper hazard:
    # `clear_task_history` runs `TaskRegistry.clear_finished_tasks/0`, which
    # sweeps EVERY finished task out of the RUN-WIDE store the whole suite
    # shares — under `async: true` that deletes another module's live fixture
    # mid-test (observed once: `ReviewLiveArchiveTest`'s task vanished between
    # its fixture insert and its `LoadData.load/2`). Serial placement means the
    # sweep can only ever see fixtures of tests that already finished.
    # The refute also stays conclusive: no concurrent module can push its own
    # `task_notification` into this view between the drain and the refute.
    test "user-initiated clear_task_history does not notify", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      # Terminal AFTER mount — would be newly-terminal on reload if the user
      # had not cleared the history.
      insert_task_fixture!(status: :completed, opts: [prompt: "cleared task"])

      render_hook(view, "clear_task_history", %{})

      # The clear re-seeds the notified-id set asynchronously; wait for that
      # readiness before triggering the scan.
      wait_notified_ids_ready(view)

      send(view.pid, :node_aware_reload_tasks)
      drain_task_reload(view)

      refute_push_event(view, "task_notification", %{}, 0)
    end
  end

  # Moved here from the async module: `EvoDashWeb.ProjectsLive.Notifications`
  # scans terminal ids in the RUN-WIDE `EvoGit.Store` and notifies every id the
  # view's mount seed did not already contain, so a `:completed` row any
  # concurrent `async: true` module inserts between this view's seed and its
  # reload is "newly terminal" for THIS view and pushes its own
  # `task_notification` (observed intermittently as `%{title: "Evolution task
  # completed", body: "Test objective"}` — a review-suite task fixture). The
  # zero-timeout refute below claims NOTHING pushes, which is only conclusive
  # once ExUnit has drained every async module; assertions are unchanged.
  describe "notification scan is store-global (refute needs global quiet)" do
    setup do
      clear_projects()
      :ok
    end

    test "no notification for a task already terminal before mount", %{conn: conn} do
      insert_task_fixture!(status: :completed)

      {:ok, view, _html} = live(conn, ~p"/projects")
      # The terminal-id SEED is part of the connected mount's async batch and
      # notification scanning is skipped until it lands — wait for it instead
      # of racing the continuation.
      wait_notified_ids_ready(view)

      # The seed pre-notifies terminal ids, so a reload must not push a
      # browser notification for them.
      send(view.pid, :node_aware_reload_tasks)
      # The scan runs off-process; settle it (and the diff that would carry a
      # pushed notification) before asserting, so the zero-timeout refute is
      # conclusive instead of a 100 ms observation window.
      html = drain_task_reload(view)

      refute_push_event(view, "task_notification", %{}, 0)
      # No active project in this describe (projects cleared, fixture
      # inserted directly into the store), so the launch panel is hidden
      refute html =~ "task-launch-button"
    end

    # Same hazard as the test above (moved from the async module for it): the
    # seed-subset assertions are placement-independent, but the REFUTES are a
    # GLOBAL-quiet claim about a scan that diffs the RUN-WIDE store.
    test "the notified-id seed never notifies for pre-existing terminal tasks", %{conn: conn} do
      ids = for _ <- 1..3, do: insert_task_fixture!(status: :completed).id

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_notified_ids_ready(view)

      # Every pre-existing terminal task is in the seed.
      assert MapSet.new(ids) |> MapSet.subset?(assigns(view)[:notified_task_ids])

      # No notification before the seed landed: the readiness poll above settles
      # the mount turn and the batch never pushes a notification itself, so a
      # zero-timeout refute is conclusive.
      refute_push_event(view, "task_notification", %{}, 0)

      # ...and none after a scan runs against the seeded set.
      send(view.pid, :node_aware_reload_tasks)
      drain_task_reload(view)

      refute_push_event(view, "task_notification", %{}, 0)
    end
  end

  describe "task_submit clears the prompt" do
    setup do
      clear_projects()
      :ok
    end

    test "clears the prompt assign and pushes the clear_prompt event on launch", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      write_provider_profile_config()
      point_registry_at_test_config!()

      {:ok, view, _html} = live(conn, ~p"/projects")

      # Open a project via the palette (open-path mode) and settle its picker.
      open_project!(view, tmp_dir)
      await_async_loads(view)

      # Seed the prompt the way the client does (restore_state is the
      # still-supported way to set the persisted prompt).
      render_change(view, "restore_state", %{"task_prompt" => "build me a thing"})
      assert assigns(view)[:task_prompt] == "build me a thing"

      # Seed a real git repo so the doomed wrapper's life is pure validation
      # (see make_git_repo!/1): ensure_repo short-circuits, rev-parse HEAD
      # succeeds, and the wrapper dies at node-path validation before any
      # agent dispatch — no LLM calls, no worktrees, no agents (which matters
      # because the scheduler's model profiles come from the boot-time
      # ambient config, not the per-test config-dir isolation).
      make_git_repo!(tmp_dir)

      # Launch an evolve task with a nonexistent node_path. The task still
      # launches successfully (start_task returns {:ok, task}); the spawned
      # wrapper then fails fast in EvoGit.Runtime.Evolution at the invalid
      # node path.
      _html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "build me a thing",
          mode: "evolve_simple",
          node_path: "./nonexistent-dir"
        })

      html = await_task_launch(view)
      assert html =~ "task started with ID:"

      # The server-side prompt assign is reset to "" after a successful
      # launch, so the next render seeds the compact layout (the visible
      # textarea itself is cleared client-side — morphdom skips it under
      # phx-update="ignore").
      assert assigns(view)[:task_prompt] == ""

      # The client-side clear event is pushed: it empties the textarea and
      # removes the persisted draft so a reload can't resurrect the prompt.
      assert_push_event(view, "clear_prompt", %{})

      # The launch spawned a real task (which fails fast on the invalid node
      # path — terminal long before this point); register the on_exit
      # cancel+delete cleanup and wait for the terminal status so the wrapper
      # has finished spawning ports before the setup on_exit rm_rf!(tmp_dir).
      [id] = Regex.run(~r/task started with ID: ([a-f0-9]{16})/, html, capture: :all_but_first)

      on_exit(fn ->
        # Cleanup in on_exit: rescue so teardown failures don't mask real test failures.
        try do
          EvoGit.TaskRegistry.cancel_task(id)
        rescue
          _ -> :ok
        end

        try do
          EvoGit.TaskRegistry.delete_task(id)
        rescue
          _ -> :ok
        end
      end)

      wait_for_task_terminal(id)
    end
  end

  # REGRESSION: the fused mode+speed capsule removed the old
  # `<select name="mode" phx-change="task_change">` and for a while no field
  # carried "mode" at all, so the browser payload had no "mode" key and the
  # strict `handle_event("task_submit", %{"prompt" => _, "mode" => _})` clause
  # raised FunctionClauseError — /projects could not start ANY task. The other
  # submit tests hand-build a `mode:` param (which is exactly what hid the bug),
  # so this one submits the REAL rendered form: render_submit/2 collects the
  # form's DOM values (hidden inputs and `form="task-form"` inputs included) and
  # deep-merges the given map over them, never supplying :mode itself.
  describe "task_submit form contract" do
    setup do
      clear_projects()
      :ok
    end

    test "an unconfigured project blocks submissions on the server and offers model settings", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects")
      open_project!(view, tmp_dir)
      await_async_loads(view)

      assert has_element?(view, "#task-model-setup")
      assert has_element?(view, "#task-launch-button[disabled]")

      tasks_before = EvoGit.TaskRegistry.list_task_ids()
      render_submit(view, "task_submit", %{"prompt" => "Draft", "mode" => "evolve_simple"})
      # The unconfigured-project guard refuses the submit BEFORE the async
      # launch is spawned (`LaunchOptions.apply/2` → `:no_task_model`), so no
      # `:task_launch_seq` bump ever happens and `await_task_launch/2` would
      # time out. Await the effect the server does produce: its rendered
      # refusal — the friendly, actionable line that points at the model
      # settings, NOT the generic "Failed to start task" wording.
      wait_for_flash(view, :error, "Configure a model on this server")
      assert has_element?(view, "#flash-error", "Configure a model on this server")
      # ...and nothing was enqueued: the refusal happens before any task row.
      assert EvoGit.TaskRegistry.list_task_ids() -- tasks_before == []
    end

    test "a real form submit with no hand-built mode param launches (hidden mode field)", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      write_provider_profile_config()
      point_registry_at_test_config!()

      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)
      await_async_loads(view)

      # A real git repo so the doomed wrapper dies at node-path validation
      # rather than spawning anything (see make_git_repo!/1).
      make_git_repo!(tmp_dir)

      # Move the server-side mode truth through the UI, exactly like clicking
      # the capsule's Layer-2 "Evolve" item; the hidden field mirrors it.
      render_click(view, "task_change", %{"mode" => "evolve_simple"})
      assert assigns(view)[:task_mode] == "evolve_simple"

      _html =
        view
        |> element("#task-form")
        |> render_submit(%{prompt: "build me a thing", node_path: "./nonexistent-dir"})

      html = await_task_launch(view)
      assert html =~ "task started with ID:"
      task_id = cleanup_launched_task(html)

      task = EvoGit.TaskRegistry.get_task(task_id)

      # "mode" reached the handler (hidden field) and mapped to the core mode
      # string; the rest of the payload's keys still arrive too.
      assert opt(task, :mode) == "simple"
      assert opt(task, :objective) == "build me a thing"
      assert opt(task, :node_path) == "./nonexistent-dir"
      assert opt(task, :path) == tmp_dir
    end
  end

  # Persist agent state reaches the task opts through `LaunchOptions`, which
  # always puts `:persistent_state` EXPLICITLY (never omits it) so the opt stays
  # self-describing: `true` by default, `false` after the Task Options toggle is
  # switched off. Both directions are proven by a real launch.
  describe "persist agent state opt threading" do
    setup do
      clear_projects()
      :ok
    end

    test "an untouched submit carries persistent_state: true", %{conn: conn, tmp_dir: tmp_dir} do
      write_provider_profile_config()
      point_registry_at_test_config!()

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_project!(view, tmp_dir)
      await_async_loads(view)
      # A real git repo so the doomed wrapper dies at node-path validation
      # rather than spawning an agent (see make_git_repo!/1).
      make_git_repo!(tmp_dir)

      _html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "build me a thing",
          mode: "evolve_simple",
          node_path: "./nonexistent-dir"
        })

      html = await_task_launch(view)
      assert html =~ "task started with ID:"
      task = EvoGit.TaskRegistry.get_task(cleanup_launched_task(html))
      assert has_persistent_state_opt?(task)
      assert persistent_state_opt(task) == true
    end

    test "toggling the control off before submitting carries persistent_state: false", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      write_provider_profile_config()
      point_registry_at_test_config!()

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_project!(view, tmp_dir)
      await_async_loads(view)
      make_git_repo!(tmp_dir)
      # Unchecked-click semantics: no "value" key in the params.
      render_click(view, "toggle_persist_agent_state", %{})
      assert assigns(view)[:persist_agent_state?] == false

      _html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "build me a thing",
          mode: "evolve_simple",
          node_path: "./nonexistent-dir"
        })

      html = await_task_launch(view)
      assert html =~ "task started with ID:"
      task = EvoGit.TaskRegistry.get_task(cleanup_launched_task(html))
      assert has_persistent_state_opt?(task)
      assert persistent_state_opt(task) == false
    end
  end

  describe "remote URL-driven project activation" do
    test "remote ?project= tilde path expands via the remote seam, never the local HOME", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      remote_home = "/remote/home/#{Path.basename(tmp_dir)}/remote-proj"
      {id, remote_node} = install_remote_activation_fixture!(remote_home)
      test_pid = self()

      # Read at call time in both dead-render normalization and activation.
      # Match the target identity and input exactly: no local HOME fallback.
      previous = Application.fetch_env(:evo_dash, :remote_path_expand_runner)

      Application.put_env(:evo_dash, :remote_path_expand_runner, fn ^remote_node,
                                                                    "~/remote-proj" ->
        send(test_pid, {:remote_path_expanded, remote_node, "~/remote-proj"})
        {:ok, remote_home}
      end)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:evo_dash, :remote_path_expand_runner, value)
          :error -> Application.delete_env(:evo_dash, :remote_path_expand_runner)
        end
      end)

      {:ok, view, _html} =
        live(conn, "/projects?project=" <> URI.encode("~/remote-proj") <> "&node=" <> id)

      assert_remote_activation_loaded(view, id, remote_node, remote_home)

      assert_receive {:remote_path_expanded, ^remote_node, "~/remote-proj"},
                     async_wait_budget()

      assert assigns(view)[:active_project_path] == remote_home
    end
  end

  describe "foreign repos — read-write validation and threading" do
    setup do
      clear_projects()
      :ok
    end

    test "task_submit threads foreign_repos (writable + base_sha) into the task opts", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      write_provider_profile_config()
      point_registry_at_test_config!()

      {repo_path, head_sha} = git_repo_fixture!(tmp_dir, "repo1")

      # The fixture makes tmp_dir non-empty, so activation auto-detects
      # genesis_existing and spawns the real GitHub-upstream git port under
      # tmp_dir — stub the runner (this test asserts no GitHub behavior).
      stub_github_upstream_check!()

      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)
      await_async_loads(view)

      render_click(view, "add_foreign_repo", %{
        "repo_id" => "repo1",
        "path" => repo_path,
        "description" => "the repo",
        "writable" => "true",
        "base_sha" => head_sha
      })

      # Seed a real git repo so the doomed wrapper's life is pure validation
      # (make_git_repo!/1) — see "task_submit clears the prompt".
      make_git_repo!(tmp_dir)

      _html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "build me a thing",
          mode: "evolve_simple",
          node_path: "./nonexistent-dir"
        })

      html = await_task_launch(view)
      assert html =~ "task started with ID:"
      task_id = cleanup_launched_task(html)

      # Re-fetch AFTER the wait — the wrapper's final-status persistence may
      # rewrite the row (the codec round-trip of :foreign_repos is unchanged).
      task = EvoGit.TaskRegistry.get_task(task_id)

      # :foreign_repos is in the codec's known-opt-key whitelist, so the key
      # round-trips as an atom; the VALUE is Jason-decoded into string-keyed
      # maps (id/root/description/writable/base_sha).
      foreign_repos = opt(task, :foreign_repos)
      assert is_list(foreign_repos)

      repo = Enum.find(foreign_repos, &(Map.get(&1, "id") == "repo1"))
      assert Map.get(repo, "writable") == true
      assert Map.get(repo, "base_sha") == head_sha
    end
  end

  describe "directory picker" do
    test "directory_pick with the picker disabled pushes unavailable", %{conn: conn} do
      # Explicit and self-documenting (test_helper.exs already sets it, but
      # state it here so this test reads standalone). The disabled flag is
      # checked FIRST in EvoDash.DirectoryPicker.pick/2, so this exercises the
      # real synchronous {:error, :unavailable} path without ever touching wx.
      original = Application.get_env(:evo_dash, :directory_picker)
      Application.put_env(:evo_dash, :directory_picker, enabled: false)

      on_exit(fn ->
        # Restore the prior config so other tests are unaffected.
        if original do
          Application.put_env(:evo_dash, :directory_picker, original)
        else
          Application.delete_env(:evo_dash, :directory_picker)
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/projects")

      render_hook(view, "directory_pick", %{picker_id: "new-project"})

      assert_push_event(
        view,
        "picker_result:new-project",
        %{unavailable: true},
        async_wait_budget()
      )
    end
  end

  describe "file attach" do
    setup do
      on_exit(fn ->
        # Clear the fake's per-test file result so it never leaks across tests.
        EvoDash.DirectoryPicker.Fake.reset()
      end)

      :ok
    end

    test "file_pick with the picker disabled pushes unavailable", %{conn: conn} do
      # Explicit and self-documenting (test_helper.exs already sets it, but
      # state it here so this test reads standalone). The disabled flag is
      # checked FIRST in EvoDash.DirectoryPicker.pick/3, so this exercises the
      # real synchronous {:error, :unavailable} path with the real picker
      # module (the env seam defaults to it).
      original = Application.get_env(:evo_dash, :directory_picker)
      Application.put_env(:evo_dash, :directory_picker, enabled: false)

      on_exit(fn ->
        # Restore the prior config so other tests are unaffected.
        if original do
          Application.put_env(:evo_dash, :directory_picker, original)
        else
          Application.delete_env(:evo_dash, :directory_picker)
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/projects")

      render_hook(view, "file_pick", %{picker_id: "objective_file", prompt: "my base prompt"})

      assert_push_event(
        view,
        "picker_result:objective_file",
        %{unavailable: true},
        async_wait_budget()
      )
    end

    test "submitting with a staged attachment threads base64 attachments and clears the staged list",
         %{
           conn: conn,
           tmp_dir: tmp_dir
         } do
      write_provider_profile_config()
      point_registry_at_test_config!()

      install_fake_picker!()

      png_path = Path.join(tmp_dir, "pic.png")
      png_bytes = <<137, 80, 78, 71, 13, 10, 26, 10>>
      File.write!(png_path, png_bytes)

      # The staged .png makes tmp_dir non-empty → activation auto-detects
      # genesis_existing and spawns the real GitHub-upstream git port under
      # tmp_dir — stub the runner (this test asserts no GitHub behavior).
      stub_github_upstream_check!()

      {:ok, view, _html} = live(conn, ~p"/projects")
      open_staging_project(view, tmp_dir)

      pick_staged(view, "objective_file_image", "image", png_path)

      # `pick_staged` only STARTS the off-process read (the fake picker sends
      # its result, the page spawns the read in `EvoDash.TaskSupervisor` and
      # applies `{{:attachment_loaded, ...}}` a frame later), so a bare
      # `assigns/1` read races that apply — under load it can observe the
      # pre-apply `[]`. Await the APPLIED assign through the file's documented
      # load-tolerant helper, then pin its exact contents below.
      await_attachment(view, "objective_file_image", fn assigns ->
        assigns[:staged_attachments] != []
      end)

      assert assigns(view)[:staged_attachments] == [
               %{
                 "type" => "image",
                 "name" => "pic.png",
                 "media_type" => "image/png",
                 "data" => png_bytes
               }
             ]

      # Seed a real git repo so the doomed wrapper's life is pure validation
      # (make_git_repo!/1) — the invalid node_path kills the wrapper at
      # validation, before any agent dispatch (no LLM calls, no worktrees, no
      # agents — see the "task_submit clears the prompt" describe).
      make_git_repo!(tmp_dir)
      await_async_loads(view)

      # Launch an evolve task with a nonexistent node_path — the task launches
      # successfully but the wrapper fails fast at validation.
      _html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "build me a thing",
          mode: "evolve_simple",
          node_path: "./nonexistent-dir"
        })

      html = await_task_launch(view)
      assert html =~ "task started with ID:"

      # A successful launch clears the staged attachments.
      assert assigns(view)[:staged_attachments] == []

      id = cleanup_launched_task(html)

      # The persisted task opts carry the attachment as BASE64 (raw bytes never
      # cross the task-opts boundary — this is the whole point of encoding at
      # submit). The :attachments opt key is not codec-whitelisted, so it
      # round-trips as the STRING "attachments" — read tolerantly for either
      # key shape.
      task = EvoGit.TaskRegistry.get_task(id)
      opts_map = Map.new(task.opts || [])
      attachments = Map.get(opts_map, "attachments") || Map.get(opts_map, :attachments)

      assert [%{} = att] = attachments
      assert att["type"] == "image"
      assert att["name"] == "pic.png"
      assert att["media_type"] == "image/png"
      assert att["data"] == Base.encode64(png_bytes)
    end
  end

  describe "custom agent selection" do
    setup do
      clear_projects()

      # Each test's isolated config-dir seam gives agents.toml a temp home.
      {:ok, _agent} =
        EvoGit.CustomAgents.save(%{
          name: "Bug Hunter",
          prompt: "You hunt bugs in code.",
          id: "my-agent"
        })

      # Bust the ModelSelector persistent_term cache so the new file is seen.
      EvoGit.CustomAgents.reload()
      :ok
    end

    test "selecting a custom agent threads :agent into the task opts", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      write_provider_profile_config()
      point_registry_at_test_config!()

      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)
      await_async_loads(view)

      render_change(view, "select_agent", %{"agent" => "my-agent"})

      # Seed a real git repo so the doomed wrapper's life is pure validation
      # (make_git_repo!/1): the invalid node_path kills it at validation,
      # before any agent dispatch (see "task_submit clears the prompt").
      make_git_repo!(tmp_dir)

      _html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "build me a thing",
          mode: "evolve_simple",
          node_path: "./nonexistent-dir"
        })

      html = await_task_launch(view)
      assert html =~ "task started with ID:"
      task_id = cleanup_launched_task(html)
      task = EvoGit.TaskRegistry.get_task(task_id)

      # The persisted task opts round-trip through EvoGit.Store.Codec, which
      # atomizes only its known-key whitelist — :agent decodes as a string key.
      assert opt(task, "agent") == "my-agent"
    end

    test "Auto (default) threads no :agent opt", %{conn: conn, tmp_dir: tmp_dir} do
      write_provider_profile_config()
      point_registry_at_test_config!()

      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)
      await_async_loads(view)

      # Seed a real git repo so the doomed wrapper's life is pure validation
      # (make_git_repo!/1) — see "task_submit clears the prompt".
      make_git_repo!(tmp_dir)

      _html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "build me a thing",
          mode: "evolve_simple",
          node_path: "./nonexistent-dir"
        })

      html = await_task_launch(view)
      assert html =~ "task started with ID:"
      task_id = cleanup_launched_task(html)
      task = EvoGit.TaskRegistry.get_task(task_id)
      refute has_opt?(task, "agent")
    end

    test "custom_agent submit with a selected agent starts an evolve task with mode custom", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      write_provider_profile_config()
      point_registry_at_test_config!()

      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)
      await_async_loads(view)

      render_change(view, "select_agent", %{"agent" => "my-agent"})

      # Seed a real git repo so the doomed wrapper's life is pure validation
      # (make_git_repo!/1) — see "task_submit clears the prompt".
      make_git_repo!(tmp_dir)

      _html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "build me a thing",
          mode: "custom_agent",
          node_path: "./nonexistent-dir"
        })

      html = await_task_launch(view)
      assert html =~ "task started with ID:"
      task_id = cleanup_launched_task(html)
      task = EvoGit.TaskRegistry.get_task(task_id)

      assert task.type == :evolve
      # :mode/:objective are in the Store codec's atomization whitelist, so the
      # round-tripped opts decode them as atom keys with STRING values; :agent
      # is not whitelisted, so it stays a string key.
      assert opt(task, :mode) == "custom"
      assert opt(task, "agent") == "my-agent"
      assert opt(task, :objective) == "build me a thing"
    end
  end

  describe "model selection auto/lock semantics" do
    setup do
      clear_projects()
      :ok
    end

    test "with model-selection rules, explicit Auto submits no model spec, lock or legacy id",
         %{conn: conn, tmp_dir: tmp_dir} do
      write_provider_profile_config()
      point_registry_at_test_config!()
      :ok = EvoGit.CustomAgents.save_model_selection_script(~s("account-a"))
      EvoGit.CustomAgents.reload()

      {:ok, view, _html} = live(conn, ~p"/projects")
      await_async_loads(view)
      # Rules expose Auto; the configured default still initializes the picker.
      assert assigns(view)[:selected_model_spec]["provider_profile_id"] == "account-a"
      assert assigns(view)[:model_selection_enabled] == true

      open_project!(view, tmp_dir)
      await_async_loads(view)
      html = render_change(view, "select_provider_profile", %{"provider_profile_id" => ""})
      assert assigns(view)[:selected_model_spec] == %{}
      assert html =~ "Auto (by rules)"

      # The capsule's Auto row is the blank provider item (selected, active)
      # and the drill row mirrors it; there is no provider `<select>` at all.
      refute has_element?(view, "#task-llm-selection select")

      assert has_element?(
               view,
               ~s(#task-llm-selection-provider-list [role="option"][phx-value-provider_profile_id=""][aria-selected="true"])
             )

      assert has_element?(
               view,
               "#task-llm-selection-provider .capsule-drill-value",
               "Auto (by rules)"
             )

      # Seed a real git repo so the doomed wrapper's life is pure validation
      # (make_git_repo!/1) — see "task_submit clears the prompt".
      make_git_repo!(tmp_dir)

      _html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "build me a thing",
          mode: "evolve_simple",
          node_path: "./nonexistent-dir"
        })

      html = await_task_launch(view)
      assert html =~ "task started with ID:"
      task_id = cleanup_launched_task(html)
      task = EvoGit.TaskRegistry.get_task(task_id)

      assert_task_auto_selection(task)
    end

    test "an explicit model and slider choice persist exactly and lock out model-selection rules",
         %{
           conn: conn,
           tmp_dir: tmp_dir
         } do
      write_provider_profile_config()
      point_registry_at_test_config!()
      :ok = EvoGit.CustomAgents.save_model_selection_script(~s("account-a"))
      EvoGit.CustomAgents.reload()

      {:ok, view, _html} = live(conn, ~p"/projects")
      await_async_loads(view)
      open_project!(view, tmp_dir)
      await_async_loads(view)

      render_change(view, "select_provider_profile", %{"provider_profile_id" => "account-a"})
      render_change(view, "select_model", %{"model" => "claude-opus-5"})
      render_change(view, "select_reasoning_effort", %{"reasoning_effort" => "0"})

      spec = %{
        "provider_profile_id" => "account-a",
        "model" => "claude-opus-5",
        "reasoning_effort" => "low"
      }

      assert assigns(view)[:selected_model_spec] == spec

      # Seed a real git repo so the doomed wrapper's life is pure validation
      # (make_git_repo!/1) — see "task_submit clears the prompt".
      make_git_repo!(tmp_dir)

      _html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "build me a thing",
          mode: "evolve_simple",
          node_path: "./nonexistent-dir"
        })

      html = await_task_launch(view)
      assert html =~ "task started with ID:"
      task_id = cleanup_launched_task(html)
      task = EvoGit.TaskRegistry.get_task(task_id)

      assert_task_model_selection(task, spec)
    end

    test "without rules the configured provider/model/effort default is submitted as a locked spec",
         %{conn: conn, tmp_dir: tmp_dir} do
      write_provider_profile_config()
      point_registry_at_test_config!()

      {:ok, view, _html} = live(conn, ~p"/projects")
      await_async_loads(view)

      spec = %{
        "provider_profile_id" => "account-a",
        "model" => "claude-sonnet-5",
        "reasoning_effort" => "low"
      }

      assert assigns(view)[:selected_model_spec] == spec
      assert assigns(view)[:model_selection_enabled] == false

      open_project!(view, tmp_dir)
      await_async_loads(view)
      refute render(view) =~ "Auto (by rules)"

      # Both fused capsules carry the shared client hook; only the model capsule
      # declares an initial `data-capsule-view`, and no provider `<select>` or
      # `phx-change` selection control exists anywhere in the picker.
      assert has_element?(view, ~s(#mode-speed-capsule[phx-hook="CapsulePanel"]))

      assert has_element?(
               view,
               ~s(#task-llm-selection[phx-hook="CapsulePanel"][data-capsule-view="model"])
             )

      assert has_element?(view, ~s(#task-llm-selection .capsule-view[data-view="model"]))
      assert has_element?(view, ~s(#task-llm-selection .capsule-view[data-view="provider"]))
      assert has_element?(view, ~s(#task-llm-selection-provider[data-capsule-drill="provider"]))
      assert has_element?(view, ~s(#task-llm-selection-provider-list[role="listbox"]))
      assert has_element?(view, ~s(#task-llm-selection .capsule-back[data-capsule-back]))
      refute has_element?(view, "#task-llm-selection select")
      refute render(view) =~ ~s(phx-change="select_provider_profile")

      # Ordered provider inventory (blank/Auto row first, then the configured
      # profile) and the selected row.
      assert render(view)
             |> Floki.parse_document!()
             |> Floki.find("#task-llm-selection-provider-list [role=\"option\"]")
             |> Floki.attribute("phx-value-provider_profile_id") == ["", "account-a"]

      assert has_element?(
               view,
               ~s(#task-llm-selection-provider-list [role="option"][phx-value-provider_profile_id="account-a"][aria-selected="true"])
             )

      assert has_element?(
               view,
               "#task-llm-selection-provider .capsule-drill-value",
               "Test account"
             )

      assert has_element?(
               view,
               ~s(#task-llm-selection-model .capsule-item-active[phx-value-model="claude-sonnet-5"])
             )

      [active_model] =
        render(view)
        |> Floki.parse_document!()
        |> Floki.find("#task-llm-selection-model .capsule-item-active")

      assert Floki.attribute(active_model, "phx-value-model") == ["claude-sonnet-5"]

      assert active_model |> Floki.find(".capsule-item-label") |> Floki.text() |> String.trim() ==
               "claude-sonnet-5"

      [reasoning_stop] =
        render(view)
        |> Floki.parse_document!()
        |> Floki.find("#task-llm-selection-reasoning .capsule-stop-active")

      assert Floki.attribute(reasoning_stop, "aria-pressed") == ["true"]
      assert reasoning_stop |> Floki.text() |> String.trim() == "Low"

      # Seed a real git repo so the doomed wrapper's life is pure validation
      # (make_git_repo!/1) — see "task_submit clears the prompt".
      make_git_repo!(tmp_dir)

      _html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "build me a thing",
          mode: "evolve_simple",
          node_path: "./nonexistent-dir"
        })

      html = await_task_launch(view)
      assert html =~ "task started with ID:"
      task_id = cleanup_launched_task(html)
      task = EvoGit.TaskRegistry.get_task(task_id)

      assert_task_model_selection(task, spec)
    end
  end

  describe "GitHub issue integration" do
    setup do
      clear_projects()

      put_github_seams([])

      :ok
    end

    test "Fix persists the exact locked model spec, or omits all model options for Auto", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      write_provider_profile_config()
      point_registry_at_test_config!()
      :ok = EvoGit.CustomAgents.save_model_selection_script(~s("account-a"))
      EvoGit.CustomAgents.reload()
      make_evolve_project(tmp_dir)

      # Seed an EMPTY (initialized, zero-commit) git repo so the spawned
      # wrapper dies BEFORE any agent dispatch, by design: ensure_repo
      # short-circuits on the pre-existing .git directory (no git init/add/
      # commit ports, no repo mutation), then resolve_starting_commit fails
      # on the unborn HEAD (rev-parse HEAD errors) — Evolution returns the
      # error before node-path validation and run_mode, so no LLM is ever
      # reachable (which matters because the scheduler's model profiles come
      # from the boot-time ambient config, not the per-test config-dir
      # isolation). The fix flow builds its opts WITHOUT a node_path (it is
      # not a task-form param), so "./" validation would always pass — the
      # unborn-HEAD lever is what keeps this launch LLM-safe.
      {_, 0} = System.cmd("git", ["init", tmp_dir], stderr_to_stdout: true)

      markdown =
        "# GitHub Issue #42: Fix the thing\n" <>
          "URL: https://github.com/acme/widgets/issues/42 | State: open | Labels: bug\n\n" <>
          "Body text"

      put_github_seams(
        github_runner: ok_upstream_runner(),
        github_issues_runner: fn _node, _path, _opts ->
          {:ok,
           [
             %{
               number: 42,
               title: "Fix the thing",
               state: "open",
               labels: ["bug"],
               url: "https://github.com/acme/widgets/issues/42",
               author: "octocat",
               created_at: "2026-08-01T10:00:00Z"
             }
           ]}
        end,
        github_issue_markdown_runner: fn _node, _path, 42 -> {:ok, markdown} end
      )

      {:ok, view, _html} = live(conn, ~p"/projects")
      await_async_loads(view)
      open_project(view, tmp_dir)
      await_async_loads(view)
      github_status(view, :ok)

      spec = %{
        "provider_profile_id" => "account-a",
        "model" => "claude-opus-5",
        "reasoning_effort" => "low"
      }

      for selection <- [spec, %{}] do
        if selection == %{} do
          render_change(view, "select_provider_profile", %{"provider_profile_id" => ""})
        else
          render_change(view, "select_provider_profile", %{"provider_profile_id" => "account-a"})
          render_change(view, "select_model", %{"model" => "claude-opus-5"})
          render_change(view, "select_reasoning_effort", %{"reasoning_effort" => "0"})
        end

        assert assigns(view)[:selected_model_spec] == selection
        render_click(view, "open_github_issues", %{})
        wait_until(view, fn a -> a[:github_issues].status == :ok end)
        render_click(view, "github_fix_issue", %{"number" => "42"})

        # The markdown fetch is async; the modal closes once the fix task starts.
        wait_until(view, fn a -> a[:github_modal_open] == false end)
        # The fix task starts inside the `{:github_fix_result, ...}`
        # continuation (`ProjectsLive.GitHub.do_start_fix_task/3`), which never
        # bumps `:task_launch_seq` — await the "task started" flash it pushes.
        html = wait_for_flash(view, :info, "task started with ID:")
        assert html =~ "task started with ID:"
        refute html =~ "github-issues-modal"

        id = cleanup_launched_task(html)
        task = EvoGit.TaskRegistry.get_task(id)
        assert task.type == :evolve
        assert task.opts[:path] == assigns(view)[:active_project_path]
        assert task.opts[:mode] == "simple"
        assert task.opts[:objective] == "Fix Fix the thing\n\n" <> markdown

        if selection == %{} do
          assert_task_auto_selection(task)
        else
          assert_task_model_selection(task, selection)
        end
      end
    end
  end

  describe "speed ↔ quality control" do
    setup do
      clear_projects()
      :ok
    end

    test "selecting fast threads :quality_level \"fast\" into the task opts", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      write_provider_profile_config()
      point_registry_at_test_config!()

      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)

      # Seed a real git repo so the doomed wrapper's life is pure validation
      # (make_git_repo!/1): the invalid node_path kills it at validation,
      # before any agent dispatch (see "task_submit clears the prompt").
      make_git_repo!(tmp_dir)
      await_async_loads(view)

      for level <- ["fast", "high_quality"] do
        render_click(view, "select_quality_level", %{"level" => level})
        assert assigns(view)[:quality_level] == level

        seq = assigns(view)[:task_launch_seq]

        _html =
          view
          |> element("#task-form")
          |> render_submit(%{
            prompt: "build me a thing",
            mode: "evolve_simple",
            node_path: "./nonexistent-dir"
          })

        html = await_task_launch(view, seq)
        assert html =~ "task started with ID:"
        task_id = cleanup_launched_task(html)
        task = EvoGit.TaskRegistry.get_task(task_id)

        assert quality_level_opt(task) == level
      end
    end

    test "the default balanced selection adds NO :quality_level opt", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      write_provider_profile_config()
      point_registry_at_test_config!()

      {:ok, view, _html} = live(conn, ~p"/projects")

      open_project!(view, tmp_dir)

      # Never touched → the assign keeps its "balanced" default.
      assert assigns(view)[:quality_level] == "balanced"

      make_git_repo!(tmp_dir)
      await_async_loads(view)

      _html =
        view
        |> element("#task-form")
        |> render_submit(%{
          prompt: "build me a thing",
          mode: "evolve_simple",
          node_path: "./nonexistent-dir"
        })

      html = await_task_launch(view)
      assert html =~ "task started with ID:"
      task_id = cleanup_launched_task(html)
      task = EvoGit.TaskRegistry.get_task(task_id)

      # "balanced" is identical to absent for the core, so the key is omitted.
      refute has_quality_level_opt?(task)
    end
  end
end
