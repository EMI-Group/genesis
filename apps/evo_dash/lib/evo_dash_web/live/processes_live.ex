defmodule EvoDashWeb.ProcessesLive do
  @moduledoc """
  Managed-process inspector: every OS execution `EvoGit.ProcessManager` tracks
  on the viewed node — agent tool calls and background jobs — with its live
  resource usage and the operator controls (pause / resume / terminate / kill).

  Node-aware like every other dashboard page: the initial snapshot is fetched
  from `@current_node` and liveness is PUSH-based. `EvoGit.ProcessManager`
  broadcasts on the `EvoGit.PubSub` `"processes"` topic:

    * `{:process_started, execution, node}`
    * `{:process_updated, id, changes, node}`
    * `{:process_exited, execution, node}`
    * `{:process_sample, node, seq, entries}`
    * `{:process_control, id, entry, node}`

  Each event carries the emitting BEAM node and is dropped unless it matches
  the node the user is currently viewing
  (`EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?/2`), so a local and
  a remote dashboard never mix their process tables. There is NO polling: the
  page loads once per node/core-filter change and then applies the broadcasts.

  No LiveView process blocks on an RPC. The initial load runs in a supervised
  task (`EvoDashWeb.ProcessesLive.Load`) inside `EvoDash.SafeCall.run/1` and
  lands as `{:processes_loaded, seq, node, result}`; every control action runs
  through `EvoDashWeb.ProcessesLive.Actions`, which returns values instead of
  raising.

  Filters are URL state (`?status=`, `?kind=`, `?q=`, `?agent_id=`,
  `?task_id=`, plus `node`): status/kind/text are render-time
  (`EvoDashWeb.ProcessesLive.Format.filter/2`), while `agent_id`/`task_id`
  narrow the tracked set itself and therefore refetch.
  """

  use EvoDashWeb, :live_view
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.LiveHooks.NodeAware
  alias EvoDashWeb.ProcessComponents
  alias EvoDashWeb.ProcessesLive.Actions
  alias EvoDashWeb.ProcessesLive.Format
  alias EvoDashWeb.ProcessesLive.Load

  @processes_topic "processes"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, @processes_topic)
    end

    # No load in mount: the node context is not resolved until handle_params/3
    # (the ?node= param lives on the URL), so a mount-time fetch would always
    # query the LOCAL node.
    {:ok,
     assign(socket,
       executions: [],
       executions_loading: false,
       executions_error: nil,
       executions_loaded: false,
       load_seq: 0,
       status_filter: "live",
       kind_filter: "all",
       search_query: "",
       agent_filter: nil,
       task_filter: nil,
       expanded: MapSet.new(),
       confirm: nil,
       confirm_reason: "",
       confirm_error: nil
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # Capture the node + CORE-side filters BEFORE `assign_node/2` so a node or
    # filter change can drop the previous node's rows and any open confirmation
    # modal (a terminate modal opened on one node must never be confirmed
    # against another).
    previous =
      {socket.assigns.current_node, socket.assigns.agent_filter, socket.assigns.task_filter}

    socket =
      socket
      |> NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/processes")
      |> assign(:status_filter, Format.normalize_status_tab(string_param(params["status"])))
      |> assign(:kind_filter, Format.normalize_kind(string_param(params["kind"])))
      |> assign(:search_query, string_param(params["q"]) || "")
      |> assign(:agent_filter, string_param(params["agent_id"]))
      |> assign(:task_filter, string_param(params["task_id"]))

    current =
      {socket.assigns.current_node, socket.assigns.agent_filter, socket.assigns.task_filter}

    socket =
      if current != previous do
        assign(socket, executions: [], executions_loaded: false, confirm: nil)
      else
        socket
      end

    cond do
      # The disconnected (static HTTP) render's async result is discarded, so
      # only the connected pass issues an RPC; the static HTML still paints the
      # loading placeholder so both renders match.
      not connected?(socket) ->
        {:noreply, assign(socket, :executions_loading, true)}

      socket.assigns.executions_loaded ->
        {:noreply, socket}

      true ->
        {:noreply, Load.start(socket)}
    end
  end

  # ---------------------------------------------------------------------------
  # Load result
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:processes_loaded, seq, node, result}, socket) do
    # Stale guards: a later load (filter/node change) bumps :load_seq, and a
    # node switch changes :current_node — either way the answer is obsolete.
    if seq != socket.assigns.load_seq or node != socket.assigns.current_node do
      {:noreply, socket}
    else
      {:noreply, apply_load_result(socket, result)}
    end
  end

  # ---------------------------------------------------------------------------
  # "processes" PubSub events (node-filtered, never a poll)
  # ---------------------------------------------------------------------------

  def handle_info({:process_started, execution, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, update_executions(socket, &prepend_execution(&1, execution))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:process_updated, id, changes, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and is_map(changes) do
      {:noreply, update_executions(socket, &update_execution(&1, id, changes))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:process_exited, execution, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, update_executions(socket, &put_execution(&1, execution))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:process_sample, node, _seq, entries}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, update_executions(socket, &apply_sample(&1, entries))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:process_control, id, entry, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and is_map(entry) do
      {:noreply, update_executions(socket, &append_control_entry(&1, id, entry))}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Node-context plumbing (NodeAware owns the resolution)
  # ---------------------------------------------------------------------------

  def handle_info({:node_selected, node_id}, socket) do
    NodeAware.handle_node_selected(socket, node_id)
  end

  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    NodeAware.handle_connection_status(socket, msg)
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Row expansion + reversible controls
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_process_row", params, socket) do
    case id_param(params) do
      nil -> {:noreply, socket}
      id -> {:noreply, assign(socket, :expanded, toggle_expanded(socket.assigns.expanded, id))}
    end
  end

  def handle_event("pause_process", params, socket) do
    {:noreply, run_reversible_control(socket, params, :pause)}
  end

  def handle_event("resume_process", params, socket) do
    {:noreply, run_reversible_control(socket, params, :resume)}
  end

  def handle_event("open_terminate", params, socket) do
    {:noreply, open_confirm(socket, params, :terminate)}
  end

  def handle_event("open_kill", params, socket) do
    {:noreply, open_confirm(socket, params, :kill)}
  end

  def handle_event("close_confirm", _params, socket) do
    {:noreply, assign(socket, confirm: nil, confirm_reason: "", confirm_error: nil)}
  end

  def handle_event("confirm_control", %{"reason" => reason}, socket) do
    {:noreply, confirm_control(socket, reason)}
  end

  def handle_event("confirm_control", _params, socket) do
    {:noreply, confirm_control(socket, "")}
  end

  def handle_event("retry", _params, socket) do
    {:noreply, Load.start(socket)}
  end

  # ---------------------------------------------------------------------------
  # Filter events — every one is a push_patch, so the URL stays the state
  # ---------------------------------------------------------------------------

  def handle_event("set_status", %{"status" => status}, socket) do
    {:noreply,
     push_patch(socket, to: filters_url(socket, %{status: Format.normalize_status_tab(status)}))}
  end

  def handle_event("set_kind", %{"kind" => kind}, socket) do
    {:noreply, push_patch(socket, to: filters_url(socket, %{kind: Format.normalize_kind(kind)}))}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, push_patch(socket, to: filters_url(socket, %{q: query}))}
  end

  def handle_event("remove_agent_filter", _params, socket) do
    {:noreply, push_patch(socket, to: filters_url(socket, %{agent_id: nil}))}
  end

  def handle_event("remove_task_filter", _params, socket) do
    {:noreply, push_patch(socket, to: filters_url(socket, %{task_id: nil}))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    filters = filters(assigns)
    # Tab counts are computed over every OTHER dimension so the three numbers
    # stay stable while the operator switches tabs.
    counts = Format.counts(Format.filter(assigns.executions, Map.delete(filters, :status)))

    assigns =
      assigns
      |> assign(:filtered, Format.filter(assigns.executions, filters))
      |> assign(:counts, counts)

    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:processes}
      config_status={@config_status}
      current_node_id={@current_node_id}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      pending_tasks={@pending_tasks}
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
      accent_color={assigns[:accent_color] || "blue"}
    >
      <%= if EvoDashWeb.RemoteGateComponents.gate_active?(assigns) do %>
        {EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns)}
      <% else %>
        <div class="mb-4">
          <h1 class="text-xl font-semibold text-base-content">{gettext("Processes")}</h1>
          <p class="text-sm text-base-content/60 mt-0.5">
            {gettext(
              "Operating-system processes Genesis tracks on this node — tool calls and background jobs — with their resource usage and operator controls."
            )}
          </p>
        </div>

        <!-- Filter bar -->
        <div class="rounded-lg border border-base-300 bg-base-100 p-3 sm:p-4 mb-4">
          <div class="flex flex-col lg:flex-row lg:items-center gap-3">
            <div class="flex items-center gap-1 bg-base-200/50 rounded-lg p-1 overflow-x-auto shrink-0">
              <button
                :for={tab <- Format.status_tabs()}
                type="button"
                phx-click="set_status"
                phx-value-status={tab}
                class={[
                  "px-3 py-1.5 rounded-md text-sm font-medium cursor-pointer transition-colors whitespace-nowrap",
                  @status_filter == tab && "bg-base-100 shadow-sm text-base-content",
                  @status_filter != tab &&
                    "hover:bg-base-200/80 text-base-content/70 hover:text-base-content"
                ]}
                aria-current={if @status_filter == tab, do: "page", else: false}
              >
                {status_tab_label(tab)}
                <span class="ml-1 text-xs text-base-content/60">{status_tab_count(@counts, tab)}</span>
              </button>
            </div>

            <form id="process-kind-filter" phx-change="set_kind" class="form-control">
              <select
                name="kind"
                class="select select-sm select-bordered rounded-md bg-base-100 sm:w-44"
                aria-label={gettext("Process kind")}
              >
                <option value="all" selected={@kind_filter == "all"}>
                  {gettext("All kinds")}
                </option>
                <option value="tool_call" selected={@kind_filter == "tool_call"}>
                  {gettext("Tool calls")}
                </option>
                <option value="background_job" selected={@kind_filter == "background_job"}>
                  {gettext("Background jobs")}
                </option>
              </select>
            </form>

            <form id="process-search" phx-change="search" phx-debounce="200" class="flex-1 min-w-0">
              <input
                type="search"
                name="q"
                value={@search_query}
                placeholder={gettext("Search command, tool, agent or task id…")}
                class="input input-sm input-bordered rounded-md w-full"
                aria-label={gettext("Search processes")}
              />
            </form>
          </div>

          <!-- Active core-side filters -->
          <div
            :if={@agent_filter != nil or @task_filter != nil}
            class="flex items-center flex-wrap gap-2 mt-3 pt-3 border-t border-base-300"
          >
            <span class="text-xs text-base-content/70">{gettext("Filters:")}</span>
            <span
              :if={@agent_filter != nil}
              class="badge badge-sm badge-ghost gap-1 rounded-md font-mono"
            >
              {gettext("Agent")} {@agent_filter}
              <button
                type="button"
                phx-click="remove_agent_filter"
                class="cursor-pointer hover:opacity-70"
                aria-label={gettext("Remove agent filter")}
              >
                ×
              </button>
            </span>
            <span
              :if={@task_filter != nil}
              class="badge badge-sm badge-ghost gap-1 rounded-md font-mono"
            >
              {gettext("Task")} {@task_filter}
              <button
                type="button"
                phx-click="remove_task_filter"
                class="cursor-pointer hover:opacity-70"
                aria-label={gettext("Remove task filter")}
              >
                ×
              </button>
            </span>
          </div>
        </div>

        <!-- First-load placeholder -->
        <div :if={@executions_loading and @executions == []} class="text-center py-12 sm:py-16">
          <.icon
            name="hero-arrow-path"
            class="size-10 mx-auto mb-4 text-base-content/40 animate-spin"
          />
          <p class="text-lg font-medium text-base-content/70">{gettext("Loading processes...")}</p>
        </div>

        <!-- Load failure with nothing to show -->
        <div
          :if={@executions_error != nil and @executions == [] and not @executions_loading}
          id="processes-load-error"
          role="alert"
          class="text-center py-12 sm:py-16"
        >
          <.icon name="hero-exclamation-triangle" class="size-10 mx-auto mb-4 text-error/70" />
          <p class="text-lg font-medium text-error">{gettext("Could not load processes.")}</p>
          <p class="text-xs text-base-content/60 mt-1 font-mono break-all">{@executions_error}</p>
          <button type="button" class="btn btn-sm btn-ghost mt-3 text-error" phx-click="retry">
            <.icon name="hero-arrow-path" class="size-3.5" /> {gettext("Retry")}
          </button>
        </div>

        <!-- Background-refresh failure: the loaded rows stay on screen -->
        <div
          :if={@executions_error != nil and @executions != []}
          id="processes-refresh-error"
          role="alert"
          class="mb-3 flex items-center justify-between gap-3 rounded-lg border border-error/20 bg-error/10 px-3 py-2 text-sm text-error"
        >
          <span class="flex items-center gap-2 min-w-0">
            <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
            <span class="truncate">{gettext("Could not refresh processes.")}</span>
          </span>
          <button type="button" class="btn btn-sm btn-ghost text-error" phx-click="retry">
            <.icon name="hero-arrow-path" class="size-3.5" /> {gettext("Retry")}
          </button>
        </div>

        <!-- Empty state, per tab -->
        <div
          :if={
            @filtered == [] and not @executions_loading and
              (@executions_error == nil or @executions != [])
          }
          id="processes-empty"
          class="text-center py-12 sm:py-16 text-base-content/70"
        >
          <.icon name="hero-cpu-chip" class="size-10 mx-auto mb-4 text-base-content/40" />
          <p class="text-lg font-medium">{empty_message(@status_filter)}</p>
          <p
            :if={@agent_filter != nil or @task_filter != nil or @search_query != ""}
            class="text-sm mt-1"
          >
            {gettext("Try clearing a filter or the search query.")}
          </p>
        </div>

        <!-- Process table (newest first, as the core returns them) -->
        <div
          :if={@filtered != []}
          class="overflow-x-auto rounded-lg border border-base-300 bg-base-100"
        >
          <table class="table table-sm">
            <thead>
              <tr class="text-xs text-base-content/60">
                <th>{gettext("Status")}</th>
                <th>{gettext("Agent")}</th>
                <th>{gettext("Task")}</th>
                <th>{gettext("Command")}</th>
                <th>{gettext("Runtime")}</th>
                <th>{gettext("Backend")}</th>
                <th>{gettext("Target")}</th>
                <th>{gettext("Uptime")}</th>
                <th class="text-right">{gettext("CPU")}</th>
                <th class="text-right">{gettext("Memory")}</th>
                <th class="text-right">{gettext("Exit")}</th>
                <th class="text-right">{gettext("Actions")}</th>
              </tr>
            </thead>
            <tbody>
              <ProcessComponents.execution_row
                :for={execution <- @filtered}
                execution={execution}
                expanded={MapSet.member?(@expanded, Format.id_string(Map.get(execution, :id)))}
                node_id={@current_node_id}
              />
            </tbody>
          </table>
        </div>

        <ProcessComponents.confirm_modal
          :if={@confirm != nil}
          confirm={@confirm}
          reason={@confirm_reason}
          error={@confirm_error}
        />
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Load results
  # ---------------------------------------------------------------------------

  defp apply_load_result(socket, {:ok, executions}) when is_list(executions) do
    assign(socket,
      executions: executions,
      executions_loaded: true,
      executions_loading: false,
      executions_error: nil
    )
  end

  defp apply_load_result(socket, {:ok, other}) do
    apply_load_result(socket, {:error, {:invalid_result, other}})
  end

  defp apply_load_result(socket, {:error, reason}) do
    assign(socket,
      executions_loading: false,
      executions_error: Format.term_text(reason)
    )
  end

  defp apply_load_result(socket, other) do
    apply_load_result(socket, {:error, {:invalid_result, other}})
  end

  # ---------------------------------------------------------------------------
  # Execution-list updates (pure helpers over the socket's :executions)
  # ---------------------------------------------------------------------------

  defp update_executions(socket, fun) when is_function(fun, 1) do
    case Map.get(socket.assigns, :executions) do
      list when is_list(list) -> assign(socket, :executions, fun.(list))
      _other -> assign(socket, :executions, fun.([]))
    end
  end

  # A newly tracked process joins the head (the list is newest first); a repeat
  # broadcast for an already-known id is dropped.
  defp prepend_execution(executions, execution) do
    id = Map.get(execution, :id)

    if id != nil and find_execution(executions, id) != nil do
      executions
    else
      [execution | executions]
    end
  end

  # Exit: the record is complete, so replace it in place (or prepend it when the
  # page never saw it start — e.g. a process spawned before this page opened).
  defp put_execution(executions, execution) do
    id = Map.get(execution, :id)

    cond do
      id == nil -> executions
      find_execution(executions, id) == nil -> [execution | executions]
      true -> Enum.map(executions, fn row -> if same_id?(row, id), do: execution, else: row end)
    end
  end

  # `{:process_updated, id, changes}` carries only the changed fields.
  defp update_execution(executions, id, changes) do
    Enum.map(executions, fn execution ->
      if same_id?(execution, id), do: merge_changes(execution, changes), else: execution
    end)
  end

  # `{:process_sample, node, seq, entries}` is a batch of resource samples:
  # only :status / :stats are applied, and only to rows the page already shows
  # (an unknown id is a process from another filter, not a new row).
  defp apply_sample(executions, entries) when is_list(executions) do
    case sample_updates(entries) do
      updates when map_size(updates) == 0 ->
        executions

      updates ->
        Enum.map(executions, fn execution ->
          case Map.get(updates, Map.get(execution, :id)) do
            nil -> execution
            changes -> merge_changes(execution, changes)
          end
        end)
    end
  end

  defp apply_sample(executions, _entries), do: executions

  defp sample_updates(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      id = Format.entry_get(entry, :id)

      if id == nil do
        acc
      else
        changes =
          %{}
          |> put_present(:status, Format.entry_get(entry, :status))
          |> put_present(:stats, Format.entry_get(entry, :stats))

        if map_size(changes) == 0, do: acc, else: Map.put(acc, id, changes)
      end
    end)
  end

  defp sample_updates(_entries), do: %{}

  # `{:process_control, id, entry}` appends the operator action to that row's
  # control log. The broadcast reaches every viewer, INCLUDING the page whose
  # click caused it (the control answer carries no log entry), so the dedupe
  # guard keeps a redelivery from showing the same action twice.
  defp append_control_entry(executions, id, entry) do
    Enum.map(executions, fn execution ->
      log = existing_control_log(execution)

      cond do
        not same_id?(execution, id) -> execution
        duplicate_entry?(log, entry) -> execution
        true -> put_control_log(execution, log ++ [entry])
      end
    end)
  end

  defp existing_control_log(execution) do
    case Map.get(execution, :control_log) do
      entries when is_list(entries) -> entries
      _other -> []
    end
  end

  defp duplicate_entry?(log, entry) do
    case List.last(log) do
      %{} = newest ->
        Format.entry_get(newest, :at) == Format.entry_get(entry, :at) and
          Format.entry_get(newest, :action) == Format.entry_get(entry, :action)

      _other ->
        false
    end
  end

  defp put_control_log(execution, log) when is_struct(execution) do
    if Map.has_key?(execution, :control_log) do
      Map.replace!(execution, :control_log, log)
    else
      execution
    end
  end

  defp put_control_log(execution, log) when is_map(execution),
    do: Map.put(execution, :control_log, log)

  defp merge_changes(execution, changes) when is_struct(execution) do
    Enum.reduce(changes, execution, fn
      {key, value}, acc when is_atom(key) ->
        if Map.has_key?(acc, key), do: Map.replace!(acc, key, value), else: acc

      _other, acc ->
        acc
    end)
  end

  defp merge_changes(execution, changes) when is_map(execution) and is_map(changes),
    do: Map.merge(execution, changes)

  defp merge_changes(execution, _changes), do: execution

  defp find_execution(executions, id) when is_list(executions) do
    Enum.find(executions, fn execution -> same_id?(execution, id) end)
  end

  defp find_execution(_executions, _id), do: nil

  # Ids cross the boundary as native terms (the page's own DOM values are
  # strings), so comparison goes through the shared string form.
  defp same_id?(execution, id) when is_map(execution) do
    Format.id_string(Map.get(execution, :id)) == Format.id_string(id)
  end

  defp same_id?(_execution, _id), do: false

  # ---------------------------------------------------------------------------
  # Control actions
  # ---------------------------------------------------------------------------

  defp run_reversible_control(socket, params, action) do
    case id_param(params) do
      nil ->
        socket

      id ->
        result =
          Actions.control(
            socket.assigns.current_node,
            id,
            action,
            Actions.default_reason(action)
          )

        {kind, message} = Actions.result_message(action, result)
        put_flash(socket, kind, message)
    end
  end

  defp open_confirm(socket, params, action) do
    case id_param(params) do
      nil ->
        socket

      id ->
        execution = find_execution(socket.assigns.executions, id) || %{id: id}

        assign(socket,
          confirm: %{id: id, action: action, execution: execution},
          confirm_reason: "",
          confirm_error: nil
        )
    end
  end

  defp confirm_control(socket, reason) do
    case socket.assigns.confirm do
      %{id: id, action: action} when action in [:terminate, :kill] ->
        case Actions.validate_reason(reason) do
          :blank ->
            message = gettext("A reason is required.")

            socket
            |> assign(:confirm_error, message)
            |> put_flash(:error, message)

          :ok ->
            trimmed = String.trim(reason)

            result =
              Actions.control(
                socket.assigns.current_node,
                id,
                control_action(action),
                trimmed
              )

            {kind, message} = Actions.result_message(action, result)
            socket = put_flash(socket, kind, message)

            case result do
              :ok ->
                assign(socket, confirm: nil, confirm_reason: "", confirm_error: nil)

              {:error, _reason} ->
                # The modal stays open with the operator's text preserved and the
                # failure shown in place, so a retry needs no retyping.
                assign(socket, :confirm_error, message)
            end
        end

      _other ->
        socket
    end
  end

  # Terminate asks politely (TERM); Kill is the destructive escalation.
  defp control_action(:kill), do: :kill
  defp control_action(_action), do: {:signal, "TERM"}

  # ---------------------------------------------------------------------------
  # Filters + URL state
  # ---------------------------------------------------------------------------

  defp filters(assigns) do
    %{
      status: Map.get(assigns, :status_filter),
      kind: Map.get(assigns, :kind_filter),
      q: Map.get(assigns, :search_query),
      agent_id: Map.get(assigns, :agent_filter),
      task_id: Map.get(assigns, :task_filter)
    }
  end

  # Rebuilds /processes from the current filters overlaid with `overrides`.
  # Because this page always carries a query string, `node` is appended with
  # "&" by hand — `EvoDashWeb.Helpers.with_node_param/2` appends "?" and would
  # produce a broken URL here.
  defp filters_url(socket, overrides) do
    filters = %{
      status: override(overrides, :status, socket.assigns.status_filter),
      kind: override(overrides, :kind, socket.assigns.kind_filter),
      q: override(overrides, :q, socket.assigns.search_query),
      agent_id: override(overrides, :agent_id, socket.assigns.agent_filter),
      task_id: override(overrides, :task_id, socket.assigns.task_filter)
    }

    query =
      filters
      |> Enum.reject(fn {key, value} -> blank?(value) or (key == :kind and value == "all") end)
      |> URI.encode_query()

    path = ~p"/processes"
    base = if query == "", do: path, else: path <> "?" <> query

    append_node_param(base, Map.get(socket.assigns, :current_node_id))
  end

  defp override(overrides, key, default), do: Map.get(overrides, key, default)

  defp append_node_param(url, node_id) when is_binary(node_id) and node_id != "" do
    # `node` is a VCT/connection target id (a slug), so form encoding is enough
    # and keeps the URL parseable by the node-aware hook.
    encoded = URI.encode_www_form(node_id)

    if String.contains?(url, "?"),
      do: url <> "&node=" <> encoded,
      else: url <> "?node=" <> encoded
  end

  defp append_node_param(url, _node_id), do: url

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  # ---------------------------------------------------------------------------
  # Param readers (total: a malformed/missing value is nil)
  # ---------------------------------------------------------------------------

  defp string_param(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_param(_value), do: nil

  defp id_param(params) when is_map(params) do
    case Map.get(params, "id") do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp id_param(_params), do: nil

  defp toggle_expanded(expanded, id) do
    if MapSet.member?(expanded, id) do
      MapSet.delete(expanded, id)
    else
      MapSet.put(expanded, id)
    end
  end

  # ---------------------------------------------------------------------------
  # Render helpers
  # ---------------------------------------------------------------------------

  defp status_tab_label("live"), do: gettext("Live")
  defp status_tab_label("finished"), do: gettext("Finished")
  defp status_tab_label(_tab), do: gettext("All")

  defp status_tab_count(counts, "live"), do: Map.get(counts, :live, 0)
  defp status_tab_count(counts, "finished"), do: Map.get(counts, :finished, 0)
  defp status_tab_count(counts, _tab), do: Map.get(counts, :all, 0)

  defp empty_message("live"), do: gettext("No live processes.")
  defp empty_message("finished"), do: gettext("No finished processes.")
  defp empty_message(_tab), do: gettext("No processes match these filters.")

  # Kept for the `:stats` sample shape: only present values are merged, so a
  # partial sample never blanks a field the page already shows.
  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
