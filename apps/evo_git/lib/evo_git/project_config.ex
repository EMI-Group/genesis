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

  @top_level_comment """
  # genesis.toml — EvoGit project configuration file.
  # This file controls per-project settings for EvoGit agents, including worktree
  # initialization scripts, foreign repository references, and dashboard commands.
  # EvoGit agents read this file automatically; most users do not need to edit it.
  """

  @worktree_comment """
  # ─── Worktree Init Script ───────────────────────────────────────────────────
  # This script runs automatically after each new git worktree is created. It
  # copies dependencies and build artifacts from the source repo into the new
  # worktree so builds start with a warm cache (avoiding re-download/recompile).
  #
  # Environment variables available to the script:
  #   SOURCE_REPO_PATH      — main repository checkout (where genesis.toml lives)
  #   SOURCE_WORKTREE_PATH  — parent agent's worktree path
  #   TARGET_WORKTREE_PATH  — newly created worktree (copy destination)
  #
  # WARNING: Do NOT modify or remove this section unless you know what you are
  # doing. EvoGit manages it automatically based on the build system selected
  # during project creation. Removing it will cause every new worktree to build
  # from scratch (much slower).
  """

  @doc """
  Reads and parses `genesis.toml` from the given repo root.
  Falls back to the legacy `evogit.toml` if `genesis.toml` is not found.
  Returns a map of the parsed config, or nil if no config file exists.
  Logs a warning if the file exists but cannot be parsed.
  """
  @spec read(String.t()) :: map() | nil
  def read(repo_root) when is_binary(repo_root) do
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
    EvoGit.Config.read_toml_file(path, nil, description: "project config")
  end

  @doc """
  Returns the worktree init script path from the project config, or nil if not configured.

  When `os` is provided, resolves OS-specific variants first:
  `script.<os>` → `script` (fallback) → nil.

  When called without `os`, uses `Platform.os/0` for automatic OS detection.
  """
  @spec worktree_script(String.t()) :: String.t() | nil
  def worktree_script(repo_root) when is_binary(repo_root) do
    worktree_script(repo_root, EvoGit.Platform.os())
  end

  @spec worktree_script(String.t(), atom()) :: String.t() | nil
  def worktree_script(repo_root, os) when is_binary(repo_root) and is_atom(os) do
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

  The scripts are written as OS-specific variants under `[worktree]`:
  `script.linux`, `script.macos`, and `script.windows`, each as a TOML
  multi-line literal string (`'''`). They are re-readable by `worktree_script/2`.

  - If `genesis.toml` does not exist, it is created with a top-level comment and
    an explanatory worktree comment block.
  - If it exists, all other sections/keys are preserved; only the `[worktree]`
    script lines are added or updated. Existing `script` / `script.<os>` keys
    under `[worktree]` are removed so the OS-variant form takes precedence.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Note on `'''` escaping

  A TOML multi-line literal string does NOT allow embedding `'''` inside. If the
  script content contains `'''`, encoding falls back to `TomlElixir`'s standard
  escaped-string form which handles it correctly.
  """
  @spec write_worktree_script(String.t(), %{
          linux: String.t(),
          macos: String.t(),
          windows: String.t()
        }) :: :ok | {:error, term()}
  def write_worktree_script(
        repo_root,
        %{linux: linux_script, macos: macos_script, windows: windows_script}
      )
      when is_binary(repo_root) and is_binary(linux_script) and is_binary(macos_script) and
             is_binary(windows_script) do
    path = Path.join(repo_root, @config_filename)

    script_lines = [
      "script.linux = #{encode_multiline_literal_string(linux_script)}",
      "script.macos = #{encode_multiline_literal_string(macos_script)}",
      "script.windows = #{encode_multiline_literal_string(windows_script)}"
    ]

    result =
      with {:ok, existing} <- read_existing(path) do
        contents = build_updated_contents(existing, script_lines)
        File.write(path, contents)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Reads existing genesis.toml contents, returning "" if missing.
  defp read_existing(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  # Builds the full updated genesis.toml contents from existing content + the new script lines.
  # Preserves all non-worktree content and non-script worktree keys.
  defp build_updated_contents("", script_lines) do
    worktree_block =
      String.trim(@worktree_comment) <>
        "\n\n[worktree]\n" <> Enum.join(script_lines, "\n") <> "\n"

    String.trim(@top_level_comment) <> "\n\n" <> worktree_block
  end

  defp build_updated_contents(existing, script_lines) do
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

        appended =
          String.trim_trailing(existing) <>
            separator <>
            "\n" <>
            worktree_comment_with_newlines() <>
            "[worktree]\n" <> Enum.join(script_lines, "\n") <> "\n"

        maybe_add_top_level_comment(appended)

      worktree_end >= length(lines) ->
        # Section found and runs to EOF.
        result = update_worktree_section(lines, worktree_start, script_lines)
        to_binary_with_top_level_comment(result)

      true ->
        # Section is bounded by a following section header at worktree_end.
        result = update_worktree_section(lines, worktree_start, script_lines, worktree_end)
        to_binary_with_top_level_comment(result)
    end
  end

  # Returns the worktree comment block as a string of lines with trailing newlines.
  defp worktree_comment_with_newlines do
    String.trim(@worktree_comment)
    |> String.split("\n")
    |> Enum.map_join(fn line -> line <> "\n" end)
  end

  # Joins a list of lines and ensures the top-level comment is present.
  defp to_binary_with_top_level_comment(lines) when is_list(lines) do
    joined = Enum.join(lines, "\n") <> "\n"
    maybe_add_top_level_comment(joined)
  end

  # Adds the top-level comment to the beginning of the contents if it is not
  # already present.
  defp maybe_add_top_level_comment(contents) do
    comment_first_line = comment_first_line(@top_level_comment)

    if String.starts_with?(String.trim_leading(contents), comment_first_line) do
      contents
    else
      String.trim(@top_level_comment) <> "\n\n" <> String.trim_leading(contents)
    end
  end

  # Returns the first non-empty line of a comment string.
  defp comment_first_line(comment) do
    comment
    |> String.trim()
    |> String.split("\n")
    |> List.first()
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
  # Keeps all non-script key=value lines under [worktree], then appends the new script lines.
  defp update_worktree_section(lines, start_idx, script_lines) do
    before = Enum.take(lines, start_idx)
    section_lines = Enum.drop(lines, start_idx + 1)

    kept = filter_section_keys(section_lines)

    # Section extends to EOF, so nothing trails it.
    before ++ ["[worktree]"] ++ kept ++ script_lines
  end

  # Rebuilds the worktree section that is bounded by a following section header at end_idx.
  defp update_worktree_section(lines, start_idx, script_lines, end_idx) do
    before = Enum.take(lines, start_idx)
    section_lines = Enum.slice(lines, (start_idx + 1)..(end_idx - 1)//1)
    rest = Enum.drop(lines, end_idx)

    kept = filter_section_keys(section_lines)

    before ++ ["[worktree]"] ++ kept ++ script_lines ++ rest
  end

  # From a list of lines belonging to one TOML section (already stripped of its header),
  # keep key=value lines up to the first sub-section header, dropping `script` keys
  # (so the new string-form `script` takes precedence) and blank lines.
  #
  # Handles multi-line literal strings ('''...'''): when a script line opens a
  # multi-line literal, all subsequent lines up to and including the closing '''
  # delimiter are dropped.
  defp filter_section_keys(section_lines) do
    {kept_rev, _} =
      Enum.reduce_while(section_lines, {[], false}, fn line, {acc, in_multiline} ->
        trimmed = String.trim(line)

        cond do
          # Currently inside a multi-line literal string — skip until closing '''.
          in_multiline ->
            if trimmed == "'''" do
              {:cont, {acc, false}}
            else
              {:cont, {acc, true}}
            end

          # Stop at next section header (when not inside a multi-line literal).
          Regex.match?(~r/^\[[^\]]/, trimmed) ->
            {:halt, {acc, false}}

          # Line is a script.* key — drop it.  If it opens a multi-line literal
          # string (one ''' without a closing ''' on the same line), enter skip
          # mode so we also drop the literal body and its closing delimiter.
          String.starts_with?(trimmed, "script") and
              Regex.match?(~r/^script[.\s=]/, trimmed) ->
            if String.contains?(trimmed, "'''") do
              parts = String.split(trimmed, "'''")

              if length(parts) >= 3 do
                # Opening and closing ''' on same line — single-line entry.
                {:cont, {acc, false}}
              else
                # Only opening ''' — enter multi-line skip mode.
                {:cont, {acc, true}}
              end
            else
              # Single-line script entry without ''' (e.g. script = "value").
              {:cont, {acc, false}}
            end

          # Blank line — drop.
          trimmed == "" ->
            {:cont, {acc, false}}

          # Regular non-script line — keep.
          true ->
            {:cont, {[line | acc], false}}
        end
      end)

    Enum.reverse(kept_rev)
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
  def foreign_repos(repo_root) when is_binary(repo_root) do
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
  def commands(repo_root) when is_binary(repo_root) do
    case read(repo_root) do
      %{"commands" => cmds} when is_map(cmds) ->
        cmds
        |> Enum.filter(fn {_k, v} -> is_binary(v) end)
        |> Map.new()

      _ ->
        %{}
    end
  end
end
