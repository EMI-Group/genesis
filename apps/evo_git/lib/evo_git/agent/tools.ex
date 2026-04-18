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
      rewrite_file_schema(),
      create_files_schema(),
      create_directories_schema(),
      replace_in_file_schema(),
      read_dir_context_schema(),
      rewrite_dir_context_schema(),
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
  def schema("rewrite_file"), do: rewrite_file_schema()
  def schema("create_files"), do: create_files_schema()
  def schema("create_directories"), do: create_directories_schema()
  def schema("replace_in_file"), do: replace_in_file_schema()
  def schema("read_dir_context"), do: read_dir_context_schema()
  def schema("rewrite_dir_context"), do: rewrite_dir_context_schema()
  def schema("run_shell_command"), do: run_shell_command_schema()
  def schema("rg"), do: rg_schema()
  def schema("git"), do: git_schema()
  def schema("glob"), do: glob_schema()
  def schema("list_directory"), do: list_directory_schema()

  @doc """
  Executes a tool by name with the given arguments.

  ## Parameters

  - `tool_name` - The name of the tool to execute
  - `args` - The arguments to pass to the tool
  - `repo_path` - The working directory path for file operations
  - `repo_root` - Optional path to the git repository root. If provided,
    this is passed to sandbox operations to allow write access to the shared
    git database (needed for git worktrees).

  """
  def execute(tool_name, args, repo_path, repo_root \\ nil) do
    execute_tool(tool_name, args, repo_path, repo_root)
  end

  defp execute_tool("read_file", args, repo_path, _repo_root) do
    file_path = Map.fetch!(args, "file_path") |> expand_path(repo_path)

    case File.read(file_path) do
      {:ok, content} -> content
      {:error, reason} -> "Error reading file #{file_path}: #{:file.format_error(reason)}"
    end
  end

  defp execute_tool("read_many_files", args, repo_path, _repo_root) do
    paths = Map.fetch!(args, "file_paths")

    Enum.map_join(paths, "\n---\n", fn path ->
      full_path = expand_path(path, repo_path)

      case File.read(full_path) do
        {:ok, content} -> "File: #{path}\n#{content}"
        {:error, reason} -> "Error reading file #{path}: #{:file.format_error(reason)}"
      end
    end)
  end

  defp execute_tool("write_file", args, repo_path, _repo_root) do
    file_path = Map.fetch!(args, "file_path") |> expand_path(repo_path)
    content = Map.fetch!(args, "content")

    # Ensure directory exists
    case File.mkdir_p(Path.dirname(file_path)) do
      :ok ->
        case File.write(file_path, content) do
          :ok -> "Successfully wrote to #{file_path}"
          {:error, reason} -> "Error writing file #{file_path}: #{:file.format_error(reason)}"
        end

      {:error, reason} ->
        "Error creating directory for #{file_path}: #{:file.format_error(reason)}"
    end
  end

  defp execute_tool("rewrite_file", args, repo_path, _repo_root) do
    file_path = Map.fetch!(args, "file_path") |> expand_path(repo_path)
    content = Map.fetch!(args, "content")

    if File.regular?(file_path) do
      case File.write(file_path, content) do
        :ok -> "Successfully rewrote #{file_path}"
        {:error, reason} -> "Error writing file #{file_path}: #{:file.format_error(reason)}"
      end
    else
      "Error: '#{file_path}' does not exist or is not a regular file"
    end
  end

  defp execute_tool("create_files", args, repo_path, _repo_root) do
    paths = Map.fetch!(args, "file_paths")

    Enum.map_join(paths, "\n", fn path ->
      full_path = expand_path(path, repo_path)

      case File.mkdir_p(Path.dirname(full_path)) do
        :ok ->
          case File.write(full_path, "") do
            :ok -> "Successfully created file #{path}"
            {:error, reason} -> "Error creating file #{path}: #{:file.format_error(reason)}"
          end

        {:error, reason} ->
          "Error creating directory for #{path}: #{:file.format_error(reason)}"
      end
    end)
  end

  defp execute_tool("create_directories", args, repo_path, _repo_root) do
    paths = Map.fetch!(args, "dir_paths")

    Enum.map_join(paths, "\n", fn path ->
      full_path = expand_path(path, repo_path)

      case File.mkdir_p(full_path) do
        :ok ->
          gitkeep_path = Path.join(full_path, ".gitkeep")

          case File.write(gitkeep_path, "") do
            :ok -> "Successfully created directory #{path} with .gitkeep"
            {:error, reason} -> "Error creating directory #{path}: #{:file.format_error(reason)}"
          end

        {:error, reason} ->
          "Error creating directory #{path}: #{:file.format_error(reason)}"
      end
    end)
  end

  defp execute_tool("replace_in_file", args, repo_path, _repo_root) do
    file_path = Map.fetch!(args, "file_path") |> expand_path(repo_path)
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

  defp execute_tool("read_dir_context", args, repo_path, _repo_root) do
    dir_path = Map.fetch!(args, "dir_path")
    full_dir = expand_path(dir_path, repo_path)

    cond do
      not File.exists?(full_dir) ->
        "Error: directory '#{dir_path}' does not exist"

      not File.dir?(full_dir) ->
        "Error: '#{dir_path}' is a file, not a directory. CONTEXT.md is only for directories."

      true ->
        context_path = Path.join(full_dir, "CONTEXT.md")

        case File.read(context_path) do
          {:ok, content} -> content
          {:error, :enoent} -> "No CONTEXT.md found in directory '#{dir_path}'"
          {:error, reason} -> "Error reading CONTEXT.md: #{:file.format_error(reason)}"
        end
    end
  end

  defp execute_tool("rewrite_dir_context", args, repo_path, repo_root) do
    dir_path = Map.fetch!(args, "dir_path")
    content = Map.fetch!(args, "content")
    commit = Map.get(args, "commit", true)
    full_dir = expand_path(dir_path, repo_path)

    cond do
      not File.exists?(full_dir) ->
        "Error: directory '#{dir_path}' does not exist"

      not File.dir?(full_dir) ->
        "Error: '#{dir_path}' is a file, not a directory. CONTEXT.md is only for directories."

      true ->
        context_path = Path.join(full_dir, "CONTEXT.md")

        case File.write(context_path, content) do
          :ok ->
            result_msg = "Successfully updated CONTEXT.md for directory '#{dir_path}'"

            if commit do
              relative_path = Path.join(dir_path, "CONTEXT.md")
              systemd_add_args = EvoGit.sandbox_args(repo_path, "git", ["add", relative_path], repo_root)
              systemd_commit_args =
                EvoGit.sandbox_args(repo_path, "git", [
                  "commit",
                  "-m",
                  "Update CONTEXT.md for #{dir_path}"
                ], repo_root)

              add_output = elem(System.cmd("systemd-run", systemd_add_args, stderr_to_stdout: true), 0)
              commit_output = elem(System.cmd("systemd-run", systemd_commit_args, stderr_to_stdout: true), 0)

              result_msg <>
                "\n\nCommitted:\n#{add_output}#{commit_output}"
            else
              result_msg
            end

          {:error, reason} ->
            "Error writing CONTEXT.md: #{:file.format_error(reason)}"
        end
    end
  end

  defp execute_tool("run_shell_command", args, repo_path, repo_root) do
    command = Map.fetch!(args, "command")
    systemd_args = EvoGit.sandbox_args(repo_path, "bash", ["-c", command], repo_root)

    # Execute via systemd-run
    {output, exit_code} = System.cmd("systemd-run", systemd_args, stderr_to_stdout: true)

    if exit_code == 0 do
      "Command executed successfully.\nOutput:\n#{output}"
    else
      "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
    end
  end

  defp execute_tool("rg", args, repo_path, repo_root) do
    args_list = Map.fetch!(args, "args")
    systemd_args = EvoGit.sandbox_args(repo_path, "rg", args_list, repo_root)

    {output, exit_code} = System.cmd("systemd-run", systemd_args, stderr_to_stdout: true)

    cond do
      exit_code == 0 -> "Command executed successfully.\nOutput:\n#{output}"
      exit_code == 1 and output == "" -> "No matches found."
      true -> "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
    end
  end

  defp execute_tool("git", args, repo_path, repo_root) do
    args_list = Map.fetch!(args, "args")
    systemd_args = EvoGit.sandbox_args(repo_path, "git", args_list, repo_root)

    {output, exit_code} = System.cmd("systemd-run", systemd_args, stderr_to_stdout: true)

    if exit_code == 0 do
      "Command executed successfully.\nOutput:\n#{output}"
    else
      "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
    end
  end

  defp execute_tool("glob", args, repo_path, _repo_root) do
    pattern = Map.fetch!(args, "pattern")

    # Path.wildcard doesn't support a cwd option directly.
    # To avoid changing the VM's global cwd (which breaks concurrent workers),
    # we prepend the cwd to the pattern, run wildcard, and then strip the cwd prefix.
    full_pattern = Path.join(repo_path, pattern)

    case Path.wildcard(full_pattern, match_dot: true) do
      [] ->
        "No files found matching pattern: #{pattern}"

      paths ->
        paths
        |> Enum.map(fn path -> Path.relative_to(path, repo_path) end)
        |> Enum.join("\n")
    end
  end

  defp execute_tool("list_directory", args, repo_path, _repo_root) do
    dir_path = Map.fetch!(args, "dir_path")
    full_path = Path.expand(dir_path, repo_path)

    case File.ls(full_path) do
      {:ok, files} -> Enum.join(files, "\n")
      {:error, reason} -> "Error listing directory #{dir_path}: #{:file.format_error(reason)}"
    end
  end

  defp execute_tool(unknown_tool, _args, _repo_path, _repo_root) do
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

  defp rewrite_file_schema do
    ReqLLM.tool(
      name: "rewrite_file",
      description:
        "Completely replaces the entire content of an existing file. " <>
          "The file must already exist. Use this instead of replace_in_file when you need to " <>
          "rewrite the whole file rather than making a targeted substitution.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "The path to the existing file to rewrite"
          },
          "content" => %{
            "type" => "string",
            "description" => "The complete new content for the file"
          }
        },
        "required" => ["file_path", "content"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  defp create_files_schema do
    ReqLLM.tool(
      name: "create_files",
      description: "Creates multiple empty files, ensuring their parent directories exist.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of file paths to create"
          }
        },
        "required" => ["file_paths"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  defp create_directories_schema do
    ReqLLM.tool(
      name: "create_directories",
      description:
        "Creates multiple empty directories and adds a .gitkeep file to each so they are tracked by version control.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of directory paths to create"
          }
        },
        "required" => ["dir_paths"]
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

  defp read_dir_context_schema do
    ReqLLM.tool(
      name: "read_dir_context",
      description:
        "Reads the CONTEXT.md file of a directory node. " <>
          "CONTEXT.md defines the directory's semantic contract (Intent, API Surface, Constraints). " <>
          "Returns the content if it exists, or a message indicating no CONTEXT.md was found.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The relative path to the directory whose CONTEXT.md should be read (e.g., '.', 'lib', 'src/foo')"
          }
        },
        "required" => ["dir_path"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  defp rewrite_dir_context_schema do
    ReqLLM.tool(
      name: "rewrite_dir_context",
      description:
        "Creates or updates the CONTEXT.md file for a directory node. " <>
          "CONTEXT.md defines the directory's semantic contract: its Intent (purpose), " <>
          "API Surface (exports), and Constraints (rules for children). " <>
          "Use this tool whenever you need to establish or revise a directory's context. " <>
          "For file-level context (header/module comments), use normal code editing tools instead.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "dir_path" => %{
            "type" => "string",
            "description" =>
              "The relative path to the directory whose CONTEXT.md should be updated (e.g., '.', 'lib', 'src/foo')"
          },
          "content" => %{
            "type" => "string",
            "description" =>
              "The full markdown content for the CONTEXT.md file. Should include Intent, API Surface, and Constraints sections."
          },
          "commit" => %{
            "type" => "boolean",
            "description" =>
              "Whether to commit the CONTEXT.md file after writing. Defaults to true. When true, only the CONTEXT.md file is committed.",
            "default" => true
          }
        },
        "required" => ["dir_path", "content"]
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

  defp expand_path(file_path, repo_path) do
    Path.expand(file_path, repo_path)
  end
end
