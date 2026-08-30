defmodule EvoGit.Agent.Tools.RunCommand do
  @moduledoc """
  Tool for executing a command-shell command.

  Exposes the `EvoGit.CommandShell` command shell (task/agent control,
  system inspection, etc.) to the self-reflective agent as a single generic
  tool. The command string is passed through verbatim to
  `EvoGit.CommandShell.execute/1`, which returns `{:ok, output} | {:error,
  reason}`; errors are surfaced to the agent as a readable `Error: ...`
  string so it can adjust its next command.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "run_command",
      description:
        "Executes a command-shell command and returns its output. Run 'help' " <>
          "to list available commands.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" =>
              "A shell command string, e.g. \"task.list\" or \"task.start evolve \\\"Write a parser\\\"\". Run 'help' to list available commands."
          }
        },
        "required" => ["command"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the run_command tool.

  Extracts the required `command` string argument and runs it through
  `EvoGit.CommandShell.execute/1`. Never raises: a missing/non-string
  argument returns the shared descriptive error string, and any command
  failure (or an unexpected command-shell raise/exit) is formatted as an
  `Error: ...` string for the agent.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, command} <- Shared.fetch_string_arg(args, "command") do
      safe_execute(command)
    else
      {:error, message} -> message
    end
  end

  # Tool boundary: the command shell may be unavailable or raise on an
  # unexpected command shape. A crash must never kill the agent loop — the
  # LLM gets a readable error string it can act on instead.
  defp safe_execute(command) do
    case EvoGit.CommandShell.execute(command) do
      {:ok, output} -> output
      {:error, reason} -> "Error: " <> reason
    end
  rescue
    e -> "Error: " <> Exception.message(e)
  catch
    :exit, reason -> "Error: " <> inspect(reason)
  end
end
