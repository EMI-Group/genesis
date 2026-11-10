defmodule EvoGit.Agent do
  @moduledoc """
  An agent session loop template that manages a single agent session,
  handling tool loops, timeouts, and graceful recovery.

  Agent state follows the design spec:
  - `context_node` (spatial): the node in the Context Tree
  - `phylo_node` (temporal): git commit state with `base_commit` and `current_commit`

  The agent's worktree path is fixed for the agent's entire lifetime. It is set
  once by the scheduler via `Process.put(:repo_path, ...)` before the agent task
  starts, read at startup, and stored in `State.repo_path`. It never changes.

  Scheduling metadata (status, worktree assignment, parent tracking) lives in
  a separate `:evogit_sched_meta` table owned by the scheduler — agents never
  read or write that table.

  ## Prompting Rules
  - **System Prompt:** Used STRICTLY to define the agent's behavior, rules, and persona.
    It must not contain the objective or the context tree.
  - **User Prompt:** The framework automatically injects the current Context Tree and
    the user's objective (the query) as user prompts.
  """

  alias EvoGit.Agent.State

  @type state :: State.t()

  @doc """
  Extracts the tool name from a tool schema struct.
  """
  def tool_name(%{name: name}), do: name
  def tool_name(_other), do: nil

  @doc """
  Determines whether the agent loop should trigger turn-limit recovery.

  Returns `true` when the turn limit is exceeded and the agent is NOT already
  in a grace period. The `in_grace_period` guard is critical: without it,
  `trigger_recovery/2` sets `in_grace_period: true` and re-enters `loop/1`,
  where the same condition re-fires — an infinite loop with no termination.

  ## The budget a mode is measured against

  - `:oneshot` (every agent today) — `turn >= max_turns`, unchanged.
  - `:interactive` — the per-exchange BURST budget measured from the start of
    the current exchange (`turn - exchange_turn_base >= exchange_turn_budget/1`)
    OR the cumulative `session_turn_budget/1` cap
    (`turn >= session_turn_budget/1`), so a yield resets the burst but never the
    whole session.

  ## The bug

  Previously this only checked `turn >= max_turns`. When recovery set
  `in_grace_period: true` and looped back, the condition re-fired immediately.
  The `in_grace_period` guard breaks the cycle.
  """
  @spec trigger_turn_limit_recovery?(State.t()) :: boolean()
  def trigger_turn_limit_recovery?(%State{in_grace_period: true}), do: false

  def trigger_turn_limit_recovery?(%State{mode: :interactive} = state) do
    state.turn - state.exchange_turn_base >= exchange_turn_budget(state) or
      state.turn >= session_turn_budget(state)
  end

  def trigger_turn_limit_recovery?(%State{turn: turn, max_turns: max}), do: turn >= max

  @doc """
  The turn budget of ONE exchange (the `:interactive` burst budget).

  An explicit `State.max_exchange_turns` wins; otherwise the configured
  `State.max_turns` is the budget — exactly what a one-shot agent uses.
  """
  @spec exchange_turn_budget(State.t()) :: pos_integer()
  def exchange_turn_budget(%State{max_exchange_turns: budget})
      when is_integer(budget) and budget > 0,
      do: budget

  def exchange_turn_budget(%State{max_turns: max}), do: max

  @doc """
  The cumulative turn cap of an `:interactive` session, across every exchange.

  Resolution order: an explicit `State.max_session_turns`, then the
  default-inert seam
  `Application.get_env(:evo_git, :interactive_session_turns, …)` read AT CALL
  TIME, then `exchange_turn_budget(state) * 10`. A value that is not a positive
  integer is IGNORED (the next source is consulted), so a mistyped seam can
  never wedge an interactive session at zero turns.
  """
  @spec session_turn_budget(State.t()) :: pos_integer()
  def session_turn_budget(%State{} = state) do
    default = exchange_turn_budget(state) * 10

    case state.max_session_turns do
      explicit when is_integer(explicit) and explicit > 0 ->
        explicit

      _unset ->
        case Application.get_env(:evo_git, :interactive_session_turns, default) do
          configured when is_integer(configured) and configured > 0 -> configured
          _invalid -> default
        end
    end
  end

  @doc """
  Determines whether a `{:continue, _}` outcome during the grace period should
  fail recovery.

  Budget-aware: during the grace period the agent gets a bounded number of
  grace turns (`State.grace_turns_remaining`) to finish (a plain-text reply
  with no tool calls completes the run, and its text IS the report).
  If it instead calls other tools (a `{:continue, _}` outcome), the turn ends
  without completing — the call sites in `EvoGit.Agent.ToolDispatch` check this
  predicate and, when it returns `false`, decrement `grace_turns_remaining` and
  allow another turn.

  - Turn-limit recovery (budget 3): `grace_turns_remaining` 3 → 2 → 1 → hard-stop.
    Three turns are what "commit one final bounded change, then deliver the
    plain-text report" actually costs, because a turn ending in a tool call does
    not finish the run: at most two turns may end in a tool call, and the third
    continues only if it completes.
  - Cancel-grace (budget 3): `grace_turns_remaining` 3 → 2 → 1 → hard-stop —
    the agent gets up to 3 grace turns total.

  This bounds any grace period, guaranteeing the loop can never run
  indefinitely.

  A state with `in_grace_period: true` and `grace_turns_remaining == 0` (the
  struct default, e.g. a state constructed without a budget) also hard-stops —
  preserving the historical default of "in grace means no more continues".
  """
  @spec grace_period_continue_failed?(State.t()) :: boolean()
  def grace_period_continue_failed?(%State{in_grace_period: true, grace_turns_remaining: n}) do
    n <= 1
  end

  def grace_period_continue_failed?(%State{in_grace_period: false}), do: false

  defmacro __using__(_opts) do
    quote do
      require Logger
      use Retry

      import ReqLLM.Context, only: [user: 1, assistant: 1, system: 1, tool_result: 3]

      def available_tools do
        EvoGit.Agent.Tools.schemas() ++
          EvoGit.Agent.SubagentSchemas.schemas(__MODULE__)
      end

      @doc """
      Returns the tool name used when this agent is spawned as a subagent.
      Override this in your agent module.
      """
      def subagent_tool_name, do: nil

      @doc """
      Returns the tool description used when this agent is spawned as a subagent.
      Override this in your agent module.
      """
      def subagent_tool_description, do: ""

      @doc """
      Returns the agent type: `:read` or `:read_write`.

      - `:read` - Read-only agents can only read files and update CONTEXT.md files
      - `:read_write` - Read-write agents can read, write, and modify code

      Override this in your agent module to declare its type.

      ## Rules for Subagent Delegation

      - **Read agents** can only spawn other read subagents
      - **Read-write agents** can spawn both read and read-write subagents,
        but read-write subagents must operate within the same node or child nodes
        of the parent agent's assigned node (no permission escalation)

      ## Example

          def agent_type, do: :read_write
      """
      def agent_type, do: :read_write

      @doc """
      Returns the delegation level for this agent type.

      `:high` — The agent is expected to actively delegate work to subagents.
      These are orchestration/planning agents (Manager, Architect, etc.)
      that receive broad objectives and should break them down into subtasks.

      `:low` — The agent receives precise, well-scoped objectives and primarily
      does the work itself. Subagent delegation, if used at all, is occasional.
      These are worker agents (Executor, TaskScheduler, etc.).

      The turn-budget warning system uses this to adjust its behavior: low-level
      agents receive significantly fewer delegation reminders since they are not
      expected to actively delegate.
      """
      def delegation_level, do: :high

      @doc """
      Returns a list of agent modules that can be spawned as subagents.
      The framework automatically generates tool schemas and execution logic
      from each module's `subagent_tool_name/0` and `subagent_tool_description/0`.

      Override this in your agent module to declare subagents.

      ## Example

          def subagent_modules do
            [EvoGit.Agents.Investigator]
          end
      """
      def subagent_modules, do: []

      @doc """
      Returns the system prompt that defines the agent's core behavior, persona, and rules.

      IMPORTANT: The system prompt MUST NOT contain dynamic state, the context tree,
      or the specific objective/query. System prompts are strictly for defining
      the agent's behavior. The objective and context tree are automatically
      provided to the agent as user prompts.
      """
      def system_prompt, do: ""

      @doc """
      Returns how a tool-free reply from this role is interpreted.

      `:oneshot` (default) — the reply FINISHES the run: completion side effects
      are written and the session stops.

      `:interactive` — the reply YIELDS: pending work is committed, the reply
      text is handed back, and the session waits for its next input. Interactive
      mode is opt-in and root-only (a subagent is always `:oneshot`).

      Override this in your agent module to opt into interactive semantics.
      """
      def session_mode, do: :oneshot

      @doc """
      Called when an `:interactive` session yields and becomes idle.

      Receives the agent's `%EvoGit.Agent.State{}`. It must be callable from any
      process and cheap: it runs inline on the session's own path, so it is for
      light notification/bookkeeping — never a blocking call, a sleep or heavy
      I/O. The default is a no-op.
      """
      def on_yield(_state), do: :ok

      defoverridable available_tools: 0,
                     system_prompt: 0,
                     subagent_tool_name: 0,
                     subagent_tool_description: 0,
                     subagent_modules: 0,
                     agent_type: 0,
                     delegation_level: 0,
                     session_mode: 0,
                     on_yield: 1
    end
  end
end
