defmodule EvoGit.Defaults do
  @moduledoc """
  Single source of truth for all EvoGit runtime default values.

  Values are read from Application config (:evo_git), with fallback
  to compile-time defaults if not configured.

  Top-level entry points (CLI, TaskRegistry, AgentScheduler.init) may read
  from Application env with these as fallbacks. Inner modules must receive
  values explicitly through opts or state — they must not call
  Application.get_env themselves.
  """

  @app :evo_git

  # Compile-time fallbacks
  @max_concurrency 3
  @max_retries 15
  @agent_max_retries 3
  @max_agent_depth 8
  @llm_model "zai_coding_plan:glm-5"
  @github_username "BillHuang2001"

  @spec get(atom(), term()) :: term()
  defp get(key, default) do
    Application.get_env(@app, key, default)
  end

  def max_concurrency, do: get(:max_concurrency, @max_concurrency)
  def max_retries, do: get(:max_retries, @max_retries)
  def agent_max_retries, do: get(:agent_max_retries, @agent_max_retries)
  def max_agent_depth, do: get(:max_agent_depth, @max_agent_depth)
  def llm_model, do: get(:llm_model, @llm_model)
  def github_username, do: get(:github_username, @github_username)
end
