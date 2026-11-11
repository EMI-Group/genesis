defmodule EvoGit.Agent.Turn do
  @moduledoc """
  ONE agent turn: tool-schema selection, the LLM call, and the tool batch.

  A turn is deliberately thin: it decides WHICH tools this agent may call, makes
  one LLM call, and hands the tool calls it carries to the shared tool batch in
  `EvoGit.Agent.ToolDispatch` (the wrap boundary, result ordering and subagent
  partitioning all live there, unchanged).

  ## Role-agnostic

  Nothing here knows whether the agent is a root agent, a subagent, a custom
  agent or the repo-less Assistant: the tool list is
  `state.agent_module.available_tools/0` plus the agent's skill schemas, minus the
  subagent-spawn schemas once the agent is at its configured maximum depth.

  ## `Turn` never owns loop control

  Loop control belongs to the engine (`EvoGit.Agent.Exchange`). The caller passes
  its continuations as ONE map:

      %{loop: (state -> outcome), trigger_recovery: (state, reason -> outcome)}

  `Turn.run/3` only forwards them to `EvoGit.Agent.ToolDispatch.do_turn/6`; a
  turn always ends in the engine's TERMINAL vocabulary — a continuing turn
  re-enters the loop through the `:loop` continuation, so it returns
  `{:yield, state, text}` (an interactive agent's tool-free reply),
  `{:finish, state, %EvoGit.Agent.Result{}}` or `{:error, reason}`.

  ## Seams

  The seams documented in `EvoGit.Agent.Exchange.Seams` (`:llm_call`,
  `:tool_batch`, `:scheduler`) are consumed by `ToolDispatch.do_turn/6` through
  the SAME `opts` keyword list passed here. They are default-inert: an absent
  seam is the production path, byte-identical to the un-seamed turn. (The fourth
  seam, `:checkpoint`, belongs to the engine's turn BOUNDARY and is never reached
  from inside a turn.)
  """

  alias EvoGit.Agent.State
  alias EvoGit.Agent.ToolDispatch

  @doc """
  Runs ONE turn of `state`.

  `cont` supplies the engine's continuations (`:loop` arity 1,
  `:trigger_recovery` arity 2) and `opts` is the seam keyword list
  (`:llm_call`, `:tool_batch`, `:scheduler`; see
  `EvoGit.Agent.Exchange.Seams`).

  An OPTIONAL `:now` entry pins the clock for this turn (see
  `EvoGit.Agent.Clock`), so a turn driven OUTSIDE an exchange honours the same
  opts pin the exchange installs for its whole body.
  """
  @spec run(
          State.t(),
          %{loop: (State.t() -> term()), trigger_recovery: (State.t(), term() -> term())},
          keyword()
        ) ::
          {:yield, State.t(), String.t()}
          | {:finish, State.t(), EvoGit.Agent.Result.t()}
          | {:error, term()}
  def run(%State{} = state, cont, opts \\ []) do
    EvoGit.Agent.Clock.with_opts(opts, fn ->
      ToolDispatch.do_turn(
        state,
        &effective_tools/1,
        state.agent_module.subagent_modules(),
        cont.loop,
        cont.trigger_recovery,
        opts
      )
    end)
  end

  @doc false
  # The tool schemas this agent may call right now: its role's own tools plus
  # the skill schemas enabled for its node path. At the configured maximum depth
  # the subagent-spawn tools are excluded — a delegation would always be refused
  # by the spatial contract, so offering it only burns a turn.
  #
  # Depth comes from the STRUCT (`state.depth` vs `state.max_depth`): both are
  # populated from the scheduler row, which is the only source of `max_depth`; a
  # `nil` max_depth means "no limit configured" and never excludes anything.
  def effective_tools(%State{} = state) do
    skill_schemas = Map.get(state, :skill_schemas, [])
    all_tools = state.agent_module.available_tools() ++ skill_schemas

    if at_max_depth?(state) do
      excluded = MapSet.new(EvoGit.Agent.SubagentSchemas.tools(state.agent_module))

      all_tools
      |> Enum.reject(fn tool ->
        name = EvoGit.Agent.tool_name(tool)
        name && MapSet.member?(excluded, name)
      end)
    else
      all_tools
    end
  end

  defp at_max_depth?(%State{} = state) do
    is_integer(state.max_depth) and state.depth >= state.max_depth
  end
end
