defmodule EvoDashWeb.ProjectsLive.Overview do
  @moduledoc """
  The Projects page's PROJECT OVERVIEW surface.

  Selecting a project (or a VCT workspace) in the palette lands here instead of
  dropping straight into the task composer: the page shows WHAT is selected
  (identity, absolute OS path, VCT point, node, branch/HEAD) and offers TWO
  explicit entry points — write a task yourself (`compose_task`), or take the
  conversation to the Genesis Assistant — plus a short recent-activity list for
  that project.

  ## Contract

    * `visible?/1` decides whether this surface REPLACES the composer. It is
      false for the remote-connection gate, for an explicit compose request, for
      the idle workbench and when nothing is selected (no project and no
      workspace token) — the page's other render branches own those states.
      A named workspace with unavailable details never falls back to the
      previous project's display or execution path.
    * `scope/1` is the ONE description of the current selection:
      `%{kind: :project | :workspace, name:, path:, point:, node_label:,
      exec_path:}`. `path` is the selection's own OS path (nil for a
      workspace — a grouping point never owns a path) while `exec_path` is the
      absolute OS path anything may be READ or EXECUTED against: the project
      path, or for a workspace the chosen/first-resolvable member's path (nil
      when no member resolves, which disables both entry points).
    * `workspace_scope/1` returns the matching
      `%{workspace:, resolved:, missing:, nested:}` view map from
      `assigns[:workspaces]` when the page's selection token names a workspace.
    * `member_options/1` lists the RESOLVED members as `%{key:, label:, path:}`
      (ordered, `key` = member VCT point or raw path) and
      `execution_member/2` picks the ONE member tasks would run in: the chosen
      key while it still resolves, else the FIRST resolved member, else nil.
    * `assistant_path/1` builds the HomeLive workbench-draft URL
      (`/assistant?wb_project=…&wb_draft=…[&node=…]`): `wb_project` is the OS
      path for a project and the WORKSPACE POINT for a workspace (a member path
      is never silently substituted — the assistant resolves the group itself).
    * `default_draft_path/1` advertises that same URL only for a confirmed
      explicit overview. The browser decides whether its restored tab rail is
      empty.
    * `draft_id/0` mints the 24-lowercase-hex workbench draft id `HomeLive`
      requires (`byte_size(draft) == 24`).
    * `load/2` reads BOTH halves of the async payload off-process —
      `%{git: <snapshot | nil>, tasks: [summary map]}` — each wrapped in
      `EvoDash.SafeCall.run/1` so one failing half never takes the other down.
      It is also the DEFAULT body of the `:projects_overview_runner` app-env
      seam (`Application.get_env(:evo_dash, :projects_overview_runner)`,
      resolved at SPAWN time).
    * `maybe_spawn/1` starts that read in `EvoDash.TaskSupervisor` through
      `EvoDash.SafeCall.start/4` with the tag
      `{:overview_loaded, seq, node, path}` — the message therefore arrives
      NESTED as `{{:overview_loaded, seq, node, path}, result}` — and bumps the
      monotonic `:overview_load_seq`; a repeat for the same
      `{target_id, node, path}` (already loaded, or in flight) is a no-op.
    * `overview/1` renders the surface. It takes ONE `page` attribute (the
      LiveView assigns map) and derives everything from it through the helpers
      above — it never relies on implicit assigns of its own.

  Every user-facing string is `gettext`-wrapped and the markup uses the
  dashboard's density tokens/scale (no arbitrary pixel sizes, `rounded-lg`
  radii, `border-base-300` borders, `text-base-content/60|70` for meta).
  Nothing here raises: unknown/absent assigns degrade to nil/empty values.
  """

  use EvoDashWeb, :html

  import Phoenix.LiveView, only: [connected?: 1]

  alias EvoDash.NodeContext
  alias EvoDash.ProjectGit
  alias EvoDash.SafeCall
  alias EvoDashWeb.DraftScope
  alias EvoDashWeb.ProjectsLive.{ModelSelectionScope, ProjectFlow, StatePersistence, Workspace}
  alias EvoDashWeb.WorkbenchComponent

  @runner_seam :projects_overview_runner
  @workspace_prefix "vct:///workspaces/"
  @recent_task_limit 5
  @draft_id_bytes 12

  @status_atoms ~w(pending running finalizing cancelling pausing paused awaiting_input completed failed cancelled)a
  @status_by_name Map.new(@status_atoms, &{Atom.to_string(&1), &1})

  # ───────────────────────────────────────────────────────────────────────────
  # Visibility
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  True when the overview REPLACES the task composer: no remote-connection gate,
  no explicit compose request (`:compose_task?`), not the idle workbench, and a
  selection to describe (an active project OR a workspace token).
  """
  @spec visible?(map()) :: boolean()
  def visible?(assigns) when is_map(assigns) do
    overview_available?(assigns) and
      not idle?(assigns) and
      (not is_nil(workspace_token(assigns)) or not is_nil(Map.get(assigns, :active_project)))
  end

  def visible?(_assigns), do: false

  @doc """
  True when the URL explicitly asks for the composer (`wb_task=1`, a resume or a
  starting commit) — the `handle_event("compose_task", …)` target state.
  """
  @spec compose_task?(map()) :: boolean()
  def compose_task?(assigns) when is_map(assigns),
    do: Map.get(assigns, :compose_task?) == true

  def compose_task?(_assigns), do: false

  defp overview_available?(assigns) do
    not EvoDashWeb.RemoteGateComponents.gate_active?(assigns) and not compose_task?(assigns)
  end

  defp idle?(assigns), do: Map.get(assigns, :workbench_idle?) == true

  # ───────────────────────────────────────────────────────────────────────────
  # Workspace scope
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  The loaded WORKSPACE view map (`%{workspace:, resolved:, missing:, nested:}`)
  whose point is the page's current selection token, or nil.

  The token is `assigns[:overview_workspace_point]` when the URL named a
  workspace, else the VCT workspace point derived from the draft scope.
  """
  @spec workspace_scope(map()) :: map() | nil
  def workspace_scope(assigns) when is_map(assigns) do
    case workspace_token(assigns) do
      token when is_binary(token) ->
        Enum.find(workspaces(assigns), fn
          %{workspace: %{point: ^token}} -> true
          _ -> false
        end)

      _ ->
        nil
    end
  end

  def workspace_scope(_assigns), do: nil

  @doc """
  The selection token of the current page: the URL's workspace point when it is
  one, else the VCT point/OS path of the draft scope.
  """
  @spec token(map()) :: String.t() | nil
  def token(assigns) when is_map(assigns) do
    case workspace_token(assigns) do
      token when is_binary(token) -> token
      _ -> StatePersistence.draft_scope(assigns)
    end
  end

  def token(_assigns), do: nil

  defp workspace_token(assigns) do
    case Map.get(assigns, :overview_workspace_point) do
      token when is_binary(token) and token != "" -> token
      _ -> workspace_point_from_scope(assigns)
    end
  end

  # `StatePersistence.draft_scope/1` is pure and total (it indexes the assigns
  # map and consults the already-loaded project list), so it is called directly:
  # a crash there is a real bug and must surface, not degrade to "no workspace".
  defp workspace_point_from_scope(assigns) do
    assigns |> StatePersistence.draft_scope() |> DraftScope.workspace()
  end

  defp workspaces(assigns) do
    case Map.get(assigns, :workspaces) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Scope description
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Describes the current selection as
  `%{kind: :project | :workspace, name:, path:, point:, node_label:, exec_path:}`.
  """
  @spec scope(map()) :: map()
  def scope(assigns) when is_map(assigns) do
    case workspace_token(assigns) do
      nil -> project_scope(assigns)
      point -> workspace_scope_map(assigns, point, workspace_scope(assigns))
    end
  end

  def scope(_assigns), do: project_scope(%{})

  defp project_scope(assigns) do
    project = Map.get(assigns, :active_project)

    path =
      case project do
        %{path: path} when is_binary(path) and path != "" -> path
        _ -> binary(Map.get(assigns, :active_project_path))
      end

    %{
      kind: :project,
      name: project_name(project, path),
      path: path,
      point: project_point(project, assigns, path),
      node_label: node_label(assigns),
      exec_path: path
    }
  end

  defp workspace_scope_map(assigns, point, view) do
    workspace = if view, do: Map.get(view, :workspace, %{}), else: %{}
    execution = execution_member(view, Map.get(assigns, :overview_member))

    %{
      kind: :workspace,
      name: workspace_name(workspace, point),
      path: nil,
      point: point,
      node_label: node_label(assigns),
      exec_path: execution && execution.path
    }
  end

  defp project_name(project, path) do
    case project do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> if(is_binary(path), do: Path.basename(path), else: nil)
    end
  end

  defp project_point(project, assigns, path) do
    case project do
      %{point: point} when is_binary(point) and point != "" -> point
      _ -> ProjectFlow.mount_point_for(Map.get(assigns, :projects) || [], path)
    end
  end

  # A workspace's display name: its mount name, else the slug its point encodes.
  defp workspace_name(workspace, point) do
    case binary(Map.get(workspace, :name)) do
      nil -> workspace_slug(point)
      name -> name
    end
  end

  defp workspace_slug(point) when is_binary(point) do
    slug =
      point
      |> String.replace_prefix(@workspace_prefix, "")
      |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
      |> String.trim("-")

    if slug == "", do: point, else: slug
  end

  defp workspace_slug(_point), do: nil

  defp node_label(assigns) do
    binary(Map.get(assigns, :current_node_name)) ||
      binary(Map.get(assigns, :current_node_id)) || gettext("Local")
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Workspace members
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  The RESOLVED members of a workspace view as ordered `%{key:, label:, path:}`
  maps; `key` is the member's VCT point, else its raw OS path.
  """
  @spec member_options(map() | nil) :: [map()]
  def member_options(workspace_view) when is_map(workspace_view) do
    workspace_view
    |> resolved_members()
    |> Enum.flat_map(fn member ->
      path = binary(Map.get(member, :path))
      key = binary(Map.get(member, :point)) || path

      if is_binary(key) do
        [%{key: key, label: binary(Map.get(member, :name)) || key, path: path}]
      else
        []
      end
    end)
  end

  def member_options(_workspace_view), do: []

  @doc """
  The ONE resolved member tasks would run in: `chosen_key` while it still
  resolves to a member with an OS path, else the FIRST such member, else nil
  (nothing is ever invented — the UI states that no member resolves).
  """
  @spec execution_member(map() | nil, term()) :: map() | nil
  def execution_member(workspace_view, chosen_key) do
    runnable =
      workspace_view
      |> member_options()
      |> Enum.filter(&is_binary(&1.path))

    case is_binary(chosen_key) && Enum.find(runnable, &(&1.key == chosen_key)) do
      %{key: _} = chosen -> chosen
      _ -> List.first(runnable)
    end
  end

  @doc """
  The workspace member refs that did NOT resolve (points/paths as stored), plus
  any nested refs — the honest "what is missing" list.
  """
  @spec missing_refs(map() | nil) :: [String.t()]
  def missing_refs(workspace_view) when is_map(workspace_view) do
    (as_list(Map.get(workspace_view, :missing)) ++ as_list(Map.get(workspace_view, :nested)))
    |> Enum.map(&Workspace.ref_text/1)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  def missing_refs(_workspace_view), do: []

  defp resolved_members(workspace_view) do
    case Map.get(workspace_view, :resolved) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Assistant hand-off
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  The HomeLive workbench-draft URL for the current selection
  (`/assistant?wb_project=…&wb_draft=…[&node=…]`).

  `wb_project` is the OS path for a project and the WORKSPACE POINT for a
  workspace — the assistant resolves the grouping point itself, so a member path
  is never silently substituted. A project without an OS path does not fall
  back to its VCT point. Blank query values are dropped; the overview enables
  the link only when the selection has an execution path.
  """
  @spec assistant_path(map()) :: String.t()
  def assistant_path(assigns) when is_map(assigns), do: assistant_path(assigns, scope(assigns))
  def assistant_path(_assigns), do: "/assistant"

  defp assistant_path(assigns, scope) do
    project = if scope.kind == :workspace, do: scope.point, else: scope.exec_path

    params =
      [wb_project: project, wb_draft: Map.get(assigns, :overview_draft_id)]
      |> Enum.filter(fn {_key, value} -> present?(value) end)

    WorkbenchComponent.navigation_path("/assistant", Map.get(assigns, :current_node_id), params)
  end

  @doc """
  The same already-minted Assistant draft URL as the overview link, or nil
  until selection is confirmed. Requires a visible overview with an explicit
  project or workspace URL selection. Implicit recent-project activation does
  not offer a default draft.

  Confirmation uses the loaded VCT registry, never Git state or extra I/O.
  Whether to open the draft depends on the browser's restored tab rail.
  """
  @spec default_draft_path(map()) :: String.t() | nil
  def default_draft_path(
        %{
          workbench_reconnect_params: %{"project" => selected} = params,
          overview_draft_id: draft
        } = assigns
      ) do
    with true <- present?(selected) and present?(draft) and visible?(assigns),
         false <- ModelSelectionScope.pending_remote?(assigns),
         nil <- assigns[:remote_project_loading],
         nil <- assigns[:workbench_project_selection],
         false <-
           assigns[:project_palette_open] == true or assigns[:workbench_open_requested] == true or
             params["wb_open"] == "1",
         false <-
           Enum.any?(
             ~w(wb_home wb_task wb_git_branch resume_from starting_commit),
             &Map.has_key?(params, &1)
           ),
         %{exec_path: path} = selection <- scope(assigns),
         true <- ProjectFlow.absolute_path_for_node?(assigns[:current_node] || node(), path),
         true <- confirmed_selection?(selection, selected, assigns) do
      assistant_path(assigns, selection)
    else
      _ -> nil
    end
  end

  def default_draft_path(_assigns), do: nil

  defp confirmed_selection?(%{kind: :workspace, point: point}, point, _assigns), do: true

  defp confirmed_selection?(
         %{kind: :project, path: path, point: point},
         path,
         %{active_project_path: path, active_project: %{path: path}} = assigns
       ) do
    DraftScope.point?(point) and
      Enum.any?(as_list(assigns[:projects]), &match?(%{path: ^path, point: ^point}, &1))
  end

  defp confirmed_selection?(_scope, _selected, _assigns), do: false

  @doc """
  A fresh workbench draft id: `:crypto.strong_rand_bytes(12)` hex-encoded →
  24 lowercase characters, the shape `EvoDashWeb.HomeLive.SessionResolution`
  requires (`byte_size(draft) == 24`).
  """
  @spec draft_id() :: String.t()
  def draft_id do
    @draft_id_bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Async load
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Reads the overview payload for `path` on `node` OFF the LiveView process:
  `%{git: <normalized snapshot | nil>, tasks: [summary map]}`.

  Each half is its own `EvoDash.SafeCall.run/1` boundary, so an unavailable git
  repository never hides recent tasks and vice versa. A non-binary path (a
  workspace with no resolvable member) reads nothing.
  """
  @spec load(node(), term()) :: %{git: map() | nil, tasks: [map()]}
  def load(node, path) when is_binary(path) and path != "" do
    %{git: git_snapshot(node, path), tasks: recent_tasks(node, path)}
  end

  def load(_node, _path), do: %{git: nil, tasks: []}

  defp git_snapshot(node, path) do
    case SafeCall.run(fn -> ProjectGit.snapshot(node, path) end) do
      {:ok, {:ok, %{} = snapshot}} -> normalize_snapshot(snapshot)
      _ -> nil
    end
  end

  defp normalize_snapshot(snapshot) do
    %{
      branch: binary(Map.get(snapshot, :branch)),
      commit: binary(Map.get(snapshot, :commit)),
      subject: binary(Map.get(snapshot, :subject))
    }
  end

  defp recent_tasks(node, path) do
    case SafeCall.run(fn ->
           NodeContext.list_tasks_page(node, limit: @recent_task_limit, project_path: path)
         end) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        rows |> Enum.filter(&is_map/1) |> Enum.take(@recent_task_limit)

      _ ->
        []
    end
  end

  @doc """
  Spawns the overview read for the current selection, bumping the monotonic
  `:overview_load_seq` stale guard.

  A read starts only on a connected, visible overview with a new
  `{target_id, node, path}` key and a usable execution path. A repeat (including
  the same member re-selected) never re-reads. A changed scope also discards
  old metadata. The payload arrives as `{{:overview_loaded, seq, node, path},
  result}`; `seq`, `node` and `path` are the caller's stale guards.
  """
  @spec maybe_spawn(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_spawn(socket) do
    assigns = socket.assigns
    path = scope(assigns).exec_path
    node = Map.get(assigns, :current_node) || node()
    key = load_key(assigns, path)

    cond do
      not connected?(socket) or Map.get(assigns, :overview_loaded_for) == key ->
        socket

      true ->
        seq = (Map.get(assigns, :overview_load_seq) || 0) + 1

        socket =
          assign(socket,
            overview_load_seq: seq,
            overview_loaded_for: nil,
            overview_git: nil,
            overview_tasks: nil
          )

        if key && visible?(assigns) do
          runner = runner()

          case SafeCall.start(self(), {:overview_loaded, seq, node, path}, fn ->
                 runner.(node, path)
               end) do
            {:ok, _pid} -> assign(socket, :overview_loaded_for, key)
            {:error, _reason} -> socket
          end
        else
          socket
        end
    end
  end

  defp load_key(assigns, path) when is_binary(path) and path != "" do
    {Map.get(assigns, :current_node_id), Map.get(assigns, :current_node) || node(), path}
  end

  defp load_key(_assigns, _path), do: nil

  # The runner seam is resolved AT SPAWN TIME so a test can stub the read.
  defp runner do
    case Application.get_env(:evo_dash, @runner_seam) do
      fun when is_function(fun, 2) -> fun
      _ -> &load/2
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Render
  # ───────────────────────────────────────────────────────────────────────────

  attr(:page, :map, default: nil)

  @doc """
  Renders the project overview. Takes the LiveView `page` assigns map and
  derives every value through this module's helpers.
  """
  def overview(assigns) do
    page =
      Map.get(assigns, :page) || Map.get(assigns, :assigns) || assigns

    scope = scope(page)
    workspace_view = workspace_scope(page)
    execution = execution_member(workspace_view, Map.get(page, :overview_member))
    missing_refs = missing_refs(workspace_view)
    key = load_key(page, scope.exec_path)
    loaded_for_scope? = not is_nil(key) and Map.get(page, :overview_loaded_for) == key

    assigns =
      assign(assigns,
        scope: scope,
        workspace_view: workspace_view,
        member_options: member_options(workspace_view),
        execution_member: execution,
        missing_refs: missing_refs,
        missing_line: missing_line(missing_refs),
        git: if(loaded_for_scope?, do: git_snapshot_assign(page)),
        tasks: if(loaded_for_scope?, do: task_rows(page), else: []),
        assistant_path: assistant_path(page, scope),
        kind_label: kind_label(scope.kind),
        runnable?: not is_nil(key)
      )

    ~H"""
    <section
      id="workbench-project-overview"
      class="flex-1 flex flex-col min-h-0 overflow-y-auto"
      aria-labelledby="overview-title"
      data-overview-kind={@scope.kind}
    >
      <div class="space-y-4">
        <header class="space-y-1">
          <p class="text-2xs uppercase tracking-wide text-base-content/60">{@kind_label}</p>
          <h1 id="overview-title" class="text-xl font-semibold" data-overview-name={@scope.name}>
            {@scope.name}
          </h1>
          <p class="text-sm text-base-content/70" data-overview-meta>
            {meta_line(@scope, @git)}
          </p>
        </header>

        <div class="flex flex-wrap items-center gap-3">
          <button
            id="overview-new-task"
            type="button"
            phx-click="compose_task"
            class="btn btn-primary"
            disabled={!@runnable?}
          >
            <.icon name="hero-plus" class="size-4" />
            {gettext("New task")}
          </button>
          <.link
            :if={@runnable?}
            id="overview-chat-assistant"
            navigate={@assistant_path}
            class="btn btn-outline"
          >
            {gettext("Chat with Assistant")}
          </.link>
          <button
            :if={!@runnable?}
            id="overview-chat-assistant"
            type="button"
            class="btn btn-outline"
            disabled
          >
            {gettext("Chat with Assistant")}
          </button>
        </div>

        <dl class="space-y-2 text-sm">
          <div class="flex flex-wrap items-start gap-x-3 gap-y-1">
            <dt class="w-28 shrink-0 text-base-content/60">{gettext("Path")}</dt>
            <dd class="min-w-0 flex-1 font-medium break-all" data-overview-path>
              <%= cond do %>
                <% is_binary(@scope.path) -> %>
                  {@scope.path}
                <% @scope.kind == :workspace -> %>
                  <span class="font-normal text-base-content/70">
                    {gettext("Grouping point — no OS path")}
                  </span>
                <% true -> %>
                  <span class="font-normal text-base-content/70">{gettext("Unavailable")}</span>
              <% end %>
            </dd>
          </div>
          <div :if={is_binary(@scope.point)} class="flex flex-wrap items-start gap-x-3 gap-y-1">
            <dt class="w-28 shrink-0 text-base-content/60">{gettext("VCT point")}</dt>
            <dd class="min-w-0 flex-1 font-mono break-all" data-overview-point>
              {@scope.point}
            </dd>
          </div>
          <div class="flex flex-wrap items-start gap-x-3 gap-y-1">
            <dt class="w-28 shrink-0 text-base-content/60">{gettext("Node")}</dt>
            <dd class="min-w-0 flex-1 font-medium break-all" data-overview-node>
              {@scope.node_label}
            </dd>
          </div>
          <div :if={head_line(@git)} class="flex flex-wrap items-start gap-x-3 gap-y-1">
            <dt class="w-28 shrink-0 text-base-content/60">{gettext("Branch / HEAD")}</dt>
            <dd class="min-w-0 flex-1 font-medium break-all" data-overview-head>
              {head_line(@git)}
            </dd>
          </div>
        </dl>

        <div :if={@scope.kind == :workspace} class="space-y-3">
          <p class="text-sm text-base-content/70">
            <%!-- zh_CN: 工作区只是把项目分组，本身不是可运行的项目，不能作为任务执行路径 --%>
            {gettext("A workspace groups projects; it is not a runnable project.")}
          </p>
          <p :if={is_nil(@workspace_view)} class="text-sm text-base-content/70" role="status">
            {gettext("Workspace details are not available.")}
          </p>

          <ol :if={@workspace_view} class="space-y-1 text-sm">
            <li
              :for={member <- @member_options}
              class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5"
            >
              <span class="font-medium">{member.label}</span>
              <span class="min-w-0 break-all text-base-content/60">{member.path}</span>
            </li>
            <li
              :for={ref <- @missing_refs}
              class="flex items-center gap-2 text-base-content/70"
              data-overview-missing
            >
              <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-warning" />
              <span class="min-w-0 font-mono break-all">{ref}</span>
              <span class="text-xs">{gettext("missing")}</span>
            </li>
          </ol>

          <form
            :if={@member_options != []}
            id="overview-member-form"
            phx-change="overview_select_member"
            class="flex flex-wrap items-center gap-2"
          >
            <label class="text-sm text-base-content/60" for="overview-member-select">
              {gettext("Run tasks in")}
            </label>
            <select
              id="overview-member-select"
              name="overview_member"
              class="select select-sm max-w-full"
            >
              <option
                :for={member <- @member_options}
                value={member.key}
                selected={@execution_member && member.key == @execution_member.key}
                data-overview-member-option
              >
                {member.label}
              </option>
            </select>
          </form>

          <p :if={@execution_member} class="text-sm" data-overview-execution-member>
            {gettext("New tasks will run in %{name} (%{path})",
              name: @execution_member.label,
              path: @execution_member.path
            )}
          </p>
          <p :if={@execution_member} class="text-xs text-base-content/70">
            {gettext("Chat with Assistant opens a conversation scoped to this workspace.")}
          </p>

          <div
            :if={@workspace_view && is_nil(@execution_member)}
            role="alert"
            class="rounded-lg border border-error/30 bg-error/10 p-4 text-sm"
            data-overview-no-member
          >
            <p class="font-medium">{gettext("No workspace member resolves to a project.")}</p>
            <p :if={@missing_line} class="mt-1 break-all text-base-content/70">{@missing_line}</p>
          </div>
        </div>

        <div :if={@tasks != []} class="space-y-2">
          <h2 class="text-lg font-semibold">{gettext("Recent activity")}</h2>
          <ul class="divide-y divide-base-300">
            <li
              :for={task <- @tasks}
              class="flex min-h-[var(--row-h-tall)] items-center gap-3 py-2"
            >
              <% status = status_atom(Map.get(task, :status)) %>
              <div class="min-w-0 flex-1">
                <%= if objective = objective_text(task) do %>
                  <p class="break-words text-sm text-base-content/80">
                    {truncate_string(objective, 120)}
                  </p>
                <% end %>
                <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5 text-xs text-base-content/60">
                  <span class="break-all font-mono" data-overview-task-id={task.id}>{task.id}</span>
                  <span>{format_datetime(Map.get(task, :started_at))}</span>
                </div>
              </div>
              <span class={"shrink-0 px-2 py-0.5 text-xs " <> task_status_badge(status)}>
                {task_status_label(status)}
              </span>
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  defp git_snapshot_assign(page) do
    case Map.get(page, :overview_git) do
      %{} = git -> git
      _ -> nil
    end
  end

  defp task_rows(page) do
    case Map.get(page, :overview_tasks) do
      list when is_list(list) ->
        list
        |> Enum.filter(fn
          %{id: id} -> is_integer(id) or present?(id)
          _ -> false
        end)
        |> Enum.take(@recent_task_limit)

      _ ->
        []
    end
  end

  defp kind_label(:workspace), do: gettext("Workspace")
  defp kind_label(_kind), do: gettext("Project")

  defp meta_line(scope, git) do
    [scope.node_label, head_line(git), subject_line(git)]
    |> Enum.filter(&present?/1)
    |> Enum.join(" · ")
  end

  defp head_line(%{branch: branch, commit: commit}) do
    case {branch, short_sha(commit)} do
      {nil, nil} -> nil
      {branch, nil} -> branch
      {nil, sha} -> sha
      {branch, sha} -> branch <> " @ " <> sha
    end
  end

  defp head_line(_git), do: nil

  defp subject_line(%{subject: subject}) when is_binary(subject) and subject != "",
    do: subject

  defp subject_line(_git), do: nil

  defp short_sha(commit) when is_binary(commit) and commit != "",
    do: String.slice(commit, 0, 7)

  defp short_sha(_commit), do: nil

  defp status_atom(status) when is_atom(status) and not is_nil(status), do: status
  defp status_atom(status) when is_binary(status), do: Map.get(@status_by_name, status, :unknown)
  defp status_atom(_status), do: :unknown

  # A task's objective: `opts[:objective]` (falling back to the legacy
  # `opts[:prompt]`), whichever key-map shape the decoded opts carry.
  defp objective_text(task) do
    opts = Map.get(task, :opts)

    text =
      cond do
        is_list(opts) and Keyword.keyword?(opts) ->
          Keyword.get(opts, :objective) || Keyword.get(opts, :prompt)

        is_map(opts) ->
          Map.get(opts, :objective) || Map.get(opts, "objective") ||
            Map.get(opts, :prompt) || Map.get(opts, "prompt")

        true ->
          nil
      end

    if present?(text), do: String.trim(text)
  end

  defp missing_line([]), do: nil

  defp missing_line(refs),
    do: gettext("Missing: %{refs}", refs: Enum.join(refs, ", "))

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp binary(value) when is_binary(value) and value != "", do: value
  defp binary(_value), do: nil

  defp as_list(value) when is_list(value), do: value
  defp as_list(_value), do: []
end
