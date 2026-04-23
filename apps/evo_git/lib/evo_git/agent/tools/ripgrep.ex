defmodule EvoGit.Agent.Tools.Ripgrep do
  @moduledoc """
  Tool for executing ripgrep (rg) commands.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "rg",
      description:
        "Executes ripgrep (rg) to search for patterns in files. Provide arguments as a list of strings.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "args" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of arguments to pass to rg, e.g. ['-n', 'pattern', 'dir']"
          }
        },
        "required" => ["args"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the rg tool.
  """
  def execute(args, repo_path, repo_root) do
    args_list = Map.fetch!(args, "args")

    case Shared.validate_string_array(args_list) do
      {:ok, sanitized_args} ->
        systemd_args = EvoGit.sandbox_args(repo_path, "rg", sanitized_args, repo_root)

        {output, exit_code} = System.cmd("systemd-run", systemd_args, stderr_to_stdout: true)

        cond do
          exit_code == 0 -> "Command executed successfully.\nOutput:\n#{output}"
          exit_code == 1 and output == "" -> "No matches found."
          true -> "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
        end

      {:error, message} ->
        "Error: #{message}"
    end
  end
end
