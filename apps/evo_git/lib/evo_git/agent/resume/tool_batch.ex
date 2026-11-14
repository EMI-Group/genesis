defmodule EvoGit.Agent.Resume.ToolBatch do
  @moduledoc """
  What ONE interrupted tool call's synthetic result says.

  A crash in the middle of a tool batch leaves the assistant `tool_calls`
  message with no `:tool` answers. `EvoGit.Agent.Resume` answers each unanswered
  call with ONE honest, class-specific result (`ReqLLM.Context.tool_result/3`
  via `EvoGit.Agent.ToolDispatch.assemble_tool_result/3`); this module owns that
  text, so the wording lives in exactly one place.

  The rule for every class: NEVER fabricate success and never invent specific
  output. State what is known (the call was interrupted) and what the agent must
  do to find out (inspect).

  ## `:subagent` resolver entry point

  A subagent spawn is the ONE class whose correct answer may become available
  again later: the scheduler-side re-attach API
  (`EvoGit.AgentScheduler.reattach_sub_agents/2`) will be able to adopt the
  interrupted children instead of losing them. `reattach/2` is that single
  entry point. It answers the fallback text today; when the scheduler API lands,
  only this function (or the `:subagent_reattach_fun` app-env seam it consults,
  read AT CALL TIME and default-inert) changes — nothing in
  `EvoGit.Agent.Resume` or the repair loop moves.

  Every function here is TOTAL and side-effect free.
  """

  alias EvoGit.Agent.ToolBatch

  @doc """
  The synthetic tool-result TEXT for one interrupted call of `class`.

  `call` is a canonical `EvoGit.Agent.ToolBatch` call entry (or any map with
  `:name`/`:id`). `:subagent` delegates to `reattach/2`; every other class
  answers a fixed, honest description.
  """
  @spec impact(ToolBatch.class(), term(), keyword()) :: String.t()
  def impact(class, call, ctx \\ [])

  def impact(:subagent, call, ctx), do: reattach(call, ctx)

  def impact(:shell, call, _ctx) do
    """
    Interrupted: this shell command's outcome is UNKNOWN. The agent run crashed while it was running, and the process was terminated with the run. It may have completed, partially run, or never started, and no output was captured.
    Verify before assuming anything: re-read the files it may have touched, check `git status`, and call `job_list` if a background job was involved. Do not blindly re-run destructive commands (#{describe(call)}).
    """
    |> String.trim()
  end

  def impact(:edit, call, _ctx) do
    """
    Interrupted: this edit was in progress when the agent run crashed. The file may be untouched, fully edited, or PARTIALLY written (inconsistent content). No result was recorded.
    Re-read the file before editing it again (#{describe(call)}).
    """
    |> String.trim()
  end

  def impact(:write, call, _ctx) do
    """
    Interrupted: this write was in progress when the agent run crashed. The target may be untouched, fully written, or partially written. No result was recorded.
    Inspect the target before writing it again (#{describe(call)}).
    """
    |> String.trim()
  end

  def impact(_class, call, _ctx) do
    """
    Interrupted: this call's result is unavailable — the agent run crashed while it was executing and no output was captured.
    Re-run it if you still need its output (#{describe(call)}).
    """
    |> String.trim()
  end

  @doc """
  The resolver entry point for an interrupted SUBAGENT spawn.

  Answers the honest fallback sentence today. A function supplied through the
  `:subagent_reattach_fun` app-env key (read at CALL TIME, default `nil`) or the
  `:reattach_fun` option is consulted first and must answer a non-empty binary
  to be used; anything else falls back. That seam is how the scheduler-side
  `EvoGit.AgentScheduler.reattach_sub_agents/2` API will replace this body
  without touching the resume path.
  """
  @spec reattach(term(), keyword()) :: String.t()
  def reattach(call, ctx \\ []) do
    case reattach_fun(ctx) do
      fun when is_function(fun, 2) ->
        case fun.(call, ctx) do
          text when is_binary(text) and text != "" -> text
          _other -> subagent_fallback(call)
        end

      _none ->
        subagent_fallback(call)
    end
  end

  defp subagent_fallback(call) do
    """
    Interrupted: this subagent run was stopped because the PARENT agent crashed and restarted, so its result is unavailable (it may have finished, partially finished, or never started its work). The subagent's own worktree — and any branch it created — may still exist.
    Decide deliberately: re-delegate the work (the child may repeat side effects), or inspect the affected paths first (`git status`, `git branch --list 'evogit-agent-*'`, re-read the files) to see how far it got (#{describe(call)}).
    """
    |> String.trim()
  end

  # Call-time read of the optional resolver seam; an absent/false/nil value is
  # the fallback path (default-inert).
  defp reattach_fun(ctx) do
    case Keyword.get(ctx, :reattach_fun) do
      nil -> Application.get_env(:evo_git, :subagent_reattach_fun)
      fun -> fun
    end
  end

  # A short "(tool `bash`, call id `call_abc`)" suffix, so the agent can match the
  # synthetic result to the assistant message. Total for a malformed call.
  defp describe(%{} = call) do
    name = Map.get(call, :name) || Map.get(call, "name")
    id = Map.get(call, :id) || Map.get(call, "id")

    case {name, id} do
      {name, id} when is_binary(name) and is_binary(id) -> "tool `#{name}`, call id `#{id}`"
      {name, _id} when is_binary(name) -> "tool `#{name}`"
      _other -> "unknown tool"
    end
  end

  defp describe(_call), do: "unknown tool"
end
