defmodule EvoGit.Store.CoveringIndexTest do
  @moduledoc """
  Coverage for `20260815000004_covering_indexes` — the two COVERING indexes that
  let the id-oriented task reads answer from the index with NO table access.

  The incident this pins: `EvoGit.Store.select_task_ids([:completed, :failed,
  :cancelled])` (the dashboard task-list projection,
  `EvoGit.Store.Operations.Lightweight.select_task_ids/2`) took **26.5 s** on the
  live `tasks.sqlite` (442 MB, 953 rows) and blew the DBConnection call deadline,
  killing the Store. The existing `(status, started_at)` composite seeks the
  right rows but does not CARRY `updated_at`/`id`, so each matching row needed a
  table fetch — and those columns sit physically LAST, behind the multi-MB
  `logs`/`opts`/`result` blob overflow chains.

  Three halves, all against a REAL dynamic repo booted on a copy of a seeded
  SQLite file in a unique tmp dir (`async: true` is safe — every test owns its
  own database file, and `EvoGit.Store.Boot` serializes concurrent migration
  runs with its `:global` lock):

    * **PLAN** — the ACTUAL SQL each lightweight read emits (captured from the
      repo's `[:evo_git, :repo, :query]` telemetry, so the assertions are tied to
      the generated statements instead of hand-written look-alikes) is replayed
      through `EXPLAIN QUERY PLAN` and asserted to be index-only for the reads
      this migration serves (no `USING INDEX <name>` table fetch, no temp
      B-tree). The reads left deliberately untouched by this migration are
      asserted to stay at least SEEK-served, and a companion test DROPs both
      indexes and shows the table-fetch plans coming back — proving the plan
      assertions are not vacuous.
    * **DDL** — both indexes exist as plain non-unique indexes with exactly
      their declared columns (positionally, via `PRAGMA index_info`), the
      migrator is idempotent, and the migration's post-condition rejects a
      same-named index of another shape.
    * **CORRECTNESS** — a new index must never change WHICH rows a query
      returns: every lightweight read is checked against the seeded data, the
      cleanup reads against an Elixir-side oracle computed from
      `select_cleanup_info/1`.

  ## Version `20260815000004`, and a fresh database

  `20260815000001_baseline_adoption` creates the final six `idx_tasks_*`
  indexes, these two included, so this migration is an idempotent no-op on a
  fresh database. The DDL tests below therefore re-arm version
  `20260815000004` (`DELETE FROM schema_migrations`) to drive the real module a
  second time through the real migrator. The four single-column legacy indexes
  (`idx_tasks_status`, `idx_tasks_finished_at`, `idx_tasks_project_path`,
  `idx_tasks_lease_expires_at`) are never created any more —
  `20260815000006_prune_redundant_indexes` only drops them on an adopted
  database — so every plan below rides the six-index set.

  ## Why the DDL/plan-sequencing tests open a SECOND connection

  `xqlite` caches a prepared statement's plan PER CONNECTION, and that cache is
  NOT invalidated by `DROP INDEX` (verified: the same `EXPLAIN QUERY PLAN` text
  replayed on the same connection after a drop still reports the dropped index).
  The migrator-idempotency test therefore boots its store with `pool_size: 1`
  (the same reason and shape as `composite_index_test.exs`), and the
  non-vacuity test observes the post-DDL plans on a FRESH connection opened on
  the same database file — a new connection prepares anew and reports the truth.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Codec
  alias EvoGit.Store.Operations.Lightweight
  alias EvoGit.Store.Operations.Tasks
  alias EvoGit.Store.RepoScope
  alias EvoGit.TaskInfo

  @status_index "idx_tasks_status_updated_at_id"
  @finished_index "idx_tasks_finished_at_id"
  @migration_version 20_260_815_000_004

  # Seed shape: a 10-status cycle repeated 150 times → 1 500 rows.
  @status_cycle ~w(completed failed cancelled completed running pending finalizing completed failed cancelling)
  @cycle_length length(@status_cycle)
  @seed_rows 1_500
  # Terminal statuses — the only rows carrying a `finished_at` (mirroring the
  # real store, where `:finalizing` has none) and the rows
  # `select_cleanup_info/1,3` actually see.
  @terminal_statuses ~w(completed failed cancelled)

  # ── setup / helpers ──────────────────────────────────────────────────────

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit_covering_idx_#{:os.getpid()}_#{System.system_time(:millisecond)}_" <>
          "#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    # ONE seeded template database, checkpointed and closed; every test copies
    # the file (a few hundred KB of pages) and boots its own repo on the copy.
    template = Path.join(root, "template.sqlite")
    {:ok, pid} = Boot.start_dynamic(template, pool_size: 1)
    Process.unlink(pid)

    # The seed writes `:failed` rows, and `Operations.Tasks` deliberately logs a
    # `Store: FAILED_WRITE …` warning (plus a stacktrace) for EVERY new failed
    # write — from the STORE's write path, i.e. not from the test process, so the
    # suite-wide `ExUnit.start(capture_log: true)` (test-process only) cannot
    # reach it, and `setup_all/1` is not inside a per-test log capture either. The
    # production diagnostic stays exactly as it is; it is captured HERE, at the
    # test boundary.
    seed_log = capture_seed_log(fn -> seed_tasks!(pid) end)

    assert_seed_warnings_are_ours!(seed_log)

    query_rows(pid, "PRAGMA wal_checkpoint(TRUNCATE)")
    :ok = Boot.stop(pid)

    {:ok, %{root: root, template: template}}
  end

  # Copies the seeded template to a per-test database file.
  defp copy_db!(%{root: root, template: template}, tag) do
    database = Path.join(root, "evogit_covering_#{tag}.sqlite")
    File.cp!(template, database)
    database
  end

  # Boots a dynamic repo on a COPY of the seeded template. `opts` go straight to
  # `Boot.start_dynamic/2` (the DDL-sequencing tests pass `pool_size: 1`).
  defp boot_copy!(ctx, tag, opts \\ []), do: ctx |> copy_db!(tag) |> boot!(opts)

  # Opens a repo on an EXISTING database file — used for the second, fresh
  # connection of the plan-non-vacuity test.
  defp boot!(database, opts) do
    {:ok, pid} = Boot.start_dynamic(database, opts)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)
    pid
  end

  defp query_rows(pid, sql, params \\ []) do
    RepoScope.with_repo(pid, fn -> Repo.query!(sql, params).rows end)
  end

  defp index_columns(pid, name) do
    pid
    |> query_rows("PRAGMA index_info(#{name})")
    |> Enum.map(fn [_seqno, _cid, column] -> column end)
  end

  # ── seed data ────────────────────────────────────────────────────────────

  # Deterministic rows across EVERY status, 7 project paths, distinct
  # `started_at` values and a `finished_at` only on terminal rows. Every third
  # row carries a 20 kB log payload, i.e. a real overflow chain behind the row —
  # the shape that made the pre-migration per-row fetch pathological.
  defp seed_tasks!(pid) do
    base = ~U[2026-03-01 12:00:00.000Z]

    for i <- 1..@seed_rows do
      status = status_at(i)

      :ok =
        Tasks.put_task(pid, %TaskInfo{
          id: seed_id(i),
          type: :evolve,
          status: String.to_atom(status),
          opts: [path: project_path(i), mode: "simple", objective: "seed #{i}"],
          started_at: DateTime.add(base, -i, :second),
          finished_at: finished_at(i),
          logs: if(rem(i, 3) == 0, do: [String.duplicate("x", 20_000)], else: []),
          result: {:ok, %{commit_sha: "sha-#{i}", branch_name: nil, result: "done #{i}"}},
          agent_count: 1,
          project_path: project_path(i)
        })
    end

    :ok
  end

  defp seed_id(i), do: "covering-#{i}"
  defp project_path(i), do: "/p/#{rem(i, 7)}"
  defp status_at(i), do: Enum.at(@status_cycle, rem(i, @cycle_length))

  defp finished_at(i) do
    if status_at(i) in @terminal_statuses do
      # Increasing with `i` so the cleanup cutoff below splits the finished rows
      # deterministically.
      DateTime.add(~U[2026-03-01 12:00:00.000Z], i * 60, :second)
    end
  end

  defp ids_with_statuses(statuses) do
    for i <- 1..@seed_rows, status_at(i) in statuses, do: seed_id(i)
  end

  defp all_ids, do: for(i <- 1..@seed_rows, do: seed_id(i))

  # ── seed log capture (scoped to the SEEDING process, not a time window) ───

  # Forwards log events to the capturing test process. Installed only for the
  # duration of the seed (see `capture_seed_log/1`).
  defmodule SeedLogCapture do
    @moduledoc false

    # Runs in the EMITTING process — `send/2` has completed before the emitting
    # `Logger.warning/1` returns, so the capture needs no settle window.
    def log(event, %{config: %{pid: pid}}) do
      send(pid, {:seed_log, to_binary(event.msg)})
      :ok
    end

    defp to_binary({:string, message}), do: IO.iodata_to_binary(message)
    defp to_binary({:report, report}), do: inspect(report)
    defp to_binary({format, args}), do: IO.iodata_to_binary(:io_lib.format(format, args))

    # `:logger` handler filters. `keep?/2` selects the SEEDING process for the
    # CAPTURING handler; `drop?/2` is installed on the DEFAULT handler for the
    # same window, so our lines do not ALSO reach the console while a sibling's
    # keep reaching it untouched (`:ignore` = "this filter does not decide", i.e.
    # the default handler logs as usual).
    def keep?(%{meta: %{pid: seed_pid}}, seed_pid), do: :log
    def keep?(_event, _seed_pid), do: :stop

    def drop?(%{meta: %{pid: seed_pid}}, seed_pid), do: :stop
    def drop?(_event, _seed_pid), do: :ignore
  end

  # Collects the log events the SEED emits and returns them as a list of message
  # strings.
  #
  # `ExUnit.CaptureLog.capture_log/2` would also catch the store's diagnostic, but
  # its window is process-AGNOSTIC: while the 1 500-row seed runs (about a second)
  # it would also swallow the lines of every sibling `async: true` module that
  # happens to log — and this module is `async: true`. The capture is therefore
  # scoped to the EMITTING PROCESS instead (not the group leader: concurrent
  # `setup_all/1` processes SHARE a group leader, so filtering on that catches
  # siblings too — verified the hard way).
  #
  # Every failed-write diagnostic the seed produces is emitted from THIS process:
  # `Tasks.put_task/2` runs the diagnostic inside the caller's transaction (see
  # `RepoScope.with_repo/2`). If that ever moves into the store's writer GenServer,
  # `assert_seed_warnings_are_ours!/1` fails LOUDLY on the count rather than
  # silently capturing nothing.
  defp capture_seed_log(fun) do
    handler_id = :evogit_covering_index_seed_log
    seed_pid = self()

    :ok =
      :logger.add_handler(handler_id, SeedLogCapture, %{
        level: :warning,
        config: %{pid: seed_pid},
        filters: [seed_pid: {&SeedLogCapture.keep?/2, seed_pid}],
        filter_default: :log
      })

    silence_console_during(handler_id, seed_pid)

    # `try/after` ONLY to detach the handler/filter on a raised seed failure
    # (teardown cleanup must not mask the real error) — the same rationale the
    # suite uses for test-only cleanup.
    try do
      fun.()
      drain_seed_log([])
    after
      _ = :logger.remove_handler_filter(:default, handler_id)
      :ok = :logger.remove_handler(handler_id)
    end
  end

  # Keeps OUR diagnostics off the console for the capture window by filtering the
  # DEFAULT handler only — never by removing it, and never by touching the global
  # level: another process's events still reach that handler untouched.
  #
  # `{:not_found, :default}` means a sibling `async: true` module's
  # `ExUnit.CaptureLog` window currently owns the console (it swaps `:default`
  # out); that window swallows everything anyway, so there is nothing to filter.
  defp silence_console_during(handler_id, seed_pid) do
    case :logger.add_handler_filter(:default, handler_id, {&SeedLogCapture.drop?/2, seed_pid}) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
    end
  end

  defp drain_seed_log(acc) do
    receive do
      {:seed_log, message} -> drain_seed_log([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Pins that the capture above saw exactly this seed's own `FAILED_WRITE`
  # diagnostics — one per newly-`:failed` row, and NOTHING else. The "nothing
  # else" half is safe to assert because the capture is scoped to the seeding
  # process: no sibling module can land in it.
  defp assert_seed_warnings_are_ours!(messages) do
    expected = ids_with_statuses(["failed"])

    # Only OUR diagnostics are collected: a sibling `async: true` module can still
    # land a line in the window (its emitter pid is compared against the seed pid,
    # so it is not counted here and is never swallowed by our `:default` filter).
    ids =
      Enum.flat_map(messages, fn message ->
        case Regex.run(~r/\AStore: FAILED_WRITE task_id=(\S+) /, message) do
          [_, id] -> [id]
          nil -> []
        end
      end)

    assert length(ids) == length(expected),
           "expected one FAILED_WRITE warning per newly-:failed seed row " <>
             "(#{length(expected)}), captured #{length(ids)}"

    assert Enum.sort(ids) == Enum.sort(expected),
           "the captured FAILED_WRITE warnings do not name the seeded :failed rows"
  end

  # ── EXPLAIN QUERY PLAN plumbing ──────────────────────────────────────────

  # The SELECT statements an operation actually emits (captured off the repo's
  # query telemetry, so the plans asserted below belong to the GENERATED SQL).
  # The handler is BEAM-wide while attached, so it forwards only events emitted
  # by THIS test process (sibling `async: true` suites query their own repos).
  defp capture_statements(pid, fun) do
    test_pid = self()
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:evo_git, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid do
          send(test_pid, {:captured_sql, metadata.query, metadata.params})
        end
      end,
      nil
    )

    try do
      _ = RepoScope.with_repo(pid, fun)

      drain_statements([])
      |> Enum.filter(fn {sql, _params} ->
        sql |> String.trim_leading() |> String.upcase() |> String.starts_with?("SELECT")
      end)
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_statements(acc) do
    receive do
      {:captured_sql, sql, params} -> drain_statements([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp plan_text(pid, {sql, params}) do
    pid
    |> query_rows("EXPLAIN QUERY PLAN " <> sql, params)
    |> Enum.map_join(" | ", fn row -> List.last(row) end)
  end

  # Plan of the single SELECT statement `fun` emits.
  defp plan_for!(pid, fun) do
    case capture_statements(pid, fun) do
      [statement] -> plan_text(pid, statement)
      other -> flunk("expected exactly one SELECT statement, captured: #{inspect(other)}")
    end
  end

  # A covering plan is reported as `SEARCH|SCAN <alias> USING COVERING INDEX
  # <name>` — a non-covering one as `USING INDEX <name>` plus an implicit table
  # fetch. These two helpers assert the difference.
  defp assert_covering(plan, index) do
    assert plan =~ "USING COVERING INDEX #{index}",
           "expected a covering plan over #{index}, got: #{plan}"

    refute plan =~ ~r/USING INDEX idx_tasks_/,
           "expected NO table-backed index traversal, got: #{plan}"
  end

  defp refute_covering(plan) do
    refute plan =~ "COVERING INDEX", "expected the pre-migration plan, got: #{plan}"
  end

  # ── PLAN: the incident query ─────────────────────────────────────────────

  describe "select_task_ids/2 (the 26.5 s incident query) is index-only" do
    test "status-filtered: COVERING INDEX seek, no table access", ctx do
      pid = boot_copy!(ctx, "plan_incident")

      plan =
        plan_for!(pid, fn ->
          Lightweight.select_task_ids(pid, [:completed, :failed, :cancelled])
        end)

      assert_covering(plan, @status_index)
      assert plan =~ "SEARCH"
      refute plan =~ ~r/\bSCAN t0\b/
      refute plan =~ "TEMP B-TREE"
    end

    test "no status filter ([]): a full COVERING index scan", ctx do
      pid = boot_copy!(ctx, "plan_all_statuses")

      plan = plan_for!(pid, fn -> Lightweight.select_task_ids(pid, []) end)

      assert_covering(plan, @status_index)
      assert plan =~ ~r/\bSCAN t0\b/
    end
  end

  # ── PLAN: the rest of the lightweight reads ──────────────────────────────

  describe "the other lightweight reads" do
    test "select_finished_task_ids/1 is served by the status covering index", ctx do
      pid = boot_copy!(ctx, "plan_finished")

      plan = plan_for!(pid, fn -> Lightweight.select_finished_task_ids(pid) end)

      # `status NOT IN (...)` cannot seek, but a covering index scan still keeps
      # every table page (and every blob overflow chain) out of the read.
      assert_covering(plan, @status_index)
    end

    test "select_cleanup_info/1 walks the finished_at covering index", ctx do
      pid = boot_copy!(ctx, "plan_cleanup_one")

      plan = plan_for!(pid, fn -> Lightweight.select_cleanup_info(pid) end)

      # A full covering index SCAN (the statement has no range predicate) — the
      # point is that no task-table page is touched.
      assert_covering(plan, @finished_index)
      assert plan =~ ~r/\bSCAN t0 USING COVERING INDEX/
    end

    test "select_cleanup_info/3: both the age cut and the count trim are covering", ctx do
      pid = boot_copy!(ctx, "plan_cleanup_three")

      statements =
        capture_statements(pid, fn ->
          Lightweight.select_cleanup_info(pid, cutoff_iso(), 100)
        end)

      assert length(statements) == 2

      for statement <- statements do
        plan = plan_text(pid, statement)

        assert_covering(plan, @finished_index)
        refute plan =~ "TEMP B-TREE"
      end
    end

    test "select_task_paths/0 rides the path composite as a covering index", ctx do
      pid = boot_copy!(ctx, "plan_paths")

      plan = plan_for!(pid, fn -> Lightweight.select_task_paths(pid) end)

      # Unchanged by this migration — a new index would only cost write time.
      # The leading `project_path` of the path composite answers the read from
      # the index b-tree alone (the single-column `idx_tasks_project_path` does
      # not exist any more).
      assert_covering(plan, "idx_tasks_project_path_started_at")
      assert plan =~ ~r/\bSCAN t0 USING COVERING INDEX/
    end

    test "select_running_lease_info/1 stays a seek (live rows are a handful by design)", ctx do
      pid = boot_copy!(ctx, "plan_lease")

      plan = plan_for!(pid, fn -> Lightweight.select_running_lease_info(pid) end)

      # Deliberately NOT given a dedicated covering index: on a real database
      # this matches only the live tasks, and this synthetic seed is the only
      # place where those are a large fraction of the table. The status seek
      # rides the composite `(status, started_at)`. What must never come back is
      # a full table scan.
      assert plan =~ "SEARCH t0 USING INDEX idx_tasks_status_started_at"
      refute plan =~ ~r/\bSCAN t0\b/
    end
  end

  # ── PLAN non-vacuity + the migration restoring the shape ─────────────────

  describe "the plan assertions are non-vacuous" do
    test "without the indexes the table-fetch plans come back, and a re-run restores them",
         ctx do
      # ONE connection for the DDL itself (see the moduledoc); the plans are then
      # observed on FRESH connections opened on the SAME database file, because
      # a connection's cached EXPLAIN plan survives a `DROP INDEX`.
      database = copy_db!(ctx, "plan_dropped")
      pid = boot!(database, pool_size: 1)

      query_rows(pid, "DROP INDEX #{@status_index}")
      query_rows(pid, "DROP INDEX #{@finished_index}")

      fresh = boot!(database, pool_size: 1)

      incident_plan =
        plan_for!(fresh, fn ->
          Lightweight.select_task_ids(fresh, [:completed, :failed, :cancelled])
        end)

      refute_covering(incident_plan)
      assert incident_plan =~ "USING INDEX idx_tasks_status_started_at"

      finished_plan = plan_for!(fresh, fn -> Lightweight.select_finished_task_ids(fresh) end)
      refute_covering(finished_plan)
      assert finished_plan =~ ~r/\bSCAN t0\b/

      cleanup_plan = plan_for!(fresh, fn -> Lightweight.select_cleanup_info(fresh) end)
      refute_covering(cleanup_plan)
      assert cleanup_plan =~ ~r/\bSCAN t0\b/

      # Re-arm the migration (the only way to drive it again through the REAL
      # migrator) and let it restore the declared shape. Only version
      # `20260815000004` is pending, so the prune migration
      # (`20260815000006`) does not re-run and cannot mask the restore.
      query_rows(pid, "DELETE FROM schema_migrations WHERE version = #{@migration_version}")
      assert Boot.run_migrations(pid) == [@migration_version]

      restored = boot!(database, pool_size: 1)

      assert_covering(
        plan_for!(restored, fn ->
          Lightweight.select_task_ids(restored, [:completed, :failed, :cancelled])
        end),
        @status_index
      )

      assert_covering(
        plan_for!(restored, fn -> Lightweight.select_cleanup_info(restored) end),
        @finished_index
      )
    end
  end

  # ── the migration's DDL shape ────────────────────────────────────────────

  describe "covering index DDL" do
    test "both indexes exist as plain non-unique indexes with exactly their declared columns",
         ctx do
      pid = boot_copy!(ctx, "ddl")

      covering_rows =
        pid
        |> query_rows("PRAGMA index_list(tasks)")
        |> Enum.map(fn [_seq, name, unique, origin, partial] ->
          {name, unique, origin, partial}
        end)
        |> Enum.filter(&(elem(&1, 0) in [@status_index, @finished_index]))
        |> Enum.sort()

      assert covering_rows ==
               Enum.sort([{@status_index, 0, "c", 0}, {@finished_index, 0, "c", 0}])

      # Column ORDER is the point (leading seek column, then the projected
      # columns) — `PRAGMA index_info` reports it positionally.
      assert index_columns(pid, @status_index) == ["status", "updated_at", "id"]
      assert index_columns(pid, @finished_index) == ["finished_at", "id"]
    end

    test "the migrator is idempotent, and the post-condition rejects a same-named index of another shape",
         ctx do
      # ONE connection (see the moduledoc): the planted index shape and the
      # migrator's own post-condition check must be seen by the connection that
      # performed the DDL.
      pid = boot_copy!(ctx, "postcondition", pool_size: 1)

      # Already current: a re-run migrates nothing and re-validates nothing.
      assert Boot.run_migrations(pid) == []

      # Plant a same-named index over the WRONG columns — the silent trap
      # `CREATE INDEX IF NOT EXISTS` alone would paper over.
      query_rows(pid, "DELETE FROM schema_migrations WHERE version = #{@migration_version}")
      query_rows(pid, "DROP INDEX #{@status_index}")
      query_rows(pid, "CREATE INDEX #{@status_index} ON tasks(status, started_at)")

      assert_raise Ecto.MigrationError, ~r/covering index idx_tasks_status_updated_at_id/, fn ->
        Boot.run_migrations(pid)
      end

      # Restoring the declared shape lets the (still pending) migration through.
      query_rows(pid, "DROP INDEX #{@status_index}")
      query_rows(pid, "CREATE INDEX #{@status_index} ON tasks(status, updated_at, id)")

      assert Boot.run_migrations(pid) == [@migration_version]
      assert index_columns(pid, @status_index) == ["status", "updated_at", "id"]
      assert index_columns(pid, @finished_index) == ["finished_at", "id"]
      assert Boot.run_migrations(pid) == []
    end
  end

  # ── CORRECTNESS: a new index never changes WHICH rows a read returns ──────

  describe "lightweight reads over covering-indexed data" do
    setup ctx do
      pid = boot_copy!(ctx, "correctness")
      {:ok, %{pid: pid}}
    end

    test "select_task_ids/2: only the requested statuses, updated_at intact", %{pid: pid} do
      wanted = [:completed, :failed, :cancelled]

      rows = Lightweight.select_task_ids(pid, wanted)

      assert Enum.sort(Enum.map(rows, & &1.id)) ==
               Enum.sort(ids_with_statuses(["completed", "failed", "cancelled"]))

      assert Enum.all?(rows, &(&1.status in wanted))
      assert Enum.all?(rows, &is_binary(&1.updated_at))

      # No filter: every seeded row, `status` decoded per row.
      all = Lightweight.select_task_ids(pid, [])
      assert Enum.sort(Enum.map(all, & &1.id)) == Enum.sort(all_ids())

      assert Enum.all?(
               all,
               &(&1.status in ~w(completed failed cancelled running pending finalizing cancelling)a)
             )
    end

    test "select_finished_task_ids/1 excludes exactly the live statuses", %{pid: pid} do
      expected = ids_with_statuses(["completed", "failed", "cancelled", "finalizing"])

      assert Lightweight.select_finished_task_ids(pid) |> Enum.sort() == Enum.sort(expected)
      refute Enum.empty?(expected)
    end

    test "select_running_lease_info/1 returns the live tasks only", %{pid: pid} do
      expected = ids_with_statuses(~w(running finalizing cancelling))

      rows = Lightweight.select_running_lease_info(pid)

      assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort(expected)
      assert Enum.all?(rows, &(&1.status in ~w(running finalizing cancelling)a))
    end

    test "select_cleanup_info/1 returns every terminal row with a decoded finished_at", %{
      pid: pid
    } do
      rows = Lightweight.select_cleanup_info(pid)

      assert Enum.sort(Enum.map(rows, & &1.id)) ==
               Enum.sort(ids_with_statuses(["completed", "failed", "cancelled"]))

      assert Enum.all?(rows, &match?(%DateTime{}, &1.finished_at))
    end

    test "select_cleanup_info/3 matches an Elixir-side oracle built from /1", %{pid: pid} do
      max_tasks = 100
      cutoff = cutoff_iso()
      cutoff_dt = DateTime.from_iso8601(cutoff) |> elem(1)

      all = Lightweight.select_cleanup_info(pid)
      assert length(all) == length(ids_with_statuses(@terminal_statuses))

      {aged, kept} = Enum.split_with(all, &(DateTime.compare(&1.finished_at, cutoff_dt) == :lt))

      trimmed =
        kept
        |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
        |> Enum.drop(max_tasks)

      expected =
        (Enum.map(aged, & &1.id) ++ Enum.map(trimmed, & &1.id)) |> Enum.sort()

      assert Lightweight.select_cleanup_info(pid, cutoff, max_tasks) |> Enum.sort() == expected
      # Guard the oracle itself: both halves must be non-empty for this assert to
      # mean anything.
      refute Enum.empty?(aged)
      refute Enum.empty?(trimmed)
    end

    test "select_task_paths/0 returns the distinct non-nil project paths", %{pid: pid} do
      assert Lightweight.select_task_paths(pid) |> Enum.sort() ==
               Enum.sort(for k <- 0..6, do: "/p/#{k}")
    end
  end

  # The fixed-precision ISO spelling the store writes, so the TEXT comparison in
  # `select_cleanup_info/3` matches the stored values byte-for-byte.
  defp cutoff_iso, do: Codec.encode_datetime(~U[2026-03-01 16:00:00.000Z])
end
