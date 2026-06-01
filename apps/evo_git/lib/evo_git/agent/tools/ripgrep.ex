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
      description: """
      Executes ripgrep (rg) to search for patterns in files. Provide arguments as a list of strings.
      The working directory is set to git repo path (the current git worktree path).

      ripgrep (rg) recursively searches the current directory for lines matching a regex pattern.
      By default, ripgrep will respect gitignore rules and automatically skip hidden files/directories and binary files.
      IMPORTANT: Explicitly provide the pattern and path arguments, otherwise rg will try to read them from stdin, which will cause the command to hang and timeout.

      USAGE:
          rg [OPTIONS] PATTERN [PATH ...]
          rg [OPTIONS] -e PATTERN ... [PATH ...]
          rg [OPTIONS] -f PATTERNFILE ... [PATH ...]
          rg [OPTIONS] --files [PATH ...]
          rg [OPTIONS] --type-list
          command | rg [OPTIONS] PATTERN
          rg [OPTIONS] --help
          rg [OPTIONS] --version

      EXAMPLE ARGS:
          ["-n", "TODO", "src/"] - searches for the pattern "TODO" in the "src/" and prints line numbers
          ["-i", "-e", "fixme", "."] - case-insensitive
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "args" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of arguments to pass to rg, e.g. ['-n', 'pattern', 'path']"
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" =>
              "Maximum output size in bytes before truncation. " <>
                "Default: 16384 (16KB). Increase up to 131072 (128KB) if you need more output.",
            "default" => 16_384
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
    case Shared.fetch_array_arg(args, "args") do
      {:ok, sanitized_args} ->
        {output, exit_code} =
          EvoGit.sandbox_run(repo_path, "rg", sanitized_args, repo_root)

        cond do
          exit_code == 0 -> "Command executed successfully.\nOutput:\n#{output}"
          exit_code == 1 and output == "" -> "No matches found."
          true -> "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
        end

      {:error, message} ->
        message
    end
  end
end
