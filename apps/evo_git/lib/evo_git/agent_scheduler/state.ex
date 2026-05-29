defmodule EvoGit.AgentScheduler.State do
  @moduledoc """
  GenServer state struct for `EvoGit.AgentScheduler`.

  Holds the full scheduler state including worktree pool configuration,
  slot management queues, agent tracking maps, and run metadata.

  ## Fields

  ### Initialization
  - `initialized` — whether the scheduler has completed initialization
  - `repo_root` — absolute path to the primary repository root
  - `repos` — registered foreign repos keyed by atom id
  - `base_sha` — the Git SHA at which all agent worktrees are branched

  ### Configuration
  - `max_concurrency` — maximum concurrent LLM calls (LLM slot pool size)
  - `max_tool_concurrency` — maximum concurrent tool executions (tool slot pool size)
  - `agent_max_retries` — crash-retry limit per agent
  - `max_depth` — maximum agent recursion depth
  - `llm_model` — the LLM model identifier passed to ReqLLM
  - `max_retries` — maximum total retries across the scheduler

  ### Agent Lifecycle
  - `next_agent_id` — monotonically increasing agent ID counter
  - `next_task_id` — monotonically increasing task ID counter (groups subagents)
  - `running_count` — number of currently executing agents
  - `ref_to_agent` — maps `Task` monitor references to agent IDs
  - `queue` — FIFO queue of agent IDs waiting for a worktree

  ### LLM Slot Management
  - `llm_slots_available` — remaining LLM slots in the pool
  - `llm_waiting` — FIFO queue of `{agent_id, from}` pairs blocked on an LLM slot
  - `llm_backoff_until` — monotonic timestamp until which all LLM calls are paused (`nil` when none)

  ### Tool Slot Management
  - `tool_slots_available` — remaining tool slots in the pool
  - `tool_waiting` — FIFO queue of `{agent_id, from}` pairs blocked on a tool slot
  """

  alias EvoGit.Core.ForeignRepo

  @enforce_keys []
  defstruct [
    initialized: false,
    repo_root: nil,
    repos: %{},
    base_sha: nil,
    max_concurrency: 3,
    agent_max_retries: 3,
    max_depth: 8,
    llm_model: nil,
    max_retries: 15,
    next_agent_id: 1,
    running_count: 0,
    ref_to_agent: %{},
    queue: :queue.new(),
    llm_slots_available: 3,
    llm_waiting: :queue.new(),
    llm_backoff_until: nil,
    tool_slots_available: 2,
    tool_waiting: :queue.new(),
    max_tool_concurrency: 2,
    next_task_id: 1
  ]

  @type t :: %__MODULE__{
          initialized: boolean(),
          repo_root: String.t() | nil,
          repos: %{atom() => ForeignRepo.t()},
          base_sha: String.t() | nil,
          max_concurrency: pos_integer(),
          agent_max_retries: non_neg_integer(),
          max_depth: pos_integer(),
          llm_model: ReqLLM.model_input(),
          max_retries: pos_integer(),
          next_agent_id: pos_integer(),
          running_count: non_neg_integer(),
          ref_to_agent: %{reference() => pos_integer()},
          queue: :queue.queue(pos_integer()),
          llm_slots_available: non_neg_integer(),
          llm_waiting: :queue.queue(term()),
          llm_backoff_until: integer() | nil,
          tool_slots_available: non_neg_integer(),
          tool_waiting: :queue.queue(term()),
          max_tool_concurrency: pos_integer(),
          next_task_id: pos_integer()
        }
end
