defmodule EvoGit.AgentState do
  @moduledoc """
  Durable per-run agent state: a SEPARATE SQLite database
  (`<data_dir>/agent_state.sqlite`) holding each agent run's conversation and
  scalar fields, so a crashed run is recoverable.

  This module is the public facade and contains NO SQL: writes go through the
  single serialized writer (`EvoGit.AgentState.Server`), reads run in the
  CALLING process against the server's dynamic repo pid so they never queue
  behind pending checkpoint casts. Persistence itself lives in
  `EvoGit.AgentState.Store` and the record/codec in
  `EvoGit.AgentState.Record` (child doc: `agent_state/CONTEXT.md`).

  ## Checkpoints

  A checkpoint carries a SMALL entry — never a whole `%EvoGit.Agent.State{}`:

      %{kind: :append | :rewrite,
        base_seq: non_neg_integer() | nil,
        messages: [ReqLLM.Message.t()],
        fields: %{atom => term()},
        owner: pid()}

  `:append` stores ONLY the new tail and is accepted only when `:base_seq`
  equals the stored message count (`nil` means `0`); otherwise nothing is
  written and the owner receives `{:agent_state_resync, task_id, agent_id}`.
  `:rewrite` replaces the whole list in one chunk (used after compression).

  `fields` keys: `:agent_module`, `:depth`, `:parent_id`, `:node_path`,
  `:repo_id`, `:repo_less`, `:repo_root`, `:custom_agent_id`, `:mode`,
  `:archive`, `:objective`, `:model_spec`, `:provider_profile_id`, `:model_id`,
  `:model_id_locked`, `:prompt_cache_key`, `:llm_model`,
  `:llm_context_window`, `:turn`, `:usage`, `:total_tokens`,
  `:compression_count`, `:current_commit`, `:phase`, `:pending_inputs`,
  `:status`, `:pause_commit`. Only the supplied keys are written; unknown keys
  are ignored.

  Every function is TOTAL: a dead/absent server, a malformed entry or a store
  fault degrades to `:ok` / `{:error, :store_unavailable}` and never crashes
  the agent run or the reader.

  ## Task-level pause/resume

  A task-level pause needs three durable facts, all owned here:

    * `pause_commit/2,3` — the git commit sha of the worktree checkpoint the
      agent made when it paused (written by `put_pause_commit/3,4`), so a later
      resume starts from exactly that commit;
    * `resumable?/1,2` — whether the task has ANY durable run row at all;
    * `root_agent_ids/1,2` — which of those runs are ROOT agents
      (`parent_id IS NULL`).

  `flush/1` is the durability barrier the pause path calls immediately before it
  delivers a paused outcome: it is a synchronous `GenServer.call` round-trip
  through the single serialized writer, so when it returns every earlier
  checkpoint cast (for every agent) is committed. It is NOT a cast.
  """

  alias EvoGit.AgentState.{Server, Store}

  @default_server Server
  @call_timeout 15_000

  @typedoc """
  A task id: the task store's 16-hex-character STRING id, or an integer id for
  callers that model tasks numerically.
  """
  @type task_id :: String.t() | pos_integer()

  @doc """
  Starts the agent-state server.

  See `EvoGit.AgentState.Server.start_link/1` for the options (`:database`,
  `:data_dir`, `:name`, `:retention_days`, `:prune_interval`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: Server.start_link(opts)

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 15_000
    }
  end

  @doc """
  The agent-state server for this process.

  The process-dictionary key `:evogit_agent_state_server` wins (the test seam
  for isolated instances); otherwise the named default is returned when it is
  alive. `nil` when neither exists.
  """
  @spec server() :: pid() | nil
  def server do
    case Process.get(:evogit_agent_state_server) do
      pid when is_pid(pid) -> pid
      _other -> alive_pid(Process.whereis(@default_server))
    end
  end

  @doc """
  The dynamic `EvoGit.Repo` pid owned by `server`, for caller-side reads.

  Published by the server in `:persistent_term` at init, so this is a plain
  term lookup — never a `GenServer.call` that could queue behind pending
  checkpoints. `nil` when the server or its repo is absent/dead.
  """
  @spec repo(pid() | nil) :: pid() | nil
  def repo(server) when is_pid(server) do
    case :persistent_term.get({__MODULE__, :repo, server}, nil) do
      repo when is_pid(repo) ->
        if Process.alive?(server) and Process.alive?(repo), do: repo, else: nil

      _other ->
        nil
    end
  end

  def repo(_server), do: nil

  @doc """
  Enqueues a checkpoint. ALWAYS `:ok`, total — this is a CAST, so the hot path
  never blocks on the database.
  """
  @spec checkpoint(String.t(), integer(), map(), keyword()) :: :ok
  def checkpoint(task_id, agent_id, entry, opts \\ []) do
    case target(opts) do
      # `GenServer.cast/2` is total for a name as well as a pid (it returns
      # `:ok` even when the name is unregistered), so a named store is safe too.
      server when is_pid(server) or (is_atom(server) and not is_nil(server)) ->
        GenServer.cast(server, {:checkpoint, task_id, agent_id, entry})

      _none ->
        :ok
    end

    :ok
  end

  @doc """
  Flushes the writer: returns once every checkpoint cast enqueued BEFORE this
  call has been persisted.

  A REAL synchronous durability barrier — a `GenServer.call` round-trip through
  the single serialized writer, never a cast — so when it returns, "the
  checkpoint is durable" is true. The writer is serialized for ALL agents, so
  flushing for one agent also commits every other agent's pending checkpoint.
  This is the pause path's barrier: it is called immediately before a paused
  outcome is delivered.

  Also the read-your-writes barrier for callers that checkpoint and then
  `load/3`/`prune/1` in the same process — a plain read deliberately does NOT
  queue behind the writer (see `load/3`). Total: `:ok` even when the server is
  absent/dead. Accepts `store:` opts, a server pid, or an agent id.
  """
  @spec flush(keyword() | pid() | integer() | nil) :: :ok
  def flush(opts \\ [])

  def flush(opts) when is_list(opts), do: flush(target(opts))

  # An agent id is accepted because the caller that pauses an agent holds one:
  # the writer is a SINGLE serialized process, so this is the same barrier as
  # flushing the server (the agent's checkpoint casts are ordered before it).
  def flush(agent_id) when is_integer(agent_id), do: flush(target([]))

  def flush(server) when is_pid(server) do
    _ = safe_call(server, :sync)
    :ok
  end

  def flush(_none), do: :ok

  @doc """
  Persists (or, with `nil`, clears) one run's `pause_commit`: the git commit
  sha of the worktree checkpoint that agent made when it paused at a turn
  boundary.

  Goes through the SAME single serialized writer as every checkpoint (one
  `GenServer.call`, so it can neither race nor reorder against a concurrent
  checkpoint) but issues a SMALL SCALAR UPDATE of the `pause_commit` column
  alone — message chunks, `message_count`/`chunk_count` and every other scalar
  are untouched, so the append/rewrite continuity rule never sees a pause as a
  conversation write.

  Answers `{:error, :not_found}` when no durable row exists for
  `(task_id, agent_id)` (e.g. `:persistent_state` was off for that task) and
  `{:error, :not_persistent_state_disabled}` when the store is not running.
  Total.
  """
  @spec put_pause_commit(task_id(), pos_integer(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def put_pause_commit(task_id, agent_id, sha, opts \\ []) do
    case call(opts, {:put_pause_commit, task_id, agent_id, sha}) do
      :ok -> :ok
      {:error, _reason} = error -> error
      :error -> {:error, :not_persistent_state_disabled}
      _other -> {:error, :store_unavailable}
    end
  end

  @doc """
  One run's persisted `pause_commit` sha, or `nil`.

  Total: `nil` on a missing row, a missing/dead store and any error.
  """
  @spec pause_commit(task_id(), pos_integer(), keyword()) :: String.t() | nil
  def pause_commit(task_id, agent_id, opts \\ []) do
    case repo(target(opts)) do
      nil -> nil
      repo -> Store.pause_commit(repo, task_id, agent_id)
    end
  end

  @doc """
  Whether the task has ANY durable run row — the cheap gate a resume checks
  before it asks `root_agent_ids/1,2` for the runs to restore.

  Total: `false` on a missing/dead store, an error and no rows.
  """
  @spec resumable?(task_id(), keyword()) :: boolean()
  def resumable?(task_id, opts \\ []) do
    case repo(target(opts)) do
      nil -> false
      repo -> Store.resumable?(repo, task_id)
    end
  end

  @doc """
  The task's ROOT agent ids (`parent_id IS NULL`), ascending.

  Total: `[]` on a missing/dead store, an error and no rows.
  """
  @spec root_agent_ids(task_id(), keyword()) :: [pos_integer()]
  def root_agent_ids(task_id, opts \\ []) do
    case repo(target(opts)) do
      nil -> []
      repo -> Store.root_agent_ids(repo, task_id)
    end
  end

  @doc """
  Loads one run's persisted state.

  Reads in the CALLING process against the server's repo, so it never queues
  behind pending checkpoint casts (use `flush/1` for a read-your-writes
  barrier).
  """
  @spec load(String.t(), integer(), keyword()) ::
          {:ok, EvoGit.AgentState.Record.t()}
          | {:error, :not_found | :corrupt_state | :store_unavailable}
  def load(task_id, agent_id, opts \\ []) do
    case repo(target(opts)) do
      nil -> {:error, :store_unavailable}
      repo -> Store.load(repo, task_id, agent_id)
    end
  end

  @doc "Marks the run completed (the row is KEPT for later recovery). Total."
  @spec mark_completed(String.t(), integer(), keyword()) :: :ok
  def mark_completed(task_id, agent_id, opts \\ []) do
    _ = call(opts, {:mark_completed, task_id, agent_id})
    :ok
  end

  @doc "Deletes one agent run's row and chunks. Total."
  @spec delete(String.t(), integer(), keyword()) :: :ok
  def delete(task_id, agent_id, opts \\ []) do
    _ = call(opts, {:delete, task_id, agent_id})
    :ok
  end

  @doc "Deletes every agent run of one task. Total."
  @spec delete_task(String.t(), keyword()) :: :ok
  def delete_task(task_id, opts \\ []) do
    _ = call(opts, {:delete_task, task_id})
    :ok
  end

  @doc """
  Deletes runs outside the retention window (see
  `EvoGit.AgentState.Retention.cutoffs/2`).

  Returns `{:ok, deleted_count}`; total (`{:ok, 0}` when the server is
  unavailable).
  """
  @spec prune(keyword()) :: {:ok, non_neg_integer()}
  def prune(opts \\ []) do
    case call(opts, :prune) do
      {:ok, count} when is_integer(count) -> {:ok, count}
      _other -> {:ok, 0}
    end
  end

  ## Internals

  defp target(opts) do
    case Keyword.get(opts, :store) do
      nil -> server()
      store -> store
    end
  end

  defp call(opts, message) do
    case target(opts) do
      server when is_pid(server) -> safe_call(server, message)
      server when is_atom(server) and not is_nil(server) -> safe_call(server, message)
      _none -> :error
    end
  end

  # Justified catch: these are documented TOTAL public functions, and a call to
  # a dead/restarting server exits the caller — there is no non-exiting
  # GenServer.call variant, so the boundary contains it.
  defp safe_call(server, message) do
    GenServer.call(server, message, @call_timeout)
  catch
    :exit, _reason -> :error
  end

  defp alive_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid, else: nil
  end

  defp alive_pid(_other), do: nil
end
