defmodule EvoDashWeb.DashboardLive.ProjectFlow do
  @moduledoc """
  Event handlers for project creation/opening on the dashboard.

  Extracted from DashboardLive to keep the main module focused on task
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

  alias EvoGit.TaskRegistry
  alias EvoDashWeb.DashboardLive.Project

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

  # Only `~`, `~/...`, and (on Windows) `~\\...` are expanded by Path.expand/1
  # without cwd-joining. `~foo` NEVER expands on any platform, and `~\\x` does
  # not expand off Windows — both would be cwd-joined, so they must fall
  # through to the relative branch above.
  defp expandable_tilde?(trimmed) do
    trimmed == "~" or
      String.starts_with?(trimmed, "~/") or
      (EvoGit.Platform.windows?() and String.starts_with?(trimmed, "~\\"))
  end

  # Recent projects offered in the palette must have absolute paths — stale
  # cwd-joined entries (from the pre-fix Path.expand-against-cwd behavior)
  # must never render.
  defp filter_absolute_recent_projects(recent_projects) do
    Enum.filter(recent_projects, &EvoGit.Platform.absolute_path?(&1.path))
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
          node = socket.assigns[:current_node]

          if EvoDash.NodeContext.dir?(node, expanded) do
            EvoDash.NodeContext.add_recent_project(node, expanded, Path.basename(expanded))

            recent_projects =
              EvoDash.NodeContext.list_recent_projects(node)
              |> filter_absolute_recent_projects()

            socket =
              socket
              |> assign(:recent_projects, recent_projects)
              |> assign(:project_palette_open, false)
              |> assign(:palette_mode, :menu)
              |> assign(:active_project, %{path: expanded, name: Path.basename(expanded)})
              |> assign(:active_project_path, expanded)

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
