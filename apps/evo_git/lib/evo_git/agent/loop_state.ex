defmodule EvoGit.Agent.LoopState do
  @moduledoc """
  Loop state threaded through the agent's turn loop.

  Created once when the agent starts running and updated on every turn. Holds
  bookkeeping data such as the conversation context, timeout deadline, LLM
  usage metrics, and warning thresholds — everything the generic agent loop
  (`EvoGit.Agent.__using__/1`) needs to decide whether to continue, warn, or
  stop.

  ## Fields

  - `agent_id` — scheduler-assigned integer agent ID
  - `agent_module` — the agent implementation module (e.g. `EvoGit.Agents.Generalist`)
  - `depth` — recursion depth (0 for top-level agents)
  - `node_path` — the context-node path this agent is working on
  - `repo_path` — absolute path to the agent's worktree, or `nil` before assignment
  - `turn` — current turn number in the agent loop (starts at 0)
  - `context` — the LLM conversation context (`ReqLLM.Context.t()`)
  - `in_grace_period` — whether the agent is in a grace period after a warning
  - `deadline` — monotonic time (ms) when the agent must finish
  - `llm_time_ms` — cumulative milliseconds spent in LLM calls
  - `total_tokens` — cumulative token count across all LLM calls
  - `last_warned_time_percent` — last time-percent at which a timeout warning was emitted
  - `timeout_ms` — configured agent session timeout in milliseconds
  """

  @enforce_keys [:agent_id, :agent_module, :depth, :node_path, :context]
  defstruct [
    :agent_id,
    :agent_module,
    :depth,
    :node_path,
    :context,
    repo_path: nil,
    turn: 0,
    timeout_ms: 1_800_000,
    in_grace_period: false,
    deadline: 0,
    llm_time_ms: 0,
    total_tokens: 0,
    last_warned_time_percent: 0,
    skill_schemas: []
  ]

  @type t :: %__MODULE__{
          agent_id: pos_integer(),
          agent_module: module(),
          depth: non_neg_integer(),
          node_path: String.t(),
          repo_path: String.t() | nil,
          turn: non_neg_integer(),
          timeout_ms: pos_integer(),
          context: ReqLLM.Context.t(),
          in_grace_period: boolean(),
          deadline: integer(),
          llm_time_ms: non_neg_integer(),
          total_tokens: non_neg_integer(),
          last_warned_time_percent: non_neg_integer(),
          skill_schemas: [ReqLLM.Tool.t()]
        }
end
