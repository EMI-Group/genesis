defmodule EvoDashWeb.ServerStatusTestRegistry do
  @moduledoc """
  Recording stand-in for `EvoGit.TaskRegistry` at the ONLY boundary the
  controller crosses: `list_task_ids/1`.

  The controller's busy set is NOT observable through the
  `:server_status_task_runner` seam: that seam replaces `task_runner/0`, i.e.
  the very function that SUPPLIES the statuses to the registry
  (`EvoGit.TaskRegistry.list_task_ids(@active_statuses)`), so injecting a runner
  hides the filter instead of exercising it.

  The busy-set tests therefore leave the runner at its production default and
  point `EvoGit.TaskRegistry.server/0`'s per-process key
  (`:evogit_task_registry_server`) at this instance: the controller then performs
  the REAL client call — `GenServer.call(server(), {:list_task_ids, statuses},
  @call_timeout)` — with its own real status list, and the recorded argument IS
  the busy set. That pins `:awaiting_input`'s exclusion atom-precisely, at the
  argument production actually sends, rather than by restating a private module
  attribute the controller does not expose.

  The reply mirrors `EvoGit.Store.select_task_ids/2`
  (`apps/evo_git/lib/evo_git/store/operations/lightweight.ex`): an empty
  `statuses` list means "no filter", a non-empty one filters by status, and the
  rows are `%{id, status, updated_at}` maps. Nothing else about the registry is
  reimplemented.

  No process-global state is involved: the instance name is unique per test and
  the `server/0` key lives in the TEST process's dictionary
  (`Phoenix.ConnTest`'s `get/2` dispatches in this same process), so it dies
  with the test.
  """

  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc "Replaces this instance's task rows (maps with `:id` and `:status`)."
  def seed(name, tasks), do: GenServer.call(name, {:seed, tasks})

  @doc "The `statuses` argument of the last `list_task_ids/1` call (`nil` before one)."
  def last_statuses(name), do: GenServer.call(name, :last_statuses)

  @impl true
  def init(_opts), do: {:ok, %{tasks: [], last_statuses: nil}}

  @impl true
  def handle_call({:seed, tasks}, _from, state), do: {:reply, :ok, %{state | tasks: tasks}}

  def handle_call(:last_statuses, _from, state), do: {:reply, state.last_statuses, state}

  def handle_call({:list_task_ids, statuses}, _from, state) do
    matching =
      case statuses do
        [] -> state.tasks
        [_ | _] -> Enum.filter(state.tasks, &(&1.status in statuses))
      end

    reply = Enum.map(matching, &Map.put(&1, :updated_at, "2026-01-01T00:00:00.000000Z"))

    {:reply, reply, %{state | last_statuses: statuses}}
  end
end

