defmodule EvoGit.TaskRegistry.ArchivePersistenceTest do
  @moduledoc """
  `EvoGit.TaskRegistry`'s per-agent archive API — the STREAMING write path
  (`put_task_archive/1`) plus the two reads (`list_task_archives/2`,
  `get_agent_archive/2`) that replaced the old single `tasks.archive_metadata`
  column and the `archive_records` list inside `result`.

  Coverage:

    * round trip through the registry (STRING-keyed entries out, the
      `include_results` contract, `total`, paging);
    * idempotent re-put on `(task_id, agent_id)` (a crash-retry completing twice
      replaces the row, never duplicates it);
    * BEST-EFFORT writes: a dead store and a dead registry both yield
      `{:error, reason}` — an agent's completion must never die because its
      archive could not be stored;
    * entries that cannot identify their row (missing task/agent id);
    * END TO END: an agent completion carrying an archive record leaves exactly
      ONE row in `task_agent_archives` with all 22 producer fields, while the
      persisted task row's `result` carries no archive keys.

  Each test runs against its OWN isolated store + registry
  (`EvoGit.TaskRegistryCase`), so nothing global is touched.
  """

  use EvoGit.TaskRegistryCase, async: true

  import ExUnit.CaptureLog

  alias EvoGit.TaskInfo

  @empty_page %{entries: [], total: 0}

  describe "put_task_archive/1 ↔ list_task_archives/2 ↔ get_agent_archive/2" do
    test "round-trips an atom-keyed entry out as a STRING-keyed map" do
      task_id = unique_task_id()

      entry = %{
        task_id: task_id,
        agent_id: 11,
        depth: 0,
        agent_type: "manager",
        context_node_path: "./",
        objective: "build it",
        result: "done",
        base_commit: "base1",
        final_commit: "final1",
        branch_name: "evogit-agent-T1-A1",
        archive_ref_start: "refs/genesis/archive/T1-A1-start",
        archive_ref_final: "refs/genesis/archive/T1-A1-final",
        repo_id: "primary",
        repo_root: "/repo",
        repo_path: "/repo/worktree",
        usage: %{total_tokens: 42},
        llm_settings: %{model: "test:model"},
        agent_settings: %{max_turns: 10},
        foreign_repos: [%{id: "ext", root: "/ext", description: nil}],
        compression_count: 2,
        started_at: "2026-03-01T00:00:00Z",
        completed_at: "2026-03-01T00:05:00Z"
      }

      assert :ok = TaskRegistry.put_task_archive(entry)

      assert %{entries: [stored], total: 1} =
               TaskRegistry.list_task_archives(task_id, include_results: true)

      assert Enum.all?(Map.keys(stored), &is_binary/1)
      assert stored["task_id"] == task_id
      assert stored["agent_id"] == 11
      assert stored["agent_type"] == "manager"
      assert stored["context_node_path"] == "./"
      assert stored["objective"] == "build it"
      assert stored["result"] == "done"
      assert stored["base_commit"] == "base1"
      assert stored["final_commit"] == "final1"
      assert stored["branch_name"] == "evogit-agent-T1-A1"
      assert stored["archive_ref_start"] == "refs/genesis/archive/T1-A1-start"
      assert stored["archive_ref_final"] == "refs/genesis/archive/T1-A1-final"
      assert stored["repo_id"] == "primary"
      assert stored["repo_root"] == "/repo"
      assert stored["repo_path"] == "/repo/worktree"
      assert stored["compression_count"] == 2
      assert stored["started_at"] == "2026-03-01T00:00:00Z"
      assert stored["completed_at"] == "2026-03-01T00:05:00Z"

      # JSON columns come back as plain decoded maps/lists (string-keyed).
      assert stored["usage"] == %{"total_tokens" => 42}
      assert stored["llm_settings"] == %{"model" => "test:model"}
      assert stored["agent_settings"] == %{"max_turns" => 10}
      assert [repo] = stored["foreign_repos"]
      assert repo == %{"id" => "ext", "root" => "/ext", "description" => nil}

      # The lazy detail read returns the SAME entry, `result` included.
      assert TaskRegistry.get_agent_archive(task_id, 11) == stored
    end

    test "re-putting the same (task_id, agent_id) REPLACES the row (idempotent)" do
      task_id = unique_task_id()

      assert :ok =
               TaskRegistry.put_task_archive(%{
                 task_id: task_id,
                 agent_id: 1,
                 depth: 0,
                 result: "first"
               })

      assert :ok =
               TaskRegistry.put_task_archive(%{
                 task_id: task_id,
                 agent_id: 1,
                 depth: 0,
                 result: "second"
               })

      assert %{entries: [stored], total: 1} =
               TaskRegistry.list_task_archives(task_id, include_results: true)

      assert stored["result"] == "second"
    end

    test "pages the roster without results and counts the whole archive" do
      task_id = unique_task_id()

      for {agent_id, depth, result} <- [{1, 0, "root"}, {2, 1, "child"}, {3, 2, "grandchild"}] do
        assert :ok =
                 TaskRegistry.put_task_archive(%{
                   task_id: task_id,
                   agent_id: agent_id,
                   depth: depth,
                   result: result
                 })
      end

      # Roster order is `depth ASC, agent_id ASC`; `total` counts every row.
      assert %{entries: roster, total: 3} = TaskRegistry.list_task_archives(task_id)
      assert Enum.map(roster, & &1["agent_id"]) == [1, 2, 3]
      refute Enum.any?(roster, &Map.has_key?(&1, "result"))

      assert %{entries: [second], total: 3} =
               TaskRegistry.list_task_archives(task_id, limit: 1, offset: 1)

      assert second["agent_id"] == 2

      assert %{entries: [with_result], total: 3} =
               TaskRegistry.list_task_archives(task_id,
                 limit: 1,
                 offset: 2,
                 include_results: true
               )

      assert with_result["result"] == "grandchild"
    end

    test "an unknown task yields the empty page and a nil detail" do
      assert TaskRegistry.list_task_archives("no-such-task") == @empty_page
      assert TaskRegistry.list_task_archives("no-such-task", include_results: true) == @empty_page
      assert TaskRegistry.get_agent_archive("no-such-task", 1) == nil
    end

    test "returns {:error, _} for an entry that cannot identify its row" do
      assert {:error, :missing_task_id} = TaskRegistry.put_task_archive(%{agent_id: 1})

      assert {:error, :missing_agent_id} =
               TaskRegistry.put_task_archive(%{task_id: "t", agent_id: "not-an-integer"})
    end
  end

  describe "best-effort write — an agent completion never dies because of the archive" do
    test "a dead store degrades to {:error, :store_unavailable} and the registry stays alive",
         %{store: store, registry: registry} do
      task_id = unique_task_id()

      assert :ok =
               TaskRegistry.put_task_archive(%{task_id: task_id, agent_id: 1, result: "first"})

      stop_store!(store)

      log =
        capture_log(fn ->
          assert {:error, :store_unavailable} =
                   TaskRegistry.put_task_archive(%{
                     task_id: task_id,
                     agent_id: 2,
                     result: "after the store died"
                   })

          # The reads degrade too, in their own documented shapes.
          assert TaskRegistry.list_task_archives(task_id) == @empty_page
          assert TaskRegistry.get_agent_archive(task_id, 1) == nil
        end)

      assert log =~ "TaskRegistry: store operation put_task_archive FAILED"
      assert Process.alive?(Process.whereis(registry))
    end

    test "a dead registry loses nothing — the write runs in the CALLER, not the registry",
         %{store: store, registry: registry} do
      task_id = unique_task_id()
      assert :ok = stop_supervised(registry)
      assert Process.whereis(registry) == nil

      # The archive row is written by the completing agent itself and needs only
      # the store (the registry name just resolves which store), so a dead
      # registry cannot lose a finishing agent's archive.
      assert :ok = TaskRegistry.put_task_archive(%{task_id: task_id, agent_id: 1, result: "x"})

      assert %{entries: [row], total: 1} =
               EvoGit.Store.list_task_archives(store, task_id, include_results: true)

      assert row["result"] == "x"
    end
  end

  describe "the archive write never blocks the registry" do
    test "an in-flight archive write leaves the registry answering reads",
         %{data_dir: data_dir} do
      unique = System.unique_integer([:positive])
      store_name = :"archive_slow_store_#{unique}"
      registry_name = :"archive_slow_registry_#{unique}"
      parent = self()

      start_supervised!(
        Supervisor.child_spec(
          {EvoGit.TaskRegistry.ArchivePersistenceTest.SlowArchiveStore,
           name: store_name, delay_ms: 2_000, notify: parent},
          id: store_name
        )
      )

      # A registry pointed at the SLOW store: only `put_task_archive` is slow,
      # every other call answers the empty projection.
      start_supervised!(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store_name, data_dir: data_dir, name: registry_name},
          id: registry_name
        )
      )

      writer =
        Task.async(fn ->
          Process.put(:evogit_task_registry_server, registry_name)
          TaskRegistry.put_task_archive(%{task_id: "slow", agent_id: 1})
        end)

      assert_receive {:archive_write_started, ^store_name}, 1_000

      # The registry answers WHILE the multi-second insert is still in flight:
      # the write runs in the completing agent's process (here `writer`), so
      # nothing queues behind it in the registry mailbox.
      probe =
        Task.async(fn ->
          Process.put(:evogit_task_registry_server, registry_name)
          TaskRegistry.list_task_ids([])
        end)

      assert {:ok, []} = Task.yield(probe, 500)
      assert Task.yield(writer, 0) == nil
      assert Task.await(writer, 5_000) == :ok
    end
  end

  describe "end to end — an agent completion persists its archive record" do
    test "exactly ONE archive row with all 22 fields; the task result carries no archive keys",
         %{store: store} do
      task_id = unique_task_id()

      # The task row the completion belongs to (persisted before the run).
      assert :ok =
               EvoGit.Store.put_task(store, %TaskInfo{
                 id: task_id,
                 type: :evolve,
                 status: :running,
                 opts: [path: "/tmp/archive_e2e"],
                 ref: nil,
                 started_at: DateTime.utc_now(),
                 logs: [],
                 result: nil
               })

      # The agent's completion record — exactly the 22 fields `CompleteTask`
      # builds (minus the task id, which this write adds).
      completion = %{
        task_id: task_id,
        agent_id: 4242,
        parent_id: nil,
        depth: 0,
        agent_type: "manager",
        context_node_path: "./",
        objective: "Evolve the project",
        result: "All done",
        base_commit: "base_sha",
        final_commit: "final_sha",
        branch_name: "evogit-agent-T1-A1",
        archive_ref_start: "refs/genesis/archive/T1-A1-start",
        archive_ref_final: "refs/genesis/archive/T1-A1-final",
        repo_id: "primary",
        repo_root: "/tmp/archive_e2e",
        repo_path: "/tmp/archive_e2e/.genesis/workers/worker_T1_A1",
        usage: %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15},
        llm_settings: %{"model" => "test:model", "model_id" => "fast"},
        agent_settings: %{"max_turns" => 40, "max_retries" => 15, "max_agent_depth" => 8},
        foreign_repos: [],
        compression_count: 0,
        started_at: "2026-03-01T00:00:00Z",
        completed_at: "2026-03-01T00:10:00Z"
      }

      assert :ok = TaskRegistry.put_task_archive(completion)

      # The wrapper's terminal result — the post-refactor shape: NO
      # `archive_records` key (the archive lives in its own table now).
      TaskRegistry.update_task_status(
        task_id,
        :completed,
        {:ok,
         %{
           commit_sha: "final_sha",
           result: "All done",
           branch_name: "evogit-agent-T1-A1"
         }}
      )

      # Sync the cast.
      TaskRegistry.list_tasks()

      # EXACTLY one archive row, carrying the table's full column set.
      expected_keys = EvoGit.Store.Schemas.TaskAgentArchiveRow.columns()
      assert length(expected_keys) == 23

      assert %{entries: [row], total: 1} =
               TaskRegistry.list_task_archives(task_id, include_results: true)

      assert Enum.sort(Map.keys(row)) == Enum.sort(expected_keys)

      for {field, value} <- Map.delete(completion, :task_id) do
        assert row[Atom.to_string(field)] == value,
               "archive field #{field} did not round-trip: #{inspect(row[Atom.to_string(field)])}"
      end

      assert row["task_id"] == task_id

      # The persisted task row's result carries NO archive keys.
      fetched = TaskRegistry.get_task(task_id)
      assert %TaskInfo{status: :completed} = fetched
      assert {:ok, stored_data} = fetched.result

      for archive_key <- [:archive_records, "archive_records"] do
        refute Map.has_key?(stored_data, archive_key)
      end

      assert stored_data[:commit_sha] == "final_sha"
      assert stored_data[:result] == "All done"

      # The task row itself has no archive column at all.
      refute Map.has_key?(fetched, :archive_metadata)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_task_id, do: "archive_#{System.unique_integer([:positive])}"

  # Stops the isolated store AND removes its child spec, so its registered name
  # resolves to no process and every later `GenServer.call/3` exits `:noproc`
  # (the production crash chain's dead-server exit).
  defp stop_store!(store) do
    store_pid = Process.whereis(store)
    assert is_pid(store_pid)
    assert :ok = stop_supervised(store)
    refute Process.alive?(store_pid)
    assert Process.whereis(store) == nil
  end
end

defmodule EvoGit.TaskRegistry.ArchivePersistenceTest.SlowArchiveStore do
  @moduledoc """
  A store stand-in whose ONLY slow call is the archive write, used to prove the
  archive producer write does not hold the registry.

  The registry boot reads (`select_running_lease_info`) and the tiny read
  projections answer an empty list; `put_task_archive` notifies the test that it
  is in flight, then sleeps for `:delay_ms` before replying `:ok`.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call({:put_task_archive, _entry}, from, state) do
    send(state.notify, {:archive_write_started, state.name})

    # Reply LATER — the same shape as the real store's write offload (which
    # answers its caller only after the commit) — so this stand-in keeps
    # answering every OTHER call while the archive write is in flight.
    Task.start(fn ->
      Process.sleep(state.delay_ms)
      GenServer.reply(from, :ok)
    end)

    {:noreply, state}
  end

  def handle_call(_request, _from, state), do: {:reply, [], state}
end
