defmodule EvoDashWeb.ProjectsLive.ProjectFlow do
  @moduledoc """
  Event handlers for project creation/opening on the dashboard.

  Extracted from ProjectsLive to keep the main module focused on task
  lifecycle management and state persistence.

  All project-opening paths are node-aware: in a remote context
  (`socket.assigns[:current_node_id] != nil`) directory checks, recent-project
  registration, and recents reload go through `EvoDash.NodeContext` so they run
  on the remote daemon's filesystem/store. In pending contexts `@current_node`
  is still the local BEAM node, where NodeContext delegates to the local
  TaskRegistry/filesystem — the safe degradation path.
  """

  use Gettext, backend: EvoDashWeb.Gettext
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]
  import EvoDashWeb.Helpers, only: [mode_info_message: 1]

  alias EvoGit.TaskRegistry
  alias EvoGit.Core.ForeignRepo
  alias EvoDash.NodeContext
  alias EvoDashWeb.ProjectsLive.Project

  # ───────────────────────────────────────────────────────────────────────────
  # Path normalization
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Normalizes a user-supplied project path for server-side use.

  Returns `{:ok, expanded}` when the trimmed input is genuinely
  tilde-expandable (`~`, `~/...`, and — on Windows only — `~\\...`) or an
  absolute path (Unix `/foo`, Windows `C:\\foo`/`D:/bar`, UNC
  `\\\\server\\share`), with `Path.expand/1` applied to the result.

  Returns `{:error, :blank}` for empty/whitespace input and
  `{:error, :relative}` for anything else: bare names, volume-relative
  (`D:Test`), root-relative (`\\Test`), `~foo`, and `~\\x` off Windows.

  Relative input is REJECTED rather than `Path.expand`-joined against the BEAM
  VM's cwd — on the Windows desktop app that cwd is the Tauri process's
  inherited cwd (typically the install dir), so a cwd-join would silently
  create/register projects in the wrong location.
  """
  @spec normalize_project_path(String.t()) ::
          {:ok, String.t()} | {:error, :blank} | {:error, :relative}
  def normalize_project_path(input) do
    trimmed = String.trim(input)

    cond do
      trimmed == "" ->
        {:error, :blank}

      expandable_tilde?(trimmed) ->
        # Tilde expansion is cwd-independent — safe to expand on any platform.
        {:ok, Path.expand(trimmed)}

      EvoGit.Platform.absolute_path?(trimmed) ->
        {:ok, Path.expand(trimmed)}

      true ->
        {:error, :relative}
    end
  end

  @doc """
  Normalizes a user-supplied project path for use on a REMOTE node.

  The local `normalize_project_path/1` must NOT be applied to remote paths:
  its `Path.expand/1` step runs against the DASHBOARD's OS, not the remote
  node's. A Windows dashboard classifies a POSIX absolute path
  (`/home/user/repo` — `Path.type/1` → `:volumerelative`) as relative, and
  `Path.expand("/home/...")` would rewrite it to a drive-letter path; a POSIX
  dashboard would cwd-join a Windows remote path (`C:\\work\\repo`). This
  function therefore performs NO local `Path.expand` on absolute input:

  - blank → `{:error, :blank}`
  - POSIX absolute (leading `/`) → `{:ok, trimmed}` passed through verbatim
  - Windows-style absolute (drive letter `C:\\`/`D:/` or UNC
    `\\\\server\\share`, via `EvoGit.Platform.absolute_path?/1`) →
    `{:ok, trimmed}` passed through verbatim
  - genuinely tilde-expandable (`~`, `~/...`, `~\\...` — same
    `expandable_tilde?/1` predicate as the local path) → expanded on the
    REMOTE node via the node-aware RPC so the remote user's home is used, not
    the dashboard user's. The expander is injectable via
    `Application.get_env(:evo_dash, :remote_path_expand_runner)` (test seam,
    same pattern as `:merge_check_runner`); RPC failure or a non-binary
    result falls back to the raw input
  - anything else → `{:error, :relative}`
  """
  @spec normalize_remote_project_path(node(), String.t()) ::
          {:ok, String.t()} | {:error, :blank} | {:error, :relative}
  def normalize_remote_project_path(node, input) do
    trimmed = String.trim(input)

    cond do
      trimmed == "" ->
        {:error, :blank}

      expandable_tilde?(trimmed) ->
        # Tilde expansion is cwd-independent but HOME-dependent: expand on the
        # remote node so the remote user's home resolves correctly. The runner
        # is read from app env at call time so tests can inject a fake without
        # a connected node; any failure degrades to the raw input.
        expand_runner =
          Application.get_env(:evo_dash, :remote_path_expand_runner) ||
            (&default_remote_path_expand/2)

        case expand_runner.(node, trimmed) do
          {:ok, expanded} when is_binary(expanded) -> {:ok, expanded}
          _ -> {:ok, trimmed}
        end

      String.starts_with?(trimmed, "/") ->
        # POSIX absolute — pass through verbatim. NO local Path.expand: on a
        # Windows dashboard it would rewrite `/home/...` to `<drive>:\home\...`.
        {:ok, trimmed}

      EvoGit.Platform.absolute_path?(trimmed) ->
        # Windows-style absolute (drive letter or UNC) — pass through verbatim.
        # NO local Path.expand: a POSIX dashboard would cwd-join `C:\work\...`.
        {:ok, trimmed}

      true ->
        {:error, :relative}
    end
  end

  # Default tilde expander for remote paths: runs `Path.expand/1` on the
  # REMOTE node via the node-aware RPC chain so the remote user's home is
  # used. `NodeContext.call_remote/4` returns `{:ok, term} | {:error, term}` —
  # a non-binary result or any failure (e.g. node down) falls back to the raw
  # input, which the caller then uses as-is.
  defp default_remote_path_expand(node, path) do
    case NodeContext.call_remote(node, Path, :expand, [path]) do
      {:ok, expanded} when is_binary(expanded) -> {:ok, expanded}
      _ -> {:ok, path}
    end
  end

  # Only `~`, `~/...`, and (on Windows) `~\\...` are expanded by Path.expand/1
  # without cwd-joining. `~foo` NEVER expands on any platform, and `~\\x` does
  # not expand off Windows — both would be cwd-joined, so they must fall
  # through to the relative branch above.
  defp expandable_tilde?(trimmed) do
    trimmed == "~" or
      String.starts_with?(trimmed, "~/") or
      (EvoGit.Platform.windows?() and String.starts_with?(trimmed, "~\\"))
  end

  @doc """
  Returns true when `path` is an absolute path for the given node.

  On the LOCAL node the existing local-semantics check
  (`EvoGit.Platform.absolute_path?/1`) is used unchanged. On a REMOTE node a
  path is accepted when it is POSIX-absolute (leading `/`) OR Windows-style
  absolute (drive letter / UNC, via `EvoGit.Platform.absolute_path?/1`): the
  remote node's paths must not be judged by the dashboard's host OS — on a
  Windows dashboard `Path.type("/home/user/repo")` is `:volumerelative`,
  which would wrongly drop remote POSIX recents from the palette (and a POSIX
  dashboard would drop remote Windows recents). Non-binary paths are always
  false.
  """
  @spec absolute_path_for_node?(node(), term()) :: boolean()
  def absolute_path_for_node?(node, path) when is_binary(path) do
    if node == node() do
      EvoGit.Platform.absolute_path?(path)
    else
      String.starts_with?(path, "/") or EvoGit.Platform.absolute_path?(path)
    end
  end

  def absolute_path_for_node?(_node, _path), do: false

  # ───────────────────────────────────────────────────────────────────────────
  # Foreign repo construction
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Builds a `%EvoGit.Core.ForeignRepo{}` for the given node.

  On the LOCAL node (`node == nil or node == node()`) delegates to
  `EvoGit.Core.ForeignRepo.new/3` — EXACT local behavior, including its
  internal `Path.expand/1` tilde/relative expansion semantics.

  On a REMOTE node constructs the struct DIRECTLY with the raw `root` and NO
  `Path.expand/1`: `ForeignRepo.new/3`'s expansion runs against the
  DASHBOARD's OS, not the remote node's, so it mangles remote paths (a
  Windows dashboard rewrites `/home/...` to a drive-letter path; a POSIX
  dashboard cwd-joins `D:\\stuff\\repo`). The remote path is stored verbatim.
  """
  @spec build_foreign_repo(node() | nil, String.t(), String.t(), keyword()) ::
          EvoGit.Core.ForeignRepo.t()
  def build_foreign_repo(node, id, path, opts \\ []) do
    if node == nil or node == node() do
      ForeignRepo.new(id, path, opts)
    else
      %ForeignRepo{
        id: id,
        root: path,
        description: Keyword.get(opts, :description)
      }
    end
  end

  # Recent projects offered in the palette must have absolute paths — stale
  # cwd-joined entries (from the pre-fix Path.expand-against-cwd behavior)
  # must never render.
  defp filter_absolute_recent_projects(recent_projects) do
    Enum.filter(recent_projects, &EvoGit.Platform.absolute_path?(&1.path))
  end

  # Node-aware recents filter: local flows keep the strict local-semantics
  # check; remote flows accept POSIX- or Windows-absolute paths so remote
  # recents survive a dashboard running on a different OS.
  defp filter_absolute_recent_projects_for_node(node, recent_projects) do
    Enum.filter(recent_projects, &absolute_path_for_node?(node, &1.path))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Project creation
  # ───────────────────────────────────────────────────────────────────────────

  # Creates (or opens, if it already exists) a project from a single full
  # path submitted by the create-new-project palette form. The parent
  # directory need not exist — `File.mkdir_p/1` creates the whole chain.
  # LOCAL-only: the palette hides "Create New Project" in remote contexts.
  def create_project(socket, %{"path" => path}) do
    case normalize_project_path(path) do
      {:error, :blank} ->
        {:noreply, put_flash(socket, :error, gettext("Invalid project name"))}

      {:error, :relative} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Enter a full path, e.g. D:\\Projects\\myproject or /home/user/myproject")
         )}

      {:ok, expanded} ->
        # Root-ish input is rejected here too: Path.basename("/") is "/" (and
        # a Windows root contains "\\"), so validate_project_name/1 fails.
        case Project.validate_project_name(Path.basename(expanded)) do
          {:error, :invalid_name} ->
            {:noreply, put_flash(socket, :error, gettext("Invalid project name"))}

          {:ok, _sanitized} ->
            if File.dir?(expanded) do
              # Project already exists — register/open it.
              register_and_open_project(socket, expanded)
            else
              case File.mkdir_p(expanded) do
                :ok ->
                  register_and_open_project(socket, expanded)

                {:error, reason} ->
                  {:noreply,
                   put_flash(
                     socket,
                     :error,
                     gettext("Could not create directory: %{path} (%{reason})",
                       path: expanded,
                       reason: inspect(reason)
                     )
                   )}
              end
            end
        end
    end
  end

  # Shared success path for create_project: register the path in recent
  # projects, reload the recents, close the palette, reset it to :menu, flash
  # info, and push the URL params to persist the project across navigation.
  defp register_and_open_project(socket, expanded) do
    TaskRegistry.add_recent_project(expanded, Path.basename(expanded))

    recent_projects =
      TaskRegistry.list_recent_projects()
      |> filter_absolute_recent_projects()

    socket =
      socket
      |> assign(:recent_projects, recent_projects)
      |> assign(:project_palette_open, false)
      |> assign(:palette_mode, :menu)
      |> put_flash(:info, gettext("Project created: %{path}", path: expanded))

    {:noreply, push_patch(socket, to: project_url(socket, expanded))}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Project opening / selection
  # ───────────────────────────────────────────────────────────────────────────

  def open_project(socket, %{"path" => path}) do
    if socket.assigns[:current_node_id] != nil do
      activate_remote_project(socket, path)
    else
      case normalize_project_path(path) do
        {:error, :blank} ->
          {:noreply, put_flash(socket, :error, gettext("Invalid project name"))}

        {:error, :relative} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Enter a full path, e.g. D:\\Projects\\myproject or /home/user/myproject")
           )}

        {:ok, expanded} ->
          if File.dir?(expanded) do
            TaskRegistry.add_recent_project(expanded, Path.basename(expanded))

            recent_projects =
              TaskRegistry.list_recent_projects()
              |> filter_absolute_recent_projects()

            socket =
              socket
              |> assign(:recent_projects, recent_projects)
              |> assign(:project_palette_open, false)
              |> assign(:palette_mode, :menu)

            # Push URL params to persist project across navigation
            {:noreply, push_patch(socket, to: project_url(socket, expanded))}
          else
            {:noreply,
             socket
             |> put_flash(
               :error,
               gettext(
                 "Directory does not exist: %{path}. Create a new project instead?",
                 path: path
               )
             )}
          end
      end
    end
  end

  def select_project(socket, %{"path" => path}) do
    if socket.assigns[:current_node_id] != nil do
      activate_remote_project(socket, path)
    else
      case normalize_project_path(path) do
        {:error, :blank} ->
          {:noreply, put_flash(socket, :error, gettext("Invalid project name"))}

        {:error, :relative} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Enter a full path, e.g. D:\\Projects\\myproject or /home/user/myproject")
           )}

        {:ok, expanded} ->
          if File.dir?(expanded) do
            TaskRegistry.add_recent_project(expanded, Path.basename(expanded))

            recent_projects =
              TaskRegistry.list_recent_projects()
              |> filter_absolute_recent_projects()

            socket =
              socket
              |> assign(:recent_projects, recent_projects)
              |> assign(:project_palette_open, false)
              |> assign(:palette_mode, :menu)

            {:noreply, push_patch(socket, to: project_url(socket, expanded))}
          else
            {:noreply,
             put_flash(socket, :error, gettext("Directory does not exist: %{path}", path: path))}
          end
      end
    end
  end

  # Remote project activation — shared by open_project/select_project. Validates
  # the directory on the remote node, registers it in the remote node's recent
  # projects, and sets a DISPLAY-ONLY active project (no local project config /
  # mode detection — those are local concerns). The push_patch URL carries the
  # `&node=` param so handle_params re-runs in the same remote context.
  defp activate_remote_project(socket, path) do
    # Gate guard (defense in depth): while the selected remote target is
    # pending/failed, `@current_node` is still the LOCAL BEAM node — validating
    # or registering the path here would leak into the local filesystem and
    # local TaskRegistry recents. Reject the event with a flash error.
    if EvoDashWeb.RemoteGateComponents.gate_active?(socket.assigns) do
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext(
           "Cannot open project: remote node %{name} is not connected. Retry the connection first.",
           name: socket.assigns[:current_node_name] || "remote"
         )
       )}
    else
      # Remote-aware normalization: the dashboard's host OS must not
      # misclassify the remote node's paths (POSIX absolute on a Windows
      # dashboard, Windows absolute on a POSIX dashboard) and no local
      # Path.expand may run on them.
      case normalize_remote_project_path(socket.assigns[:current_node], path) do
        {:error, :blank} ->
          {:noreply, put_flash(socket, :error, gettext("Invalid project name"))}

        {:error, :relative} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Enter a full path, e.g. D:\\Projects\\myproject or /home/user/myproject")
           )}

        {:ok, expanded} ->
          node = socket.assigns[:current_node]

          if NodeContext.dir?(node, expanded) do
            NodeContext.add_recent_project(node, expanded, Path.basename(expanded))

            recent_projects =
              filter_absolute_recent_projects_for_node(
                node,
                NodeContext.list_recent_projects(node)
              )

            config = NodeContext.read_project_config(node, expanded)
            mode = Project.detect_mode(node, expanded)
            mode_info = mode_info_message(mode)

            {project_config, worktree_script, commands} =
              Project.load_project_config(node, expanded, config)

            foreign_repos = Project.load_foreign_repos(node, expanded, config)

            socket =
              socket
              |> assign(:recent_projects, recent_projects)
              |> assign(:project_palette_open, false)
              |> assign(:palette_mode, :menu)
              |> assign(:active_project, %{path: expanded, name: Path.basename(expanded)})
              |> assign(:active_project_path, expanded)
              |> assign(:task_mode, mode)
              |> assign(:task_mode_info, mode_info)
              |> assign(:project_config, project_config)
              |> assign(:worktree_script, worktree_script)
              |> assign(:commands, commands)
              |> assign(:foreign_repos, foreign_repos)
              |> assign(:show_add_foreign_repo_form, false)

            {:noreply, push_patch(socket, to: project_url(socket, expanded))}
          else
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Directory does not exist on the remote node: %{path}", path: path)
             )}
          end
      end
    end
  end

  # Builds the dashboard URL for a project path. In a remote context the
  # `&node=` param is appended so the node context survives the push_patch —
  # NOTE: deliberately NOT `EvoDashWeb.Helpers.with_node_param/2`, which
  # appends with `?` and would corrupt the existing `?project=` query.
  defp project_url(socket, path) do
    case socket.assigns[:current_node_id] do
      nil -> "/?project=#{URI.encode(path)}"
      node_id -> "/?project=#{URI.encode(path)}&node=#{node_id}"
    end
  end
end
