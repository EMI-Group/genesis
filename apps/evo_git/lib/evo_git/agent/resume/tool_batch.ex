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

  ## `:subagent` text here is the FALLBACK

  A subagent spawn is the ONE class whose real answer may still become available
  after the crash: `EvoGit.Agent.Resume.Reattach` re-attaches the interrupted
  batch through `EvoGit.AgentScheduler.reattach_sub_agents/3` and supplies the
  real, formatted result for every child that survived. This module's
  `:subagent` text is what a call gets when NO real result can be used — the
  slot was lost, the scheduler refused the batch, or the re-attach degraded — so
  it must stay honest about the uncertainty.

  Every function here is TOTAL and side-effect free.
  """

  alias EvoGit.Agent.ToolBatch

  @doc """
  The synthetic tool-result TEXT for one interrupted call of `class`.

  `call` is a canonical `EvoGit.Agent.ToolBatch` call entry (or any map with
  `:name`/`:id`). Every class answers a fixed, honest description; `:subagent`
  answers the re-attach FALLBACK text (`EvoGit.Agent.Resume.Reattach` supplies
  the real result when one can be recovered).
  """
  @spec impact(ToolBatch.class(), term()) :: String.t()
  def impact(class, call)

  def impact(:subagent, call), do: subagent_fallback(call)

  def impact(:shell, call) do
    """
    Interrupted: this shell command's outcome is UNKNOWN. The agent run crashed while it was running, and the process was terminated with the run. It may have completed, partially run, or never started, and no output was captured.
    Verify before assuming anything: re-read the files it may have touched, check `git status`, and call `job_list` if a background job was involved. Do not blindly re-run destructive commands (#{describe(call)}).
    """
    |> String.trim()
  end

  def impact(:edit, call) do
    """
    Interrupted: this edit was in progress when the agent run crashed. The file may be untouched, fully edited, or PARTIALLY written (inconsistent content). No result was recorded.
    Re-read the file before editing it again (#{describe(call)}).
    """
    |> String.trim()
  end

  def impact(:write, call) do
    """
    Interrupted: this write was in progress when the agent run crashed. The target may be untouched, fully written, or partially written. No result was recorded.
    Inspect the target before writing it again (#{describe(call)}).
    """
    |> String.trim()
  end

  def impact(_class, call) do
    """
    Interrupted: this call's result is unavailable — the agent run crashed while it was executing and no output was captured.
    Re-run it if you still need its output (#{describe(call)}).
    """
    |> String.trim()
  end

  defp subagent_fallback(call) do
    """
    Interrupted: this subagent run was stopped because the PARENT agent crashed and restarted, so its result is unavailable (it may have finished, partially finished, or never started its work). The subagent's own worktree — and any branch it created — may still exist.
    Decide deliberately: re-delegate the work (the child may repeat side effects), or inspect the affected paths first (`git status`, `git branch --list 'evogit-agent-*'`, re-read the files) to see how far it got (#{describe(call)}).
    """
    |> String.trim()
  end

  # A short "(tool `bash`, call id `call_abc`)" suffix, so the agent can match the
  # synthetic result to the assistant message. Total for a malformed call — a
  # `%ReqLLM.ToolCall{}` carries its name/id NESTED (`function.name`), so it is
  # flattened first; a struct with a malformed `function` degrades to the id only.
  defp describe(%ReqLLM.ToolCall{id: id, function: %{name: name}}) do
    describe(%{name: name, id: id})
  end

  defp describe(%ReqLLM.ToolCall{id: id}), do: describe(%{name: nil, id: id})

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
