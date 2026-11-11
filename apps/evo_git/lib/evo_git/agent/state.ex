defmodule EvoGit.Agent.State do
  @moduledoc """
  The ONE authoritative agent state of the runtime.

  There is exactly ONE copy of it in the system, owned by exactly one process —
  the agent's `EvoGit.Agent.Session`. `%EvoGit.AgentScheduler.AgentState{}` is
  only the summary read model of this struct.

  Its fields fall into four groups: identity, conversation, control and budget.
  `EvoGit.Agent.Exchange.run/2` consumes the struct and threads it through every
  turn of ONE exchange, and `EvoGit.Agent.Session.Setup.build_initial_state/3`
  builds the initial value before that call.

  The `EvoGit.Agent.Session` process owns this struct — the exchange engine stays
  a pure function over it — and the per-exchange worker installs the DERIVED
  per-process values (the process dictionary the tools read) from it via
  `EvoGit.Agent.Session.Setup.install_process_context/3`.

  The state is SESSION-OWNED and is the ONLY copy of the conversation in the
  system: no ETS row, archive or RPC payload carries the messages. It is also
  the only copy of the cross-process control state (`pending_inputs`, `cancel`),
  which `EvoGit.Agent.Session` writes through its commands and the exchange
  drains at the top of each turn.

  ## Plain data, no runtime handles

  This struct holds no funs, no ETS handles and no ports or sockets. The ONLY
  runtime handles it carries are the session-local transport bookkeeping —
  `watchers` (consumer pid → monitor ref) and `exchange_ref` — which the
  session re-stamps onto every checkpointed copy and which never enter a
  durable snapshot, a `%EvoGit.Agent.Stream.Snapshot{}` or a JSON payload. That
  is what makes a whole-struct copy a valid SNAPSHOT at every exchange boundary
  and the result/settings payload serializable — the archive path already proves
  that payload is JSON-clean.

  ## The four groups

  ### identity (immutable after start)

  `agent_id`, `agent_module`, `task_id`, `depth`, `parent_id`, `node_path`,
  `context_node`, `repo_id`, `repo_root`, `repo_less`, `custom_agent_id`,
  `mode`, `archive`, `worktree`.

  Who this agent is and where it runs. The session installs the derived
  process-dictionary projection of these fields at exchange start (the struct
  stays authoritative, the process dictionary is only a projection). `worktree`
  belongs here because its lifetime is the session's lifetime — it is kept for
  the session's whole life and reclaimed only when the session ends.

  ### conversation (the only copy in the system)

  `context`, `turn`, `total_tokens`, `usage`, `compression_count`,
  `llm_context_window`, `llm_model`, `llm_generation_params`, `model_spec`,
  `provider_profile_id`, `model_id`, `model_id_locked`, `prompt_cache_key`,
  `objective`, `attachments`, `repo_path`, `current_commit`, `repo_notes`,
  `foreign_repos`, `skill_schemas`.

  The LLM conversation plus everything derived from the objective and the
  resolved model selection. This is the ONLY copy of the context: the ETS
  summary row carries no context at all.

  ### control (written only via commands)

  `pending_inputs`, `cancel`, `phase` (default `:starting`), `exchange_ref`
  (default `nil`), `event_seq` (default `0`), `watchers` (default `%{}`),
  `last_checkpoint_at` (default `nil`).

  Cross-process control state, changed only through the explicit session commands
  (`inspect` / `history` / `input` / `cancel`). `watchers` is the streaming gate: zero
  watchers ⇒ no chunk callbacks and no broadcast, so the LLM call path carries
  no streaming overhead.

  ### budget (per-run terminal budgets)

  `max_turns`, `exchange_turn_base`, `max_exchange_turns`, `max_session_turns`,
  `max_depth`, `max_retries`, `grace_turns_remaining`,
  `in_grace_period`, `delegation_hints`, `read_delegation_hints`,
  `delegation_level`, `last_warned_level`, `turns_since_subagent`,
  `quality_level`.

  The per-run terminal budgets and the delegation-nudge bookkeeping, read
  directly from the struct by the exchange engine
  (`EvoGit.Agent.Exchange.Grace` / `Exchange.Warnings`) instead of re-reading
  ETS every turn.

  ## Field reference

  - `agent_id` — scheduler-assigned integer agent ID
  - `agent_module` — the agent implementation module (e.g. `EvoGit.Agents.Manager`)
  - `task_id` — the owning task's 16-char hex id, or `nil` when not yet known
  - `depth` — recursion depth (0 for top-level agents)
  - `parent_id` — the parent agent's id, or `nil` when this agent is the ROOT agent of the task (exactly equivalent to depth 0). Used by the compression refresh (`ContextBuilder.refresh_first_user_message/2`) to re-apply the root-only attachment/authority/quality gates.
  - `node_path` — the context-node path this agent is working on
  - `context_node` — the `%EvoGit.Core.ContextNode{}` (the spatial state) this agent is targeting, or `nil` when not yet resolved
  - `repo_id` — string identifying which repo this agent belongs to (`"primary"` for main, or a foreign repo id)
  - `repo_root` — absolute filesystem path to the repo root (for display/grouping), or `nil` before assignment
  - `repo_less` — `true` when this agent runs without a git worktree (chatbot-style self-reflective agent). Gates the authority/quality sections + attachments off in the `<context>` block.
  - `custom_agent_id` — the custom agent definition's id when this agent was created from `<config_dir>/agents.toml`, else `nil`
  - `mode` — `:oneshot` (today's agents) or `:interactive` (opt-in sessions); decides only what a tool-free reply means
  - `archive` — whether task archiving is enabled for this agent (writes git refs + a `task_agent_archives` row on completion)
  - `worktree` — the agent's git worktree PATH, or `nil` for a repo-less agent / before the worktree is created. The worktree lease joins this field in a later phase; the worktree's lifetime is the session's lifetime.
  - `context` — the LLM conversation context (`ReqLLM.Context.t()`)
  - `turn` — current turn number in the agent loop (starts at 0)
  - `total_tokens` — cumulative token count across all LLM calls
  - `usage` — cumulative token and cost usage tracking across all LLM calls (`EvoGit.Agent.Usage.t()`)
  - `compression_count` — number of times context compression has fired for this agent
  - `llm_context_window` — the agent's configured LLM context window in tokens (from its model profile's `context_window`), used for the compression threshold and the stage-1 pruning target; defaults to 200_000
  - `llm_model` — the LLM model for this agent to use (`nil` = not yet resolved)
  - `llm_generation_params` — the LLM generation parameters (temperature, max_tokens, etc.) passed to ReqLLM calls
  - `model_spec` — canonical string-keyed provider/model/optional reasoning-effort TASK selection, independent of runtime credentials and parameters
  - `provider_profile_id` — immutable provider/account resource key for shared concurrency and backoff
  - `model_id` — optional legacy selection id for compatibility/display, not resource identity
  - `model_id_locked` — a task-level selection lock inherited together with the full model_spec by descendants
  - `prompt_cache_key` — the stable per-agent-run (per-session in `:interactive` mode) provider routing/cache identity, or `nil` when the account declares none
  - `objective` — the RAW objective string this agent was started with (never rewritten). Re-rendered by the compression refresh so the `<objective>` block stays byte-identical.
  - `attachments` — the `:attachments` value passed to `ContextBuilder.build_initial_messages/4` (already `nil` for repo-less agents), retained so the compression refresh can reproduce the root agent's media content parts.
  - `repo_path` — absolute path to the agent's worktree, or `nil` before assignment
  - `current_commit` — the worktree HEAD the engine last observed (recorded after tool execution and at completion), or `nil` — the source of the summary row's `current_commit`
  - `repo_notes` — the already-rendered git-submodules note block (markdown text) for this agent's repo tree, or `nil` when the repo has no submodules (or detection failed). Rendered into the agent's `<context>` block; subagents inherit it from the parent (no re-detection).
  - `foreign_repos` — list of foreign repos available to this agent tree (inherited from parent agent)
  - `skill_schemas` — tool schemas from enabled skills
  - `pending_inputs` — queued user inputs awaiting the next turn (`String.t()` or the canonical multimodal message map). The exchange drains and injects them at the top of each turn.
  - `cancel` — the pending cancel request, `nil` = none. Set by the session's `cancel` command and consumed by the exchange's cancel-grace path.
  - `phase` — the session lifecycle phase.
  - `exchange_ref` — the in-flight exchange worker reference, `nil` when none. Carried (always `nil`).
  - `event_seq` — monotonic per-session delta sequence number, incremented by the session once per flushed batch; a watcher drops deltas with `seq <= snapshot.seq`. Session-authoritative: a checkpointed worker copy is re-stamped with the session's value.
  - `watchers` — the live streaming consumers (consumer pid → monitor ref); empty means unwatched, which is the zero-cost default (no chunk callbacks, no batcher timer, no broadcast). Session-authoritative, like `event_seq`.
  - `last_checkpoint_at` — when the state was last checkpointed, or `nil`. Carried (always `nil`) — durability is deliberately deferred.
  - `max_turns` — maximum turns allowed for this agent (from config)
  - `exchange_turn_base` — the `turn` value at the START of the current exchange; the interactive per-exchange burst budget is measured from it (`turn - exchange_turn_base`), so a yield resets the burst without resetting the conversation.
  - `max_exchange_turns` — the per-exchange burst budget of an `:interactive` session; `nil` resolves at call time to `max_turns` (`EvoGit.Agent.exchange_turn_budget/1`).
  - `max_session_turns` — the cumulative turn cap of an `:interactive` session across every exchange; `nil` resolves at call time from the default-inert `:interactive_session_turns` seam, else `exchange_turn_budget × 10` (`EvoGit.Agent.session_turn_budget/1`).
  - `max_depth` — maximum agent recursion depth; `nil` means NO LIMIT CONFIGURED and must read that way at every comparison site. The scheduler row is always authoritative and populates it.
  - `max_retries` — maximum LLM call retries for this agent; `nil` means NO LIMIT CONFIGURED (same rule as `max_depth`). The scheduler row is always authoritative and populates it.
  - `in_grace_period` — whether the agent is in a grace period after a warning
  - `grace_turns_remaining` — remaining grace turns; `0` means not in a grace period. Set to the grace budget when entering a grace period: `3` for turn-limit recovery (enough for one bounded final commit plus the plain-text report, since a tool-calling turn does not finish the run), `3` for cancel-grace (a user-requested graceful cancellation). Decremented at the grace hard-stop call sites (continue-after-tools / protocol-violation paths) each time a turn ends without completing (a plain-text reply completes); when it reaches `1`, the next continue hard-stops with `{:error, :recovery_failed}`.
  - `delegation_hints` — map tracking write-tool calls to child directories (key: normalized child path, value: `%{count: non_neg_integer, hint_shown: boolean}`). Used to detect when an agent should be nudged to spawn a subagent.
  - `read_delegation_hints` — map tracking read-tool calls (read_file, rg, glob, list_dir) to child directories (key: normalized child path, value: `%{count: non_neg_integer, hint_shown: boolean}`). Used to detect when a high-level agent should be nudged to delegate investigation to a subagent.
  - `delegation_level` — whether this agent is expected to actively delegate (`:high`) or primarily do work itself (`:low`). Controls the frequency of delegation reminders from the turn-budget warning system.
  - `last_warned_level` — last positional warning level emitted (`:none` initially; escalates through `:beginning` → `:end` → `:critical`)
  - `turns_since_subagent` — turns elapsed since the last subagent delegation (resets to 0 on delegation or when the middle warning fires; used by the periodic middle reminder)
  - `quality_level` — the normalized per-task `:quality_level` opt (or `nil`), consulted only for the ROOT agent's quality-guidance section.
  """

  @enforce_keys [:agent_id, :agent_module, :depth, :node_path, :context]

  alias EvoGit.Agent.Usage
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.ForeignRepo

  defstruct [
    # identity
    :agent_id,
    :agent_module,
    :depth,
    :node_path,
    :context,
    task_id: nil,
    parent_id: nil,
    context_node: nil,
    repo_id: "primary",
    repo_root: nil,
    repo_less: false,
    custom_agent_id: nil,
    mode: :oneshot,
    archive: false,
    worktree: nil,
    # conversation
    repo_path: nil,
    current_commit: nil,
    turn: 0,
    total_tokens: 0,
    usage: %EvoGit.Agent.Usage{},
    compression_count: 0,
    llm_context_window: 200_000,
    llm_model: nil,
    llm_generation_params: [],
    model_spec: nil,
    provider_profile_id: nil,
    model_id: nil,
    model_id_locked: false,
    prompt_cache_key: nil,
    objective: nil,
    attachments: nil,
    repo_notes: nil,
    foreign_repos: [],
    skill_schemas: [],
    # control
    pending_inputs: [],
    cancel: nil,
    phase: :starting,
    exchange_ref: nil,
    event_seq: 0,
    watchers: %{},
    last_checkpoint_at: nil,
    # budget
    max_turns: 128,
    exchange_turn_base: 0,
    max_exchange_turns: nil,
    max_session_turns: nil,
    max_depth: nil,
    max_retries: nil,
    grace_turns_remaining: 0,
    in_grace_period: false,
    delegation_hints: %{},
    read_delegation_hints: %{},
    delegation_level: :high,
    last_warned_level: :none,
    turns_since_subagent: 0,
    quality_level: nil
  ]

  @type phase :: :starting | :running | :awaiting_input | :cancelling | :finalizing | :done

  @type mode :: :oneshot | :interactive

  @type t :: %__MODULE__{
          # identity
          agent_id: pos_integer(),
          agent_module: module(),
          task_id: String.t() | nil,
          depth: non_neg_integer(),
          parent_id: integer() | nil,
          node_path: String.t(),
          context_node: ContextNode.t() | nil,
          repo_id: String.t(),
          repo_root: String.t() | nil,
          repo_less: boolean(),
          custom_agent_id: String.t() | nil,
          mode: mode(),
          archive: boolean(),
          worktree: String.t() | nil,
          # conversation
          context: ReqLLM.Context.t(),
          turn: non_neg_integer(),
          total_tokens: non_neg_integer(),
          usage: Usage.t(),
          compression_count: non_neg_integer(),
          llm_context_window: pos_integer(),
          llm_model: ReqLLM.model_input() | nil,
          llm_generation_params: keyword(),
          model_spec: map() | nil,
          provider_profile_id: String.t() | nil,
          model_id: String.t() | nil,
          model_id_locked: boolean(),
          prompt_cache_key: String.t() | nil,
          objective: String.t() | nil,
          attachments: term(),
          repo_path: String.t() | nil,
          current_commit: String.t() | nil,
          repo_notes: String.t() | nil,
          foreign_repos: [ForeignRepo.t()],
          skill_schemas: [ReqLLM.Tool.t()],
          # control
          pending_inputs: [String.t() | map()],
          cancel: term(),
          phase: phase(),
          exchange_ref: reference() | nil,
          event_seq: non_neg_integer(),
          watchers: %{pid() => reference()},
          last_checkpoint_at: DateTime.t() | nil,
          # budget
          max_turns: pos_integer(),
          exchange_turn_base: non_neg_integer(),
          max_exchange_turns: pos_integer() | nil,
          max_session_turns: pos_integer() | nil,
          max_depth: pos_integer() | nil,
          max_retries: pos_integer() | nil,
          grace_turns_remaining: non_neg_integer(),
          in_grace_period: boolean(),
          delegation_hints: %{String.t() => %{count: non_neg_integer(), hint_shown: boolean()}},
          read_delegation_hints: %{
            String.t() => %{count: non_neg_integer(), hint_shown: boolean()}
          },
          delegation_level: :high | :low,
          last_warned_level: :beginning | :end | :critical | :none,
          turns_since_subagent: non_neg_integer(),
          quality_level: String.t() | nil
        }
end
