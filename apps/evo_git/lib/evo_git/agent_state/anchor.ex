defmodule EvoGit.AgentState.Anchor do
  @moduledoc """
  The git-durability anchor that keeps an agent run's commits reachable after
  its worktree is reclaimed.

  A branch inside `.genesis/workers/` is NOT durability: the first worktree
  create after a BEAM restart wipes the workers directory and every
  `evogit-agent-*` branch, and an unanchored commit then becomes gc-eligible.
  So at every turn-boundary checkpoint the session anchors its
  `current_commit` at

      refs/genesis/agent-state/<task_id>/<agent_id>

  ## Why the ref survives reclamation

  `refs/genesis/agent-state/*` is a plain ref in the repository's git dir, not a
  branch and not under `refs/heads/`:

    * `EvoGit.AgentScheduler.WorktreeManager.clean_orphaned_branches/1` only
      deletes branches matching `evogit-agent-*` (it lists them through
      `EvoGit.Adapters.Git.list_branches/2`, which reads `refs/heads`), so it
      cannot see or delete an agent-state ref;
    * `destroy_worktree/3` deletes the agent's BRANCH
      (`EvoGit.AgentScheduler.Worktrees.delete_branch_tolerant/2`) and prunes the
      worktree registry — neither touches `refs/genesis/…`;
    * nothing in the Elixir code runs `git gc`/`git prune` (only
      `git worktree prune`, which drops administrative worktree metadata), so
      the anchor stays the reason the commit is reachable when the eventual
      `git gc` runs.

  ## Fire and forget, deduped per caller

  `anchor/4` never runs a `git` subprocess on the caller's path and never
  raises or exits into the caller: it records the sha in the CALLER's process
  dictionary and hands ONE `EvoGit.Adapters.Git.update_ref/3` to a supervised,
  UNLINKED `EvoGit.TaskSupervisor` child. The process-dictionary entry doubles
  as the dedupe: an unchanged commit writes nothing, so a turn-boundary
  checkpoint that did not produce a new commit costs one map lookup. A failed
  write is logged at debug level (never warn-spam) — a lost anchor degrades
  durability, it does not break the run.
  """

  require Logger

  alias EvoGit.Adapters.Git

  @ref_prefix "refs/genesis/agent-state/"
  @pdict_key :evogit_agent_state_anchor

  @doc """
  The anchor ref name for a run: `refs/genesis/agent-state/<task_id>/<agent_id>`.

  Total: both identifiers are stringified (a term that cannot be stringified is
  inspected instead), so this never raises.
  """
  @spec ref(term(), term()) :: String.t()
  def ref(task_id, agent_id) do
    @ref_prefix <> stringify(task_id) <> "/" <> stringify(agent_id)
  end

  @doc """
  Anchors `sha` at `ref/2` for `(task_id, agent_id)` in `repo_path`.

  Fire-and-forget: returns `:ok` immediately. The `git update-ref` runs in a
  supervised unlinked task, so it can never block, raise or exit into the
  caller. A `nil`/non-binary (or blank) `repo_path` or `sha` is a no-op — a
  repo-less agent has no repository to anchor into — and re-anchoring the SAME
  sha from the same process is deduped through the caller's process dictionary
  (see `last_anchored/3`).
  """
  @spec anchor(term(), term(), term(), term()) :: :ok
  def anchor(repo_path, task_id, agent_id, sha) when is_binary(repo_path) and is_binary(sha) do
    if repo_path == "" or sha == "" do
      :ok
    else
      key = key(repo_path, task_id, agent_id)

      case Process.get(key) do
        ^sha ->
          # Already anchored from this process: write nothing.
          :ok

        _other ->
          # Record BEFORE dispatching, so two checkpoints in the same turn
          # never race two writes for an unchanged commit.
          Process.put(key, sha)
          dispatch_write(repo_path, ref(task_id, agent_id), sha)
      end
    end
  end

  def anchor(_repo_path, _task_id, _agent_id, _sha), do: :ok

  @doc false
  # The last sha this PROCESS anchored for `(repo_path, task_id, agent_id)`, or
  # `nil`. Exists for tests asserting the dedupe; production callers never
  # need it.
  @spec last_anchored(term(), term(), term()) :: term()
  def last_anchored(repo_path, task_id, agent_id) do
    Process.get(key(repo_path, task_id, agent_id))
  end

  # --- Internals ------------------------------------------------------------

  defp key(repo_path, task_id, agent_id), do: {@pdict_key, repo_path, task_id, agent_id}

  # Hands the single `git update-ref` to a supervised UNLINKED task. When the
  # supervisor is not running (an isolated/partial boot, a crashed agent group)
  # the anchor is dropped with a debug line: durability degrades, the run does
  # not.
  defp dispatch_write(repo_path, ref_name, sha) do
    write = fn -> write_ref(repo_path, ref_name, sha) end

    if Process.whereis(EvoGit.TaskSupervisor) do
      start_child(write)
    else
      Logger.debug(
        "AgentState.Anchor: #{EvoGit.TaskSupervisor} not running — skipping #{ref_name}"
      )

      :ok
    end
  end

  defp start_child(write) do
    case Task.Supervisor.start_child(EvoGit.TaskSupervisor, write) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.debug("AgentState.Anchor: could not start anchor task: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.debug("AgentState.Anchor: could not start anchor task: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.debug("AgentState.Anchor: could not start anchor task: #{inspect({kind, reason})}")
      :ok
  end

  # Runs inside the supervised task. Total: a raise/throw/exit is logged at
  # debug level and swallowed (an unlinked task's crash would otherwise emit a
  # crash report for a purely best-effort bookkeeping write).
  defp write_ref(repo_path, ref_name, sha) do
    case Git.update_ref(repo_path, ref_name, sha) do
      {:ok, _output} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "AgentState.Anchor: failed to anchor #{ref_name} at #{sha} in #{repo_path}: " <>
            inspect(reason)
        )

        :ok
    end
  rescue
    error ->
      Logger.debug("AgentState.Anchor: anchoring #{ref_name} failed: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.debug("AgentState.Anchor: anchoring #{ref_name} failed: #{inspect({kind, reason})}")
      :ok
  end

  defp stringify(value) when is_binary(value), do: value

  defp stringify(value) do
    to_string(value)
  rescue
    _error -> inspect(value)
  catch
    _kind, _reason -> inspect(value)
  end
end
