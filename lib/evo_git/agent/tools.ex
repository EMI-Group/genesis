defmodule EvoGit.Agent.Tools do
  @moduledoc """
  Tool implementations for the coding agent.
  """

  @doc """
  Returns a list of all available tool schemas for ReqLLM.
  """
  def schemas do
    [
      read_file_schema(),
      read_many_files_schema(),
      write_file_schema(),
      replace_in_file_schema(),
      run_shell_command_schema(),
      rg_schema(),
      git_schema(),
      glob_schema(),
      list_directory_schema()
    ]
  end

  @doc """
  Returns a specific tool schema by name.
  """
  def schema("read_file"), do: read_file_schema()
  def schema("read_many_files"), do: read_many_files_schema()
  def schema("write_file"), do: write_file_schema()
  def schema("replace_in_file"), do: replace_in_file_schema()
  def schema("run_shell_command"), do: run_shell_command_schema()
  def schema("rg"), do: rg_schema()
  def schema("git"), do: git_schema()
  def schema("glob"), do: glob_schema()
  def schema("list_directory"), do: list_directory_schema()

  @doc """
  Executes a tool by name with the given arguments.
  """
  def execute("read_file", args) do
    file_path = Map.fetch!(args, "file_path")

    case File.read(file_path) do
      {:ok, content} -> content
      {:error, reason} -> "Error reading file #{file_path}: #{:file.format_error(reason)}"
    end
  end

  def execute("read_many_files", args) do
    paths = Map.fetch!(args, "file_paths")

    Enum.map_join(paths, "\n---\n", fn path ->
      case File.read(path) do
        {:ok, content} -> "File: #{path}\n#{content}"
        {:error, reason} -> "Error reading file #{path}: #{:file.format_error(reason)}"
      end
    end)
  end

  def execute("write_file", args) do
    file_path = Map.fetch!(args, "file_path")
    content = Map.fetch!(args, "content")

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(file_path))

    case File.write(file_path, content) do
      :ok -> "Successfully wrote to #{file_path}"
      {:error, reason} -> "Error writing file #{file_path}: #{:file.format_error(reason)}"
    end
  end

  def execute("replace_in_file", args) do
    file_path = Map.fetch!(args, "file_path")
    old_text = Map.fetch!(args, "old_text")
    new_text = Map.fetch!(args, "new_text")

    case File.read(file_path) do
      {:ok, content} ->
        if String.contains?(content, old_text) do
          updated_content = String.replace(content, old_text, new_text)

          case File.write(file_path, updated_content) do
            :ok -> "Successfully replaced text in #{file_path}"
            {:error, reason} -> "Error writing file #{file_path}: #{:file.format_error(reason)}"
          end
        else
          "Error: old_text not found in file #{file_path}"
        end

      {:error, reason} ->
        "Error reading file #{file_path}: #{:file.format_error(reason)}"
    end
  end

  def execute("run_shell_command", args) do
    command = Map.fetch!(args, "command")

    cwd = Application.get_env(:evo_git, :repo_path, File.cwd!())
    systemd_args = EvoGit.sandbox_args(cwd, "bash", ["-c", command])

    # Execute via systemd-run
    {output, exit_code} = System.cmd("systemd-run", systemd_args, stderr_to_stdout: true)

    if exit_code == 0 do
      "Command executed successfully.\nOutput:\n#{output}"
    else
      "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
    end
  end

  def execute("rg", args) do
    args_list = Map.fetch!(args, "args")

    cwd = Application.get_env(:evo_git, :repo_path, File.cwd!())
    systemd_args = EvoGit.sandbox_args(cwd, "rg", args_list)

    {output, exit_code} = System.cmd("systemd-run", systemd_args, stderr_to_stdout: true)

    cond do
      exit_code == 0 -> "Command executed successfully.\nOutput:\n#{output}"
      exit_code == 1 and output == "" -> "No matches found."
      true -> "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
    end
  end

  def execute("git", args) do
    args_list = Map.fetch!(args, "args")

    cwd = Application.get_env(:evo_git, :repo_path, File.cwd!())
    systemd_args = EvoGit.sandbox_args(cwd, "git", args_list)

    {output, exit_code} = System.cmd("systemd-run", systemd_args, stderr_to_stdout: true)

    if exit_code == 0 do
      "Command executed successfully.\nOutput:\n#{output}"
    else
      "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
    end
  end

  def execute("glob", args) do
    pattern = Map.fetch!(args, "pattern")
    cwd = Application.get_env(:evo_git, :repo_path, File.cwd!())

    File.cd!(cwd, fn ->
      case Path.wildcard(pattern, match_dot: true) do
        [] -> "No files found matching pattern: #{pattern}"
        paths -> Enum.join(paths, "\n")
      end
    end)
  end

  def execute("list_directory", args) do
    dir_path = Map.fetch!(args, "dir_path")
    cwd = Application.get_env(:evo_git, :repo_path, File.cwd!())
    full_path = Path.expand(dir_path, cwd)

    case File.ls(full_path) do
      {:ok, files} -> Enum.join(files, "\n")
      {:error, reason} -> "Error listing directory #{dir_path}: #{:file.format_error(reason)}"
    end
  end

  def execute(unknown_tool, _args) do
    "Error: Unknown tool '#{unknown_tool}'"
  end

  # --- Schemas ---

  defp read_file_schema do
    ReqLLM.tool(
      name: "read_file",
      description: "Reads the content of a single file.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "The path to the file to read"}
        },
        "required" => ["file_path"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  defp read_many_files_schema do
    ReqLLM.tool(
      name: "read_many_files",
      description: "Reads the contents of multiple files.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of file paths to read"
          }
        },
        "required" => ["file_paths"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  defp write_file_schema do
    ReqLLM.tool(
      name: "write_file",
      description: "Writes content to a file, creating it if it doesn't exist.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "The path to the file to write"},
          "content" => %{"type" => "string", "description" => "The content to write to the file"}
        },
        "required" => ["file_path", "content"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  defp replace_in_file_schema do
    ReqLLM.tool(
      name: "replace_in_file",
      description: "Replaces exactly matching text in a file with new text.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string", "description" => "The path to the file"},
          "old_text" => %{
            "type" => "string",
            "description" => "The exact literal text to replace"
          },
          "new_text" => %{
            "type" => "string",
            "description" => "The exact literal text to replace old_text with"
          }
        },
        "required" => ["file_path", "old_text", "new_text"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  defp run_shell_command_schema do
    ReqLLM.tool(
      name: "run_shell_command",
      description:
        "Executes a shell command via bash -c. Common Linux command line tools and tools used in the project are mostly available.",
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

  defp rg_schema do
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

  defp git_schema do
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

  defp glob_schema do
    ReqLLM.tool(
      name: "glob",
      description: "Finds files matching a specific glob pattern.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "The glob pattern to match against (e.g., 'lib/**/*.ex')"
          }
        },
        "required" => ["pattern"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  defp list_directory_schema do
    ReqLLM.tool(
      name: "list_directory",
      description:
        "Lists the names of files and subdirectories directly within a specified directory path.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" => "The path to the directory to list (e.g., '.', 'lib', 'test')"
          }
        },
        "required" => ["dir_path"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end
end
