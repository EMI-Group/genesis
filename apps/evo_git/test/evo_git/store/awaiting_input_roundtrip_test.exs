defmodule EvoGit.Store.AwaitingInputRoundtripTest do
  @moduledoc """
  The store half of P3's `:awaiting_input` / `tasks.session_mode` contract.

  An interactive agent session yields to the NON-TERMINAL status
  `:awaiting_input` between exchanges and persists its driver mode in
  `tasks.session_mode` (`"oneshot"` default, `"interactive"`). This suite pins
  that both facts survive the WHOLE store read surface — the full row read, the
  lightweight detail read, the paged summary projection, the summary reads, and
  the liveness/cleanup projections — because a status that silently degrades to
  `:pending` (or a mode that degrades to `"oneshot"`) would make an idle
  session look either like a fresh task or like an ordinary one-shot run.

  Pinned here:

    * `(a)` `put_task/2` + `get_task/2`, `get_task_lite/2`, the paged row and
      the summary row all report `:awaiting_input` VERBATIM (never masked to
      `:pending`), and the raw stored TEXT is `"awaiting_input"`;
    * `(b)` `select_finished_task_ids/1` does NOT return it (cleanup must never
      delete a waiting session) while `select_running_lease_info/1` DOES (boot
      reconciliation and the heartbeat must still see it);
    * `(c)` `session_mode` round-trips `"interactive"`, defaults to `"oneshot"`
      when absent from both the struct and the opts, an opts-supplied mode wins
      over the struct's default, and a NULL cell written before the column
      existed (or by an older build) reads back as `"oneshot"`;
    * `(d)` `EvoGit.Store.Types.SessionMode.cast/1` rejects an unknown value at
      cast time.

  Isolation: every test starts its OWN uniquely-named `EvoGit.Store` GenServer
  on its own SQLite file, which is a byte copy of the module's schema-complete
  template (`EvoGit.TestSupport.StoreTemplate`), so no shared application state
  is touched and the module runs `async: true`. The one raw NULL write goes
  through `EvoGit.Repo.query!/2` on that isolated repository.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Types.SessionMode
  alias EvoGit.TaskInfo
  alias EvoGit.TestSupport.StoreTemplate

  @started_at ~U[2024-05-05 05:05:05.555Z]
  @started_at_iso "2024-05-05T05:05:05.555Z"

  # ONE schema-complete template per module; each test copies it and boots its
  # OWN database file from the copy.
  setup_all do
    {:ok, %{copy_db: StoreTemplate.new!()}}
  end

  setup %{copy_db: copy_db} do
    Process.put(:store_template_copy, copy_db)
    :ok
  end

  # ── (a) status round-trip ─────────────────────────────────────────────────

  describe "(:awaiting_input round-trip)" do
    test "put_task/get_task and get_task_lite keep :awaiting_input verbatim" do
      store = start_store!()
      task = task(%{})

      assert :ok = Store.put_task(store, task)

      full = Store.get_task(store, task.id)
      assert %TaskInfo{} = full
      assert full.status == :awaiting_input
      refute full.status == :pending

      lite = Store.get_task_lite(store, task.id)
      assert %TaskInfo{} = lite
      assert lite.status == :awaiting_input
      refute lite.status == :pending
    end

    test "the paged row and the summary row report :awaiting_input" do
      store = start_store!()
      task = task(%{})

      assert :ok = Store.put_task(store, task)

      assert %{rows: [row], total: 1} = Store.select_tasks_page(store, limit: 10)
      assert row.id == task.id
      assert row.status == :awaiting_input
      refute row.status == :pending

      assert [summary] = Store.select_tasks_summary(store, [:awaiting_input], nil)
      assert summary.id == task.id
      assert summary.status == :awaiting_input

      # The changed-since read is the dashboard's incremental refresh: a row
      # written now must be included, with the same status.
      assert [changed] =
               Store.select_tasks_changed_since(store, "2000-01-01T00:00:00.000Z")

      assert changed.id == task.id
      assert changed.status == :awaiting_input
    end

    test "the raw stored status TEXT is exactly \"awaiting_input\"" do
      store = start_store!()
      task = task(%{})

      assert :ok = Store.put_task(store, task)

      assert [[stored]] = raw_rows(store, "SELECT status FROM tasks WHERE id = ?", [task.id])
      assert stored == "awaiting_input"
    end
  end

  # ── (b) finished / lease classification ───────────────────────────────────

  describe "(finished vs lease classification)" do
    test "select_finished_task_ids/1 omits it while select_running_lease_info/1 includes it" do
      store = start_store!()
      waiting = task(%{lease_expires_at: 999_999_999_999})

      assert :ok = Store.put_task(store, waiting)

      refute waiting.id in Store.select_finished_task_ids(store)

      assert [%{id: id, status: :awaiting_input}] =
               Enum.filter(Store.select_running_lease_info(store), &(&1.id == waiting.id))

      assert id == waiting.id
    end

    test "a terminal row is finished and absent from lease info (contrast)" do
      store = start_store!()

      done = task(%{id: next_id(), status: :completed, finished_at: @started_at})
      waiting = task(%{id: next_id(), status: :awaiting_input})

      assert :ok = Store.put_task(store, done)
      assert :ok = Store.put_task(store, waiting)

      finished_ids = Store.select_finished_task_ids(store)
      assert done.id in finished_ids
      refute waiting.id in finished_ids

      lease_ids = Enum.map(Store.select_running_lease_info(store), & &1.id)
      assert waiting.id in lease_ids
      refute done.id in lease_ids
    end
  end

  # ── (c) session_mode round-trip ───────────────────────────────────────────

  describe "(session_mode round-trip)" do
    test "\"interactive\" round-trips through get_task, the paged row and the summary" do
      store = start_store!()
      task = task(%{session_mode: "interactive"})

      assert :ok = Store.put_task(store, task)

      assert Store.get_task(store, task.id).session_mode == "interactive"
      assert Store.get_task_lite(store, task.id).session_mode == "interactive"

      assert %{rows: [row]} = Store.select_tasks_page(store, limit: 10)
      assert row.session_mode == "interactive"

      assert [summary] = Store.select_tasks_summary(store, [], nil)
      assert summary.session_mode == "interactive"
    end

    test "defaults to \"oneshot\" when the struct and the opts omit it" do
      store = start_store!()
      # `%TaskInfo{}`'s own default, and no `:session_mode` opt.
      assert %TaskInfo{session_mode: "oneshot"} = task = task(%{})

      assert :ok = Store.put_task(store, task)

      assert Store.get_task(store, task.id).session_mode == "oneshot"
      assert Store.get_task_lite(store, task.id).session_mode == "oneshot"
      assert %{rows: [%{session_mode: "oneshot"}]} = Store.select_tasks_page(store, limit: 10)
      assert [%{session_mode: "oneshot"}] = Store.select_tasks_summary(store, [], nil)

      assert [[stored]] =
               raw_rows(store, "SELECT session_mode FROM tasks WHERE id = ?", [task.id])

      assert stored == "oneshot"
    end

    test "an opts-supplied :session_mode wins over the struct default" do
      store = start_store!()

      task = %TaskInfo{
        id: next_id(),
        type: :reflect,
        status: :awaiting_input,
        started_at: @started_at,
        opts: [objective: "inspect", session_mode: "interactive"]
      }

      assert :ok = Store.put_task(store, task)

      assert Store.get_task(store, task.id).session_mode == "interactive"
      assert %{rows: [%{session_mode: "interactive"}]} = Store.select_tasks_page(store, limit: 10)
    end

    test "a NULL cell (written before the column existed) reads back as \"oneshot\"" do
      store = start_store!()
      id = next_id()

      insert_raw_null_session_mode!(store, id)

      # The raw cell really is NULL — not the `"oneshot"` value.
      assert [[nil]] = raw_rows(store, "SELECT session_mode FROM tasks WHERE id = ?", [id])

      assert Store.get_task(store, id).session_mode == "oneshot"
      assert Store.get_task_lite(store, id).session_mode == "oneshot"

      assert %{rows: rows} = Store.select_tasks_page(store, limit: 10)
      assert [%{id: ^id, session_mode: "oneshot"}] = rows

      assert [summary] = Store.select_tasks_summary(store, [], nil)
      assert summary.id == id
      assert summary.session_mode == "oneshot"

      # The status of that legacy row is untouched by the session_mode decode.
      assert Store.get_task(store, id).status == :running
    end
  end

  # ── (d) cast-time validation ──────────────────────────────────────────────

  describe "(SessionMode.cast/1)" do
    test "accepts the canonical values, normalizes nil and atoms" do
      assert {:ok, "oneshot"} = SessionMode.cast("oneshot")
      assert {:ok, "interactive"} = SessionMode.cast("interactive")
      # Round-trip safety for an already-decoded value.
      assert {:ok, "interactive"} = SessionMode.cast(:interactive)
      # A missing value is the documented default, never an error.
      assert {:ok, "oneshot"} = SessionMode.cast(nil)
    end

    test "rejects an unknown spelling and a non-string value at cast time" do
      assert :error = SessionMode.cast("bogus")
      assert :error = SessionMode.cast("")
      assert :error = SessionMode.cast(123)
      assert :error = SessionMode.cast(%{mode: "interactive"})
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Uniquely-named store GenServer on its own tmp SQLite file (the idiom
  # `store_invariants_test.exs` uses). The file starts as a copy of the
  # module's schema template, so boot only runs the probe-guarded no-op
  # migrations.
  defp start_store! do
    unique =
      "#{System.pid()}_#{System.system_time(:millisecond)}_" <>
        "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}"

    data_dir = Path.join(System.tmp_dir!(), "evogit_awaiting_#{unique}.sqlite")
    name = :"awaiting_store_#{unique}"

    # The module's template copy function, put in the test's process dictionary
    # by `setup/1` (a `setup_all` value cannot reach a helper called from a
    # test body).
    Process.get(:store_template_copy).(data_dir)

    {:ok, pid} = Store.start_link(data_dir: data_dir, name: name, pool_size: 1)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000), else: :ok
      File.rm(data_dir)
      File.rm(data_dir <> "-wal")
      File.rm(data_dir <> "-shm")
    end)

    name
  end

  defp task(overrides) do
    struct(
      %TaskInfo{
        id: next_id(),
        type: :evolve,
        status: :awaiting_input,
        opts: [path: "/tmp/repo", mode: "simple"],
        started_at: @started_at
      },
      overrides
    )
  end

  defp next_id, do: "task-awaiting-#{System.unique_integer([:positive, :monotonic])}"

  # Raw INSERT that OMITS `session_mode`, so SQLite stores NULL — the exact
  # shape a row written before migration `…00008` (or by an older build) has.
  # Through the typed schema the column would be dumped as `"oneshot"`; the
  # raw statement is what proves the READ path's NULL handling.
  defp insert_raw_null_session_mode!(store, id) do
    opts = ~s({"path":"/tmp/repo","mode":"simple"})

    raw_query!(
      store,
      """
      INSERT INTO tasks (id, type, status, opts, started_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [id, "evolve", "running", opts, @started_at_iso, @started_at_iso]
    )

    :ok
  end

  defp raw_rows(store, sql, params) do
    raw_query!(store, sql, params).rows
  end

  defp raw_query!(store, sql, params) do
    repo = Store.__repo_pid__(store)
    RepoScope.with_repo(repo, fn -> Repo.query!(sql, params) end)
  end
end
