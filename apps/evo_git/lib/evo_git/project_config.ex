defmodule EvoGit.ProjectConfig do
  @moduledoc """
  Reads and parses the `genesis.toml` project configuration file from the repo root.

  Currently supports:

  - `worktree.script` — A script path (relative to repo root) that runs immediately
    after worktree creation and before agent execution. The script receives three
    environment variables:

    - `SOURCE_REPO_PATH` — The path to the main repository checkout
    - `SOURCE_WORKTREE_PATH` — The parent agent's worktree path (or `SOURCE_REPO_PATH` for top-level agents)
    - `TARGET_WORKTREE_PATH` — The path to the newly created worktree

    Supports OS-specific variants:
    ```toml
    [worktree]
    script.linux = "scripts/setup_linux.sh"
    script.macos = "scripts/setup_macos.sh"
    script.windows = "scripts/setup_windows.ps1"
    # OR fallback:
    script = "scripts/setup.sh"
    ```

    Resolution order: `script.<current_os>` → `script` (fallback). If neither exists, returns nil.

  - `foreign_repos` — A map of foreign repository references. Each entry is a
    TOML table with `path` (required) and `name` (optional) keys.

  - `commands` — User-defined command shortcuts for the dashboard. Each entry
    is a name-command pair:
    ```toml
    [commands]
    dev = "npm run dev"
    test = "mix test"
    build = "mix compile"
    ```
  """

  require Logger

  alias EvoGit.Core.ForeignRepo

  @config_filename "genesis.toml"
  @legacy_config_filename "evogit.toml"

  @doc """
  Reads and parses `genesis.toml` from the given repo root.
  Falls back to the legacy `evogit.toml` if `genesis.toml` is not found.
  Returns a map of the parsed config, or nil if no config file exists.
  Logs a warning if the file exists but cannot be parsed.
  """
  @spec read(String.t()) :: map() | nil
  def read(repo_root) do
    path = Path.join(repo_root, @config_filename)

    if File.exists?(path) do
      read_config_file(path)
    else
      legacy_path = Path.join(repo_root, @legacy_config_filename)

      if File.exists?(legacy_path) do
        read_config_file(legacy_path)
      else
        nil
      end
    end
  end

  defp read_config_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        parse_toml(contents, path)

      {:error, reason} ->
        Logger.warning("Failed to read #{path}: #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Returns the worktree init script path from the project config, or nil if not configured.

  When `os` is provided, resolves OS-specific variants first:
  `script.<os>` → `script` (fallback) → nil.

  When called without `os`, uses `Platform.os/0` for automatic OS detection.
  """
  @spec worktree_script(String.t()) :: String.t() | nil
  def worktree_script(repo_root) do
    worktree_script(repo_root, EvoGit.Platform.os())
  end

  @spec worktree_script(String.t(), atom()) :: String.t() | nil
  def worktree_script(repo_root, os) do
    os_key = Atom.to_string(os)

    case read(repo_root) do
      %{"worktree" => %{"script" => script}} when is_map(script) ->
        Map.get(script, os_key)

      %{"worktree" => %{"script" => script}} when is_binary(script) ->
        script

      _ ->
        nil
    end
  end

  @doc """
  Writes (or merges) the worktree init script content into `genesis.toml` at `repo_root`.

  The script is written as inline CONTENT under `[worktree].script` using a TOML
  multi-line literal string (`'''`). It is therefore re-readable by `worktree_script/2`.

  - If `genesis.toml` does not exist, it is created.
  - If it exists, all other sections/keys are preserved; only `[worktree].script` is
    added or updated. Existing `script.<os>` variants under `[worktree]` are removed so
    the string form takes precedence (TOML cannot hold both forms).

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Note on `'''` escaping

  A TOML multi-line literal string does NOT allow embedding `'''` inside. If the script
  content contains `'''`, encoding falls back to `TomlElixir`'s standard escaped-string form
  which handles it correctly.
  """
  @spec write_worktree_script(String.t(), String.t()) :: :ok | {:error, term()}
  def write_worktree_script(repo_root, script_content)
      when is_binary(repo_root) and is_binary(script_content) do
    path = Path.join(repo_root, @config_filename)

    toml_value = encode_multiline_literal_string(script_content)
    script_line = "script = #{toml_value}"

    result =
      with {:ok, existing} <- read_existing(path) do
        contents = build_updated_contents(existing, script_line) |> to_binary()
        File.write(path, contents)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Normalizes build_updated_contents output to a single binary string.
  # The merge path returns a list of lines; the create/append paths return a binary.
  defp to_binary(lines) when is_list(lines), do: Enum.join(lines, "\n") <> "\n"
  defp to_binary(binary) when is_binary(binary), do: binary

  # Reads existing genesis.toml contents, returning "" if missing.
  defp read_existing(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  # Builds the full updated genesis.toml contents from existing content + the new script line.
  # Preserves all non-worktree content and non-script worktree keys.
  defp build_updated_contents("", script_line) do
    "[worktree]\n#{script_line}\n"
  end

  defp build_updated_contents(existing, script_line) do
    lines = String.split(existing, "\n")

    # Scan the existing content to locate the [worktree] section boundaries:
    #   - `worktree_start` — index of the `[worktree]` line (nil if absent)
    #   - `worktree_end`   — index of the line that ENDS the section (next section
    #     header, or length(lines) if the section runs to EOF)
    {worktree_start, worktree_end} = locate_worktree_section(lines)

    cond do
      is_nil(worktree_start) ->
        # No [worktree] section — append one (preserving all existing content).
        separator =
          if existing != "" and not String.ends_with?(existing, "\n"), do: "\n", else: ""

        String.trim_trailing(existing) <> separator <> "\n[worktree]\n#{script_line}\n"

      worktree_end >= length(lines) ->
        # Section found and runs to EOF.
        update_worktree_section(lines, worktree_start, script_line)

      true ->
        # Section is bounded by a following section header at worktree_end.
        update_worktree_section(lines, worktree_start, script_line, worktree_end)
    end
  end

  # Returns {worktree_start_index, worktree_end_index}.
  # worktree_start is nil if there is no [worktree] section.
  # worktree_end is the index of the first line AFTER the section (next header, or
  # a value >= length(lines) if the section extends to EOF).
  defp locate_worktree_section(lines) do
    indexed = Enum.with_index(lines)

    start_idx =
      Enum.find_value(indexed, fn {line, idx} ->
        if Regex.match?(~r/^\[worktree\]\s*$/, String.trim(line)), do: idx
      end)

    case start_idx do
      nil ->
        {nil, 0}

      ^start_idx ->
        end_idx =
          indexed
          |> Enum.drop(start_idx + 1)
          |> Enum.find_value(length(lines), fn {line, idx} ->
            if Regex.match?(~r/^\[[^\]]/, String.trim(line)), do: idx
          end)

        {start_idx, end_idx}
    end
  end

  # Rebuilds the worktree section in-place (section extends to EOF).
  # Keeps all non-script key=value lines under [worktree], then appends the new script line.
  defp update_worktree_section(lines, start_idx, script_line) do
    before = Enum.take(lines, start_idx)
    section_lines = Enum.drop(lines, start_idx + 1)

    kept = filter_section_keys(section_lines)

    # Section extends to EOF, so nothing trails it.
    before ++ ["[worktree]"] ++ kept ++ [script_line]
  end

  # Rebuilds the worktree section that is bounded by a following section header at end_idx.
  defp update_worktree_section(lines, start_idx, script_line, end_idx) do
    before = Enum.take(lines, start_idx)
    section_lines = Enum.slice(lines, (start_idx + 1)..(end_idx - 1)//1)
    rest = Enum.drop(lines, end_idx)

    kept = filter_section_keys(section_lines)

    before ++ ["[worktree]"] ++ kept ++ [script_line] ++ rest
  end

  # From a list of lines belonging to one TOML section (already stripped of its header),
  # keep key=value lines up to the first sub-section header, dropping `script` keys
  # (so the new string-form `script` takes precedence) and blank lines.
  defp filter_section_keys(section_lines) do
    section_lines
    |> Enum.take_while(fn line -> not Regex.match?(~r/^\[[^\]]/, String.trim(line)) end)
    |> Enum.reject(fn line ->
      trimmed = String.trim(line)
      # Drop existing script.* keys so the string form takes precedence.
      String.starts_with?(trimmed, "script") and
        Regex.match?(~r/^script[.\s=]/, trimmed)
    end)
    |> Enum.reject(fn line -> line == "" end)
  end

  # Encodes a string as a TOML multi-line literal string ('''...''').
  # Falls back to TomlElixir's standard (escaped) encoding when the content contains
  # `'''`, since a multi-line literal string cannot embed that delimiter.
  defp encode_multiline_literal_string(content) do
    if String.contains?(content, "'''") do
      # Fallback: let TomlElixir escape the string safely.
      with {:ok, toml} <- TomlElixir.encode(%{"script" => content}) do
        # The encoder writes `script = "..."`; extract just the value.
        toml
        |> String.trim()
        |> String.trim_leading("script = ")
      else
        _ -> "'''" <> String.replace(content, "'''", "''") <> "'''"
      end
    else
      "'''" <> content <> "'''"
    end
  end

  @doc """
  Reads foreign repo configurations from genesis.toml.

  Returns a list of `EvoGit.Core.ForeignRepo` structs, or an empty list if none configured.
  Each entry under `[foreign_repos]` is a table with:

  - `path` (required) - absolute path to the foreign repo
  - `description` (optional) - human-readable description of the repo
  """
  @spec foreign_repos(String.t()) :: [EvoGit.Core.ForeignRepo.t()]
  def foreign_repos(repo_root) do
    case read(repo_root) do
      %{"foreign_repos" => repos} when is_map(repos) ->
        repos
        |> Enum.flat_map(fn {id_str, config} ->
          case build_foreign_repo(id_str, config) do
            {:ok, repo} ->
              [repo]

            {:error, reason} ->
              Logger.warning("Failed to parse foreign_repos '#{id_str}': #{reason}")
              []
          end
        end)

      _ ->
        []
    end
  end

  defp build_foreign_repo(id_str, config) when is_map(config) do
    case Map.fetch(config, "path") do
      {:ok, path} ->
        description = Map.get(config, "description")
        {:ok, ForeignRepo.new(id_str, path, description: description)}

      :error ->
        {:error, "missing required 'path' key"}
    end
  end

  defp build_foreign_repo(_id_str, _config) do
    {:error, "invalid config (expected a TOML table)"}
  end

  @doc """
  Reads user-defined command shortcuts from the `[commands]` section of genesis.toml.

  Returns a map of `%{name => command_string}`, or an empty map if no commands
  section exists or no config file is present.

  ## Example

      iex> ProjectConfig.commands("/path/to/repo")
      %{"dev" => "npm run dev", "test" => "mix test"}
  """
  @spec commands(String.t()) :: %{String.t() => String.t()}
  def commands(repo_root) do
    case read(repo_root) do
      %{"commands" => cmds} when is_map(cmds) ->
        cmds
        |> Enum.filter(fn {_k, v} -> is_binary(v) end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp parse_toml(contents, path) do
    case TomlElixir.decode(contents) do
      {:ok, config} ->
        config

      {:error, reason} ->
        Logger.warning("Failed to parse #{path}: #{inspect(reason)}")
        nil
    end
  end
end
