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
  alias EvoDashWeb.ProjectsLive.ProjectFlow
  import Phoenix.LiveView, only: [put_flash: 3]

  require Logger

  @doc """
  Loads available model profiles from the resolved config and selects the
  default (first) profile. Returns `{profiles, selected_id}`. If no profiles
  are configured, returns `{[], nil}`.

  When a model-selection script is configured
  (`EvoGit.CustomAgents.ModelSelector.enabled?/0`), the default selection is
  the `""` sentinel — the task form renders "Auto (by rules)" and threads
  neither `:model_id` nor `:model_id_locked`, so the runtime script decides
  the model.

  Local-node convenience — delegates to `load_model_profiles/1` with
  `node()`.
  """
  def load_model_profiles do
    load_model_profiles(node())
  end

  @doc """
  Node-aware variant of `load_model_profiles/0`: resolves the model profiles
  from the config of the node being viewed — the node that will actually run
  the launched task.

  - **Local node**: keeps the existing `Config.resolve()` path with the
    `:memo_config_resolve` Process-dict memo (set in `ProjectsLive.mount/3`).
    The memo is LOCAL-only — it is never consulted for remote nodes.
  - **Remote node**: resolves the config via
    `EvoDash.NodeContext.get_resolved_config/1` (the remote daemon's own
    config.toml, atom-keyed — the same shape `Schema.model_profiles/1` and
    `Schema.default_model_profile/1` operate on) and derives the
    model-selection-script state from the remote node's own `agents.toml` via
    `EvoDash.NodeContext.list_custom_agents/1`. On RPC failure degrades to
    `{[], nil}` — never crashes the page (mirrors the degraded
    `load_custom_agents/1` behavior).
  """
  def load_model_profiles(nil), do: load_model_profiles(node())

  def load_model_profiles(node) do
    if node == node() do
      config = Process.get(:memo_config_resolve) || Config.resolve()

      load_model_profiles_from_config(
        config,
        EvoGit.CustomAgents.ModelSelector.enabled?()
      )
    else
      case NodeContext.get_resolved_config(node) do
        {:ok, config} ->
          load_model_profiles_from_config(config, remote_model_selection_enabled?(node))

        {:error, _reason} ->
          {[], nil}
      end
    end
  end

  @doc """
  Pure selection logic shared by the local and remote paths of
  `load_model_profiles/1`: given a resolved config map (the shape returned by
  `EvoGit.Config.resolve/0`, e.g. `%{llm: %{models: [...]}}`) and whether the
  node's model-selection script is enabled, returns `{profiles, selected_id}`.

  `selected_id` is the `""` sentinel ("Auto (by rules)") when the script is
  enabled, else the first profile's id, or `nil` when no profiles exist.
  Exposed for unit testing the node-aware selection logic with an injected
  config map (remote RPC results cannot be injected in tests).
  """
  def load_model_profiles_from_config(config, model_selection_enabled)
      when is_map(config) and is_boolean(model_selection_enabled) do
    profiles = Schema.model_profiles(config)

    selected_id =
      if model_selection_enabled do
        ""
      else
        case Schema.default_model_profile(config) do
          {:ok, profile} -> Map.get(profile, :id)
          {:error, :not_found} -> nil
        end
      end

    {profiles, selected_id}
  end

  # Whether the node being viewed has a model-selection script configured.
  # Node-aware: reads the node's own agents.toml via EvoDash.NodeContext
  # (which degrades to no-script on transport failure). Mirrors the
  # `EvoGit.CustomAgents.ModelSelector.enabled?/0` semantics used on the
  # local node — a configured-but-broken script still counts as enabled.
  defp remote_model_selection_enabled?(node) do
    case NodeContext.list_custom_agents(node) do
      {:ok, %{model_selection_script: script}} -> is_binary(script) and script != ""
      _ -> false
    end
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
  node suggestions come from the shared `EvoGit.PathSuggestions.suggest/1` —
  the same module the remote daemon runs — so local and remote autocomplete
  behave identically.

  The recents filter is also node-aware: recents must pass
  `ProjectFlow.absolute_path_for_node?/2`, which keeps the local
  `EvoGit.Platform.absolute_path?/1` semantics for the local node and accepts
  POSIX- or Windows-absolute paths for remote nodes (so remote recents are not
  dropped when the dashboard runs on a different OS). Recents additionally
  match the typed value as a case-insensitive SUBSTRING of the full path
  (covers the basename and multi-segment queries like `src/proj`) — filesystem
  entries keep prefix-match semantics.
  """
  def path_suggestions(node, value, recent_projects) do
    recents =
      recent_projects
      |> Enum.map(& &1.path)
      |> Enum.filter(
        &(is_binary(&1) and
            EvoDashWeb.ProjectsLive.ProjectFlow.absolute_path_for_node?(node, &1) and
            matches_substring?(&1, value))
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

  # Recents match the typed value as a case-insensitive SUBSTRING of the full
  # path — a recent "/home/test/sources/project" surfaces when the user types
  # "proj" (an infix) or "test/sources" (a multi-segment query), not just when
  # the whole path happens to start with the query. Empty/nil values match all
  # recents. (Filesystem suggestions keep prefix semantics — see
  # `EvoGit.PathSuggestions.suggest/1`.)
  defp matches_substring?(_path, value) when value == "" or is_nil(value), do: true

  defp matches_substring?(path, value) do
    String.contains?(String.downcase(path), String.downcase(value))
  end

  # Local filesystem suggestions delegate to the shared
  # `EvoGit.PathSuggestions.suggest/1` — the single source of truth the remote
  # daemon branch (`EvoDash.NodeContext.list_path_suggestions/2`) already uses,
  # so local and remote autocomplete behave identically. It preserves the old
  # normalize_project_path-gated semantics (absolute or genuinely
  # tilde-expandable input only; relative input like bare names, `~foo`,
  # off-Windows `~\x` → `[]`; no `File.cwd!()`-anchored fallback) and fixes two
  # divergences of the old local port: the trailing-separator check runs on the
  # RAW value because `Path.expand/1` strips trailing separators
  # (`Path.expand("/tmp/foo/") == "/tmp/foo"`), so typing `<dir>/` lists the
  # directory's contents immediately; and bare `~` / `~/` list the home
  # directory's own entries.
  defp filesystem_suggestions(value) do
    EvoGit.PathSuggestions.suggest(value)
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
  the local variant. When remote, extracts foreign repos from the already-parsed
  config as RAW structs (no local `Path.expand` — remote POSIX/Windows roots
  must not be rewritten by the dashboard's OS).
  """
  def load_foreign_repos(node, repo_path, config) do
    if node == node() do
      load_foreign_repos(repo_path, config)
    else
      # Remote: extract from the already-parsed config (same logic as the
      # local /2 variant) but construct RAW structs — `ForeignRepo.new/3`
      # runs `Path.expand/1` against the DASHBOARD's OS and would mangle
      # remote POSIX/Windows paths.
      repos = extract_foreign_repos(node, config)

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

  defp extract_foreign_repos(config) do
    extract_foreign_repos(node(), config)
  end

  defp extract_foreign_repos(_node, nil), do: []

  defp extract_foreign_repos(node, config) when is_map(config) do
    case config do
      %{"foreign_repos" => repos} when is_map(repos) ->
        repos
        |> Enum.flat_map(fn {id_str, cfg} ->
          case build_foreign_repo(node, id_str, cfg) do
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

  # Node-aware foreign-repo builder: the LOCAL node keeps `ForeignRepo.new/3`
  # (exact current semantics, incl. its internal `Path.expand/1`); a REMOTE
  # node builds a RAW struct via `ProjectFlow.build_foreign_repo/4` so remote
  # POSIX/Windows roots are never expanded against the dashboard's OS.
  defp build_foreign_repo(node, id_str, config) when is_map(config) do
    case Map.fetch(config, "path") do
      {:ok, path} ->
        description = Map.get(config, "description")
        {:ok, ProjectFlow.build_foreign_repo(node, id_str, path, description: description)}

      :error ->
        {:error, "missing required 'path' key"}
    end
  end

  defp build_foreign_repo(_node, _id_str, _config) do
    {:error, "invalid config (expected a TOML table)"}
  end
end
