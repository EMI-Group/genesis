defmodule EvoDashWeb.WorkbenchComponent do
  @moduledoc """
  Recent-project shortcuts (`mode: :projects`) and the project history panel
  (`mode: :history`) around the existing dashboard pages.

  The sidebar lists at most five recently opened projects as ONE flat
  recency-ordered shortcut list — never every project × every task — so it
  stays a short entry point rather than a second task list.

  The history panel is a SERVER-SIDE read: the project, status and free-text
  query are real filters of the paged task read (and of the conversation
  rows), so a filter change is a new request rather than a client-side filter
  over one cached page.
  """
  use EvoDashWeb, :live_component

  alias EvoDash.{ChatHistory, NodeContext, WorkbenchSidebarCache}
  alias EvoDashWeb.HomeLive.{SessionList, Workspace}

  @history_limit 15
  @recent_project_limit 5

  @history_statuses ~w(pending running finalizing awaiting_input cancelling pausing paused completed failed cancelled)

  # Lifecycle classes of a history task row, and the ONE destination each class
  # deserves:
  #   * FINISHED — the run is over and its output (diff, merge/reject, archive)
  #     is what the user came for, so the row opens the review page.
  #   * LIVE — the run is still in flight, so the row opens THAT run's detail on
  #     the tasks page (`?task=<id>` is the page's focus mode: it filters the
  #     list to the one task and opens its card). `/agents` is NOT a valid target
  #     here — it accepts no task param and would land on the whole inspector.
  # A status outside both classes (an unknown/future value) falls back to the
  # live destination, which focuses the task without claiming it is reviewable.
  @finished_task_statuses [:completed, :failed, :cancelled]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       mode: nil,
       node_id: nil,
       target: nil,
       project: nil,
       targets: [],
       statuses: %{},
       patch_links: false,
       hosts: [],
       request: nil,
       result: nil,
       loading: false,
       loading_more: false,
       error: false,
       older_rows: [],
       history_scope: nil,
       scope_pending?: false,
       history_kind: "task",
       history_query: "",
       history_status: "",
       history_project: nil,
       history_sig: nil,
       history_total: 0,
       history_offset: @history_limit,
       project_options: nil,
       project_options_scope: nil
     )}
  end

  @impl true
  def update(%{refresh: true}, socket) do
    refresh_assigns =
      case socket.assigns.mode do
        :history ->
          Map.take(socket.assigns, [:mode, :node_id, :target, :project, :scope_pending?])

        _projects ->
          Map.take(socket.assigns, [:mode, :targets, :statuses, :patch_links, :project, :node_id])
      end

    update(refresh_assigns, assign(socket, :request, nil))
  end

  def update(%{mode: :projects} = assigns, socket) do
    hosts = hosts(Map.get(assigns, :targets) || [], Map.get(assigns, :statuses) || %{})
    request = {:projects, hosts}

    socket =
      socket
      |> assign(Map.put(assigns, :hosts, hosts))
      |> seed_projects(hosts)

    {:ok, load(socket, request, fn -> fetch_projects(hosts) end)}
  end

  def update(%{mode: :history} = assigns, socket) do
    node_id = Map.get(assigns, :node_id)
    target = Map.get(assigns, :target)
    project = Map.get(assigns, :project)
    pending? = Map.get(assigns, :scope_pending?, false)
    scope = {node_id, target, project, pending?}

    socket =
      socket
      |> assign(Map.take(assigns, [:id, :mode, :node_id, :target, :project]))
      |> assign(:scope_pending?, pending?)

    socket =
      if scope != socket.assigns.history_scope do
        socket
        |> cancel_async(:history_load)
        |> cancel_async(:history_projects)
        |> assign(
          history_scope: scope,
          request: nil,
          result: nil,
          older_rows: [],
          history_total: 0,
          history_offset: @history_limit,
          loading: false,
          loading_more: false,
          error: false,
          history_query: "",
          history_status: "",
          history_project: project || "",
          project_options: nil,
          project_options_scope: nil
        )
      else
        socket
      end

    socket =
      if history_ready?(socket.assigns) do
        socket
        |> load_project_options({node_id, target})
        |> ensure_history_read()
      else
        socket
      end

    {:ok, socket}
  end

  defp seed_projects(%{assigns: %{result: nil}} = socket, hosts) do
    case WorkbenchSidebarCache.get(socket, :project_registry) do
      {^hosts, projects} -> assign(socket, :result, projects)
      _ -> socket
    end
  end

  defp seed_projects(socket, _hosts), do: socket

  defp fetch_projects(hosts) do
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

  def handle_event(event, _params, %{assigns: %{mode: :history, scope_pending?: true}} = socket)
      when event in ["history_filters", "history_kind", "more_history"] do
    {:noreply, socket}
  end

  # The search box and both selects live in ONE form, so a change (or an Enter
  # submit in the search box) answers with a partial param map — a missing key
  # keeps the assign it already had, and an unchanged filter state is a no-op
  # rather than a duplicate read.
  def handle_event("history_filters", params, %{assigns: %{mode: :history}} = socket)
      when is_map(params) do
    query = params |> Map.get("query", socket.assigns.history_query) |> to_string()
    project = params |> Map.get("project", socket.assigns.history_project) |> to_string()
    status = params |> Map.get("status", socket.assigns.history_status) |> to_string()

    if query == socket.assigns.history_query and project == socket.assigns.history_project and
         status == socket.assigns.history_status do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(history_query: query, history_project: project, history_status: status)
       |> reload_history()}
    end
  end

  def handle_event(
        "history_kind",
        %{"kind" => kind},
        %{assigns: %{mode: :history}} = socket
      )
      when kind in ["task", "chat"] do
    {:noreply, socket |> assign(:history_kind, kind) |> reload_history()}
  end

  def handle_event("history_kind", _params, %{assigns: %{mode: :history}} = socket) do
    {:noreply, socket}
  end

  def handle_event("more_history", _, %{assigns: %{mode: :history}} = socket) do
    %{history_kind: kind, history_offset: offset, history_total: total} = socket.assigns
    loading_more? = socket.assigns.loading_more

    if kind == "task" and not loading_more? and offset < total do
      {:noreply, socket |> assign(request: nil, loading_more: true) |> ensure_history_read()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(key, _result, %{assigns: %{mode: :history, scope_pending?: true}} = socket)
      when key in [:history_projects, :history_load] do
    {:noreply, socket}
  end

  def handle_async(:history_projects, {:ok, {scope, options}}, socket) do
    if socket.assigns.project_options_scope == scope do
      {:noreply, assign(socket, :project_options, options)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:history_projects, {:exit, _}, socket) do
    {:noreply, assign(socket, :project_options, [])}
  end

  def handle_async(
        :history_load,
        {:ok, {:ok, %{sig: sig} = page}},
        %{assigns: %{mode: :history}} = socket
      ) do
    cond do
      sig != socket.assigns.history_sig ->
        {:noreply, socket}

      socket.assigns.loading_more ->
        {:noreply, append_history_page(socket, page)}

      true ->
        socket =
          assign(socket,
            result: page.rows,
            history_total: page.total,
            history_offset: @history_limit,
            loading: false,
            loading_more: false,
            error: false
          )

        {:noreply, assign(socket, :request, history_signature(socket.assigns))}
    end
  end

  def handle_async(:history_load, _failure, %{assigns: %{mode: :history}} = socket) do
    {:noreply, assign(socket, loading: false, loading_more: false, error: true)}
  end

  def handle_async(:load, {:ok, result}, %{assigns: %{mode: :projects, hosts: hosts}} = socket) do
    WorkbenchSidebarCache.put(socket, :project_registry, {hosts, result})
    {:noreply, assign(socket, result: result, loading: false, error: false)}
  end

  def handle_async(:load, {:exit, _}, socket) do
    {:noreply, assign(socket, loading: false, error: true)}
  end

  @impl true
  def render(%{mode: :projects} = assigns) do
    result = assigns.result || %{}

    projects =
      assigns.hosts
      |> recent_projects(result, assigns.project, assigns.node_id)
      |> Enum.take(@recent_project_limit)

    assigns =
      assign(assigns,
        projects: projects,
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
      aria-label={gettext("Recent projects")}
      data-workbench-projects-loading={to_string(@loading)}
    >
      <div class="workbench-section-heading">
        <%!-- zh_CN: 最近项目 — 仅作为快捷入口，不列出每个项目的历史任务 --%>
        <span class="sidebar-label text-sm font-semibold">{gettext("Recent projects")}</span>
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
          <% href = navigation_path("/projects", host.id, project: project.path) %>
          <% active = host.id == @node_id and project.path == @project %>
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
              <.icon name="hero-folder" class="size-4 shrink-0 text-base-content/50" />
              <span class="workbench-project-name min-w-0 truncate">{project.name}</span>
              <span class="workbench-project-server" title={host.name}>{host.name}</span>
            </.link>
          </div>
        </div>
      </div>
    </section>
    """
  end

  def render(%{mode: :history} = assigns) do
    rows = Enum.uniq_by((assigns.result || []) ++ assigns.older_rows, &{&1.kind, &1.id})
    options = effective_project_options(assigns.project_options, assigns.project)
    ready? = history_ready?(assigns)

    assigns =
      assign(assigns,
        rows: rows,
        filter_options: options,
        status_options: @history_statuses,
        ready?: ready?,
        empty?: ready? and assigns.result != nil and rows == [] and !assigns.error,
        first_load?: ready? and is_nil(assigns.result) and assigns.loading
      )

    ~H"""
    <section
      id={@id}
      phx-hook="WorkbenchSection"
      class="workbench-history-content"
      aria-label={gettext("Project history")}
      data-workbench-history-empty={if @empty?, do: "true"}
    >
      <p :if={@scope_pending?} class="workbench-hint" role="status">
        {gettext("Resolving project…")}
      </p>
      <p :if={!@scope_pending? && @project && !@target} class="workbench-hint">
        {gettext("Connect to see this project's history.")}
      </p>
      <%!-- The three filters are ONE request: the form serializes
      `query`/`project`/`status` on both change and submit, so the search
      input never performs a native form submit on Enter. --%>
      <form
        :if={@ready?}
        id="workbench-history-filters"
        class="workbench-history-controls"
        phx-change="history_filters"
        phx-submit="history_filters"
        phx-target={@myself}
      >
        <div class="workbench-history-filters">
          <label class="workbench-history-field" for="workbench-history-project-filter">
            <span class="workbench-history-field-label">{gettext("Project")}</span>
            <select
              id="workbench-history-project-filter"
              class="workbench-history-filter"
              name="project"
              aria-label={gettext("Filter by project")}
            >
              <%!-- zh_CN: 所有项目 — 项目筛选里表示不过滤项目 --%>
              <option value="">{gettext("All projects")}</option>
              <option
                :for={option <- @filter_options}
                value={option.path}
                selected={option.path == @history_project}
              >
                {option.name}
              </option>
            </select>
          </label>
          <label class="workbench-history-field" for="workbench-history-status-filter">
            <span class="workbench-history-field-label">{gettext("Status")}</span>
            <select
              id="workbench-history-status-filter"
              class="workbench-history-filter"
              name="status"
              aria-label={gettext("Filter by status")}
            >
              <%!-- zh_CN: 任意状态 — 状态筛选里表示不过滤状态 --%>
              <option value="">{gettext("Any status")}</option>
              <option
                :for={status <- @status_options}
                value={status}
                selected={status == @history_status}
              >
                {status_label(status)}
              </option>
            </select>
          </label>
        </div>
        <label id="workbench-history-query" class="workbench-query workbench-history-query">
          <.icon name="hero-magnifying-glass" class="size-4 shrink-0" />
          <input
            id="workbench-history-search"
            type="search"
            name="query"
            value={@history_query}
            placeholder={gettext("Search history")}
            aria-label={gettext("Search history")}
            autocomplete="off"
            phx-debounce="300"
          />
        </label>
        <div
          class="workbench-segmented workbench-history-switch"
          data-history-kind={if @history_kind == "task", do: "tasks", else: "conversations"}
          role="group"
          aria-label={gettext("History type")}
        >
          <button
            type="button"
            data-workbench-kind="task"
            aria-pressed={to_string(@history_kind == "task")}
            phx-click="history_kind"
            phx-value-kind="task"
            phx-target={@myself}
          >
            {gettext("Tasks")}
          </button>
          <button
            type="button"
            data-workbench-kind="chat"
            aria-pressed={to_string(@history_kind == "chat")}
            phx-click="history_kind"
            phx-value-kind="chat"
            phx-target={@myself}
          >
            {gettext("Conversations")}
          </button>
        </div>
      </form>
      <p :if={@first_load?} class="workbench-hint" role="status">{gettext("Loading…")}</p>
      <p :if={@ready? && @error} class="workbench-hint">
        {gettext("Could not load history")}
      </p>
      <p
        :if={@ready? && @history_kind == "chat" && @empty? && !@loading}
        class="workbench-hint"
      >
        {gettext("No conversations found.")}
      </p>
      <div
        :if={@ready?}
        id="workbench-history-rows"
        data-loading={to_string(!!@first_load?)}
      >
        <div
          :for={row <- @rows}
          class="workbench-history-row"
          data-workbench-item={row.kind}
          data-item-id={row.id}
          data-item-title={row.title}
          data-item-href={row.href}
          data-item-active={row[:active] && "true"}
          data-item-state={status_label(row.status)}
        >
          <.link navigate={row.href} class="workbench-row" title={row.title} data-workbench-open>
            <span :if={row.kind == "chat"} class="workbench-history-kind" aria-hidden="true">
              <.icon name="hero-chat-bubble-left" class="size-4" />
            </span>
            <div class="workbench-history-label">
              <span class="workbench-history-title truncate text-sm">{row.title}</span>
              <span class="workbench-history-meta text-xs">
                <span
                  class={["workbench-status", task_status_dot_class(row.status)]}
                  aria-hidden="true"
                ></span>
                <span>{status_label(row.status)}</span>
                <time :if={is_struct(row[:at], DateTime)} datetime={DateTime.to_iso8601(row.at)}>{Calendar.strftime(
                  row.at,
                  "%m/%d"
                )}</time>
              </span>
            </div>
          </.link>
        </div>
        <button
          :if={@history_kind == "task" and @history_offset < @history_total}
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

  # -- history requests -----------------------------------------------------

  defp history_ready?(%{scope_pending?: pending?, project: project, target: target}) do
    not pending? and is_binary(project) and not is_nil(target)
  end

  # A filter change (or a kind switch) is a NEW request, so the paging window
  # and every accumulated page are dropped before the read is re-issued.
  defp reload_history(socket) do
    socket
    |> cancel_async(:history_load)
    |> assign(
      result: nil,
      older_rows: [],
      history_total: 0,
      history_offset: @history_limit,
      request: nil,
      loading: false,
      loading_more: false,
      error: false
    )
    |> ensure_history_read()
  end

  # Issues the read the current filter state calls for — the FIRST page when
  # nothing is loaded for this signature, the next page when `loading_more` is
  # set. The stored `request` signature (offset included) is what keeps a
  # parent re-render (every broadcast calls `update/2`) from re-issuing the
  # same read; a load-more stores the signature of its OWN offset.
  defp ensure_history_read(socket) do
    %{loading_more: loading_more?} = socket.assigns

    if connected?(socket) and history_ready?(socket.assigns) do
      request = history_signature(socket.assigns)

      if socket.assigns.request == request do
        socket
      else
        %{node_id: node_id, target: target, history_offset: offset} = socket.assigns
        sig = (socket.assigns.history_sig || 0) + 1
        read_offset = if loading_more?, do: offset, else: 0

        read_opts = %{
          kind: socket.assigns.history_kind,
          project: socket.assigns.history_project,
          query: socket.assigns.history_query,
          status: socket.assigns.history_status,
          offset: read_offset,
          sig: sig
        }

        socket
        |> cancel_async(:history_load)
        |> assign(
          request: request,
          history_sig: sig,
          loading: not loading_more?,
          loading_more: loading_more?,
          error: false
        )
        |> start_async(:history_load, fn ->
          EvoDash.SafeCall.run(fn -> read_history(read_opts.kind, target, node_id, read_opts) end)
        end)
      end
    else
      socket
    end
  end

  defp history_signature(assigns) do
    {assigns.node_id, assigns.target, assigns.history_project, assigns.history_kind,
     assigns.history_query, assigns.history_status, assigns.history_offset}
  end

  defp append_history_page(socket, page) do
    offset = socket.assigns.history_offset + @history_limit

    socket =
      assign(socket,
        older_rows: socket.assigns.older_rows ++ page.rows,
        history_total: page.total,
        history_offset: offset,
        loading: false,
        loading_more: false,
        error: false
      )

    assign(socket, :request, history_signature(socket.assigns))
  end

  # -- reads (always OFF the LiveView process) ------------------------------

  defp read_history("chat", target, node_id, opts) do
    rows =
      case EvoDash.SafeCall.run(fn -> SessionList.load(target) end) do
        {:ok, {:ok, rows}} when is_list(rows) -> rows
        _ -> []
      end
      |> Enum.filter(&chat_project_match?(&1, node_id, target, opts.project))
      |> Enum.filter(&chat_query_match?(&1, opts.query))
      |> Enum.filter(&chat_status_match?(&1, opts.status))
      |> Enum.take(@history_limit)

    %{
      sig: opts.sig,
      rows: Enum.map(rows, &chat_row(&1, node_id)),
      total: length(rows)
    }
  end

  defp read_history(_kind, target, node_id, opts) do
    %{rows: tasks, total: total} =
      NodeContext.list_tasks_page(target,
        limit: @history_limit,
        offset: opts.offset,
        filters: history_filters(opts)
      )

    task_rows =
      for %{id: id} = task <- tasks, task[:type] != :reflect do
        task_row(task, id, node_id)
      end

    %{sig: opts.sig, rows: task_rows, total: total}
  end

  # Blank filters are OMITTED: the store's WHERE builder treats an absent key
  # as "no clause" while `"all"` is its own no-filter literal, so an empty
  # string would match no row at all.
  defp history_filters(opts) do
    []
    |> maybe_filter(:search, opts.query)
    |> maybe_filter(:project_path, opts.project)
    |> maybe_filter(:status, opts.status)
  end

  defp maybe_filter(filters, _key, value) when value in [nil, ""], do: filters
  defp maybe_filter(filters, key, value) when is_binary(value), do: filters ++ [{key, value}]
  defp maybe_filter(filters, _key, _value), do: filters

  defp task_row(task, id, node_id) do
    opts = task[:opts] || []
    title = opts[:objective] || opts[:prompt] || id
    status = task[:status]
    finished? = status in @finished_task_statuses

    %{
      kind: "task",
      id: id,
      title: String.slice(to_string(title), 0, 100),
      status: status,
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
      href: task_row_href(finished?, id, node_id)
    }
  end

  # A finished run is reviewable: `/review/<id>` (node-preserving, so a remote
  # node's review page opens through the remote gate). A live run is focused on
  # the tasks page.
  defp task_row_href(true, id, node_id), do: navigation_path("/review/#{id}", node_id)
  defp task_row_href(false, id, node_id), do: navigation_path("/tasks", node_id, task: id)

  defp chat_row(row, node_id) do
    %{
      kind: "chat",
      id: row.id,
      title: row.title,
      status: row.marker,
      active: row.marker != :ended,
      href: navigation_path("/assistant", node_id, session: row.id)
    }
  end

  defp chat_project_match?(_row, _node_id, _target, project) when project in [nil, ""], do: true

  defp chat_project_match?(row, node_id, target, project) do
    match?(%{path: ^project}, chat_workspace(row.id, node_id, target))
  end

  defp chat_query_match?(_row, query) when query in [nil, ""], do: true

  defp chat_query_match?(row, query) do
    title = if is_binary(row.title), do: row.title, else: ""
    String.contains?(String.downcase(title), String.downcase(query))
  end

  defp chat_status_match?(_row, ""), do: true
  defp chat_status_match?(%{marker: marker}, "awaiting_input"), do: marker == :awaiting_input
  defp chat_status_match?(%{marker: marker}, "running"), do: marker == :running

  defp chat_status_match?(%{marker: marker}, status)
       when status in ["completed", "cancelled", "failed", "ended"],
       do: marker == :ended

  defp chat_status_match?(_row, _status), do: false

  defp chat_workspace(id, node_id, target) do
    case ChatHistory.get_state(id) do
      %{workspace: workspace} = state ->
        unless SessionList.unsent_workbench_draft?(state),
          do: Workspace.restore(workspace, {node_id, target})

      _ ->
        nil
    end
  end

  # -- project-filter options ----------------------------------------------

  defp load_project_options(socket, scope) do
    project = socket.assigns.project

    if connected?(socket) and socket.assigns.project_options_scope != scope do
      socket
      |> cancel_async(:history_projects)
      |> assign(project_options_scope: scope)
      |> start_async(:history_projects, fn -> {scope, project_options(scope, project)} end)
    else
      socket
    end
  end

  defp project_options({_node_id, target}, project) do
    options =
      case EvoDash.SafeCall.run(fn -> NodeContext.projects(target) end) do
        {:ok, projects} when is_list(projects) -> Enum.flat_map(projects, &project_option/1)
        _ -> []
      end

    ensure_project_option(options, project)
  end

  defp project_option(%EvoGit.VCT.Mount{path: path, name: name}) when is_binary(path) do
    [%{path: path, name: option_name(name, path)}]
  end

  defp project_option(%{path: path} = entry) when is_binary(path) do
    [%{path: path, name: option_name(Map.get(entry, :name), path)}]
  end

  defp project_option(_entry), do: []

  defp option_name(name, _path) when is_binary(name) and name != "", do: name
  defp option_name(_name, path), do: Path.basename(path)

  defp ensure_project_option(options, project) when is_binary(project) do
    if Enum.any?(options, &(&1.path == project)) do
      options
    else
      [%{path: project, name: Path.basename(project)} | options]
    end
  end

  defp ensure_project_option(options, _project), do: options

  # The option list is never empty while a project is open, so the select can
  # always show (and keep selected) the project being viewed.
  defp effective_project_options(options, project) when is_list(options) do
    ensure_project_option(options, project)
  end

  defp effective_project_options(_options, project) do
    ensure_project_option([], project)
  end

  # -- recent projects ------------------------------------------------------

  defp recent_projects(hosts, result, project, node_id) do
    entries =
      hosts
      |> Enum.filter(& &1.node)
      |> Enum.flat_map(fn host ->
        Enum.flat_map(result[host.id] || [], fn entry ->
          case project_entry(entry) do
            %{project: normalized, last_opened_at: at} -> [{host, normalized, at}]
            nil -> []
          end
        end)
      end)

    entries =
      entries
      |> Enum.sort_by(&recency_key/1)
      |> ensure_current_project(hosts, project, node_id)

    Enum.map(entries, fn {host, normalized, _last_opened_at} -> {host, normalized} end)
  end

  # Newest first, with an unknown timestamp LAST: the VCT registry already
  # arrives newest-first per host, so a stable sort on the timestamp keeps
  # that order and merging hosts keeps ONE global recency order.
  defp recency_key({_host, _project, %DateTime{} = at}),
    do: {0, -DateTime.to_unix(at, :microsecond)}

  defp recency_key({_host, _project, _at}), do: {1, 0}

  defp project_entry(%EvoGit.VCT.Mount{path: path, name: name, last_opened_at: at})
       when is_binary(path) do
    %{project: %{path: path, name: option_name(name, path)}, last_opened_at: at}
  end

  defp project_entry(%{path: path} = entry) when is_binary(path) do
    %{
      project: %{path: path, name: option_name(Map.get(entry, :name), path)},
      last_opened_at: Map.get(entry, :last_opened_at)
    }
  end

  # A workspace has no OS path (`path: nil`) — it is a grouping point, never a
  # project shortcut.
  defp project_entry(_entry), do: nil

  defp ensure_current_project(entries, _hosts, project, _node_id) when not is_binary(project),
    do: entries

  defp ensure_current_project(entries, hosts, project, node_id) do
    if Enum.any?(entries, fn {_host, entry, _at} -> entry.path == project end) do
      entries
    else
      host = Enum.find(hosts, &(&1.id == node_id)) || %{id: node_id, name: nil, node: nil}
      [{host, %{path: project, name: Path.basename(project)}, nil} | entries]
    end
  end

  defp status_label(status), do: task_status_label(status)

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
end
