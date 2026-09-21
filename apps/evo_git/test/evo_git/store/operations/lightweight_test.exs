defmodule EvoGit.Store.Operations.LightweightTest do
  @moduledoc """
  Tests for `EvoGit.Store.Operations.Lightweight` — the Ecto ports of the
  lightweight-ID/lease/cleanup query handlers.

  Every test drives a REAL unnamed dynamic repo instance
  (`EvoGit.Store.Boot.start_dynamic/1`) and seeds rows through the TYPED
  `TaskRow` schema (`Repo.insert_all` — the schema dumps via the Codec: status
  atoms → TEXT, `%DateTime{}` → fixed-ms ISO, opts/result JSON-encodable
  terms), then reads through the operation under test and pins the EXACT
  return shape of the old raw-SQL handler it ports.

  Pinned contracts (per handler):

    * `select_task_paths/1` — DISTINCT non-nil project_path strings (dups
      collapse), nil paths dropped; empty DB → `[]`.
    * `select_finished_task_ids/1` — ids of every status EXCEPT
      running/pending/cancelling (`:finalizing` IS in the finished set);
      no decode — raw id strings.
    * `select_task_ids/2` — `%{id, status, updated_at}` maps; `[]` statuses
      = all rows; atom statuses pushed into SQL as their TEXT spelling;
      `updated_at` returned RAW (the stored ISO string, not a DateTime).
    * `select_running_lease_info/1` — `%{id, status, lease_expires_at}` maps
      for ONLY running/finalizing/cancelling rows; `lease_expires_at` is the
      raw INTEGER; `status` the decoded atom.
    * `select_cleanup_info/1` — `%{id, finished_at}` maps for finished rows
      only (`finished_at IS NOT NULL`), `finished_at` decoded to DateTime.
    * `select_cleanup_info/3` — `q1_ids ++ q2_ids`: Q1 = strictly
      `finished_at < cutoff` (ALL age-expired, no count trim — a row exactly
      AT the cutoff is NOT age-expired); Q2 = `finished_at >= cutoff` beyond
      the newest `max_tasks` (newest-first, offset-past-cap).
  """

  use ExUnit.Case, async: true

  require Ecto.Query

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Operations.Lightweight
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRow

  @cutoff ~U[2024-06-01 00:00:00.000Z]
  @cutoff_iso "2024-06-01T00:00:00.000Z"

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Starts an unnamed dynamic repo on a UNIQUE tmp database file (per test
  # process — `async: true` safe), unlinked, stopped on exit.
  #
  # The production `EvoGit.Store.Boot` serializes concurrent migration runs
  # globally (`:global.trans`), so parallel boots are safe.
  defp start_repo! do
    unique = System.unique_integer([:positive, :monotonic])

    path =
      Path.join(System.tmp_dir!(), "evogit_r3a_#{unique}_#{inspect(self())}.sqlite")

    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid), else: :ok end)
    pid
  end

  # Seeds rows through the TYPED TaskRow schema (the correct write path —
  # raw schemas are read-projection only). Each entry:
  # {id, status, project_path, finished_at, lease_expires_at}
  defp seed!(pid, rows) do
    entries =
      Enum.map(rows, fn {id, status, project_path, finished_at, lease} ->
        [
          id: id,
          type: :evolve,
          status: status,
          opts: [path: "/tmp/repo", mode: "simple"],
          updated_at: ~U[2024-05-05 05:05:05.555Z],
          finished_at: finished_at,
          project_path: project_path,
          lease_expires_at: lease
        ]
      end)

    RepoScope.with_repo(pid, fn -> Repo.insert_all(TaskRow, entries) end)
  end

  defp old_finished_finished_at, do: DateTime.add(@cutoff, -1, :millisecond)

  # One row per status spanning the finished/live/lease sets + the nil-path
  # case. finished_at: old (< cutoff), at-cutoff, new (> cutoff), nil.
  @spec standard_rows() :: [
          {String.t(), atom(), String.t() | nil, DateTime.t() | nil, integer() | nil}
        ]
  defp standard_rows do
    [
      # ── live statuses (never "finished", never lease-info) ──
      {"t-pending", :pending, "/p/a", nil, nil},
      {"t-running", :running, "/p/a", nil, 111},
      {"t-cancelling", :cancelling, nil, nil, 333},
      # ── lease-only extra statuses ──
      {"t-finalizing", :finalizing, "/p/b", nil, 222},
      # ── finished statuses (finished_at IS NOT NULL variants) ──
      {"t-completed", :completed, "/p/b", old_finished_finished_at(), nil},
      {"t-failed", :failed, "/p/c", @cutoff, nil},
      {"t-cancelled", :cancelled, "/p/c", @cutoff, nil},
      {"t-completed-new", :completed, "/p/c", DateTime.add(@cutoff, 1, :millisecond), 444}
    ]
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  # ── select_task_paths/1 ──────────────────────────────────────────────────

  describe "select_task_paths/1" do
    test "returns distinct non-nil project paths (dups collapse)" do
      pid = start_repo!()
      seed!(pid, standard_rows())

      assert MapSet.new(Lightweight.select_task_paths(pid)) ==
               MapSet.new(["/p/a", "/p/b", "/p/c"])
    end

    test "returns each distinct path exactly once" do
      pid = start_repo!()
      seed!(pid, standard_rows())

      paths = Lightweight.select_task_paths(pid)
      assert length(paths) == length(Enum.uniq(paths))
    end

    test "returns [] on an empty database" do
      pid = start_repo!()
      assert Lightweight.select_task_paths(pid) == []
    end

    test "returns [] when every project_path is nil" do
      pid = start_repo!()
      seed!(pid, [{"t-a", :completed, nil, @cutoff, nil}])

      assert Lightweight.select_task_paths(pid) == []
    end
  end

  # ── select_finished_task_ids/1 ───────────────────────────────────────────

  describe "select_finished_task_ids/1" do
    test "returns exactly the ids NOT running/pending/cancelling" do
      pid = start_repo!()
      seed!(pid, standard_rows())

      assert MapSet.new(Lightweight.select_finished_task_ids(pid)) ==
               MapSet.new([
                 "t-finalizing",
                 "t-completed",
                 "t-failed",
                 "t-cancelled",
                 "t-completed-new"
               ])
    end

    test "returns [] on an empty database" do
      pid = start_repo!()
      assert Lightweight.select_finished_task_ids(pid) == []
    end

    test "returns [] when only live-status rows exist" do
      pid = start_repo!()

      seed!(pid, [
        {"t-p", :pending, "/p/a", nil, nil},
        {"t-r", :running, "/p/a", nil, 1},
        {"t-c", :cancelling, nil, nil, 2}
      ])

      assert Lightweight.select_finished_task_ids(pid) == []
    end
  end

  # ── select_task_ids/2 ────────────────────────────────────────────────────

  describe "select_task_ids/2" do
    test "[] statuses returns ALL rows with the exact map shape" do
      pid = start_repo!()
      seed!(pid, standard_rows())

      rows = Lightweight.select_task_ids(pid, [])

      assert length(rows) == 8

      assert %{
               id: "t-running",
               status: :running,
               updated_at: "2024-05-05T05:05:05.555Z"
             } in rows

      # updated_at is the RAW stored ISO string, never a DateTime
      refute Enum.any?(rows, &match?(%DateTime{}, &1.updated_at))
    end

    test "subset statuses filters in SQL and maps atoms to TEXT" do
      pid = start_repo!()
      seed!(pid, standard_rows())

      assert MapSet.new(Lightweight.select_task_ids(pid, [:completed]) |> ids()) ==
               MapSet.new(["t-completed", "t-completed-new"])

      assert MapSet.new(Lightweight.select_task_ids(pid, [:running, :cancelling]) |> ids()) ==
               MapSet.new(["t-running", "t-cancelling"])

      assert MapSet.new(Lightweight.select_task_ids(pid, [:finalizing, :failed]) |> ids()) ==
               MapSet.new(["t-finalizing", "t-failed"])
    end

    test "a status no row has returns []" do
      pid = start_repo!()
      seed!(pid, standard_rows())

      assert Lightweight.select_task_ids(pid, [:nope_status_like]) == []
    end

    test "returns [] on an empty database (with and without a filter)" do
      pid = start_repo!()

      assert Lightweight.select_task_ids(pid, []) == []
      assert Lightweight.select_task_ids(pid, [:running]) == []
    end
  end

  # ── select_running_lease_info/1 ──────────────────────────────────────────

  describe "select_running_lease_info/1" do
    test "returns the exact shape for ONLY running/finalizing/cancelling rows" do
      pid = start_repo!()
      seed!(pid, standard_rows())

      rows = Lightweight.select_running_lease_info(pid)

      assert MapSet.new(rows) ==
               MapSet.new([
                 %{id: "t-running", status: :running, lease_expires_at: 111},
                 %{id: "t-finalizing", status: :finalizing, lease_expires_at: 222},
                 %{id: "t-cancelling", status: :cancelling, lease_expires_at: 333}
               ])
    end

    test "returns [] on an empty database" do
      pid = start_repo!()
      assert Lightweight.select_running_lease_info(pid) == []
    end

    test "excludes terminal statuses even when they carry a lease" do
      pid = start_repo!()
      seed!(pid, [{"t-done", :completed, "/p/a", @cutoff, 999}])

      assert Lightweight.select_running_lease_info(pid) == []
    end

    test "keeps a nil lease_expires_at as nil (raw INTEGER column)" do
      pid = start_repo!()
      seed!(pid, [{"t-r", :running, "/p/a", nil, nil}])

      assert Lightweight.select_running_lease_info(pid) == [
               %{id: "t-r", status: :running, lease_expires_at: nil}
             ]
    end
  end

  # ── select_cleanup_info/1 ────────────────────────────────────────────────

  describe "select_cleanup_info/1" do
    test "returns %{id, finished_at} maps for finished rows only, decoded" do
      pid = start_repo!()
      seed!(pid, standard_rows())

      rows = Lightweight.select_cleanup_info(pid)

      assert MapSet.new(rows) ==
               MapSet.new([
                 %{id: "t-completed", finished_at: old_finished_finished_at()},
                 %{id: "t-failed", finished_at: @cutoff},
                 %{id: "t-cancelled", finished_at: @cutoff},
                 %{id: "t-completed-new", finished_at: DateTime.add(@cutoff, 1, :millisecond)}
               ])
    end

    test "returns [] on an empty database" do
      pid = start_repo!()
      assert Lightweight.select_cleanup_info(pid) == []
    end

    test "returns [] when no row has a finished_at" do
      pid = start_repo!()
      seed!(pid, [{"t-r", :running, "/p/a", nil, 1}])

      assert Lightweight.select_cleanup_info(pid) == []
    end
  end

  # ── select_cleanup_info/3 ────────────────────────────────────────────────

  describe "select_cleanup_info/3" do
    test "Q1 = strictly-older-than-cutoff (ALL deleted); at-cutoff stays in Q2" do
      pid = start_repo!()
      seed!(pid, standard_rows())

      # max_tasks 0 → Q2 = every finished row with finished_at >= cutoff
      ids = Lightweight.select_cleanup_info(pid, @cutoff_iso, 0)

      assert MapSet.new(ids) ==
               MapSet.new([
                 "t-completed",
                 "t-failed",
                 "t-cancelled",
                 "t-completed-new"
               ])
    end

    test "cutoff boundary is exclusive for Q1 and inclusive for Q2" do
      pid = start_repo!()

      seed!(pid, [
        {"t-old", :completed, "/p/a", DateTime.add(@cutoff, -1, :millisecond), nil},
        {"t-at", :completed, "/p/a", @cutoff, nil},
        {"t-new", :completed, "/p/a", DateTime.add(@cutoff, 1, :millisecond), nil}
      ])

      # max_tasks 0 trims every non-age-expired row → q1 ++ [all of Q2]
      assert MapSet.new(Lightweight.select_cleanup_info(pid, @cutoff_iso, 0)) ==
               MapSet.new(["t-old", "t-at", "t-new"])

      # max_tasks large → only the strictly-older row is deleted
      assert Lightweight.select_cleanup_info(pid, @cutoff_iso, 100) == ["t-old"]
    end

    test "Q2 keeps the NEWEST max_tasks and trims the rest, newest-first" do
      pid = start_repo!()

      # 5 finished rows past the cutoff, at strictly increasing timestamps.
      for i <- 1..5 do
        seed!(pid, [
          {"t-#{i}", :completed, "/p/a", DateTime.add(@cutoff, i, :millisecond), nil}
        ])
      end

      # Keep the newest 2 → the 3 OLDEST past-cutoff rows are trimmed.
      # Q1 is empty, so the whole result is Q2 in its newest-first order.
      assert Lightweight.select_cleanup_info(pid, @cutoff_iso, 2) ==
               ["t-3", "t-2", "t-1"]
    end

    test "age-expired rows are deleted regardless of count (no count trim in Q1)" do
      pid = start_repo!()

      for i <- 1..4 do
        seed!(pid, [
          {"t-old-#{i}", :completed, "/p/a", DateTime.add(@cutoff, -i, :millisecond), nil}
        ])
      end

      # max_tasks 100 would keep every past-cutoff row — but Q1 ignores it.
      assert MapSet.new(Lightweight.select_cleanup_info(pid, @cutoff_iso, 100)) ==
               MapSet.new(["t-old-1", "t-old-2", "t-old-3", "t-old-4"])
    end

    test "never-finished rows are never returned" do
      pid = start_repo!()
      seed!(pid, standard_rows())

      ids = Lightweight.select_cleanup_info(pid, @cutoff_iso, 0)

      refute "t-pending" in ids
      refute "t-running" in ids
      refute "t-cancelling" in ids
      refute "t-finalizing" in ids
    end

    test "returns [] on an empty database" do
      pid = start_repo!()
      assert Lightweight.select_cleanup_info(pid, @cutoff_iso, 0) == []
    end
  end
end
