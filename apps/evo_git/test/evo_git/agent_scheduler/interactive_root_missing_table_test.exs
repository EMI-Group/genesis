defmodule EvoGit.AgentScheduler.InteractiveRootMissingTableTest do
  @moduledoc """
  `EvoGit.AgentScheduler.InteractiveRoot` — the ONE definition of the
  interactive-root (`/assistant`) SESSION SHAPE, shared by
  `EvoGit.Agent.Tools.ElixirEval.Authorization` and
  `EvoGit.CommandApproval.request_eval/5` — must DEGRADE, never raise.

  Its documented degradation has two halves, both pinned here:

    * a MISSING TABLE — `:evogit_sched_meta` / `:evogit_agent_summary` are
      created once by `EvoGit.Application` and can vanish during a scheduler
      restart, so every read is `:ets.whereis/1`-guarded and the predicate
      answers `false` in the CALLER instead of letting an `:ets` badarg escape
      into admission logic;
    * a MISSING ROW — an identity that is not the interactive-root shape is
      refused (`false`), and the local `/assistant` approval flow answers its
      documented `:denied` (fail closed) rather than a crash.

  ## Why a `:peer` node for the missing-TABLE arm

  No test may delete the app-global scheduler tables: every concurrent module's
  registration write would raise inside that window and nothing recreates the
  tables before the next test. So the genuinely table-less state is driven on a
  bare `:peer` BEAM — the SAME compiled code (`-pa` carries this node's code
  paths) with the `:evo_git` application NOT started, so `:ets.whereis/1`
  honestly answers `:undefined` there. `connection: :standard_io` needs no
  distribution and no epmd, and the peer is stopped in `on_exit`.

  ## Why `async: true`

  The peer boots its own VM and touches NONE of this node's state. The local
  contrast writes only PRODUCTION-SHAPED rows keyed by this module's per-test
  unique id (`9_910_000 +`, deleted in `on_exit`) — inserted RAW, so a fixture
  emits no `:agent_registered` broadcast on the shared `"agents"` topic — and
  the approval flow is exercised ONLY on its registration-denial path, which
  never reaches the `EvoGit.CommandApproval` service or an approval window.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.InteractiveRoot
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentSpec
  alias EvoGit.CommandApproval
  alias EvoGit.Core.ContextNode

  @agent_id_base 9_910_000

  describe "a node whose scheduler tables are absent" do
    test "the interactive-root predicate refuses instead of raising" do
      {peer, _peer_node} = start_bare_peer()

      # The premise of this test: the tables genuinely do not exist there.
      assert :peer.call(peer, :ets, :whereis, [:evogit_sched_meta]) == :undefined
      assert :peer.call(peer, :ets, :whereis, [:evogit_agent_summary]) == :undefined

      # The documented degradation: `false`, from the guard — never an `:ets`
      # badarg escaping into admission logic.
      assert :peer.call(peer, InteractiveRoot, :live?, [unique_agent_id(), "task-absent", :any]) ==
               false

      assert :peer.call(peer, InteractiveRoot, :live?, [1, "task-absent", :any]) == false
      # Malformed identities stay total there too.
      assert :peer.call(peer, InteractiveRoot, :live?, [nil, nil, :any]) == false

      assert :peer.call(peer, InteractiveRoot, :session_meta?, [%{}, "task-absent", :any]) ==
               false
    end
  end

  describe "with the tables present" do
    test "an absent row is refused by the flow, and the real session shape is admitted" do
      agent_id = unique_agent_id()
      task_id = "interactive-root-#{agent_id}"
      # A LIVE session pid is part of the shape; it is a plain holder process.
      session =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> send(session, :stop) end)

      # (a) No rows anywhere: refused by the predicate…
      refute InteractiveRoot.live?(agent_id, task_id)
      # …and the local `/assistant` approval flow answers its documented
      # fail-closed refusal (a scheduler-minted task id owns no `tasks` row, so
      # admission rests on the shared predicate alone).
      assert :denied =
               CommandApproval.request_eval(
                 "1 + 1",
                 :write,
                 node(),
                 Integer.to_string(agent_id),
                 task_id
               )

      # (b) The REAL interactive-root shape IS admitted — so the refusal above
      # is a decision, not a predicate that always answers `false`.
      put_interactive_root_rows(agent_id, task_id, session)
      on_exit(fn -> delete_interactive_root_rows(agent_id) end)

      assert InteractiveRoot.live?(agent_id, task_id)
      assert InteractiveRoot.live?(agent_id, task_id, session)

      # (c) …and each half of the identity still refuses a mismatch.
      refute InteractiveRoot.live?(agent_id, task_id <> "-other")
      refute InteractiveRoot.live?(agent_id, task_id, self())
      refute InteractiveRoot.live?(agent_id, task_id, nil)
      refute InteractiveRoot.live?(unique_agent_id(), task_id)
    end

    test "a cancelled session row is refused even when the shape matches" do
      agent_id = unique_agent_id()
      task_id = "interactive-root-#{agent_id}"

      session =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> send(session, :stop) end)
      put_interactive_root_rows(agent_id, task_id, session)
      on_exit(fn -> delete_interactive_root_rows(agent_id) end)

      assert InteractiveRoot.live?(agent_id, task_id)

      # The cancellation flag lives in the CONTROL PLANE (never on the summary
      # row), and it must close the gate: a cancelling session is not a live
      # principal for new evaluation requests.
      assert :ok = EvoGit.AgentScheduler.ControlPlane.set_cancel(agent_id, true)
      on_exit(fn -> EvoGit.AgentScheduler.ControlPlane.delete(agent_id) end)

      refute InteractiveRoot.live?(agent_id, task_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  # A bare BEAM carrying THIS node's compiled code and nothing else: no
  # `:evo_git` application, so the scheduler tables do not exist there.
  defp start_bare_peer do
    args = for path <- :code.get_path(), arg <- [~c"-pa", path], do: arg
    {:ok, peer, peer_node} = :peer.start_link(%{connection: :standard_io, args: args})
    on_exit(fn -> stop_peer(peer) end)
    {peer, peer_node}
  end

  defp stop_peer(peer) do
    :peer.stop(peer)
  catch
    _kind, _reason -> :ok
  end

  # PRODUCTION-SHAPED rows (a plain map would make a concurrent module's
  # whole-table scan crash), inserted RAW so a fixture emits no
  # `:agent_registered` broadcast on the shared `"agents"` topic.
  defp put_interactive_root_rows(agent_id, task_id, session_pid) do
    spec = %AgentSpec{
      agent_module: EvoGit.Agents.SelfReflective,
      context_node: %ContextNode{path: ".", repo: "/tmp/evogit-fixture"},
      objective: "fixture",
      repo_id: "primary",
      foreign_repos: [],
      phylo_node: nil,
      opts: [repo_less: true, session_mode: :interactive]
    }

    meta = %SchedMeta{
      id: agent_id,
      depth: 0,
      parent_id: nil,
      result_sent: false,
      mode: :interactive,
      task_id: task_id,
      session_pid: session_pid,
      status: :awaiting_input,
      spec: spec
    }

    :ets.insert(:evogit_sched_meta, {agent_id, meta})

    :ets.insert(
      :evogit_agent_summary,
      {agent_id,
       %AgentState{
         context_node: %ContextNode{path: "./", repo: "[system]"},
         llm_model: nil,
         max_retries: 3,
         max_depth: nil,
         parent_id: nil,
         repo_id: "primary",
         foreign_repos: [],
         mode: :interactive,
         status: :awaiting_input
       }}
    )
  end

  defp delete_interactive_root_rows(agent_id) do
    delete_row(:evogit_sched_meta, agent_id)
    delete_row(:evogit_agent_summary, agent_id)
  end

  defp delete_row(table, id) do
    if :ets.whereis(table) != :undefined, do: :ets.delete(table, id)
    :ok
  end

  defp unique_agent_id, do: @agent_id_base + System.unique_integer([:positive])
end
