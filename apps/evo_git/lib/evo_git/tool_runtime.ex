defmodule EvoGit.ToolRuntime do
  @moduledoc """
  The MANAGED tool-call runtime: one request struct in, one function, and the
  agent owns no concurrency logic.

  `EvoGit.Agent.ToolDispatch.batch_execute_tools/5` resolves a
  `EvoGit.ToolRuntime.Request` from the agent's process dictionary and the
  scheduler, then hands the whole batch here. Everything execution-shaped lives
  in this node:

    * batch partition (serial file-mutating calls first, then the concurrent
      group) and result ordering — `EvoGit.ToolRuntime.Executor`;
    * per-call timeout resolution, the scheduler tool-slot gate, the spawned
      tool task and its failure containment — `EvoGit.ToolRuntime.Executor`;
    * `:tool_call` tracking in `EvoGit.ProcessManager` (record → terminal status,
      OS-handle kill on timeout) — `EvoGit.ToolRuntime.Tracking`;
    * installation of the per-call context (tmpdir, owner identity, role-guard
      inputs, execution id) inside every spawned tool task — because a spawned
      task does NOT inherit the caller's process dictionary;
    * the sanitize/truncation-feedback pipeline — `EvoGit.ToolRuntime.Output`.

  What stays AGENT-side: delegation-hint bookkeeping and the redundant-cd
  warning, which are process-dictionary state of the long-lived agent process
  and are applied afterwards, in request order, by
  `EvoGit.Agent.ToolDispatch.apply_tool_output_tracking/3`.
  """

  alias EvoGit.ToolRuntime.Executor
  alias EvoGit.ToolRuntime.Request

  @type result :: {non_neg_integer(), String.t(), String.t(), term()}

  @doc """
  Executes a batch of standard (non-subagent) tool calls.

  `indexed_calls` is `[{ReqLLM.ToolCall.t(), index}]`; the request carries the
  agent/role identity the runtime needs. Returns
  `[{index, tool_call_id, name, output}]` SORTED BY INDEX, where `output` is the
  sanitized output (a plain binary for an all-text result, a
  `%EvoGit.Agent.ToolOutput{}` when media was attached, `nil` for no output) —
  sanitized but NOT hint-adjusted.
  """
  @spec execute_batch([{ReqLLM.ToolCall.t(), non_neg_integer()}], Request.t()) :: [result()]
  def execute_batch(indexed_calls, %Request{} = request) do
    Executor.execute_batch(indexed_calls, request)
  end
end
