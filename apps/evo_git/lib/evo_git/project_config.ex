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
