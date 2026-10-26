defmodule EvoGit.Store.V0138UpgradePathTest do
  @moduledoc """
  THE released-v0.13.8 → current-HEAD upgrade path, end to end.

  Every other store-migration suite either boots a FRESH database or stamps
  every shipped version EXCEPT the one under test; neither reproduces what a
  user upgrading from the v0.13.8 release actually has on disk — a
  `schema_migrations` stamped with EXACTLY the three migrations that release
  shipped (`…00001_baseline_adoption`, `…00002_data_normalization`,
  `…00003_composite_indexes`, all byte-identical to HEAD's copies), so the REAL
  pending set is `…00005` … `…00009` (the gap at `…00004` is legal: no such file
  ships), over a `tasks` table in the pre-drop TWENTY-column shape (still
  carrying `archive_metadata`) with the six baseline + two composite indexes.

  This suite crafts that file with RAW xqlite — never through the migration
  modules, so the fixture stays independent of HEAD's code — seeds v0.13.8-shaped
  rows, and runs the REAL boot path (`EvoGit.Store.Boot.run_migrations/1`, the
  entry point `Boot.start_dynamic/2` and `mix migrate.store` use), pinning the
  applied list, the HEAD shapes, the per-agent archive fan-out, the
  `archive_records` strip, the untouched archive-less/canonical rows, the
  absence of any `"z1:"` payload (`…00006` is a no-op on v0.13.8 data) and a
  second run that applies nothing and changes nothing.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Codec

  # The three migrations released v0.13.8 shipped — a real v0.13.8
  # `schema_migrations` carries exactly these rows.
  @v0138_versions [20_260_815_000_001, 20_260_815_000_002, 20_260_815_000_003]

  # The five migrations HEAD ships ON TOP of them: the REAL pending set a
  # v0.13.8 database boots through.
  @pending_versions [
    20_260_815_000_005,
    20_260_815_000_006,
    20_260_815_000_007,
    20_260_815_000_008,
    20_260_815_000_009
  ]

  @shipped_versions @v0138_versions ++ @pending_versions

  # The v0.13.8 `tasks` columns in physical order (pre-drop, 20 columns); the
  # HEAD shape is the same list minus `archive_metadata`.
  @v0138_task_columns ~w(id type status opts started_at finished_at logs result review_status
                         usage agent_count base_sha commit_sha archive_metadata
                         lease_expires_at model_id project_path branch_name error updated_at)a

  @head_task_columns @v0138_task_columns -- [:archive_metadata]

  # The eight indexes a v0.13.8 database carries: the six single-column ones
  # `…00001` created + the two composites `…00003` created. They must SURVIVE
  # the upgrade (no later migration re-creates them).
  @v0138_indexes [
    {"idx_tasks_status", "status"},
    {"idx_tasks_finished_at", "finished_at"},
    {"idx_tasks_lease_expires_at", "lease_expires_at"},
    {"idx_tasks_project_path", "project_path"},
    {"idx_tasks_updated_at", "updated_at"},
    {"idx_tasks_started_at", "started_at"},
    {"idx_tasks_status_started_at", "status, started_at"},
    {"idx_tasks_project_path_started_at", "project_path, started_at"}
  ]

  @v0138_index_names Enum.sort(
                       Enum.map(@v0138_indexes, &elem(&1, 0)) ++ ["sqlite_autoindex_tasks_1"]
                     )

  # Every index on `tasks` after the upgrade: the v0.13.8 eight + the two
  # covering indexes `…00005` adds, plus the PK autoindex.
  @head_task_index_names Enum.sort(
                           Enum.map(@v0138_indexes, &elem(&1, 0)) ++
                             ~w(idx_tasks_status_updated_at_id idx_tasks_finished_at_id
                                sqlite_autoindex_tasks_1)
                         )

  # The canonical `task_agent_archives` columns, in table order.
  @archive_columns ~w(task_id agent_id parent_id depth agent_type context_node_path objective
                     result base_commit final_commit branch_name archive_ref_start
                     archive_ref_final repo_id repo_root repo_path usage llm_settings
                     agent_settings foreign_repos compression_count started_at completed_at)

  # The four archive columns stored as plain JSON TEXT.
  @archive_json_columns ~w(usage llm_settings agent_settings foreign_repos)

  @archive_index "task_agent_archives_task_depth_idx"
  @archive_projection Enum.join(@archive_columns, ", ")
  @sqlite_master_sql "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
  @migration_rows_sql "SELECT version, inserted_at FROM schema_migrations ORDER BY version"

  @archived_id "v0138-completed-archive"
  @legacy_id "v0138-old-null-archive"
  @canonical_id "v0138-canonical"

  @archived_base "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
  @archived_root_final "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c"
  @archived_head_final "9a8b7c6d5e4f302132435465768798a9b0c1d2e3"

  # The two archive-less tasks' commit SHAs.
  @legacy_sha "1111111111111111111111111111111111111111"
  @canonical_sha "2222222222222222222222222222222222222222"
  @canonical_base "3333333333333333333333333333333333333333"

  # The v0.13.8 `tasks` DDL — 20 columns, still carrying `archive_metadata`.
  @tasks_ddl """
  CREATE TABLE tasks (id TEXT PRIMARY KEY, type TEXT, status TEXT NOT NULL, opts TEXT,
    started_at TEXT, finished_at TEXT, logs TEXT, result TEXT, review_status TEXT,
    usage TEXT, agent_count INTEGER, base_sha TEXT, commit_sha TEXT, archive_metadata TEXT,
    lease_expires_at INTEGER, model_id TEXT, project_path TEXT, branch_name TEXT,
    error TEXT, updated_at TEXT)
  """

  @projects_ddl """
  CREATE TABLE projects (path TEXT PRIMARY KEY, name TEXT, last_opened_at TEXT)
  """

  setup do
    # Wall-clock ms + OS pid on top of the per-BEAM unique integer: a counter
    # alone collides with a PREVIOUS run's leftover directory.
    stamp =
      "#{System.system_time(:millisecond)}_#{:os.getpid()}_#{System.unique_integer([:positive])}"

    root = Path.join(System.tmp_dir!(), "evogit_v0138_upgrade_#{stamp}_#{inspect(self())}")

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, %{path: Path.join(root, "tasks.sqlite")}}
  end

  # ── The chain ─────────────────────────────────────────────────────────────

  describe "released v0.13.8 database → HEAD" do
    test "applies exactly the five pending migrations and stamps the eight shipped versions",
         %{path: path} do
      build_v0138_db!(path)

      # The fixture really is a v0.13.8 database: only its three versions.
      assert migration_versions!(path) == @v0138_versions

      pid = start_repo!(path)

      # The REAL pending set, in ascending order.
      assert Boot.run_migrations(pid) == @pending_versions

      assert migration_versions!(path) == @shipped_versions
      refute 20_260_815_000_004 in migration_versions!(path)
    end

    test "ends at HEAD's 19-column tasks shape with the ten indexes intact", %{path: path} do
      build_v0138_db!(path)

      # Pre-boot: the genuine v0.13.8 twenty-column shape with its eight
      # indexes (no `archive_metadata` drop, no covering indexes).
      pre_boot = task_table_info!(path)
      assert length(pre_boot) == 20
      assert "archive_metadata" in column_names(pre_boot)
      assert table_index_names!(path, "tasks") == @v0138_index_names

      pid = start_repo!(path)
      Boot.run_migrations(pid)

      info = task_table_info!(path)
      assert column_names(info) == column_strings(@head_task_columns)
      refute "archive_metadata" in column_names(info)

      # Contiguous `cid`s (the dropped column left no hole) and the full
      # per-column type/nullability/default/PK contract.
      assert Enum.map(info, fn [cid | _rest] -> cid end) == Enum.to_list(0..18)

      assert column_specs(info) ==
               Map.new(@head_task_columns, &{to_string(&1), head_column_spec(&1)})

      # The pre-existing indexes survive and the two covering ones were added.
      assert table_index_names!(path, "tasks") == @head_task_index_names

      covering = index_columns!(path, "idx_tasks_status_updated_at_id")
      assert covering == ["status", "updated_at", "id"]
      assert index_columns!(path, "idx_tasks_finished_at_id") == ["finished_at", "id"]
    end

    test "creates task_agent_archives with TEXT repo_id and one row per archived agent",
         %{path: path} do
      build_v0138_db!(path)
      pid = start_repo!(path)
      Boot.run_migrations(pid)

      info = archive_table_info!(path)
      assert column_names(info) == @archive_columns
      assert length(info) == 23

      # `repo_id` holds a repo ID STRING ("primary"/a foreign repo id), so the
      # canonical affinity is TEXT — never the pre-release INTEGER.
      assert column_info(info, "repo_id") == {"TEXT", 0, nil}
      assert column_info(info, "task_id") == {"TEXT", 1, nil}
      assert column_info(info, "agent_id") == {"INTEGER", 1, nil}
      assert column_info(info, "depth") == {"INTEGER", 1, "0"}
      assert column_info(info, "compression_count") == {"INTEGER", 1, "0"}

      assert index_columns!(path, @archive_index) == ["task_id", "depth", "agent_id"]

      # ONE row per agent of the v0.13.8 `archive_metadata` array, ordered by
      # agent id, EVERY column mapped from the record. The extra spot checks
      # keep the roster's shape readable.
      assert archive_entries!(path, @archived_id) ==
               Enum.map(archive_records(), &Map.put(&1, "task_id", @archived_id))

      [root, child] = archive_entries!(path, @archived_id)
      assert {root["agent_id"], root["depth"], root["repo_id"]} == {1, 0, "primary"}
      assert {child["agent_id"], child["depth"], child["repo_id"]} == {2, 1, "primary"}
      assert child["parent_id"] == 1
      assert root["started_at"] == "2025-11-02T09:00:00.000Z"
      assert root["completed_at"] == "2025-11-02T09:40:58.240Z"

      # The archive-less rows never produce an archive row.
      assert archive_entries!(path, @legacy_id) == []
      assert archive_entries!(path, @canonical_id) == []
    end

    test "strips the duplicated archive_records from result and keeps the rest decodable",
         %{path: path} do
      build_v0138_db!(path)
      pid = start_repo!(path)
      Boot.run_migrations(pid)

      raw = raw_value!(path, @archived_id, "result")
      decoded = Jason.decode!(raw)

      assert decoded["__result_tag__"] == "ok"
      refute Map.has_key?(decoded["data"], "archive_records")

      # Everything else in the result survives the migration's decode/
      # re-encode for the strip.
      assert decoded["data"] == Map.delete(archived_result_data(), "archive_records")

      # ...and the row is still readable through the strict codec (an
      # untagged/non-canonical result would raise here).
      assert Codec.decode_result(raw) ==
               {:ok,
                %{
                  commit_sha: @archived_root_final,
                  result: "Created README.md and linked it from the project page.",
                  tag: "v0.13.8",
                  branch_name: "genesis/agent_0138abc",
                  usage: expected_usage(),
                  agent_count: 2
                }}
    end

    test "leaves the archive-less and already-canonical rows byte-identical", %{path: path} do
      build_v0138_db!(path)

      before = task_rows_snapshot!(path, @v0138_task_columns)

      pid = start_repo!(path)
      Boot.run_migrations(pid)

      after_ = task_rows_snapshot!(path, @head_task_columns)

      # (b) the older, never-archived task and (c) the already-canonical row:
      # not one byte moved (no normalization, no backfill, no z1 unpacking).
      for id <- [@legacy_id, @canonical_id] do
        assert after_[id] == Map.drop(before[id], ["archive_metadata"])
      end

      # (a) the archived task differs ONLY by the dropped archive column and
      # the stripped `result`.
      assert Map.drop(after_[@archived_id], ["result"]) ==
               Map.drop(before[@archived_id], ["archive_metadata", "result"])

      # No `"z1:"`-prefixed value survives anywhere — v0.13.8 never wrote that
      # format, so `…00006` had nothing to unpack and never rewrote a byte.
      for {_id, row} <- after_, {column, value} <- row, is_binary(value) do
        refute String.starts_with?(value, "z1:"), "#{column} still holds a z1: payload"
      end
    end

    test "re-running the migration entry point applies nothing and changes nothing",
         %{path: path} do
      build_v0138_db!(path)
      pid = start_repo!(path)

      assert Boot.run_migrations(pid) == @pending_versions

      snapshot = db_snapshot!(path)

      # `Ecto.Migrator` reports the empty pending set, and no migration body
      # re-runs (the `IF NOT EXISTS` / column-probe guards converge anyway).
      assert Boot.run_migrations(pid) == []

      assert db_snapshot!(path) == snapshot
      assert migration_versions!(path) == @shipped_versions
    end
  end

  # ── Seeding a v0.13.8 database (raw SQL, never the migrations) ────────────

  defp build_v0138_db!(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)

    for ddl <- [@tasks_ddl, @projects_ddl] ++ v0138_index_ddl(), do: exec!(conn, ddl)

    # Ecto's `schema_migrations` shape, stamped with exactly the three versions
    # v0.13.8 shipped.
    exec!(conn, "CREATE TABLE schema_migrations (version BIGINT PRIMARY KEY, inserted_at TEXT)")

    for version <- @v0138_versions do
      exec!(conn, "INSERT INTO schema_migrations (version, inserted_at) VALUES (?1, ?2)", [
        version,
        "2025-11-02 09:00:00"
      ])
    end

    exec!(conn, "INSERT INTO projects (path, name, last_opened_at) VALUES (?1, ?2, ?3)", [
      "/home/user/projects/demo",
      "demo",
      "2025-11-02T09:42:12.001Z"
    ])

    for row <- [archived_row(), legacy_row(), canonical_row()], do: insert_task!(conn, row)

    :ok = XqliteNIF.close(conn)
    :ok
  end

  defp exec!(conn, sql, params \\ []), do: {:ok, _} = XqliteNIF.query(conn, sql, params)

  defp v0138_index_ddl do
    for {name, columns} <- @v0138_indexes do
      "CREATE INDEX IF NOT EXISTS #{name} ON tasks(#{columns})"
    end
  end

  defp insert_task!(conn, row) do
    columns = Enum.map_join(@v0138_task_columns, ", ", &Atom.to_string/1)
    placeholders = Enum.map_join(1..length(@v0138_task_columns), ", ", &"?#{&1}")
    # A missing key is SQL NULL, exactly like an untouched v0.13.8 row.
    values = Enum.map(@v0138_task_columns, &Keyword.get(row, &1))
    exec!(conn, "INSERT INTO tasks (#{columns}) VALUES (#{placeholders})", values)
  end

  # A v0.13.8 `tasks` row: the common non-NULL shape, plus `overrides`.
  defp task_row(id, overrides) do
    Keyword.merge(
      [
        id: id,
        type: "genesis",
        status: "completed",
        opts: ~S({"mode":"new","path":"/home/user/projects/demo","prompt":"Build it"}),
        started_at: "2025-09-01T12:00:00.000Z",
        finished_at: "2025-09-01T12:30:00.000Z",
        logs: ~S(["task started","agent completed"]),
        usage: Jason.encode!(usage_map()),
        agent_count: 1,
        model_id: "default",
        project_path: "/home/user/projects/demo",
        updated_at: "2025-09-01T12:30:01.000Z"
      ],
      overrides
    )
  end

  # (a) A COMPLETED task whose per-agent archive lives in `archive_metadata`
  # (a two-record JSON array) AND is duplicated under `result.data.archive_records`
  # — the exact duplicate `…00008` fans out and strips.
  defp archived_row do
    task_row(@archived_id,
      type: "evolve",
      opts: ~S({"mode":"simple","path":"/home/user/projects/demo","objective":"Add a README"}),
      started_at: "2025-11-02T09:00:00.000Z",
      finished_at: "2025-11-02T09:42:11.123Z",
      logs: ~S(["task started","agent 1 completed","agent 2 completed"]),
      result: result_json(archived_result_data()),
      review_status: "open",
      agent_count: 2,
      base_sha: @archived_base,
      commit_sha: @archived_root_final,
      archive_metadata: Jason.encode!(archive_records()),
      model_id: "deepseek-chat",
      branch_name: "genesis/agent_0138abc",
      updated_at: "2025-11-02T09:42:12.001Z"
    )
  end

  # (b) An OLDER task with no archive at all: `archive_metadata` is SQL NULL
  # and its result carries no `archive_records` key.
  defp legacy_row do
    task_row(@legacy_id,
      status: "cancelled",
      opts: ~S({"mode":"new","path":"/home/user/projects/legacy","prompt":"Build a CLI"}),
      started_at: "2025-06-14T07:30:00.000Z",
      finished_at: "2025-06-14T07:55:41.900Z",
      logs: ~S(["task started","task cancelled"]),
      result: ok_result(@legacy_sha, "Built the initial CLI.", "genesis/agent_legacy01", 1),
      review_status: "ignored",
      commit_sha: @legacy_sha,
      project_path: "/home/user/projects/legacy",
      branch_name: "genesis/agent_legacy01",
      updated_at: "2025-06-14T07:55:42.500Z"
    )
  end

  # (c) A row ALREADY in the canonical JSON shapes (JSON-object opts, tagged
  # ok-result, fixed-millisecond timestamps): the upgrade must not rewrite a
  # single byte of it.
  defp canonical_row do
    task_row(@canonical_id,
      opts:
        ~S({"mode":"new","path":"/home/user/projects/canonical","prompt":"Scaffold a library"}),
      result: ok_result(@canonical_sha, "Scaffolded the library.", "genesis/agent_canon01", 3),
      review_status: "merged",
      agent_count: 3,
      base_sha: @canonical_base,
      commit_sha: @canonical_sha,
      project_path: "/home/user/projects/canonical",
      branch_name: "genesis/agent_canon01"
    )
  end

  # ── Seeded archive/result payloads ────────────────────────────────────────

  # ONE v0.13.8 archive record, STRING-keyed exactly as Jason serialized it
  # (atom keys stringified, `%DateTime{}` values as ISO strings). Every key is
  # an archive-table column.
  defp archive_record(overrides) do
    Map.merge(
      %{
        "parent_id" => nil,
        "objective" => "Add a README",
        "result" => "Created README.md and linked it from the project page.",
        "base_commit" => @archived_base,
        "branch_name" => "genesis/agent_0138abc",
        "compression_count" => 0,
        "repo_path" => "/home/user/projects/demo",
        "repo_id" => "primary",
        "repo_root" => "/home/user/projects/demo",
        "started_at" => "2025-11-02T09:00:00.000Z",
        "completed_at" => "2025-11-02T09:40:58.240Z",
        "llm_settings" => %{
          "model" => "deepseek-chat",
          "context_compression_threshold" => 200_000,
          "model_id" => "default",
          "temperature" => 0.3
        },
        "agent_settings" => %{"max_turns" => 40, "max_retries" => 3, "max_agent_depth" => 3},
        "foreign_repos" => [],
        "agent_type" => "manager",
        "context_node_path" => "."
      },
      overrides
    )
  end

  defp archive_records do
    [
      archive_record(%{
        "agent_id" => 1,
        "depth" => 0,
        "final_commit" => @archived_root_final,
        "archive_ref_start" => "refs/genesis/archive/Tv0138-A1-start",
        "archive_ref_final" => "refs/genesis/archive/Tv0138-A1-final",
        "usage" => archive_usage(usage_map())
      }),
      archive_record(%{
        "agent_id" => 2,
        "parent_id" => 1,
        "depth" => 1,
        "objective" => "Write the install section",
        "final_commit" => @archived_head_final,
        "archive_ref_start" => "refs/genesis/archive/Tv0138-A2-start",
        "archive_ref_final" => "refs/genesis/archive/Tv0138-A2-final",
        "usage" => archive_usage(usage_map()),
        "compression_count" => 1,
        "started_at" => "2025-11-02T09:20:00.000Z",
        "agent_type" => "executor",
        "context_node_path" => "docs"
      })
    ]
  end

  # The archive-record usage map: the `%Usage{}` field set + the derived
  # `cache_hit_rate` this shape carries.
  defp archive_usage(usage_map), do: Map.put(usage_map, "cache_hit_rate", 0.0)

  # Row (a)'s canonical `{:ok, data}` result — the data map DUPLICATES the
  # archive under `archive_records` (exactly what v0.13.8 persisted).
  defp archived_result_data do
    %{
      "commit_sha" => @archived_root_final,
      "result" => "Created README.md and linked it from the project page.",
      "tag" => "v0.13.8",
      "branch_name" => "genesis/agent_0138abc",
      "usage" => usage_map(),
      "agent_count" => 2,
      "archive_records" => archive_records()
    }
  end

  defp result_json(data), do: Jason.encode!(%{"__result_tag__" => "ok", "data" => data})

  # The canonical `{:ok, data}` result of a task with no archive.
  defp ok_result(commit_sha, text, branch_name, agent_count) do
    result_json(%{
      "commit_sha" => commit_sha,
      "result" => text,
      "tag" => nil,
      "branch_name" => branch_name,
      "usage" => usage_map(),
      "agent_count" => agent_count
    })
  end

  defp expected_usage do
    struct!(EvoGit.Agent.Usage,
      input_tokens: 1234,
      output_tokens: 567,
      total_tokens: 1801,
      input_cost: 0.0004,
      output_cost: 0.0011,
      total_cost: 0.0015,
      cached_tokens: 0,
      cache_creation_tokens: 0
    )
  end

  # The task-level `usage` column shape (the `%Usage{}` field set, string-keyed).
  defp usage_map(usage \\ expected_usage()) do
    usage
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  # ── Repo lifecycle / raw reads ────────────────────────────────────────────

  # The shape `mix migrate.store` uses: an UNNAMED dynamic repo, so the
  # applied-version list `Boot.run_migrations/1` returns stays observable
  # (`Boot.start_dynamic/1` runs the same migrations but discards it).
  defp start_repo!(path) do
    {:ok, pid} = Repo.start_link(database: Path.expand(path), name: nil, pool_size: 1)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)
    pid
  end

  defp query_rows!(path, statement, params \\ []) do
    {:ok, conn} = Xqlite.open(path, journal_mode: :wal, synchronous: :normal)
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, statement, params)
    :ok = XqliteNIF.close(conn)
    rows
  end

  defp raw_value!(path, id, column) do
    [[value]] = query_rows!(path, "SELECT #{column} FROM tasks WHERE id = ?1", [id])
    value
  end

  defp task_table_info!(path), do: query_rows!(path, "PRAGMA table_info(tasks)")
  defp archive_table_info!(path), do: query_rows!(path, "PRAGMA table_info(task_agent_archives)")

  defp column_names(table_info), do: Enum.map(table_info, fn [_cid, name | _rest] -> name end)
  defp column_strings(columns), do: Enum.map(columns, &Atom.to_string/1)

  # `PRAGMA table_info` row → `{type, notnull, dflt}` for one column.
  defp column_info(table_info, column) do
    Enum.find_value(table_info, fn
      [_cid, ^column, type, notnull, dflt | _rest] -> {type, notnull, dflt}
      _other -> nil
    end)
  end

  # Column name => `{type, notnull, dflt, pk}` for a whole `PRAGMA table_info`.
  defp column_specs(table_info) do
    Map.new(table_info, fn [_cid, name, type, notnull, dflt, pk] ->
      {name, {type, notnull, dflt, pk}}
    end)
  end

  # {type, notnull, dflt, pk} per HEAD `tasks` column: only `status` is NOT
  # NULL, `id` is the PK, and `agent_count`/`lease_expires_at` are INTEGER.
  defp head_column_spec(:id), do: {"TEXT", 0, nil, 1}
  defp head_column_spec(:status), do: {"TEXT", 1, nil, 0}

  defp head_column_spec(column) when column in [:agent_count, :lease_expires_at],
    do: {"INTEGER", 0, nil, 0}

  defp head_column_spec(_column), do: {"TEXT", 0, nil, 0}

  defp index_columns!(path, index_name) do
    query_rows!(path, "PRAGMA index_info(#{index_name})")
    |> Enum.map(fn [_seqno, _cid, column] -> column end)
  end

  defp table_index_names!(path, table) do
    query_rows!(
      path,
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?1 ORDER BY name",
      [table]
    )
    |> List.flatten()
  end

  defp migration_versions!(path) do
    query_rows!(path, "SELECT version FROM schema_migrations ORDER BY version")
    |> List.flatten()
  end

  # ONE row per task as a COLUMN => value map for the given column list (20
  # columns pre-drop, 19 post-drop). `id` is selected first, so `hd/1` keys the
  # map. Raw xqlite — independent of the repo/codec.
  defp task_rows_snapshot!(path, columns) do
    names = column_strings(columns)
    sql = "SELECT #{Enum.join(names, ", ")} FROM tasks ORDER BY id"

    query_rows!(path, sql)
    |> Map.new(fn row -> {hd(row), Map.new(Enum.zip(names, row))} end)
  end

  # The whole observable database state: schema, migration bookkeeping, every
  # task row, every archive row, and both PRAGMA shapes. A second migration
  # run must leave it untouched.
  defp db_snapshot!(path) do
    {
      query_rows!(path, @sqlite_master_sql),
      query_rows!(path, @migration_rows_sql),
      task_table_info!(path),
      archive_table_info!(path),
      task_rows_snapshot!(path, @head_task_columns),
      query_rows!(
        path,
        "SELECT #{@archive_projection} FROM task_agent_archives ORDER BY task_id, agent_id"
      )
    }
  end

  # The archive roster of ONE task, one STRING-keyed map per row with the four
  # JSON columns DECODED (map key order can never make an assertion flaky).
  defp archive_entries!(path, task_id) do
    path
    |> query_rows!(
      "SELECT #{@archive_projection} FROM task_agent_archives WHERE task_id = ?1 " <>
        "ORDER BY agent_id",
      [task_id]
    )
    |> Enum.map(fn row ->
      @archive_columns
      |> Enum.zip(row)
      |> Map.new()
      |> Map.new(fn {column, value} ->
        if column in @archive_json_columns and is_binary(value) do
          {column, Jason.decode!(value)}
        else
          {column, value}
        end
      end)
    end)
  end
end
