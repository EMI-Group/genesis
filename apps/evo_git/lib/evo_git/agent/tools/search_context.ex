defmodule EvoGit.Agent.Tools.SearchContext do
  @moduledoc """
  Tool for searching patterns in CONTEXT.md files within a node path.

  Wraps ripgrep to specifically target CONTEXT.md files, allowing agents to
  search architectural documentation and spatial contracts across the codebase.
  """

  alias EvoGit.Agent.Tools.Shared

  @default_path "./"
  @default_context 3

  def schema do
    ReqLLM.tool(
      name: "search_context",
      description: """
      Search for a regex pattern in all CONTEXT.md files within a given node path recursively.
      Returns matching lines with their file paths and surrounding context lines.
      Use this tool to quickly narrow down relevant architectural information to help navigate the codebase and understand spatial contracts.
      Uses ripgrep internally, so the pattern follows ripgrep's regex syntax.
      """,
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "The regex pattern to search for in CONTEXT.md files"
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "The node path (directory) to search within, relative to repository root (e.g., './', './lib', './src/components'). Default: \"./\"",
            "default" => @default_path
          },
          "context" => %{
            "type" => "integer",
            "description" =>
              "Number of context lines to display around matches (combines before and after). Default: #{@default_context}",
            "default" => @default_context
          }
        },
        "required" => ["pattern"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  def execute(args, repo_path, repo_root) do
    case Shared.fetch_string_arg(args, "pattern") do
      {:ok, pattern} ->
        path = get_optional_string(args, "path", @default_path)
        context = get_optional_integer(args, "context", @default_context)

        rg_args = ["-n", "-C", to_string(context), pattern, "--glob", "CONTEXT.md", path]

        {output, exit_code} = EvoGit.sandbox_run(repo_path, "rg", rg_args, repo_root)

        cond do
          exit_code == 0 -> "Command executed successfully.\nOutput:\n#{output}"
          exit_code == 1 and output == "" -> "No matches found."
          true -> "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
        end

      {:error, message} ->
        message
    end
  end

  defp get_optional_string(args, key, default) do
    case Map.get(args, key, default) do
      val when is_binary(val) -> val
      val -> to_string(val)
    end
  end

  defp get_optional_integer(args, key, default) do
    case Map.get(args, key, default) do
      val when is_integer(val) -> val
      val when is_binary(val) -> String.to_integer(val)
      _ -> default
    end
  end
end
