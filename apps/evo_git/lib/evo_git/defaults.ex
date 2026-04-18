defmodule EvoGit.Defaults do
  @moduledoc """
  Single source of truth for all EvoGit runtime default values.

  Top-level entry points (CLI, TaskRegistry, AgentScheduler.init) may read
  from Application env with these as fallbacks. Inner modules must receive
  values explicitly through opts or state — they must not call
  Application.get_env themselves.
  """

  @max_concurrency 3
  @max_retries 15
  @agent_max_retries 3
  @max_agent_depth 5
  @llm_model "zai_coding_plan:glm-5"

  def max_concurrency, do: @max_concurrency
  def max_retries, do: @max_retries
  def agent_max_retries, do: @agent_max_retries
  def max_agent_depth, do: @max_agent_depth
  def llm_model, do: @llm_model
end
