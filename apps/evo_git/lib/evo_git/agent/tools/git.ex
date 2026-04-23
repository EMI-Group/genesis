defmodule EvoGit.Agent.Tools.Git do
  @moduledoc """
  Tool for executing git commands.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "git",
      description: "Executes a git command. Provide arguments as a list of strings.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "args" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of arguments to pass to git, e.g. ['status'], ['diff', 'HEAD']"
          }
        },
        "required" => ["args"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the git tool.
  """
  def execute(args, repo_path, repo_root) do
    args_list = Map.fetch!(args, "args")

    case Shared.validate_string_array(args_list) do
      {:ok, sanitized_args} ->
        systemd_args = EvoGit.sandbox_args(repo_path, "git", sanitized_args, repo_root)

        {output, exit_code} = System.cmd("systemd-run", systemd_args, stderr_to_stdout: true)

        if exit_code == 0 do
          "Command executed successfully.\nOutput:\n#{output}"
        else
          "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
        end

      {:error, message} ->
        "Error: #{message}"
    end
  end
end
