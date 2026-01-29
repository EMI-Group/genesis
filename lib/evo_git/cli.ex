defmodule EvoGit.CLI do
  @moduledoc """
  Entry point for the EvoGit CLI.
  """
  alias EvoGit.Runtime.Genesis
  alias EvoGit.Runtime.Optimization

  def main(args) do
    # Parse args and dispatch to Runtime
    case args do
      ["genesis", prompt] ->
        Genesis.run(prompt)

      ["optimize", objective] ->
        Optimization.run(objective)

      _ ->
        IO.puts("Usage:")
        IO.puts("  evogit genesis <prompt>")
        IO.puts("  evogit optimize <objective>")
    end
  end
end
