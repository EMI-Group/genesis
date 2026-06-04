defmodule EvoGit.ProjectConfig do
  @moduledoc """
  Reads and parses the `evogit.toml` project configuration file from the repo root.

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

  @config_filename "evogit.toml"

  @doc """
  Reads and parses the evogit.toml from the given repo root.
  Returns a map of the parsed config, or nil if no config file exists.
  Logs a warning if the file exists but cannot be parsed.
  """
  @spec read(String.t()) :: map() | nil
  def read(repo_root) do
    path = Path.join(repo_root, @config_filename)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, contents} ->
          parse_toml(contents, path)

        {:error, reason} ->
          Logger.warning("Failed to read #{path}: #{inspect(reason)}")
          nil
      end
    else
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
  Reads foreign repo configurations from evogit.toml.

  Returns a list of `EvoGit.Core.ForeignRepo` structs, or an empty list if none configured.
  Each entry under `[foreign_repos]` is a table with:

  - `path` (required) - absolute path to the foreign repo
  - `name` (optional) - human-readable name
  """
  @spec foreign_repos(String.t()) :: [EvoGit.Core.ForeignRepo.t()]
  def foreign_repos(repo_root) do
    case read(repo_root) do
      %{"foreign_repos" => repos} when is_map(repos) ->
        Enum.map(repos, fn {id_str, config} ->
          id = String.to_atom(id_str)
          path = Map.fetch!(config, "path")
          name = Map.get(config, "name")
          ForeignRepo.new(id, path, name: name)
        end)

      _ ->
        []
    end
  rescue
    e ->
      Logger.warning("Failed to parse foreign_repos from evogit.toml: #{inspect(e)}")
      []
  end

  @doc """
  Reads user-defined command shortcuts from the `[commands]` section of evogit.toml.

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
