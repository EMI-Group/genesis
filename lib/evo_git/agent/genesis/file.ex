defmodule EvoGit.Agent.Genesis.File do
  @moduledoc """
  A dedicated agent for the Genesis creation phase of a file.
  """
  use EvoGit.Agent.Coder

  def available_tools do
    EvoGit.Agent.Tools.schemas() ++ [completion_schema()]
  end

  def system_prompt do
    """
    You are an EvoGit Genesis Agent responsible for planning and realizing a single code file.
    Your task is to define the context and implement the code logic for the specific file according to the architectural plan.
    When you are completely finished, you MUST call 'complete_task' to indicate that the file implementation is done.
    """
  end
end
