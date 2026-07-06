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

  ### Initialization
  - `initialized` — whether the scheduler has completed initialization
  - `initialized_repos` — map of absolute repo paths that have been initialized (`%{String.t() => true}`)

  ### Configuration
  - `max_concurrency` — backward-compat default concurrency limit (mirrors the default profile's concurrency)
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
  defstruct initialized: false,
            initialized_repos: %{},
            max_concurrency: 3,
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
          initialized: boolean(),
          initialized_repos: %{String.t() => true},
          max_concurrency: pos_integer(),
          model_concurrency: %{String.t() => pos_integer()},
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
      max_concurrency: Keyword.get(opts, :max_concurrency, default_concurrency),
      llm_holders: empty_holders,
      llm_waiting: empty_queues,
      llm_backoff_until: empty_pools,
      llm_last_granted: empty_last_granted
    }
  end

  @doc """
  Returns the concurrency limit for a given model_id, falling back to the
  state's `max_concurrency` (backward compat) if the model is not in the map.
  """
  @spec concurrency_for(t(), String.t()) :: pos_integer()
  def concurrency_for(%__MODULE__{} = state, model_id) do
    Map.get(state.model_concurrency, model_id, state.max_concurrency)
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
  Returns a list of all model_ids that have pools configured.
  Falls back to the model_concurrency keys.
  """
  @spec all_model_ids(t()) :: [String.t()]
  def all_model_ids(%__MODULE__{} = state) do
    Map.keys(state.model_concurrency)
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
        pool_state = from_model_profiles(profiles)
        # Merge non-LLM fields from the old state
        %__MODULE__{
          pool_state
          | initialized: state.initialized,
            initialized_repos: state.initialized_repos,
            agent_max_retries: Keyword.get(opts, :agent_max_retries, state.agent_max_retries),
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

    # Apply all field updates
    state =
      state
      |> maybe_update(:max_concurrency, opts)
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

    # Grant any newly-available slots to waiting agents
    {state, status_updates} = Slots.grant_pending_on_resume(state)
    Lifecycle.apply_status_updates(status_updates)

    Logger.info(
      "AgentScheduler: Config updated — max_concurrency: #{state.max_concurrency}, " <>
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
end
