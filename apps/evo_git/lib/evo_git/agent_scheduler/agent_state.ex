defmodule EvoGit.AgentScheduler.AgentState do
  @moduledoc """
  The SUMMARY projection of an agent — a read model, NOT the authoritative state.

  The authoritative agent state is `%EvoGit.Agent.State{}`: exactly ONE copy of
  it, owned by exactly one process (the per-agent `EvoGit.Agent.Session`). This
  struct is what the scheduler publishes into the `:evogit_agent_summary` ETS
  table so that the dashboard/RPC read paths can observe an agent without
  touching its process.

  It carries NO conversation and no cross-process control state: the injected
  message queue and the graceful-cancel flag live in
  `EvoGit.AgentScheduler.ControlPlane`, and the messages themselves are served
  by `EvoGit.Agent.Session.history/2`.

  ## Writers

  Exactly ONE runtime writer: the owning session, through
  `EvoGit.Agent.Session.Summary.publish/3`, which copies the summary-relevant
  fields of its `%EvoGit.Agent.State{}` onto the row. The remaining writes are
  REGISTRATION writes (`Dispatch` creates the row; `Worktrees` and `Lifecycle`
  update the commit/retry fields).

  Every row is therefore a possibly-stale SNAPSHOT of the agent's own state — a
  reader must never treat it as authoritative.

  ## Fields

  - `context_node` — the spatial state (ContextNode) the agent is targeting
  - `llm_model` — the LLM model string for this agent to use
  - `llm_generation_params` — REGISTRATION-ONLY immutable generation parameters (temperature, max_tokens, etc.): read ONCE by the session at `:starting` to build the authoritative `%EvoGit.Agent.State{}`, never written afterwards
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
  - `usage` — cumulative token and cost usage for this agent (`nil` until the first LLM call completes)
  - `turn` — the current turn number for this agent (`nil` until the loop starts; mirrors `EvoGit.Agent.State.turn`). Used by the dashboard to display the actual turn rather than a fabricated index.
  - `archive` — whether task archiving is enabled for this agent (writes git refs + ETS records on completion)
  - `compression_count` — number of times context compression has fired for this agent
  - `total_tokens` — cumulative token count across all LLM calls since the last compression (mirrors `EvoGit.Agent.State.total_tokens`). Used by the dashboard to display context progress. Reset to 0 on each compression.
  - `foreign_repos` — list of foreign repos available to this agent (inherited from parent; root agents get this from CLI opts or genesis.toml)
  - `repo_notes` — the already-rendered git-submodules note block (markdown text) for this agent's repo tree, or `nil` when the repo has no submodules (or detection failed). Rendered into the agent's `<context>` block; subagents inherit it from the parent (no re-detection).
  - `status` — the summary status (`:pending`/`:running`/`:done`/`:failed`), published by the session
  - `mode` — `:oneshot` or `:interactive`
  - `objective_preview` — a bounded (≤ 4096 characters) preview of the objective, published for display
  - `message_count` — number of messages in the session's conversation
  - `context_window` — the resolved configured context window in tokens
  - `current_commit` — the worktree HEAD the agent last observed
  - `last_activity_at` — when the row last actually changed
  """

  alias EvoGit.Agent.Usage
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo

  @enforce_keys [:context_node, :llm_model, :max_retries, :max_depth]
  defstruct context_node: nil,
            llm_model: nil,
            # REGISTRATION-ONLY immutable input: read ONCE by the session at `:starting`.
            llm_generation_params: [],
            llm_context_window: 200_000,
            model_id: "default",
            provider_profile_id: nil,
            model_spec: nil,
            model_id_locked: false,
            max_retries: nil,
            max_depth: nil,
            max_turns: nil,
            parent_id: nil,
            objective: nil,
            repo_id: "primary",
            repo_root: nil,
            task_local_id: nil,
            usage: nil,
            turn: nil,
            archive: false,
            compression_count: 0,
            total_tokens: 0,
            foreign_repos: [],
            repo_notes: nil,
            status: nil,
            mode: :oneshot,
            objective_preview: nil,
            message_count: 0,
            context_window: nil,
            current_commit: nil,
            last_activity_at: nil

  @type t :: %__MODULE__{
          context_node: ContextNode.t(),
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
          status: atom() | nil,
          mode: :oneshot | :interactive,
          objective_preview: String.t() | nil,
          message_count: non_neg_integer(),
          context_window: pos_integer() | nil,
          current_commit: String.t() | nil,
          last_activity_at: DateTime.t() | nil
        }
end
