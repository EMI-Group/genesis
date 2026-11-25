defmodule EvoGit.TaskRegistry.PauseTest do
  @moduledoc """
  TASK-LEVEL PAUSE & RESUME in `EvoGit.TaskRegistry` (`docs/task-pause.md`):
  `pause_task/1`, the wrapper's `{:paused, info}` result, the straggler guard,
  `resume_task/1` (in-place re-enqueue + `resume_kind`), the restart mapping
  (`init/1` → dirty pause), the RPC mirrors and the paused-row invariants.

  Runs `async: true`: every test gets its OWN isolated `EvoGit.Store` +
  `EvoGit.TaskRegistry` from `EvoGit.TaskRegistryCase`, so no registry state is
  shared. Three APP-GLOBAL resources are touched, always with per-test-unique
  ids so a concurrent module can never observe them:

    * the app-booted `EvoGit.AgentState.Server` — the store `Pause.resume/4`
      resolves inside the REGISTRY process (a process-dictionary seam set in the
      test process would not reach it), seeded with unique task ids and removed
      in `on_exit` (the same pattern as `agent_state_cascade_test.exs`);
    * the global `EvoGit.AgentScheduler` task-pause marker
      (`:evogit_task_pause`) and the cancel marker, driven through
      `begin_task_pause/1`/`clear_task_pause/1` with unique task ids and cleared
      in `on_exit`;
    * the process-global `"tasks"` PubSub topic — every broadcast assertion is
      pinned to this test's task id, and every "no broadcast" assertion is a
      zero-wait `refute_receive ..., 0` scoped to the row under test and issued
      after (or spanning) the synchronous `GenServer.call`s to the same
      registry; a wildcard id would observe a concurrent module's broadcast and
      is never used (see `apps/evo_git/test/CONTEXT.md`).

  No `Process.sleep/1` is used: broadcasts are awaited with `assert_receive`
  and "nothing happened" is proven by the FIFO/zero-wait idiom.
  """

  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.Agent.Result
  alias EvoGit.AgentScheduler.ControlPlane
  alias EvoGit.AgentState
  alias EvoGit.AgentState.Snapshot
  alias EvoGit.TaskRegistry.Pause
  alias EvoGit.TaskRegistry.RuntimeOpts

  ## Setup helpers

  # Subscribe to the (process-global) task topic and drop anything already
  # queued, so each test starts from an empty window for ITS id.
  defp subscribe_tasks! do
    Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
    drain_tasks_mailbox()
  end

  defp drain_tasks_mailbox do
    receive do
      _msg -> drain_tasks_mailbox()
    after
      0 -> :ok
    end
  end

  # Seeds one row straight into the isolated store. `extra` overrides any
  # field; `lease` defaults to a live lease (a pause request starts from a
  # running task, which always has one).
  defp seed_task!(task_id, status, extra \\ []) do
    task = %TaskInfo{
      id: task_id,
      type: :genesis,
      status: status,
      opts: Keyword.get(extra, :opts, path: "/tmp/test"),
      ref: nil,
      started_at: Keyword.get(extra, :started_at, DateTime.utc_now()),
      finished_at: Keyword.get(extra, :finished_at),
      logs: [],
      result: Keyword.get(extra, :result),
      usage: Keyword.get(extra, :usage),
      review_status: Keyword.get(extra, :review_status),
      base_sha: Keyword.get(extra, :base_sha),
      commit_sha: Keyword.get(extra, :commit_sha),
      branch_name: Keyword.get(extra, :branch_name),
      session_mode: Keyword.get(extra, :session_mode, "oneshot"),
      pause_kind: Keyword.get(extra, :pause_kind),
      lease_expires_at: Keyword.get(extra, :lease_expires_at, System.system_time(:second) + 300)
    }

    :ok = EvoGit.Store.put_task(store(), task)
    task
  end

  defp reload(task_id), do: EvoGit.Store.get_task(store(), task_id)

  # Writes one durable run for the task through the app-booted default
  # agent-state server (the one the REGISTRY resolves), flushes, and schedules
  # its removal. `parent_id` is left absent, so the row IS a ROOT run — the
  # durable ROOT row `EvoGit.TaskRegistry.Pause` gates resume admission and
  # restart classification on. `fields` adds the run facts a resume carries
  # (`:current_commit`, `:branch`, `:anchor_ref`, `:pause_commit`, …).
  defp seed_durable_run!(task_id, agent_id \\ 1, fields \\ %{}) do
    on_exit(fn -> AgentState.delete_task(task_id) end)

    :ok =
      AgentState.checkpoint(task_id, agent_id, %{
        kind: :rewrite,
        messages: [
          %ReqLLM.Message{
            role: :user,
            content: [ReqLLM.Message.ContentPart.text("paused run #{task_id}")]
          }
        ],
        fields: Map.put(fields, :phase, "paused")
      })

    :ok = AgentState.flush()
    assert {:ok, _record} = AgentState.load(task_id, agent_id)
    :ok
  end

  # Writes one CHILD durable run (a `parent_id` no row holds by default,
  # `depth: 1`), so a task's roster can be made child-only (nothing a resume
  # could restore) or a real two-level tree. `fields` adds/overrides run facts —
  # a still-running child keeps `status: "running"` and its own `pause_commit`.
  defp seed_child_run!(task_id, agent_id \\ 2, parent_id \\ 99, fields \\ %{}) do
    on_exit(fn -> AgentState.delete_task(task_id) end)

    run_fields = Map.merge(%{parent_id: parent_id, depth: 1, phase: "paused"}, fields)

    :ok =
      AgentState.checkpoint(task_id, agent_id, %{
        kind: :rewrite,
        messages: [
          %ReqLLM.Message{
            role: :user,
            content: [ReqLLM.Message.ContentPart.text("child run #{task_id}")]
          }
        ],
        fields: run_fields
      })

    :ok = AgentState.flush()
    assert {:ok, _record} = AgentState.load(task_id, agent_id)
    :ok
  end

  # Registers a fake wrapper ref in the registry's in-memory `task_refs` for
  # `task_id` and returns the ref, so a test can deliver the wrapper's
  # `{ref, result}` / `:DOWN` message exactly like `Task.Supervisor.async_nolink/4`
  # does. The pid stays alive (`Process.sleep(:infinity)`) so the registry never
  # sees a phantom death; it is killed in `on_exit`.
  defp put_fake_wrapper!(task_id) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    ref = make_ref()

    :sys.replace_state(TaskRegistry.server(), fn state ->
      %{
        state
        | task_refs:
            Map.put(state.task_refs, task_id, %Task{
              pid: pid,
              ref: ref,
              owner: self(),
              mfa:
                {EvoGit.TaskRegistry.TaskExecutor, :execute_task,
                 [:genesis, [path: "/tmp"], task_id]}
            })
      }
    end)

    ref
  end

  # A pending wrapper result: delivered as a plain message (the registry's
  # `handle_info({ref, result}, state)` arm), then synchronized through a
  # synchronous call so the handler has fully run before assertions.
  defp deliver_wrapper_result(ref, result) do
    send(TaskRegistry.server(), {ref, result})
    sync_registry()
  end

  defp deliver_wrapper_down(ref, pid, reason) do
    send(TaskRegistry.server(), {:DOWN, ref, :process, pid, reason})
    sync_registry()
  end

  # TWO synchronous barriers: the first lands the delivered message's handler,
  # and a handler that re-enqueues work on ITSELF (e.g. the `:cancelling` arm
  # casting `:cancelled`) only finishes after the second one.
  defp sync_registry do
    _ = TaskRegistry.list_tasks()
    _ = TaskRegistry.list_tasks()
    :ok
  end

  # The persisted `updated_at` of one row, straight from the store's raw
  # projection. Used to prove an idempotent call wrote NOTHING (the timestamp
  # is pinned to a fixed past value through `set_updated_at/3` first, so any
  # write — even within the same millisecond — would move it).
  defp updated_at(task_id, sqlite_path) do
    set_updated_at(sqlite_path, task_id, "2024-01-01T00:00:00.000Z")

    store()
    |> EvoGit.Store.select_task_ids([])
    |> Enum.find(&(&1.id == task_id))
    |> Map.fetch!(:updated_at)
  end

  # Overwrites the store-internal updated_at column with a fixed-precision ISO
  # string through a raw connection (the codec never sees this write).
  defp set_updated_at(sqlite_path, task_id, iso) do
    {:ok, raw_conn} = Xqlite.open(sqlite_path)

    {:ok, _} =
      XqliteNIF.execute(raw_conn, "UPDATE tasks SET updated_at = ?1 WHERE id = ?2", [
        iso,
        task_id
      ])

    XqliteNIF.close(raw_conn)
  end

  defp clear_pause_marker!(task_id) do
    on_exit(fn -> EvoGit.AgentScheduler.clear_task_pause(task_id) end)
    :ok
  end

  ## pause_task/1 — accepted + idempotent

  describe "pause_task/1 — the :running transition" do
    test "writes :pausing, broadcasts exactly once and flags the task in the scheduler",
         %{store: _store} do
      unique = System.unique_integer([:positive])
      task_id = "pause_running_#{unique}"
      lease = System.system_time(:second) + 300
      seed_task!(task_id, :running, result: "previous report", lease_expires_at: lease)
      clear_pause_marker!(task_id)
      subscribe_tasks!()

      assert :ok = TaskRegistry.pause_task(task_id)

      # Persist BEFORE broadcast: the row is already :pausing when the call
      # returns, and the transition is NOT a completion (no finished_at, the
      # live lease is untouched, the preserved report is untouched).
      fetched = reload(task_id)
      assert fetched.status == :pausing
      assert fetched.finished_at == nil
      assert fetched.lease_expires_at == lease
      assert fetched.pause_kind == nil
      assert fetched.result == "previous report"

      # Exactly ONE `:pausing` broadcast, and nothing else for this task.
      assert_receive {:task_updated, ^task_id, :pausing, _node}, 1_000
      refute_receive {:task_updated, ^task_id, _, _}, 0

      # The scheduler half: the task is marked as draining, which is what makes
      # an agent registered from now on start with `pause_requested = true`.
      assert ControlPlane.task_pausing?(task_id)
    end
  end

  describe "pause_task/1 — idempotency" do
    test "an already :pausing task answers :ok with NO write and NO broadcast",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      task_id = "pause_idem_pausing_#{unique}"
      seed_task!(task_id, :pausing)
      subscribe_tasks!()
      # Pin updated_at to a fixed PAST value first: any write (even one inside
      # the same millisecond) would move it, so this is real "no write" evidence.
      before = updated_at(task_id, sqlite_path)

      assert :ok = TaskRegistry.pause_task(task_id)

      assert reload(task_id).status == :pausing
      assert selected_updated_at(task_id) == before
      refute_receive {:task_updated, ^task_id, _, _}, 0
    end

    test "an already :paused task answers :ok with NO write and NO broadcast",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      task_id = "pause_idem_paused_#{unique}"
      seed_task!(task_id, :paused, pause_kind: :clean, finished_at: nil, lease_expires_at: nil)
      subscribe_tasks!()
      before = updated_at(task_id, sqlite_path)

      assert :ok = TaskRegistry.pause_task(task_id)

      fetched = reload(task_id)
      assert fetched.status == :paused
      assert fetched.pause_kind == :clean
      assert selected_updated_at(task_id) == before
      refute_receive {:task_updated, ^task_id, _, _}, 0
    end
  end

  ## pause_task/1 — refusals

  describe "pause_task/1 — refusals" do
    test ":awaiting_input is refused — an idle interactive session has no resumable run" do
      unique = System.unique_integer([:positive])
      task_id = "pause_awaiting_#{unique}"
      seed_task!(task_id, :awaiting_input, opts: [path: "/tmp/test", session_mode: "interactive"])
      subscribe_tasks!()

      assert {:error, :not_pausable} = TaskRegistry.pause_task(task_id)

      assert reload(task_id).status == :awaiting_input
      refute_receive {:task_updated, ^task_id, _, _}, 0
      refute ControlPlane.task_pausing?(task_id)
    end

    test "a :running interactive-session task is refused too (:not_pausable)" do
      # Regression pin: `:session_mode` is a STRING-keyed persisted opt
      # (`EvoGit.Store.Codec`), so the classifier must recognize the DECODED
      # spelling `{"session_mode", "interactive"}` — an atom-key-only lookup
      # silently admitted a pause for an interactive run.
      unique = System.unique_integer([:positive])
      task_id = "pause_interactive_running_#{unique}"
      seed_task!(task_id, :running, opts: [path: "/tmp/test", session_mode: "interactive"])
      subscribe_tasks!()

      # The row really does carry the string-keyed spelling after the round-trip.
      assert {"session_mode", "interactive"} in reload(task_id).opts

      assert {:error, :not_pausable} = TaskRegistry.pause_task(task_id)

      assert reload(task_id).status == :running
      refute_receive {:task_updated, ^task_id, _, _}, 0
      refute ControlPlane.task_pausing?(task_id)
    end

    test ":persistent_state false (or a non-boolean) is refused — nothing durable to restore" do
      unique = System.unique_integer([:positive])
      off_id = "pause_no_persist_#{unique}"
      junk_id = "pause_junk_persist_#{unique}"
      seed_task!(off_id, :running, opts: [path: "/tmp/test", persistent_state: false])
      seed_task!(junk_id, :running, opts: [path: "/tmp/test", persistent_state: "yes"])
      subscribe_tasks!()

      assert {:error, :not_resumable} = TaskRegistry.pause_task(off_id)
      assert {:error, :not_resumable} = TaskRegistry.pause_task(junk_id)

      assert reload(off_id).status == :running
      assert reload(junk_id).status == :running
      refute_receive {:task_updated, ^off_id, _, _}, 0
      refute_receive {:task_updated, ^junk_id, _, _}, 0
    end

    test "every other status is {:error, :not_running} and the row is left untouched",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])

      statuses = [:pending, :finalizing, :cancelling, :completed, :failed, :cancelled]

      # Subscribe FIRST: the property is "THIS row's refusal broadcast nothing",
      # so the window must be open across the calls. Scoped per id — another
      # concurrent module's `{:task_updated, other_id, …}` can never be evidence
      # for or against this row's refusal.
      subscribe_tasks!()

      ids =
        for status <- statuses do
          task_id = "pause_refuse_#{status}_#{unique}"
          seed_task!(task_id, status)
          before = updated_at(task_id, sqlite_path)

          assert {:error, :not_running} = TaskRegistry.pause_task(task_id),
                 "expected :not_running for #{inspect(status)}"

          assert reload(task_id).status == status
          assert selected_updated_at(task_id) == before
          task_id
        end

      for id <- ids, do: refute_receive({:task_updated, ^id, _, _}, 0)
    end

    test "an unknown task answers {:error, :not_found}" do
      subscribe_tasks!()

      missing = "pause_missing_#{System.unique_integer([:positive])}"

      assert {:error, :not_found} = TaskRegistry.pause_task(missing)

      refute_receive {:task_updated, ^missing, _, _}, 0
    end
  end

  ## The wrapper's {:paused, info} result

  describe "wrapper {:paused, info} result" do
    test "parks a :running task :paused with pause_kind :clean, no finished_at/lease, facts preserved" do
      unique = System.unique_integer([:positive])
      task_id = "paused_result_running_#{unique}"
      started_at = DateTime.utc_now()
      usage = %EvoGit.Agent.Usage{total_tokens: 42, input_tokens: 30, output_tokens: 12}

      seed_task!(task_id, :running,
        started_at: started_at,
        result: "paused run report",
        usage: usage,
        commit_sha: "abc123",
        base_sha: "base123",
        branch_name: "genesis/agent_abc",
        review_status: :pending
      )

      clear_pause_marker!(task_id)
      subscribe_tasks!()
      ref = put_fake_wrapper!(task_id)

      deliver_wrapper_result(
        ref,
        {:paused, %{agent_id: 1, task_id: task_id, reason: :task_pause}}
      )

      fetched = reload(task_id)
      # The paused resting state: NOT finished, NOT cancelled, NOT failed.
      assert fetched.status == :paused
      assert fetched.pause_kind == :clean
      assert fetched.finished_at == nil
      assert fetched.lease_expires_at == nil
      # A TARGETED write: the paused run's report/usage/identity survive so a
      # resume ACCUMULATES usage and keeps the same report.
      assert fetched.result == "paused run report"
      assert %EvoGit.Agent.Usage{total_tokens: 42} = fetched.usage
      assert fetched.commit_sha == "abc123"
      assert fetched.base_sha == "base123"
      assert fetched.branch_name == "genesis/agent_abc"
      assert fetched.review_status == :pending
      assert DateTime.to_unix(fetched.started_at) == DateTime.to_unix(started_at)

      # Exactly ONE `:paused` broadcast, after the write; never a terminal one.
      assert_receive {:task_updated, ^task_id, :paused, _node}, 1_000
      refute_receive {:task_updated, ^task_id, _, _}, 0

      # The wrapper is done: its ref is dropped and the scheduler pause marker
      # is cleared (the drain is over).
      refute Map.has_key?(:sys.get_state(TaskRegistry.server()).task_refs, task_id)
      refute ControlPlane.task_pausing?(task_id)
    end

    test "also parks a still-draining :pausing task as :paused/:clean" do
      unique = System.unique_integer([:positive])
      task_id = "paused_result_pausing_#{unique}"
      seed_task!(task_id, :pausing)
      subscribe_tasks!()
      ref = put_fake_wrapper!(task_id)

      deliver_wrapper_result(ref, {:paused, %{agent_id: 2, task_id: task_id}})

      fetched = reload(task_id)
      assert fetched.status == :paused
      assert fetched.pause_kind == :clean
      assert fetched.finished_at == nil
      assert fetched.lease_expires_at == nil
      assert_receive {:task_updated, ^task_id, :paused, _node}, 1_000
      refute_receive {:task_updated, ^task_id, _, _}, 0
    end

    test "derives pause_kind from the pause REPORT — only a provable clean snapshot stays :clean" do
      # A report that cannot prove a clean snapshot must never claim one, or the
      # resume would skip the crash repair it needs. The four shapes below are
      # the whole rule: an explicit `:dirty`, a non-durable flush, an
      # interrupted (non-subagent) freeze point, and the honest clean case.
      unique = System.unique_integer([:positive])

      cases = [
        {"clean", %{agent_id: 1, pause_kind: :clean, durable: true, clean_freeze: true}, :clean},
        {"dirty_kind", %{agent_id: 1, pause_kind: :dirty, durable: true, clean_freeze: true},
         :dirty},
        {"not_durable", %{agent_id: 1, pause_kind: :clean, durable: false, clean_freeze: true},
         :dirty},
        {"not_clean_freeze",
         %{agent_id: 1, pause_kind: :clean, durable: true, clean_freeze: false}, :dirty}
      ]

      subscribe_tasks!()

      for {label, report, expected} <- cases do
        task_id = "paused_kind_#{label}_#{unique}"

        seed_task!(task_id, :running,
          result: "pause report #{label}",
          usage: %EvoGit.Agent.Usage{total_tokens: 11},
          commit_sha: "sha_#{label}"
        )

        clear_pause_marker!(task_id)
        ref = put_fake_wrapper!(task_id)

        deliver_wrapper_result(
          ref,
          {:paused, Map.merge(%{task_id: task_id, reason: :task_pause}, report)}
        )

        fetched = reload(task_id)
        assert fetched.status == :paused, "expected :paused for #{label}"
        assert fetched.pause_kind == expected, "expected #{inspect(expected)} for #{label}"
        # Still the PAUSED resting state: not finished, no lease, and every
        # paused-run fact preserved for the resume.
        assert fetched.finished_at == nil
        assert fetched.lease_expires_at == nil
        assert fetched.result == "pause report #{label}"
        assert %EvoGit.Agent.Usage{total_tokens: 11} = fetched.usage
        assert fetched.commit_sha == "sha_#{label}"

        assert_receive {:task_updated, ^task_id, :paused, _node}, 1_000
        refute_receive {:task_updated, ^task_id, _, _}, 0
        refute Map.has_key?(:sys.get_state(TaskRegistry.server()).task_refs, task_id)
      end
    end

    test "a pause report that loses to a :cancelling row resolves it :cancelled" do
      unique = System.unique_integer([:positive])
      task_id = "paused_result_cancelling_#{unique}"
      seed_task!(task_id, :cancelling, lease_expires_at: System.system_time(:second) + 300)
      subscribe_tasks!()
      ref = put_fake_wrapper!(task_id)

      deliver_wrapper_result(ref, {:paused, %{agent_id: 3, task_id: task_id}})

      # The cancel wins: the row is never parked `:paused`.
      fetched = reload(task_id)
      assert fetched.status == :cancelled
      assert fetched.finished_at != nil
      refute_receive {:task_updated, ^task_id, :paused, _node}, 0
    end

    test "a duplicate pause report for an already :paused row writes and broadcasts nothing",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      task_id = "paused_result_dup_#{unique}"
      seed_task!(task_id, :paused, pause_kind: :clean, lease_expires_at: nil)
      subscribe_tasks!()
      before = updated_at(task_id, sqlite_path)
      ref = put_fake_wrapper!(task_id)

      deliver_wrapper_result(ref, {:paused, %{agent_id: 4, task_id: task_id}})

      assert reload(task_id).status == :paused
      assert selected_updated_at(task_id) == before
      refute_receive {:task_updated, ^task_id, _, _}, 0
      refute Map.has_key?(:sys.get_state(TaskRegistry.server()).task_refs, task_id)
    end

    test "a pause report for a row that already resolved is discarded" do
      unique = System.unique_integer([:positive])
      task_id = "paused_result_terminal_#{unique}"
      seed_task!(task_id, :completed, finished_at: DateTime.utc_now(), result: "done")
      subscribe_tasks!()
      ref = put_fake_wrapper!(task_id)

      deliver_wrapper_result(ref, {:paused, %{agent_id: 5, task_id: task_id}})

      fetched = reload(task_id)
      assert fetched.status == :completed
      assert fetched.finished_at != nil
      refute_receive {:task_updated, ^task_id, _, _}, 0
      refute Map.has_key?(:sys.get_state(TaskRegistry.server()).task_refs, task_id)
    end
  end

  ## The straggler guard

  describe "straggler guard — a late wrapper outcome never resurrects a paused task" do
    test "a late {:ok, %Result{}} for a :paused row is discarded" do
      unique = System.unique_integer([:positive])
      task_id = "straggler_ok_paused_#{unique}"
      seed_task!(task_id, :paused, pause_kind: :clean, result: "paused report")
      subscribe_tasks!()
      ref = put_fake_wrapper!(task_id)

      deliver_wrapper_result(ref, {:ok, %Result{result: "late report", commit_sha: "late_sha"}})

      fetched = reload(task_id)
      assert fetched.status == :paused
      assert fetched.pause_kind == :clean
      assert fetched.result == "paused report"
      assert fetched.finished_at == nil
      refute_receive {:task_updated, ^task_id, _, _}, 0
    end

    test "a late {:ok, %Result{}} and a late {:error, _} for a :pausing row are discarded" do
      unique = System.unique_integer([:positive])
      ok_id = "straggler_ok_pausing_#{unique}"
      err_id = "straggler_err_pausing_#{unique}"
      seed_task!(ok_id, :pausing)
      seed_task!(err_id, :pausing)
      subscribe_tasks!()

      ok_ref = put_fake_wrapper!(ok_id)

      deliver_wrapper_result(
        ok_ref,
        {:ok, %Result{result: "late report", commit_sha: "late_sha"}}
      )

      err_ref = put_fake_wrapper!(err_id)
      deliver_wrapper_result(err_ref, {:error, :boom})

      for id <- [ok_id, err_id] do
        fetched = reload(id)
        assert fetched.status == :pausing
        assert fetched.finished_at == nil
        assert fetched.result == nil
      end

      refute_receive {:task_updated, ^ok_id, _, _}, 0
      refute_receive {:task_updated, ^err_id, _, _}, 0
    end

    test "a late :DOWN for a :paused row is discarded (never :failed)" do
      unique = System.unique_integer([:positive])
      task_id = "straggler_down_paused_#{unique}"
      seed_task!(task_id, :paused, pause_kind: :clean)
      subscribe_tasks!()
      ref = put_fake_wrapper!(task_id)
      pid = :sys.get_state(TaskRegistry.server()).task_refs[task_id].pid

      deliver_wrapper_down(ref, pid, :boom)

      fetched = reload(task_id)
      assert fetched.status == :paused
      assert fetched.finished_at == nil
      refute_receive {:task_updated, ^task_id, _, _}, 0
    end
  end

  ## resume_task/1

  describe "resume_task/1" do
    test "re-enqueues the SAME id with resume_kind :clean_pause and preserves the run's facts",
         %{store: _store} do
      unique = System.unique_integer([:positive])
      task_id = "resume_clean_#{unique}"
      started_at = DateTime.utc_now()
      usage = %EvoGit.Agent.Usage{total_tokens: 77}
      opts = [path: "/tmp/test", mode: "simple", archive: true]

      seed_task!(task_id, :paused,
        pause_kind: :clean,
        opts: opts,
        started_at: started_at,
        result: "paused run report",
        usage: usage,
        commit_sha: "abc123",
        base_sha: "base123",
        branch_name: "genesis/agent_abc",
        review_status: :pending,
        finished_at: nil,
        lease_expires_at: nil
      )

      seed_durable_run!(task_id)
      _registry = start_registry_with_spawn_seam!(self())
      subscribe_tasks!()

      assert :ok = TaskRegistry.resume_task(task_id)

      # The spawn seam received the ADMITTED persisted opts plus the pause kind.
      assert_receive {:wrapper_spawned, :genesis, spawn_opts, ^task_id, _server}, 1_000
      assert Keyword.get(spawn_opts, :resume_kind) == :clean_pause
      assert Keyword.get(spawn_opts, :path) == "/tmp/test"
      assert Keyword.get(spawn_opts, :mode) == "simple"

      fetched = reload(task_id)
      assert fetched.status == :running
      assert fetched.pause_kind == nil
      assert fetched.finished_at == nil
      assert fetched.error == nil
      # A FRESH lease, cleared pause state, and every paused-run fact preserved.
      now = System.system_time(:second)
      assert fetched.lease_expires_at > now
      assert fetched.lease_expires_at <= now + TaskRegistry.lease_duration() + 5
      assert Enum.sort(fetched.opts) == Enum.sort(opts)
      assert DateTime.to_unix(fetched.started_at) == DateTime.to_unix(started_at)
      assert fetched.result == "paused run report"
      assert %EvoGit.Agent.Usage{total_tokens: 77} = fetched.usage
      assert fetched.commit_sha == "abc123"
      assert fetched.base_sha == "base123"
      assert fetched.branch_name == "genesis/agent_abc"
      assert fetched.review_status == :pending

      # The re-enqueue is tracked (the existing {ref, result} / :DOWN handlers
      # then work unchanged) and exactly ONE `:running` broadcast is emitted.
      assert Map.has_key?(:sys.get_state(TaskRegistry.server()).task_refs, task_id)
      assert_receive {:task_updated, ^task_id, :running, _node}, 1_000
      refute_receive {:task_updated, ^task_id, _, _}, 0

      # Same id: no second row was minted by the resume.
      ids = EvoGit.Store.select_task_ids(store(), []) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == [task_id]
      refute_receive {:wrapper_spawned, _, _, _, _}, 0
    end

    test "a legacy :paused row with a nil pause_kind resumes as :clean_pause" do
      unique = System.unique_integer([:positive])
      task_id = "resume_legacy_#{unique}"
      seed_task!(task_id, :paused, pause_kind: nil, lease_expires_at: nil)
      seed_durable_run!(task_id)
      start_registry_with_spawn_seam!(self())

      assert :ok = TaskRegistry.resume_task(task_id)
      assert_receive {:wrapper_spawned, :genesis, spawn_opts, ^task_id, _server}, 1_000
      assert Keyword.get(spawn_opts, :resume_kind) == :clean_pause
      assert reload(task_id).status == :running
    end

    test "a :dirty paused row resumes with resume_kind :dirty_pause" do
      unique = System.unique_integer([:positive])
      task_id = "resume_dirty_#{unique}"
      seed_task!(task_id, :paused, pause_kind: :dirty, lease_expires_at: nil)
      seed_durable_run!(task_id)
      start_registry_with_spawn_seam!(self())

      assert :ok = TaskRegistry.resume_task(task_id)
      assert_receive {:wrapper_spawned, :genesis, spawn_opts, ^task_id, _server}, 1_000
      assert Keyword.get(spawn_opts, :resume_kind) == :dirty_pause
      assert reload(task_id).pause_kind == nil
    end

    test "accepts :paused ONLY — {:error, :not_paused} for any other status and nothing is spawned",
         %{sqlite_path: sqlite_path} do
      unique = System.unique_integer([:positive])
      _registry = start_registry_with_spawn_seam!(self())

      for status <- [:running, :pausing, :pending, :awaiting_input, :completed, :cancelled] do
        task_id = "resume_refuse_#{status}_#{unique}"
        seed_task!(task_id, status)
        before = updated_at(task_id, sqlite_path)

        assert {:error, :not_paused} = TaskRegistry.resume_task(task_id),
               "expected :not_paused for #{inspect(status)}"

        assert reload(task_id).status == status
        assert selected_updated_at(task_id) == before
      end

      refute_receive {:wrapper_spawned, _, _, _, _}, 0
    end

    test "an unknown task answers {:error, :not_found}" do
      _registry = start_registry_with_spawn_seam!(self())

      assert {:error, :not_found} =
               TaskRegistry.resume_task("resume_missing_#{System.unique_integer([:positive])}")

      refute_receive {:wrapper_spawned, _, _, _, _}, 0
    end

    test "an admission failure answers the error and leaves the row :paused (nothing spawned)" do
      unique = System.unique_integer([:positive])
      _registry = start_registry_with_spawn_seam!(self())

      cases = [
        {"resume_bad_spec_#{unique}", [path: "/tmp/test", model_spec: "not-a-map"],
         :invalid_model_spec},
        {"resume_bad_session_#{unique}", [path: "/tmp/test", session_mode: 123],
         :invalid_session_mode},
        {"resume_bad_persist_#{unique}", [path: "/tmp/test", persistent_state: "yes"],
         :invalid_persistent_state}
      ]

      for {task_id, opts, expected} <- cases do
        seed_task!(task_id, :paused, pause_kind: :clean, opts: opts, lease_expires_at: nil)
        # Durable state exists, so the ONLY thing that can refuse is admission.
        seed_durable_run!(task_id)

        assert {:error, ^expected} = TaskRegistry.resume_task(task_id),
               "expected #{inspect(expected)} for #{task_id}"

        fetched = reload(task_id)
        assert fetched.status == :paused
        assert fetched.pause_kind == :clean
        assert fetched.finished_at == nil
      end

      refute_receive {:wrapper_spawned, _, _, _, _}, 0
    end

    test "a paused row with NO durable run is {:error, :not_resumable} and stays :paused" do
      unique = System.unique_integer([:positive])
      task_id = "resume_no_state_#{unique}"
      seed_task!(task_id, :paused, pause_kind: :clean, lease_expires_at: nil)
      _registry = start_registry_with_spawn_seam!(self())

      assert {:error, :not_resumable} = TaskRegistry.resume_task(task_id)

      fetched = reload(task_id)
      assert fetched.status == :paused
      assert fetched.pause_kind == :clean
      assert fetched.lease_expires_at == nil
      refute_receive {:wrapper_spawned, _, _, _, _}, 0
    end

    test "a CHILD-only durable roster is {:error, :not_resumable} — nothing restores a ROOT" do
      # The ROOT row is the gate: "any durable row" is not enough, because a
      # resume that cannot restore a root would silently restart the objective
      # from scratch.
      unique = System.unique_integer([:positive])
      task_id = "resume_child_only_#{unique}"
      seed_task!(task_id, :paused, pause_kind: :clean, lease_expires_at: nil)
      seed_child_run!(task_id)
      _registry = start_registry_with_spawn_seam!(self())

      assert {:error, :not_resumable} = TaskRegistry.resume_task(task_id)

      fetched = reload(task_id)
      assert fetched.status == :paused
      assert fetched.pause_kind == :clean
      assert fetched.lease_expires_at == nil
      refute_receive {:wrapper_spawned, _, _, _, _}, 0
    end

    test "carries the ROOT run's five resume facts on the spawn opts" do
      unique = System.unique_integer([:positive])
      task_id = "resume_facts_#{unique}"
      agent_id = 7
      anchor_ref = "refs/genesis/agent-state/#{task_id}/#{agent_id}"

      seed_task!(task_id, :paused, pause_kind: :clean, lease_expires_at: nil)

      seed_durable_run!(task_id, agent_id, %{
        pause_commit: "pause123",
        current_commit: "cur123",
        branch: "evogit-agent_facts",
        anchor_ref: anchor_ref
      })

      _registry = start_registry_with_spawn_seam!(self())

      assert :ok = TaskRegistry.resume_task(task_id)
      assert_receive {:wrapper_spawned, :genesis, spawn_opts, ^task_id, _server}, 1_000

      assert Keyword.get(spawn_opts, :resume_kind) == :clean_pause
      assert Keyword.get(spawn_opts, :pause_commit) == "pause123"
      assert Keyword.get(spawn_opts, :resume_agent_id) == agent_id
      assert Keyword.get(spawn_opts, :resume_current_commit) == "cur123"
      assert Keyword.get(spawn_opts, :resume_branch) == "evogit-agent_facts"
      assert Keyword.get(spawn_opts, :resume_anchor_ref) == anchor_ref
    end

    test "restores the WHOLE frozen tree — the running child keeps its own row" do
      unique = System.unique_integer([:positive])
      task_id = "resume_tree_#{unique}"
      root_id = 1
      child_id = 2
      anchor_ref = "refs/genesis/agent-state/#{task_id}/#{root_id}"

      seed_task!(task_id, :paused, pause_kind: :clean, lease_expires_at: nil)

      seed_durable_run!(task_id, root_id, %{
        pause_commit: "root_pause",
        current_commit: "root_cur",
        branch: "evogit-agent_tree",
        anchor_ref: anchor_ref
      })

      # A still-running child of the SAME frozen tree with its own checkpoint:
      # the thaw planner restores it, so the registry must neither read its
      # facts nor consume its row.
      seed_child_run!(task_id, child_id, root_id, %{
        pause_commit: "child_pause",
        status: "running"
      })

      _registry = start_registry_with_spawn_seam!(self())

      assert :ok = TaskRegistry.resume_task(task_id)

      assert_receive {:wrapper_spawned, :genesis, spawn_opts, ^task_id, _server}, 1_000
      assert Keyword.get(spawn_opts, :resume_kind) == :clean_pause
      # The ROOT's five facts — the child's are the planner's business.
      assert Keyword.get(spawn_opts, :pause_commit) == "root_pause"
      assert Keyword.get(spawn_opts, :resume_agent_id) == root_id
      assert Keyword.get(spawn_opts, :resume_current_commit) == "root_cur"
      assert Keyword.get(spawn_opts, :resume_branch) == "evogit-agent_tree"
      assert Keyword.get(spawn_opts, :resume_anchor_ref) == anchor_ref

      # The SAME task id was re-enqueued…
      assert reload(task_id).status == :running

      # …and the child is STILL a live row in the durable snapshot: nothing in
      # the resume admission consumed it, so the planner can restore it from its
      # own conversation, worktree base and position.
      assert {:ok, snapshot} = Snapshot.read(task_id)
      assert snapshot.root.agent_id == root_id

      # Both rows stay LIVE — the root's own row is untouched too — so the thaw
      # planner finds the whole frozen tree, child included.
      assert Enum.map(Snapshot.live(snapshot), & &1.agent_id) == [root_id, child_id]

      child = Enum.find(Snapshot.live(snapshot), &(&1.agent_id == child_id))
      assert child.fields[:pause_commit] == "child_pause"
      assert child.fields[:parent_id] == root_id
    end

    test "a root row WITHOUT an anchor_ref still carries the derived anchor fact" do
      unique = System.unique_integer([:positive])
      task_id = "resume_anchor_derived_#{unique}"
      agent_id = 3

      seed_task!(task_id, :paused, pause_kind: :clean, lease_expires_at: nil)
      # `pause_commit` is DELIBERATELY absent too: a resolved-but-empty fact must
      # still be present on the opts, so "nothing stored" and "never resolved"
      # stay distinguishable (the latter is the direct-dispatch fallback).
      seed_durable_run!(task_id, agent_id, %{current_commit: "cur456", branch: "b"})
      _registry = start_registry_with_spawn_seam!(self())

      assert :ok = TaskRegistry.resume_task(task_id)
      assert_receive {:wrapper_spawned, :genesis, spawn_opts, ^task_id, _server}, 1_000

      assert Keyword.has_key?(spawn_opts, :resume_anchor_ref)

      assert Keyword.get(spawn_opts, :resume_anchor_ref) ==
               EvoGit.AgentState.Anchor.ref(task_id, agent_id)

      assert Keyword.has_key?(spawn_opts, :pause_commit)
      assert Keyword.get(spawn_opts, :pause_commit) == nil
      assert Keyword.get(spawn_opts, :resume_current_commit) == "cur456"
    end
  end

  ## Restart mapping (dirty pause)

  describe "restart mapping — a resumable wrapper-less row becomes a DIRTY pause" do
    test "init/1 parks a resumable :running row :paused/:dirty (one broadcast), facts preserved",
         %{data_dir: data_dir, registry: registry} do
      unique = System.unique_integer([:positive])
      task_id = "restart_running_#{unique}"
      future_lease = System.system_time(:second) + 300
      # Stop the registry FIRST so the row exists before the fresh instance boots
      # (the Store keeps running — it is the durable source of truth).
      stop_supervised(registry)

      seed_task!(task_id, :running,
        result: "paused run report",
        usage: %EvoGit.Agent.Usage{total_tokens: 9},
        lease_expires_at: future_lease
      )

      seed_durable_run!(task_id)
      subscribe_tasks!()

      start_supervised(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store(), data_dir: data_dir, name: registry},
          id: registry
        )
      )

      fetched = reload(task_id)
      assert fetched.status == :paused
      assert fetched.pause_kind == :dirty
      assert fetched.finished_at == nil
      assert fetched.lease_expires_at == nil
      # A TARGETED write: the pre-restart report/usage survive.
      assert fetched.result == "paused run report"
      assert %EvoGit.Agent.Usage{total_tokens: 9} = fetched.usage

      assert_receive {:task_updated, ^task_id, :paused, _node}, 1_000
      refute_receive {:task_updated, ^task_id, _, _}, 0
    end

    test "init/1 parks a resumable :pausing row :paused/:dirty (an interrupted drain)",
         %{data_dir: data_dir, registry: registry} do
      unique = System.unique_integer([:positive])
      task_id = "restart_pausing_#{unique}"
      stop_supervised(registry)

      seed_task!(task_id, :pausing, lease_expires_at: System.system_time(:second) + 300)
      seed_durable_run!(task_id)
      subscribe_tasks!()

      start_supervised(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store(), data_dir: data_dir, name: registry},
          id: registry
        )
      )

      fetched = reload(task_id)
      assert fetched.status == :paused
      assert fetched.pause_kind == :dirty
      assert fetched.finished_at == nil
      assert fetched.lease_expires_at == nil
      assert_receive {:task_updated, ^task_id, :paused, _node}, 1_000
      refute_receive {:task_updated, ^task_id, _, _}, 0
    end

    test "init/1 leaves a NON-resumable :running/:pausing row exactly as it was",
         %{data_dir: data_dir, registry: registry} do
      unique = System.unique_integer([:positive])
      running_id = "restart_nonresumable_running_#{unique}"
      pausing_id = "restart_nonresumable_pausing_#{unique}"
      future_lease = System.system_time(:second) + 300
      stop_supervised(registry)

      # No durable agent-state row exists for either: today's behaviour stands
      # (`:running` waits for the one-shot :lease_sweep, `:pausing` likewise).
      seed_task!(running_id, :running, lease_expires_at: future_lease)
      seed_task!(pausing_id, :pausing, lease_expires_at: future_lease)
      subscribe_tasks!()

      start_supervised(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store(), data_dir: data_dir, name: registry},
          id: registry
        )
      )

      running = reload(running_id)
      assert running.status == :running
      assert running.pause_kind == nil
      assert running.lease_expires_at == future_lease

      pausing = reload(pausing_id)
      assert pausing.status == :pausing
      assert pausing.pause_kind == nil
      assert pausing.lease_expires_at == future_lease

      refute_receive {:task_updated, ^running_id, _, _}, 0
      refute_receive {:task_updated, ^pausing_id, _, _}, 0
    end

    test "init/1 trusts the ROOT row rule: an interactive row stays NON-resumable, its one-shot twin parks",
         %{data_dir: data_dir, registry: registry} do
      unique = System.unique_integer([:positive])
      interactive_id = "restart_interactive_#{unique}"
      oneshot_id = "restart_oneshot_#{unique}"
      future_lease = System.system_time(:second) + 300
      stop_supervised(registry)

      # The SAME row shape and the SAME durable ROOT row for both; only the
      # persisted `:session_mode` differs. An interactive session's lifecycle is
      # user-driven, so a resumed one would have no client and park in
      # `:awaiting_input` forever — it must keep today's `:running` →
      # `:lease_expired` treatment instead of becoming a dirty pause.
      seed_task!(interactive_id, :running,
        opts: [path: "/tmp/test", session_mode: "interactive"],
        lease_expires_at: future_lease
      )

      seed_task!(oneshot_id, :running,
        opts: [path: "/tmp/test", session_mode: "oneshot"],
        lease_expires_at: future_lease
      )

      seed_durable_run!(interactive_id)
      seed_durable_run!(oneshot_id)
      subscribe_tasks!()

      start_supervised(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store(), data_dir: data_dir, name: registry},
          id: registry
        )
      )

      interactive = reload(interactive_id)
      assert interactive.status == :running
      assert interactive.pause_kind == nil
      assert interactive.lease_expires_at == future_lease

      oneshot = reload(oneshot_id)
      assert oneshot.status == :paused
      assert oneshot.pause_kind == :dirty
      assert oneshot.finished_at == nil
      assert oneshot.lease_expires_at == nil

      assert_receive {:task_updated, ^oneshot_id, :paused, _node}, 1_000
      refute_receive {:task_updated, ^interactive_id, _, _}, 0
    end

    test "init/1 never touches a :paused row (the resting state is not an input)",
         %{data_dir: data_dir, registry: registry} do
      unique = System.unique_integer([:positive])
      task_id = "restart_keeps_paused_#{unique}"
      stop_supervised(registry)

      seed_task!(task_id, :paused, pause_kind: :clean, lease_expires_at: nil, result: "report")
      # Durable state exists — it must NOT be re-classified as dirty.
      seed_durable_run!(task_id)
      subscribe_tasks!()

      start_supervised(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store(), data_dir: data_dir, name: registry},
          id: registry
        )
      )

      fetched = reload(task_id)
      assert fetched.status == :paused
      assert fetched.pause_kind == :clean
      assert fetched.result == "report"
      assert fetched.lease_expires_at == nil
      refute_receive {:task_updated, ^task_id, _, _}, 0
    end
  end

  ## The restart classifier's ROOT gate

  describe "pause_kind_for_restart/1,2 — the ROOT row gate" do
    test "a CHILD-only durable roster is nil; a ROOT row makes the same task :dirty" do
      unique = System.unique_integer([:positive])
      child_only_id = "restart_child_only_#{unique}"
      root_id = "restart_has_root_#{unique}"
      seed_task!(child_only_id, :running)
      seed_task!(root_id, :running)
      seed_child_run!(child_only_id)
      seed_durable_run!(root_id)

      # Map arity (the row is already decoded, as both restart paths hand it over).
      assert Pause.pause_kind_for_restart(reload(child_only_id)) == nil
      assert Pause.pause_kind_for_restart(reload(root_id)) == :dirty

      # (store, task_id) arity: the narrow row the boot reconciliation and the
      # lease sweep actually hold is re-read once through `get_task_lite/2`.
      assert Pause.pause_kind_for_restart(store(), child_only_id) == nil
      assert Pause.pause_kind_for_restart(store(), root_id) == :dirty
    end
  end

  ## An interactive session is never dirty-pausable

  describe "dirty_pausable?/1 — an interactive session is never resumable" do
    test "a ROOT row makes the one-shot twin dirty, never the interactive task (both arities)" do
      unique = System.unique_integer([:positive])
      interactive_id = "restart_dirty_interactive_#{unique}"
      oneshot_id = "restart_dirty_oneshot_#{unique}"

      seed_task!(interactive_id, :running, opts: [path: "/tmp/test", session_mode: "interactive"])

      seed_task!(oneshot_id, :running, opts: [path: "/tmp/test", session_mode: "oneshot"])
      seed_durable_run!(interactive_id)
      seed_durable_run!(oneshot_id)

      # BOTH tasks hold a durable ROOT row, so the session mode alone decides —
      # and the row really does carry the string-keyed spelling after the
      # round-trip (`:session_mode` is a STRING-keyed persisted opt).
      assert {:ok, _root} = AgentState.load(interactive_id, 1)
      assert {:ok, _root} = AgentState.load(oneshot_id, 1)
      assert {"session_mode", "interactive"} in reload(interactive_id).opts

      refute Pause.dirty_pausable?(reload(interactive_id))
      assert Pause.dirty_pausable?(reload(oneshot_id))

      # Map arity (the row is already decoded, as both restart paths hand it over).
      assert Pause.pause_kind_for_restart(reload(interactive_id)) == nil
      assert Pause.pause_kind_for_restart(reload(oneshot_id)) == :dirty

      # (store, task_id) arity: the narrow row the boot reconciliation and the
      # lease sweep actually hold is re-read once through `get_task_lite/2`.
      assert Pause.pause_kind_for_restart(store(), interactive_id) == nil
      assert Pause.pause_kind_for_restart(store(), oneshot_id) == :dirty
    end
  end

  ## Persistent-state opt-out

  describe "persistent_state: false — neither pausable nor resumable" do
    test "a :running row and its :paused counterpart are both refused" do
      unique = System.unique_integer([:positive])
      running_id = "no_persist_pause_#{unique}"
      paused_id = "no_persist_resume_#{unique}"
      opts = [path: "/tmp/test", persistent_state: false]

      seed_task!(running_id, :running, opts: opts)
      seed_task!(paused_id, :paused, opts: opts, pause_kind: :clean, lease_expires_at: nil)
      _registry = start_registry_with_spawn_seam!(self())
      subscribe_tasks!()

      # Nothing durable would be written, so a pause would be a lie…
      assert {:error, :not_resumable} = TaskRegistry.pause_task(running_id)
      assert reload(running_id).status == :running

      # …and the matching resting row has no ROOT run to restore.
      assert {:error, :not_resumable} = TaskRegistry.resume_task(paused_id)
      assert reload(paused_id).status == :paused

      # Scoped to the two rows under test: the app-global `"tasks"` topic also
      # carries other concurrently running modules' broadcasts, which say
      # nothing about whether THESE rows were flipped.
      refute_receive {:task_updated, ^running_id, _, _}, 0
      refute_receive {:task_updated, ^paused_id, _, _}, 0
      refute_receive {:wrapper_spawned, _, _, _, _}, 0
    end
  end

  ## RPC mirrors

  describe "RPC — RemoteAPI / RemoteNode" do
    test "RemoteAPI.pause_task/1 and resume_task/1 delegate to the registry" do
      unique = System.unique_integer([:positive])
      task_id = "rpc_pause_#{unique}"
      seed_task!(task_id, :running)
      clear_pause_marker!(task_id)

      # Delegation is proven by the ISOLATED registry answering: the process
      # dictionary seam points `EvoGit.TaskRegistry.server/0` at this test's
      # instance, so a straight delegation reaches it.
      assert :ok = EvoGit.AgentScheduler.RemoteAPI.pause_task(task_id)
      assert reload(task_id).status == :pausing

      # resume delegates too, with its documented dry shapes for a row that
      # cannot be resumed (the row is `:pausing`, never `:paused`).
      assert {:error, :not_paused} = EvoGit.AgentScheduler.RemoteAPI.resume_task(task_id)

      assert {:error, :not_found} =
               EvoGit.AgentScheduler.RemoteAPI.resume_task("rpc_missing_#{unique}")
    end

    test "RemoteNode.pause_task/2 and resume_task/2 mirror cancel_task/2's local and remote behavior" do
      unique = System.unique_integer([:positive])
      task_id = "rpc_node_pause_#{unique}"
      seed_task!(task_id, :running)
      clear_pause_marker!(task_id)

      # LOCAL: a direct call to RemoteAPI → TaskRegistry (this test's instance).
      assert :ok = EvoGit.RemoteNode.pause_task(node(), task_id)
      assert reload(task_id).status == :pausing
      assert {:error, :not_paused} = EvoGit.RemoteNode.resume_task(node(), task_id)

      # REMOTE: an unreachable node answers the degraded `{:error, reason}` shape,
      # exactly like `cancel_task/2`.
      fake_remote = :"genesis_remote_down_#{unique}@127.0.0.1"
      assert {:error, _reason} = EvoGit.RemoteNode.pause_task(fake_remote, task_id)
      assert {:error, _reason} = EvoGit.RemoteNode.resume_task(fake_remote, task_id)
    end
  end

  ## Paused-row invariants

  describe "paused-row invariants" do
    test "a :paused row is never reported as finished — clear_finished_tasks keeps it" do
      unique = System.unique_integer([:positive])
      paused_id = "invariant_paused_#{unique}"
      completed_id = "invariant_completed_#{unique}"
      seed_task!(paused_id, :paused, pause_kind: :clean, lease_expires_at: nil)
      seed_task!(completed_id, :completed, finished_at: DateTime.utc_now())

      assert :ok = TaskRegistry.clear_finished_tasks()

      assert %TaskInfo{status: :paused} = reload(paused_id)
      assert reload(completed_id) == nil
    end

    test "the pure resume-kind / runtime-opt forwarding contract" do
      # `Pause.resume_kind/1` is the ONE paused-kind → narration selector.
      assert Pause.resume_kind(:dirty) == :dirty_pause
      assert Pause.resume_kind(:clean) == :clean_pause
      assert Pause.resume_kind(nil) == :clean_pause

      # The spawn opt is FORWARDED into the runtime opts (which turn it into the
      # dispatch ctx `resume_kind`) for exactly the two known kinds — an unknown
      # value is omitted, so a normal run's runtime opts stay byte-identical.
      {nil, clean} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/test", resume_kind: :clean_pause],
          "task_resume_kind_clean",
          :evolve
        )

      assert Keyword.get(clean, :resume_kind) == :clean_pause

      {nil, dirty} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/test", resume_kind: :dirty_pause],
          "task_resume_kind_dirty",
          :evolve
        )

      assert Keyword.get(dirty, :resume_kind) == :dirty_pause

      {nil, plain} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/test", resume_kind: :crash],
          "task_resume_kind_unknown",
          :evolve
        )

      refute Keyword.has_key?(plain, :resume_kind)

      {nil, absent} =
        RuntimeOpts.build_common_runtime_opts(
          [path: "/tmp/test"],
          "task_resume_kind_absent",
          :evolve
        )

      refute Keyword.has_key?(absent, :resume_kind)
    end
  end

  ## Spawn-seam helper

  # Starts a SECOND, isolated registry instance over THIS test's store whose
  # wrapper spawn is the `:wrapper_spawn_fun` seam: it reports the spawn to
  # `test_pid` and returns a fake (alive) `%Task{}` instead of running a real
  # runtime. The process dictionary then points every in-test
  # `EvoGit.TaskRegistry.*` call at that instance.
  defp start_registry_with_spawn_seam!(test_pid) do
    unique = System.unique_integer([:positive])
    name = :"evogit_test_pause_registry_#{unique}"

    spawn_fun = fn task_type, spawn_opts, task_id, server ->
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:wrapper_spawned, task_type, spawn_opts, task_id, server})

      %Task{
        pid: pid,
        ref: make_ref(),
        owner: test_pid,
        mfa: {EvoGit.TaskRegistry.TaskExecutor, :execute_task, [task_type, spawn_opts, task_id]}
      }
    end

    start_supervised!(
      Supervisor.child_spec(
        {TaskRegistry,
         task_store: store(),
         data_dir: System.tmp_dir!(),
         name: name,
         wrapper_spawn_fun: spawn_fun},
        id: name
      )
    )

    Process.put(:evogit_task_registry_server, name)
    name
  end

  defp selected_updated_at(task_id) do
    store()
    |> EvoGit.Store.select_task_ids([])
    |> Enum.find(&(&1.id == task_id))
    |> Map.fetch!(:updated_at)
  end
end