defmodule EvoDashWeb.ServerStatusControllerTest do
  # async: true — the ONLY process-global this suite touches is the
  # `:evo_dash` app-env key `:server_status_task_runner` (the seam injected by
  # `put_seam/2` below). That key is read ONLY by
  # `EvoDashWeb.ServerStatusController.task_runner/0`, which no other suite
  # exercises (grep: the key appears in no other file), and every test restores
  # the previous value in `on_exit`, so no concurrent async module can observe
  # it. Nothing else here is shared: the default-path test reads the real
  # `EvoGit.TaskRegistry` without writing to it.
  #
  # The busy-set describe below adds a second, equally local seam: a
  # uniquely-named `ServerStatusTestRegistry` (started under this test's supervisor)
  # plus the `:evogit_task_registry_server` PROCESS DICTIONARY key of the test
  # process — never an app-env write, so no other module can see it either.
  use EvoDashWeb.ConnCase, async: true

  # An explicit `as:` alias: a bare `ServerStatusTestRegistry` reference would be
  # resolved against this module's lexical nesting, which is not where the
  # stand-in is defined.
  alias EvoDashWeb.ServerStatusTestRegistry, as: FakeRegistry

  @seam :server_status_task_runner

  # The four LIVE statuses the controller counts. `:awaiting_input` is
  # deliberately absent: it marks an idle interactive session waiting for the
  # user (no worker, no LLM slot, no tool slot, no timer), so winding it down
  # during an upgrade loses no work and it must never block the CLI's
  # self-update idle gate.
  @busy_statuses [:running, :pending, :finalizing, :cancelling]
  @idle_or_terminal_statuses [:awaiting_input, :completed, :failed, :cancelled]

  describe "GET /server/status" do
    test "answers 200 JSON with exactly status, version and active_tasks", %{conn: conn} do
      put_seam(@seam, fn -> [%{id: "a"}, %{id: "b"}] end)

      conn = get(conn, "/server/status")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      body = json_response(conn, 200)

      assert body |> Map.keys() |> Enum.sort() == ["active_tasks", "status", "version"]
      assert body["status"] == "ok"
      assert is_binary(body["version"])
      assert body["version"] != ""
      assert is_integer(body["active_tasks"])
    end

    test "active_tasks counts the ids returned by the registry read", %{conn: conn} do
      put_seam(@seam, fn -> [%{id: "a"}, %{id: "b"}] end)

      assert json_response(get(conn, "/server/status"), 200)["active_tasks"] == 2
    end

    test "an empty live-task set reports 0", %{conn: conn} do
      put_seam(@seam, fn -> [] end)

      assert json_response(get(conn, "/server/status"), 200)["active_tasks"] == 0
    end

    test "a raising task read degrades to -1 and still answers 200", %{conn: conn} do
      put_seam(@seam, fn -> raise "boom" end)

      conn = get(conn, "/server/status")

      assert conn.status == 200
      assert json_response(conn, 200)["active_tasks"] == -1
    end

    # The interesting case: a registry `GenServer.call` timeout/dead process
    # EXITS the caller, which a `rescue` cannot catch — only `SafeCall.run/1`'s
    # `catch :exit` turns it into a value.
    test "an exiting task read degrades to -1", %{conn: conn} do
      put_seam(@seam, fn -> exit(:timeout) end)

      conn = get(conn, "/server/status")

      assert conn.status == 200
      assert json_response(conn, 200)["active_tasks"] == -1
    end

    test "a non-list task read degrades to -1 (never a wrong zero)", %{conn: conn} do
      put_seam(@seam, fn -> :nope end)

      conn = get(conn, "/server/status")

      assert conn.status == 200
      assert json_response(conn, 200)["active_tasks"] == -1
    end

    test "version reports the running evo_git application version", %{conn: conn} do
      body = json_response(get(conn, "/server/status"), 200)

      assert body["version"] == to_string(Application.spec(:evo_git, :vsn))
    end

    test "needs no session, CSRF token or authentication", %{conn: conn} do
      # A bare connection (no browser pipeline, no cookies) is enough.
      put_seam(@seam, fn -> [] end)

      conn = get(conn, "/server/status")

      assert conn.status == 200
      # The probe must not redirect (e.g. to the onboarding/welcome page).
      assert conn.state == :sent
    end

    # Leaves the seam at its default: the real `EvoGit.TaskRegistry` path must
    # produce an integer verdict — the task count, or `-1` when the registry is
    # unavailable — instead of raising.
    test "the default registry read returns an integer count", %{conn: conn} do
      active_tasks = json_response(get(conn, "/server/status"), 200)["active_tasks"]

      assert is_integer(active_tasks)

      if active_tasks != -1 do
        assert active_tasks >= 0
      end
    end
  end

  # The busy set is the controller's `@active_statuses` (a PRIVATE module
  # attribute — not persisted, so `__info__(:attributes)` cannot see it) handed
  # to `EvoGit.TaskRegistry.list_task_ids/1`. These tests keep the production
  # runner and record that argument instead: see `EvoDashWeb.ServerStatusTestRegistry`.
  describe "GET /server/status — the busy-status set (:awaiting_input excluded)" do
    setup :use_busy_status_registry

    test "an :awaiting_input session is not busy while a :running task is",
         %{conn: conn, registry: registry} do
      FakeRegistry.seed(registry, [
        %{id: "awaiting-1", status: :awaiting_input},
        %{id: "running-1", status: :running}
      ])

      assert json_response(get(conn, "/server/status"), 200)["active_tasks"] == 1

      statuses = FakeRegistry.last_statuses(registry)
      assert :running in statuses
      refute :awaiting_input in statuses
    end

    # Atom-precise pin of the busy set: if `:awaiting_input` (or anything else)
    # were admitted to `@active_statuses` — or one of the four were dropped —
    # this fails loudly, independently of the counting assertions below.
    test "the controller asks the registry for exactly the four live statuses",
         %{conn: conn, registry: registry} do
      FakeRegistry.seed(registry, [])

      assert json_response(get(conn, "/server/status"), 200)["active_tasks"] == 0

      assert Enum.sort(FakeRegistry.last_statuses(registry)) ==
               Enum.sort([:running, :pending, :finalizing, :cancelling])
    end

    for status <- [:running, :pending, :finalizing, :cancelling] do
      test "#{status} tasks count as busy", %{conn: conn, registry: registry} do
        busy_status = unquote(status)
        FakeRegistry.seed(registry, [%{id: "busy-1", status: busy_status}])

        assert json_response(get(conn, "/server/status"), 200)["active_tasks"] == 1
        assert busy_status in FakeRegistry.last_statuses(registry)
      end
    end

    for status <- [:awaiting_input, :completed, :failed, :cancelled] do
      test "#{status} tasks do not count as busy", %{conn: conn, registry: registry} do
        idle_status = unquote(status)
        FakeRegistry.seed(registry, [%{id: "idle-1", status: idle_status}])

        assert json_response(get(conn, "/server/status"), 200)["active_tasks"] == 0
        refute idle_status in FakeRegistry.last_statuses(registry)
      end
    end

    # The idle-gate contract: a server whose only "live" rows are parked
    # interactive sessions is IDLE, so the headless self-updater may stop it. It
    # must report 0 — never an error sentinel (`-1`) and never a positive count.
    test "a set made only of :awaiting_input sessions reports 0",
         %{conn: conn, registry: registry} do
      FakeRegistry.seed(registry, [
        %{id: "session-1", status: :awaiting_input},
        %{id: "session-2", status: :awaiting_input},
        %{id: "session-3", status: :awaiting_input}
      ])

      conn = get(conn, "/server/status")

      assert conn.status == 200
      assert json_response(conn, 200)["active_tasks"] == 0
    end

    test "a mixed set counts only the four busy statuses", %{conn: conn, registry: registry} do
      tasks =
        (@busy_statuses ++ @idle_or_terminal_statuses)
        |> Enum.with_index()
        |> Enum.map(fn {status, index} -> %{id: "task-#{index}", status: status} end)

      FakeRegistry.seed(registry, tasks)

      assert json_response(get(conn, "/server/status"), 200)["active_tasks"] ==
               length(@busy_statuses)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────

  # Points `EvoGit.TaskRegistry.server/0` at a per-test recording instance.
  #
  # `start_supervised!/1` and `Process.put/2` both run in the TEST process (a
  # module-level `setup`, never `setup_all`), which is also the process that
  # dispatches `get(conn, "/server/status")` — and `server/0` reads the key at
  # CALL time, so the controller's default runner resolves to this instance. The
  # key is process-local, so it disappears when the test process exits; there is
  # no app-env write and nothing to restore.
  defp use_busy_status_registry(_context) do
    name = :"server_status_test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({FakeRegistry, name: name})
    Process.put(:evogit_task_registry_server, name)

    {:ok, registry: name}
  end

  # Injects a runner seam and restores the previous value on exit, so no
  # `:evo_dash` app-env state leaks into another suite.
  defp put_seam(key, fun) do
    previous = Application.get_env(:evo_dash, key)
    Application.put_env(:evo_dash, key, fun)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:evo_dash, key)
        value -> Application.put_env(:evo_dash, key, value)
      end
    end)

    :ok
  end
end
