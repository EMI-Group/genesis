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

  Remote project ACTIVATION is async: the gate guard + path normalization run
  synchronously in the event handler, then `spawn_remote_project_activation/2`
  runs the RPC-heavy sequence in a supervised `EvoDash.TaskSupervisor` task so
  the LiveView never blocks on cross-node round-trips. Results arrive as
  `{:async_remote_project, node, path, result}` messages that
  `ProjectsLive.handle_info/2` stale-guards (node + in-flight
  `@remote_project_loading` path) and applies.
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
  absolute path (Unix `/foo`, Windows `C:\\foo`/`D:/bar`), with
  `Path.expand/1` applied to the result.

  UNC paths (`//wsl.localhost/...`, `\\\\server\\share\\...`) are normalized
  WITHOUT `Path.expand/1`: `Path.expand` preserves a `//`-prefixed UNC root
  only on Windows — on any other OS it collapses the `//` to `/` (POSIX) or
  cwd-joins the `\\\\`-prefixed path, corrupting the path. They are instead
  converted to forward-slash form with trailing separators stripped (via
  `EvoGit.Platform.normalize_separators/1` and
  `EvoGit.Platform.trim_trailing_separators/1`) and passed through intact.

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

      String.starts_with?(trimmed, "//") or String.starts_with?(trimmed, "\\\\") ->
        # UNC path (`//wsl.localhost/...`, `\\server\share\...`) — NEVER
        # Path.expand against a non-matching OS: `Path.expand` collapses a
        # `//`-prefixed root to `/` on POSIX and cwd-joins a `\\`-prefixed
        # path. Normalize separators to forward slashes + strip trailing
        # separators instead, so the path round-trips intact.
        {:ok,
         trimmed
         |> EvoGit.Platform.normalize_separators()
         |> EvoGit.Platform.trim_trailing_separators()}

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
  - absolute (POSIX leading `/` — incl. `//`-prefixed forward-slash UNC — or
    Windows-style drive letter/backslash UNC, via the node-agnostic
    `remote_absolute_path?/1` predicate) → `{:ok, trimmed}` passed through
    VERBATIM — no `Path.expand`, no separator normalization (the remote
    node's own OS understands its separators)
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

      remote_absolute_path?(trimmed) ->
        # Absolute (POSIX or Windows-style, incl. UNC) — pass through verbatim.
        # NO local Path.expand and NO separator normalization: the remote
        # node's own OS understands its separators, and a dashboard on a
        # different OS would rewrite the path.
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
  (`EvoGit.Platform.absolute_path?/1`) is used unchanged. On a REMOTE node the
  node-agnostic `remote_absolute_path?/1` predicate is used: a path is
  accepted when it is POSIX-absolute (leading `/`, incl. `//`-prefixed
  forward-slash UNC) OR Windows-style absolute (drive letter / backslash UNC,
  via `EvoGit.Platform.absolute_path?/1`) — the remote node's paths must not
  be judged by the dashboard's host OS: on a Windows dashboard
  `Path.type("/home/user/repo")` is `:volumerelative`, which would wrongly
  drop remote POSIX recents from the palette (and a POSIX dashboard would
  drop remote Windows recents). Non-binary paths are always false.
  """
  @spec absolute_path_for_node?(node(), term()) :: boolean()
  def absolute_path_for_node?(node, path) when is_binary(path) do
    if node == node() do
      EvoGit.Platform.absolute_path?(path)
    else
      remote_absolute_path?(path)
    end
  end

  def absolute_path_for_node?(_node, _path), do: false

  # Node-agnostic absolute-path check — never judged by the dashboard's host
  # OS. Accepts POSIX-absolute (leading `/`, which also covers `//`-prefixed
  # forward-slash UNC like `//wsl.localhost/...` on any dashboard OS) OR
  # anything `EvoGit.Platform.absolute_path?/1` accepts (drive letters +
  # backslash UNC — the core predicate is host-OS independent).
  defp remote_absolute_path?(path) when is_binary(path) do
    String.starts_with?(path, "/") or EvoGit.Platform.absolute_path?(path)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Foreign repo construction
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Builds a `%EvoGit.Core.ForeignRepo{}` for the given node.

  On the LOCAL node (`node == nil or node == node()`) delegates to
  `EvoGit.Core.ForeignRepo.new/3` — EXACT local behavior, including its
  internal `Path.expand/1` tilde/relative expansion semantics and its
  `writable:`/`base_sha:` opt coercion.

  On a REMOTE node constructs the struct DIRECTLY with the raw `root` and NO
  `Path.expand/1`: `ForeignRepo.new/3`'s expansion runs against the
  DASHBOARD's OS, not the remote node's, so it mangles remote paths (a
  Windows dashboard rewrites `/home/...` to a drive-letter path; a POSIX
  dashboard cwd-joins `D:\\stuff\\repo`). The remote path is stored verbatim,
  and `base_sha` is likewise kept RAW (never locally rewritten — only
  `ForeignRepo.new/3` coerces/expands it, and it is never used for remote
  roots). `writable` defaults to `false`, `base_sha` to `nil`.
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
        description: Keyword.get(opts, :description),
        writable: Keyword.get(opts, :writable, false),
        base_sha: Keyword.get(opts, :base_sha)
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

  # Remote project activation — ASYNC — shared by open_project/select_project.
  # The synchronous part here is ONLY the gate guard + remote-aware path
  # normalization; the RPC-heavy sequence (dir? validation, recent-project
  # registration + reload, config/mode/foreign-repo loading) runs OUTSIDE the
  # LiveView process in a supervised EvoDash.TaskSupervisor task so the UI
  # never blocks on the 6-7 cross-node round-trips per activation click. The
  # result arrives as a `{:async_remote_project, node, path, result}` message
  # that ProjectsLive.handle_info/2 stale-guards and applies, ending with a
  # push_patch whose URL carries the `&node=` param so handle_params re-runs
  # in the same remote context.
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
          {:noreply, spawn_remote_project_activation(socket, expanded)}
      end
    end
  end

  @doc """
  Spawns the ASYNC remote project activation for `expanded` and returns the
  socket with the loading flag set and the palette closed.

  Shared by the open-project/select-project events and the command-palette
  Enter path (`activate_remote_palette_project/2`). Re-trigger guard: an
  activation already in flight for the SAME path is a no-op; a DIFFERENT path
  supersedes it (the in-flight flag is replaced, so the older task's result is
  dropped by the stale-guard in `ProjectsLive.handle_info/2`). The RPC-heavy
  sequence runs OUTSIDE the LiveView process in a supervised
  `EvoDash.TaskSupervisor` task and reports back as
  `{:async_remote_project, node, expanded, result}` where `result` is
  `{:ok, results_map}` — the assigns the sync flow applied today — or
  `{:error, :not_a_directory}` when the path does not exist on the remote
  node. The palette closes immediately here so the UI responds instantly; the
  result applies a frame later via the continuation.
  """
  def spawn_remote_project_activation(socket, expanded) do
    if socket.assigns[:remote_project_loading] == expanded do
      # Same path already loading (e.g. double Enter) — no re-spawn.
      socket
    else
      socket = assign(socket, :remote_project_loading, expanded)

      node = socket.assigns[:current_node]
      view_pid = self()

      Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
        result = remote_project_load(node, expanded)
        send(view_pid, {:async_remote_project, node, expanded, result})
      end)

      socket
      |> assign(:project_palette_open, false)
      |> assign(:palette_mode, :menu)
    end
  end

  # The RPC-heavy remote activation sequence, run in the supervised task.
  # Returns `{:ok, results_map}` (the assigns the sync flow applied: recents
  # reloaded + node-filtered, the display-only active project, the auto-
  # detected task mode + info, and the project config / worktree script /
  # commands / foreign repos) or `{:error, :not_a_directory}`. NodeContext's
  # graceful degradation handles transport failures — no try/rescue.
  defp remote_project_load(node, expanded) do
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

      {:ok,
       %{
         recent_projects: recent_projects,
         active_project: %{path: expanded, name: Path.basename(expanded)},
         active_project_path: expanded,
         task_mode: mode,
         task_mode_info: mode_info,
         project_config: project_config,
         worktree_script: worktree_script,
         commands: commands,
         foreign_repos: foreign_repos
       }}
    else
      {:error, :not_a_directory}
    end
  end

  # Builds the dashboard URL for a project path. In a remote context the
  # `&node=` param is appended so the node context survives the push_patch —
  # NOTE: deliberately NOT `EvoDashWeb.Helpers.with_node_param/2`, which
  # appends with `?` and would corrupt the existing `?project=` query.
  defp project_url(socket, path) do
    case socket.assigns[:current_node_id] do
      nil -> "/projects?project=#{URI.encode(path)}"
      node_id -> "/projects?project=#{URI.encode(path)}&node=#{node_id}"
    end
  end
end
