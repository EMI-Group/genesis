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
  Returns a map of the parsed config, or nil if no config file exists.
  Logs a warning if the file exists but cannot be parsed.
  """
  @spec read(String.t()) :: map() | nil
  def read(repo_root) when is_binary(repo_root) do
    path = Path.join(repo_root, @config_filename)
    if File.exists?(path), do: read_config_file(path), else: nil
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
    script keys are added or updated. Existing `script` / `script.<os>` keys
    under `[worktree]` are removed so the OS-variant form takes precedence.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Implementation: parse-modify-serialize

  Rather than performing fragile line-by-line string manipulation on the raw
  file, this function uses a parse-modify-serialize approach:
  1. Read the existing TOML as a map (via `read/1` → `TomlElixir.decode/1`).
  2. Update `worktree.script` to the new OS-variant map, preserving any
     non-script keys under `[worktree]` and all other sections.
  3. Serialize back to TOML with custom formatting for the `[worktree]` section
     (multi-line literal strings) and `TomlElixir.encode/1` for the rest.

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

    # 1. Parse existing config (nil if no file → start from empty map).
    existing = read(repo_root) || %{}

    # 2. Modify: set worktree.script to the OS-variant map, preserving any
    #    non-script keys that were already under [worktree].
    existing_worktree = Map.get(existing, "worktree", %{}) |> Map.delete("script")
    updated_worktree = Map.put(existing_worktree, "script", %{
      "linux" => linux_script,
      "macos" => macos_script,
      "windows" => windows_script
    })
    updated_config = Map.put(existing, "worktree", updated_worktree)

    # 3. Serialize with custom formatting and write.
    contents = serialize_config(updated_config)
    File.write(path, contents)
  end

  # Serializes a parsed config map back into a genesis.toml string.
  #
  # The `[worktree]` section is manually formatted with `'''` multi-line literal
  # strings (via `encode_multiline_literal_string/1`) because worktree scripts
  # must be readable. All other sections are serialized with `TomlElixir.encode/1`.
  # The top-level comment and worktree comment are regenerated from module
  # attributes (TOML parsers discard comments, but we control the format).
  defp serialize_config(config) do
    worktree = Map.get(config, "worktree", %{})
    script = Map.get(worktree, "script", %{})
    non_script_worktree = Map.delete(worktree, "script")
    remaining = Map.drop(config, ["worktree"])

    # Build the [worktree] section header.
    worktree_header =
      "#{String.trim(@worktree_comment)}\n\n[worktree]\n"

    # Non-script worktree keys (e.g. timeout, verbose) go before the script keys.
    non_script_lines =
      if map_size(non_script_worktree) == 0 do
        ""
      else
        case TomlElixir.encode(%{"worktree" => non_script_worktree}) do
          {:ok, encoded} ->
            # Strip the leading "\n[worktree]\n" prefix that TomlElixir adds.
            encoded
            |> String.trim_leading("\n")
            |> String.trim_leading("[worktree]\n")
            |> String.trim_trailing("\n")

          {:error, _reason} ->
            ""
        end
      end

    # Script keys as multi-line literal strings.
    script_lines =
      [
        {"linux", "script.linux"},
        {"macos", "script.macos"},
        {"windows", "script.windows"}
      ]
      |> Enum.map(fn {key, label} ->
        content = Map.get(script, key, "")
        "#{label} = #{encode_multiline_literal_string(content)}"
      end)

    # Assemble the worktree section.
    worktree_section =
      case non_script_lines do
        "" ->
          worktree_header <> Enum.join(script_lines, "\n") <> "\n"

        _ ->
          worktree_header <> non_script_lines <> "\n" <> Enum.join(script_lines, "\n") <> "\n"
      end

    # Remaining sections (commands, foreign_repos, etc.) via TomlElixir.
    remaining_section =
      if map_size(remaining) == 0 do
        ""
      else
        case TomlElixir.encode(remaining) do
          {:ok, encoded} ->
            # TomlElixir may prepend a newline; trim it so we control spacing.
            String.trim_leading(encoded, "\n")

          {:error, _reason} ->
            ""
        end
      end

    # Assemble the full file: top-level comment + worktree + remaining.
    top = "#{String.trim(@top_level_comment)}\n\n"
    top <> worktree_section <> remaining_section
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
