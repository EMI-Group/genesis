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
      name: "edit",
      description:
        "Performs an exact string replacement in an existing file.\n" <>
          "- `old_string` must match the file byte-exactly and must be UNIQUE: if it is not, " <>
          "extend `old_string` with more surrounding context, or set `replace_all: true`.\n" <>
          "- Preserve the file's exact indentation from `read` output: the line-number prefix " <>
          "there is NUMBER<TAB>, so the indentation after it is the real file indentation.\n" <>
          "- Returns \"The file <file_path> has been updated successfully.\" " <>
          "(with `replace_all: true`: \"The file <file_path> has been updated. " <>
          "All occurrences were successfully replaced.\").",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" =>
              "The file to modify (path relative to the repo root, e.g. './lib/app.ex')"
          },
          "old_string" => %{
            "type" => "string",
            "description" =>
              "The exact text to replace — must occur exactly once unless replace_all is true"
          },
          "new_string" => %{
            "type" => "string",
            "description" => "The replacement text, inserted byte-for-byte"
          },
          "replace_all" => %{
            "type" => "boolean",
            "description" => "Replace every occurrence of old_string (default: false)",
            "default" => false
          }
        },
        "required" => ["file_path", "old_string", "new_string"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the `edit` tool (internal dispatch key `edit_file`).
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
        Shared.perform_string_replace(
          file_path,
          display_path,
          old_string,
          new_string,
          replace_all
        )

      {:error, message} ->
        message
    end
  end
end
