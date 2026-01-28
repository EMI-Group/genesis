defmodule EvoGit.Adapters.Gemini do
  @moduledoc """
  Wrapper for Gemini CLI integration.
  """

  def call(_prompt, _input \\ nil) do
    # echo input | gemini --prompt prompt
    {:ok, "response"}
  end
end
