defmodule EvoGit.AgentState.Snapshot do
  @moduledoc """
  The ONE durable SNAPSHOT read model of a task's agent tree.

  A paused (or resumable) task needs the same few facts over and over: which
  agent is the ROOT, which of its agents were still `running`, which children
  belonged to ONE frozen tool batch, and what was in flight at the moment of the
  freeze. Today those questions were answered ad hoc — one `roster/2` call here,
  a per-agent `load/3` there, a re-derived batch class somewhere else — so two
  consumers could disagree about the same tree.

  This module is the shared answer: `read/2` reads ONE task's roster
  (`EvoGit.AgentState.roster/2`, already ordered `depth ASC, agent_id ASC`) and
  splits it into the `root` record (the one whose `parent_id` is `nil`) and the
  full `agents` roster. Everything else here is a pure, TOTAL projection over
  that value, so a consumer never re-reads the database to answer a follow-up
  question about the same snapshot. `children/3` accepts EITHER a snapshot or a
  plain list of records, so a consumer holding only the rows reuses the same
  filter instead of growing a private copy of it.

  ## Reading through a BOUNDED reader

  A life-critical caller (`EvoGit.TaskRegistry`) must never block on the durable
  store, so it reads its roster through
  `EvoGit.TaskRegistry.AgentStateRead.roster/2` and asks
  `build/2` — the PURE constructor — for the snapshot instead of calling
  `read/2`. `read/2` is exactly `build/2` over the direct roster read, with the
  store probe (`available?/1`) deciding the `{:error, :unavailable}` answer, so
  both paths produce the same value and a consumer never grows a private
  root/roster split of its own.

  The snapshot is DURABLE-BY-NATURE — it is built from `agent_state.sqlite`,
  which holds one row per RUNNING agent — so it survives the scheduler and even
  a BEAM restart. It is deliberately a plain data structure (no pids, no
  timers): the live session facts stay in the scheduler, which is why the
  frozen agents are correlated by `agent_id`.

  ## Positions

  `position/1` answers where a run was interrupted, derived from its durable
  in-flight batch marker (`EvoGit.Agent.ToolBatch.normalize/1`):

    * `:turn_boundary` — no marker: the agent stopped between turns, nothing was
      in flight;
    * `{:awaiting_children, turn}` — the marker holds ONLY `:subagent` calls: the
      agent was parked inside `spawn_sub_agents/2`, waiting for its children;
    * `{:batch, class}` — any other marker: a call of `class` may have been
      interrupted half-way. `class` is chosen by the FIXED severity order
      (`:shell`, `:edit`, `:write`, `:read`) rather than by the call's position
      in the batch, so the same marker always produces the same verdict.

  Every function is total: a malformed record, a missing field or a
  non-snapshot argument answers that function's documented empty value instead
  of raising.
  """

  alias EvoGit.Agent.ToolBatch
  alias EvoGit.AgentState
  alias EvoGit.AgentState.Record

  @enforce_keys [:task_id, :root, :agents]
  defstruct [:task_id, :root, :agents]

  @type t :: %__MODULE__{
          task_id: String.t(),
          root: Record.t(),
          agents: [Record.t()]
        }

  @typedoc "Where a run was interrupted, derived from its in-flight batch marker."
  @type position ::
          :turn_boundary
          | {:awaiting_children, integer() | nil}
          | {:batch, ToolBatch.class()}

  # The class severity order a `{:batch, class}` verdict is chosen in: the first
  # class present wins. Fixed (never derived from call order) so two readers of
  # the same marker always agree.
  @class_order [:shell, :edit, :write, :read]

  @doc """
  Reads `task_id`'s durable agent tree.

  Answers `{:ok, snapshot}` when the roster has a ROOT row (a record whose
  `parent_id` is `nil`), and one of

    * `{:error, :unavailable}` — there is no agent-state store (or it is
      degraded), so the answer is "cannot tell", never "empty";
    * `{:error, :empty}` — the store answered an EMPTY roster;
    * `{:error, :no_root}` — rows exist but none of them is a root.

  `opts` are `EvoGit.AgentState`'s own (`:store`, the server or its supervisor).
  """
  @spec read(String.t(), keyword()) :: {:ok, t()} | {:error, :empty | :no_root | :unavailable}
  def read(task_id, opts \\ [])

  def read(task_id, opts) when is_binary(task_id) do
    if available?(opts) do
      # `EvoGit.AgentState.roster/2` flattens EVERY store/read error to `[]`, so
      # an unavailable store is answered by the probe above — which is exactly
      # why that probe exists — and inside this branch the list is the truth.
      build(task_id, AgentState.roster(task_id, opts))
    else
      {:error, :unavailable}
    end
  end

  def read(_task_id, _opts), do: {:error, :empty}

  @doc """
  Builds the snapshot from a roster the caller ALREADY read — no store access.

  This is the PURE half of `read/2`, for a caller that must use its own bounded
  reader (`EvoGit.TaskRegistry.AgentStateRead`) and still wants the ONE
  root/roster split. Answers

    * `{:error, :empty}` — the roster is empty (a non-list roster included);
    * `{:error, :no_root}` — rows exist but none of them is a root.

  The store-availability answer (`{:error, :unavailable}`) belongs to
  `read/2`/`available?/1`, because a reader that answered `[]` for a degraded
  store cannot be distinguished from one that found no rows.
  """
  @spec build(String.t(), [Record.t()] | term()) :: {:ok, t()} | {:error, :empty | :no_root}
  def build(task_id, records) when is_binary(task_id) and is_list(records) do
    case records do
      [] ->
        {:error, :empty}

      records ->
        case Enum.find(records, &root?/1) do
          nil -> {:error, :no_root}
          root -> {:ok, %__MODULE__{task_id: task_id, root: root, agents: records}}
        end
    end
  end

  def build(_task_id, _records), do: {:error, :empty}

  @doc """
  `true` when a durable agent-state record is a ROOT run — the record whose
  `parent_id` is absent or `nil`.

  The durable tree is keyed `(task_id, agent_id)` and only a ROOT record can
  restore a paused task (a resume starts from the root), so this ONE predicate
  is what `read/2`/`build/2` select the root with and what every resumability
  classification asks. Total: a non-record answers `false`.
  """
  @spec root?(Record.t() | term()) :: boolean()
  def root?(%Record{} = record), do: is_nil(parent_id(record))
  def root?(_record), do: false

  @doc """
  Whether the durable agent-state store can answer at all — the probe behind
  `read/2`'s `{:error, :unavailable}` verdict.

  `false` means "cannot tell", never "no rows": a caller assembling the
  snapshot from its own bounded roster read asks this first so it reports an
  absent/degraded store honestly instead of an empty tree. `opts` is
  `EvoGit.AgentState`'s own (`:store`, the server or its supervisor). Total.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    store =
      case Keyword.get(opts, :store) do
        nil -> AgentState.server()
        store -> store
      end

    not is_nil(AgentState.repo(store))
  end

  @doc """
  The snapshot records whose persisted `status` is `"running"`.

  A `done` (or `nil`) row is excluded: it already settled and must not be
  frozen, resumed or waited on.
  """
  @spec live(t() | term()) :: [Record.t()]
  def live(%__MODULE__{agents: agents}) when is_list(agents) do
    Enum.filter(agents, &(Record.status(&1) == "running"))
  end

  def live(_snapshot), do: []

  @doc """
  The children ONE parent spawned in ONE tool batch, ordered by `spawn_index`.

  This is the pending-batch roster of a freeze: the same `parent_id` +
  `spawn_turn` pair a parent's `%EvoGit.Agent.State{pending_tool_batch}` names.
  A record without an integer `spawn_index` sorts last (it cannot be placed in
  the batch), ties break on `agent_id` for determinism.

  The first argument is EITHER a `%Snapshot{}` or a plain list of records
  (a roster read the caller already has), so there is ONE implementation of this
  filter and two consumers over one snapshot can never disagree.

  Total: a non-snapshot/non-list, a non-integer `parent_id` or an empty match
  answers `[]`.
  """
  @spec children(t() | [Record.t()] | term(), integer() | nil, integer() | nil) :: [Record.t()]
  def children(%__MODULE__{agents: agents}, parent_id, spawn_turn),
    do: children(agents, parent_id, spawn_turn)

  def children(records, parent_id, spawn_turn) when is_list(records) and is_integer(parent_id) do
    records
    |> Enum.filter(fn record ->
      parent_id(record) == parent_id and field(record, :spawn_turn) == spawn_turn
    end)
    # `agent_id` is a STRUCT field (the row key), not a `fields` scalar.
    |> Enum.sort_by(fn record -> {index_sort_key(record), agent_id(record)} end)
  end

  def children(_snapshot_or_records, _parent_id, _spawn_turn), do: []

  @doc """
  Where a run was interrupted, from its durable in-flight batch marker.

  See the moduledoc's "Positions" section. Total: any non-record input, and a
  record without a marker, answers `:turn_boundary`.
  """
  @spec position(Record.t() | term()) :: position()
  def position(record) do
    case ToolBatch.normalize(field(record, :pending_tool_batch)) do
      nil ->
        :turn_boundary

      batch ->
        if ToolBatch.subagent_only?(batch) do
          {:awaiting_children, batch.turn}
        else
          {:batch, batch_class(batch.calls)}
        end
    end
  end

  @doc """
  Every agent id of the roster, in roster order (`depth ASC, agent_id ASC`).

  Total: a non-snapshot answers `[]`.
  """
  @spec agent_ids(t() | term()) :: [integer()]
  def agent_ids(%__MODULE__{agents: agents}) when is_list(agents) do
    Enum.map(agents, &agent_id/1)
  end

  def agent_ids(_snapshot), do: []

  @doc """
  How many records of the tree are still LIVE (`live/1`) — the size of the run
  a resume has to restore.

  Total: a non-snapshot answers `0`.
  """
  @spec running_count(t() | term()) :: non_neg_integer()
  def running_count(snapshot), do: length(live(snapshot))

  # --- Private helpers ---

  defp batch_class(calls) do
    Enum.find(@class_order, :read, fn class ->
      Enum.any?(calls, &(&1.class == class))
    end)
  end

  # Integer indices first (ascending), a missing one last.
  defp index_sort_key(record) do
    case field(record, :spawn_index) do
      index when is_integer(index) -> index
      _other -> :infinity
    end
  end

  defp parent_id(record), do: field(record, :parent_id)

  defp agent_id(%Record{agent_id: agent_id}), do: agent_id
  defp agent_id(_record), do: nil

  defp field(%Record{fields: fields}, key) when is_map(fields), do: Map.get(fields, key)
  defp field(_record, _key), do: nil
end
