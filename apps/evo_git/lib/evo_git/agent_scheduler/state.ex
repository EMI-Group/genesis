defmodule EvoGit.AgentScheduler.State do
  @moduledoc """
  GenServer state struct for `EvoGit.AgentScheduler`.

  Holds the full scheduler state including worktree pool configuration,
  slot management queues, agent tracking maps, and run metadata.

  ## Fields

  ### Initialization
  - `initialized` — whether the scheduler has completed initialization
  - `initialized_repos` — map of absolute repo paths that have been initialized (`%{String.t() => true}`)

  ### Configuration
  - `max_concurrency` — maximum concurrent LLM calls (LLM slot pool size)
  - `max_tool_concurrency` — maximum concurrent tool executions (tool slot pool size)
  - `agent_max_retries` — crash-retry limit per agent
  - `max_depth` — maximum agent recursion depth
  - `llm_model` — the LLM model identifier passed to ReqLLM
  - `llm_generation_params` — LLM generation parameters (temperature, max_tokens, etc.) passed to ReqLLM calls
  - `max_retries` — maximum total retries across the scheduler
  - `max_turns` — maximum turns per agent loop
  - `max_turns_root` — maximum turns for the root (top-level) agent only

  ### Agent Lifecycle
  - `next_agent_id` — monotonically increasing agent ID counter
  - `task_local_counters` — map of `task_id (string) => next_local_id` for per-task agent numbering
  - `task_agent_counts` — map of `task_id (string) => total agents spawned` (for stats reporting)
  - `ref_to_agent` — maps `Task` monitor references to agent IDs
  - `queue` — FIFO queue of agent IDs waiting for a worktree

  ### LLM Slot Management
  - `llm_holders` — `MapSet` of agent IDs currently holding an LLM slot
  - `llm_waiting` — FIFO queue of `{agent_id, from}` pairs blocked on an LLM slot
  - `llm_backoff_until` — monotonic timestamp until which all LLM calls are paused (`nil` when none)
  - `llm_last_granted` — map of `agent_id => monotonic_millisecond_timestamp`, tracking when each agent was last granted an LLM slot (for recency-based prioritization)

  ### Pause Control
  - `paused` — whether the scheduler is paused (no new slots or agent dispatches granted)

  ### Tool Slot Management
  - `tool_holders` — `MapSet` of agent IDs currently holding a tool slot
  - `tool_waiting` — FIFO queue of `{agent_id, from}` pairs blocked on a tool slot
  """

  @enforce_keys []
  defstruct initialized: false,
            initialized_repos: %{},
            max_concurrency: 3,
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
            llm_holders: MapSet.new(),
            llm_waiting: :queue.new(),
            llm_backoff_until: nil,
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
          llm_holders: MapSet.t(pos_integer()),
          llm_waiting: :queue.queue(term()),
          llm_backoff_until: integer() | nil,
          llm_last_granted: %{optional(pos_integer()) => integer()},
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
end
