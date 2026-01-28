defmodule EvoGit.Agent do
  @moduledoc """
  An Agent is a stateless function: NewState = Agent(State, Objective).
  """

  @type state :: %{commit_sha: String.t(), node_path: String.t()}
  @type objective :: String.t()

  @doc """
  Executes the agent logic.
  In EvoGit 1.0, this shells out to the Gemini CLI.
  """
  def run(state, objective) do
    # 1. Construct Context (Local + Ancestral)
    # 2. Call Gemini CLI
    # 3. Return NewState
    {:ok, state}
  end
end
