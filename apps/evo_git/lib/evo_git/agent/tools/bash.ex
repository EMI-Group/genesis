defmodule EvoGit.Agent.Tools.Bash do
  @moduledoc """
  Tool for executing bash commands.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "bash",
      description: """
      Executes a shell command via bash -c.
      Useful for running scripts, building, testing, or executing common command-line tools.
      The current working directory is automatically set to the current node path under a worktree.

      STRICT CONSTRAINTS:
      - Do NOT use bash for file operations unless dedicated tools fail.
      - File search: Use glob (not find)
      - Directory creation: Use make_dir (not mkdir)
      - Read files: Use file_read (not cat/head/tail)
      - Edit files: Use file_edit (not sed/awk)
      - Write files: Use file_write (not echo/cat EOF)
      - Communication: Output directly (not echo/printf)
      Aside from these exceptions, you can use bash to run tools for file operations:
      - Use ls with args for listing files with specific needs (e.g., `ls -la` for detailed listing).
      - Use find for complex file searching with regex
      - Use mkdir for creating directories
      - Use project level package managers (e.g., uv, npm, mix, cargo) for managing dependencies.

      EXECUTION RULES:
      - Avoid using `cd`, and prefer relative paths for in-repo operations and absolute paths for external operations.
      - Double-quote all paths containing spaces.
      - Verify parent directories exist before creating files/folders.
      - Always use $TMPDIR for temporary files, never /tmp.
      - In `find -regex` alternations, place the longest alternative first (e.g., `'.*\.\(tsx\|ts\)'`).
      """,
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
    case Shared.fetch_string_arg(args, "command") do
      {:ok, command} ->
        do_execute(command, repo_path, repo_root)

      {:error, message} ->
        message
    end
  end

  defp do_execute(command, repo_path, repo_root) do
    systemd_args = EvoGit.sandbox_args(repo_path, "bash", ["-c", command], repo_root)

    {output, exit_code} = System.cmd("systemd-run", systemd_args, stderr_to_stdout: true)

    if exit_code == 0 do
      "Command executed successfully.\nOutput:\n#{output}"
    else
      "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
    end
  end
end
