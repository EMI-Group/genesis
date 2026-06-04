defmodule EvoGit.Agent.LoopState do
  @moduledoc """
  Loop state threaded through the agent's turn loop.

  Created once when the agent starts running and updated on every turn. Holds
  bookkeeping data such as the conversation context, turn-limit configuration,
  and warning thresholds — everything the generic agent loop
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
  - `max_turns` — maximum turns allowed for this agent (from config)
  - `total_tokens` — cumulative token count across all LLM calls
  - `last_warned_turns_percent` — last turn-percent at which a turn-limit warning was emitted
  - `skill_schemas` — tool schemas from enabled skills
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
    in_grace_period: false,
    max_turns: 128,
    total_tokens: 0,
    last_warned_turns_percent: 0,
    skill_schemas: []
  ]

  @type t :: %__MODULE__{
          agent_id: pos_integer(),
          agent_module: module(),
          depth: non_neg_integer(),
          node_path: String.t(),
          repo_path: String.t() | nil,
          turn: non_neg_integer(),
          context: ReqLLM.Context.t(),
          in_grace_period: boolean(),
          max_turns: pos_integer(),
          total_tokens: non_neg_integer(),
          last_warned_turns_percent: non_neg_integer(),
          skill_schemas: [ReqLLM.Tool.t()]
        }
end
