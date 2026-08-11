defmodule EvoDashWeb.ProjectsLive.Project do
  @moduledoc """
  Project-related helpers for the dashboard LiveView.

  Functions for loading model profiles, detecting task mode, path suggestions,
  project configuration, foreign repos, flash messages, and task notifications.
  """

  alias EvoGit.Config
  alias EvoGit.Config.Schema
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.ProjectConfig
  alias EvoDash.NodeContext
  import Phoenix.LiveView, only: [put_flash: 3]

  require Logger

  @doc """
  Loads available model profiles from the resolved config and selects the
  default (first) profile. Returns `{profiles, selected_id}`. If no profiles
  are configured, returns `{[], nil}`.
  """
  def load_model_profiles do
    config = Process.get(:memo_config_resolve) || Config.resolve()
    profiles = Schema.model_profiles(config)

    selected_id =
      case Schema.default_model_profile(config) do
        {:ok, profile} -> Map.get(profile, :id)
        {:error, :not_found} -> nil
      end

    {profiles, selected_id}
  end

  @doc """
  Detects the task mode for a given project path.
  Returns one of: `"genesis_new"`, `"genesis_existing"`, `"evolve_simple"`.
  """
  def detect_mode(path) do
    path = Path.expand(path)

    cond do
      new_codebase?(path) -> "genesis_new"
      not File.exists?(Path.join(path, "CONTEXT.md")) -> "genesis_existing"
      true -> "evolve_simple"
    end
  end

  @doc """
  Node-aware variant of `detect_mode/1`. When `node == node()`, delegates to
  the local variant. When remote, uses `NodeContext` for filesystem checks.
  """
  def detect_mode(node, path) do
    if node == node() do
      detect_mode(path)
    else
      cond do
        new_codebase?(node, path) -> "genesis_new"
        not NodeContext.file_exists?(node, Path.join(path, "CONTEXT.md")) -> "genesis_existing"
        true -> "evolve_simple"
      end
    end
  end

  @doc """
  Returns `true` if the given path appears to be a new/empty codebase.
  """
  def new_codebase?(path) do
    files =
      case File.ls(path) do
        {:ok, items} -> items -- [".git", "README.md", ".genesis", ".gitignore"]
        _ -> []
      end

    Enum.empty?(files)
  end

  @doc """
  Node-aware variant of `new_codebase?/1`.
  """
  def new_codebase?(node, path) do
    if node == node() do
      new_codebase?(path)
    else
      files =
        case NodeContext.ls(node, path) do
          {:ok, items} -> items -- [".git", "README.md", ".genesis", ".gitignore"]
          _ -> []
        end

      Enum.empty?(files)
    end
  end

  @doc """
  Returns path suggestions for the file-system picker based on the input value.

  When `recent_projects` (a list of `%EvoGit.RecentProject{}` structs) is
  given, recently opened projects whose path matches the typed value are
  listed FIRST, followed by filesystem suggestions. A path that appears both
  in the recent list and on disk is only listed once (recents win).
  """
  def path_suggestions(value, recent_projects \\ [])

  def path_suggestions(value, recent_projects) do
    path_suggestions(node(), value, recent_projects)
  end

  @doc """
  Node-aware variant of `path_suggestions/2`: resolves suggestions against the
  given node's filesystem. On a remote node (`node != node()`) suggestions come
  from `EvoDash.NodeContext.list_path_suggestions/2` (the remote daemon
  resolves paths against its own filesystem; `[]` on RPC failure). On the local
  node the existing filesystem-suggestion implementation is used unchanged.
  """
  def path_suggestions(node, value, recent_projects) do
    recents =
      recent_projects
      |> Enum.map(& &1.path)
      |> Enum.filter(
        &(is_binary(&1) and EvoGit.Platform.absolute_path?(&1) and matches_prefix?(&1, value))
      )
      |> Enum.take(8)

    suggestions =
      if node == node() do
        filesystem_suggestions(value)
      else
        EvoDash.NodeContext.list_path_suggestions(node, value)
      end

    Enum.uniq(recents ++ suggestions)
  end

  defp matches_prefix?(_path, value) when value == "" or is_nil(value), do: true

  defp matches_prefix?(path, value) do
    String.starts_with?(String.downcase(path), String.downcase(value))
  end

  defp filesystem_suggestions(value) when value == "" or is_nil(value), do: []

  # Suggestions are produced only for absolute or genuinely tilde-expandable
  # input (guaranteed by ProjectFlow.normalize_project_path/1); relative input
  # (bare names, ~foo, off-Windows ~\x) yields []. The old bare-name branch
  # that anchored suggestions at File.cwd!() is gone — File.cwd!()-anchored
  # suggestions for relative input can never be produced.
  defp filesystem_suggestions(value) do
    case EvoDashWeb.ProjectsLive.ProjectFlow.normalize_project_path(value) do
      {:error, _} ->
        []

      {:ok, expanded} ->
        {dir, prefix} =
          cond do
            String.ends_with?(expanded, "/") or String.ends_with?(expanded, "\\") ->
              {expanded, ""}

            true ->
              dir = Path.dirname(expanded)
              base = Path.basename(expanded)
              {dir, base}
          end

        case File.ls(dir) do
          {:ok, entries} ->
            entries
            |> Enum.filter(fn entry ->
              String.starts_with?(String.downcase(entry), String.downcase(prefix))
            end)
            |> Enum.sort_by(fn entry ->
              {not File.dir?(Path.join(dir, entry)), String.downcase(entry)}
            end)
            |> Enum.take(15)
            |> Enum.map(fn entry -> Path.join(dir, entry) end)

          {:error, _} ->
            []
        end
    end
  end

  @doc """
  Loads the project configuration from a `genesis.toml` file in the project root.
  Returns `{config, worktree_script, commands}`.
  """
  def load_project_config(project_root) do
    config = ProjectConfig.read(project_root)
    load_project_config(project_root, config)
  end

  @doc """
  Same as `load_project_config/1` but accepts an already-parsed config map
  (from `ProjectConfig.read/1`) to avoid re-reading the file from disk.
  """
  def load_project_config(_project_root, config) do
    worktree_script =
      case config do
        %{"worktree" => %{"script" => script}} when is_binary(script) -> script
        _ -> nil
      end

    commands =
      case config do
        %{"commands" => cmds} when is_map(cmds) ->
          cmds |> Enum.filter(fn {_k, v} -> is_binary(v) end) |> Map.new()

        _ ->
          %{}
      end

    {config, worktree_script, commands}
  end

  @doc """
  Node-aware variant of `load_project_config/2`. When `node == node()`, delegates to
  the local variant. When remote, uses the config map fetched from the remote node.
  """
  def load_project_config(node, path, config) do
    if node == node() do
      load_project_config(path, config)
    else
      # Remote: config is already parsed from the remote genesis.toml.
      # Use the same extraction logic as the local variant.
      worktree_script =
        case config do
          %{"worktree" => %{"script" => script}} when is_binary(script) -> script
          _ -> nil
        end

      commands =
        case config do
          %{"commands" => cmds} when is_map(cmds) ->
            cmds |> Enum.filter(fn {_k, v} -> is_binary(v) end) |> Map.new()

          _ ->
            %{}
        end

      {config, worktree_script, commands}
    end
  end

  @doc """
  Loads foreign repos from the project's genesis.toml configuration.
  Returns a sorted list of `ForeignRepo` structs.
  """
  def load_foreign_repos(repo_path) do
    config = ProjectConfig.read(repo_path)
    load_foreign_repos(repo_path, config)
  end

  @doc """
  Same as `load_foreign_repos/1` but accepts an already-parsed config map
  (from `ProjectConfig.read/1`) to avoid re-reading the file from disk.
  """
  def load_foreign_repos(_repo_path, config) do
    repos = extract_foreign_repos(config)

    Enum.sort_by(repos, fn repo ->
      {if(ForeignRepo.primary?(repo.id), do: 0, else: 1), repo.id}
    end)
  end

  @doc """
  Node-aware variant of `load_foreign_repos/2`. When `node == node()`, delegates to
  the local variant. When remote, extracts foreign repos from the already-parsed config.
  """
  def load_foreign_repos(node, repo_path, config) do
    if node == node() do
      load_foreign_repos(repo_path, config)
    else
      # Remote: extract from the already-parsed config (same logic as local /2 variant)
      repos = extract_foreign_repos(config)

      Enum.sort_by(repos, fn repo ->
        {if(ForeignRepo.primary?(repo.id), do: 0, else: 1), repo.id}
      end)
    end
  end

  @doc """
  Validates a project name for new project creation.
  Returns `{:ok, trimmed}` or `{:error, :invalid_name}`.
  """
  def validate_project_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:error, :invalid_name}
      String.contains?(trimmed, "/") or String.contains?(trimmed, "\\") -> {:error, :invalid_name}
      true -> {:ok, trimmed}
    end
  end

  @doc """
  Puts a flash info message about the detected mode, but only when the project
  is newly activated (no existing project).
  """
  def maybe_put_flash_mode_info(socket, ""), do: socket

  def maybe_put_flash_mode_info(socket, mode_info) do
    if socket.assigns.active_project_path && socket.assigns.active_project do
      # Already had a project — skip flash on re-activation
      socket
    else
      put_flash(socket, :info, mode_info)
    end
  end

  @doc """
  Returns the notification title and body for a completed/failed task.
  """
  def task_notification_content(task) do
    objective = task.opts[:prompt] || task.opts[:objective] || ""

    case task.result do
      {:ok, %{pr_title: pr_title}} when is_binary(pr_title) and pr_title != "" ->
        {pr_title, objective}

      {:ok, _} ->
        case task.type do
          :genesis -> {"Genesis task completed", objective}
          :evolve -> {"Evolution task completed", objective}
        end

      {:error, reason} ->
        {"Task failed", inspect(reason)}

      {:exit, reason} ->
        {"Task crashed", inspect(reason)}

      _ ->
        {"Task finished", objective}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  defp extract_foreign_repos(nil), do: []

  defp extract_foreign_repos(config) when is_map(config) do
    case config do
      %{"foreign_repos" => repos} when is_map(repos) ->
        repos
        |> Enum.flat_map(fn {id_str, cfg} ->
          case build_foreign_repo(id_str, cfg) do
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
end
