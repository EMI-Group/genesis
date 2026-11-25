defmodule EvoGit.AgentScheduler.TaskFreeze do
  @moduledoc """
  The PURE state machine of ONE task pause: the coordinator's bookkeeping, with
  no timers, no ETS and no GenServer calls.

  A task pause is a whole-TREE SNAPSHOT. Every live agent of the task freezes at
  its exact position — a turn boundary, or parked while waiting on its subagent
  batch, with an in-flight tool batch given a bounded chance to finish — so the
  pause is only COMPLETE once every one of them has reported its `{:paused,
  info}` term, and a tree that stopped half-way is not a clean pause at all. This
  module owns exactly that accounting:

    * `begin/4` opens the freeze over the roster the scheduler resolved;
    * `report/3` records ONE agent's paused outcome and answers whether the tree
      is now fully frozen (`{:complete, freeze}`) or still waiting
      (`{:pending, freeze}`);
    * `add_agent/2` admits an agent that joined the task AFTER the freeze opened
      (a late dispatch, a crash-retry) — it must report like everybody else;
    * `timeout/1` / `complete_forced/1` are the QUIESCE path: an agent that never
      answers (a wedged session) must not hang the pause forever, so its leftovers
      are forced and the task is recorded DIRTY.

  ## The kind

  `kind` is the TASK-level pause kind and it only ever degrades from `:clean` to
  `:dirty`:

    * `:clean` — every agent proved an uninterrupted freeze at its own position
      (a turn boundary, or a parent parked on its subagent batch) with its state
      made durable. A resume restores it without repair.
    * `:dirty` — at least one agent reported `clean_freeze: false` (a mixed or
      non-subagent call may have been interrupted half-way) or `durable: false`
      (its conversation/checkpoint could not be confirmed written), or an agent
      was FORCED by the quiesce timeout. A resume must run the crash repair.

  Everything here is total and side-effect free, so the whole coordinator protocol
  is unit-testable without a scheduler: an unknown agent, a duplicate report, a
  report from an agent that already left and a string/atom keyed info map are all
  handled by the documented answer instead of raising.
  """

  alias EvoGit.Util.Time

  @enforce_keys [:task_id]
  defstruct task_id: nil,
            root_id: nil,
            pending: MapSet.new(),
            reported: %{},
            kind: :clean,
            forced: false,
            started_at: nil

  @type kind :: :clean | :dirty

  @type t :: %__MODULE__{
          task_id: String.t() | nil,
          root_id: pos_integer() | nil,
          pending: MapSet.t(pos_integer()),
          reported: %{optional(pos_integer()) => map()},
          kind: kind(),
          forced: boolean(),
          started_at: integer() | nil
        }

  @doc """
  Opens a freeze over `agent_ids` for `task_id`, with `root_id` as the agent whose
  caller receives the pause term.

  `opts`:
    * `:now` — the `started_at` clock value (default: `EvoGit.Util.Time.now_ms/0`);
    * `:kind` — the initial kind (default `:clean`).

  Non-list `agent_ids` and non-integer ids are ignored; a non-integer `root_id` is
  kept as-is (a task with no resolvable root is the caller's problem, not this
  module's).
  """
  @spec begin(String.t() | nil, [integer()], integer() | nil, keyword()) :: t()
  def begin(task_id, agent_ids, root_id, opts \\ []) do
    pending =
      agent_ids
      |> List.wrap()
      |> Enum.filter(&is_integer/1)
      |> MapSet.new()

    %__MODULE__{
      task_id: task_id,
      root_id: root_id,
      pending: pending,
      reported: %{},
      kind: Keyword.get(opts, :kind, :clean),
      forced: false,
      started_at: Keyword.get(opts, :now) || Time.now_ms()
    }
  end

  @doc """
  Admits one more agent to the freeze.

  Idempotent: an agent already pending is left alone, and an agent that has
  ALREADY REPORTED is never re-added (its outcome is known — asking for it again
  would hang the pause).
  """
  @spec add_agent(t(), integer() | nil) :: t()
  def add_agent(%__MODULE__{} = freeze, agent_id) when is_integer(agent_id) do
    if Map.has_key?(freeze.reported, agent_id) do
      freeze
    else
      %{freeze | pending: MapSet.put(freeze.pending, agent_id)}
    end
  end

  def add_agent(%__MODULE__{} = freeze, _agent_id), do: freeze

  @doc """
  Records one agent's paused outcome.

  `info` is the `{:paused, info}` payload the agent's session delivered. The
  freeze turns `:dirty` when that payload says `clean_freeze: false` (something
  may have been interrupted) or `durable: false` (its state could not be confirmed
  written).

  Answers `{:complete, freeze}` when this was the LAST pending agent and
  `{:pending, freeze}` otherwise — including a LATE report from an agent the
  freeze no longer waits for (it is stored and marked, and the caller's freeze is
  already complete, which is harmless).
  """
  @spec report(t(), integer() | nil, map()) :: {:pending, t()} | {:complete, t()}
  def report(%__MODULE__{} = freeze, agent_id, info) do
    info = if is_map(info), do: info, else: %{}

    freeze = %{
      freeze
      | reported: Map.put(freeze.reported, agent_id, info),
        pending: MapSet.delete(freeze.pending, agent_id),
        kind: if(clean_report?(info), do: freeze.kind, else: :dirty)
    }

    if MapSet.size(freeze.pending) == 0 do
      {:complete, freeze}
    else
      {:pending, freeze}
    end
  end

  @doc """
  The QUIESCE verdict: the agents still pending are the VICTIMS that must be
  forced, and the freeze is DIRTY from here on.

  Answers `{freeze, victims}` where `victims` is the sorted list of still-pending
  agent ids (empty when everybody already reported).

  Each victim is recorded as SETTLED with an EMPTY payload: nobody reported for
  it, so there is nothing honest to claim about its checkpoint — but `agents/1`
  still lists the whole frozen tree, and a report that arrives late simply
  overwrites the empty payload.
  """
  @spec timeout(t()) :: {t(), [integer()]}
  def timeout(%__MODULE__{} = freeze) do
    victims = freeze.pending |> MapSet.to_list() |> Enum.sort()
    reported = Enum.reduce(victims, freeze.reported, fn id, acc -> Map.put(acc, id, %{}) end)

    {%{freeze | forced: true, kind: :dirty, pending: MapSet.new(), reported: reported}, victims}
  end

  @doc """
  Marks the freeze COMPLETE by force: nothing is pending any more and the task
  pause is DIRTY (whatever has not reported is taken from its durable state
  as-is).

  This is the grace-expiry verdict — the last resort after the quiesce timeout
  already asked every victim to force-freeze.
  """
  @spec complete_forced(t()) :: t()
  def complete_forced(%__MODULE__{} = freeze) do
    %{freeze | pending: MapSet.new(), forced: true, kind: :dirty}
  end

  @doc "The agent ids the freeze is still waiting for, sorted."
  @spec pending(t()) :: [integer()]
  def pending(%__MODULE__{pending: pending}) do
    pending |> MapSet.to_list() |> Enum.sort()
  end

  @doc """
  Every agent of the freeze — reported, forced or still pending — sorted.
  """
  @spec agents(t()) :: [integer()]
  def agents(%__MODULE__{} = freeze) do
    (Map.keys(freeze.reported) ++ MapSet.to_list(freeze.pending))
    |> Enum.sort()
  end

  @doc "The task-level pause kind (`:clean` until something degrades it)."
  @spec kind(t()) :: kind()
  def kind(%__MODULE__{kind: kind}), do: kind

  @doc "The id of the ROOT agent (whose caller receives the pause term), or `nil`."
  @spec root_id(t()) :: integer() | nil
  def root_id(%__MODULE__{root_id: root_id}), do: root_id

  @doc """
  The ROOT agent's reported `{:paused, info}` payload, or `%{}` when it has not
  reported (a forced freeze).

  Total: a non-freeze answers `%{}`.
  """
  @spec root_info(t() | term()) :: map()
  def root_info(%__MODULE__{root_id: root_id, reported: reported}) do
    case Map.get(reported, root_id) do
      info when is_map(info) -> info
      _other -> %{}
    end
  end

  def root_info(_freeze), do: %{}

  @doc """
  True when nothing is pending any more (every agent reported, or the freeze was
  forced).
  """
  @spec complete?(t() | term()) :: boolean()
  def complete?(%__MODULE__{pending: pending}), do: MapSet.size(pending) == 0
  def complete?(_freeze), do: false

  # A report can only DEGRADE the kind: `clean_freeze` must be literally `true`
  # and `durable` must not be literally `false` (an omitted `durable` is treated
  # as durable, matching the pause payload's default).
  defp clean_report?(info) do
    fetch(info, :clean_freeze) == true and fetch(info, :durable) != false
  end

  # One accessor for BOTH key shapes (a freshly built payload is atom-keyed, a
  # JSON-restored one string-keyed). `Map.fetch/2` — never `Map.get/2 ||` — so a
  # LITERAL `false` (`durable: false`) is not mistaken for an absent key.
  defp fetch(info, key) do
    case Map.fetch(info, key) do
      {:ok, value} -> value
      :error -> Map.get(info, Atom.to_string(key))
    end
  end
end
