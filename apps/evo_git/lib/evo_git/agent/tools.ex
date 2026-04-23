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
      file_write_schema(),
      file_edit_schema(),
      read_dir_context_schema(),
      rewrite_dir_context_schema(),
      bash_schema(),
      rg_schema(),
      git_schema(),
      glob_schema(),
      list_directory_schema(),
      web_search_schema(),
      web_read_schema()
    ]
  end

  @doc """
  Returns a specific tool schema by name.
  """
  def schema(:read_file), do: read_file_schema()
  def schema(:file_write), do: file_write_schema()
  def schema(:file_edit), do: file_edit_schema()
  def schema(:read_dir_context), do: read_dir_context_schema()
  def schema(:rewrite_dir_context), do: rewrite_dir_context_schema()
  def schema(:bash), do: bash_schema()
  def schema(:rg), do: rg_schema()
  def schema(:git), do: git_schema()
  def schema(:glob), do: glob_schema()
  def schema(:list_directory), do: list_directory_schema()
  def schema(:web_search), do: web_search_schema()
  def schema(:web_read), do: web_read_schema()

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

  # Validates and sanitizes an array argument to ensure all elements are binaries.
  # Returns {:ok, sanitized_list} or :error with a descriptive message.
  defp validate_string_array(array) when is_list(array) do
    Enum.reduce_while(array, {:ok, []}, fn item, {:ok, acc} ->
      case to_string_binary(item) do
        {:ok, binary} -> {:cont, {:ok, [binary | acc]}}
        :error -> {:halt, {:error, "Arguments contains non-string value: #{inspect(item)}"}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = error -> error
    end
  end

  defp validate_string_array(_), do: {:error, "The arguments must be an array"}

  # Converts a value to a string binary if possible.
  defp to_string_binary(value) when is_binary(value), do: {:ok, value}
  defp to_string_binary(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp to_string_binary(value) when is_float(value), do: {:ok, Float.to_string(value)}
  defp to_string_binary(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp to_string_binary(_), do: :error

  # Finds the actual string in file content, handling quote normalization
  # LLMs output straight quotes, but files may contain curly quotes
  defp find_actual_string(file_content, search_string) do
    if String.contains?(file_content, search_string) do
      search_string
    else
      # Try quote normalization (curly quotes → straight quotes)
      normalized_search = normalize_quotes(search_string)
      normalized_file = normalize_quotes(file_content)

      if String.contains?(normalized_file, normalized_search) do
        # Find the position in normalized content
        case :binary.match(normalized_file, normalized_search) do
          {start_pos, _length} ->
            # Extract original string with curly quotes from file
            byte_len = byte_size(search_string)
            binary_part(file_content, start_pos, byte_len)

          :nomatch ->
            nil
        end
      else
        nil
      end
    end
  end

  # Normalizes curly quotes to straight quotes for matching
  # U+2018 ' → ', U+2019 ' → ', U+201C " → ", U+201D " → "
  defp normalize_quotes(str) do
    str
    |> String.replace("\u2018", "'")
    |> String.replace("\u2019", "'")
    |> String.replace("\u201C", "\"")
    |> String.replace("\u201D", "\"")
  end

  defp count_occurrences(content, pattern) do
    content
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end

  defp apply_edit(content, old_string, new_string, replace_all) do
    # Strip trailing whitespace from new_string
    trimmed_new = String.trim_trailing(new_string)

    if replace_all do
      String.replace(content, old_string, trimmed_new)
    else
      String.replace(content, old_string, trimmed_new, global: false)
    end
  end

  defp execute_tool("read_file", args, repo_path, _repo_root) do
    file_path = Map.fetch!(args, "file_path") |> expand_path(repo_path)
    offset = Map.get(args, "offset", 1)
    limit = Map.get(args, "limit", 2000)

    with {:ok, stat} <- File.stat(file_path),
         :ok <-
           validate_file_size(stat, Map.has_key?(args, "offset") or Map.has_key?(args, "limit")),
         {:ok, result} <- read_file_with_lines(file_path, stat, offset, limit) do
      format_file_read_result(result, file_path)
    else
      {:error, :too_large} ->
        "Error: File #{file_path} is too large (>256 KB). Use offset and limit parameters to read specific ranges."

      {:error, reason} ->
        "Error reading file #{file_path}: #{:file.format_error(reason)}"
    end
  end

  defp execute_tool("file_write", args, repo_path, _repo_root) do
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

  defp execute_tool("file_edit", args, repo_path, _repo_root) do
    file_path = Map.fetch!(args, "file_path") |> expand_path(repo_path)
    old_string = Map.fetch!(args, "old_string")
    new_string = Map.fetch!(args, "new_string")
    replace_all = Map.get(args, "replace_all", false)

    case File.read(file_path) do
      {:ok, content} ->
        # Quote normalization: find actual string in file (may have curly quotes)
        actual_old = find_actual_string(content, old_string)

        if is_nil(actual_old) do
          "Error: old_string not found in file #{file_path}"
        else
          # Count matches
          match_count = count_occurrences(content, actual_old)

          if match_count > 1 and not replace_all do
            "Error: Found #{match_count} matches of old_string in file. Set replace_all=true or provide more context."
          else
            # Apply replacement
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

              systemd_add_args =
                EvoGit.sandbox_args(repo_path, "git", ["add", relative_path], repo_root)

              systemd_commit_args =
                EvoGit.sandbox_args(
                  repo_path,
                  "git",
                  [
                    "commit",
                    "-m",
                    "Update CONTEXT.md for #{dir_path}"
                  ],
                  repo_root
                )

              add_output =
                elem(System.cmd("systemd-run", systemd_add_args, stderr_to_stdout: true), 0)

              commit_output =
                elem(System.cmd("systemd-run", systemd_commit_args, stderr_to_stdout: true), 0)

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

  defp execute_tool("bash", args, repo_path, repo_root) do
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

    case validate_string_array(args_list) do
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

  defp execute_tool("git", args, repo_path, repo_root) do
    args_list = Map.fetch!(args, "args")

    case validate_string_array(args_list) do
      {:ok, sanitized_args} ->
        systemd_args = EvoGit.sandbox_args(repo_path, "git", sanitized_args, repo_root)

        {output, exit_code} = System.cmd("systemd-run", systemd_args, stderr_to_stdout: true)

        if exit_code == 0 do
          "Command executed successfully.\nOutput:\n#{output}"
        else
          "Command failed with exit code #{exit_code}.\nOutput:\n#{output}"
        end

      {:error, message} ->
        "Error: #{message}"
    end
  end

  defp execute_tool("glob", args, repo_path, _repo_root) do
    pattern = Map.fetch!(args, "pattern")
    search_path = Map.get(args, "path", repo_path) |> Path.expand(repo_path)
    max_files = Map.get(args, "max_files", 100)

    # Path.wildcard doesn't support a cwd option directly.
    # To avoid changing the VM's global cwd (which breaks concurrent workers),
    # we prepend the search_path to the pattern, run wildcard, and then strip the prefix.
    full_pattern = Path.join(search_path, pattern)

    case Path.wildcard(full_pattern, match_dot: true) do
      [] ->
        "No files found matching pattern: #{pattern}"

      paths ->
        # Get file stats for sorting by mtime
        {sorted_paths, total_count} =
          paths
          |> Enum.flat_map(fn path ->
            case File.stat(path) do
              {:ok, stat} -> [{path, stat.mtime}]
              {:error, _} -> []
            end
          end)
          |> Enum.sort_by(fn {_path, mtime} -> mtime end, :desc)
          |> then(fn sorted ->
            total = length(sorted)

            truncated =
              if total > max_files do
                Enum.take(sorted, max_files)
              else
                sorted
              end

            {truncated, total}
          end)

        # Convert to relative paths
        relative_paths =
          Enum.map(sorted_paths, fn {path, _mtime} ->
            Path.relative_to(path, search_path)
          end)

        truncated = total_count > max_files

        format_glob_result(relative_paths, total_count, truncated)
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

  # Web Search using Z.AI (zhipu.ai/chat.z.ai) - NOT Google Search
  defp execute_tool("web_search", args, _repo_path, _repo_root) do
    search_query = Map.fetch!(args, "search_query")
    count = Map.get(args, "count", 10)
    search_domain_filter = Map.get(args, "search_domain_filter")
    search_recency_filter = Map.get(args, "search_recency_filter", "noLimit")

    api_key = System.get_env("ZAI_API_KEY")

    if is_nil(api_key) do
      "Error: ZAI_API_KEY environment variable is not set"
    else
      url = "https://api.z.ai/api/paas/v4/web-search"

      body =
        %{
          search_query: search_query,
          count: count,
          search_recency_filter: search_recency_filter
        }
        |> then(fn base ->
          if search_domain_filter do
            Map.put(base, :search_domain_filter, search_domain_filter)
          else
            base
          end
        end)

      case Req.post(url,
             json: body,
             auth: {:bearer, api_key},
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: response_body}} ->
          format_web_search_response(response_body)

        {:ok, %{status: status, body: response_body}} ->
          "Error: Web search failed with status #{status}. #{inspect(response_body)}"

        {:error, reason} ->
          "Error: Web search request failed: #{inspect(reason)}"
      end
    end
  end

  # Web Read using Z.AI (zhipu.ai/chat.z.ai) Web Reader API
  defp execute_tool("web_read", args, _repo_path, _repo_root) do
    url = Map.fetch!(args, "url")
    timeout = Map.get(args, "timeout", 20)
    no_cache = Map.get(args, "no_cache", false)
    return_format = Map.get(args, "return_format", "markdown")
    retain_images = Map.get(args, "retain_images", true)

    api_key = System.get_env("ZAI_API_KEY")

    if is_nil(api_key) do
      "Error: ZAI_API_KEY environment variable is not set"
    else
      reader_url = "https://api.z.ai/api/paas/v4/reader"

      body = %{
        url: url,
        timeout: timeout * 1000,
        no_cache: no_cache,
        return_format: return_format,
        retain_images: retain_images
      }

      case Req.post(reader_url,
             json: body,
             auth: {:bearer, api_key},
             receive_timeout: :timer.seconds(timeout + 10)
           ) do
        {:ok, %{status: 200, body: response_body}} ->
          format_web_read_response(response_body)

        {:ok, %{status: status, body: response_body}} ->
          "Error: Web read failed with status #{status}. #{inspect(response_body)}"

        {:error, reason} ->
          "Error: Web read request failed: #{inspect(reason)}"
      end
    end
  end

  defp execute_tool(unknown_tool, _args, _repo_path, _repo_root) do
    "Error: Unknown tool '#{unknown_tool}'"
  end

  # --- Schemas ---

  defp read_file_schema do
    ReqLLM.tool(
      name: "read_file",
      description:
        "Reads the content of a single file. " <>
          "Returns formatted output with line numbers (cat -n style). " <>
          "Usage: " <>
          "- By default reads up to 2000 lines, with a 128 KB file size limit. " <>
          "- For large files (>128 KB), you MUST use offset and limit parameters. " <>
          "- Automatically streams files >= 5 MB for memory efficiency.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "The path to the file to read"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "Line number to start reading from (1-indexed, default: 1)",
            "default" => 1
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of lines to read (default: 2000)"
          }
        },
        "required" => ["file_path"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  defp file_write_schema do
    ReqLLM.tool(
      name: "file_write",
      description:
        "Writes a file to the local filesystem. " <>
          "Usage: " <>
          "- This tool will overwrite the existing file if there is one at the provided path. " <>
          "- Prefer the file_edit tool for modifying existing files — it only sends the diff. " <>
          "Only use this tool to create new files or for complete rewrites.",
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

  defp file_edit_schema do
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

  defp bash_schema do
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
      description:
        "Fast file pattern matching tool that works with any codebase size. " <>
          "Supports glob patterns like '**/*.js' or 'src/**/*.ts'. " <>
          "Returns matching file paths sorted by modification time (newest first). " <>
          "Usage: " <>
          "- Use this tool when you need to find files by name patterns. " <>
          "- Results are limited to 100 files by default (use max_files to adjust). " <>
          "- Example patterns: '**/*.ex', 'lib/**/*.ex', 'test/**/test_*.ex'",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" =>
              "The glob pattern to match against (e.g., 'lib/**/*.ex', '**/*.{ex,exs}')"
          },
          "path" => %{
            "type" => "string",
            "description" => "Directory to search in (default: current working directory)"
          },
          "max_files" => %{
            "type" => "integer",
            "description" => "Maximum number of files to return (default: 100)",
            "default" => 100
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

  # Web Search tool using Z.AI's Web Search API
  # Note: This is NOT Google Search. Z.AI (zhipu.ai/chat.z.ai) is a Chinese AI service provider.
  defp web_search_schema do
    ReqLLM.tool(
      name: "web_search",
      description:
        "Searches the web for information. " <>
          "Returns structured search results including titles, URLs, summaries, site names, and publication dates.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "search_query" => %{
            "type" => "string",
            "description" => "The search query string"
          },
          "count" => %{
            "type" => "integer",
            "description" => "Number of results to return (1-50, default 10)",
            "default" => 10
          },
          "search_domain_filter" => %{
            "type" => "string",
            "description" =>
              "Optional domain filter (e.g., 'www.example.com') to only search within a specific domain"
          },
          "search_recency_filter" => %{
            "type" => "string",
            "description" =>
              "Time filter for search results (e.g., 'noLimit', '1d', '1w', '1m', '1y')",
            "default" => "noLimit"
          }
        },
        "required" => ["search_query"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  # Web Read tool using Z.AI's Web Reader API
  # Note: Z.AI (zhipu.ai/chat.z.ai) is a Chinese AI service provider.
  defp web_read_schema do
    ReqLLM.tool(
      name: "web_read",
      description:
        "Reads and parses the content of a web page. " <>
          "Returns the page content in markdown or text format.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "The URL to retrieve"
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Request timeout in seconds (default 20)",
            "default" => 20
          },
          "no_cache" => %{
            "type" => "boolean",
            "description" => "Whether to disable caching (default false)",
            "default" => false
          },
          "return_format" => %{
            "type" => "string",
            "description" => "Return format: 'markdown' or 'text' (default markdown)",
            "default" => "markdown"
          },
          "retain_images" => %{
            "type" => "boolean",
            "description" => "Whether to retain images in the output (default true)",
            "default" => true
          }
        },
        "required" => ["url"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  defp expand_path(file_path, repo_path) when is_binary(file_path) do
    Path.expand(file_path, repo_path)
  end

  defp expand_path(file_path, repo_path) do
    # Gracefully handle non-string inputs by converting to string
    file_path
    |> to_string()
    |> then(&Path.expand(&1, repo_path))
  end

  # Formats the web search API response into a readable string
  defp format_web_search_response(%{"search_result" => results}) when is_list(results) do
    formatted =
      Enum.map(results, fn result ->
        title = result["title"] || "Untitled"
        link = result["link"] || ""
        content = result["content"] || ""
        media = result["media"] || ""
        publish_date = result["publish_date"] || ""

        date_str = if publish_date != "", do: " (#{publish_date})", else: ""
        media_str = if media != "", do: " - #{media}", else: ""

        "## #{title}#{date_str}#{media_str}\n#{link}\n\n#{content}\n"
      end)
      |> Enum.join("\n---\n\n")

    "Found #{length(results)} results:\n\n#{formatted}"
  end

  defp format_web_search_response(response) do
    "Search response (unexpected format): #{inspect(response)}"
  end

  # Formats the web read API response into a readable string
  defp format_web_read_response(%{"reader_result" => result}) do
    title = result["title"] || "Untitled"
    url = result["url"] || ""
    content = result["content"] || ""
    description = result["description"] || ""

    header = "# #{title}\n\nSource: #{url}\n"

    description_str =
      if description != "" do
        "#{description}\n\n"
      else
        ""
      end

    header <> description_str <> content
  end

  defp format_web_read_response(response) do
    "Read response (unexpected format): #{inspect(response)}"
  end

  # Strips UTF-8 BOM if present at start of content
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  # Validates file size - only enforce limit for default (no offset/limit) reads
  defp validate_file_size(stat, custom_range?) do
    # 256 KB
    max_size = 256 * 1024

    if custom_range? or stat.size <= max_size do
      :ok
    else
      {:error, :too_large}
    end
  end

  # Reads file with line number support, handling large files via streaming
  defp read_file_with_lines(file_path, stat, offset, limit) do
    # Fast path: small files (< 5 MB) read entirely
    file_size = stat.size

    if file_size < 5 * 1024 * 1024 do
      read_file_fast_path(file_path, offset, limit)
    else
      read_file_streaming(file_path, offset, limit)
    end
  end

  # Fast path for small files - read entirely into memory
  defp read_file_fast_path(file_path, offset, limit) do
    with {:ok, raw_content} <- File.read(file_path) do
      # Strip UTF-8 BOM if present
      content = strip_bom(raw_content)

      # Split into lines, handling both \n and \r\n
      lines =
        content
        |> String.split("\n")
        |> Enum.map(fn line -> String.replace_suffix(line, "\r", "") end)

      total_lines = length(lines)

      # Convert offset to 0-indexed, clamp to valid range
      start_index = max(0, offset - 1)
      end_index = if limit, do: min(start_index + limit, total_lines), else: total_lines

      selected_lines = Enum.slice(lines, start_index, end_index - start_index)

      {:ok,
       %{
         lines: selected_lines,
         start_line: offset,
         total_lines: total_lines,
         num_lines: length(selected_lines)
       }}
    end
  end

  # Streaming path for large files - process line by line
  defp read_file_streaming(file_path, offset, limit) do
    # Use File.stream! for memory-efficient reading
    end_index = if limit, do: offset + limit, else: :infinity

    {selected_lines, total_lines} =
      file_path
      # 512KB chunks
      |> File.stream!([], 512_000)
      |> Enum.map(fn line -> String.replace_suffix(line, "\r", "") end)
      |> Enum.reduce({[], 0}, fn line, {acc, idx} ->
        current_line = idx + 1

        selected =
          if current_line >= offset and current_line < end_index do
            [line | acc]
          else
            acc
          end

        {selected, current_line}
      end)

    {:ok,
     %{
       lines: Enum.reverse(selected_lines),
       start_line: offset,
       total_lines: total_lines,
       num_lines: length(selected_lines)
     }}
  end

  # Formats result with line numbers (cat -n style)
  defp format_file_read_result(result, file_path) do
    %{lines: lines, start_line: start_line, total_lines: total_lines, num_lines: num_lines} =
      result

    cond do
      # Empty file case
      total_lines == 0 ->
        "File: #{file_path}\nWarning: File exists but has empty contents.\n"

      # Normal case with content
      true ->
        # Format: "line_number|content"
        numbered_lines =
          lines
          |> Enum.with_index(start_line)
          |> Enum.map(fn {line, num} -> "#{num}|#{line}" end)
          |> Enum.join("\n")

        # Add header metadata for context
        header =
          "File: #{file_path}\nLines: #{num_lines}-#{start_line + num_lines - 1} of #{total_lines}\n\n"

        header <> numbered_lines
    end
  end

  # Formats glob results with metadata
  defp format_glob_result(paths, total_count, truncated) do
    count = length(paths)

    truncated_str = if truncated, do: " (truncated)", else: ""

    header = "Found: #{count} of #{total_count} files#{truncated_str}\n"

    paths_str = Enum.join(paths, "\n")

    header <> "\n" <> paths_str
  end

end
