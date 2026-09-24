defmodule EvoGit.Store.BootNormalizationTest do
  @moduledoc """
  DATA-normalization tests for boot migration `20260815000002_data_normalization`
  — the Ecto port of the raw-SQL `Schema.normalize_timestamps/1` /
  `canonicalize_results/1` / `canonicalize_opts/1` boot repair steps plus the
  `mix migrate.store` denormalization backfills — exercised through
  `EvoGit.Store.Boot.start_dynamic/1`, exactly how a production task store
  boots an adopted database.

  The sibling schema-adoption unit (`repo_test.exs`) pins the SCHEMA side
  (applied versions, 20-column shape, indexes); THIS module pins the DATA side
  only: legacy VALUES sitting in a current-shape table are rewritten at boot.

  ## Fixture technique

  Normalization runs DURING boot, so PRE-normalization data cannot be seeded
  through a booted repo (a second boot finds no pending migrations and never
  re-runs the rewrite). Each test therefore creates the tables RAW via xqlite
  with the current-shape DDL copied from the baseline migration
  (`20260815000001`) — deliberately CURRENT shape so baseline adoption is a
  pure no-op (no ALTERs) and every byte change observed below is attributable
  to the data migration alone — inserts legacy-VALUE rows, closes the
  connection, and only THEN calls `Boot.start_dynamic/1`.

  Post-state is asserted through `RepoScope.with_repo/2`: `TaskRowRaw` selects
  for raw wire values, plain `Repo.query!/1` SQL for byte-identity snapshots
  and the migration's own guard predicates.

  Concurrent `Boot.start_dynamic/1` boots are safe — the migration run inside
  `EvoGit.Store.Boot` is serialized by a cluster-safe `:global.trans` lock
  around the one-time migration-module compile plus each run, and the migrator
  is always handed the PRE-LOADED `[{version, module}]` source
  (`Boot.migration_source/0`) rather than the migrations directory (see
  `EvoGit.Store.Boot`).
  ## Pinned rules (from the migration source)

    * timestamps — `strftime('%Y-%m-%dT%H:%M:%fZ', col)` where `col NOT GLOB
      '*.[0-9][0-9][0-9]Z' AND julianday(col) IS NOT NULL`, for
      `tasks.started_at`, `tasks.finished_at`, `projects.last_opened_at`
      (NOT `tasks.updated_at` — that column is only backfilled, never
      re-formatted); unparseable/NULL values are skipped.
    * results — JSON literal `null` text → SQL NULL; every other untagged
      value (raw non-JSON strings AND untagged JSON objects/arrays/scalars)
      wrapped verbatim as `{"__result_tag__":"string","value":<original>}`;
      already-tagged rows byte-identical.
    * opts — legacy positional `[key, value]` pair arrays → JSON objects,
      rewritten in ELIXIR (Jason) so JSON booleans survive as booleans (never
      `json_group_object`, which collapses them to SQLite integers); malformed
      rows left untouched.
    * `branch_name` — backfilled from `json_extract(result,
      '$.data.branch_name')` only where `branch_name IS NULL` AND the result
      carries `__result_tag__ = 'ok'`.
    * `updated_at` — backfilled where NULL as `COALESCE(finished_at,
      started_at, now)` — i.e. AFTER timestamp normalization, so the backfilled
      value is already the fixed-ms form.
    * DETS-era `tasks_quarantine` / `projects_quarantine` tables dropped.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Codec
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRowRaw

  # ── Fixtures ──────────────────────────────────────────────────────────────

  # Current-shape 20-column tasks DDL — the exact CREATE TABLE body of the
  # baseline migration (20260815000001). Created RAW (never through a prior
  # boot) so legacy values can be seeded BEFORE the data migration runs.
  @current_tasks_ddl """
  CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    type TEXT,
    status TEXT NOT NULL,
    opts TEXT,
    started_at TEXT,
    finished_at TEXT,
    logs TEXT,
    result TEXT,
    review_status TEXT,
    usage TEXT,
    agent_count INTEGER,
    base_sha TEXT,
    commit_sha TEXT,
    archive_metadata TEXT,
    lease_expires_at INTEGER,
    model_id TEXT,
    project_path TEXT,
    branch_name TEXT,
    error TEXT,
    updated_at TEXT
  )
  """

  @current_projects_ddl """
  CREATE TABLE projects (
    path TEXT PRIMARY KEY,
    name TEXT,
    last_opened_at TEXT
  )
  """

  # The migration's own timestamp-rewrite predicate (tasks.started_at
  # variant) — quoted verbatim so the "already normalized ⇒ no-op" assertion
  # pins the guard itself, not a paraphrase of it.
  @pending_started_at_sql """
  SELECT id FROM tasks
  WHERE started_at IS NOT NULL
    AND started_at NOT GLOB '*.[0-9][0-9][0-9]Z'
    AND julianday(started_at) IS NOT NULL
  """

  @tagged_ok_result ~s({"__result_tag__":"ok","data":{"branch_name":"feat/x","commit_sha":"abc"}})

  @string_wrapped_plain ~s({"__result_tag__":"string","value":"Task crashed: boom"})

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Per-test unique tmp database (`async: true` safe).
  defp db_path do
    unique = System.unique_integer([:positive, :monotonic])

    Path.join(System.tmp_dir!(), "evogit_r6b2_#{unique}_#{inspect(self())}.sqlite")
  end

  # Seeds PRE-normalization data: raw xqlite connection, current-shape tables,
  # legacy-VALUE rows, then CLOSED — the database on disk has never been booted
  # when this returns, so `Boot.start_dynamic/1` is what runs the migrations.
  #
  # `extra`:
  #   * `projects: true` — also create the `projects` table
  #   * `project_rows: [[path, name, last_opened_at], ...]`
  #   * `extra_sql: [sql, ...]` — raw statements (quarantine DDL + rows, ...)
  defp seed_db!(path, task_rows, extra \\ []) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Xqlite.open(path)

    {:ok, _} = XqliteNIF.execute(conn, @current_tasks_ddl, [])

    if extra[:projects] do
      {:ok, _} = XqliteNIF.execute(conn, @current_projects_ddl, [])
    end

    for sql <- Keyword.get(extra, :extra_sql, []) do
      {:ok, _} = XqliteNIF.execute(conn, sql, [])
    end

    Enum.each(task_rows, &insert_task!(conn, &1))

    for [proj_path, name, last_opened_at] <- Keyword.get(extra, :project_rows, []) do
      {:ok, _} =
        XqliteNIF.execute(
          conn,
          "INSERT INTO projects (path, name, last_opened_at) VALUES (?1, ?2, ?3)",
          [proj_path, name, last_opened_at]
        )
    end

    :ok = XqliteNIF.close(conn)

    on_exit(fn ->
      # Best-effort hygiene; the repo's own on_exit stops it first or the rm
      # simply unlinks the still-open inode (POSIX) — either order is safe.
      File.rm(path)
      File.rm(path <> "-wal")
      File.rm(path <> "-shm")
    end)
  end

  defp insert_task!(conn, row) do
    {:ok, _} =
      XqliteNIF.execute(
        conn,
        """
        INSERT INTO tasks (id, status, opts, started_at, finished_at, result, branch_name, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """,
        [
          row.id,
          Map.get(row, :status, "completed"),
          Map.get(row, :opts),
          Map.get(row, :started_at),
          Map.get(row, :finished_at),
          Map.get(row, :result),
          Map.get(row, :branch_name),
          Map.get(row, :updated_at)
        ]
      )
  end

  # Boots the seeded database through the REAL production entry point. The
  # migration run is serialized by the production `:global` lock in
  # `EvoGit.Store.Boot` (it also guards the one-time migration-module compile),
  # and the repo is UNLINKED: on_exit/1 runs after the test process is gone, so
  # the link's exit signal must not own the shutdown (alive-guarded stop).
  defp boot!(path) do
    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)
    pid
  end

  # Raw wire values — TaskRowRaw applies no casting, so the strings are the
  # exact bytes SQLite stores.
  defp raw_task!(pid, id), do: RepoScope.with_repo(pid, fn -> Repo.get(TaskRowRaw, id) end)

  defp query_rows(pid, sql), do: RepoScope.with_repo(pid, fn -> Repo.query!(sql).rows end)

  # Full-database snapshot for byte-identity comparison across boots.
  defp snapshot(pid) do
    {
      query_rows(pid, "SELECT * FROM tasks ORDER BY id"),
      query_rows(pid, "SELECT * FROM projects ORDER BY path"),
      query_rows(pid, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    }
  end

  # ── Timestamp normalization ───────────────────────────────────────────────

  describe "timestamp normalization" do
    test "variable-precision timestamps are rewritten to the fixed 3-digit form" do
      path = db_path()

      seed_db!(
        path,
        [
          %{
            id: "six",
            started_at: "2024-01-01T12:00:00.123456Z",
            finished_at: "2024-01-01T13:00:00.654321Z"
          },
          %{
            id: "whole",
            started_at: "2024-01-01T12:00:00Z",
            finished_at: "2024-01-01T13:00:00Z"
          },
          %{id: "garbage", started_at: "not-a-date", finished_at: "also-not-a-date"},
          %{id: "null", started_at: nil, finished_at: nil}
        ],
        projects: true,
        project_rows: [["/p-six", "P1", "2024-01-01T12:00:00.123456Z"]]
      )

      pid = boot!(path)

      # 6-digit fractional seconds are TRUNCATED to 3 digits (strftime %f).
      six = raw_task!(pid, "six")
      assert six.started_at == "2024-01-01T12:00:00.123Z"
      assert six.finished_at == "2024-01-01T13:00:00.654Z"

      # Whole seconds gain an explicit .000Z.
      whole = raw_task!(pid, "whole")
      assert whole.started_at == "2024-01-01T12:00:00.000Z"
      assert whole.finished_at == "2024-01-01T13:00:00.000Z"

      # Unparseable values are skipped by the julianday(...) IS NOT NULL guard
      # — never nulled, never mangled; NULL stays NULL.
      garbage = raw_task!(pid, "garbage")
      assert {garbage.started_at, garbage.finished_at} == {"not-a-date", "also-not-a-date"}

      null_row = raw_task!(pid, "null")
      assert {null_row.started_at, null_row.finished_at} == {nil, nil}

      # projects.last_opened_at is normalized by the same rule.
      assert query_rows(pid, "SELECT last_opened_at FROM projects WHERE path = '/p-six'") ==
               [["2024-01-01T12:00:00.123Z"]]
    end

    test "already-fixed-ms timestamps are byte-identical — the rewrite predicate selects nothing" do
      path = db_path()

      seed_db!(path, [
        %{
          id: "fixed",
          started_at: "2024-01-01T12:00:00.123Z",
          finished_at: "2024-01-01T13:00:00.500Z"
        }
      ])

      pid = boot!(path)

      fixed = raw_task!(pid, "fixed")

      # Byte-identical post-boot — including the trailing-zero ".500", which a
      # re-formatting rewrite would also preserve but which pins that nothing
      # re-spelled the value.
      assert fixed.started_at == "2024-01-01T12:00:00.123Z"
      assert fixed.finished_at == "2024-01-01T13:00:00.500Z"

      # Deviation note on "NOT rewritten": for already-fixed values the
      # strftime rewrite is byte-equivalent, so data inspection alone cannot
      # distinguish a skipped row from a rewritten one. The OBSERVABLE no-op
      # contract is the migration's own guard — after boot its WHERE clause
      # (quoted verbatim in @pending_started_at_sql) selects ZERO rows.
      assert query_rows(pid, @pending_started_at_sql) == []
    end
  end

  # ── Opts canonicalization ─────────────────────────────────────────────────

  describe "opts canonicalization" do
    test "legacy positional pair-array opts become JSON objects with booleans preserved" do
      path = db_path()

      seed_db!(path, [
        %{id: "legacy-archive", opts: ~s([["archive",true]])},
        %{id: "legacy-multi", opts: ~s([["path","/tmp/p"],["archive",true]])},
        %{id: "already-object", opts: ~s({"path":"/tmp/p","archive":false})},
        %{id: "malformed-flat", opts: ~s(["path","/tmp/p"])}
      ])

      pid = boot!(path)

      # Exact bytes: `true` stays a JSON boolean — the rewrite happens in
      # Elixir (Jason encode), never json_group_object, which would collapse
      # it to the SQLite integer 1.
      archive = raw_task!(pid, "legacy-archive")
      assert archive.opts == ~s({"archive":true})
      assert Codec.decode_opts(archive.opts) == [archive: true]

      # Multi-pair rows canonicalize to the object with every value type
      # intact (asserted order-agnostically through the decoder).
      multi = raw_task!(pid, "legacy-multi")
      assert Jason.decode!(multi.opts) == %{"path" => "/tmp/p", "archive" => true}
      assert multi_opts = Jason.decode!(multi.opts)
      assert is_boolean(multi_opts["archive"])

      # Already-object rows never match the SQL scan guard — byte-identical.
      assert raw_task!(pid, "already-object").opts == ~s({"path":"/tmp/p","archive":false})

      # Malformed rows (selected by the guard but rejected by the Elixir-side
      # all-2-element-lists check) are left untouched.
      assert raw_task!(pid, "malformed-flat").opts == ~s(["path","/tmp/p"])
    end
  end

  # ── Result canonicalization ───────────────────────────────────────────────

  describe "result canonicalization" do
    test "untagged legacy result blobs are wrapped in the modern string-tag envelope" do
      path = db_path()

      seed_db!(path, [
        %{id: "plain", result: "Task crashed: boom"},
        %{id: "untagged-obj", result: ~s({"x":1})},
        %{id: "untagged-arr", result: "[1,2]"},
        %{id: "scalar-int", result: "42"},
        %{id: "json-null", result: "null"},
        %{id: "null-result"},
        %{id: "tagged-ok", result: @tagged_ok_result},
        %{id: "tagged-error", result: ~s({"__result_tag__":"error","reason":"boom"})}
      ])

      pid = boot!(path)

      # Raw non-JSON strings: wrapped verbatim as a JSON string value.
      assert raw_task!(pid, "plain").result == @string_wrapped_plain
      assert Codec.decode_result(raw_task!(pid, "plain").result) == "Task crashed: boom"

      # Untagged JSON objects/arrays/scalars: the WHOLE text becomes the
      # string value (json_object quotes its TEXT argument) — content
      # round-trips verbatim after decode.
      assert raw_task!(pid, "untagged-obj").result ==
               ~S({"__result_tag__":"string","value":"{\"x\":1}"})

      assert Codec.decode_result(raw_task!(pid, "untagged-obj").result) == ~s({"x":1})

      assert raw_task!(pid, "untagged-arr").result ==
               ~S({"__result_tag__":"string","value":"[1,2]"})

      assert raw_task!(pid, "scalar-int").result ==
               ~s({"__result_tag__":"string","value":"42"})

      # The JSON literal `null` text becomes SQL NULL, matching a row that
      # was NULL all along.
      assert raw_task!(pid, "json-null").result == nil
      assert raw_task!(pid, "null-result").result == nil

      # Already-tagged rows are untouched — byte-identical.
      assert raw_task!(pid, "tagged-ok").result == @tagged_ok_result

      assert raw_task!(pid, "tagged-error").result ==
               ~s({"__result_tag__":"error","reason":"boom"})
    end
  end

  # ── branch_name backfill ──────────────────────────────────────────────────

  describe "branch_name backfill" do
    test "NULL branch_name is backfilled only from tagged-ok results" do
      path = db_path()

      seed_db!(path, [
        %{id: "ok-branch", result: @tagged_ok_result},
        %{id: "ok-preset", result: @tagged_ok_result, branch_name: "already/set"},
        %{
          id: "ok-no-branch",
          result: ~s({"__result_tag__":"ok","data":{"commit_sha":"abc"}})
        },
        %{id: "error-tag", result: ~s({"__result_tag__":"error","reason":"boom"})},
        %{id: "raw-string", result: "untagged result text"}
      ])

      pid = boot!(path)

      # Rule: branch_name = json_extract(result, '$.data.branch_name') where
      # branch_name IS NULL AND __result_tag__ = 'ok'.
      assert raw_task!(pid, "ok-branch").branch_name == "feat/x"

      # A non-NULL branch_name is never overwritten (IS NULL guard).
      assert raw_task!(pid, "ok-preset").branch_name == "already/set"

      # A tagged-ok result WITHOUT data.branch_name extracts NULL — the row
      # stays NULL rather than being invented.
      assert raw_task!(pid, "ok-no-branch").branch_name == nil

      # Non-ok tags never backfill...
      assert raw_task!(pid, "error-tag").branch_name == nil

      # ...and neither do rows whose result the SAME boot just canonicalized
      # to the string tag — the backfill runs after canonicalization and only
      # recognizes the 'ok' tag.
      assert raw_task!(pid, "raw-string").branch_name == nil
    end
  end

  # ── updated_at backfill ───────────────────────────────────────────────────

  describe "updated_at backfill" do
    test "NULL updated_at is backfilled as COALESCE(finished_at, started_at, now)" do
      path = db_path()

      seed_db!(path, [
        %{
          id: "both",
          started_at: "2024-01-01T12:00:00.123456Z",
          finished_at: "2024-01-01T13:00:00Z"
        },
        %{id: "started-only", started_at: "2024-01-01T12:00:00.123456Z"},
        %{id: "neither"},
        %{id: "preset", updated_at: "2020-05-05T05:05:05.555Z"},
        %{id: "preset-loose", updated_at: "2020-05-05T05:05:05.5555Z"}
      ])

      pid = boot!(path)

      # finished_at wins the COALESCE — and it is the NORMALIZED form
      # (".000Z"), proving the backfill runs AFTER timestamp normalization
      # (had it run before, the backfill would carry "2024-01-01T13:00:00Z").
      assert raw_task!(pid, "both").updated_at == "2024-01-01T13:00:00.000Z"

      # started_at is the fallback, likewise already normalized.
      assert raw_task!(pid, "started-only").updated_at == "2024-01-01T12:00:00.123Z"

      # No timestamps at all → a fresh "now" in the fixed-ms wire form.
      now_value = raw_task!(pid, "neither").updated_at
      assert Regex.match?(~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, now_value)
      assert {:ok, dt, 0} = DateTime.from_iso8601(now_value)
      assert DateTime.diff(DateTime.utc_now(), dt, :second) < 120

      # A preset updated_at is never rewritten (IS NULL guard)...
      assert raw_task!(pid, "preset").updated_at == "2020-05-05T05:05:05.555Z"

      # ...and — pinned actual behavior — updated_at is NOT in the migration's
      # timestamp-normalize list (tasks.started_at / tasks.finished_at /
      # projects.last_opened_at only), so even a non-fixed legacy spelling
      # survives boot untouched.
      assert raw_task!(pid, "preset-loose").updated_at == "2020-05-05T05:05:05.5555Z"
    end
  end

  # ── Quarantine table drops ────────────────────────────────────────────────

  describe "quarantine table drops" do
    test "the DETS-era tasks_quarantine and projects_quarantine tables are dropped" do
      path = db_path()

      seed_db!(path, [%{id: "t1"}],
        extra_sql: [
          "CREATE TABLE tasks_quarantine (id TEXT PRIMARY KEY, data TEXT)",
          "CREATE TABLE projects_quarantine (id TEXT PRIMARY KEY, data TEXT)",
          "INSERT INTO tasks_quarantine VALUES ('q1', 'quarantined')"
        ]
      )

      pid = boot!(path)

      # DROP TABLE IF EXISTS — gone, and the surviving inventory is exactly
      # the three expected tables.
      assert query_rows(pid, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") ==
               [["projects"], ["schema_migrations"], ["tasks"]]
    end
  end

  # ── Idempotent second boot ────────────────────────────────────────────────

  describe "idempotent second boot" do
    test "a second boot on the normalized database changes zero data bytes" do
      path = db_path()

      seed_db!(
        path,
        [
          %{
            id: "plain",
            started_at: "2024-01-01T12:00:00.123456Z",
            finished_at: "2024-01-01T13:00:00Z",
            result: "Task crashed: boom"
          },
          %{id: "legacy-archive", opts: ~s([["archive",true]])},
          %{id: "ok-branch", result: @tagged_ok_result},
          %{id: "no-dates"},
          %{id: "preset", branch_name: "keep/me", updated_at: "2020-05-05T05:05:05.555Z"}
        ],
        projects: true,
        project_rows: [["/p", "P", "2024-01-01T09:00:00.987654Z"]],
        extra_sql: [
          "CREATE TABLE tasks_quarantine (id TEXT PRIMARY KEY, data TEXT)",
          "CREATE TABLE projects_quarantine (id TEXT PRIMARY KEY, data TEXT)"
        ]
      )

      pid = boot!(path)

      # Sanity: the FIRST boot really normalized — the captured snapshot is
      # the post-normalization state, not the untouched seed.
      assert raw_task!(pid, "plain").started_at == "2024-01-01T12:00:00.123Z"
      assert raw_task!(pid, "plain").result == @string_wrapped_plain
      assert raw_task!(pid, "legacy-archive").opts == ~s({"archive":true})
      assert raw_task!(pid, "ok-branch").branch_name == "feat/x"

      before = snapshot(pid)

      :ok = Boot.stop(pid)

      # Re-boot the SAME database: schema_migrations is current, the migrator
      # runs nothing, and every guard in the data migration is a no-op.
      {:ok, pid2} = Boot.start_dynamic(path)
      Process.unlink(pid2)
      on_exit(fn -> if Process.alive?(pid2), do: :ok = Boot.stop(pid2) end)

      # Full-database byte identity: task rows, project rows, table inventory.
      assert snapshot(pid2) == before
    end
  end
end
