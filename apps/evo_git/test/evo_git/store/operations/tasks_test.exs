defmodule EvoGit.Store.Operations.TasksTest do
  @moduledoc """
  Tests for `EvoGit.Store.Operations.Tasks` — the R2a task write/core Ecto
  operations.

  Each test boots its own UNNAMED dynamic repo (`EvoGit.Store.Boot.start_dynamic/1`)
  on a unique tmp SQLite file, so `async: true` is safe. The boot is
  serialized through the BEAM-global `EvoGit.TestSupport.StoreBootLock`
  (`Ecto.Migrator` recompiles migrations on every pending run — concurrent
  compiles race). Raw-column assertions go through the read-only
  `TaskRowRaw` projection (exact stored bytes, no type casting).
  """

  use ExUnit.Case, async: true

  import Ecto.Query

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Operations.Tasks
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.TaskInfo
  alias EvoGit.TestSupport.StoreBootLock

  # ── Self-contained helpers (no shared files) ─────────────────────────────

  defp start_repo! do
    unique = System.unique_integer([:positive, :monotonic])

    path =
      Path.join(System.tmp_dir!(), "evogit_r2a_#{unique}_#{inspect(self())}.sqlite")

    {:ok, pid} = StoreBootLock.with_boot_lock(fn -> Boot.start_dynamic(path) end)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)
    pid
  end

  defp raw_row(repo, task_id) do
    RepoScope.with_repo(repo, fn ->
      Repo.one(from(t in TaskRowRaw, where: t.id == ^task_id))
    end)
  end

  # A rich-but-cheap TaskInfo exercising every column family.
  defp full_task(id) do
    %TaskInfo{
      id: id,
      type: :evolve,
      status: :completed,
      opts: [path: "/tmp/r2a-proj", mode: "simple", objective: "fix the bug"],
      started_at: ~U[2026-06-26 07:19:44.123456Z],
      finished_at: ~U[2026-06-26 08:00:00.999999Z],
      logs: ["line 1", "line 2"],
      result:
        {:ok,
         %{
           commit_sha: "abc123def",
           branch_name: "genesis/agent_beef",
           result: "Agent summary",
           pr_url: nil,
           pr_title: nil
         }},
      review_status: :merged,
      usage: %EvoGit.Agent.Usage{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_cost: 0.01,
        output_cost: 0.02,
        total_cost: 0.03,
        cached_tokens: 10,
        cache_creation_tokens: 5
      },
      agent_count: 5,
      base_sha: "base789",
      commit_sha: "head012",
      archive_metadata: [%{"agent_id" => "a1", "path" => "/archive/a1"}],
      lease_expires_at: 1_767_225_600,
      model_id: "deepseek-chat",
      branch_name: "genesis/agent_beef"
    }
  end

  defp put!(repo, %TaskInfo{} = task) do
    :ok = Tasks.put_task(repo, task)
  end

  # ── put/get round-trip ──────────────────────────────────────────────────

  describe "put_task/get_task round-trip" do
    test "all fields survive (DateTime µs-truncated, opts/result/logs/usage intact)" do
      repo = start_repo!()
      task = full_task("rt-1")

      put!(repo, task)
      fetched = Tasks.get_task(repo, "rt-1")

      assert %TaskInfo{} = fetched
      assert fetched.id == "rt-1"
      assert fetched.type == :evolve
      assert fetched.status == :completed
      assert fetched.review_status == :merged
      assert fetched.agent_count == 5
      assert fetched.base_sha == "base789"
      assert fetched.commit_sha == "head012"
      assert fetched.lease_expires_at == 1_767_225_600
      assert fetched.model_id == "deepseek-chat"
      assert fetched.project_path == "/tmp/r2a-proj"
      assert fetched.branch_name == "genesis/agent_beef"
      assert fetched.ref == nil

      # Datetimes are stored at fixed-ms precision (Codec wire format): the
      # microsecond part does NOT survive, the millisecond part does.
      assert fetched.started_at == ~U[2026-06-26 07:19:44.123Z]
      assert fetched.finished_at == ~U[2026-06-26 08:00:00.999Z]

      assert fetched.opts[:path] == "/tmp/r2a-proj"
      assert fetched.opts[:mode] == "simple"
      assert fetched.opts[:objective] == "fix the bug"

      assert fetched.logs == ["line 1", "line 2"]

      assert {:ok, data} = fetched.result
      assert data.commit_sha == "abc123def"
      assert data.branch_name == "genesis/agent_beef"
      assert data.pr_url == nil
      assert data.result == "Agent summary"

      assert %EvoGit.Agent.Usage{} = fetched.usage
      assert fetched.usage.input_tokens == 100
      assert fetched.usage.total_cost == 0.03
      assert fetched.usage.cache_creation_tokens == 5

      assert fetched.archive_metadata == [%{"agent_id" => "a1", "path" => "/archive/a1"}]
    end

    test "a bare-minimum TaskInfo round-trips with struct defaults intact" do
      repo = start_repo!()

      put!(repo, %TaskInfo{id: "rt-bare", type: :evolve, status: :pending})
      fetched = Tasks.get_task(repo, "rt-bare")

      assert fetched.status == :pending
      # logs default to [] on decode (never nil) — the LogsJson type contract.
      assert fetched.logs == []
      assert fetched.opts == nil
      assert fetched.result == nil
    end
  end

  # ── REPLACE semantics (the critical property) ───────────────────────────

  describe "put_task replace semantics" do
    test "re-putting the SAME id NULLs columns the new struct omits (INSERT OR REPLACE parity)" do
      repo = start_repo!()

      put!(repo, full_task("replace-1"))

      # Same id, everything the old row carried now nil/empty.
      :ok =
        Tasks.put_task(
          repo,
          %TaskInfo{id: "replace-1", type: :evolve, status: :running, opts: nil}
        )

      fetched = Tasks.get_task(repo, "replace-1")

      assert fetched.status == :running
      assert fetched.branch_name == nil
      assert fetched.project_path == nil
      assert fetched.result == nil
      assert fetched.logs == []
      assert fetched.finished_at == nil
      assert fetched.usage == nil
      assert fetched.archive_metadata == nil
      assert fetched.error == nil
      assert fetched.model_id == nil
      assert fetched.commit_sha == nil
      assert fetched.base_sha == nil
      assert fetched.agent_count == nil
      assert fetched.lease_expires_at == nil
      assert fetched.review_status == nil
    end

    test "two puts then get returns exactly the second task (no residue)" do
      repo = start_repo!()

      put!(repo, %TaskInfo{id: "same-id", status: :completed, model_id: "m1", type: :genesis})
      put!(repo, %TaskInfo{id: "same-id", status: :failed, model_id: nil, type: :evolve})

      fetched = Tasks.get_task(repo, "same-id")

      assert fetched.status == :failed
      assert fetched.model_id == nil
      assert fetched.type == :evolve
      # Exactly ONE row for the id — replace, not append.
      assert Tasks.count_tasks(repo) == 1
    end

    test "an explicit project_path/branch_name in the struct beats the denormalization" do
      repo = start_repo!()

      put!(
        repo,
        %TaskInfo{
          id: "explicit-cols",
          type: :evolve,
          status: :completed,
          opts: [path: "/from/opts"],
          project_path: "/explicit/path",
          result: {:ok, %{branch_name: "from/result"}},
          branch_name: "explicit-branch"
        }
      )

      fetched = Tasks.get_task(repo, "explicit-cols")
      assert fetched.project_path == "/explicit/path"
      assert fetched.branch_name == "explicit-branch"
    end
  end

  # ── Denormalizations (raw column assertions) ────────────────────────────

  describe "put_task denormalizations" do
    test "project_path is extracted from opts[:path] into the raw column" do
      repo = start_repo!()

      put!(
        repo,
        %TaskInfo{
          id: "denorm-path",
          type: :evolve,
          status: :running,
          opts: [path: "/tmp/denorm", mode: "simple"]
        }
      )

      assert raw_row(repo, "denorm-path").project_path == "/tmp/denorm"
    end

    test "branch_name is extracted from an {:ok, %{branch_name: _}} result" do
      repo = start_repo!()

      put!(
        repo,
        %TaskInfo{
          id: "denorm-branch",
          type: :evolve,
          status: :completed,
          result: {:ok, %{branch_name: "genesis/agent_cafe"}}
        }
      )

      assert raw_row(repo, "denorm-branch").branch_name == "genesis/agent_cafe"
    end

    test "a non-map result contributes no branch_name" do
      repo = start_repo!()

      put!(
        repo,
        %TaskInfo{id: "denorm-none", type: :evolve, status: :failed, result: {:error, "boom"}}
      )

      assert raw_row(repo, "denorm-none").branch_name == nil
    end

    test "updated_at is bumped on re-put and stored as a fixed-ms ISO string" do
      repo = start_repo!()

      put!(repo, %TaskInfo{id: "ts-1", type: :evolve, status: :running})
      first = raw_row(repo, "ts-1").updated_at

      assert is_binary(first)
      # Fixed-millisecond precision: exactly 3 fractional digits + "Z".
      assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/, first)
      assert {:ok, first_dt, _} = DateTime.from_iso8601(first)

      # A re-put bumps updated_at (sleep past 1ms so the stamps differ).
      Process.sleep(5)
      put!(repo, %TaskInfo{id: "ts-1", type: :evolve, status: :completed})
      second = raw_row(repo, "ts-1").updated_at

      assert {:ok, second_dt, _} = DateTime.from_iso8601(second)
      assert DateTime.compare(second_dt, first_dt) == :gt
    end
  end

  # ── get missing / validation shapes ─────────────────────────────────────

  describe "get_task/2 missing row" do
    test "returns nil for an unknown id (old handler shape)" do
      repo = start_repo!()
      assert Tasks.get_task(repo, "nope") == nil
    end
  end

  describe "put_task/2 validation errors" do
    test "returns {:error, :missing_task_id} without writing" do
      repo = start_repo!()

      assert Tasks.put_task(repo, %TaskInfo{id: nil, status: :running}) ==
               {:error, :missing_task_id}

      assert Tasks.count_tasks(repo) == 0
    end

    test "returns {:error, :missing_task_status} without writing" do
      repo = start_repo!()

      assert Tasks.put_task(repo, %TaskInfo{id: "s", status: nil}) ==
               {:error, :missing_task_status}

      assert Tasks.count_tasks(repo) == 0
    end
  end

  # ── deletes ─────────────────────────────────────────────────────────────

  describe "delete_task/2" do
    test "deletes an existing row and returns :ok" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "del-1", type: :evolve, status: :pending})

      assert Tasks.delete_task(repo, "del-1") == :ok
      assert Tasks.get_task(repo, "del-1") == nil
      assert Tasks.count_tasks(repo) == 0
    end

    test "returns :ok for a missing id (no-op delete)" do
      repo = start_repo!()
      assert Tasks.delete_task(repo, "missing") == :ok
      assert Tasks.count_tasks(repo) == 0
    end
  end

  describe "delete_tasks/2" do
    test "deletes multiple ids and returns :ok" do
      repo = start_repo!()

      for i <- 1..3, do: put!(repo, %TaskInfo{id: "multi-#{i}", type: :evolve, status: :pending})
      put!(repo, %TaskInfo{id: "keep", type: :evolve, status: :pending})

      assert Tasks.delete_tasks(repo, ["multi-1", "multi-2", "multi-3"]) == :ok
      assert Tasks.count_tasks(repo) == 1
      assert Tasks.get_task(repo, "keep") != nil
    end

    test "handles an empty id list (writes nothing)" do
      repo = start_repo!()
      put!(repo, %TaskInfo{id: "stay", type: :evolve, status: :pending})

      assert Tasks.delete_tasks(repo, []) == :ok
      assert Tasks.count_tasks(repo) == 1
    end

    test "501 ids are chunked (2 statements of 500+1) and all rows go" do
      repo = start_repo!()

      ids = Enum.map(1..501, &"chunk-#{&1}")
      # Minimal rows: id + status only — the leanest seed that still exercises
      # the full typed write path.
      Enum.each(ids, fn id ->
        :ok = Tasks.put_task(repo, %TaskInfo{id: id, type: :evolve, status: :pending})
      end)

      assert Tasks.count_tasks(repo) == 501

      assert Tasks.delete_tasks(repo, ids) == :ok
      assert Tasks.count_tasks(repo) == 0
    end
  end

  # ── select_all_tasks / count_tasks / clear_tasks ─────────────────────────

  describe "select_all_tasks/1" do
    test "returns every task as TaskInfo structs" do
      repo = start_repo!()
      put!(repo, full_task("all-1"))
      put!(repo, %TaskInfo{id: "all-2", type: :evolve, status: :pending})

      tasks = Tasks.select_all_tasks(repo)

      assert length(tasks) == 2
      assert Enum.all?(tasks, &is_struct(&1, TaskInfo))
      ids = tasks |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == ["all-1", "all-2"]

      by_id = Map.new(tasks, fn t -> {t.id, t} end)
      assert by_id["all-1"].branch_name == "genesis/agent_beef"
      assert by_id["all-2"].status == :pending
    end

    test "returns [] for an empty table" do
      repo = start_repo!()
      assert Tasks.select_all_tasks(repo) == []
    end
  end

  describe "count_tasks/1" do
    test "counts rows" do
      repo = start_repo!()
      assert Tasks.count_tasks(repo) == 0

      for i <- 1..4, do: put!(repo, %TaskInfo{id: "c-#{i}", type: :evolve, status: :pending})
      assert Tasks.count_tasks(repo) == 4
    end
  end

  describe "clear_tasks/1" do
    test "deletes every row and returns :ok" do
      repo = start_repo!()
      put!(repo, full_task("clear-1"))
      put!(repo, %TaskInfo{id: "clear-2", type: :evolve, status: :pending})

      assert Tasks.clear_tasks(repo) == :ok
      assert Tasks.count_tasks(repo) == 0
      assert Tasks.select_all_tasks(repo) == []
    end
  end
end
