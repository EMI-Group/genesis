defmodule EvoGit.AgentState do
  @moduledoc """
  Durable per-run agent state: a SEPARATE SQLite database
  (`<data_dir>/agent_state.sqlite`) holding each RUNNING agent run's
  conversation and scalar fields, so a crashed or paused run is recoverable.

  This module is the public facade and contains NO SQL: writes go through the
  single serialized writer (`EvoGit.AgentState.Server`), reads run in the
  CALLING process against the server's dynamic repo pid so they never queue
  behind pending checkpoint casts. Persistence itself lives in
  `EvoGit.AgentState.Store` and the record/codec in
  `EvoGit.AgentState.Record` (child doc: `agent_state/CONTEXT.md`).

  ## Row model

  ONE row per RUNNING agent run, keyed `(task_id, agent_id)` with `agent_id`
  stable across restarts, plus its compressed message chunks. `parent_id` links
  a child to the agent that spawned it (`NULL` for a task's root) and
  `depth` places it in the tree, so a task's whole agent tree is reachable
  through `roster/2` — and the lean skeletons of MANY tasks through
  `roster_many/2`.

  `status` is `running` or `done`: a `done` child row stays readable until its
  parent's checkpoint consumes that batch (`delete_done_children/4`), a
  completed root is `delete/3`d, and retention pruning is the backstop for rows
  a crash left behind.

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

  The writer COALESCES: checkpoints still queued for the same run are folded
  into ONE transaction (`EvoGit.AgentState.Entry`), its mailbox is bounded
  (over the backlog cap the arriving checkpoint is dropped and its owner
  resynced) and a payload above the size cap is skipped. Both caps are start
  options (`:max_backlog`, `:max_payload_bytes`) whose defaults come from the
  app env; see `EvoGit.AgentState.Server`.

  `fields` keys: `:agent_module`, `:depth`, `:parent_id`, `:node_path`,
  `:repo_id`, `:repo_less`, `:repo_root`, `:custom_agent_id`, `:mode`,
  `:archive`, `:objective`, `:model_spec`, `:provider_profile_id`, `:model_id`,
  `:model_id_locked`, `:prompt_cache_key`, `:llm_model`,
  `:llm_context_window`, `:turn`, `:usage`, `:total_tokens`,
  `:compression_count`, `:current_commit`, `:phase`, `:pending_inputs`,
  `:pending_tool_batch`, `:status`, `:pause_commit`, `:spawn_turn`,
  `:spawn_index`, `:branch`, `:base_commit`, `:anchor_ref`, `:redispatch`,
  `:result`. Only the supplied keys are written; unknown keys are ignored.

  A run's per-turn SCALARS can also be refreshed without touching its
  conversation at all: `update_volatile/4` issues ONE constant-shape `UPDATE`
  of the volatile columns alone (`turn`, `usage`, `total_tokens`,
  `compression_count`, `current_commit`, `phase`, `pending_inputs`,
  `pending_tool_batch`, `status`), with REPLACE semantics — the caller supplies
  the FULL map every turn. Because its column list is fixed at compile time it
  is one reused prepared statement, so a per-turn refresh never re-encodes an
  identity or run fact.

  Every function is TOTAL: a dead/absent server, a malformed entry or a store
  fault degrades to that function's documented answer — `:ok` for a cast,
  `[]`/`nil`/`0` for a read, `{:ok, count}` for `prune/1`, and an error tuple
  where the caller must be able to tell (`{:error, :store_unavailable}` for an
  absent/degraded store, `{:error, :not_found}` for a missing row,
  `{:error, :timeout}` for a durability barrier that could not confirm) — and
  never crashes the agent run or the reader.

  ## Task-level pause/resume

  A task-level pause needs two durable facts, both owned here:

    * `pause_commit/2,3` — the git commit sha of the worktree checkpoint the
      agent made when it paused (written by `put_pause_commit/3,4`), so a later
      resume starts from exactly that commit;
    * `roster/2` — the task's whole durable run tree, from which a resume
      admission resolves the ROOT row it must restore.

  `flush/1` is the durability barrier the pause path calls immediately before it
  delivers a paused outcome: it is a synchronous `GenServer.call` round-trip
  through the single serialized writer, so when it returns `:ok` every earlier
  checkpoint cast (for every agent) is committed. It is NOT a cast, and it is
  HONEST: `{:error, :timeout}` means this caller may not claim durability (a
  dead/stopped server, a degraded writer, or a writer whose queue is already
  past the backlog cap).

  ## Supervision & total APIs

  The subsystem lives under `EvoGit.AgentState.Supervisor` (generous restart
  intensity), so a failing disk can never take the application down: the writer
  boots DEGRADED and retries with bounded backoff. Every public function stays
  total in every state, and every function accepts EITHER the supervisor pid
  (what `child_spec/1` starts and `start_supervised!/2` returns) OR the writer
  pid — a supervisor pid is resolved through `:persistent_term`.
  """

  alias EvoGit.AgentState.{Server, Store, Supervisor}

  @default_server Server

  # The drain budget for a synchronous call. NEVER smaller than the database's
  # own wait budget plus a statement budget: `EvoGit.Repo.start_opts/0` sets
  # `busy_timeout: 30_000` (a lock waits in the calling process for up to 30 s)
  # and a statement gets a further 10 s of headroom here. A shorter call timeout
  # would answer "timed out" for exactly the lock contention the barrier exists
  # for — and worse, the abandoned call would still be executed later.
  @call_timeout 40_000

  @typedoc """
  A task id: the task store's 16-hex-character STRING id, or an integer id for
  callers that model tasks numerically.
  """
  @type task_id :: String.t() | pos_integer()

  @typedoc """
  A checkpoint entry, in the normalized shape `EvoGit.AgentState.Entry`
  validates and folds:

      %{kind: :append | :rewrite,
        base_seq: non_neg_integer() | nil,
        messages: [ReqLLM.Message.t()],
        fields: %{atom => term()},
        owner: pid() | nil}

  The facade only forwards it (the writer validates and logs it), so a
  malformed entry degrades to a dropped checkpoint, never a crash.
  """
  @type checkpoint_entry :: EvoGit.AgentState.Entry.t()

  @doc """
  Starts the agent-state SUPERVISOR (the writer is its child).

  See `EvoGit.AgentState.Server.start_link/1` for the options (`:database`,
  `:data_dir`, `:name`, `:retention_days`, `:prune_interval`,
  `:boot_retry_base`, `:boot_retry_max`, `:max_backlog`, `:max_payload_bytes`).
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []), do: Supervisor.start_link(opts)

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Supervisor, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
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
  def repo(server) do
    case resolve(server) do
      pid when is_pid(pid) ->
        case :persistent_term.get({__MODULE__, :repo, pid}, nil) do
          repo when is_pid(repo) ->
            if Process.alive?(pid) and Process.alive?(repo), do: repo, else: nil

          _other ->
            nil
        end

      _other ->
        nil
    end
  end

  @doc """
  Enqueues a checkpoint. ALWAYS `:ok`, total — this is a CAST, so the hot path
  never blocks on the database.
  """
  @spec checkpoint(task_id(), integer(), checkpoint_entry(), keyword()) :: :ok
  def checkpoint(task_id, agent_id, entry, opts \\ []) do
    cast(opts, {:checkpoint, task_id, agent_id, entry})
  end

  @doc """
  Rewrites ONLY the VOLATILE per-turn scalars of one run.

  A CAST through the SAME single serialized writer as `checkpoint/4`, so it
  stands in the same order as the conversation writes around it and the agent's
  turn never blocks on the database. The writer issues ONE constant-shape
  `UPDATE` (`Record.volatile_columns/0`: `turn`, `usage`, `total_tokens`,
  `compression_count`, `current_commit`, `phase`, `pending_inputs`,
  `pending_tool_batch`, `status`), never a variable-width upsert.

  The contract a caller (the session package) must honour:

    * REPLACE semantics — supply the FULL volatile map on every turn. A key the
      caller OMITTED is written as the column's default/`NULL`, NOT left alone
      (the four `NOT NULL` columns fall back to their table defaults, so an
      omitted `turn`/`total_tokens`/`compression_count`/`status` resets rather
      than fails).
    * It never INSERTS. A run's row comes into existence with its start
      snapshot; with no matching row the store answers `{:error, :not_found}`
      and the writer logs it.
    * `pause_commit`, `result` and every identity/run fact are deliberately NOT
      in this set — they belong to `put_pause_commit/4`, `mark_done/5` and the
      checkpoint `fields` respectively.
    * It is a CAST: total and `:ok`. Call `flush/1` when the write must be
      observed (it is ordered behind everything queued before it).
  """
  @spec update_volatile(task_id(), integer(), map(), keyword()) :: :ok
  def update_volatile(task_id, agent_id, fields, opts \\ []) do
    cast(opts, {:update_volatile, task_id, agent_id, fields})
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
  queue behind the writer (see `load/3`).

  Accepts the whole target set `keyword() | pid() | atom() | integer() | nil`:
  `store:` opts (a KEYWORD list), a server/supervisor pid, a registered name,
  `nil` (no target at all) or an agent id. Anything else — a binary (a real
  task id), a struct, a non-keyword list — is NOT a target this barrier can
  flush, so it answers `{:error, :timeout}` instead of claiming a durability
  nothing verified; that is exactly the agent-id/task-id mix-up the barrier
  exists to catch.

  HONEST: `:ok` means the writer committed everything queued before this call;
  `{:error, :timeout}` means the caller must NOT claim durability (the server
  is absent/dead, the writer is degraded, its backlog is over the writer's
  cap — the `:max_backlog` start option, else app env
  `:agent_state_max_backlog`, default 200 — or the target was not a target at
  all). `nil` (no target at all) is `:ok` — there is nothing to flush.
  """
  @spec flush(keyword() | pid() | atom() | integer() | nil) :: :ok | {:error, :timeout}
  def flush(opts \\ [])

  def flush(opts) when is_list(opts) do
    # A non-keyword list is not a target set: it was never flushed, so this
    # never reaches `target/1` (whose `Keyword.get/3` would raise on it).
    if Keyword.keyword?(opts), do: flush(target(opts)), else: {:error, :timeout}
  end

  # An agent id is accepted because the caller that pauses an agent holds one:
  # the writer is a SINGLE serialized process, so this is the same barrier as
  # flushing the server (the agent's checkpoint casts are ordered before it).
  def flush(agent_id) when is_integer(agent_id), do: flush(target([]))

  def flush(nil), do: :ok

  # A call to a dying/absent writer exits the caller; the barrier converts that
  # into its documented non-durable answer instead of crashing a pause.
  def flush(server) when is_pid(server) or is_atom(server) do
    case safe_call(resolve(server), :sync) do
      :ok -> :ok
      _other -> {:error, :timeout}
    end
  end

  # An UNRECOGNISED target (a binary task id, a struct, …) never got a `:sync`,
  # so nothing was flushed and durability cannot be claimed.
  def flush(_other), do: {:error, :timeout}

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
  `(task_id, agent_id)` (an agent that never checkpointed, or a task whose
  durable state is gone) and `{:error, :store_unavailable}` when the store is
  simply absent/degraded — that is an AVAILABILITY failure, not a
  configuration one. `:not_persistent_state_disabled` is the FLAG-specific tag
  (the task's `:persistent_state` was turned OFF); no producer emits it today,
  because `persistent_state: false` is fully inert, so it must never be used
  to report unavailability.

  Total: `{:error, :not_found | :store_unavailable | term()}`, and a caller
  that only cares whether the sha landed may treat any `{:error, reason}` as
  "not durable" (which is what `EvoGit.Agent.Session.Pause` does).
  """
  @spec put_pause_commit(task_id(), pos_integer(), String.t() | nil, keyword()) ::
          :ok | {:error, :not_found | :store_unavailable | term()}
  def put_pause_commit(task_id, agent_id, sha, opts \\ []) do
    case call(opts, {:put_pause_commit, task_id, agent_id, sha}) do
      :ok -> :ok
      {:error, _reason} = error -> error
      :error -> {:error, :store_unavailable}
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
  The task's WHOLE durable agent tree, ordered `depth ASC, agent_id ASC`.

  ONE `SELECT` over `agent_states` with no chunk read. The projection is LEAN
  (file-wise lean): `messages` is `nil`, and so are `pending_inputs` and
  `usage` — no roster consumer reads those, so they are not even selected.
  Everything else is present: identity and parentage (`agent_id`, `parent_id`,
  `depth`), the spawn position (`spawn_turn`, `spawn_index`), the git facts
  (`branch`, `base_commit`, `current_commit`, `anchor_ref`), `status`,
  `result`, the re-dispatch payload (`redispatch`), the objective and the
  module/model selection. A caller that needs one run's transcript calls
  `load/3`.

  Total: `[]` on a missing/dead/degraded store, an error and no rows.
  """
  @spec roster(task_id(), keyword()) :: [EvoGit.AgentState.Record.t()]
  def roster(task_id, opts \\ []) do
    case repo(target(opts)) do
      nil ->
        []

      repo ->
        case Store.roster(repo, task_id) do
          {:ok, records} -> records
          _other -> []
        end
    end
  end

  @doc """
  The LEAN `roster/2` skeletons of MANY tasks in one bounded pass.

  One constant-shape `SELECT` per batch of task ids (`Store.roster_many/2`),
  ordered `task_id ASC, depth ASC, agent_id ASC` — the bulk shape a registry
  rebuilding several task trees at once needs, without a call per task. Each
  record carries the same LEAN projection as `roster/2` (so `messages`,
  `pending_inputs` and `usage` are `nil`; `objective`/`redispatch`, the git
  facts, `status` and `result` are present).

  Input is filtered to binary task ids and deduplicated by the store, so a
  repeated or non-binary id is simply ignored (and an empty list reads
  nothing).

  Total: `[]` on a missing/dead/degraded store, an error, a non-list argument
  and no rows.
  """
  @spec roster_many([task_id()], keyword()) :: [EvoGit.AgentState.Record.t()]
  def roster_many(task_ids, opts \\ [])

  def roster_many(task_ids, opts) when is_list(task_ids) do
    case repo(target(opts)) do
      nil ->
        []

      repo ->
        case Store.roster_many(repo, task_ids) do
          {:ok, records} -> records
          _other -> []
        end
    end
  end

  def roster_many(_task_ids, _opts), do: []

  @doc """
  The highest `agent_id` the durable store has ever held, `0` when empty.

  The scheduler seeds its id counter from this at boot, so an id it hands out
  never collides with a row a restart must restore. Total: `0` on a
  missing/dead/degraded store.
  """
  @spec max_agent_id(keyword()) :: non_neg_integer()
  def max_agent_id(opts \\ []) do
    case repo(target(opts)) do
      nil -> 0
      repo -> Store.max_agent_id(repo)
    end
  end

  @doc """
  Loads one run's persisted state.

  Reads in the CALLING process against the server's repo, so it never queues
  behind pending checkpoint casts (use `flush/1` for a read-your-writes
  barrier).
  """
  @spec load(task_id(), integer(), keyword()) ::
          {:ok, EvoGit.AgentState.Record.t()}
          | {:error, :not_found | :corrupt_state | :store_unavailable}
  def load(task_id, agent_id, opts \\ []) do
    case repo(target(opts)) do
      nil -> {:error, :store_unavailable}
      repo -> Store.load(repo, task_id, agent_id)
    end
  end

  @doc """
  Marks the run DONE with its result and the commit it produced.

  A CAST through the single serialized writer: total, `:ok`, and never a
  synchronous barrier for the finalizing session — the result is delivered
  before any durable bookkeeping. Call `flush/1` when the write must be
  observed.

  `result` is the finished run's small JSON map (`text`, `commit`, repo id) and
  `current_commit` its newest git commit; passing `nil` for either records
  nothing new for that fact instead of clearing a stored value.
  """
  @spec mark_done(task_id(), integer(), map() | nil, String.t() | nil, keyword()) :: :ok
  def mark_done(task_id, agent_id, result, current_commit, opts \\ []) do
    cast(opts, {:mark_done, task_id, agent_id, result, current_commit})
  end

  @doc """
  Deletes the DONE children one parent spawned in a single tool batch.

  The parent's checkpoint that clears its in-flight batch consumed exactly
  those results, so their rows are no longer needed. A CAST: total, `:ok`;
  only rows with `status == "done"` and a matching `spawn_turn` are touched,
  and a non-integer `spawn_turn` deletes nothing.
  """
  @spec delete_done_children(task_id(), integer() | nil, integer() | nil, keyword()) :: :ok
  def delete_done_children(task_id, parent_id, spawn_turn, opts \\ []) do
    cast(opts, {:delete_done_children, task_id, parent_id, spawn_turn})
  end

  @doc """
  Deletes one agent run's row and chunks.

  A CAST: total, `:ok`. Call `flush/1` when the deletion must be observed.
  """
  @spec delete(task_id(), integer(), keyword()) :: :ok
  def delete(task_id, agent_id, opts \\ []) do
    cast(opts, {:delete, task_id, agent_id})
  end

  @doc """
  Deletes every agent run of one task.

  A CAST: total, `:ok`. Call `flush/1` when the deletion must be observed.
  """
  @spec delete_task(task_id(), keyword()) :: :ok
  def delete_task(task_id, opts \\ []) do
    cast(opts, {:delete_task, task_id})
  end

  @doc """
  Deletes every run of MANY tasks in ONE cast (one writer message, one
  transaction) — the bulk shape a registry clearing finished tasks needs.

  Total and `:ok`; non-list input is ignored.
  """
  @spec delete_tasks([String.t()], keyword()) :: :ok
  def delete_tasks(task_ids, opts \\ [])

  def delete_tasks(task_ids, opts) when is_list(task_ids),
    do: cast(opts, {:delete_tasks, task_ids})

  def delete_tasks(_task_ids, _opts), do: :ok

  @doc """
  Deletes runs outside the retention window (see
  `EvoGit.AgentState.Retention.cutoffs/2`).

  `{:ok, deleted_count}` when the sweep ran, and `{:error, reason}` when it
  FAILED — the store's own failure is passed through, never flattened into
  "0 runs expired". Absence is not a failure: with no store or a dead server
  there is nothing to prune, so that answers `{:ok, 0}`.
  """
  @spec prune(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(opts \\ []) do
    case call(opts, :prune) do
      {:ok, count} when is_integer(count) -> {:ok, count}
      {:error, _reason} = error -> error
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

  # `GenServer.cast/2` is total for a name as well as a pid (it returns `:ok`
  # even when the name is unregistered), and a supervisor pid is resolved to the
  # writer first — a cast/call sent to a supervisor would be an unknown message.
  defp cast(opts, message) do
    case resolve(target(opts)) do
      server when is_pid(server) or (is_atom(server) and not is_nil(server)) ->
        GenServer.cast(server, message)

      _none ->
        :ok
    end

    :ok
  end

  defp call(opts, message) do
    case resolve(target(opts)) do
      server when is_pid(server) -> safe_call(server, message)
      server when is_atom(server) and not is_nil(server) -> safe_call(server, message)
      _none -> :error
    end
  end

  # A supervisor pid (what `child_spec/1` starts) maps to its writer through a
  # `:persistent_term` entry the writer publishes at init. Anything else is
  # already a usable target.
  defp resolve(pid) when is_pid(pid) do
    case :persistent_term.get({__MODULE__, :server_for, pid}, nil) do
      server when is_pid(server) -> server
      _other -> pid
    end
  end

  defp resolve(target), do: target

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
