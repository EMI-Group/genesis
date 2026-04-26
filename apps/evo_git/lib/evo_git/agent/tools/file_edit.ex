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
      name: "file_edit",
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
          "file_path" => %{"type" => "string", "description" => "The path to the file to modify"},
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
  Executes the file_edit tool.
  """
  def execute(args, repo_path, _repo_root) do
    with {:ok, file_path} <- Shared.fetch_string_arg(args, "file_path"),
         {:ok, old_string} <- Shared.fetch_string_arg(args, "old_string"),
         {:ok, new_string} <- Shared.fetch_string_arg(args, "new_string"),
         {:ok, replace_all} <- validate_replace_all(Map.get(args, "replace_all", false)),
         expanded_path = Shared.expand_path(file_path, repo_path) do
      do_edit(expanded_path, old_string, new_string, replace_all)
    end
  end

  defp validate_replace_all(value) when is_boolean(value), do: {:ok, value}

  defp validate_replace_all(value),
    do: {:error, "Argument 'replace_all' must be a boolean, got: #{inspect(value)}"}

  defp do_edit(file_path, old_string, new_string, replace_all) do
    case File.read(file_path) do
      {:ok, content} ->
        actual_old = Shared.find_actual_string(content, old_string)

        if is_nil(actual_old) do
          "Error: old_string not found in file #{file_path}"
        else
          match_count = Shared.count_occurrences(content, actual_old)

          if match_count > 1 and not replace_all do
            "Error: Found #{match_count} matches of old_string in file. Set replace_all=true or provide more context."
          else
            updated_content = apply_edit(content, actual_old, new_string, replace_all)

            case File.write(file_path, updated_content) do
              :ok ->
                if replace_all do
                  "The file #{file_path} has been updated. All occurrences were successfully replaced."
                else
                  "The file #{file_path} has been updated successfully."
                end

              {:error, reason} ->
                "Error writing file #{file_path}: #{:file.format_error(reason)}"
            end
          end
        end

      {:error, reason} ->
        "Error reading file #{file_path}: #{:file.format_error(reason)}"
    end
  end

  defp apply_edit(content, old_string, new_string, replace_all) do
    trimmed_new = String.trim_trailing(new_string)

    if replace_all do
      String.replace(content, old_string, trimmed_new)
    else
      String.replace(content, old_string, trimmed_new, global: false)
    end
  end
end
