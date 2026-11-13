defmodule EvoGit.AgentStateRetentionTest do
  @moduledoc """
  RETENTION + DELETE coverage for the durable agent-state store: `mark_completed`
  keeps the row and stamps `status`/`completed_at`, `prune/1` deletes exactly the
  expired runs (with their chunks), a recently-touched row is never pruned, and
  `delete/3` / `delete_task/2` remove one run / every run of a task.

  Every case uses its OWN isolated `EvoGit.AgentState` instance started with an
  EXPLICIT `retention_days: 7` start option (never an app-env mutation, so the
  module stays `async: true`) on a per-test SQLite file, addressed through
  `store: pid`. Checkpoints are CASTS: every read/SQL assertion is preceded by
  `EvoGit.AgentState.flush/1`, while `mark_completed`/`delete`/`delete_task`/
  `prune` are synchronous calls.

  Expiry is produced by BACKDATING the stored ISO8601 timestamps through the
  store's own dynamic repo — no clock seam, no sleeping.
  """

  use ExUnit.Case, async: true

  alias EvoGit.AgentState
  alias EvoGit.AgentState.Record
  alias EvoGit.Store.RepoScope

  @moduletag :tmp_dir

  @retention_days 7

  ## Isolation helpers (duplicated per file on purpose: no shared support module)

  defp start_store!(tmp_dir, opts) do
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

  defp count_rows!(pid, task_id) do
    assert %{rows: [[n]]} =
             sql!(pid, "SELECT COUNT(*) FROM agent_states WHERE task_id = ?", [task_id])

    n
  end

  ## Backdating helpers

  defp days_ago(days) do
    DateTime.utc_now()
    |> DateTime.add(-days * 86_400, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  # A completed run that finished `days` ago and has not been touched since.
  defp backdate_completed!(pid, task_id, agent_id, days) do
    stamp = days_ago(days)

    assert %{num_rows: 1} =
             sql!(
               pid,
               "UPDATE agent_states SET completed_at = ?, updated_at = ? " <>
                 "WHERE task_id = ? AND agent_id = ?",
               [stamp, stamp, task_id, agent_id]
             )
  end

  # A completed run whose completion is OLD but which was touched just now.
  defp backdate_completed_only!(pid, task_id, agent_id, days) do
    assert %{num_rows: 1} =
             sql!(
               pid,
               "UPDATE agent_states SET completed_at = ? WHERE task_id = ? AND agent_id = ?",
               [days_ago(days), task_id, agent_id]
             )
  end

  # A run that never completed (crash/abandon) whose last write is `days` old.
  defp backdate_updated!(pid, task_id, agent_id, days) do
    assert %{num_rows: 1} =
             sql!(
               pid,
               "UPDATE agent_states SET updated_at = ? WHERE task_id = ? AND agent_id = ?",
               [days_ago(days), task_id, agent_id]
             )
  end

  ## Message fixtures

  defp message(text),
    do: %ReqLLM.Message{
      role: :user,
      content: [ReqLLM.Message.ContentPart.text(text)]
    }

  defp rewrite(messages),
    do: %{kind: :rewrite, messages: messages, fields: %{status: "running"}}

  ## 1. mark_completed/3

  test "mark_completed/3 stamps status + completed_at and keeps messages and counts",
       %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir, retention_days: @retention_days)
    messages = [message("one"), message("two")]
    checkpoint!(pid, "task-a", 1, rewrite(messages))

    assert {:ok, %Record{} = before} = AgentState.load("task-a", 1, store: pid)
    # The migration default for a live run.
    assert before.fields[:status] == "running"
    assert before.completed_at == nil
    assert before.message_count == 2
    assert before.chunk_count == 1

    assert :ok = AgentState.mark_completed("task-a", 1, store: pid)

    assert {:ok, %Record{} = completed} = AgentState.load("task-a", 1, store: pid)
    assert completed.fields[:status] == "completed"
    assert %DateTime{} = completed.completed_at
    assert DateTime.compare(completed.completed_at, DateTime.utc_now()) == :lt

    # The row is KEPT for later recovery, conversation included.
    assert completed.task_id == "task-a"
    assert completed.agent_id == 1
    assert completed.messages == messages
    assert completed.message_count == 2
    assert completed.chunk_count == 1
    assert count_chunks!(pid, "task-a", 1) == 1
  end

  ## 2. prune/1 deletes exactly the expired runs

  test "prune/1 deletes only expired runs, with their chunks", %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir, retention_days: @retention_days)

    for {task_id, agent_id} <- [{"task-a", 1}, {"task-a", 2}, {"task-b", 1}, {"task-b", 2}] do
      checkpoint!(pid, task_id, agent_id, rewrite([message("#{task_id}/#{agent_id}")]))
    end

    # `task-a`'s two runs COMPLETE; `task-b`'s two never do (crash/abandon).
    assert :ok = AgentState.mark_completed("task-a", 1, store: pid)
    assert :ok = AgentState.mark_completed("task-a", 2, store: pid)

    # Expired: completed 10 days ago, untouched since.
    backdate_completed!(pid, "task-a", 1, 10)
    # Kept: completed now.
    # Expired: never completed, last write 20 days ago (past 2 × 7 days).
    backdate_updated!(pid, "task-b", 1, 20)
    # Kept: never completed, touched now.

    assert {:ok, 2} = AgentState.prune(store: pid)

    assert {:error, :not_found} = AgentState.load("task-a", 1, store: pid)
    assert {:error, :not_found} = AgentState.load("task-b", 1, store: pid)
    assert {:ok, %Record{}} = AgentState.load("task-a", 2, store: pid)
    assert {:ok, %Record{}} = AgentState.load("task-b", 2, store: pid)

    # Chunks are deleted explicitly (no foreign key), per (task_id, agent_id).
    assert count_chunks!(pid, "task-a", 1) == 0
    assert count_chunks!(pid, "task-b", 1) == 0
    assert count_chunks!(pid, "task-a", 2) == 1
    assert count_chunks!(pid, "task-b", 2) == 1

    assert count_rows!(pid, "task-a") == 1
    assert count_rows!(pid, "task-b") == 1
  end

  ## 3. A recently-touched row is never pruned

  test "a row touched inside the window is kept even when completed long ago",
       %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir, retention_days: @retention_days)
    checkpoint!(pid, "task-a", 1, rewrite([message("recent")]))
    assert :ok = AgentState.mark_completed("task-a", 1, store: pid)

    # Old completion, but `updated_at` is NOW: the prune SQL additionally
    # requires `updated_at < completed_before`.
    backdate_completed_only!(pid, "task-a", 1, 10)

    assert {:ok, 0} = AgentState.prune(store: pid)
    assert {:ok, %Record{} = record} = AgentState.load("task-a", 1, store: pid)
    assert record.fields[:status] == "completed"
    assert record.messages == [message("recent")]
    assert count_chunks!(pid, "task-a", 1) == 1
  end

  ## 4. prune/1 is idempotent

  test "a second prune returns {:ok, 0}", %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir, retention_days: @retention_days)
    checkpoint!(pid, "task-a", 1, rewrite([message("expired")]))
    assert :ok = AgentState.mark_completed("task-a", 1, store: pid)
    backdate_completed!(pid, "task-a", 1, 10)

    assert {:ok, 1} = AgentState.prune(store: pid)
    assert {:ok, 0} = AgentState.prune(store: pid)
    assert {:error, :not_found} = AgentState.load("task-a", 1, store: pid)
  end

  ## 5. delete/3

  test "delete/3 removes one run's row and chunks, leaving its siblings alone",
       %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir, retention_days: @retention_days)
    checkpoint!(pid, "task-a", 1, rewrite([message("a1")]))
    checkpoint!(pid, "task-a", 2, rewrite([message("a2")]))
    checkpoint!(pid, "task-b", 1, rewrite([message("b1")]))

    assert :ok = AgentState.delete("task-a", 1, store: pid)

    assert {:error, :not_found} = AgentState.load("task-a", 1, store: pid)
    assert count_chunks!(pid, "task-a", 1) == 0

    assert {:ok, %Record{messages: [%ReqLLM.Message{}]}} =
             AgentState.load("task-a", 2, store: pid)

    assert count_chunks!(pid, "task-a", 2) == 1
    assert {:ok, %Record{}} = AgentState.load("task-b", 1, store: pid)
    assert count_chunks!(pid, "task-b", 1) == 1

    # Total: deleting an absent run is still `:ok`.
    assert :ok = AgentState.delete("task-a", 1, store: pid)
    assert :ok = AgentState.delete("never-seen", 9, store: pid)
  end

  ## 6. delete_task/2

  test "delete_task/2 removes every run of one task and all its chunks",
       %{tmp_dir: tmp_dir} do
    pid = start_store!(tmp_dir, retention_days: @retention_days)
    checkpoint!(pid, "task-a", 1, rewrite([message("a1"), message("a1b")]))
    checkpoint!(pid, "task-a", 2, rewrite([message("a2")]))
    checkpoint!(pid, "task-b", 1, rewrite([message("b1")]))

    assert :ok = AgentState.delete_task("task-a", store: pid)

    assert {:error, :not_found} = AgentState.load("task-a", 1, store: pid)
    assert {:error, :not_found} = AgentState.load("task-a", 2, store: pid)
    assert count_chunks!(pid, "task-a", 1) == 0
    assert count_chunks!(pid, "task-a", 2) == 0
    assert count_rows!(pid, "task-a") == 0

    assert {:ok, %Record{}} = AgentState.load("task-b", 1, store: pid)
    assert count_chunks!(pid, "task-b", 1) == 1
    assert count_rows!(pid, "task-b") == 1

    # Total: deleting an absent task is still `:ok`.
    assert :ok = AgentState.delete_task("never-seen", store: pid)
  end
end
