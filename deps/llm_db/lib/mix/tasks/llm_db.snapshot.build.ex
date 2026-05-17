defmodule Mix.Tasks.LlmDb.Snapshot.Build do
  use Mix.Task

  @shortdoc "Build a canonical snapshot artifact"

  @moduledoc """
  Alias for `mix llm_db.build`.
  """

  @impl Mix.Task
  def run(args) do
    Mix.Tasks.LlmDb.Build.run(args)
  end
end
