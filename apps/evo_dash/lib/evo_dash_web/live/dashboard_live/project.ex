defmodule EvoDashWeb.DashboardLive.Project do
  @moduledoc """
  Project-related helpers for the dashboard LiveView.

  Functions for loading model profiles, detecting task mode, path suggestions,
  project configuration, foreign repos, flash messages, and task notifications.
  """

  alias EvoGit.Config
  alias EvoGit.Config.Schema
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.ProjectConfig
  import Phoenix.LiveView, only: [put_flash: 3]

  @doc """
  Loads available model profiles from the resolved config and selects the
  default (first) profile. Returns `{profiles, selected_id}`. If no profiles
  are configured, returns `{[], nil}`.
  """
  def load_model_profiles do
    config = Config.resolve()
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
  Returns path suggestions for the file-system picker based on the input value.
  """
  def path_suggestions(value) when value == "" or is_nil(value), do: []

  def path_suggestions(value) do
    expanded = Path.expand(value)

    {dir, prefix} =
      cond do
        String.ends_with?(expanded, "/") or String.ends_with?(expanded, "\\") ->
          {expanded, ""}

        String.contains?(expanded, "/") or String.contains?(expanded, "\\") ->
          dir = Path.dirname(expanded)
          base = Path.basename(expanded)
          {dir, base}

        true ->
          {File.cwd!(), expanded}
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

  @doc """
  Loads the project configuration from a `genesis.toml` file in the project root.
  Returns `{config, worktree_script, commands}`.
  """
  def load_project_config(project_root) do
    config = ProjectConfig.read(project_root)

    worktree_script =
      case config do
        %{"worktree" => %{"script" => script}} when is_binary(script) -> script
        _ -> nil
      end

    commands = ProjectConfig.commands(project_root)

    {config, worktree_script, commands}
  end

  @doc """
  Loads foreign repos from the project's genesis.toml configuration.
  Returns a sorted list of `ForeignRepo` structs.
  """
  def load_foreign_repos(repo_path) do
    repos = ProjectConfig.foreign_repos(repo_path)

    Enum.sort_by(repos, fn repo ->
      {if(ForeignRepo.primary?(repo.id), do: 0, else: 1), repo.id}
    end)
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
end
