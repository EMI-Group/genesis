defmodule EvoGit.StoreSummaryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Store
  alias EvoGit.Store.Codec
  alias EvoGit.TaskInfo

  # The exact 16 keys returned by the summary API (select_tasks_summary/0,1,2,
  # select_tasks_summary_by_path/2,3,4 and select_tasks_changed_since/1,2).
  # `updated_at` is store-internal bookkeeping — returned as the raw
  # fixed-precision ISO string, NOT a DateTime.
  @summary_keys [
    :id,
    :status,
    :review_status,
    :result,
    :started_at,
    :finished_at,
    :type,
    :project_path,
    :opts,
    :branch_name,
    :model_id,
    :agent_count,
    :base_sha,
    :commit_sha,
    :lease_expires_at,
    :updated_at
  ]

  @insert_task_sql """
  INSERT OR REPLACE INTO tasks
  (id, type, status, opts, started_at, finished_at, logs,
   result, review_status, usage, agent_count, base_sha, commit_sha,
   archive_metadata, lease_expires_at, model_id, project_path, branch_name)
  VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
  """

  # Same isolation pattern as store_test.exs: stop the app's Store/TaskRegistry,
  # start an isolated Store on a temp SQLite file, restore on exit.
  setup do
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_store_summary_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({Store, data_dir: sqlite_path})

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.Store)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    end)

    {:ok, %{sqlite_path: sqlite_path}}
  end

  defp make_task(id, overrides \\ []) do
    %TaskInfo{
      id: id,
      type: :genesis,
      status: :completed,
      opts: [path: "/tmp/proj", mode: "simple"],
      started_at: ~U[2026-06-26 07:19:44Z],
      finished_at: ~U[2026-06-26 08:00:00Z],
      logs: [],
      result: nil
    }
    |> Map.merge(Enum.into(overrides, %{}))
  end

  defp put_task!(task) do
    :ok = Store.put_task(Store, task)
    task
  end

  # Bulk-inserts tasks through a raw Xqlite connection (single transaction) so
  # large batches (e.g. > 500 ids for the chunked-delete test) stay fast.
  defp insert_tasks_raw!(sqlite_path, tasks) do
    {:ok, conn} = Xqlite.open(sqlite_path)
    {:ok, _} = XqliteNIF.execute(conn, "BEGIN", [])

    Enum.each(tasks, fn task ->
      {:ok, _} = XqliteNIF.execute(conn, @insert_task_sql, Codec.encode_task(task))
    end)

    {:ok, _} = XqliteNIF.execute(conn, "COMMIT", [])
    :ok = XqliteNIF.close(conn)
  end

  # Overwrites the store-internal `updated_at` column for a task through a raw
  # Xqlite connection so since-filter tests control the value deterministically
  # (put_task! writes DateTime.utc_now(), which is not reproducible). All values
  # are fixed-precision 24-char ISO strings, so lexicographic == chronological.
  defp set_updated_at!(sqlite_path, id, iso_string) do
    {:ok, conn} = Xqlite.open(sqlite_path)

    {:ok, _} =
      XqliteNIF.execute(conn, "UPDATE tasks SET updated_at = ?1 WHERE id = ?2", [iso_string, id])

    :ok = XqliteNIF.close(conn)
  end

  describe "select_tasks_summary/1" do
    test "returns maps with exactly the 16 contract keys and decoded values" do
      put_task!(
        make_task("sum-1",
          status: :completed,
          review_status: :merged,
          result: {:ok, %{commit_sha: "abc123", branch_name: "feat/x"}},
          agent_count: 5,
          base_sha: "base123",
          commit_sha: "commit456",
          lease_expires_at: 1_234_567_890,
          model_id: "gpt-4o",
          branch_name: "evogit/feature"
        )
      )

      [summary] = Store.select_tasks_summary(Store)

      assert Map.keys(summary) |> Enum.sort() == Enum.sort(@summary_keys)

      assert summary.id == "sum-1"
      assert summary.status == :completed
      assert summary.review_status == :merged
      assert summary.type == :genesis
      assert {:ok, %{commit_sha: "abc123"}} = summary.result
      assert summary.project_path == "/tmp/proj"
      assert summary.opts[:mode] == "simple"
      assert summary.branch_name == "evogit/feature"
      assert summary.model_id == "gpt-4o"
      assert summary.agent_count == 5
      assert summary.base_sha == "base123"
      assert summary.commit_sha == "commit456"
      assert summary.lease_expires_at == 1_234_567_890
      assert DateTime.compare(summary.started_at, ~U[2026-06-26 07:19:44Z]) == :eq
      assert DateTime.compare(summary.finished_at, ~U[2026-06-26 08:00:00Z]) == :eq

      # updated_at is store-internal bookkeeping: the RAW fixed-precision ISO
      # string written by put_task (Codec.encode_datetime(DateTime.utc_now())).
      assert is_binary(summary.updated_at)
      assert summary.updated_at =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
    end

    test "nil scalar columns stay nil" do
      put_task!(make_task("sum-nil", finished_at: nil, lease_expires_at: nil))

      [summary] = Store.select_tasks_summary(Store)
      assert summary.finished_at == nil
      assert summary.lease_expires_at == nil
      assert summary.agent_count == nil
      assert summary.branch_name == nil
      assert summary.model_id == nil
      assert summary.base_sha == nil
      assert summary.commit_sha == nil
    end

    test "returns all tasks with no status filter ([] = all)" do
      put_task!(make_task("sum-a", status: :completed))
      put_task!(make_task("sum-b", status: :running))
      put_task!(make_task("sum-c", status: :pending))

      summaries = Store.select_tasks_summary(Store, [])
      assert length(summaries) == 3
    end

    test "filters by status atoms pushed into SQL" do
      put_task!(make_task("f-completed", status: :completed))
      put_task!(make_task("f-running", status: :running))
      put_task!(make_task("f-pending", status: :pending))
      put_task!(make_task("f-failed", status: :failed))

      only_completed = Store.select_tasks_summary(Store, [:completed])
      assert Enum.map(only_completed, & &1.id) == ["f-completed"]

      mixed = Store.select_tasks_summary(Store, [:completed, :running])
      assert Enum.map(mixed, & &1.id) |> Enum.sort() == ["f-completed", "f-running"]

      # A status with no matching rows returns [].
      assert Store.select_tasks_summary(Store, [:cancelled]) == []
    end

    test "status atoms are decoded, not strings" do
      put_task!(make_task("status-atom", status: :running))

      [summary] = Store.select_tasks_summary(Store)
      assert summary.status == :running
      assert is_atom(summary.status)
    end
  end

  describe "select_tasks_summary_by_path/3" do
    test "combines path and status filters" do
      put_task!(make_task("a-running", status: :running, opts: [path: "/tmp/proj_a"]))
      put_task!(make_task("a-pending", status: :pending, opts: [path: "/tmp/proj_a"]))
      put_task!(make_task("a-completed", status: :completed, opts: [path: "/tmp/proj_a"]))
      put_task!(make_task("b-running", status: :running, opts: [path: "/tmp/proj_b"]))

      both = Store.select_tasks_summary_by_path(Store, "/tmp/proj_a", [:running, :pending])
      assert Enum.map(both, & &1.id) |> Enum.sort() == ["a-pending", "a-running"]

      all_a = Store.select_tasks_summary_by_path(Store, "/tmp/proj_a", [])
      assert length(all_a) == 3

      b_running = Store.select_tasks_summary_by_path(Store, "/tmp/proj_b", [:running])
      assert Enum.map(b_running, & &1.id) == ["b-running"]

      assert Store.select_tasks_summary_by_path(Store, "/nope", []) == []
    end
  end

  describe "since filter + select_tasks_changed_since/2" do
    test "select_tasks_summary/3 with since returns only rows with updated_at > since", %{
      sqlite_path: sqlite_path
    } do
      put_task!(make_task("since-old", status: :completed))
      put_task!(make_task("since-new", status: :completed))
      put_task!(make_task("since-newer", status: :running))

      set_updated_at!(sqlite_path, "since-old", "2026-01-01T00:00:00.000Z")
      set_updated_at!(sqlite_path, "since-new", "2026-01-02T00:00:00.000Z")
      set_updated_at!(sqlite_path, "since-newer", "2026-01-03T00:00:00.000Z")

      newer =
        Store.select_tasks_summary(Store, [], "2026-01-01T00:00:00.000Z")

      assert Enum.map(newer, & &1.id) |> Enum.sort() == ["since-new", "since-newer"]

      all = Store.select_tasks_summary(Store, [], "2000-01-01T00:00:00.000Z")
      assert length(all) == 3
    end

    test "boundary: a row with updated_at == since is excluded (strict >)", %{
      sqlite_path: sqlite_path
    } do
      put_task!(make_task("since-boundary", status: :completed))
      put_task!(make_task("since-after", status: :completed))

      set_updated_at!(sqlite_path, "since-boundary", "2026-01-02T00:00:00.000Z")
      set_updated_at!(sqlite_path, "since-after", "2026-01-03T00:00:00.000Z")

      # The row whose updated_at exactly equals the since value must NOT match.
      rows =
        Store.select_tasks_summary(Store, [], "2026-01-02T00:00:00.000Z")

      assert Enum.map(rows, & &1.id) == ["since-after"]
    end

    test "since combines with statuses", %{sqlite_path: sqlite_path} do
      put_task!(make_task("since-completed-old", status: :completed))
      put_task!(make_task("since-completed-new", status: :completed))
      put_task!(make_task("since-running-new", status: :running))

      set_updated_at!(sqlite_path, "since-completed-old", "2026-01-01T00:00:00.000Z")
      set_updated_at!(sqlite_path, "since-completed-new", "2026-01-02T00:00:00.000Z")
      set_updated_at!(sqlite_path, "since-running-new", "2026-01-02T00:00:00.000Z")

      completed =
        Store.select_tasks_summary(Store, [:completed], "2026-01-01T00:00:00.000Z")

      assert Enum.map(completed, & &1.id) == ["since-completed-new"]
    end

    test "nil since (2-arity) still returns everything", %{sqlite_path: sqlite_path} do
      put_task!(make_task("nil-since-a", status: :completed))
      put_task!(make_task("nil-since-b", status: :running))

      set_updated_at!(sqlite_path, "nil-since-a", "2026-01-01T00:00:00.000Z")
      set_updated_at!(sqlite_path, "nil-since-b", "2026-01-02T00:00:00.000Z")

      summaries = Store.select_tasks_summary(Store, [])
      assert length(summaries) == 2
      assert Enum.map(summaries, & &1.id) |> Enum.sort() == ["nil-since-a", "nil-since-b"]
    end

    test "select_tasks_changed_since/2 returns only newer rows with the 16-key projection", %{
      sqlite_path: sqlite_path
    } do
      put_task!(make_task("cs-old", status: :completed))
      put_task!(make_task("cs-new", status: :running))

      set_updated_at!(sqlite_path, "cs-old", "2026-01-01T00:00:00.000Z")
      set_updated_at!(sqlite_path, "cs-new", "2026-01-02T00:00:00.000Z")

      changed = Store.select_tasks_changed_since(Store, "2026-01-01T00:00:00.000Z")

      assert Enum.map(changed, & &1.id) == ["cs-new"]
      assert Enum.map(changed, & &1.updated_at) == ["2026-01-02T00:00:00.000Z"]
      assert Map.keys(hd(changed)) |> Enum.sort() == Enum.sort(@summary_keys)

      # The boundary row (updated_at == since) is excluded here too.
      assert Store.select_tasks_changed_since(Store, "2026-01-02T00:00:00.000Z") == []
    end

    test "select_tasks_changed_since/2 returns [] for a far-future since", %{
      sqlite_path: sqlite_path
    } do
      put_task!(make_task("cs-future", status: :completed))
      set_updated_at!(sqlite_path, "cs-future", "2026-01-01T00:00:00.000Z")

      assert Store.select_tasks_changed_since(Store, "2100-01-01T00:00:00.000Z") == []
    end

    test "select_tasks_summary_by_path/4 applies the same since filter", %{
      sqlite_path: sqlite_path
    } do
      put_task!(make_task("bp-old", status: :completed, opts: [path: "/tmp/proj"]))
      put_task!(make_task("bp-new", status: :completed, opts: [path: "/tmp/proj"]))
      put_task!(make_task("bp-other", status: :completed, opts: [path: "/tmp/other"]))

      set_updated_at!(sqlite_path, "bp-old", "2026-01-01T00:00:00.000Z")
      set_updated_at!(sqlite_path, "bp-new", "2026-01-02T00:00:00.000Z")
      set_updated_at!(sqlite_path, "bp-other", "2026-01-02T00:00:00.000Z")

      rows =
        Store.select_tasks_summary_by_path(Store, "/tmp/proj", [], "2026-01-01T00:00:00.000Z")

      assert Enum.map(rows, & &1.id) == ["bp-new"]

      # Strict > boundary within the path filter too.
      at_boundary =
        Store.select_tasks_summary_by_path(Store, "/tmp/proj", [], "2026-01-02T00:00:00.000Z")

      assert at_boundary == []
    end
  end

  describe "legacy raw-string result skip-and-log" do
    test "select_tasks_summary/1 skips the undecodable row and logs a warning", %{
      sqlite_path: sqlite_path
    } do
      bad_id = "legacy-raw-#{System.unique_integer([:positive])}"
      good_id = "legacy-raw-good-#{System.unique_integer([:positive])}"

      put_task!(make_task(bad_id, status: :completed))
      put_task!(make_task(good_id, status: :completed))

      # Overwrite the result column with a legacy raw string (pre-canonical
      # codec). decode_result/1 raises ArgumentError on it, so the summary read
      # must skip + log the row instead of crashing.
      {:ok, conn} = Xqlite.open(sqlite_path)

      {:ok, _} =
        XqliteNIF.execute(
          conn,
          "UPDATE tasks SET result = ?1 WHERE id = ?2",
          ["no-json-here", bad_id]
        )

      :ok = XqliteNIF.close(conn)

      # Deterministic updated_at (put_task! stamps DateTime.utc_now(), which is
      # not reproducible).
      set_updated_at!(sqlite_path, bad_id, "2026-06-26T07:19:44.000Z")

      {rows, log} = with_log(fn -> Store.select_tasks_summary(Store) end)

      ids = Enum.map(rows, & &1.id)
      assert good_id in ids
      refute bad_id in ids
      assert log =~ "Store: skipping undecodable row in tasks"

      # The Store survives: a follow-up read still succeeds and still excludes
      # the undecodable row.
      rows_again = Store.select_tasks_summary(Store)
      assert is_list(rows_again)
      refute Enum.map(rows_again, & &1.id) |> Enum.member?(bad_id)
    end

    test "select_tasks_changed_since/2 skips the undecodable row and logs a warning", %{
      sqlite_path: sqlite_path
    } do
      good_id = "cs-good-#{System.unique_integer([:positive])}"
      bad_id = "cs-legacy-raw-#{System.unique_integer([:positive])}"

      put_task!(make_task(good_id, status: :completed))
      put_task!(make_task(bad_id, status: :completed))

      {:ok, conn} = Xqlite.open(sqlite_path)

      {:ok, _} =
        XqliteNIF.execute(
          conn,
          "UPDATE tasks SET result = ?1 WHERE id = ?2",
          ["no-json-here", bad_id]
        )

      :ok = XqliteNIF.close(conn)

      # Both rows are newer than the `since` cutoff, so both are selected by the
      # SQL — the good row decodes, the legacy raw-string row is skipped + logged.
      set_updated_at!(sqlite_path, good_id, "2026-06-26T08:00:00.000Z")
      set_updated_at!(sqlite_path, bad_id, "2026-06-26T08:30:00.000Z")

      {rows, log} =
        with_log(fn -> Store.select_tasks_changed_since(Store, "2026-06-26T07:30:00.000Z") end)

      ids = Enum.map(rows, & &1.id)
      assert good_id in ids
      refute bad_id in ids
      assert log =~ "Store: skipping undecodable row in tasks"

      # The Store survives: a follow-up read still succeeds and still excludes
      # the undecodable row.
      rows_again = Store.select_tasks_changed_since(Store, "2026-06-26T07:30:00.000Z")
      assert is_list(rows_again)
      refute Enum.map(rows_again, & &1.id) |> Enum.member?(bad_id)
    end
  end

  describe "delete_tasks/2 chunked batch" do
    test "deletes more than 500 ids (chunked WHERE id IN)", %{sqlite_path: sqlite_path} do
      ids = for i <- 1..1005, do: "batch-#{i}"

      tasks =
        Enum.map(ids, fn id ->
          %TaskInfo{
            id: id,
            type: :genesis,
            status: :completed,
            opts: [path: "/tmp/proj"],
            started_at: ~U[2026-01-01 00:00:00Z],
            finished_at: nil,
            logs: [],
            result: nil
          }
        end)

      insert_tasks_raw!(sqlite_path, tasks)

      assert Store.count_tasks(Store) == 1005

      :ok = Store.delete_tasks(Store, ids)

      assert Store.count_tasks(Store) == 0
      assert Store.select_tasks_summary(Store) == []
    end

    test "chunked delete leaves non-listed rows untouched" do
      for i <- 1..3, do: put_task!(make_task("keep-#{i}"))

      :ok = Store.delete_tasks(Store, ["keep-1", "keep-2"])
      assert Store.get_task(Store, "keep-3") != nil
      assert Store.count_tasks(Store) == 1
    end
  end

  describe "select_task_logs/2 narrow read" do
    test "returns the decoded logs list for a task with logs" do
      put_task!(make_task("logs-1", logs: ["line 1", "line 2", "line 3"]))
      assert Store.select_task_logs(Store, "logs-1") == ["line 1", "line 2", "line 3"]
    end

    test "returns [] for a task whose logs are empty" do
      put_task!(make_task("logs-2", logs: []))
      assert Store.select_task_logs(Store, "logs-2") == []
    end

    test "returns nil for an unknown id" do
      assert Store.select_task_logs(Store, "no-such-id") == nil
    end
  end

  describe "select_task_update_info/2 narrow read" do
    test "returns the 4-field narrow map" do
      put_task!(
        make_task("ui-1",
          status: :running,
          opts: [path: "/tmp/proj", prompt: "build it"],
          finished_at: nil,
          lease_expires_at: 999_999_999
        )
      )

      assert %{
               status: :running,
               opts: [path: "/tmp/proj", prompt: "build it"],
               finished_at: nil,
               lease_expires_at: 999_999_999
             } = Store.select_task_update_info(Store, "ui-1")
    end

    test "decodes finished_at as a DateTime" do
      put_task!(make_task("ui-2", status: :completed, finished_at: ~U[2026-06-26 08:00:00Z]))

      info = Store.select_task_update_info(Store, "ui-2")
      assert DateTime.compare(info.finished_at, ~U[2026-06-26 08:00:00Z]) == :eq
    end

    test "returns nil for an unknown id" do
      assert Store.select_task_update_info(Store, "no-such-id") == nil
    end
  end

  describe "SQL pushdown" do
    test "select_running_lease_info/0 returns only running/finalizing rows" do
      put_task!(make_task("rl-running", status: :running, lease_expires_at: 111))
      put_task!(make_task("rl-finalizing", status: :finalizing, lease_expires_at: 222))
      put_task!(make_task("rl-completed", status: :completed, lease_expires_at: 333))
      put_task!(make_task("rl-pending", status: :pending, lease_expires_at: 444))

      infos = Store.select_running_lease_info(Store)
      assert length(infos) == 2

      by_id = Map.new(infos, &{&1.id, &1})

      assert by_id["rl-running"] == %{
               id: "rl-running",
               status: :running,
               lease_expires_at: 111
             }

      assert by_id["rl-finalizing"] == %{
               id: "rl-finalizing",
               status: :finalizing,
               lease_expires_at: 222
             }

      refute Map.has_key?(by_id, "rl-completed")
      refute Map.has_key?(by_id, "rl-pending")
    end

    test "select_cleanup_info/0 returns only rows with non-nil finished_at" do
      put_task!(make_task("cl-1", finished_at: ~U[2026-06-26 08:00:00Z]))
      put_task!(make_task("cl-2", finished_at: nil))
      put_task!(make_task("cl-3", finished_at: ~U[2026-06-26 09:00:00Z]))

      infos = Store.select_cleanup_info(Store)
      assert length(infos) == 2

      by_id = Map.new(infos, &{&1.id, &1})
      assert by_id["cl-1"].id == "cl-1"
      assert DateTime.compare(by_id["cl-1"].finished_at, ~U[2026-06-26 08:00:00Z]) == :eq
      refute Map.has_key?(by_id, "cl-2")
      assert by_id["cl-3"].id == "cl-3"
      assert DateTime.compare(by_id["cl-3"].finished_at, ~U[2026-06-26 09:00:00Z]) == :eq
    end

    test "narrow queries return []/nil on an empty store" do
      assert Store.select_tasks_summary(Store) == []
      assert Store.select_tasks_summary(Store, [:completed]) == []
      assert Store.select_tasks_summary_by_path(Store, "/tmp/x", []) == []
      assert Store.select_tasks_changed_since(Store, "2100-01-01T00:00:00.000Z") == []
      assert Store.select_tasks_summary(Store, [], "2100-01-01T00:00:00.000Z") == []
      assert Store.select_running_lease_info(Store) == []
      assert Store.select_cleanup_info(Store) == []
      assert Store.select_task_logs(Store, "missing") == nil
      assert Store.select_task_update_info(Store, "missing") == nil
      assert Store.select_task_ids(Store) == []
      assert Store.select_task_ids(Store, [:completed]) == []
    end
  end

  describe "select_task_ids/2 minimal projection" do
    test "returns ALL rows with [] statuses" do
      put_task!(make_task("ids-a", status: :completed))
      put_task!(make_task("ids-b", status: :running))
      put_task!(make_task("ids-c", status: :pending))
      put_task!(make_task("ids-d", status: :failed))

      rows = Store.select_task_ids(Store, [])
      assert length(rows) == 4
      assert Enum.map(rows, & &1.id) |> Enum.sort() == ["ids-a", "ids-b", "ids-c", "ids-d"]
    end

    test "filters by status atoms pushed into SQL" do
      put_task!(make_task("idf-completed", status: :completed))
      put_task!(make_task("idf-running", status: :running))
      put_task!(make_task("idf-pending", status: :pending))
      put_task!(make_task("idf-failed", status: :failed))

      only_completed = Store.select_task_ids(Store, [:completed])
      assert Enum.map(only_completed, & &1.id) == ["idf-completed"]

      mixed = Store.select_task_ids(Store, [:completed, :failed])
      assert Enum.map(mixed, & &1.id) |> Enum.sort() == ["idf-completed", "idf-failed"]

      # A status with no matching rows returns [].
      assert Store.select_task_ids(Store, [:cancelled]) == []
    end

    test "returns maps with exactly the :id/:status/:updated_at keys" do
      put_task!(make_task("idk-1", status: :completed, result: {:ok, %{commit_sha: "abc"}}))

      [row] = Store.select_task_ids(Store)
      assert Enum.sort(Map.keys(row)) == [:id, :status, :updated_at]
      refute Map.has_key?(row, :result)
      refute Map.has_key?(row, :opts)
    end

    test "updated_at is the raw stored ISO string, not a DateTime", %{sqlite_path: sqlite_path} do
      put_task!(make_task("idu-1", status: :completed))

      # Deterministic updated_at (put_task! stamps DateTime.utc_now(), which is
      # not reproducible).
      set_updated_at!(sqlite_path, "idu-1", "2026-01-02T03:04:05.000Z")

      [row] = Store.select_task_ids(Store)
      assert row.updated_at == "2026-01-02T03:04:05.000Z"
      assert is_binary(row.updated_at)
      refute is_struct(row.updated_at, DateTime)
      assert row.updated_at =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
    end

    test "status is decoded to an atom, not a string" do
      put_task!(make_task("idst-1", status: :running))

      [row] = Store.select_task_ids(Store)
      assert row.status == :running
      assert is_atom(row.status)
    end
  end
end
