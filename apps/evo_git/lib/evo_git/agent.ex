defmodule EvoGit.Agent do
  @moduledoc """
  An agent session loop template that manages a single agent session,
  handling tool loops, timeouts, and graceful recovery.

  Agent state follows the design spec:
  - `context_node` (spatial): the node in the Context Tree
  - `phylo_node` (temporal): git commit state with `base_commit` and `current_commit`

  The agent's worktree path is fixed for the agent's entire lifetime. It is set
  once by the scheduler via `Process.put(:repo_path, ...)` before the agent task
  starts, read at startup, and stored in `LoopState.repo_path`. It never changes.

  Scheduling metadata (status, worktree assignment, parent tracking) lives in
  a separate `:evogit_sched_meta` table owned by the scheduler — agents never
  read or write that table.

  ## Prompting Rules
  - **System Prompt:** Used STRICTLY to define the agent's behavior, rules, and persona.
    It must not contain the objective or the context tree.
  - **User Prompt:** The framework automatically injects the current Context Tree and
    the user's objective (the query) as user prompts.
  """

  alias EvoGit.Agent.LoopState

  @type state :: LoopState.t()

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

  ## The bug

  Previously this only checked `turn >= max_turns`. When recovery set
  `in_grace_period: true` and looped back, the condition re-fired immediately.
  The `in_grace_period` guard breaks the cycle.
  """
  @spec trigger_turn_limit_recovery?(LoopState.t()) :: boolean()
  def trigger_turn_limit_recovery?(%LoopState{in_grace_period: true}), do: false
  def trigger_turn_limit_recovery?(%LoopState{turn: turn, max_turns: max}), do: turn >= max

  @doc """
  Determines whether a `{:continue, _}` outcome during the grace period should
  fail recovery.

  During the grace period (the recovery turn), the agent gets exactly one turn
  to call `complete_task`. If it instead calls other tools, recovery has failed
  and the loop must terminate with `{:error, :recovery_failed}`.

  This bounds the grace period to exactly one turn, guaranteeing the loop can
  never run indefinitely.
  """
  @spec grace_period_continue_failed?(LoopState.t()) :: boolean()
  def grace_period_continue_failed?(%LoopState{in_grace_period: true}), do: true
  def grace_period_continue_failed?(%LoopState{in_grace_period: false}), do: false

  defmacro __using__(_opts) do
    quote do
      require Logger
      use Retry

      import ReqLLM.Context, only: [user: 1, assistant: 1, system: 1, tool_result: 3]

      @doc """
      Runs the agent synchronously. Delegates to the shared Runner module.
      """
      def run(objective, dispatch_ctx) do
        EvoGit.Agent.Runner.run(__MODULE__, objective, dispatch_ctx)
      end

      def available_tools do
        EvoGit.Agent.Tools.schemas() ++
          EvoGit.Agent.SubagentSchemas.schemas(__MODULE__) ++
          [EvoGit.Agent.Tools.CompleteTask.schema()]
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
      These are orchestration/planning agents (Manager, CodebaseLead, etc.)
      that receive broad objectives and should break them down into subtasks.

      `:low` — The agent receives precise, well-scoped objectives and primarily
      does the work itself. Subagent delegation, if used at all, is occasional.
      These are worker agents (Executor, TaskScheduler, Evaluator, etc.).

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
            [EvoGit.Agents.CodebaseInvestigator]
          end
      """
      def subagent_modules, do: []

      @doc false
      def subagent_tools do
        EvoGit.Agent.SubagentSchemas.tools(__MODULE__)
      end

      @doc """
      Returns the system prompt that defines the agent's core behavior, persona, and rules.

      IMPORTANT: The system prompt MUST NOT contain dynamic state, the context tree,
      or the specific objective/query. System prompts are strictly for defining
      the agent's behavior. The objective and context tree are automatically
      provided to the agent as user prompts.
      """
      def system_prompt, do: ""

      defoverridable available_tools: 0,
                     system_prompt: 0,
                     subagent_tool_name: 0,
                     subagent_tool_description: 0,
                     subagent_modules: 0,
                     agent_type: 0,
                     delegation_level: 0
    end
  end
end
