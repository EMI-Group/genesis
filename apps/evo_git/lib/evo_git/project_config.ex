defmodule EvoGit.ProjectConfig do
  @moduledoc """
  Reads and parses the `evogit.toml` project configuration file from the repo root.

  Currently supports:

  - `worktree.script` — A script path (relative to repo root) that runs immediately
    after worktree creation and before agent execution. The script receives two
    environment variables:

    - `SOURCE_REPO_PATH` — The path to the main repository checkout
    - `TARGET_WORKTREE_PATH` — The path to the newly created worktree
  """

  require Logger

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
  The path is relative to the repo root.
  """
  @spec worktree_script(String.t()) :: String.t() | nil
  def worktree_script(repo_root) do
    case read(repo_root) do
      %{"worktree" => %{"script" => script}} when is_binary(script) -> script
      _ -> nil
    end
  end

  defp parse_toml(contents, path) do
    case Toml.decode(contents) do
      {:ok, config} ->
        config

      {:error, reason} ->
        Logger.warning("Failed to parse #{path}: #{inspect(reason)}")
        nil
    end
  end
end
