defmodule EvoGit.AgentScheduler.AgentState do
  @moduledoc """
  The ETS/summary PROJECTION of an agent — a read model, NOT the authoritative state.

  The authoritative agent state is `%EvoGit.Agent.State{}`: exactly ONE copy of
  it, owned by exactly one process (in P1 the agent `Task`, from P2 the
  per-agent session process). This struct is what the scheduler publishes into
  the `:evogit_agent_state` ETS table so that the dashboard/RPC read paths can
  observe an agent without touching its process.

  Its row shape is bounded to what a reader needs (identity, counters, model
  selection, the summary-only fields added below) plus, for now, the fields the
  turn loop still reads and writes directly. A subscriber must treat every row
  here as a possibly-stale SNAPSHOT: the process owning the agent is the only
  writer, and after the refactor it only publishes summary updates.

  ## Transitional fields (removed from this row in a later phase)

  These five fields exist only because the loop still reads them from this ETS
  row (P1/P2). They must stay until the engine reads that control plane from the
  `%EvoGit.Agent.State{}` it owns instead:

  - `context` — the conversation context (to be replaced by the authoritative
    `State.context`; the ETS copy disappears with the summary re-keying)
  - `pending_user_messages` — the injected-message queue (to be replaced by
    `State.pending_inputs`)
  - `cancel_requested` — the graceful-cancel flag (to be replaced by
    `State.cancel`)
  - `phylo_node` — the temporal state node (derived; not summary information)
  - `llm_generation_params` — the generation parameters (conversation data, not
    summary information)

  ## Summary fields the projection owns

  `status`, `mode`, `objective_preview`, `message_count`, `context_window`,
  `current_commit`, `last_activity_at`.

  ## Other fields

  - `context_node` — the spatial state (ContextNode) the agent is targeting
  - `llm_model` — the LLM model string for this agent to use
  - `llm_context_window` — the agent's configured LLM context window in tokens (from its model profile's `context_window`), used for the compression threshold and the stage-1 pruning target; defaults to 200_000
  - `model_id` — optional legacy selection id for compatibility/display, not resource identity.
  - `provider_profile_id` — immutable provider/account resource key for shared concurrency and backoff.
  - `model_spec` — canonical string-keyed provider/model/optional reasoning-effort selection, independent of runtime credentials and parameters.
  - `model_id_locked` — a task-level selection lock inherited together with the full model_spec by descendants.
  - `max_retries` — maximum LLM call retries for this agent
  - `max_depth` — maximum agent recursion depth
  - `max_turns` — maximum turns per agent loop
  - `parent_id` — the parent agent ID (if this is a subagent), or `nil`
  - `objective` — the objective/task the agent was given
  - `repo_id` — string identifying which repo this agent belongs to (`"primary"` for main, or a foreign repo id)
  - `repo_root` — absolute filesystem path to the repo root (for display/grouping). Set from scheduler state at registration.
  - `task_local_id` — per-task agent number (starts at 1 for each task), used for display and workspace/branch naming
  - `foreign_repos` — list of foreign repos available to this agent (inherited from parent; root agents get this from CLI opts or genesis.toml)
  - `repo_notes` — the already-rendered git-submodules note block (markdown text) for this agent's repo tree, or `nil` when the repo has no submodules (or detection failed). Rendered into the agent's `<context>` block; subagents inherit it from the parent (no re-detection).
  - `usage` — cumulative token and cost usage for this agent (`nil` until the first LLM call completes)
  - `turn` — the current turn number for this agent (`nil` until the loop starts; mirrors `EvoGit.Agent.State.turn`). Used by the dashboard to display the actual turn rather than a fabricated index.
  - `archive` — whether task archiving is enabled for this agent (writes git refs + ETS records on completion)
  - `compression_count` — number of times context compression has fired for this agent
  - `total_tokens` — cumulative token count across all LLM calls since the last compression (mirrors `EvoGit.Agent.State.total_tokens`). Used by the dashboard to display context progress. Reset to 0 on each compression.
  """

  alias EvoGit.Agent.Usage
  alias EvoGit.Attachments
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.PhyloGraphNode

  @enforce_keys [:context_node, :llm_model, :max_retries, :max_depth]
  defstruct [
    # --- today's row shape, kept VERBATIM (name + default) ---
    # `context` is TRANSITIONAL (the authoritative copy is `State.context`).
    :context,
    :context_node,
    # `phylo_node` is TRANSITIONAL (derived; not summary information).
    :phylo_node,
    :llm_model,
    :max_retries,
    :max_depth,
    :max_turns,
    :parent_id,
    :objective,
    :task_local_id,
    :turn,
    model_id: "default",
    provider_profile_id: nil,
    model_spec: nil,
    model_id_locked: false,
    archive: false,
    usage: nil,
    compression_count: 0,
    total_tokens: 0,
    # `llm_generation_params` is TRANSITIONAL (conversation data, not summary).
    llm_generation_params: [],
    llm_context_window: 200_000,
    repo_id: "primary",
    repo_root: nil,
    foreign_repos: [],
    repo_notes: nil,
    # `pending_user_messages` is TRANSITIONAL (replaced by `State.pending_inputs`).
    pending_user_messages: [],
    # `cancel_requested` is TRANSITIONAL (replaced by `State.cancel`).
    cancel_requested: nil,
    # --- summary-row fields owned by the projection ---------------------------
    status: nil,
    mode: :oneshot,
    objective_preview: nil,
    message_count: 0,
    context_window: nil,
    current_commit: nil,
    last_activity_at: nil
  ]

  @type t :: %__MODULE__{
          context: ReqLLM.Context.t() | nil,
          context_node: ContextNode.t(),
          phylo_node: PhyloGraphNode.t() | nil,
          llm_model: ReqLLM.model_input(),
          llm_generation_params: keyword(),
          llm_context_window: pos_integer(),
          model_id: String.t() | nil,
          provider_profile_id: String.t() | nil,
          model_spec: map() | nil,
          model_id_locked: boolean(),
          max_retries: pos_integer(),
          max_depth: pos_integer(),
          max_turns: pos_integer(),
          parent_id: pos_integer() | nil,
          objective: String.t() | nil,
          repo_id: String.t(),
          repo_root: String.t() | nil,
          task_local_id: pos_integer() | nil,
          usage: Usage.t() | nil,
          turn: non_neg_integer() | nil,
          archive: boolean(),
          compression_count: non_neg_integer(),
          total_tokens: non_neg_integer(),
          foreign_repos: [ForeignRepo.t()],
          repo_notes: String.t() | nil,
          pending_user_messages: [String.t() | Attachments.message()],
          cancel_requested: boolean() | nil,
          status: atom() | nil,
          mode: :oneshot | :interactive,
          objective_preview: String.t() | nil,
          message_count: non_neg_integer(),
          context_window: pos_integer() | nil,
          current_commit: String.t() | nil,
          last_activity_at: DateTime.t() | nil
        }
end
