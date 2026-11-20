defmodule EvoDashWeb.WorkbenchComponent do
  @moduledoc "Project navigation and recent activity around the existing dashboard pages."
  use EvoDashWeb, :live_component

  alias EvoDash.{ChatHistory, NodeContext, WorkbenchSidebarCache}
  alias EvoDashWeb.HomeLive.{SessionList, Workspace}

  @history_limit 50
  @project_activity_limit 4

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       request: nil,
       result: nil,
       loading: false,
       error: false,
       session_targets: nil,
       project_sessions: %{},
       history_scope: nil,
       history_by_project: %{},
       activity_scope: nil,
       activity_limit: @project_activity_limit
     )}
  end

  @impl true
  def update(%{refresh: true}, socket) do
    update(
      Map.take(socket.assigns, [:mode, :targets, :statuses, :patch_links, :project]),
      assign(socket, :request, nil)
    )
  end

  def update(%{mode: :projects} = assigns, socket) do
    hosts = hosts(assigns.targets, assigns.statuses)
    request = {:projects, hosts}

    socket =
      socket
      |> assign(Map.put(assigns, :hosts, hosts))
      |> seed_projects(hosts)
      |> load_project_sessions(hosts)

    {:ok,
     load(socket, request, fn ->
       hosts
       |> Task.async_stream(
         fn host ->
           case EvoDash.SafeCall.run(fn ->
                  if host.node, do: NodeContext.projects(host.node), else: []
                end) do
             {:ok, projects} -> {host.id, projects}
             {:error, _} -> {host.id, nil}
           end
         end,
         ordered: false,
         timeout: 8_000,
         on_timeout: :kill_task
       )
       |> Enum.flat_map(fn
         {:ok, entry} -> [entry]
         {:exit, _} -> []
       end)
       |> Map.new()
     end)}
  end

  def update(%{mode: :history} = assigns, socket) do
    %{node_id: node_id, target: target, project: project, sessions: sessions} = assigns
    scope = {node_id, target, project}
    request = {:history, scope, assigns.active, sessions}
    changed_scope? = scope != socket.assigns.history_scope
    socket = assign(socket, assigns)

    socket =
      if changed_scope? do
        cached = socket.assigns.history_by_project[scope]

        socket
        |> cancel_async(:load)
        |> cancel_async(:history_page)
        |> assign(
          history_scope: scope,
          request: nil,
          result: cached && cached.rows,
          older_rows: [],
          history_total: if(cached, do: cached.total, else: 0),
          history_offset: @history_limit,
          loading: false,
          loading_more: false,
          error: false
        )
      else
        socket
      end

    socket =
      if is_binary(project) and not is_nil(target) and !assigns.sessions_loading do
        load(socket, request, fn -> history(target, node_id, project, sessions) end)
      else
        socket
      end

    {:ok, socket}
  end

  def update(%{mode: :project_activity} = assigns, socket) do
    {:ok, socket |> assign(assigns) |> load_project_activity()}
  end

  defp seed_projects(%{assigns: %{result: nil}} = socket, hosts) do
    case WorkbenchSidebarCache.get(socket, :project_registry) do
      {^hosts, projects} -> assign(socket, :result, projects)
      _ -> socket
    end
  end

  defp seed_projects(socket, _hosts), do: socket

  # Always-visible project lists share one session fetch per server.
  defp load_project_sessions(socket, hosts) do
    targets = for %{id: id, node: target} <- hosts, not is_nil(target), do: {id, target}

    if connected?(socket) and socket.assigns.session_targets != targets do
      socket
      |> cancel_async(:project_sessions)
      |> assign(
        session_targets: targets,
        project_sessions: Map.take(socket.assigns.project_sessions, targets)
      )
      |> start_async(:project_sessions, fn ->
        targets
        |> Task.async_stream(
          fn {_id, target} = key ->
            sessions =
              case EvoDash.SafeCall.run(fn -> SessionList.load(target) end) do
                {:ok, {:ok, rows}} -> rows
                _ -> []
              end

            {key, sessions}
          end,
          ordered: false,
          on_timeout: :kill_task
        )
        |> Enum.reduce(Map.new(targets, &{&1, []}), fn
          {:ok, {key, rows}}, acc -> Map.put(acc, key, rows)
          {:exit, _}, acc -> acc
        end)
      end)
    else
      socket
    end
  end

  defp load_project_activity(socket) do
    %{node_id: node_id, target: target, project: project, sessions: sessions, active: active} =
      socket.assigns

    scope = {node_id, target, project}

    socket =
      if socket.assigns.activity_scope != scope do
        {result, limit} =
          WorkbenchSidebarCache.get(socket, {:project_activity, scope}) ||
            {nil, @project_activity_limit}

        socket
        |> cancel_async(:load)
        |> assign(
          activity_scope: scope,
          activity_limit: limit,
          request: nil,
          result: result,
          error: false,
          loading: false
        )
      else
        socket
      end

    limit = socket.assigns.activity_limit
    request = {:project_activity, scope, active, sessions, limit}

    if is_list(sessions) do
      load(socket, request, fn ->
        %{rows: tasks, total: total} = task_page(target, node_id, project, 0, limit)
        chats = project_chat_rows(target, node_id, project, sessions)

        %{rows: tasks ++ Enum.to_list(chats), more?: limit < @history_limit && total > limit}
      end)
    else
      socket
    end
  end

  defp load(socket, request, fun) do
    if connected?(socket) and socket.assigns.request != request do
      socket
      |> cancel_async(:load)
      |> assign(
        request: request,
        loading: true,
        error: false
      )
      |> start_async(:load, fun)
    else
      socket
    end
  end

  @impl true
  def handle_event(
        "discard_assistant_draft",
        %{"id" => id},
        %{assigns: %{mode: :projects}} = socket
      )
      when is_binary(id) and byte_size(id) == 24 do
    ChatHistory.discard_workbench_draft(id)
    {:noreply, socket}
  end

  def handle_event("more_history", _, %{assigns: %{mode: :history}} = socket) do
    %{target: target, project: project, node_id: node_id, history_offset: offset} = socket.assigns

    if target && project && offset < socket.assigns.history_total && !socket.assigns.loading_more do
      {:noreply,
       socket
       |> assign(:loading_more, true)
       |> start_async(:history_page, fn -> task_page(target, node_id, project, offset) end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("more_project_activity", _, %{assigns: %{mode: :project_activity}} = socket) do
    if socket.assigns.result[:more?] && !socket.assigns.loading do
      {:noreply,
       socket
       |> assign(
         :activity_limit,
         min(socket.assigns.activity_limit + @project_activity_limit, @history_limit)
       )
       |> load_project_activity()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:project_sessions, {:ok, sessions}, socket) do
    {:noreply, assign(socket, :project_sessions, sessions)}
  end

  def handle_async(:project_sessions, {:exit, _}, socket) do
    {:noreply,
     assign(socket, :project_sessions, Map.new(socket.assigns.session_targets, &{&1, []}))}
  end

  def handle_async(
        :load,
        {:ok, %{rows: rows, total: total} = history},
        %{assigns: %{mode: :history, history_scope: scope}} = socket
      ) do
    {:noreply,
     assign(socket,
       result: rows,
       history_total: total,
       history_by_project: Map.put(socket.assigns.history_by_project, scope, history),
       loading: false,
       error: false
     )}
  end

  def handle_async(:history_page, {:ok, %{rows: rows, total: total}}, socket) do
    {:noreply,
     assign(socket,
       older_rows: socket.assigns.older_rows ++ rows,
       history_total: total,
       history_offset: socket.assigns.history_offset + @history_limit,
       loading_more: false
     )}
  end

  def handle_async(:history_page, {:exit, _}, socket) do
    {:noreply, assign(socket, loading_more: false, error: true)}
  end

  def handle_async(:load, {:ok, result}, %{assigns: %{mode: :projects, hosts: hosts}} = socket) do
    WorkbenchSidebarCache.put(socket, :project_registry, {hosts, result})
    {:noreply, assign(socket, result: result, loading: false, error: false)}
  end

  def handle_async(
        :load,
        {:ok, result},
        %{assigns: %{mode: :project_activity} = assigns} = socket
      ) do
    WorkbenchSidebarCache.put(
      socket,
      {:project_activity, assigns.activity_scope},
      {result, assigns.activity_limit}
    )

    {:noreply, assign(socket, result: result, loading: false, error: false)}
  end

  def handle_async(:load, {:exit, _}, socket) do
    {:noreply, assign(socket, loading: false, error: true)}
  end

  @impl true
  def render(%{mode: :projects} = assigns) do
    result = assigns.result || %{}

    projects =
      for host <- assigns.hosts,
          host.node,
          project <- result[host.id] || [] do
        {host, project}
      end

    assigns =
      assign(assigns,
        projects:
          Enum.sort_by(projects, fn {host, project} ->
            {String.downcase(project.name), host.id || "", project.path}
          end),
        project_load_failed?:
          assigns.error or
            (assigns.result != nil and
               Enum.any?(assigns.hosts, &(&1.node && is_nil(result[&1.id]))))
      )

    ~H"""
    <section
      id={@id}
      phx-hook="WorkbenchSection"
      class="workbench-projects sidebar-label"
      aria-label={gettext("Projects")}
      data-workbench-projects-loading={to_string(@loading)}
    >
      <div class="workbench-section-heading">
        <span>{gettext("Projects")}</span>
        <div class="workbench-project-actions">
          <.link
            navigate={navigation_path("/projects", @node_id, project: @project, wb_open: "1")}
            id="workbench-recent-projects"
            title={gettext("Projects and workspaces")}
            aria-label={gettext("Projects and workspaces")}
          >
            <.icon name="hero-ellipsis-horizontal" class="size-4" />
          </.link>
          <button
            type="button"
            id="workbench-open-directory"
            data-workbench-project-window="open"
            title={gettext("Open Existing Project")}
            aria-label={gettext("Open Existing Project")}
          >
            <.icon name="hero-folder-open" class="size-4" />
          </button>
          <button
            type="button"
            id="workbench-new-project"
            data-workbench-attention={
              if @result != nil and @projects == [] and !@loading and !@project_load_failed?,
                do: "true"
            }
            data-workbench-project-window="create"
            title={gettext("Create New Project")}
            aria-label={gettext("Create New Project")}
          >
            <.icon name="hero-plus" class="size-4" />
          </button>
        </div>
      </div>
      <p :if={@loading and is_nil(@result)} class="workbench-hint">{gettext("Loading…")}</p>
      <p :if={@project_load_failed?} class="workbench-hint">{gettext("Could not load projects")}</p>
      <div :if={@projects != []} class="workbench-project-list">
        <div
          :for={{host, project} <- @projects}
          data-workbench-project-row
          class="workbench-project-entry"
        >
          <% href = navigation_path("/projects", host.id, project: project.path, wb_home: "1") %>
          <% active = host.id == @node_id and project.path == @project %>
          <% activity_id =
            "workbench-project-activity-" <>
              Base.url_encode64(:erlang.term_to_binary({host.id, project.path}), padding: false) %>
          <div class="workbench-project-heading">
            <.link
              patch={if @patch_links, do: href}
              navigate={unless @patch_links, do: href}
              class={["workbench-row workbench-project-link", active && "is-current"]}
              aria-current={active && "page"}
              phx-mounted={JS.ignore_attributes(["class", "aria-current"])}
              title={project.path}
              data-workbench-project={project.path}
              data-workbench-project-name={project.name}
              data-workbench-node={host.id || ""}
            >
              <.icon name="hero-folder" class="size-4 shrink-0" />
              <span class="min-w-0 truncate">{project.name}</span>
              <span class="workbench-project-server" title={host.name}>{host.name}</span>
            </.link>
          </div>
          <div
            id={activity_id <> "-open"}
            class="workbench-project-open-windows"
            data-workbench-project-windows
            phx-update="ignore"
          >
          </div>
          <.live_component
            module={__MODULE__}
            id={activity_id}
            mode={:project_activity}
            node_id={host.id}
            target={host.node}
            project={project.path}
            active={if host.id == @node_id, do: @active || [], else: []}
            sessions={(host.id == @node_id && @sessions) || @project_sessions[{host.id, host.node}]}
            current_task={if active, do: @current_task}
            current_session={if active, do: @current_session}
          />
        </div>
      </div>
    </section>
    """
  end

  def render(%{mode: :project_activity} = assigns) do
    ~H"""
    <div id={@id} class="workbench-project-activity" phx-hook="WorkbenchSection">
      <p :if={(@loading || is_nil(@sessions)) && is_nil(@result)} class="workbench-hint" role="status">
        {gettext("Loading…")}
      </p>
      <p :if={@error} class="workbench-hint">{gettext("Could not load history")}</p>
      <.link
        :for={row <- @result[:rows] || []}
        navigate={row.href}
        class={[
          "workbench-row workbench-project-activity-link",
          activity_current?(row, @current_task, @current_session) && "is-current"
        ]}
        aria-current={activity_current?(row, @current_task, @current_session) && "page"}
        title={row.title}
        data-project-activity-kind={row.kind}
        data-project-activity-id={row.id}
        data-workbench-open
      >
        <span
          role="img"
          aria-label={task_status_label(row.status)}
          class={["workbench-status shrink-0", task_status_dot_class(row.status)]}
        ></span>
        <.icon
          name={if row.kind == "task", do: "hero-clipboard-document", else: "hero-chat-bubble-left"}
          class="size-3.5 shrink-0"
        />
        <span class="min-w-0 flex-1 truncate">{row.title}</span>
        <time :if={is_struct(row[:at], DateTime)} datetime={DateTime.to_iso8601(row.at)}>
          {Calendar.strftime(row.at, "%m/%d")}
        </time>
      </.link>
      <button
        :if={@result[:more?]}
        type="button"
        class="workbench-row workbench-history-more"
        phx-click="more_project_activity"
        phx-target={@myself}
        disabled={@loading}
      >{gettext("Load more tasks")}</button>
    </div>
    """
  end

  def render(%{mode: :history} = assigns) do
    rows = Enum.uniq_by((assigns.result || []) ++ assigns.older_rows, &{&1.kind, &1.id})
    assigns = assign(assigns, :rows, rows)

    ~H"""
    <section
      id={@id}
      phx-hook="WorkbenchSection"
      class="workbench-history-content"
      aria-label={gettext("Project history")}
      data-workbench-history-empty={if @result != nil and @rows == [] and !@error, do: "true"}
    >
      <p :if={@project && !@target} class="workbench-hint">
        {gettext("Connect to see this project's history.")}
      </p>
      <div :if={@project && @target} class="workbench-history-controls">
        <div class="workbench-segmented" role="group" aria-label={gettext("History type")}>
          <button type="button" data-workbench-kind="task" aria-pressed="true">{gettext("Tasks")}</button>
          <button type="button" data-workbench-kind="chat" aria-pressed="false">{gettext(
            "Conversations"
          )}</button>
        </div>
        <label id="workbench-history-query" class="workbench-query workbench-history-query" hidden>
          <.icon name="hero-magnifying-glass" class="size-4 shrink-0" />
          <input
            id="workbench-history-search"
            type="search"
            placeholder={gettext("Search history")}
            aria-label={gettext("Search history")}
            autocomplete="off"
          />
        </label>
      </div>
      <% first_load? = @project && @target && is_nil(@result) && (@loading || @sessions_loading) %>
      <p :if={first_load?} class="workbench-hint" role="status">{gettext("Loading…")}</p>
      <p :if={@project && @target && @error} class="workbench-hint">
        {gettext("Could not load history")}
      </p>
      <div
        :if={@project && @target}
        id="workbench-history-rows"
        data-loading={to_string(!!first_load?)}
      >
        <div
          :for={row <- @rows}
          class="workbench-history-row"
          data-workbench-item={row.kind}
          data-item-id={row.id}
          data-item-title={row.title}
          data-item-href={row.href}
          data-item-active={row[:active] && "true"}
          data-item-state={task_status_label(row.status)}
          hidden={row.kind == "chat"}
        >
          <.link navigate={row.href} class="workbench-row" title={row.title} data-workbench-open>
            <.icon
              name={
                if row.kind == "task", do: "hero-clipboard-document", else: "hero-chat-bubble-left"
              }
              class="size-4 shrink-0"
            />
            <div class="workbench-history-label">
              <span class="truncate">{row.title}</span>
              <span class="workbench-history-meta">
                <span
                  class={["workbench-status", task_status_dot_class(row.status)]}
                  aria-hidden="true"
                ></span>
                <span>{task_status_label(row.status)}</span>
                <time :if={is_struct(row[:at], DateTime)} datetime={DateTime.to_iso8601(row.at)}>{Calendar.strftime(
                  row.at,
                  "%m/%d"
                )}</time>
              </span>
            </div>
          </.link>
        </div>
        <p data-workbench-empty hidden class="workbench-hint">
          {gettext("No activity in this view.")}
        </p>
        <button
          :if={@history_offset < @history_total}
          type="button"
          data-workbench-more
          class="workbench-row workbench-history-more"
          phx-click="more_history"
          phx-target={@myself}
          disabled={@loading_more}
        >
          {if @loading_more, do: gettext("Loading…"), else: gettext("Load more tasks")}
        </button>
      </div>
    </section>
    """
  end

  defp activity_current?(%{kind: "task", id: id}, task, _session), do: id == task
  defp activity_current?(%{kind: "chat", id: id}, _task, session), do: id == session

  def navigation_path(path, node_id, params \\ []) do
    query = if node_id, do: [node: node_id] ++ params, else: params
    if query == [], do: path, else: path <> "?" <> URI.encode_query(query)
  end

  def target(nil, _statuses), do: node()

  def target(id, statuses) do
    with %{phase: :connected, node: name} when is_binary(name) <- statuses[id] do
      Enum.find(Node.list(:connected), &(Atom.to_string(&1) == name))
    else
      _ -> nil
    end
  end

  defp hosts(targets, statuses) do
    local = %{id: nil, name: gettext("Local"), node: node()}
    [local | Enum.map(targets, &%{id: &1.id, name: &1.name, node: target(&1.id, statuses)})]
  end

  defp history(target, node_id, project, sessions) do
    %{rows: tasks, total: total} = task_page(target, node_id, project, 0)

    chats = target |> project_chat_rows(node_id, project, sessions) |> Enum.take(@history_limit)
    %{rows: tasks ++ chats, total: total}
  end

  defp project_chat_rows(target, node_id, project, sessions) do
    sessions
    |> Stream.filter(fn row ->
      match?(%{path: ^project}, chat_workspace(row.id, node_id, target))
    end)
    |> Stream.map(fn row ->
      %{
        kind: "chat",
        id: row.id,
        title: row.title,
        status: row.marker,
        active: row.marker != :ended,
        href: navigation_path("/assistant", node_id, session: row.id)
      }
    end)
  end

  defp task_page(target, node_id, project, offset, limit \\ @history_limit) do
    %{rows: tasks, total: total} =
      NodeContext.list_tasks_page(target,
        limit: limit,
        offset: offset,
        filters: [project_path: project]
      )

    task_rows =
      for %{id: id} = task <- tasks, task[:type] != :reflect do
        opts = task[:opts] || []
        title = opts[:objective] || opts[:prompt] || id

        %{
          kind: "task",
          id: id,
          title: String.slice(title, 0, 100),
          status: task[:status],
          at: task[:finished_at] || task[:started_at],
          active:
            task[:status] in [
              :pending,
              :running,
              :finalizing,
              :awaiting_input,
              :paused,
              :pausing,
              :cancelling
            ],
          href: navigation_path("/tasks", node_id, task: id)
        }
      end

    %{rows: task_rows, total: total}
  end

  defp chat_workspace(id, node_id, target) do
    case ChatHistory.get_state(id) do
      %{workspace: workspace} = state ->
        unless SessionList.unsent_workbench_draft?(state),
          do: Workspace.restore(workspace, {node_id, target})

      _ ->
        nil
    end
  end
end
