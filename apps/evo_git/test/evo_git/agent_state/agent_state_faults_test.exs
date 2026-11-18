defmodule EvoGit.AgentStateFaultsTest do
  @moduledoc """
  FAULT-path coverage for the durable agent-state store: a missing run, a
  corrupt payload blob, disagreeing message/chunk counts, a STOPPED server, the
  `server/0` process-dictionary seam and malformed checkpoint entries.

  Every case uses its OWN isolated `EvoGit.AgentState` instance (unnamed, on a
  per-test SQLite file, with the hourly prune timer parked) and addresses it
  through `store: pid`, so the app-booted `EvoGit.AgentState.Server` singleton is
  never read or written. Checkpoints are CASTS, so every read/SQL assertion is
  preceded by `EvoGit.AgentState.flush/1` — the documented read-your-writes
  barrier.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.AgentState
  alias EvoGit.AgentState.Record
  alias EvoGit.Store.RepoScope

  @moduletag :tmp_dir

  ## Isolation helpers (duplicated per file on purpose: no shared support module)

  defp start_store!(tmp_dir, opts \\ []) do
    start_supervised!(
      {EvoGit.AgentState,
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

  # A test that must STOP its server needs a `:temporary` child, otherwise the
  # test supervisor restarts it and the "dead server" assertions race.
  defp start_stoppable_store!(tmp_dir) do
    start_supervised!(
      Supervisor.child_spec(
        {EvoGit.AgentState,
         database: Path.join(tmp_dir, "agent_state.sqlite"), name: nil, prune_interval: 3_600_000},
        id: {:agent_state, System.unique_integer([:positive])},
        restart: :temporary
      )
    )
  end

  defp checkpoint!(pid, task_id, agent_id, entry) do
    :ok = EvoGit.AgentState.checkpoint(task_id, agent_id, entry, store: pid)
    :ok = EvoGit.AgentState.flush(store: pid)
  end

  defp sql!(pid, sql, params) do
    repo = EvoGit.AgentState.repo(pid)

    RepoScope.with_repo(repo, fn ->
      {:ok, result} = Ecto.Adapters.SQL.query(EvoGit.Repo.get_dynamic_repo(), sql, params)
      result
    end)
  end

  defp count_chunks!(pid, task_id, agent_id) do
    assert %{rows: [[n]]} =
             sql!(
               pid,
               "SELECT COUNT(*) FROM agent_state_chunks WHERE task_id = ? AND agent_id = ?",
               [task_id, agent_id]
             )

    n
  end

  ## Message fixtures

  defp message(text),
    do: %ReqLLM.Message{
      role: :user,
      content: [ReqLLM.Message.ContentPart.text(text)]
    }

  defp assistant_message(text) do
    %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: [ReqLLM.ToolCall.new("call_1", "read", "{}")]
    }
  end

  defp rewrite(messages, fields \\ %{}),
    do: %{kind: :rewrite, messages: messages, fields: Map.put(fields, :status, "running")}

  ## 1. Unknown run

  test "load on a run with no row at all answers {:error, :not_found}", %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir)

    assert is_pid(AgentState.repo(pid))
    assert {:error, :not_found} = AgentState.load("unknown-task", 42, store: pid)
  end

  ## 2. Corrupt payload blob

  test "a corrupt payload blob answers {:error, :corrupt_state} without crashing",
       %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir)
    checkpoint!(pid, "task-a", 1, rewrite([message("one"), assistant_message("two")]))
    assert {:ok, _record} = AgentState.load("task-a", 1, store: pid)

    assert %{num_rows: 1} =
             sql!(
               pid,
               "UPDATE agent_state_chunks SET payload = ? " <>
                 "WHERE task_id = ? AND agent_id = ? AND seq = 0",
               [<<1, 2, 3>>, "task-a", 1]
             )

    assert {:error, :corrupt_state} = AgentState.load("task-a", 1, store: pid)
    assert Process.alive?(pid)
  end

  ## 3. Chunk message_count disagrees with its payload

  test "a chunk whose message_count disagrees with its payload is :corrupt_state",
       %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir)
    checkpoint!(pid, "task-a", 1, rewrite([message("one"), assistant_message("two")]))
    assert {:ok, _record} = AgentState.load("task-a", 1, store: pid)

    assert %{num_rows: 1} =
             sql!(
               pid,
               "UPDATE agent_state_chunks SET message_count = 99 WHERE task_id = ? AND agent_id = ?",
               ["task-a", 1]
             )

    assert {:error, :corrupt_state} = AgentState.load("task-a", 1, store: pid)
    assert Process.alive?(pid)
  end

  ## 4. Row message_count / chunk_count disagree with the chunks

  test "a row message_count that disagrees with the chunks is :corrupt_state",
       %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir)
    checkpoint!(pid, "task-a", 1, rewrite([message("one"), assistant_message("two")]))
    assert {:ok, _record} = AgentState.load("task-a", 1, store: pid)

    assert %{num_rows: 1} =
             sql!(
               pid,
               "UPDATE agent_states SET message_count = 99 WHERE task_id = ? AND agent_id = ?",
               [
                 "task-a",
                 1
               ]
             )

    assert {:error, :corrupt_state} = AgentState.load("task-a", 1, store: pid)
    assert Process.alive?(pid)
  end

  test "a row chunk_count that disagrees with the chunk rows is :corrupt_state",
       %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir)
    checkpoint!(pid, "task-a", 1, rewrite([message("one"), assistant_message("two")]))
    assert {:ok, _record} = AgentState.load("task-a", 1, store: pid)
    assert count_chunks!(pid, "task-a", 1) == 1

    assert %{num_rows: 1} =
             sql!(
               pid,
               "UPDATE agent_states SET chunk_count = 5 WHERE task_id = ? AND agent_id = ?",
               [
                 "task-a",
                 1
               ]
             )

    assert {:error, :corrupt_state} = AgentState.load("task-a", 1, store: pid)
    assert Process.alive?(pid)
  end

  ## 5. Stopped server

  test "a stopped server answers {:error, :store_unavailable} and every mutation stays total",
       %{tmp_dir: tmp_dir} do
    pid = start_stoppable_store!(tmp_dir)
    checkpoint!(pid, "task-a", 1, rewrite([message("one")]))
    assert {:ok, _record} = AgentState.load("task-a", 1, store: pid)

    # `GenServer.stop/1` is synchronous and runs `terminate/2`, which erases the
    # published repo pid.
    assert :ok = GenServer.stop(pid)
    refute Process.alive?(pid)

    assert AgentState.repo(pid) == nil
    assert {:error, :store_unavailable} = AgentState.load("task-a", 1, store: pid)

    # A cast to a dead pid is total...
    assert :ok = AgentState.checkpoint("task-a", 1, rewrite([message("two")]), store: pid)

    # ...but the barrier is HONEST: a dead writer cannot be claimed durable.
    assert {:error, :timeout} = AgentState.flush(store: pid)

    # ...and every call is total: the guarded `GenServer.call/3` contains the exit.
    assert :ok = AgentState.mark_completed("task-a", 1, store: pid)
    assert :ok = AgentState.delete("task-a", 1, store: pid)
    assert :ok = AgentState.delete_task("task-a", store: pid)
    assert {:ok, 0} = AgentState.prune(store: pid)
  end

  ## 6. server/0 process-dictionary seam

  test "server/0 honours the process-dictionary seam and [] opts resolve to it",
       %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir)
    on_exit(fn -> Process.delete(:evogit_agent_state_server) end)

    Process.put(:evogit_agent_state_server, pid)
    assert AgentState.server() == pid

    # No `store:` opt at all: every function resolves through `server/0`.
    assert :ok = AgentState.checkpoint("task-seam", 7, rewrite([message("seam")]))
    assert :ok = AgentState.flush()
    assert {:ok, record} = AgentState.load("task-seam", 7)
    assert record.messages == [message("seam")]

    # `store: nil` means "resolve server/0" (NOT "no store"), so it reaches the
    # seam-bound instance rather than the app-global default.
    assert :ok = AgentState.checkpoint("task-seam", 8, rewrite([message("via nil")]), store: nil)
    assert :ok = AgentState.flush(store: nil)
    assert {:ok, record} = AgentState.load("task-seam", 8, store: nil)
    assert record.messages == [message("via nil")]
    assert count_chunks!(pid, "task-seam", 8) == 1
  end

  test "server/0 with no seam falls back to the named default", %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir)
    Process.delete(:evogit_agent_state_server)

    # `nil` requires NEITHER the seam NOR a live named default. In `:test` the
    # application boots `EvoGit.AgentState.Server`, so the honest fallback here
    # is that live pid — a test may never stop the app-global to force `nil`.
    default = Process.whereis(EvoGit.AgentState.Server)
    assert is_pid(default)
    assert AgentState.server() == default
    refute AgentState.server() == pid
  end

  ## 7. No server at all is a no-op

  test "an absent server target keeps every function total" do
    # The absent target is an UNREGISTERED NAME: `store: nil` would resolve
    # through `server/0` to the app-booted default, and this suite never touches
    # it. A name is exactly the dead-target shape a caller can hit in
    # production (server restarting), and both the cast and the guarded call are
    # documented total for it.
    absent = :"evogit_agent_state_absent_#{System.unique_integer([:positive])}"

    assert Process.whereis(absent) == nil
    assert AgentState.repo(absent) == nil

    assert :ok = AgentState.checkpoint("task-z", 1, rewrite([message("one")]), store: absent)
    # An unregistered NAME is a dead writer, not "nothing to flush".
    assert {:error, :timeout} = AgentState.flush(store: absent)
    assert {:error, :store_unavailable} = AgentState.load("task-z", 1, store: absent)
    assert :ok = AgentState.mark_completed("task-z", 1, store: absent)
    assert :ok = AgentState.delete("task-z", 1, store: absent)
    assert :ok = AgentState.delete_task("task-z", store: absent)
    assert {:ok, 0} = AgentState.prune(store: absent)
  end

  ## 8. Malformed checkpoint entries are dropped, never fatal

  test "malformed checkpoint entries are dropped and leave the stored state untouched",
       %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir)
    checkpoint!(pid, "task-a", 1, rewrite([message("kept")]))

    assert {:ok, %Record{messages: [%ReqLLM.Message{}] = kept}} =
             AgentState.load("task-a", 1, store: pid)

    # The server logs one warning per dropped entry; capture it so the suite
    # stays quiet (capture_log is process-scoped, so this is async-safe).
    capture_log(fn ->
      for entry <- [
            %{kind: :bogus, messages: []},
            %{kind: :append, messages: ["not a message"]},
            %{kind: :append, base_seq: -1, messages: [message("negative base")]},
            %{kind: :append, messages: [message("bad fields")], fields: "not a map"}
          ] do
        assert :ok = AgentState.checkpoint("task-a", 1, entry, store: pid)
        assert :ok = AgentState.checkpoint("task-b", 2, entry, store: pid)
      end

      assert :ok = AgentState.flush(store: pid)
    end)

    # The valid run is unchanged (not truncated, not rewritten)...
    assert {:ok, %Record{} = record} = AgentState.load("task-a", 1, store: pid)
    assert record.messages == kept
    assert record.message_count == 1

    # ...and a run that only ever saw malformed entries has no row at all.
    assert {:error, :not_found} = AgentState.load("task-b", 2, store: pid)
    assert Process.alive?(pid)
  end
end
