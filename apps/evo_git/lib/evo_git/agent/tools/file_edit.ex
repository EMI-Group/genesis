defmodule EvoGit.Agent.Tools.FileEdit do
  @moduledoc """
  Tool for editing file contents via string replacement.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "edit_file",
      description:
        "Performs exact string replacements in files. " <>
          "Usage: " <>
          "- When editing text from Read tool output, ensure you preserve the exact indentation " <>
          "(tabs/spaces) as it appears AFTER the line number prefix. " <>
          "- ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required. " <>
          "- The edit will FAIL if `old_string` is not unique in the file. Either provide a larger " <>
          "string with more surrounding context to make it unique or use `replace_all` to change " <>
          "every instance of `old_string`.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "The path to the file to modify (relative to git repo path, e.g., './lib/app.ex')"},
          "old_string" => %{
            "type" => "string",
            "description" => "The exact text to replace"
          },
          "new_string" => %{
            "type" => "string",
            "description" => "The replacement text"
          },
          "replace_all" => %{
            "type" => "boolean",
            "description" => "Replace all occurrences (default: false)",
            "default" => false
          }
        },
        "required" => ["file_path", "old_string", "new_string"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the edit_file tool.
  """
  def execute(args, repo_path, _repo_root, node_path \\ nil) do
    with {:ok, file_path} <- Shared.fetch_string_arg(args, "file_path"),
         {:ok, old_string} <- Shared.fetch_string_arg(args, "old_string"),
         {:ok, new_string} <- Shared.fetch_string_arg(args, "new_string"),
         {:ok, replace_all} <- Shared.validate_replace_all(Map.get(args, "replace_all", false)),
         expanded_path = Shared.expand_path(file_path, repo_path) do
      do_edit(expanded_path, file_path, old_string, new_string, replace_all, repo_path, node_path)
    end
  end

  defp do_edit(file_path, display_path, old_string, new_string, replace_all, repo_path, node_path) do
    case Shared.validate_file_scope(file_path, node_path, repo_path) do
      :ok ->
        Shared.perform_string_replace(file_path, display_path, old_string, new_string, replace_all)

      {:error, message} ->
        message
    end
  end
end
