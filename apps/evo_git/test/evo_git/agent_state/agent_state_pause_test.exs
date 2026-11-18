defmodule EvoGit.AgentState.PauseTest do
  @moduledoc """
  Coverage for the durable facts a TASK-LEVEL PAUSE writes into the agent-state
  store: `agent_states.pause_commit` (the paused worktree checkpoint sha) plus
  the roster read a resume uses (`pause_commit/2,3`) and `flush/1`'s synchronous
  durability barrier.

  Every test starts its OWN unnamed `EvoGit.AgentState` server on its own temp
  SQLite file and addresses it explicitly through the `store:` option, so the
  app-global `EvoGit.AgentState.Server` is never touched — hence `async: true`.
  Checkpoints are CASTS, so every read-backed assertion follows
  `EvoGit.AgentState.flush/1`; there is no `Process.sleep`.

  The pause writes are asserted through a DIRECT `SELECT` as well as the API:
  a `pause_commit` write that secretly rewrote the scalar row or the chunks
  would pass an API-only test.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentState
  alias EvoGit.Store.RepoScope
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @moduletag :tmp_dir

  @sha "6f1c0d9b2a4e8f7c3d5b1a9e0c2f4d6b8a0e1c3d5f7a9b1d3e5f7a9c1b3d5e7f"
  @other_sha "0000000000000000000000000000000000000000"

  ## Isolation helpers

  defp start_store!(tmp_dir, opts \\ []) do
    start_supervised!(
      {AgentState,
       Keyword.merge(
         [
           database: Path.join(tmp_dir, "agent_state.sqlite"),
           name: nil,
           prune_interval: 3_600_000
         ],
         opts
       )}
    )
  end

  defp checkpoint!(pid, task_id, agent_id, entry) do
    :ok = AgentState.checkpoint(task_id, agent_id, entry, store: pid)
    :ok = AgentState.flush(store: pid)
  end

  # The isolated instance pid is a SUPERVISOR pid; its writer is the one child.
  defp server_pid(supervisor) do
    case Supervisor.which_children(supervisor) do
      [{EvoGit.AgentState.Server, pid, :worker, _modules}] when is_pid(pid) -> pid
      other -> flunk("unexpected agent-state children: #{inspect(other)}")
    end
  end

  defp rewrite(messages, fields), do: %{kind: :rewrite, messages: messages, fields: fields}

  defp sql!(pid, sql, params) do
    repo = AgentState.repo(pid)
    assert is_pid(repo), "the isolated agent-state server has no repo pid"

    RepoScope.with_repo(repo, fn ->
      {:ok, result} = Ecto.Adapters.SQL.query(EvoGit.Repo.get_dynamic_repo(), sql, params)
      result
    end)
  end

  defp counts!(pid, task_id, agent_id) do
    sql!(
      pid,
      "SELECT message_count, chunk_count FROM agent_states WHERE task_id = ? AND agent_id = ?",
      [task_id, agent_id]
    ).rows
  end

  defp chunk_count!(pid, task_id, agent_id) do
    [[count]] =
      sql!(
        pid,
        "SELECT count(*) FROM agent_state_chunks WHERE task_id = ? AND agent_id = ?",
        [task_id, agent_id]
      ).rows

    count
  end

  defp message(text) do
    %Message{role: :assistant, content: [ContentPart.text(text)]}
  end

  defp absent_store do
    :"evogit_agent_state_absent_#{System.unique_integer([:positive])}"
  end

  ## put_pause_commit / pause_commit

  describe "pause_commit" do
    test "round-trips, a second put replaces it and nil clears it", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_pause_roundtrip"
      agent_id = 1

      checkpoint!(pid, task_id, agent_id, rewrite([message("working")], %{objective: "pause me"}))

      # Nothing paused yet: an existing row with no marker reads nil.
      assert AgentState.pause_commit(task_id, agent_id, store: pid) == nil

      assert :ok = AgentState.put_pause_commit(task_id, agent_id, @sha, store: pid)
      assert AgentState.pause_commit(task_id, agent_id, store: pid) == @sha

      # The row itself holds it — a write that only touched an in-memory cache
      # would fail here.
      assert sql!(
               pid,
               "SELECT pause_commit FROM agent_states WHERE task_id = ? AND agent_id = ?",
               [task_id, agent_id]
             ).rows == [[@sha]]

      assert :ok = AgentState.put_pause_commit(task_id, agent_id, @other_sha, store: pid)
      assert AgentState.pause_commit(task_id, agent_id, store: pid) == @other_sha

      assert :ok = AgentState.put_pause_commit(task_id, agent_id, nil, store: pid)
      assert AgentState.pause_commit(task_id, agent_id, store: pid) == nil

      assert sql!(
               pid,
               "SELECT pause_commit FROM agent_states WHERE task_id = ? AND agent_id = ?",
               [task_id, agent_id]
             ).rows == [[nil]]
    end

    test "a missing row answers {:error, :not_found} and reads nil", %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)

      assert {:error, :not_found} =
               AgentState.put_pause_commit("task_absent_row", 9, @sha, store: pid)

      # A pause marker NEVER creates a row: that would fabricate an empty
      # conversation for a run that never checkpointed.
      assert AgentState.pause_commit("task_absent_row", 9, store: pid) == nil
      assert {:error, :not_found} = AgentState.load("task_absent_row", 9, store: pid)
      assert sql!(pid, "SELECT count(*) FROM agent_states", []).rows == [[0]]
    end

    test "touches ONLY pause_commit: counts, chunks and append continuity are untouched",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_pause_isolated"
      agent_id = 1

      checkpoint!(pid, task_id, agent_id, rewrite([message("one")], %{phase: "working"}))

      assert counts!(pid, task_id, agent_id) == [[1, 1]]
      assert chunk_count!(pid, task_id, agent_id) == 1

      assert :ok = AgentState.put_pause_commit(task_id, agent_id, @sha, store: pid)
      assert :ok = AgentState.flush(store: pid)

      # No conversation write happened: counts, chunk rows and the scalar row
      # are exactly as the last checkpoint left them.
      assert counts!(pid, task_id, agent_id) == [[1, 1]]
      assert chunk_count!(pid, task_id, agent_id) == 1

      assert {:ok, record} = AgentState.load(task_id, agent_id, store: pid)
      assert record.messages == [message("one")]
      assert record.fields[:phase] == "working"
      assert record.fields[:pause_commit] == @sha

      # The continuity rule was not disturbed: an append at the pre-pause
      # baseline is still accepted and the marker survives it.
      assert :ok =
               AgentState.checkpoint(
                 task_id,
                 agent_id,
                 %{kind: :append, base_seq: 1, messages: [message("two")], fields: %{}},
                 store: pid
               )

      assert :ok = AgentState.flush(store: pid)

      assert {:ok, record} = AgentState.load(task_id, agent_id, store: pid)
      assert record.messages == [message("one"), message("two")]
      assert record.message_count == 2
      assert record.chunk_count == 2
      assert record.fields[:pause_commit] == @sha
    end

    test "is inert without a store", %{tmp_dir: tmp_dir} do
      absent = absent_store()
      assert Process.whereis(absent) == nil

      assert {:error, :not_persistent_state_disabled} =
               AgentState.put_pause_commit("task-inert", 1, @sha, store: absent)

      assert AgentState.pause_commit("task-inert", 1, store: absent) == nil
      # An absent writer is NOT a durability barrier: it honestly answers the
      # non-durable shape instead of a false `:ok`.
      assert {:error, :timeout} = AgentState.flush(store: absent)
      assert :ok = AgentState.flush(1)

      # Sanity: the same calls work through a live store, so the assertions
      # above pin the inert shape rather than an unusable API.
      pid = start_store!(tmp_dir)
      checkpoint!(pid, "task-inert", 1, rewrite([message("hi")], %{}))
      assert :ok = AgentState.put_pause_commit("task-inert", 1, @sha, store: pid)
    end
  end

  ## flush/1 — the durability barrier

  describe "flush" do
    test "is a synchronous barrier: a just-cast checkpoint is durable when it returns",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_flush"
      agent_id = 3

      # The WRITER answers the barrier synchronously (it is a GenServer.call,
      # never a cast): this is the structural pin on "`:ok` means durable".
      server = server_pid(pid)
      assert GenServer.call(server, :sync, 1_000) == :ok

      # A cast checkpoint followed immediately by the barrier: after it returns
      # a FRESH load must see the message, with no sleeping and no retry.
      :ok =
        AgentState.checkpoint(
          task_id,
          agent_id,
          rewrite([message("durable")], %{phase: "paused"}),
          store: pid
        )

      # An AGENT ID is accepted (the pause path holds one): the single
      # serialized writer makes it the same barrier.
      Process.put(:evogit_agent_state_server, server)
      on_exit(fn -> Process.delete(:evogit_agent_state_server) end)

      assert :ok = AgentState.flush(agent_id)

      assert {:ok, record} = AgentState.load(task_id, agent_id, store: pid)
      assert record.messages == [message("durable")]
      assert record.fields[:phase] == "paused"

      # The barrier also covers a pause-marker write queued right before it.
      assert :ok = AgentState.put_pause_commit(task_id, agent_id, @sha, store: pid)
      assert :ok = AgentState.flush(store: pid)
      assert AgentState.pause_commit(task_id, agent_id, store: pid) == @sha
    end

    test "several pending checkpoints are all durable when the barrier returns",
         %{tmp_dir: tmp_dir} do
      pid = start_store!(tmp_dir)
      task_id = "task_flush_many"
      agent_id = 1

      :ok = AgentState.checkpoint(task_id, agent_id, rewrite([message("m0")], %{}), store: pid)

      for index <- 1..5 do
        :ok =
          AgentState.checkpoint(
            task_id,
            agent_id,
            %{
              kind: :append,
              base_seq: index,
              messages: [message("m#{index}")],
              fields: %{turn: index}
            },
            store: pid
          )
      end

      # The pause path knows only the agent id, so the store it is talking to
      # comes from the process-dictionary seam (production: the named default).
      Process.put(:evogit_agent_state_server, server_pid(pid))
      on_exit(fn -> Process.delete(:evogit_agent_state_server) end)

      assert :ok = AgentState.flush(agent_id)

      assert {:ok, record} = AgentState.load(task_id, agent_id, store: pid)
      assert record.messages == Enum.map(0..5, fn index -> message("m#{index}") end)
      assert record.message_count == 6
      # The checkpoints were still QUEUED when the barrier reached the writer, so
      # the writer folds them: ONE chunk (the initial rewrite was not committed
      # yet, so the whole burst became a single rewrite) or TWO (the rewrite was
      # committed, the five appends then folded into one) — never one per
      # checkpoint. The barrier promises every MESSAGE is durable, not one row.
      assert record.chunk_count in [1, 2]
      assert record.fields[:turn] == 5
    end
  end
end
