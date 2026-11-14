defmodule EvoGit.AgentScheduler.ArchiveResetResumeTest do
  @moduledoc """
  The ARCHIVE-ROSTER half of task-level pause & resume: a resume must not wipe
  the paused run's per-agent archive.

  `run_agent/2` clears the task's leftover `task_agent_archives` rows on a plain
  start (the canonical-archive-per-run rule). A task-level PAUSE RESUME is the
  ONE exception: it re-enqueues the SAME task id (`EvoGit.TaskRegistry.Pause`),
  so the rows already stored are the PAUSED run's roster — the durable half of
  its report — and clearing them would destroy it.

  Pinned here, through the real `handle_call({:run_agent, spec}, ...)` path with
  a PAUSED scheduler state (so the agent is queued and never dispatched — no
  session, no worktree, no LLM):
    * a spec carrying `resume_kind: :clean_pause` (and `:dirty_pause`) leaves the
      task's archive rows untouched;
    * a spec WITHOUT `resume_kind` still clears them, byte-identically to
      today's behaviour;
    * a resumed run's own completions therefore UPSERT onto the surviving roster
      (`task_agent_archives` is keyed `(task_id, agent_id)`: re-writing the same
      agent's row REPLACES it, a new agent id appends a second row).

  `async: true`: every row lives under a per-test UNIQUE task id and a
  scheduler state whose `next_agent_id` is unique per test, so nothing here
  observes or disturbs a sibling test. The archive rows go through the
  app-global `EvoGit.Store`, as `remote_node_test.exs` does.
  """
  use ExUnit.Case, async: true
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Store

  # A far-away per-test agent-id band: `run_agent/2` registers the agent in the
  # app-global ETS tables using `state.next_agent_id`, so the states below start
  # well clear of any other test's ids.
  @id_base 9_970_000

  setup %{tmp_dir: tmp_dir} do
    for {name, opts} <- [
          {:evogit_cancelling_tasks, [:named_table, :public, :set]},
          {:evogit_task_pause, [:named_table, :public, :set]},
          {:evogit_agent_summary, [:named_table, :public, :set]},
          {:evogit_sched_meta, [:named_table, :public, :set]},
          {:evogit_agent_inbox, [:bag, :named_table, :public]},
          {:evogit_agent_control, [:named_table, :public, :set]}
        ] do
      if :ets.whereis(name) == :undefined, do: :ets.new(name, opts)
    end

    task_id = "archive-resume-#{System.unique_integer([:positive])}"
    first_agent_id = @id_base + System.unique_integer([:positive]) * 10

    on_exit(fn ->
      Store.delete_task_archives(Store, task_id)
      :ets.delete(:evogit_sched_meta, first_agent_id)
      :ets.delete(:evogit_agent_summary, first_agent_id)
    end)

    %{task_id: task_id, repo: tmp_dir, first_agent_id: first_agent_id}
  end

  @moduletag :tmp_dir

  describe "run_agent/2 archive reset admission" do
    test "a pause resume keeps the paused run's roster", %{task_id: task_id} = ctx do
      seed_roster!(task_id)
      state = state(ctx)

      assert {:noreply, _state} =
               AgentScheduler.handle_call(
                 {:run_agent, spec(task_id, resume_kind: :clean_pause)},
                 from(),
                 state
               )

      assert roster(task_id) == [1, 2]
    end

    test "a dirty pause resume keeps it too", %{task_id: task_id} = ctx do
      seed_roster!(task_id)

      assert {:noreply, _state} =
               AgentScheduler.handle_call(
                 {:run_agent, spec(task_id, resume_kind: :dirty_pause)},
                 from(),
                 state(ctx)
               )

      assert roster(task_id) == [1, 2]
    end

    test "a plain start still clears the previous run's rows", %{task_id: task_id} = ctx do
      seed_roster!(task_id)

      assert {:noreply, _state} =
               AgentScheduler.handle_call(
                 {:run_agent, spec(task_id)},
                 from(),
                 state(ctx)
               )

      assert roster(task_id) == []
    end

    test "an unrecognized resume_kind keeps the clearing behaviour", %{task_id: task_id} = ctx do
      seed_roster!(task_id)

      assert {:noreply, _state} =
               AgentScheduler.handle_call(
                 {:run_agent, spec(task_id, resume_kind: :crash)},
                 from(),
                 state(ctx)
               )

      assert roster(task_id) == []
    end
  end

  describe "a resumed run's completions append to the surviving roster" do
    test "a new agent id appends and a re-written agent id replaces its row", %{
      task_id: task_id
    } do
      seed_roster!(task_id)

      # A resumed run's agent is a NEW agent id, so its archived row APPENDS to
      # the paused run's roster instead of replacing anything.
      :ok =
        Store.put_task_archive(Store, %{
          task_id: task_id,
          agent_id: 3,
          depth: 0,
          objective: "resumed root",
          result: "resumed result"
        })

      assert roster(task_id) == [1, 2, 3]

      # `(task_id, agent_id)` is the key: a second write for the same agent
      # REPLACES that row (never duplicates it, omitted columns NULLed).
      :ok =
        Store.put_task_archive(Store, %{
          task_id: task_id,
          agent_id: 3,
          depth: 0,
          objective: "resumed root (again)",
          result: "second result"
        })

      assert roster(task_id) == [1, 2, 3]

      assert %{"result" => "second result", "objective" => "resumed root (again)"} =
               Store.get_agent_archive(Store, task_id, 3)
    end
  end

  # --- Helpers -------------------------------------------------------------

  # Two roster rows standing in for the paused run's per-agent archive.
  defp seed_roster!(task_id) do
    for agent_id <- [1, 2] do
      :ok =
        Store.put_task_archive(Store, %{
          task_id: task_id,
          agent_id: agent_id,
          depth: 0,
          objective: "paused agent #{agent_id}",
          result: "paused result #{agent_id}"
        })
    end

    :ok
  end

  defp roster(task_id) do
    %{entries: entries} = Store.list_task_archives(Store, task_id, limit: 100)
    Enum.map(entries, & &1["agent_id"])
  end

  # A PAUSED scheduler state: `run_agent/2` queues the new agent instead of
  # dispatching it, so the ONLY store side effect under test is the archive
  # reset. `next_agent_id` is unique per test (see `@id_base`).
  defp state(%{first_agent_id: first_agent_id}) do
    [%{id: "default", model: "test:model", concurrency: 3}]
    |> State.from_model_profiles()
    |> struct!(
      paused: true,
      next_agent_id: first_agent_id,
      agent_max_retries: 3,
      ref_to_agent: %{}
    )
  end

  defp spec(task_id, extra \\ []) do
    %AgentSpec{
      context_node: %ContextNode{path: "./", repo: "/tmp/archive-reset-test"},
      phylo_node: %PhyloGraphNode{
        repo: "/tmp/archive-reset-test",
        base_commit: "abc",
        current_commit: "abc"
      },
      agent_module: EvoGit.Agents.SelfReflective,
      objective: "archive reset admission",
      opts: [task_id: task_id, repo_less: true] ++ extra
    }
  end

  defp from, do: {self(), make_ref()}
end
