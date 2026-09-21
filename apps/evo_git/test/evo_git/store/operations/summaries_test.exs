defmodule EvoGit.Store.Operations.SummariesTest do
  @moduledoc """
  Tests for `EvoGit.Store.Operations.Summaries` — the Ecto port of the three
  raw-SQL summary-projection handlers (unit R3b).

  Pinned contracts (mirror of the raw store's `@summary_columns` handlers in
  `store.ex` — zero consumer changes allowed):

    * EXACT 16-key map shape on every row: id, status, review_status,
      started_at, finished_at, type, project_path, opts, branch_name, model_id,
      agent_count, base_sha, commit_sha, lease_expires_at, updated_at, error
    * `updated_at` is the RAW stored ISO string, byte-identical (a typed
      DateTime select would round-trip the spelling)
    * `result` is NEVER selected — a huge/corrupt `result` column does not
      affect the summary path at all
    * `statuses` pushes atoms down as TEXT strings; `since` is a STRICT
      raw-string `updated_at >` compare; `project_path` exact equality
    * `error` lenient-decodes: atom-keyed map for :failed rows, nil otherwise
    * undecodable rows (raising `opts` decode) are skipped + logged
    * NO ORDER BY / NO LIMIT (rows come back in insertion/table order)

  Tests drive REAL unnamed dynamic repo instances (`Boot.start_dynamic/1`),
  seeding rows with `Repo.insert_all(TaskRow, ...)` — typed dumps through the
  Codec (raw schemas are read-projection only).
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Operations.Summaries
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRow
  alias EvoGit.TestSupport.StoreBootLock

  @summary_keys [
    :id,
    :status,
    :review_status,
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
    :updated_at,
    :error
  ]

  # The raw fixed-precision (24-char) ISO string seeded for the byte-identical
  # `updated_at` assertions.
  @raw_updated_at "2024-01-02T03:04:05.678Z"

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Starts an unnamed dynamic repo on a UNIQUE tmp database file (per test
  # process, per call — `async: true` safe) and stops it on test exit.
  #
  # The boot is serialized through the BEAM-global `StoreBootLock` —
  # `Ecto.Migrator` recompiles each `.exs` migration on every pending run, and
  # concurrent compiles of the same module race (see
  # `EvoGit.TestSupport.StoreBootLock`'s moduledoc).
  #
  # The repo is UNLINKED: `Boot.start_dynamic/1` links it to this test process
  # and `on_exit/1` callbacks run after that process is gone, so the link's
  # exit signal must not own the shutdown. The alive-guard keeps cleanup safe
  # for tests that stopped their instance manually.
  defp start_repo!(tag) do
    # The name embeds the OS pid + wall-clock ms ON TOP OF the per-BEAM unique
    # integer + test pid: `System.unique_integer/1` restarts in every BEAM and
    # test pids are deterministic across runs, so without those a PREVIOUS
    # test run's stale tmp file (rows committed, BEAM long gone) silently gets
    # adopted — a fresh-looking DB that already holds the seeded rows.
    path =
      Path.join(
        System.tmp_dir!(),
        "evogit_r3b_#{tag}_#{System.pid()}_#{System.system_time(:millisecond)}_" <>
          "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}.sqlite"
      )

    {:ok, pid} = StoreBootLock.with_boot_lock(fn -> Boot.start_dynamic(path) end)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid), else: :ok end)
    pid
  end

  defp with_repo(pid, fun), do: RepoScope.with_repo(pid, fun)

  # Seeds one task row through the TYPED schema — `insert_all` dumps values
  # through the schema's Ecto types (thin Codec delegation), i.e. the canonical
  # wire format. `updated_at` is `TaskTimestampRaw`, so the seeded raw string
  # is stored byte-identically (no round-trip).
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
      updated_at: @raw_updated_at
    ]

    row = Keyword.merge(defaults, overrides)

    {1, nil} =
      with_repo(pid, fn ->
        Repo.insert_all(TaskRow, [row])
      end)

    Keyword.fetch!(row, :id)
  end

  # Writes a row with ARBITRARY raw column text (bypassing the typed schema's
  # dump) — used to seed corrupt `opts`/`result` wire values the typed schema
  # could never produce.
  defp insert_raw_text!(pid, overrides) do
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
      updated_at: @raw_updated_at
    ]

    row = Keyword.merge(defaults, overrides)

    {1, nil} =
      with_repo(pid, fn ->
        Repo.insert_all(EvoGit.Store.Schemas.TaskRowRaw, [row])
      end)

    Keyword.fetch!(row, :id)
  end

  defp ids(summaries), do: Enum.map(summaries, & &1.id)

  # ── 16-key projection shape ──────────────────────────────────────────────

  describe "projection shape" do
    test "every row carries EXACTLY the 16 summary keys (no result, no extras)" do
      pid = start_repo!(:shape)
      seeded = insert_task!(pid, id: "t16", error: nil)

      [row] = Summaries.select_tasks_summary(pid, [], nil)

      assert Map.keys(row) |> Enum.sort() == Enum.sort(@summary_keys)
      assert Map.has_key?(row, :result) == false
      assert row.id == seeded
    end

    test "decoded field types: atoms, DateTimes, keyword opts, integer counts" do
      pid = start_repo!(:types)
      started = ~U[2024-01-01 05:06:07.890Z]

      insert_task!(pid,
        id: "ttypes",
        status: :completed,
        review_status: :open,
        type: :genesis,
        started_at: started,
        finished_at: ~U[2024-01-01 06:06:06.000Z],
        opts: [objective: "obj", mode: "simple"],
        agent_count: 7,
        lease_expires_at: 1_700_000_000_000,
        branch_name: "genesis/agent_dead",
        commit_sha: "abc123",
        base_sha: "def456"
      )

      [row] = Summaries.select_tasks_summary(pid, [], nil)

      assert row.id == "ttypes"
      assert row.status == :completed
      assert row.review_status == :open
      assert row.type == :genesis
      assert row.started_at == started
      assert row.finished_at == ~U[2024-01-01 06:06:06.000Z]
      # `opts` round-trips through a JSON object (map key order is unstable),
      # so the keyword order is not guaranteed — compare order-insensitively.
      assert Enum.sort(row.opts) == Enum.sort(objective: "obj", mode: "simple")
      assert row.project_path == "/repo/x"
      assert row.branch_name == "genesis/agent_dead"
      assert row.model_id == "test-model"
      assert row.agent_count == 7
      assert row.base_sha == "def456"
      assert row.commit_sha == "abc123"
      assert row.lease_expires_at == 1_700_000_000_000
      assert row.error == nil
    end

    test "updated_at is the RAW stored ISO string, byte-identical" do
      pid = start_repo!(:raw_ts)
      insert_task!(pid, id: "t_raw", updated_at: @raw_updated_at)

      [row] = Summaries.select_tasks_summary(pid, [], nil)

      assert row.updated_at == "2024-01-02T03:04:05.678Z"
      assert is_binary(row.updated_at)
      assert row.started_at == ~U[2024-01-01 00:00:00.000Z]
    end

    test "a huge / undecodable result column never affects the summary read" do
      pid = start_repo!(:heavy_result)

      # 60 KB of legal (but never-summary-selected) result text plus a row
      # whose result is outright broken JSON — the summary path must return
      # BOTH rows untouched because `result` is never selected or decoded.
      big = String.duplicate("x", 60_000)

      insert_raw_text!(pid,
        id: "heavy",
        result: "{\"__result_tag__\":\"string\",\"value\":\"#{big}\"}"
      )

      insert_raw_text!(pid, id: "corrupt_result", result: "{not json at all [")

      rows = Summaries.select_tasks_summary(pid, [], nil)

      assert ids(rows) |> Enum.sort() == ["corrupt_result", "heavy"]
      assert Enum.all?(rows, fn row -> not Map.has_key?(row, :result) end)
    end
  end

  # ── statuses filter ──────────────────────────────────────────────────────

  describe "statuses filter" do
    test "empty statuses returns ALL rows (no WHERE clause)" do
      pid = start_repo!(:all)
      a = insert_task!(pid, id: "s_all_a", status: :running)
      b = insert_task!(pid, id: "s_all_b", status: :completed)
      c = insert_task!(pid, id: "s_all_c", status: :failed)

      assert ids(Summaries.select_tasks_summary(pid, [], nil)) |> Enum.sort() ==
               Enum.sort([a, b, c])
    end

    test "atoms are pushed down as TEXT strings (mixed-match selection)" do
      pid = start_repo!(:filter)
      insert_task!(pid, id: "s_run", status: :running)
      insert_task!(pid, id: "s_done", status: :completed)
      insert_task!(pid, id: "s_fail", status: :failed)

      assert ids(Summaries.select_tasks_summary(pid, [:running], nil)) == ["s_run"]

      assert ids(Summaries.select_tasks_summary(pid, [:running, :failed], nil)) |> Enum.sort() ==
               ["s_fail", "s_run"]

      assert ids(Summaries.select_tasks_summary(pid, [:pending], nil)) == []
    end

    test "statuses filter composes with since" do
      pid = start_repo!(:status_since)
      insert_task!(pid, id: "old_run", status: :running, updated_at: "2024-01-01T00:00:00.000Z")
      insert_task!(pid, id: "new_run", status: :running, updated_at: "2024-06-01T00:00:00.000Z")

      insert_task!(pid,
        id: "new_done",
        status: :completed,
        updated_at: "2024-06-01T00:00:00.000Z"
      )

      got = Summaries.select_tasks_summary(pid, [:running], "2024-03-01T00:00:00.000Z")

      assert ids(got) == ["new_run"]
    end
  end

  # ── since boundary ───────────────────────────────────────────────────────

  describe "since boundary (strict raw-string compare)" do
    test "before / at / after straddle: only strictly-newer rows return" do
      pid = start_repo!(:since)

      insert_task!(pid, id: "older", updated_at: "2024-01-01T00:00:00.000Z")
      insert_task!(pid, id: "exact", updated_at: "2024-03-01T12:00:00.000Z")
      insert_task!(pid, id: "newer", updated_at: "2024-06-01T00:00:00.000Z")

      # AT the boundary — STRICT `>`: the equal row is excluded.
      assert ids(Summaries.select_tasks_summary(pid, [], "2024-03-01T12:00:00.000Z")) ==
               ["newer"]

      # Before the boundary — both later rows (strict) return.
      assert ids(Summaries.select_tasks_summary(pid, [], "2024-02-01T00:00:00.000Z"))
             |> Enum.sort() ==
               ["exact", "newer"]

      # After every row — nothing returns.
      assert ids(Summaries.select_tasks_summary(pid, [], "2024-07-01T00:00:00.000Z")) == []
    end

    test "millisecond-precision straddling compares lexicographically" do
      pid = start_repo!(:since_ms)
      insert_task!(pid, id: "ms_low", updated_at: "2024-03-01T12:00:00.001Z")
      insert_task!(pid, id: "ms_high", updated_at: "2024-03-01T12:00:00.999Z")

      # 1ms below both, and a timestamp falling BETWEEN the two rows.
      assert ids(Summaries.select_tasks_summary(pid, [], "2024-03-01T12:00:00.000Z"))
             |> Enum.sort() ==
               ["ms_high", "ms_low"]

      assert ids(Summaries.select_tasks_summary(pid, [], "2024-03-01T12:00:00.500Z")) ==
               ["ms_high"]
    end

    test "select_tasks_changed_since/2 uses the same strict compare" do
      pid = start_repo!(:changed_since)
      insert_task!(pid, id: "cs_old", updated_at: "2024-01-01T00:00:00.000Z")
      insert_task!(pid, id: "cs_edge", updated_at: "2024-03-01T12:00:00.000Z")
      insert_task!(pid, id: "cs_new", updated_at: "2024-06-01T00:00:00.000Z")

      assert ids(Summaries.select_tasks_changed_since(pid, "2024-03-01T12:00:00.000Z")) ==
               ["cs_new"]

      assert ids(Summaries.select_tasks_changed_since(pid, "2024-01-01T00:00:00.000Z"))
             |> Enum.sort() ==
               ["cs_edge", "cs_new"]
    end
  end

  # ── by_path filter ───────────────────────────────────────────────────────

  describe "project_path filter" do
    test "exact TEXT equality on project_path" do
      pid = start_repo!(:by_path)

      insert_task!(pid,
        id: "p_a1",
        project_path: "/proj/a",
        updated_at: "2024-01-01T00:00:00.000Z"
      )

      insert_task!(pid,
        id: "p_a2",
        project_path: "/proj/a",
        updated_at: "2024-02-01T00:00:00.000Z"
      )

      insert_task!(pid,
        id: "p_b1",
        project_path: "/proj/b",
        updated_at: "2024-03-01T00:00:00.000Z"
      )

      # Prefix path — must NOT match (exact equality, not LIKE).
      insert_task!(pid,
        id: "p_prefix",
        project_path: "/proj/a/sub",
        updated_at: "2024-04-01T00:00:00.000Z"
      )

      got = Summaries.select_tasks_summary_by_path(pid, "/proj/a", [], nil)

      assert ids(got) |> Enum.sort() == ["p_a1", "p_a2"]

      assert ids(Summaries.select_tasks_summary_by_path(pid, "/proj/missing", [], nil)) == []
    end

    test "project_path composes with statuses and since" do
      pid = start_repo!(:by_path_compose)

      insert_task!(pid,
        id: "pc_run_old",
        project_path: "/proj/c",
        status: :running,
        updated_at: "2024-01-01T00:00:00.000Z"
      )

      insert_task!(pid,
        id: "pc_run_new",
        project_path: "/proj/c",
        status: :running,
        updated_at: "2024-06-01T00:00:00.000Z"
      )

      insert_task!(pid,
        id: "pc_done_new",
        project_path: "/proj/c",
        status: :completed,
        updated_at: "2024-06-01T00:00:00.000Z"
      )

      insert_task!(pid,
        id: "pc_other_path",
        project_path: "/proj/d",
        status: :running,
        updated_at: "2024-06-01T00:00:00.000Z"
      )

      got =
        Summaries.select_tasks_summary_by_path(
          pid,
          "/proj/c",
          [:running],
          "2024-03-01T00:00:00.000Z"
        )

      assert ids(got) == ["pc_run_new"]
    end

    test "nil project_path rows never match a concrete path" do
      pid = start_repo!(:by_path_nil)
      insert_task!(pid, id: "np", project_path: nil)

      assert Summaries.select_tasks_summary_by_path(pid, "/proj/a", [], nil) == []
    end
  end

  # ── error lenient-decode ─────────────────────────────────────────────────

  describe "error lenient decode" do
    test "a :failed row with valid error JSON decodes to an atom-keyed map" do
      pid = start_repo!(:err_failed)

      insert_task!(pid,
        id: "ef",
        status: :failed,
        error: %{
          kind: :timeout,
          source: :result_handler,
          message: "boom",
          stacktrace: ["frame1", "frame2"]
        }
      )

      [row] = Summaries.select_tasks_summary(pid, [:failed], nil)

      assert row.error == %{
               kind: :timeout,
               source: :result_handler,
               message: "boom",
               stacktrace: ["frame1", "frame2"]
             }

      assert is_map(row.error)
      assert is_atom(Map.keys(row.error) |> hd())
    end

    test "non-:failed rows (nil error column) decode error to nil" do
      pid = start_repo!(:err_nonfailed)
      insert_task!(pid, id: "er", status: :running, error: nil)

      [row] = Summaries.select_tasks_summary(pid, [], nil)
      assert row.error == nil
    end

    test "error is lenient: undecodable error text yields nil, never a skip" do
      pid = start_repo!(:err_lenient)

      # `error` decode is LENIENT by contract (Codec.decode_error/1 never
      # raises) — a corrupt error column must NOT trip the skip-and-log path.
      insert_raw_text!(pid, id: "ebad", status: "failed", error: "{broken json [")
      insert_raw_text!(pid, id: "escalar", status: "failed", error: "42")

      rows = Summaries.select_tasks_summary(pid, [], nil)

      assert ids(rows) |> Enum.sort() == ["ebad", "escalar"]

      for row <- rows do
        assert row.error == nil
      end
    end
  end

  # ── lenient per-row skip ─────────────────────────────────────────────────

  describe "undecodable-row skip" do
    test "a row with raising opts JSON is skipped and logged; other rows survive" do
      pid = start_repo!(:skip)

      insert_task!(pid, id: "good_one", status: :running)
      # Legacy positional pair-array opts — Codec.decode_opts/1 raises
      # ArgumentError ("expected JSON object"); the row must be SKIPPED.
      insert_raw_text!(pid, id: "bad_opts", opts: "[[\"objective\",\"x\"]]")
      insert_task!(pid, id: "good_two", status: :completed)

      rows = Summaries.select_tasks_summary(pid, [], nil)

      assert ids(rows) |> Enum.sort() == ["good_one", "good_two"]

      # The skip applies identically on the by_path and changed-since shapes.
      assert ids(Summaries.select_tasks_summary_by_path(pid, "/repo/x", [], nil)) |> Enum.sort() ==
               ["good_one", "good_two"]

      assert ids(Summaries.select_tasks_changed_since(pid, "2023-01-01T00:00:00.000Z"))
             |> Enum.sort() ==
               ["good_one", "good_two"]
    end

    test "invalid (non-JSON) opts text is skipped too" do
      pid = start_repo!(:skip_invalid)
      insert_raw_text!(pid, id: "inv", opts: "not json {{")
      insert_task!(pid, id: "ok", status: :running)

      assert ids(Summaries.select_tasks_summary(pid, [], nil)) == ["ok"]
    end

    test "all rows undecodable yields []" do
      pid = start_repo!(:skip_all)
      insert_raw_text!(pid, id: "b1", opts: "1")
      insert_raw_text!(pid, id: "b2", opts: "\"scalar\"")

      assert Summaries.select_tasks_summary(pid, [], nil) == []
    end
  end

  # ── no ORDER BY / no LIMIT ───────────────────────────────────────────────

  describe "ordering and limits" do
    test "rows return in table order with no truncation (many rows)" do
      pid = start_repo!(:no_limit)

      for i <- 1..40 do
        insert_task!(pid, id: "row_#{String.pad_leading(Integer.to_string(i), 2, "0")}")
      end

      rows = Summaries.select_tasks_summary(pid, [], nil)

      assert length(rows) == 40
      # No ORDER BY: SQLite returns rows in rowid (insertion) order.
      assert ids(rows) ==
               Enum.map(1..40, &"row_#{String.pad_leading(Integer.to_string(&1), 2, "0")}")
    end
  end
end
