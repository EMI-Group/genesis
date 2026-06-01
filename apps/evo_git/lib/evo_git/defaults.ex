defmodule EvoGit.Defaults do
  @moduledoc """
  Backward-compatible accessor functions for EvoGit configuration.

  Delegates to `EvoGit.Config` for all values. This module exists for
  backward compatibility — new code should use `EvoGit.Config` directly.

  ## Migration Guide

  Replace:
    `Defaults.max_concurrency()`
  With:
    `Config.resolve([:scheduler, :max_concurrency])`
  """

  alias EvoGit.Config

  @doc "Returns the max LLM concurrency limit."
  def max_concurrency, do: Config.resolve([:scheduler, :max_concurrency])

  @doc "Returns the max tool execution concurrency limit."
  def max_tool_concurrency, do: Config.resolve([:scheduler, :max_tool_concurrency])

  @doc "Returns the max LLM API call retries."
  def max_retries, do: Config.resolve([:scheduler, :max_retries])

  @doc "Returns the max crash-retries per agent."
  def agent_max_retries, do: Config.resolve([:scheduler, :agent_max_retries])

  @doc "Returns the max subagent recursion depth."
  def max_agent_depth, do: Config.resolve([:scheduler, :max_agent_depth])

  @doc "Returns the default LLM model, or nil if not configured."
  def llm_model, do: Config.resolve([:llm, :model])

  @doc "Returns the github username, or nil if not configured."
  def github_username, do: Config.resolve([:user, :github_username])

  @doc "Returns the compression threshold in tokens."
  def compression_threshold_tokens, do: Config.resolve([:llm, :compression_threshold_tokens])

  @doc "Returns the sandbox mode (:auto, :enabled, or :disabled)."
  def sandbox, do: Config.resolve([:sandbox, :mode])

  @doc "Returns the max tool output size in bytes before truncation (default: 131_072)."
  def tool_output_max_bytes, do: Config.resolve([:truncation, :tool_output_max_bytes])

  @doc "Returns the truncated output size in bytes (default: 8_192)."
  def tool_output_truncate_size, do: Config.resolve([:truncation, :tool_output_truncate_size])

  @doc "Returns the default tool output size in bytes before truncation for high-output tools (default: 16_384)."
  def tool_output_default_max_bytes, do: Config.resolve([:truncation, :tool_output_default_max_bytes])

  @doc "Returns the max CONTEXT.md file size in bytes before truncation (default: 65_536)."
  def context_max_bytes, do: Config.resolve([:truncation, :context_max_bytes])

  @doc "Returns the sandbox resource limits map."
  def sandbox_resources, do: Config.resolve([:sandbox, :resources])
end
