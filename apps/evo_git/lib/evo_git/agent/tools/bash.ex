defmodule EvoGit.Agent.Tools.Bash do
  @moduledoc """
  Tool for executing bash commands.
  """

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "bash",
      description:
        "Executes a shell command via bash -c. Useful for running scripts, building, testing, or executing common command-line tools.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "The bash command to execute"}
        },
        "required" => ["command"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the bash tool.
  """
  def execute(args, repo_path, repo_root) do
    command = Map.fetch!(args, "command")
    systemd_args = EvoGit.sandbox_args(repo_path, "bash", ["-c", command], repo_root)

    {output, exit_code} = System.cmd("systemd-run", systemd_args, stderr_to_stdout: true)

    if exit_code == 0 do
      "Command executed successfully.\nOutput:\n#{output}"
    else
      "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
    end
  end
end
