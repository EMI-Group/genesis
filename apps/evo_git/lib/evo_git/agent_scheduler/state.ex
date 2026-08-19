defmodule EvoGit.AgentScheduler.State do
  @moduledoc """
  GenServer state struct for `EvoGit.AgentScheduler`.

  Holds the full scheduler state including worktree pool configuration,
  slot management queues, agent tracking maps, and run metadata.

  ## Per-Model LLM Slot Pools

  LLM slots are organized into **per-model pools**. Each model profile gets
  its own concurrency limit, holder set, waiting queue, backoff timer, and
  last-granted tracking. This means a rate-limit on one provider no longer
  blocks agents using a different model.

  The per-model data is stored in maps keyed by `model_id`:
  - `model_concurrency` — `%{model_id => limit}`
  - `llm_holders` — `%{model_id => MapSet.t(agent_id)}`
  - `llm_waiting` — `%{model_id => :queue.queue()}`
  - `llm_backoff_until` — `%{model_id => timestamp | nil}`
  - `llm_last_granted` — `%{model_id => %{agent_id => timestamp}}`

  `llm_model` / `llm_generation_params` remain as backward-compat fields
  representing the **default** model profile.

  ## Fields

  ### Configuration
  - `default_llm_max_concurrency` — default per-LLM concurrency limit, used as the fallback when a model profile doesn't specify its own (mirrors the default profile's concurrency)
  - `model_concurrency` — `%{model_id => limit}` per-model concurrency limits
  - `model_profiles` — list of model profile maps loaded from config at init
  - `max_tool_concurrency` — maximum concurrent tool executions (tool slot pool size)
  - `agent_max_retries` — crash-retry limit per agent
  - `max_depth` — maximum agent recursion depth
  - `llm_model` — the default LLM model identifier (from default profile, backward compat)
  - `llm_generation_params` — default LLM generation params (from default profile, backward compat)
  - `max_retries` — maximum total retries across the scheduler
  - `max_turns` — maximum turns per agent loop
  - `max_turns_root` — maximum turns for the root (top-level) agent only

  ### Agent Lifecycle
  - `next_agent_id` — monotonically increasing agent ID counter
  - `task_local_counters` — map of `task_id (string) => next_local_id` for per-task agent numbering
  - `task_agent_counts` — map of `task_id (string) => total agents spawned` (for stats reporting)
  - `ref_to_agent` — maps `Task` monitor references to agent IDs
  - `queue` — FIFO queue of agent IDs waiting for a worktree

  ### LLM Slot Management (per-model pools)
  - `llm_holders` — `%{model_id => MapSet}` of agent IDs currently holding an LLM slot
  - `llm_waiting` — `%{model_id => queue}` of `{agent_id, from, backoff}` pairs blocked on an LLM slot
  - `llm_backoff_until` — `%{model_id => timestamp | nil}` per-model backoff (`nil` means no active backoff)
  - `llm_last_granted` — `%{model_id => %{agent_id => timestamp}}` per-model recency tracking

  ### Pause Control
  - `paused` — whether the scheduler is paused (no new slots or agent dispatches granted)

  ### Tool Slot Management
  - `tool_holders` — `MapSet` of agent IDs currently holding a tool slot
  - `tool_waiting` — FIFO queue of `{agent_id, from}` pairs blocked on a tool slot
  """

  require Logger
  alias EvoGit.AgentScheduler.Lifecycle
  alias EvoGit.AgentScheduler.Slots

  @enforce_keys []
  defstruct default_llm_max_concurrency: 3,
            model_concurrency: %{},
            model_profiles: [],
            agent_max_retries: 3,
            max_depth: 8,
            llm_model: nil,
            llm_generation_params: [],
            max_retries: 15,
            max_turns: 128,
            max_turns_root: 128,
            next_agent_id: 1,
            ref_to_agent: %{},
            queue: :queue.new(),
            llm_holders: %{},
            llm_waiting: %{},
            llm_backoff_until: %{},
            llm_last_granted: %{},
            tool_holders: MapSet.new(),
            tool_waiting: :queue.new(),
            max_tool_concurrency: 2,
            task_local_counters: %{},
            task_agent_counts: %{},
            paused: false,
            sandbox_mode: nil,
            sandbox_resources: nil,
            sandbox_process_resources: nil

  @type t :: %__MODULE__{
          default_llm_max_concurrency: pos_integer(),
          model_concurrency: %{String.t() => non_neg_integer()},
          model_profiles: [map()],
          agent_max_retries: non_neg_integer(),
          max_depth: pos_integer(),
          llm_model: ReqLLM.model_input(),
          llm_generation_params: keyword(),
          max_retries: pos_integer(),
          max_turns: pos_integer(),
          max_turns_root: pos_integer(),
          next_agent_id: pos_integer(),
          ref_to_agent: %{reference() => pos_integer()},
          queue: :queue.queue(pos_integer()),
          llm_holders: %{String.t() => MapSet.t(pos_integer())},
          llm_waiting: %{String.t() => :queue.queue(term())},
          llm_backoff_until: %{String.t() => integer() | nil},
          llm_last_granted: %{String.t() => %{optional(pos_integer()) => integer()}},
          tool_holders: MapSet.t(pos_integer()),
          tool_waiting: :queue.queue(term()),
          max_tool_concurrency: pos_integer(),
          task_local_counters: %{optional(String.t()) => pos_integer()},
          task_agent_counts: %{optional(String.t()) => pos_integer()},
          paused: boolean(),
          sandbox_mode: :auto | :enabled | :disabled | nil,
          sandbox_resources: map() | nil,
          sandbox_process_resources: map() | nil
        }

  @doc """
  Returns the default model profile id from the state's `model_profiles`.

  The default profile is the first in the list. Returns `"default"` if no
  profiles are configured.
  """
  @spec default_model_id(t()) :: String.t()
  def default_model_id(%__MODULE__{model_profiles: []}), do: "default"

  def default_model_id(%__MODULE__{model_profiles: [profile | _]}) do
    Map.get(profile, :id, "default")
  end

  @doc """
  Builds a fresh `State` from a list of model profiles, initializing all
  per-model pool maps (holders, waiting queues, backoff, last_granted)
  with empty values for each profile.

  Used by `AgentScheduler.init/1` and tests.
  """
  @spec from_model_profiles([map()], keyword()) :: t()
  def from_model_profiles(profiles, opts \\ []) do
    model_ids = Enum.map(profiles, fn p -> Map.get(p, :id, "default") end)

    model_concurrency =
      profiles
      |> Enum.zip(model_ids)
      |> Map.new(fn {profile, id} ->
        {id, Map.get(profile, :concurrency, 3)}
      end)

    empty_pools =
      Map.new(model_ids, fn id ->
        {id, nil}
      end)

    empty_last_granted =
      Map.new(model_ids, fn id ->
        {id, %{}}
      end)

    empty_holders =
      Map.new(model_ids, fn id ->
        {id, MapSet.new()}
      end)

    empty_queues =
      Map.new(model_ids, fn id ->
        {id, :queue.new()}
      end)

    default_profile = List.first(profiles)

    {default_model, default_params, default_concurrency} =
      case default_profile do
        nil ->
          {nil, [], 3}

        profile ->
          model = Map.get(profile, :model)
          params = EvoGit.Config.Schema.llm_generation_params(profile)
          concurrency = Map.get(profile, :concurrency, 3)
          {model, params, concurrency}
      end

    %__MODULE__{
      model_profiles: profiles,
      model_concurrency: model_concurrency,
      llm_model: Keyword.get(opts, :llm_model, default_model),
      llm_generation_params: Keyword.get(opts, :llm_generation_params, default_params),
      default_llm_max_concurrency:
        Keyword.get(opts, :default_llm_max_concurrency, default_concurrency),
      llm_holders: empty_holders,
      llm_waiting: empty_queues,
      llm_backoff_until: empty_pools,
      llm_last_granted: empty_last_granted
    }
  end

  @doc """
  Returns the concurrency limit for a given model_id, falling back to the
  state's `default_llm_max_concurrency` if the model is not in the map.

  `0` is a valid value: it is the PeakHourEngine's hard-pause signal meaning
  "this model has zero LLM slots right now" (a `Map.get` on an explicit `0`
  entry returns 0, never the default).
  """
  @spec concurrency_for(t(), String.t()) :: non_neg_integer()
  def concurrency_for(%__MODULE__{} = state, model_id) do
    Map.get(state.model_concurrency, model_id, state.default_llm_max_concurrency)
  end

  @doc """
  Returns the holder MapSet for a given model_id, creating an empty one
  if the model is not in the map (backward compat for unknown models).
  """
  @spec holders_for(t(), String.t()) :: MapSet.t(pos_integer())
  def holders_for(%__MODULE__{} = state, model_id) do
    Map.get(state.llm_holders, model_id, MapSet.new())
  end

  @doc """
  Returns the waiting queue for a given model_id, creating an empty one
  if the model is not in the map.
  """
  @spec waiting_for(t(), String.t()) :: :queue.queue(term())
  def waiting_for(%__MODULE__{} = state, model_id) do
    Map.get(state.llm_waiting, model_id, :queue.new())
  end

  @doc """
  Returns the backoff timestamp for a given model_id (nil if no backoff).
  """
  @spec backoff_for(t(), String.t()) :: integer() | nil
  def backoff_for(%__MODULE__{} = state, model_id) do
    Map.get(state.llm_backoff_until, model_id)
  end

  @doc """
  Returns the last_granted map for a given model_id (empty map if none).
  """
  @spec last_granted_for(t(), String.t()) :: %{optional(pos_integer()) => integer()}
  def last_granted_for(%__MODULE__{} = state, model_id) do
    Map.get(state.llm_last_granted, model_id, %{})
  end

  @doc """
  Updates the holder MapSet for a given model_id, creating the pool entry
  if it doesn't exist.
  """
  @spec update_holders(t(), String.t(), MapSet.t(pos_integer())) :: t()
  def update_holders(%__MODULE__{} = state, model_id, holders) do
    %{state | llm_holders: Map.put(state.llm_holders, model_id, holders)}
  end

  @doc """
  Updates the waiting queue for a given model_id, creating the pool entry
  if it doesn't exist.
  """
  @spec update_waiting(t(), String.t(), :queue.queue(term())) :: t()
  def update_waiting(%__MODULE__{} = state, model_id, waiting) do
    %{state | llm_waiting: Map.put(state.llm_waiting, model_id, waiting)}
  end

  @doc """
  Sets the backoff timestamp for a given model_id.
  """
  @spec update_backoff(t(), String.t(), integer() | nil) :: t()
  def update_backoff(%__MODULE__{} = state, model_id, timestamp) do
    %{state | llm_backoff_until: Map.put(state.llm_backoff_until, model_id, timestamp)}
  end

  @doc """
  Updates the last_granted map for a given model_id, creating the pool entry
  if it doesn't exist.
  """
  @spec update_last_granted(t(), String.t(), %{optional(pos_integer()) => integer()}) :: t()
  def update_last_granted(%__MODULE__{} = state, model_id, last_granted) do
    %{state | llm_last_granted: Map.put(state.llm_last_granted, model_id, last_granted)}
  end

  @doc """
  Returns the union of all model_ids that have pool entries: the configured
  `model_concurrency` keys plus any live/stale pool entries in the LLM holder,
  waiting, or backoff maps.

  Stale model ids — e.g. agents whose ETS `model_id` no longer matches a
  configured profile after a profiles update removed their profile, or agents
  requesting a model that was never in the profiles — remain visible so the
  slot sweeps in `EvoGit.AgentScheduler.Slots` can release their holders and
  grant their queued waiters. Their capacity is `concurrency_for/2`'s fallback
  (`default_llm_max_concurrency`), which is correct and safe.
  """
  @spec all_model_ids(t()) :: [String.t()]
  def all_model_ids(%__MODULE__{} = state) do
    state.model_concurrency
    |> Map.keys()
    |> Kernel.++(Map.keys(state.llm_holders))
    |> Kernel.++(Map.keys(state.llm_waiting))
    |> Kernel.++(Map.keys(state.llm_backoff_until))
    |> Enum.uniq()
  end

  # --- Config Update ---

  @doc """
  Updates the scheduler state with the given runtime configuration options.

  Returns a GenServer reply tuple `{:reply, :ok, state}`.
  """
  @spec do_update_config(keyword(), t()) :: {:reply, :ok, t()}
  def do_update_config(opts, %__MODULE__{} = state) do
    # Reload model profiles from config if model_profiles is being updated,
    # or if llm_model is being updated (backward compat: updates default profile)
    state =
      if Keyword.has_key?(opts, :model_profiles) do
        profiles = Keyword.get(opts, :model_profiles)
        # Pass opts through so a :default_llm_max_concurrency override in the
        # same update is honored instead of being clobbered by the first
        # profile's concurrency.
        pool_state = from_model_profiles(profiles, opts)

        # Preserve LIVE per-model LLM pools from the old state: holders must
        # stay counted (over-grant prevention) and queued waiters' GenServer
        # `from` refs must never be dropped (a dropped from = permanently
        # blocked agent). Old entries win for ids present in both; brand-new
        # profile ids keep the fresh empty entries; stale pool ids (profiles
        # removed at runtime) keep their live entries so the slot sweeps can
        # still release/grant them.
        pool_state = %__MODULE__{
          pool_state
          | llm_holders: Map.merge(pool_state.llm_holders, state.llm_holders),
            llm_waiting: Map.merge(pool_state.llm_waiting, state.llm_waiting),
            llm_backoff_until: Map.merge(pool_state.llm_backoff_until, state.llm_backoff_until),
            llm_last_granted: Map.merge(pool_state.llm_last_granted, state.llm_last_granted)
        }

        pool_state = prune_empty_pools(pool_state)

        # Merge non-LLM fields from the old state
        %__MODULE__{
          pool_state
          | agent_max_retries: Keyword.get(opts, :agent_max_retries, state.agent_max_retries),
            max_depth: Keyword.get(opts, :max_depth, state.max_depth),
            max_retries: Keyword.get(opts, :max_retries, state.max_retries),
            max_turns: Keyword.get(opts, :max_turns, state.max_turns),
            max_turns_root: Keyword.get(opts, :max_turns_root, state.max_turns_root),
            next_agent_id: state.next_agent_id,
            ref_to_agent: state.ref_to_agent,
            queue: state.queue,
            task_local_counters: state.task_local_counters,
            task_agent_counts: state.task_agent_counts,
            paused: state.paused,
            tool_holders: state.tool_holders,
            tool_waiting: state.tool_waiting,
            max_tool_concurrency:
              Keyword.get(opts, :max_tool_concurrency, state.max_tool_concurrency),
            sandbox_mode: Keyword.get(opts, :sandbox_mode, state.sandbox_mode),
            sandbox_resources: Keyword.get(opts, :sandbox_resources, state.sandbox_resources),
            sandbox_process_resources:
              Keyword.get(opts, :sandbox_process_resources, state.sandbox_process_resources)
        }
      else
        state
      end

    # Apply all field updates. `:model_concurrency` replaces the per-model map
    # and re-applies the active default floor (dynamic engine updates — e.g.
    # PeakHourEngine — must never drop a CLI -c / runtime floor).
    state =
      state
      |> maybe_apply_default_llm_concurrency(opts)
      |> maybe_update_model_concurrency(opts)
      |> maybe_update(:agent_max_retries, opts)
      |> maybe_update(:max_depth, opts)
      |> maybe_update(:llm_model, opts)
      |> maybe_update(:max_retries, opts)
      |> maybe_update(:max_turns, opts)
      |> maybe_update(:max_turns_root, opts)
      |> maybe_update(:max_tool_concurrency, opts)
      |> maybe_update(:sandbox_mode, opts)
      |> maybe_update(:sandbox_resources, opts)
      |> maybe_update(:sandbox_process_resources, opts)
      |> maybe_update(:llm_generation_params, opts)

    # Propagate sandbox resource changes to the live slice (Linux only)
    state =
      if Keyword.has_key?(opts, :sandbox_resources) and EvoGit.Platform.linux?() do
        resources = Keyword.get(opts, :sandbox_resources)

        case EvoGit.SandboxSlice.update_resources(resources) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to update sandbox slice resources: #{inspect(reason)}")
        end

        state
      else
        state
      end

    # Grant any newly-available slots to waiting agents. This sweep runs for
    # EVERY update (including :model_concurrency replacements), so a capacity
    # increase from a new per-model map — or from the :default_llm_max_concurrency
    # floor — is granted automatically. Do NOT add a second sweep call here.
    {state, status_updates} = Slots.grant_pending_on_resume(state)
    Lifecycle.apply_status_updates(status_updates)

    Logger.info(
      "AgentScheduler: Config updated — default_llm_max_concurrency: #{state.default_llm_max_concurrency}, " <>
        "max_tool_concurrency: #{state.max_tool_concurrency}, " <>
        "agent_max_retries: #{state.agent_max_retries}, max_depth: #{state.max_depth}"
    )

    EvoGit.AgentScheduler.PubSub.broadcast_config_updated()

    {:reply, :ok, state}
  end

  @doc """
  Conditionally updates a single field in the state struct from the given opts keyword list.
  If the key is not present in opts, returns the state unchanged.
  """
  @spec maybe_update(t(), atom(), keyword()) :: t()
  def maybe_update(%__MODULE__{} = state, key, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> struct(state, [{key, value}])
      :error -> state
    end
  end

  @doc """
  Applies a runtime `default_llm_max_concurrency` override (floor semantics).

  Sets `state.default_llm_max_concurrency` to the new value AND raises every
  per-model concurrency limit to at least that value: the default acts as a
  lower bound on ALL live pools, so raising it takes effect immediately for
  every model — both with and without `[[llm.models]]` profiles. Explicit
  profile concurrencies above the new default are never lowered (profiles
  still win when their concurrency is higher).

  An explicit `0` entry is the PeakHourEngine's **hard-pause** signal and is
  preserved as-is (never floored): `{id, 0}` means "this model has zero LLM
  slots during the peak window", and flooring it to `new_default` would
  silently re-enable the model. This preservation is also the fixed-point
  invariant that keeps the engine's re-broadcast loop stable: the engine emits
  0 → State stores 0 → re-broadcast → engine re-checks `effective_concurrency`
  → no-op.

  Note: this floor applies to runtime `update_config` only. At init, the file
  semantics remain "profile wins" (`from_model_profiles/2` does not floor).

  This floor is bypassed ONLY when the caller passes `model_concurrency_skip_floor:
  true` on a `model_concurrency` update (the PeakHourEngine sets it — the engine
  owns the floor logic in that case, including its explicit in-peak
  `peak_concurrency` exemptions, and storing verbatim preserves its fixed-point
  invariant). The hard-pause `0` exemption and all other paths are unchanged.
  """
  @spec apply_default_llm_concurrency_override(t(), pos_integer()) :: t()
  def apply_default_llm_concurrency_override(%__MODULE__{} = state, new_default) do
    %__MODULE__{
      state
      | default_llm_max_concurrency: new_default,
        model_concurrency:
          Map.new(state.model_concurrency, fn {id, concurrency} ->
            {id, if(concurrency == 0, do: 0, else: max(concurrency, new_default))}
          end)
    }
  end

  defp maybe_apply_default_llm_concurrency(%__MODULE__{} = state, opts) do
    case Keyword.fetch(opts, :default_llm_max_concurrency) do
      {:ok, value} -> apply_default_llm_concurrency_override(state, value)
      :error -> state
    end
  end

  # Replaces `model_concurrency` with the given `%{model_id => pos_integer()}`
  # map (wall-clock dynamic overrides, e.g. PeakHourEngine), then re-applies
  # the active floor: an engine update with values below an active
  # `default_llm_max_concurrency` (CLI `-c` / runtime override) must NEVER
  # silently drop the floor. `apply_default_llm_concurrency_override/2` also
  # re-sets `default_llm_max_concurrency` to the passed value — passing the
  # current state value keeps it unchanged, which is correct.
  #
  # The `:model_concurrency_skip_floor` opt (boolean, default false) bypasses
  # the re-floor: when truthy the map is stored VERBATIM. PeakHourEngine sets
  # it — the engine's map is already floored with explicit in-peak
  # `peak_concurrency` exemptions, so the scheduler must not re-floor. Storing
  # verbatim is what preserves the engine's fixed-point invariant (the engine
  # re-check compares its own map against the stored map → no loop). ALL other
  # update paths (CLI `-c` / runtime `default_llm_max_concurrency` override via
  # `maybe_apply_default_llm_concurrency/2`, and any `model_concurrency` send
  # WITHOUT the opt) keep the documented floor semantics unchanged.
  defp maybe_update_model_concurrency(%__MODULE__{} = state, opts) do
    case Keyword.fetch(opts, :model_concurrency) do
      {:ok, map} ->
        if Keyword.get(opts, :model_concurrency_skip_floor, false) do
          struct(state, model_concurrency: map)
        else
          state
          |> struct(model_concurrency: map)
          |> apply_default_llm_concurrency_override(state.default_llm_max_concurrency)
        end

      :error ->
        state
    end
  end

  # Drops per-model pool entries whose values are empty (empty holder MapSet,
  # empty waiting queue, nil backoff, empty last_granted map). Safe because
  # all `holders_for`/`waiting_for`/`backoff_for`/`last_granted_for` accessors
  # default gracefully, and `all_model_ids/1` keeps configured profile ids
  # visible via `model_concurrency` even when their pool entries are pruned.
  defp prune_empty_pools(%__MODULE__{} = state) do
    %__MODULE__{
      state
      | llm_holders:
          Map.filter(state.llm_holders, fn {_id, holders} -> MapSet.size(holders) > 0 end),
        llm_waiting:
          Map.filter(state.llm_waiting, fn {_id, waiting} -> not :queue.is_empty(waiting) end),
        llm_backoff_until:
          Map.filter(state.llm_backoff_until, fn {_id, backoff} -> backoff != nil end),
        llm_last_granted:
          Map.filter(state.llm_last_granted, fn {_id, last_granted} ->
            map_size(last_granted) > 0
          end)
    }
  end
end
