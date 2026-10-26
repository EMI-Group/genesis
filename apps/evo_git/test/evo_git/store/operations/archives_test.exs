defmodule EvoGit.Store.Operations.ArchivesTest do
  @moduledoc """
  Tests for `EvoGit.Store.Operations.Archives` — the relational per-agent
  archive (`task_agent_archives`).

  Pinned contracts:

    * `put/2` + `get/3` round-trip EVERY column: string-keyed entries out,
      ISO-8601 timestamps returned as the stored strings, JSON columns decoded
      back to maps/lists, and `nil` JSON columns staying `nil` (SQL NULL);
    * `repo_id` is a repo ID STRING (`"primary"` / a foreign repo id) that
      round-trips unchanged through put/get/list — an integer-shaped input is
      stored as its decimal TEXT, never coerced into an integer column;
    * `put/2` is IDEMPOTENT on `(task_id, agent_id)` — a re-put REPLACES the
      row (never duplicates it) and NULLs the columns the new entry omits;
    * both key spellings are accepted on write (atom-keyed producer maps and
      string-keyed maps straight out of `get/3`);
    * `list/3` pages `ORDER BY depth ASC, agent_id ASC` with `limit` default
      100 clamped to 1..1000, `offset` never negative, and a `total` that
      counts every row of the task regardless of the page;
    * `include_results: false` (the default) does not SELECT `result` at all,
      so the `"result"` key is ABSENT — not `nil`, not `""`;
    * `delete_by_task/2` / `delete_by_tasks/2` / `delete_all/1` remove exactly
      the rows they name, and the facade
      (`put_task_archive/2`, `list_task_archives/3`, `get_agent_archive/3`,
      `delete_task_archives/2`) passes those shapes through unchanged.

  Every test boots its own UNNAMED dynamic repo on a unique tmp SQLite file
  (`async: true` is safe — `EvoGit.Store.Boot` serializes migration runs with
  a `:global` lock), mirroring `operations/pages_test.exs`. The facade section
  starts its own uniquely-named `EvoGit.Store` GenServer instead, so it never
  touches the shared application store.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Operations.Archives
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskAgentArchiveRow

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Unique-per-call database file, then an UNNAMED dynamic repo (the same shape
  # `EvoGit.Store` boots in production).
  defp start_repo!(tag) do
    path =
      Path.join(
        System.tmp_dir!(),
        "evogit_archives_#{tag}_#{System.pid()}_#{System.system_time(:millisecond)}_" <>
          "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}.sqlite"
      )

    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: :ok = Boot.stop(pid), else: :ok
      File.rm(path)
      File.rm(path <> "-wal")
      File.rm(path <> "-shm")
    end)

    pid
  end

  # Uniquely-named store GenServer for the facade section.
  defp start_store! do
    unique =
      "#{System.pid()}_#{System.system_time(:millisecond)}_" <>
        "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}"

    data_dir = Path.join(System.tmp_dir!(), "evogit_archives_api_#{unique}.sqlite")
    name = :"archives_api_store_#{unique}"

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

  # A FULL entry — every column of the row, string-keyed (the shape the RPC /
  # dashboard layers carry and the shape `get/3` returns).
  defp full_entry(overrides \\ %{}) do
    Map.merge(
      %{
        "task_id" => "task-a",
        "agent_id" => 7,
        "parent_id" => 3,
        "depth" => 2,
        "agent_type" => "executor",
        "context_node_path" => "lib/evo_git/",
        "objective" => "Implement the thing",
        "result" => "Done — the thing is implemented.",
        "base_commit" => "base0001",
        "final_commit" => "final0002",
        "branch_name" => "evogit-agent-T1-A7",
        "archive_ref_start" => "refs/archive/start",
        "archive_ref_final" => "refs/archive/final",
        "repo_id" => "primary",
        "repo_root" => "/repo/primary",
        "repo_path" => "lib/evo_git",
        "usage" => %{"input_tokens" => 1200, "output_tokens" => 340, "total_cost" => 0.42},
        "llm_settings" => %{"model_id" => "deepseek-chat", "temperature" => 0.2},
        "agent_settings" => %{"max_turns" => 40, "delegation_level" => "low"},
        "foreign_repos" => [
          %{"id" => "docs", "path" => "/repo/docs", "writable" => true},
          %{"id" => "site", "path" => "/repo/site", "writable" => false}
        ],
        "compression_count" => 3,
        "started_at" => "2026-03-04T05:06:07.008Z",
        "completed_at" => "2026-03-04T05:16:07.000Z"
      },
      overrides
    )
  end

  # A minimal-but-identifying entry: only the composite key and a depth.
  defp seed(repo, task_id, agent_id, depth) do
    :ok = Archives.put(repo, %{task_id: task_id, agent_id: agent_id, depth: depth})
  end

  # ── put/2 + get/3 round trip ─────────────────────────────────────────────

  test "put/2 + get/3 round-trip every column, string-keyed" do
    repo = start_repo!("roundtrip")
    entry = full_entry()

    assert :ok = Archives.put(repo, entry)
    assert {:ok, stored} = Archives.get(repo, "task-a", 7)

    # The entry comes back EXACTLY as written: same 23 keys, same values, all
    # string-keyed. ISO-8601 timestamps are the stored STRINGS (never re-parsed
    # into DateTimes), and the four JSON columns are decoded back to terms.
    assert stored == entry

    assert stored["usage"] == %{
             "input_tokens" => 1200,
             "output_tokens" => 340,
             "total_cost" => 0.42
           }

    assert stored["llm_settings"] == %{"model_id" => "deepseek-chat", "temperature" => 0.2}
    assert stored["agent_settings"] == %{"max_turns" => 40, "delegation_level" => "low"}
    assert length(stored["foreign_repos"]) == 2
    assert Enum.at(stored["foreign_repos"], 0)["writable"] == true
    assert stored["started_at"] == "2026-03-04T05:06:07.008Z"
    assert stored["completed_at"] == "2026-03-04T05:16:07.000Z"
    # `repo_id` is a repo ID STRING ("primary" / a foreign repo id), never an
    # index — it comes back byte-identical.
    assert stored["repo_id"] == "primary"

    # STRING keys only — no atom-keyed twin.
    assert Map.has_key?(stored, "agent_id")
    refute Map.has_key?(stored, :agent_id)

    for key <- [
          "task_id",
          "agent_id",
          "parent_id",
          "depth",
          "agent_type",
          "context_node_path",
          "objective",
          "result",
          "base_commit",
          "final_commit",
          "branch_name",
          "archive_ref_start",
          "archive_ref_final",
          "repo_id",
          "repo_root",
          "repo_path",
          "usage",
          "llm_settings",
          "agent_settings",
          "foreign_repos",
          "compression_count",
          "started_at",
          "completed_at"
        ] do
      assert Map.has_key?(stored, key), "missing #{key}"
    end

    assert map_size(stored) == 23
  end

  test "repo_id round-trips as the repo ID STRING the runtime sends" do
    repo = start_repo!("repo-id")

    # The real domain: `AgentState.repo_id` is "primary" or a foreign repo id —
    # never an index. Both must survive put/get/list unchanged.
    :ok = Archives.put(repo, full_entry(%{"repo_id" => "primary"}))
    :ok = Archives.put(repo, full_entry(%{"agent_id" => 8, "repo_id" => "cowboy"}))

    assert {:ok, primary} = Archives.get(repo, "task-a", 7)
    assert primary["repo_id"] == "primary"

    assert {:ok, foreign} = Archives.get(repo, "task-a", 8)
    assert foreign["repo_id"] == "cowboy"

    assert {:ok, %{entries: entries, total: 2}} =
             Archives.list(repo, "task-a", include_results: true)

    # Same depth (2), so the roster orders by agent_id: 7 ("primary"), 8
    # ("cowboy").
    assert Enum.map(entries, & &1["repo_id"]) == ["primary", "cowboy"]
    assert Enum.all?(entries, &is_binary(&1["repo_id"]))

    # A re-put keeps the string form too (the column is TEXT, not a coerced one).
    assert :ok = Archives.put(repo, Map.put(primary, "result", "re-read then re-written"))
    assert {:ok, %{"repo_id" => "primary"}} = Archives.get(repo, "task-a", 7)

    # An integer-shaped input is STORED AS ITS DECIMAL TEXT (documented in
    # `normalize_repo_id/1`) so the on-disk format stays uniformly TEXT.
    :ok = Archives.put(repo, %{task_id: "task-int", agent_id: 1, repo_id: 0})
    assert {:ok, %{"repo_id" => "0"}} = Archives.get(repo, "task-int", 1)
  end

  test "put/2 rejects a repo_id that is neither a string nor an integer" do
    repo = start_repo!("repo-id-invalid")

    assert {:error, :invalid_repo_id} =
             Archives.put(repo, %{"task_id" => "task-a", "agent_id" => 1, "repo_id" => [1]})

    assert {:ok, %{entries: [], total: 0}} = Archives.list(repo, "task-a")
  end

  test "nil JSON columns stay nil and timestamps keep their stored spelling" do
    repo = start_repo!("nils")

    :ok =
      Archives.put(repo, %{
        task_id: "task-nil",
        agent_id: 0,
        started_at: "2026-03-04T05:06:07Z"
      })

    assert {:ok, stored} = Archives.get(repo, "task-nil", 0)

    assert stored["usage"] == nil
    assert stored["llm_settings"] == nil
    assert stored["agent_settings"] == nil
    assert stored["foreign_repos"] == nil
    # A non-millisecond ISO-8601 spelling is NOT normalized — the stored text is
    # returned byte-for-byte.
    assert stored["started_at"] == "2026-03-04T05:06:07Z"
    assert stored["completed_at"] == nil
    # Defaults applied on write.
    assert stored["depth"] == 0
    assert stored["compression_count"] == 0
    assert stored["result"] == nil
    assert stored["parent_id"] == nil
  end

  test "get/3 returns {:ok, nil} for an unknown agent or task" do
    repo = start_repo!("missing")
    :ok = Archives.put(repo, full_entry())

    assert {:ok, nil} = Archives.get(repo, "task-a", 999)
    assert {:ok, nil} = Archives.get(repo, "no-such-task", 7)
  end

  # ── Idempotence & key spellings ──────────────────────────────────────────

  test "re-putting the same (task_id, agent_id) REPLACES the row, never duplicates" do
    repo = start_repo!("idempotent")

    :ok = Archives.put(repo, full_entry())

    :ok =
      Archives.put(repo, %{
        task_id: "task-a",
        agent_id: 7,
        depth: 2,
        result: "second write",
        usage: %{"total_tokens" => 5}
      })

    assert {:ok, page} = Archives.list(repo, "task-a", include_results: true)
    assert page.total == 1
    assert length(page.entries) == 1

    assert {:ok, stored} = Archives.get(repo, "task-a", 7)
    assert stored["result"] == "second write"
    assert stored["usage"] == %{"total_tokens" => 5}
    # Replace semantics (INSERT OR REPLACE parity): every column the re-put
    # omits is NULLed / reset to its default.
    assert stored["objective"] == nil
    assert stored["final_commit"] == nil
    assert stored["foreign_repos"] == nil
    assert stored["compression_count"] == 0
    assert stored["started_at"] == nil
  end

  test "a string-keyed entry (as returned by get/3) is writable without reshaping" do
    repo = start_repo!("spellings")

    :ok = Archives.put(repo, full_entry())
    assert {:ok, read} = Archives.get(repo, "task-a", 7)

    # Read-modify-write: add one field, write the SAME entry back.
    updated = Map.put(read, "objective", "re-read then re-written")
    assert :ok = Archives.put(repo, updated)
    assert {:ok, again} = Archives.get(repo, "task-a", 7)
    assert again["objective"] == "re-read then re-written"
    assert again["result"] == read["result"]

    # An atom key wins over a string key of the same name when both are present.
    assert :ok =
             Archives.put(repo, %{"task_id" => "task-a", "agent_id" => 7, agent_id: 7, depth: 5})

    assert {:ok, depth5} = Archives.get(repo, "task-a", 7)
    assert depth5["depth"] == 5
  end

  test "put/2 rejects entries that cannot identify a row, without writing" do
    repo = start_repo!("validation")

    assert {:error, :missing_task_id} = Archives.put(repo, %{"agent_id" => 1})
    assert {:error, :missing_task_id} = Archives.put(repo, %{"task_id" => "", "agent_id" => 1})
    assert {:error, :missing_agent_id} = Archives.put(repo, %{"task_id" => "task-a"})

    assert {:error, :missing_agent_id} =
             Archives.put(repo, %{"task_id" => "task-a", "agent_id" => "1"})

    assert {:error, :invalid_entry} = Archives.put(repo, :not_a_map)

    assert {:ok, %{entries: [], total: 0}} = Archives.list(repo, "task-a")
  end

  # ── Paging ───────────────────────────────────────────────────────────────

  test "list/3 orders by depth then agent_id, and total ignores the page" do
    repo = start_repo!("paging-order")

    # Insertion order deliberately differs from both sort keys.
    seed(repo, "task-a", 7, 0)
    seed(repo, "task-a", 9, 1)
    seed(repo, "task-a", 2, 1)
    seed(repo, "task-a", 5, 0)
    seed(repo, "task-a", 11, 2)
    # Another task's rows must never leak in (nor be counted).
    seed(repo, "task-b", 1, 0)

    assert {:ok, %{entries: entries, total: 5}} = Archives.list(repo, "task-a")
    assert Enum.map(entries, & &1["agent_id"]) == [5, 7, 2, 9, 11]
    assert Enum.map(entries, & &1["depth"]) == [0, 0, 1, 1, 2]

    # Every entry is a STRING-keyed map.
    for entry <- entries do
      assert Map.has_key?(entry, "agent_id")
      refute Map.has_key?(entry, :agent_id)
    end
  end

  test "list/3 applies limit/offset while total counts every row" do
    repo = start_repo!("paging-window")

    for agent_id <- 1..10, do: seed(repo, "task-a", agent_id, 0)

    assert {:ok, %{entries: entries, total: 10}} =
             Archives.list(repo, "task-a", limit: 3)

    assert Enum.map(entries, & &1["agent_id"]) == [1, 2, 3]

    assert {:ok, %{entries: entries, total: 10}} =
             Archives.list(repo, "task-a", limit: 3, offset: 3)

    assert Enum.map(entries, & &1["agent_id"]) == [4, 5, 6]

    assert {:ok, %{entries: entries, total: 10}} =
             Archives.list(repo, "task-a", limit: 3, offset: 9)

    assert Enum.map(entries, & &1["agent_id"]) == [10]

    # Offset past the end: an EMPTY page (the last-page refetch belongs to the
    # dashboard's task page, not to this roster read) with the same total.
    assert {:ok, %{entries: [], total: 10}} =
             Archives.list(repo, "task-a", limit: 3, offset: 99)

    # A negative offset is clamped to 0; a negative limit is clamped to 1.
    assert {:ok, %{entries: [first], total: 10}} =
             Archives.list(repo, "task-a", limit: 1, offset: -5)

    assert first["agent_id"] == 1

    assert {:ok, %{entries: [only], total: 10}} =
             Archives.list(repo, "task-a", limit: 0)

    assert only["agent_id"] == 1
  end

  test "list/3 clamps the page size: default 100, minimum 1, maximum 1000" do
    repo = start_repo!("paging-clamp")

    # ONE statement to seed 1001 rows (the clamps need a task bigger than the
    # 1000-row cap; going through put/2 would issue 1001 writes for no added
    # coverage).
    RepoScope.with_repo(repo, fn ->
      rows = for agent_id <- 1..1001, do: %{task_id: "task-many", agent_id: agent_id, depth: 0}
      Repo.insert_all(TaskAgentArchiveRow, rows)
    end)

    # Default page size is 100.
    assert {:ok, %{entries: entries, total: 1001}} = Archives.list(repo, "task-many")
    assert length(entries) == 100

    # A too-large limit is capped at 1000 (not 1001, not 9999).
    assert {:ok, %{entries: entries, total: 1001}} =
             Archives.list(repo, "task-many", limit: 9999)

    assert length(entries) == 1000

    # A zero/negative limit becomes 1.
    assert {:ok, %{entries: entries}} = Archives.list(repo, "task-many", limit: 0)
    assert length(entries) == 1

    assert {:ok, %{entries: entries}} = Archives.list(repo, "task-many", limit: -7)
    assert length(entries) == 1

    # A non-integer limit falls back to the default.
    assert {:ok, %{entries: entries}} = Archives.list(repo, "task-many", limit: "lots")
    assert length(entries) == 100
  end

  # ── result projection ────────────────────────────────────────────────────

  test "include_results: false omits the \"result\" key entirely; true includes it" do
    repo = start_repo!("results")

    :ok = Archives.put(repo, full_entry())
    :ok = Archives.put(repo, full_entry(%{"agent_id" => 8, "result" => "second agent"}))

    # Default: no results — the key is ABSENT (not nil, not "").
    assert {:ok, %{entries: entries}} = Archives.list(repo, "task-a")
    assert length(entries) == 2

    for entry <- entries do
      refute Map.has_key?(entry, "result")
      refute Map.has_key?(entry, :result)
    end

    # Explicit false behaves like the default.
    assert {:ok, %{entries: entries}} = Archives.list(repo, "task-a", include_results: false)
    for entry <- entries, do: refute(Map.has_key?(entry, "result"))

    # include_results: true carries each agent's result text.
    assert {:ok, %{entries: entries}} = Archives.list(repo, "task-a", include_results: true)

    assert Enum.map(entries, & &1["result"]) == [
             "Done — the thing is implemented.",
             "second agent"
           ]

    # get/3 is always the FULL row, result included.
    assert {:ok, one} = Archives.get(repo, "task-a", 8)
    assert one["result"] == "second agent"
  end

  # ── Roster projection opt-ins ────────────────────────────────────────────
  test "the default roster keeps usage and omits the result + the three settings columns" do
    repo = start_repo!("roster-lean")
    :ok = Archives.put(repo, full_entry())

    assert {:ok, %{entries: [entry], total: 1}} = Archives.list(repo, "task-a")
    assert {:ok, full} = Archives.get(repo, "task-a", 7)

    # A lean entry is a STRICT subset of the full row: the same keys with the
    # same decoded values, minus the opt-in groups — ABSENT, never nil.
    assert entry ==
             Map.drop(full, ["result", "llm_settings", "agent_settings", "foreign_repos"])

    for absent <- ["result", "llm_settings", "agent_settings", "foreign_repos"] do
      refute Map.has_key?(entry, absent), "the lean roster entry must not carry #{absent}"
    end

    # `usage` is NOT opt-in: every roster view shows the token/cost figures.
    assert Map.has_key?(entry, "usage")

    assert entry["usage"] == %{
             "input_tokens" => 1200,
             "output_tokens" => 340,
             "total_cost" => 0.42
           }
  end

  test "include_settings: true adds exactly the three settings columns, decoded" do
    repo = start_repo!("roster-settings")
    :ok = Archives.put(repo, full_entry())

    assert {:ok, %{entries: [entry]}} = Archives.list(repo, "task-a", include_settings: true)

    assert entry["llm_settings"] == %{"model_id" => "deepseek-chat", "temperature" => 0.2}
    assert entry["agent_settings"] == %{"max_turns" => 40, "delegation_level" => "low"}
    assert length(entry["foreign_repos"]) == 2
    assert Enum.at(entry["foreign_repos"], 0)["writable"] == true

    # The settings opt-in does NOT drag the heavy `result` column along.
    refute Map.has_key?(entry, "result")

    # Both opt-ins together are the FULL row, byte for byte the `get/3` entry.
    assert {:ok, %{entries: [with_result]}} =
             Archives.list(repo, "task-a", include_settings: true, include_results: true)

    assert {:ok, full} = Archives.get(repo, "task-a", 7)
    assert with_result == full
  end

  test "include_total: false answers total: nil (never 0, never a partial count)" do
    repo = start_repo!("roster-total")
    for agent_id <- 1..3, do: seed(repo, "task-a", agent_id, 0)

    assert {:ok, %{entries: [_, _, _], total: 3}} = Archives.list(repo, "task-a")

    assert {:ok, %{entries: entries, total: nil}} =
             Archives.list(repo, "task-a", include_total: false, limit: 2)

    # The page itself is unchanged; only the aggregate is skipped.
    assert Enum.map(entries, & &1["agent_id"]) == [1, 2]

    assert {:ok, %{entries: [with_total], total: 3}} = Archives.list(repo, "task-a", limit: 1)
    assert Map.keys(hd(entries)) |> Enum.sort() == Map.keys(with_total) |> Enum.sort()

    # An EMPTY roster answers `nil` too, not 0 — the caller asked for no count.
    assert {:ok, %{entries: [], total: nil}} =
             Archives.list(repo, "no-such-task", include_total: false)
  end

  # ── Deletes ──────────────────────────────────────────────────────────────

  test "delete_by_task/2 deletes only that task's rows" do
    repo = start_repo!("delete-one")

    seed(repo, "task-a", 1, 0)
    seed(repo, "task-a", 2, 1)
    seed(repo, "task-b", 1, 0)

    assert :ok = Archives.delete_by_task(repo, "task-a")
    assert {:ok, %{entries: [], total: 0}} = Archives.list(repo, "task-a")
    assert {:ok, %{entries: [_kept], total: 1}} = Archives.list(repo, "task-b")

    # Deleting an already-empty task is a successful no-op.
    assert :ok = Archives.delete_by_task(repo, "task-a")
    assert :ok = Archives.delete_by_task(repo, "never-existed")
  end

  test "delete_by_tasks/2 removes exactly the named tasks, in chunks" do
    repo = start_repo!("delete-many")

    # 600 ids → two chunks (the 500-id batch boundary is exercised for real).
    task_ids = for i <- 1..600, do: "task-#{i}"
    for task_id <- task_ids, do: seed(repo, task_id, 1, 0)
    seed(repo, "task-keep", 1, 0)

    assert :ok = Archives.delete_by_tasks(repo, task_ids)

    for task_id <- ["task-1", "task-500", "task-501", "task-600"] do
      assert {:ok, %{entries: [], total: 0}} = Archives.list(repo, task_id)
    end

    assert {:ok, %{entries: [_kept], total: 1}} = Archives.list(repo, "task-keep")

    assert :ok = Archives.delete_by_tasks(repo, [])
  end

  test "delete_all/1 clears the table" do
    repo = start_repo!("delete-all")

    seed(repo, "task-a", 1, 0)
    seed(repo, "task-b", 1, 0)

    assert :ok = Archives.delete_all(repo)
    assert {:ok, %{entries: [], total: 0}} = Archives.list(repo, "task-a")
    assert {:ok, %{entries: [], total: 0}} = Archives.list(repo, "task-b")
  end

  # ── Facade ───────────────────────────────────────────────────────────────

  test "Store facade dispatches put/list/get/delete and keeps the documented shapes" do
    store = start_store!()
    entry = full_entry()

    assert :ok = Store.put_task_archive(store, entry)
    assert :ok = Store.put_task_archive(store, full_entry(%{"agent_id" => 8, "depth" => 0}))

    # list_task_archives/3 → %{entries: [...], total: n}, no results by default.
    assert %{entries: entries, total: 2} = Store.list_task_archives(store, "task-a")
    assert Enum.map(entries, & &1["agent_id"]) == [8, 7]
    for entry <- entries, do: refute(Map.has_key?(entry, "result"))

    assert %{entries: entries, total: 2} =
             Store.list_task_archives(store, "task-a", include_results: true, limit: 1)

    assert length(entries) == 1
    assert hd(entries)["result"] == entry["result"]

    # get_agent_archive/3 → the full entry map, nil when absent.
    assert %{"agent_id" => 7, "result" => "Done — the thing is implemented."} =
             Store.get_agent_archive(store, "task-a", 7)

    assert Store.get_agent_archive(store, "task-a", 999) == nil
    assert Store.get_agent_archive(store, "no-such-task", 7) == nil

    # Re-put is still idempotent through the facade.
    assert :ok = Store.put_task_archive(store, full_entry(%{"result" => "facade re-put"}))
    assert %{"result" => "facade re-put"} = Store.get_agent_archive(store, "task-a", 7)
    assert %{total: 2} = Store.list_task_archives(store, "task-a")

    # delete_task_archives/2 deletes only that task's rows.
    assert :ok =
             Store.put_task_archive(store, full_entry(%{"task_id" => "task-b", "agent_id" => 1}))

    assert :ok = Store.delete_task_archives(store, "task-a")
    assert %{entries: [], total: 0} = Store.list_task_archives(store, "task-a")
    assert %{total: 1} = Store.list_task_archives(store, "task-b")
  end
end
