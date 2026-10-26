defmodule EvoGit.Store.OversizedRowMigrationTest do
  @moduledoc """
  Coverage for `20260815000004_compress_oversized_rows` — the one-shot rewrite
  of task rows written BEFORE the codec's transparent compression and before
  the archive-dedup persistence boundary (`EvoGit.TaskRegistry.ArchiveDedup`).

  ## Fixture shape

  Each test crafts a REAL pre-migration database with RAW xqlite (never the
  repo): the canonical 20-column `tasks` table, the `projects` table, and a
  `schema_migrations` table stamped through version 3 — i.e. exactly the state
  a booted v0.13.x database is in before this migration (004, the first of the
  two new migrations) ships. Seeded rows:

    * `big-archive` — a plain-JSON canonical `{:ok, data}` result whose
      `data.archive_records` array (~6 kB) is a verbatim duplicate of the
      `archive_metadata` column: the row this migration exists for.
    * `big-result` — a plain-JSON result with NO `archive_records` but > 4096
      bytes: compression only, nothing stripped.
    * `small` — a small plain-JSON result + a small archive: must stay
      BYTE-IDENTICAL (below the compression threshold).
    * `nil-result` — NULL `result` / `archive_metadata`: must stay NULL.

  ## Pinned contracts

    * oversized plain-JSON rows are stored as `"z1:"`-prefixed compressed text
      (`EvoGit.Store.Codec`'s marker) that decodes back to the SAME result
      MINUS `archive_records`, and to the SAME archive list;
    * a compressed result that shrank below the threshold after the archive
      strip is NOT compressed (the codec only compresses > 4096 bytes) — the
      post-condition predicate is length-based, so that is a correct final
      state;
    * `updated_at` is BYTE-IDENTICAL afterwards (the rewrite must not look like
      a task mutation) — for every row, rewritten or not;
    * small rows and NULL rows are untouched;
    * the store reads the rewrites back through the public API
      (`Store.get_task/2`);
    * a SECOND boot changes nothing (idempotent: the version is stamped, and
      even a forced re-run matches no candidate);
    * an undecodable oversized row is logged as a WARNING naming the task id
      and left exactly as it was — the migration still applies and converges.

  Never writes to the user's real data dir: every database lives under the
  per-test `System.tmp_dir!()` root.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Codec
  alias EvoGit.Store.RepoScope

  @baseline_version 20_260_815_000_001
  @normalization_version 20_260_815_000_002
  @composite_index_version 20_260_815_000_003
  @compress_rows_version 20_260_815_000_004
  @covering_index_version 20_260_815_000_005
  @archive_table_version 20_260_815_000_007

  # Ascending, exactly as `schema_migrations` reports it: the compression /
  # archive-dedup rewrite (004) runs BEFORE the covering-index build (005) so
  # the index walk never crawls the unrewritten blob overflow chains.
  @migration_versions [
    @baseline_version,
    @normalization_version,
    @composite_index_version,
    @compress_rows_version,
    @covering_index_version,
    @archive_table_version
  ]

  # The canonical 20-column DDL (identical to the baseline migration's CREATE
  # and `EvoGit.Store.Schema.create_tables/1`) — a v0.13.x database that was
  # already adopted by the Ecto migrations.
  @tasks_ddl """
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

  @projects_ddl """
  CREATE TABLE projects (
    path TEXT PRIMARY KEY,
    name TEXT,
    last_opened_at TEXT
  )
  """

  @updated_at "2024-05-05T10:00:01.000Z"

  setup do
    # pid + wall-clock ms on top of the per-BEAM unique integer: a counter
    # alone collides with a PREVIOUS run's leftover directory.
    stamp =
      "#{System.system_time(:millisecond)}_#{:os.getpid()}_#{System.unique_integer([:positive])}"

    root = Path.join(System.tmp_dir!(), "evogit_compress_rows_#{stamp}_#{inspect(self())}")

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, %{root: root}}
  end

  describe "20260815000004_compress_oversized_rows" do
    test "compresses oversized rows and drops the duplicated archive from result", %{root: root} do
      path = Path.join(root, "compress.sqlite")

      %{
        archive: archive,
        result: expected_result,
        archive_only_result: expected_archive_only,
        big_archive: big_id
      } = seed!(path)

      start_repo!(path)

      # Oversized rows (still oversized AFTER the archive strip) are compressed,
      # and so is the duplicated archive column.
      assert compressed?(raw!(path, big_id, "result"))
      assert compressed?(raw!(path, big_id, "archive_metadata"))
      assert compressed?(raw!(path, "big-result", "result"))
      assert compressed?(raw!(path, "archive-only", "archive_metadata"))

      # A result whose ONLY bulk was the duplicated archive shrinks below the
      # threshold — the codec keeps it as plain JSON, which is a correct final
      # state (and the post-condition predicate is length-based).
      refute compressed?(raw!(path, "archive-only", "result"))
      assert Codec.decode_result(raw!(path, "archive-only", "result")) == expected_archive_only

      # `result` decodes back to the EXACT same map, minus `archive_records`:
      # `archive_metadata` is the single stored copy of the per-agent archive.
      decoded = Codec.decode_result(raw!(path, big_id, "result"))

      assert decoded == expected_result
      {:ok, decoded_data} = decoded
      refute Map.has_key?(decoded_data, :archive_records)

      # ...and the archive column still carries the full list.
      assert Codec.decode_archive(raw!(path, big_id, "archive_metadata")) == archive
    end

    test "rewritten rows are readable through the public store API", %{root: root} do
      path = Path.join(root, "store_read.sqlite")
      %{archive: archive, result: expected_result, big_archive: big_id} = seed!(path)

      store = :"oversized_row_store_#{System.unique_integer([:positive])}"
      {:ok, pid} = Store.start_link(data_dir: path, name: store)
      Process.unlink(pid)

      on_exit(fn ->
        case Process.whereis(store) do
          nil -> :ok
          alive -> :ok = GenServer.stop(alive)
        end
      end)

      assert %EvoGit.TaskInfo{} = task = Store.get_task(store, big_id)
      assert task.result == expected_result
      assert task.archive_metadata == archive
      assert task.status == :completed
    end

    test "leaves small rows and NULL rows byte-identical, and never bumps updated_at", %{
      root: root
    } do
      path = Path.join(root, "untouched.sqlite")
      %{archive: _archive, result: _expected, big_archive: big_id} = seed!(path)

      before = snapshot!(path)
      start_repo!(path)
      after_ = snapshot!(path)

      # Small result + small archive: still the plain JSON we seeded, verbatim.
      refute compressed?(after_[{"small", "result"}])
      assert after_[{"small", "result"}] == before[{"small", "result"}]
      assert after_[{"small", "archive_metadata"}] == before[{"small", "archive_metadata"}]

      # NULL columns stay NULL.
      assert after_[{"nil-result", "result"}] == nil
      assert after_[{"nil-result", "archive_metadata"}] == nil

      # The rewrite never touches updated_at — for ANY row (rewritten or not).
      for {id, updated_at} <- before_updated_at!(path) do
        assert raw!(path, id, "updated_at") == updated_at
      end

      assert compressed?(raw!(path, big_id, "result"))
    end

    test "is idempotent: a second boot rewrites nothing", %{root: root} do
      path = Path.join(root, "idempotent.sqlite")
      %{big_archive: big_id} = seed!(path)

      pid = start_repo!(path)
      first = snapshot!(path)
      assert compressed?(first[{big_id, "result"}])

      :ok = Boot.stop(pid)

      # Second boot: the version is already stamped, so the migration body never
      # runs and the bytes cannot move.
      pid = start_repo!(path)
      second = snapshot!(path)

      assert second == first
      assert migration_versions(pid) == @migration_versions
    end

    test "an undecodable oversized row is logged and left untouched, and the migration converges",
         %{root: root} do
      path = Path.join(root, "undecodable.sqlite")
      %{big_archive: big_id} = seed!(path)

      unique = System.unique_integer([:positive])

      # Two flavours of "cannot decode":
      #   * `corrupt-result` — NOT valid JSON at all (`json_valid` = 0);
      #   * `untagged-result` — valid JSON, but not a canonical tagged result,
      #     so `Codec.decode_result/1` raises (this one IS `json_valid` = 1 and
      #     is the case the post-condition's skipped-id exclusion exists for).
      corrupt_id = "corrupt-result-#{unique}"
      untagged_id = "untagged-result-#{unique}"

      blob = String.duplicate("not-json{", 600)

      insert_rows!(path, [
        [id: corrupt_id, result: blob, archive_metadata: blob],
        [
          id: untagged_id,
          result: Jason.encode!(%{"unexpected" => "shape", "pad" => blob}),
          archive_metadata: Jason.encode!([%{"agent_id" => "T9_A1", "pad" => blob}])
        ]
      ])

      before = snapshot!(path)

      log = capture_log(fn -> start_repo!(path) end)
      assert log =~ "skipping task #{corrupt_id}"
      assert log =~ "skipping task #{untagged_id}"

      after_ = snapshot!(path)

      # The undecodable RESULTS are exactly as they were.
      assert after_[{corrupt_id, "result"}] == before[{corrupt_id, "result"}]
      assert after_[{untagged_id, "result"}] == before[{untagged_id, "result"}]

      # The corrupt ARCHIVE (not valid JSON) is left alone — it must never be
      # nilled out or clobbered...
      assert after_[{corrupt_id, "archive_metadata"}] == before[{corrupt_id, "archive_metadata"}]

      # ...while the untagged row's archive is a perfectly valid JSON list, so
      # it is compressed normally (the archive column's rewrite does not depend
      # on the result column's decodability).
      assert compressed?(after_[{untagged_id, "archive_metadata"}])

      assert Codec.decode_archive(after_[{untagged_id, "archive_metadata"}]) == [
               %{"agent_id" => "T9_A1", "pad" => blob}
             ]

      # ...while the healthy rows were still rewritten, and the migration applied.
      assert compressed?(after_[{big_id, "result"}])
    end
  end

  # ── Fixture ───────────────────────────────────────────────────────────────

  # Builds the pre-migration database and seeds the canonical rows.
  # Returns the values the assertions compare against.
  defp seed!(path) do
    create_db!(path)

    archive =
      for i <- 1..4 do
        %{
          "agent_id" => "T5_A#{i}",
          "parent_id" => if(i == 1, do: nil, else: "T5_A1"),
          "depth" => i - 1,
          "objective" => "Genesis step #{i}",
          "result" => String.duplicate("archive-payload-#{i} ", 80),
          "base_commit" => "base#{i}",
          "final_commit" => "final#{i}"
        }
      end

    # The bulk of the final report — keeps the row above the compression
    # threshold EVEN AFTER the archive is stripped, so one row exercises BOTH
    # halves of the rewrite.
    long_report = String.duplicate("long report line ", 400)

    # The result DATA map exactly as the runtime built it: the per-agent archive
    # embedded under `archive_records` (the duplicate) plus the report keys.
    result_data = %{
      "commit_sha" => "abc123def456",
      "result" => long_report,
      "tag" => "v9",
      "branch_name" => "genesis/agent_abc123",
      "agent_count" => 3,
      "archive_records" => archive,
      "repos" => %{
        "primary" => %{"commit_sha" => "abc123def456", "branch_name" => "genesis/agent_abc123"}
      }
    }

    big_result = Jason.encode!(%{"__result_tag__" => "ok", "data" => result_data})
    assert byte_size(big_result) > 4096

    # A result whose ONLY bulk is the duplicated archive: after the strip it is
    # far below the threshold, so the codec stores it as PLAIN JSON (correct
    # final state — the post-condition predicate is length-based).
    archive_only_result =
      Jason.encode!(%{
        "__result_tag__" => "ok",
        "data" => %{
          "commit_sha" => "aaa111",
          "result" => "short report",
          "branch_name" => "genesis/agent_aaa111",
          "archive_records" => archive
        }
      })

    assert byte_size(archive_only_result) > 4096

    big_result_only =
      Jason.encode!(%{
        "__result_tag__" => "ok",
        "data" => %{"commit_sha" => "def789", "result" => long_report, "branch_name" => nil}
      })

    assert byte_size(big_result_only) > 4096

    small_result = Jason.encode!(%{"__result_tag__" => "string", "value" => "ok"})
    small_archive = Jason.encode!([%{"agent_id" => "T1_A1", "role" => "manager"}])

    insert_rows!(path, [
      [id: "big-archive", result: big_result, archive_metadata: Jason.encode!(archive)],
      [id: "archive-only", result: archive_only_result, archive_metadata: Jason.encode!(archive)],
      [id: "big-result", result: big_result_only, archive_metadata: nil],
      [id: "small", result: small_result, archive_metadata: small_archive],
      [id: "nil-result", result: nil, archive_metadata: nil]
    ])

    %{
      archive: archive,
      long_report: long_report,
      # The decoded in-memory result the rewritten row must still carry: atom
      # keys for the known result-data fields, the archive key GONE.
      result:
        {:ok,
         %{
           # `repos` is NOT in the codec's known result-data fields, so it stays
           # a STRING key after the decode (documented in `Store.Codec`).
           "repos" => %{
             "primary" => %{
               "commit_sha" => "abc123def456",
               "branch_name" => "genesis/agent_abc123"
             }
           },
           commit_sha: "abc123def456",
           result: long_report,
           tag: "v9",
           branch_name: "genesis/agent_abc123",
           agent_count: 3
         }},
      archive_only_result:
        {:ok,
         %{
           commit_sha: "aaa111",
           result: "short report",
           branch_name: "genesis/agent_aaa111"
         }},
      big_archive: "big-archive"
    }
  end

  # Creates the canonical tables + a `schema_migrations` stamped through
  # version 3 — the state a pre-release (v0.13.x) database is in, with BOTH new
  # migrations pending. 004 (this rewrite) runs first and 005 (the covering
  # index build) after it, which is exactly the shipped order.
  defp create_db!(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    for ddl <- [@tasks_ddl, @projects_ddl] do
      {:ok, _} = XqliteNIF.query(conn, ddl, [])
    end

    {:ok, _} =
      XqliteNIF.query(
        conn,
        "CREATE TABLE schema_migrations (version BIGINT PRIMARY KEY, inserted_at TEXT)",
        []
      )

    for version <- @migration_versions -- [@compress_rows_version, @covering_index_version] do
      {:ok, _} =
        XqliteNIF.query(
          conn,
          "INSERT INTO schema_migrations (version, inserted_at) VALUES (?1, ?2)",
          [version, "2024-05-05 00:00:00"]
        )
    end

    :ok = XqliteNIF.close(conn)
    :ok
  end

  # Inserts task rows into an EXISTING fixture database.
  defp insert_rows!(path, rows) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    defaults = [
      type: "genesis",
      status: "completed",
      opts: ~S({"mode":"new","path":"/tmp/oversized-row"}),
      started_at: "2024-05-05T09:00:00.000Z",
      finished_at: "2024-05-05T10:00:00.000Z",
      logs: "[]",
      result: nil,
      review_status: "open",
      usage: nil,
      agent_count: 1,
      base_sha: nil,
      commit_sha: nil,
      archive_metadata: nil,
      lease_expires_at: nil,
      model_id: nil,
      project_path: "/tmp/oversized-row",
      branch_name: nil,
      error: nil,
      updated_at: @updated_at
    ]

    columns = [:id | Keyword.keys(defaults)]
    placeholders = columns |> Enum.with_index(1) |> Enum.map_join(", ", fn {_c, i} -> "?#{i}" end)

    insert_sql =
      "INSERT INTO tasks (#{Enum.map_join(columns, ", ", &Atom.to_string/1)}) " <>
        "VALUES (#{placeholders})"

    for row <- rows do
      merged = Keyword.merge(defaults, row)
      values = Enum.map(columns, &Keyword.fetch!(merged, &1))
      {:ok, _} = XqliteNIF.query(conn, insert_sql, values)
    end

    :ok = XqliteNIF.close(conn)
    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Boots a dynamic repo (running any PENDING migration, i.e. this one) and
  # unlinks it: the `on_exit` guard runs after the test process is gone.
  defp start_repo!(path) do
    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)
    pid
  end

  defp migration_versions(pid) do
    RepoScope.with_repo(pid, fn ->
      Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows
      |> Enum.map(&hd/1)
    end)
  end

  # Raw xqlite read of ONE column of ONE row — the ground truth on disk,
  # independent of the repo/codec.
  defp raw!(path, id, column) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: [[value]]}} =
      XqliteNIF.query(conn, "SELECT #{column} FROM tasks WHERE id = ?1", [id])

    :ok = XqliteNIF.close(conn)
    value
  end

  # Every (id, result, archive_metadata) triple on disk, keyed by
  # `{id, column}` — used to prove byte-identity across a boot.
  defp snapshot!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(conn, "SELECT id, result, archive_metadata FROM tasks", [])

    :ok = XqliteNIF.close(conn)

    for [id, result, archive] <- rows,
        {column, value} <- [{"result", result}, {"archive_metadata", archive}],
        into: %{},
        do: {{id, column}, value}
  end

  defp before_updated_at!(path) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, "SELECT id, updated_at FROM tasks", [])
    :ok = XqliteNIF.close(conn)
    Map.new(rows, fn [id, updated_at] -> {id, updated_at} end)
  end

  defp compressed?(value), do: is_binary(value) and String.starts_with?(value, "z1:")
end
