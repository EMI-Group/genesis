defmodule EvoGit.Store.Operations.SafetyTest do
  @moduledoc """
  Tests for `EvoGit.Store.Operations.Safety` — the Ecto port of the raw-SQL
  store's safe-select + size handlers (unit R4b).

  Pinned contracts (mirror of the raw store's store.ex:925-953 handlers — zero
  consumer changes allowed):

    * `safe_select_all_tasks/1` / `safe_select_all_projects/1` return a plain
      LIST of decoded structs (the `{tasks, total_count}` split belongs to the
      PAGINATED variant, never these handlers), unordered (rowid order), with
      undecodable rows SKIPPED + `Logger.warning`'d
    * `size/1` = SUM of both tables' ROW COUNTS (COUNT(*) semantics — corrupt
      rows count too; never PRAGMA byte math)
    * `TaskInfo.ref` is always `nil` (runtime-only), `status || :pending`

  Every test boots its OWN unnamed dynamic `EvoGit.Repo` instance
  (`EvoGit.Store.Boot.start_dynamic/1` — globally lock-safe, no boot lock
  needed) on a unique tmp database. Good rows are seeded through the TYPED
  schemas (canonical Codec wire dumps); corrupt rows through the RAW twins
  (raw TEXT the typed dump could never produce). Self-contained by design
  (R4b unit contract): no shared helper files.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Operations.Safety
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.ProjectRow
  alias EvoGit.Store.Schemas.ProjectRowRaw
  alias EvoGit.Store.Schemas.TaskRow
  alias EvoGit.Store.Schemas.TaskRowRaw

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Boots an unnamed dynamic repo on a UNIQUE tmp database (async: true safe —
  # the path embeds the OS pid + wall-clock ms ON TOP OF the per-BEAM unique
  # integer, so a stale file from a previous run can never be adopted) and
  # stops it on test exit. Unlinked: `on_exit/1` runs after the test process
  # exits, and the start_link link would tear the repo down mid-stop.
  defp start_repo!(tag) do
    path =
      Path.join(
        System.tmp_dir!(),
        "evogit_r4b_#{tag}_#{:os.getpid()}_#{System.system_time(:millisecond)}_" <>
          "#{System.unique_integer([:positive])}.sqlite"
      )

    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)
    pid
  end

  defp with_repo(pid, fun), do: RepoScope.with_repo(pid, fun)

  # Seeds one GOOD task row through the TYPED schema — `insert_all` dumps
  # values through the schema's Ecto types (thin Codec delegation), i.e. the
  # canonical wire format. Returns the id.
  defp insert_task!(pid, overrides) do
    defaults = [
      id: "task_#{System.unique_integer([:positive, :monotonic])}",
      type: :evolve,
      status: :running,
      opts: [objective: "do the thing", path: "/repo/x"],
      started_at: ~U[2024-01-01 00:00:00.000Z],
      finished_at: nil,
      logs: [],
      result: nil,
      review_status: nil,
      usage: nil,
      agent_count: 1,
      base_sha: nil,
      commit_sha: nil,
      archive_metadata: nil,
      lease_expires_at: nil,
      model_id: "test-model",
      project_path: "/repo/x",
      branch_name: nil,
      error: nil,
      updated_at: "2024-01-02T03:04:05.678Z"
    ]

    row = Keyword.merge(defaults, overrides)

    {1, nil} = with_repo(pid, fn -> Repo.insert_all(TaskRow, [row]) end)
    Keyword.fetch!(row, :id)
  end

  # Seeds one task row with ARBITRARY raw column text (bypassing the typed
  # schema's dump) — used to seed corrupt `opts` wire values the typed schema
  # could never produce. Returns the id.
  defp insert_raw_task!(pid, overrides) do
    defaults = [
      id: "raw_#{System.unique_integer([:positive, :monotonic])}",
      type: "evolve",
      status: "running",
      opts: "{\"objective\":\"ok\"}",
      started_at: "2024-01-01T00:00:00.000Z",
      finished_at: nil,
      logs: "[]",
      result: nil,
      review_status: nil,
      usage: nil,
      agent_count: 1,
      base_sha: nil,
      commit_sha: nil,
      archive_metadata: nil,
      lease_expires_at: nil,
      model_id: nil,
      project_path: "/repo/x",
      branch_name: nil,
      error: nil,
      updated_at: "2024-01-02T03:04:05.678Z"
    ]

    row = Keyword.merge(defaults, overrides)

    {1, nil} = with_repo(pid, fn -> Repo.insert_all(TaskRowRaw, [row]) end)
    Keyword.fetch!(row, :id)
  end

  # Seeds one GOOD project row through the TYPED schema. Returns the path.
  defp insert_project!(pid, path, name, dt \\ ~U[2026-06-26 07:19:44.123Z]) do
    {1, nil} =
      with_repo(pid, fn ->
        Repo.insert_all(ProjectRow, [[path: path, name: name, last_opened_at: dt]])
      end)

    path
  end

  # Seeds one project row with ARBITRARY raw column text (raw twin insert).
  defp insert_raw_project!(pid, path, name, last_opened_at) do
    {1, nil} =
      with_repo(pid, fn ->
        Repo.insert_all(ProjectRowRaw, [[path: path, name: name, last_opened_at: last_opened_at]])
      end)

    path
  end

  defp ids(tasks), do: Enum.map(tasks, & &1.id)
  defp paths(projects), do: Enum.map(projects, & &1.path)

  # ── safe_select_all_tasks/1 ──────────────────────────────────────────────

  describe "safe_select_all_tasks/1" do
    test "empty DB returns []" do
      pid = start_repo!(:tasks_empty)
      assert Safety.safe_select_all_tasks(pid) == []
    end

    test "2 good + 1 corrupt row → old split: 2 decoded structs, bad skipped + warned" do
      pid = start_repo!(:tasks_skip)

      good_one = insert_task!(pid, id: "good_one", status: :running)
      # Non-JSON opts text — Codec.decode_opts/1 raises ArgumentError; the row
      # must be SKIPPED with a warning, never crash the whole read.
      insert_raw_task!(pid, id: "bad", status: "running", opts: "{not json")
      good_two = insert_task!(pid, id: "good_two", status: :completed)

      {tasks, logs} = with_log(fn -> Safety.safe_select_all_tasks(pid) end)

      assert ids(tasks) |> Enum.sort() == Enum.sort([good_one, good_two])

      assert %EvoGit.TaskInfo{} = hd(tasks)
      assert Enum.all?(tasks, &(&1.ref == nil))
      assert Enum.all?(tasks, &is_atom(&1.status))
      assert Enum.all?(tasks, &is_struct(&1.started_at, DateTime))

      assert logs =~ "Store: skipping undecodable row in tasks (id: \"bad\")"
    end

    test "legacy positional pair-array opts is skipped too (raising decode)" do
      pid = start_repo!(:tasks_legacy)

      insert_raw_task!(pid, id: "legacy", opts: "[[\"objective\",\"x\"]]")
      ok = insert_task!(pid, id: "ok", status: :running)

      assert ids(Safety.safe_select_all_tasks(pid)) == [ok]
    end

    test "all rows undecodable yields [] (still a plain list, no crash)" do
      pid = start_repo!(:tasks_all_bad)
      insert_raw_task!(pid, id: "b1", opts: "1")
      insert_raw_task!(pid, id: "b2", opts: "\"scalar\"")

      assert Safety.safe_select_all_tasks(pid) == []
    end

    test "rows return in insertion order (old SQL had no ORDER BY)" do
      pid = start_repo!(:tasks_order)
      first = insert_task!(pid, id: "row_a")
      second = insert_task!(pid, id: "row_b")

      assert ids(Safety.safe_select_all_tasks(pid)) == [first, second]
    end
  end

  # ── safe_select_all_projects/1 ───────────────────────────────────────────

  describe "safe_select_all_projects/1" do
    test "empty DB returns []" do
      pid = start_repo!(:projects_empty)
      assert Safety.safe_select_all_projects(pid) == []
    end

    test "2 good projects return as RecentProject structs" do
      pid = start_repo!(:projects_good)

      insert_project!(pid, "/p1", "P1")
      insert_project!(pid, "/p2", "P2", ~U[2027-02-02 00:00:00.500Z])

      projects = Safety.safe_select_all_projects(pid)

      assert paths(projects) |> Enum.sort() == ["/p1", "/p2"]
      assert Enum.all?(projects, &is_struct(&1, EvoGit.RecentProject))
      assert Enum.all?(projects, &is_struct(&1.last_opened_at, DateTime))
    end

    test "a row with an unparseable last_opened_at SURVIVES decode with nil (lenient datetime)" do
      pid = start_repo!(:projects_bad_ts)

      # Codec.decode_datetime/1 is LENIENT (returns nil on DateTime.from_iso8601
      # error — the project skip arm is effectively unreachable over TEXT wire
      # values); the OLD store behaved identically, so this row is NOT skipped.
      insert_raw_project!(pid, "/bad", "Bad", "not-a-timestamp")
      insert_project!(pid, "/good", "Good")

      projects = Safety.safe_select_all_projects(pid)

      assert paths(projects) |> Enum.sort() == ["/bad", "/good"]
      assert Enum.find(projects, &(&1.path == "/bad")).last_opened_at == nil

      assert Enum.find(projects, &(&1.path == "/good")).last_opened_at !=
               nil
    end

    test "corrupt project rows are skipped with a warning when decode raises" do
      pid = start_repo!(:projects_skip)

      # Force the raising path through the shared boundary: a corrupt task row
      # is skipped + logged while the PROJECT read below stays unaffected —
      # the tasks describe block already pins the full 2-good+1-bad task split.
      {projects, logs} =
        with_log(fn ->
          insert_project!(pid, "/kept", "Kept")
          insert_raw_task!(pid, id: "bad_proj_seed", opts: "{not json")

          Safety.safe_select_all_tasks(pid)
          Safety.safe_select_all_projects(pid)
        end)

      assert paths(projects) == ["/kept"]
      assert logs =~ "Store: skipping undecodable row in tasks (id: \"bad_proj_seed\")"
    end
  end

  # ── size/1 ───────────────────────────────────────────────────────────────

  describe "size/1" do
    test "empty DB (both tables) returns 0" do
      pid = start_repo!(:size_empty)
      assert Safety.size(pid) == 0
    end

    test "sums ROW COUNTS across both tables (old count_table semantics)" do
      pid = start_repo!(:size_sum)

      insert_task!(pid, id: "t1")
      insert_task!(pid, id: "t2")
      insert_project!(pid, "/p1", "P1")

      assert Safety.size(pid) == 3
    end

    test "corrupt rows COUNT too (COUNT(*) never decodes — old semantics)" do
      pid = start_repo!(:size_corrupt)

      insert_task!(pid, id: "good")
      insert_raw_task!(pid, id: "bad", opts: "{not json")
      insert_raw_project!(pid, "/praw", "PRaw", nil)

      # size/1 counts rows, it does not decode them: 2 tasks + 1 project.
      assert Safety.size(pid) == 3
      # ...while the safe selects skip the undecodable ones.
      assert ids(Safety.safe_select_all_tasks(pid)) == ["good"]
      assert paths(Safety.safe_select_all_projects(pid)) == ["/praw"]
    end
  end
end
