defmodule EvoGit.Agent.ToolOutputTracking do
  @moduledoc """
  Agent-side bookkeeping applied to one batch of tool outputs after execution.

  Runs in the AGENT process, in request order, accumulating the write/read
  delegation-hint maps and firing the once-per-run redundant-cd warning. Media
  survives: the hint modules are binary-only, so the text component is unwrapped,
  extended and re-attached (`EvoGit.Agent.ToolOutput.with_text/2`).
  """

  alias EvoGit.Agent.ToolInvocation
  alias EvoGit.Agent.ToolOutput

  @doc false
  # Applies the redundant-cd warning and write/read delegation hints to one
  # tool output in the parent process, threading the hint maps through the
  # batch accumulator (index-ordered, deterministic).
  #
  # The wrap boundary lives here too: the redundant-cd warning preserves media,
  # while the delegation-hint modules are BINARY-ONLY, so the text component is
  # unwrapped, the hint appends run on it, and the (possibly extended) text is
  # re-attached with the media preserved (`ToolOutput.with_text/2`). An all-text
  # output never becomes a struct — `rewrap_output/2` returns the plain binary.
  def apply_tool_output_tracking({index, call, output}, {acc_results, hints, read_hints}, ctx) do
    name = ReqLLM.ToolCall.name(call)
    # TOTAL accessor: the tolerant parse may have handed a RAW string to the tool
    # layer (undecodable arguments), and the hint helpers are map-only.
    args = ToolInvocation.arguments_map(call)
    tool_call_id = call.id || name || "unknown"

    output =
      maybe_append_redundant_cd_warning(output, name, args, ctx.repo_path, ctx.repo_root)

    text = output_text(output)

    # Track delegation hints for write tools (skip during conflict resolution)
    {text, hints} = track_write_delegation_hint(text, hints, name, args, ctx)

    # Track read delegation hints for read tools (skip during conflict resolution)
    {text, read_hints} = track_read_delegation_hint(text, read_hints, name, args, ctx)

    output = rewrap_output(output, text)

    {acc_results ++ [{index, tool_call_id, name, output}], hints, read_hints}
  end

  # Returns the TEXT component of a tool output — the plain binary itself, or
  # `ToolOutput.text/1` for a media-carrying `%ToolOutput{}`. The sanitize /
  # truncation / hint pipeline is BINARY-ONLY and therefore always consumes this.
  defp output_text(%ToolOutput{} = output), do: ToolOutput.text(output)
  defp output_text(text), do: text

  # Re-attaches `text` to the SAME media set as `output`: a `%ToolOutput{}`
  # keeps its attachments (`ToolOutput.with_text/2`), while a plain binary (or
  # the legacy non-binary pass-through) is returned as-is.
  defp rewrap_output(%ToolOutput{} = output, text), do: ToolOutput.with_text(output, text)
  defp rewrap_output(_output, text), do: text

  # Appends the write-tool delegation hint when the write threshold is
  # exceeded (skipped during conflict resolution).
  defp track_write_delegation_hint(output, hints, name, args, ctx) do
    if ctx.threshold > 0 do
      child_paths =
        EvoGit.Agent.DelegationHints.extract_child_paths(
          name,
          args,
          ctx.node_path,
          ctx.repo_path
        )

      child_paths =
        EvoGit.Agent.DelegationHints.filter_child_paths_if_conflicts(
          child_paths,
          ctx.conflict_files
        )

      EvoGit.Agent.DelegationHints.maybe_append_delegation_hint(
        output,
        hints,
        child_paths,
        ctx.threshold
      )
    else
      {output, hints}
    end
  end

  # Appends the read-tool delegation hint when the read threshold is exceeded
  # (skipped during conflict resolution).
  defp track_read_delegation_hint(output, read_hints, name, args, ctx) do
    if ctx.read_threshold > 0 do
      read_child_paths =
        EvoGit.Agent.DelegationHints.extract_read_child_paths(
          name,
          args,
          ctx.node_path,
          ctx.repo_path
        )

      read_child_paths =
        EvoGit.Agent.DelegationHints.filter_child_paths_if_conflicts(
          read_child_paths,
          ctx.conflict_files
        )

      EvoGit.Agent.DelegationHints.maybe_append_read_delegation_hint(
        output,
        read_hints,
        read_child_paths,
        ctx.read_threshold,
        ctx.delegation_level,
        ctx.agent_module
      )
    else
      {output, read_hints}
    end
  end

  # --- Redundant CD Warning ---
  # The "you don't need to cd into your worktree" warning fires only once
  # per agent run (tracked via the process dictionary), unlike the
  # wrong-path cd warnings which fire every time.

  @doc false
  def maybe_append_redundant_cd_warning(output, name, args, repo_path, repo_root) do
    # ALIAS-AWARE: the model-facing shell tool name is `bash` while the internal
    # dispatch keys are `run_bash` / `run_powershell`, so compare through the
    # alias spine (`EvoGit.Agent.ToolNames`) instead of a hardcoded name list —
    # otherwise a `bash` call never reaches the warning.
    if EvoGit.Agent.ToolNames.normalize(name) == EvoGit.Agent.ToolNames.shell_tool_name() do
      command = Map.get(args, "command", "")

      if EvoGit.Agent.Tools.ShellTool.redundant_cd?(command, repo_path, repo_root) and
           not Process.get(:redundant_cd_warned, false) do
        Process.put(:redundant_cd_warned, true)

        append_output_text(
          output,
          "\n\n" <> EvoGit.Agent.Tools.ShellTool.redundant_cd_warning(repo_path)
        )
      else
        output
      end
    else
      output
    end
  end

  # Appends `suffix` to the TEXT component of a tool output while PRESERVING any
  # media: a `%ToolOutput{}` is unwrapped (`ToolOutput.text/1`), the suffix is
  # concatenated, and the result is re-attached (`ToolOutput.with_text/2`); a
  # plain binary stays a plain binary (the byte-identity invariant).
  defp append_output_text(%ToolOutput{} = output, suffix) do
    ToolOutput.with_text(output, ToolOutput.text(output) <> suffix)
  end

  defp append_output_text(binary, suffix) when is_binary(binary), do: binary <> suffix
end
