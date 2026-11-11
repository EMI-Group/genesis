defmodule EvoGit.Agent.Stream.InspectionTest do
  @moduledoc """
  P4 pins for the CHEAP INSPECTION paths of the session refactor
  (`docs/agent-runtime-refactor.md` §4.6 "Inspection and streaming", §4.12
  "Roster render" / "Transcript read", and §7 invariant 1 — "one writer, one
  copy" — plus invariant 2's "the snapshot is the only resync").

  Three surfaces, one describe each:

  * (h1) **the roster is a SUMMARY read** — `RemoteAPI.list_agents/0` and
    `RemoteAPI.get_agent_state/1` answer from the `:evogit_agent_summary`
    summary rows, so they work with NO session process at all and never carry
    a conversation. §4.12's "roster render: `:ets.select` over summaries"
    instead of copying every live context.
  * (h2) **history is the SNAPSHOT path** — `RemoteAPI.get_agent_history/1` is a
    straight pass-through to `EvoGit.Agent.Session.history/2` (the session owns
    the only copy of the conversation), and it is TOTAL: a gone or
    never-registered agent answers `[]` within the documented deadline instead
    of hanging or exiting.
  * (h3) **the streaming reads are total on a nonexistent target** — the
    snapshot resync path and the watcher registration answer the documented
    `{:error, {:not_found, :session_not_found}}`, and detaching answers `:ok`.

  No mocking: every session here is a REAL `EvoGit.Agent.Session` started
  through the shared harness against a repo-less dispatch context with a
  scripted `:llm_call` engine seam, so no git repo, worktree, LLM request or
  scheduler dispatch is involved.

  ## Why `async: false`

  The FORCING GLOBAL is the roster read itself:
  `EvoGit.AgentScheduler.RemoteAPI.list_agents/0` scans the BEAM-global
  `:evogit_sched_meta` / `:evogit_agent_summary` ETS tables **table-wide**
  (`:ets.select/2` over every row, and `:ets.select([{{:"$1", :"$2"}, [], [:"$2"]}])`
  for the states), which `apps/evo_git/test/CONTEXT.md` treats as a
  serialization reason: `build_agent_summary/3` pattern-matches each row as the
  production structs, so a concurrently running module's row is observed by
  this one. Every assertion below therefore FILTERS to this test's unique agent
  id and never asserts on table size/emptiness — but a wholesale scan is still a
  table-wide read of state another module writes, so the module stays serialized
  rather than pretend otherwise.

  Everything ELSE the harness touches is per-agent: one PRODUCTION-SHAPED
  `%AgentState{}` + `%SchedMeta{}` row under a per-test unique id
  (`9_960_000 + System.unique_integer/1`) plus its temp dir, all deleted in
  `on_exit`.
  """
  use EvoGit.Agent.StreamCase, async: false

  alias EvoGit.Agent.Session
  alias EvoGit.Agent.Stream
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.RemoteAPI

  # Kept clear of every other suite's id range.
  @never_registered_id 9_969_999_999

  # ---------------------------------------------------------------------------
  # (h1) The roster is a summary read
  # ---------------------------------------------------------------------------

  describe "(h1) the roster is a summary read — no context, no session" do
    test "list_agents/0 answers for a registered agent with NO session process",
         %{agent_id: agent_id} do
      # The precondition that makes this a pin for §4.12: there is nothing for a
      # session call to answer, so a roster built from sessions would be empty.
      assert Session.whereis(agent_id) == :error

      row = roster_row(agent_id)

      assert %{} = row
      assert row.id == agent_id
    end

    test "the roster row carries NO conversation value", %{agent_id: agent_id} do
      row = roster_row(agent_id)

      # The load-bearing shape of the read model: the field is GONE, not empty.
      refute Map.has_key?(row, :context)

      # ... and, stronger than a key check, no VALUE of the row is a conversation
      # (`%ReqLLM.Context{}` or a list of `%ReqLLM.Message{}`).
      refute Enum.any?(Map.values(row), &conversation_value?/1),
             "expected no conversation in the roster row, got: #{inspect(Map.values(row))}"
    end

    test "the row's summary fields come from the installed %AgentState{}",
         %{agent_id: agent_id} do
      row = roster_row(agent_id)

      # `EvoGit.AgentScheduler.Store.put_agent_state/2` is the ONE writer of the
      # summary row (`Session.Summary.publish/3` funnels through it), and it
      # carries no conversation — so these fields ARE the registration record.
      assert row.objective == "streaming registration objective sentinel"
      assert row.message_count == 0
      assert row.total_tokens == 0
      assert row.agent_module == EvoGit.Agent.StreamCase.InteractiveAgent
      assert row.depth == 0
    end

    test "get_agent_state/1 is a summary row read too", %{agent_id: agent_id} do
      # The detail counters come from the SAME summary row: the same struct,
      # still without a `:context` field.
      assert %AgentState{} = state = RemoteAPI.get_agent_state(agent_id)

      refute Map.has_key?(state, :context)
      assert state.objective == "streaming registration objective sentinel"
    end

    test "a roster read AFTER a live session parked is still conversation-free",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: driver_llm_call(self())))

      assert_receive {:llm_call, worker, _context}, 5_000
      send(worker, {:reply, "roster text"})
      assert await_yield(pid, "roster text") == true

      row = roster_row(agent_id)

      assert %{} = row
      assert row.id == agent_id
      # The session PUBLISHES its summary fields onto the existing row...
      assert row.message_count > 0
      # ... and the row still carries no conversation: it lives in the session.
      refute Map.has_key?(row, :context)
      refute Enum.any?(Map.values(row), &conversation_value?/1)
      # `Session.Summary.publish/3` merges summary fields only — the
      # registration objective is untouched.
      assert row.objective == "streaming registration objective sentinel"
    end
  end

  # ---------------------------------------------------------------------------
  # (h2) History is the snapshot path
  # ---------------------------------------------------------------------------

  describe "(h2) history is the snapshot path — bounded, never an exit" do
    test "a live session's transcript is served identically by the RPC and the session",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: driver_llm_call(self())))

      assert_receive {:llm_call, worker, _context}, 5_000
      send(worker, {:reply, "history text"})
      assert await_yield(pid, "history text") == true

      messages = RemoteAPI.get_agent_history(agent_id)

      assert is_list(messages)
      assert length(messages) == 3
      assert hd(messages).role == :system

      middle = Enum.at(messages, 1)
      assert middle.role == :user
      assert text_of(middle) =~ "streaming session test objective"

      assert List.last(messages).role == :assistant
      assert text_of(List.last(messages)) == "history text"

      # The RPC is a STRAIGHT pass-through — identical terms, no re-projection.
      assert messages == Session.history(pid)
    end

    test "a gone session answers [] within the bounded deadline",
         %{agent_id: agent_id, tmp_dir: tmp_dir} do
      {:ok, pid, _ref} =
        start_session(dispatch_ctx(agent_id, tmp_dir, llm_call: driver_llm_call(self())))

      assert_receive {:llm_call, worker, _context}, 5_000
      send(worker, {:reply, "gone text"})
      assert await_yield(pid, "gone text") == true

      assert :ok = Session.cancel(pid, :force)
      assert wait_until(fn -> Session.whereis(agent_id) == :error end) == true

      # Bounded: the documented deadline is 5 s, so a 6 s await proves "bounded,
      # never an exit" (a hang flunks instead of wedging the suite).
      assert bounded_history(agent_id) == []
    end

    test "a never-registered agent id answers [] and never exits", %{agent_id: agent_id} do
      refute agent_id == @never_registered_id
      assert Session.whereis(@never_registered_id) == :error

      assert bounded_history(@never_registered_id) == []
      # TOTAL by construction, not by rescue: the same call shape the RPC uses.
      assert Session.history(@never_registered_id) == []
    end
  end

  # ---------------------------------------------------------------------------
  # (h3) Streaming reads are total on a nonexistent target
  # ---------------------------------------------------------------------------

  describe "(h3) streaming reads on a nonexistent target are total" do
    test "snapshot/watch answer :not_found and unwatch answers :ok", %{agent_id: agent_id} do
      refute agent_id == @never_registered_id
      assert Session.whereis(@never_registered_id) == :error

      # The snapshot is the ONLY resync path, so its absence must be a value.
      assert Stream.snapshot(@never_registered_id) == {:error, {:not_found, :session_not_found}}
      assert Stream.watch(@never_registered_id) == {:error, {:not_found, :session_not_found}}
      # Detaching is idempotent and TOTAL, even for a target that never existed.
      assert Stream.unwatch(@never_registered_id) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Table-wide scan (that is the point of the pin) narrowed to THIS test's id.
  defp roster_row(agent_id) do
    Enum.find(RemoteAPI.list_agents(), &(&1.id == agent_id))
  end

  # A conversation-shaped VALUE: a context or a list of messages. The empty list
  # is not a conversation (several summary fields are lists).
  defp conversation_value?(%ReqLLM.Context{}), do: true
  defp conversation_value?(%ReqLLM.Message{}), do: true

  defp conversation_value?([_ | _] = list),
    do: Enum.all?(list, &match?(%ReqLLM.Message{}, &1))

  defp conversation_value?(_other), do: false

  # A deliberately bounded RPC call: a wedged read flunks the test at the
  # timeout instead of hanging the run.
  defp bounded_history(agent_id, budget \\ 6_000) do
    task = Task.async(fn -> RemoteAPI.get_agent_history(agent_id) end)
    Task.await(task, budget)
  end
end
