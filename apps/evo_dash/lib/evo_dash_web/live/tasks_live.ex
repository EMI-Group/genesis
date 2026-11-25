defmodule EvoDashWeb.TasksLive do
  @moduledoc """
  Cross-project task list with filtering by status, project, and review state.

  Node-aware: reads task history via `EvoDash.NodeContext` so it works for both
  the local BEAM node and a remote `genesis_remote` daemon (SSH Remote
  Development, Phase 3). Change detection is fully push-based: `:evo_git`
  broadcasts `{:task_updated, task_id, status, node}` and
  `{:task_deleted, task_id, node}` on the `EvoGit.PubSub` "tasks" topic;
  `NodeAware.handle_task_info/2` applies the node filter and schedules a
  debounced `:node_aware_reload_tasks` full-page reload.

  No LiveView process blocks on a store/RPC call: every page load runs in a
  supervised task (`EvoDashWeb.TasksLive.PageLoad`) behind
  `EvoDash.SafeCall.run/1`, and its result arrives as
  `{:tasks_page_loaded, seq, node, result}`. An exit (store timeout / dead
  store) becomes a retry-able `:tasks_error` state, and the user-initiated
  mutating events are SafeCall-wrapped so an exit flashes instead of crashing
  the LiveView.

  The page load transfers the LIGHTWEIGHT summary projection only (no `result`
  / `usage` / `logs` / `archive_metadata`). The heavy data is fetched per card,
  on demand, by `EvoDashWeb.TasksLive.TaskDetail` (lite detail + archive),
  which owns the bounded `:task_details` cache and its `:task_detail_seq`
  stale-guard.

  ## Interactive sessions

  A task can be an INTERACTIVE agent session parked at the non-terminal
  `:awaiting_input` status (violet family): the agent is idle, waiting for the
  user's next message. The page load reports
  `awaiting_sessions: %{task_id => agent_id}`; an idle session's card posts a
  message (`NodeContext.send_session_message/4`) or closes the session
  (`NodeContext.close_session/3`, the only non-cancellation way out) through
  this page. `:session_mode_filter` (`all`/`oneshot`/`interactive`) travels in
  the `filters` keyword list the page loader builds, and the core's shared
  WHERE builder applies it
  (`EvoGit.Store.Operations.Filters.where_session_mode_filter/2`), so it is a
  real SQL predicate beside status/project/review/search — never an in-memory
  post-filter.
  """
  use EvoDashWeb, :live_view
  use Gettext, backend: EvoDashWeb.Gettext
  use EvoDashWeb.ModalHelpers

  alias EvoDash.SafeCall
  alias EvoDashWeb.TasksLive.PageLoad
  alias EvoDashWeb.TasksLive.TaskDetail

  @default_page_size 25

  # The filter vocabulary, in lifecycle order, whitelisted on the way IN
  # (`handle_params/3`, from the query string) and on the way OUT (`tasks_url/3`
  # and the select options). The status strings ARE the stored status TEXT, so
  # nothing is atomized; `needs_review` is DERIVED, not stored (see
  # `PageLoad.needs_review_filter?/1`).
  @status_filters ~w(
    all running pending finalizing cancelling awaiting_input pausing paused
    completed failed cancelled needs_review
  )
  @review_filters ~w(all pending merged rejected continued)
  @session_filters ~w(all oneshot interactive)

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:tasks}
      config_status={@config_status}
      current_node_id={@current_node_id}
      remote_targets={assigns[:remote_targets] || []}
      connection_statuses={assigns[:connection_statuses] || %{}}
      workbench_project={@workbench_project}
      workbench_git_project={
        if @current_node_id || !@workbench_remote_requested, do: @workbench_project
      }
      workbench_task={@focused_task_id}
      workbench_title={@workbench_title}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      session_list={assigns[:session_list] || []}
      session_list_loading={assigns[:session_list_loading] == true}
      session_list_error={assigns[:session_list_error]}
      current_session_id={assigns[:current_session_id]}
      pending_tasks={@pending_tasks}
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
      accent_color={assigns[:accent_color] || "blue"}
    >
      <%= if EvoDashWeb.RemoteGateComponents.gate_active?(assigns) do %>
        {EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns)}
      <% else %>
        <h1 :if={!@focused_task_id} class="text-xl font-semibold mb-4">
          {gettext("Task History")}
        </h1>
        <div
          :if={!@focused_task_id}
          class="rounded-lg border border-base-300 bg-base-100 p-3 sm:p-4 mb-4"
        >
          <form id="task-filters" phx-submit="noop">
            <div class="task-history-filters">
              <!-- Status Filter -->
              <div class="form-control">
                <select
                  name="status_filter"
                  aria-label={gettext("Status")}
                  class="select select-bordered select-sm w-full min-w-0"
                  phx-change="filter_tasks"
                >
                  <option value="all" selected={@status_filter == "all"}>
                    {gettext("All Statuses")}
                  </option>
                  <option value="running" selected={@status_filter == "running"}>
                    {gettext("Running")}
                  </option>
                  <option value="pending" selected={@status_filter == "pending"}>
                    {gettext("Pending")}
                  </option>
                  <option value="finalizing" selected={@status_filter == "finalizing"}>
                    <%!-- zh_CN: 正在收尾（生成结果/归档中，不可取消） --%>
                    {gettext("Finalizing")}
                  </option>
                  <option value="cancelling" selected={@status_filter == "cancelling"}>
                    {gettext("Cancelling")}
                  </option>
                  <option value="awaiting_input" selected={@status_filter == "awaiting_input"}>
                    <%!-- zh_CN: 等待输入（交互式会话空闲） --%>
                    {gettext("Awaiting Input")}
                  </option>
                  <%!-- The pause statuses ride the store's exact-TEXT status
                       filter unchanged ("pausing"/"paused" are the stored
                       status strings) — no atom conversion anywhere. --%>
                  <option value="pausing" selected={@status_filter == "pausing"}>
                    <%!-- zh_CN: 正在暂停（等当前工具调用结束后停止） --%>
                    {gettext("Pausing")}
                  </option>
                  <option value="paused" selected={@status_filter == "paused"}>
                    <%!-- zh_CN: 已暂停（非终态，可恢复） --%>
                    {gettext("Paused")}
                  </option>
                  <option value="completed" selected={@status_filter == "completed"}>
                    {gettext("Completed")}
                  </option>
                  <option value="failed" selected={@status_filter == "failed"}>
                    {gettext("Failed")}
                  </option>
                  <option value="cancelled" selected={@status_filter == "cancelled"}>
                    {gettext("Cancelled")}
                  </option>
                  <%!-- Derived REVIEW-TRIAGE option, not a stored status: the
                       store selects completed + undecided + branch-bearing
                       tasks (PageLoad.filters/1 emits status "all" plus
                       review_status "pending"). --%>
                  <option value="needs_review" selected={@status_filter == "needs_review"}>
                    <%!-- zh_CN: 待审阅：已完成但尚未做出评审决定的任务 --%>
                    {gettext("Needs review")}
                  </option>
                </select>
              </div>

              <!-- Session Kind Filter (applied server-side by the page loader) -->
              <div class="form-control">
                <select
                  name="session_mode_filter"
                  aria-label={gettext("All task kinds")}
                  class="select select-bordered select-sm w-full min-w-0"
                  phx-change="filter_session_mode"
                >
                  <option value="all" selected={@session_mode_filter == "all"}>
                    {gettext("All task kinds")}
                  </option>
                  <option value="oneshot" selected={@session_mode_filter == "oneshot"}>
                    <%!-- zh_CN: 一次性任务 --%>
                    {gettext("One-shot tasks")}
                  </option>
                  <option value="interactive" selected={@session_mode_filter == "interactive"}>
                    <%!-- zh_CN: 交互式会话 --%>
                    {gettext("Interactive sessions")}
                  </option>
                </select>
              </div>

              <!-- Project Filter -->
              <div class="form-control">
                <select
                  name="project_filter"
                  aria-label={gettext("All Projects")}
                  class="select select-bordered select-sm w-full min-w-0"
                  phx-change="filter_tasks"
                >
                  <option value="all" selected={@project_filter == "all"}>
                    {gettext("All Projects")}
                  </option>
                  <%= for path <- @project_paths do %>
                    <option value={path} selected={@project_filter == path}>
                      {Path.basename(path)} ({String.slice(path, 0, 30)}...)
                    </option>
                  <% end %>
                </select>
              </div>

              <!-- Review Status Filter -->
              <div class="form-control">
                <select
                  name="review_filter"
                  aria-label={gettext("All Reviews")}
                  class="select select-bordered select-sm w-full min-w-0"
                  phx-change="filter_review"
                >
                  <option value="all" selected={@review_status_filter == "all"}>
                    {gettext("All Reviews")}
                  </option>
                  <option value="pending" selected={@review_status_filter == "pending"}>
                    {gettext("Pending Review")}
                  </option>
                  <option value="merged" selected={@review_status_filter == "merged"}>
                    {gettext("Merged")}
                  </option>
                  <option value="rejected" selected={@review_status_filter == "rejected"}>
                    {gettext("Rejected")}
                  </option>
                  <option value="continued" selected={@review_status_filter == "continued"}>
                    {gettext("Continued")}
                  </option>
                </select>
              </div>
            </div>
            <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-2">
              <div class="min-w-0 grow basis-56">
                <div class="relative">
                  <.icon
                    name="hero-magnifying-glass"
                    class="absolute left-3 top-1/2 -translate-y-1/2 size-4 text-base-content/60 pointer-events-none z-10"
                  />
                  <%!-- 搜索结果同时匹配 agent 的最终回复消息 --%>
                  <input
                    type="text"
                    name="search_query"
                    aria-label={gettext("Search by task ID, prompt, objective, or response...")}
                    value={@search_query}
                    class="input input-bordered input-sm pl-9 w-full"
                    placeholder={gettext("Search by task ID, prompt, objective, or response...")}
                    phx-change="search_tasks"
                    phx-debounce="200"
                  />
                </div>
              </div>

              <!-- Actions -->
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                <%!-- 勾选后显示 Home 聊天页(自省智能体, :reflect 仓库外聊天任务)产生的聊天任务 --%>
                <label class="label cursor-pointer gap-2">
                  <input
                    type="checkbox"
                    name="show_reflect_tasks"
                    value="true"
                    checked={@show_reflect_tasks}
                    phx-change="toggle_reflect_tasks"
                    class="checkbox checkbox-sm"
                  />
                  <span class="label-text whitespace-nowrap">{gettext("Show chat tasks")}</span>
                </label>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm"
                  phx-click="reset_filters"
                  title={gettext("Reset all filters")}
                >
                  <.icon name="hero-x-mark" class="size-4" /> {gettext("Reset")}
                </button>
              </div>
            </div>
          </form>

          <!-- Active filters indicator -->
          <%= if @status_filter != "all" or @project_filter != "all" or @search_query != "" or @review_status_filter != "all" or @session_mode_filter != "all" do %>
            <div class="flex flex-wrap items-center gap-2 mt-3 pt-3 border-t border-base-300">
              <span class="text-xs text-base-content/70">{gettext("Active filters:")}</span>
              <%= if @status_filter != "all" do %>
                <span class="badge badge-primary gap-1 rounded-md">
                  {status_filter_label(@status_filter)}
                  <button
                    phx-click="clear_filter"
                    phx-value-filter="status"
                    class="cursor-pointer hover:opacity-70"
                  >×</button>
                </span>
              <% end %>
              <%= if @project_filter != "all" do %>
                <span class="badge badge-secondary gap-1 rounded-md">
                  {Path.basename(@project_filter)}
                  <button
                    phx-click="clear_filter"
                    phx-value-filter="project"
                    class="cursor-pointer hover:opacity-70"
                  >×</button>
                </span>
              <% end %>
              <%= if @search_query != "" do %>
                <span class="badge badge-accent gap-1 rounded-md">
                  "{String.slice(@search_query, 0, 20)}{if String.length(@search_query) > 20,
                    do: "..."}"
                  <button
                    phx-click="clear_filter"
                    phx-value-filter="search"
                    class="cursor-pointer hover:opacity-70"
                  >×</button>
                </span>
              <% end %>
              <%= if @review_status_filter != "all" do %>
                <span class="badge badge-accent gap-1 rounded-md">
                  <%= case @review_status_filter do %>
                    <% "pending" -> %>
                      {gettext("Pending Review")}
                    <% "merged" -> %>
                      {gettext("Merged")}
                    <% "rejected" -> %>
                      {gettext("Rejected")}
                    <% "continued" -> %>
                      {gettext("Continued")}
                    <% _ -> %>
                      {@review_status_filter}
                  <% end %>
                  <button
                    phx-click="clear_filter"
                    phx-value-filter="review"
                    class="cursor-pointer hover:opacity-70"
                  >×</button>
                </span>
              <% end %>
              <%= if @session_mode_filter != "all" do %>
                <span class="badge badge-primary gap-1 rounded-md">
                  {session_mode_label(@session_mode_filter)}
                  <button
                    phx-click="clear_filter"
                    phx-value-filter="session_mode"
                    class="cursor-pointer hover:opacity-70"
                  >×</button>
                </span>
              <% end %>
            </div>
          <% end %>
        </div>

        <!-- Task Count (hidden while a load is in flight — otherwise the stale
           count flashes "0 tasks found" during every filter/navigation; also
           hidden when a failed load left no rows at all, where the count would
           contradict the error block below) -->
        <%= if !@focused_task_id and not @tasks_loading and not (@tasks_error != nil and @filtered_tasks == []) do %>
          <div class="flex items-center justify-between mb-4">
            <p class="text-sm text-base-content/60">
              {count_line(@status_filter, length(@filtered_tasks))}
            </p>
          </div>
        <% end %>

        <!-- Background-refresh failure: the already-loaded rows stay on screen,
           so only a compact retry strip is added above the list. -->
        <%= if @tasks_error != nil and @filtered_tasks != [] do %>
          <div
            id="tasks-refresh-error"
            role="alert"
            class="mb-4 flex items-center justify-between gap-3 rounded-lg border border-error/20 bg-error/10 px-3 py-2 text-sm text-error"
          >
            <span class="flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="size-4" />
              {gettext("Could not refresh tasks.")}
            </span>
            <button type="button" class="btn btn-sm btn-ghost text-error" phx-click="retry_load">
              <.icon name="hero-arrow-path" class="size-3.5" /> {gettext("Retry")}
            </button>
          </div>
        <% end %>

        <!-- Non-first load (a filter / search / pagination / session-kind
           change with rows already on screen): the loaded rows stay mounted and
           this thin inline line is the only loading affordance. Setting
           `@tasks_refreshing` (never `@tasks_loading`) is what keeps the list
           from blanking on every keystroke. -->
        <div
          :if={@tasks_refreshing}
          id="tasks-refreshing"
          role="status"
          aria-live="polite"
          class="mb-4 flex items-center gap-2 text-xs text-base-content/60"
        >
          <span class="loading loading-spinner loading-xs" aria-hidden="true"></span>
          {gettext("Refreshing tasks…")}
        </div>

        <!-- Task List. The `ListEnter` hook animates only genuinely NEW row keys
           within one unchanged `data-list-enter-scope` (a filter/page/node change
           reseeds its silent baseline). The rows themselves live in the keyed
           stream container below, so an update patches ONE card. -->
        <div
          id="tasks-list"
          phx-hook="ListEnter"
          data-list-enter-scope={list_enter_scope(assigns)}
        >
          <%= if @tasks_loading do %>
            <%!-- FIRST load only (nothing on screen yet): daisyUI skeleton rows
                 stand in for the cards. The "Loading tasks..." text stays as the
                 accessible label (and the suite's load-finished marker). --%>
            <div id="tasks-loading" role="status" aria-live="polite" class="space-y-4">
              <span class="sr-only">{gettext("Loading tasks...")}</span>
              <%= for _ <- 1..3 do %>
                <div class="rounded-lg border border-base-300 bg-base-100 p-4">
                  <div class="skeleton h-4 w-1/3 mb-3"></div>
                  <div class="skeleton h-3 w-2/3 mb-2"></div>
                  <div class="skeleton h-3 w-1/2"></div>
                </div>
              <% end %>
            </div>
          <% else %>
            <%= if @filtered_tasks == [] do %>
              <%= if @tasks_error != nil do %>
                <div id="tasks-load-error" class="text-center py-12 sm:py-16 text-base-content/70">
                  <.icon
                    name="hero-exclamation-triangle"
                    class="size-10 mx-auto mb-4 text-error/70"
                  />
                  <p class="text-lg font-medium text-error">{gettext("Could not load tasks.")}</p>
                  <button
                    type="button"
                    class="btn btn-sm btn-ghost mt-3 text-error"
                    phx-click="retry_load"
                  >
                    <.icon name="hero-arrow-path" class="size-3.5" /> {gettext("Retry")}
                  </button>
                </div>
              <% else %>
                <div class="text-center py-12 sm:py-16 text-base-content/70">
                  <.icon name="hero-inbox" class="size-10 mx-auto mb-4 text-base-content/40" />
                  <h2 class="text-lg font-medium">
                    {cond do
                      @focused_task_id -> gettext("Task not found")
                      @status_filter == "needs_review" -> gettext("No tasks need review")
                      true -> gettext("No tasks found")
                    end}
                  </h2>
                  <.link
                    :if={@focused_task_id}
                    navigate={with_node_param(~p"/tasks", @current_node_id)}
                    class="btn btn-ghost btn-sm mt-3"
                  >
                    {gettext("Task History")}
                  </.link>
                  <p :if={!@focused_task_id} class="text-sm mt-1">
                    <%= cond do %>
                      <% @status_filter == "needs_review" -> %>
                        {gettext("Finished tasks that still need a review decision appear here.")}
                      <% @status_filter != "all" or @project_filter != "all" or @search_query != "" or @review_status_filter != "all" or @session_mode_filter != "all" or (@total_count > 0 and not @show_reflect_tasks) -> %>
                        {gettext("Try adjusting your filters or search query.")}
                      <% true -> %>
                        {gettext("Tasks will appear here once you start them from the dashboard.")}
                    <% end %>
                  </p>
                </div>
              <% end %>
            <% else %>
              <%!-- Keyed stream: `id` is exactly `task-<id>` and every row keeps
                   ONE persistent DOM node, so a refresh patches the rows that
                   actually changed instead of re-rendering the whole list. A
                   `reset` happens ONLY on a landed page load (first load, filter,
                   page, node switch, refresh) — never on a push or a mutation. --%>
              <div id="tasks-stream" phx-update="stream" class="space-y-4">
                <div
                  :for={{dom_id, task} <- @streams.tasks}
                  id={dom_id}
                  data-list-enter-key={task.id}
                  class="relative z-10 has-[[open]]:z-30"
                >
                  <EvoDashWeb.TaskCardComponents.task_card
                    task={task}
                    focused={@focused_task_id == task.id}
                    show_details={MapSet.member?(@expanded_task_ids, task.id)}
                    detail={Map.get(@task_details, task.id)}
                    current_node_id={@current_node_id}
                    session_agent_id={session_agent_id(@awaiting_sessions, task.id)}
                    action_busy={@action_busy}
                  />
                </div>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Pagination Controls -->
        <%= if @total_pages > 1 and is_nil(@focused_task_id) do %>
          <% offset = (@current_page - 1) * @page_size %>
          <% range_start = offset + 1 %>
          <% range_end = min(offset + @page_size, @total_count) %>
          <% pages = page_window(@current_page, @total_pages) %>
          <div class="mt-4 flex flex-col items-center gap-3">
            <p class="text-sm text-base-content/70">
              {gettext("Showing %{start}–%{end} of %{total} tasks",
                start: range_start,
                end: range_end,
                total: @total_count
              )}
            </p>
            <div class="flex items-center gap-2">
              <div class="join">
                <button
                  class="join-item btn btn-sm"
                  phx-click="prev_page"
                  disabled={@current_page <= 1}
                >
                  <.icon name="hero-chevron-left" class="size-4" />
                </button>
                <%= for p <- pages do %>
                  <%= if p == @current_page do %>
                    <button class="join-item btn btn-sm btn-primary" disabled>
                      {p}
                    </button>
                  <% else %>
                    <button
                      class="join-item btn btn-sm"
                      phx-click="goto_page"
                      phx-value-page={p}
                    >
                      {p}
                    </button>
                  <% end %>
                <% end %>
                <button
                  class="join-item btn btn-sm"
                  phx-click="next_page"
                  disabled={@current_page >= @total_pages}
                >
                  <.icon name="hero-chevron-right" class="size-4" />
                </button>
              </div>
            </div>
            <p class="text-xs text-base-content/70">
              {gettext("Page %{current} of %{total}", current: @current_page, total: @total_pages)}
            </p>
          </div>
        <% end %>

        <!-- Clear History (moved to bottom for safety) -->
        <div :if={!@focused_task_id} class="mt-6 flex justify-center sm:justify-end">
          <button
            type="button"
            class="btn btn-ghost btn-sm text-error gap-1"
            phx-click="clear_task_history"
            disabled={@clearing_history}
            data-confirm={gettext("Clear all finished task history? This cannot be undone.")}
          >
            <.icon :if={!@clearing_history} name="hero-trash" class="size-3.5" />
            <span :if={@clearing_history} class="loading loading-spinner loading-xs"></span>
            {if @clearing_history,
              do: gettext("Clearing…"),
              else: gettext("Clear History")}
          </button>
        </div>

        <!-- Full Result Modal — `@selected_result` is a modal STATE, not a raw
             result: %{state: :loading} | %{state: :ok, result: result} |
             %{state: :error, error: reason}. The result itself comes from the
             lazy per-card detail cache (TasksLive.ModalHelpers.view_full_result/2),
             so "not loaded yet" is a first-class, non-crashing state. -->
        <%= if @selected_result do %>
          <EvoDashWeb.Helpers.modal on_close="close_result_modal">
            <:title>
              <.icon name="hero-information-circle" class="size-5 text-base-content/70" />
              {gettext("Task Result")}
            </:title>
            <%= case @selected_result do %>
              <% %{state: :ok, result: result} -> %>
                {EvoDashWeb.TaskCardComponents.render_result_full(result)}
              <% %{state: :error} -> %>
                <p id="full-result-error" class="text-sm text-base-content/70">
                  {gettext("Could not load the task result.")}
                </p>
              <% _ -> %>
                <p id="full-result-loading" class="text-sm text-base-content/70">
                  {gettext("Task result is not loaded yet.")}
                </p>
            <% end %>
            <:actions>
              <%= if match?(%{state: :ok}, @selected_result) do %>
                <button
                  id="full-result-copy"
                  phx-hook="ClipboardCopy"
                  data-content={
                    EvoDashWeb.TaskCardComponents.result_copy_text(Map.get(@selected_result, :result))
                  }
                  class="btn btn-sm btn-ghost rounded-md"
                >
                  <.icon name="hero-clipboard-document" class="size-4 mr-1.5" />
                  <%!-- zh_CN: 复制按钮 --%>{gettext("Copy")}
                </button>
              <% end %>
            </:actions>
          </EvoDashWeb.Helpers.modal>
        <% end %>

        <!-- Full Options Modal -->
        <%= if @selected_options do %>
          <EvoDashWeb.Helpers.modal on_close="close_options_modal">
            <:title>
              <.icon name="hero-chat-bubble-left-ellipsis" class="size-5 text-primary-standalone" />
              {gettext("Full Objective")}
            </:title>
            <pre class="text-sm whitespace-pre-wrap break-words"><%= @selected_options %></pre>
            <:actions>
              <button
                id="full-options-copy"
                phx-hook="ClipboardCopy"
                data-content={@selected_options}
                class="btn btn-sm btn-ghost rounded-md"
              >
                <.icon name="hero-clipboard-document" class="size-4 mr-1.5" />
                <%!-- zh_CN: 复制按钮 --%>{gettext("Copy")}
              </button>
            </:actions>
          </EvoDashWeb.Helpers.modal>
        <% end %>

        <!-- Cancel Task confirmation modal (graceful: agents save + exit) -->
        <%= if @confirm_cancel_task_id do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
            <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="close_cancel_modal">
            </div>
            <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-300 max-w-lg w-full p-5 sm:p-6">
              <div class="flex items-center gap-3 mb-4">
                <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
                <h3 class="text-lg font-semibold">{gettext("Cancel Task?")}</h3>
              </div>

              <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
                {gettext(
                  "All agents of this task will be informed to immediately save their changes and exit. Intermediate results will be saved."
                )}
              </p>
              <p class="text-xs text-base-content/70 mb-5">
                {gettext("Task: %{task_id}", task_id: @confirm_cancel_task_id)}
              </p>

              <div class="flex justify-end gap-3 pt-2">
                <button
                  type="button"
                  class="btn btn-ghost rounded-md px-6"
                  phx-click="close_cancel_modal"
                >
                  {gettext("Keep Running")}
                </button>
                <button
                  type="button"
                  class="btn btn-warning rounded-md px-6 gap-2"
                  phx-click="confirm_cancel_task"
                  disabled={action_busy?(@action_busy, @confirm_cancel_task_id)}
                >
                  <span
                    :if={action_busy?(@action_busy, @confirm_cancel_task_id)}
                    class="loading loading-spinner loading-xs"
                  ></span>
                  <.icon
                    :if={!action_busy?(@action_busy, @confirm_cancel_task_id)}
                    name="hero-x-mark"
                    class="size-4.5"
                  />
                  {gettext("Cancel Task")}
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <!-- Force Kill Task confirmation modal (brutal: immediate, all progress lost) -->
        <%= if @confirm_force_kill_task_id do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
            <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="close_force_kill_modal">
            </div>
            <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-300 max-w-lg w-full p-5 sm:p-6">
              <div class="flex items-center gap-3 mb-4">
                <.icon name="hero-exclamation-triangle" class="size-5 text-error" />
                <h3 class="text-lg font-semibold">{gettext("Force Kill Task?")}</h3>
              </div>

              <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
                {gettext(
                  "Immediately stops the task and all of its agents. ALL progress will be completely lost. This cannot be undone."
                )}
              </p>
              <p class="text-xs text-base-content/70 mb-5">
                {gettext("Task: %{task_id}", task_id: @confirm_force_kill_task_id)}
              </p>

              <div class="flex justify-end gap-3 pt-2">
                <button
                  type="button"
                  class="btn btn-ghost rounded-md px-6"
                  phx-click="close_force_kill_modal"
                >
                  {gettext("Keep Running")}
                </button>
                <button
                  type="button"
                  class="btn btn-error rounded-md px-6 gap-2"
                  phx-click="confirm_force_kill_task"
                  disabled={action_busy?(@action_busy, @confirm_force_kill_task_id)}
                >
                  <span
                    :if={action_busy?(@action_busy, @confirm_force_kill_task_id)}
                    class="loading loading-spinner loading-xs"
                  ></span>
                  <.icon
                    :if={!action_busy?(@action_busy, @confirm_force_kill_task_id)}
                    name="hero-x-circle"
                    class="size-4.5"
                  />
                  {gettext("Force Kill")}
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <!-- Close interactive-session confirmation modal -->
        <%= if @confirm_close_session_task_id do %>
          <EvoDashWeb.TasksLive.Session.confirm_close_session_modal
            task_id={@confirm_close_session_task_id}
            session_agent_id={session_agent_id(@awaiting_sessions, @confirm_close_session_task_id)}
            busy={action_busy?(@action_busy, @confirm_close_session_task_id)}
          />
        <% end %>

        <!-- Pause Task confirmation modal (graceful: agents stop at their next
             turn boundary, the task keeps its work and stays resumable) -->
        <%= if @confirm_pause_task_id do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
            <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="close_pause_modal">
            </div>
            <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-300 max-w-lg w-full p-5 sm:p-6">
              <div class="flex items-center gap-3 mb-4">
                <.icon name="hero-pause-circle" class="size-5 text-primary-standalone" />
                <h3 class="text-lg font-semibold">{gettext("Pause task?")}</h3>
              </div>

              <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
                <%!-- zh_CN: 暂停在下一轮对话边界生效，当前工具调用会先执行完，所以可能要等一会儿 --%>
                {gettext(
                  "The agent finishes its current tool call first, so this can take a moment. The task keeps all of its work and can be resumed later."
                )}
              </p>
              <p class="text-xs text-base-content/70 mb-5">
                {gettext("Task: %{task_id}", task_id: @confirm_pause_task_id)}
              </p>

              <div class="flex justify-end gap-3 pt-2">
                <button
                  type="button"
                  class="btn btn-ghost rounded-md px-6"
                  phx-click="close_pause_modal"
                >
                  {gettext("Keep Running")}
                </button>
                <button
                  type="button"
                  class="btn btn-primary rounded-md px-6 gap-2"
                  phx-click="confirm_pause_task"
                  phx-value-task_id={@confirm_pause_task_id}
                >
                  <.icon name="hero-pause" class="size-4.5" />
                  {gettext("Pause Task")}
                </button>
              </div>
            </div>
          </div>
        <% end %>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :page_title, gettext("Task History"))

    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
    end

    config_status = config_status()

    socket =
      socket
      |> assign(
        tasks: [],
        # The rendered list (@filtered_tasks) is only ever filled by a landed
        # page load, but the ERROR state reads it before any load has
        # succeeded — seed it empty so a first-load failure renders the retry
        # block instead of crashing on a missing assign.
        filtered_tasks: [],
        # Project paths (the project-filter dropdown's options) are fetched by
        # the async page load (PageLoad.start/3 → PageLoad.load/4, which calls
        # get_unique_paths/1) and land with its {:tasks_page_loaded, ...}
        # result. Seeding empty here keeps mount/3 free of a blocking store
        # query — which would also always run against the LOCAL node, before
        # handle_params/3 resolves the ?node= context.
        project_paths: [],
        status_filter: "all",
        project_filter: "all",
        search_query: "",
        review_status_filter: "all",
        # Reveal preference (default OFF): hides :reflect repo-less Home-chat
        # tasks from the cross-project list. A page-local reveal toggle, NOT a
        # narrowing filter — deliberately left out of reset_filters and the
        # active-filters indicator.
        show_reflect_tasks: false,
        expanded_task_ids: MapSet.new(),
        # Per-card lazy detail cache, owned by EvoDashWeb.TasksLive.TaskDetail:
        # %{task_id => %{state:, task:, error:, seq:, archive:}} where `archive`
        # is the PAGED envelope (entries/total/next_offset/agent_results). Bounded
        # to ONE page's worth of entries (TaskDetail.prune/2 runs on every landed
        # page load) and seeded empty — nothing is fetched until a card is
        # expanded.
        task_details: %{},
        # Monotonic spawn counter for BOTH detail and archive fetches (the
        # per-entry stale guard) — deliberately its OWN key, independent of
        # :page_load_seq and of NodeAware's :tasks_load_seq.
        task_detail_seq: 0,
        selected_result: nil,
        selected_options: nil,
        confirm_cancel_task_id: nil,
        confirm_force_kill_task_id: nil,
        # Pause confirmation modal's task id (nil = closed) and the per-task
        # in-flight action map the cards use to disable/spin their PAUSE /
        # RESUME controls: `%{to_string(task_id) => :pause | :resume}` — keyed
        # by the STRING form because that is what a card's
        # `phx-value-task_id` carries. An entry is cleared by the action's own
        # async result (success OR failure), so a button can never wedge.
        confirm_pause_task_id: nil,
        action_busy: %{},
        # `task_id => agent_id` of the sessions parked at `:awaiting_input`
        # (their cards render a reply box + close control), and the
        # close-session modal's task id (nil = closed). `session_mode_filter`
        # is applied server-side by the page loader.
        awaiting_sessions: %{},
        confirm_close_session_task_id: nil,
        session_mode_filter: "all",
        config_status: config_status,
        current_page: 1,
        page_size: @default_page_size,
        total_count: 0,
        total_pages: 1,
        # Async page-load state: page_load_seq is the monotonic spawn counter
        # for the in-flight page-load task (stale-guard) — deliberately its OWN
        # key, never :tasks_load_seq, which EvoDashWeb.LiveHooks.NodeAware owns
        # for the sidebar's "Active Tasks" fetch. The debounced reload spawns
        # BOTH loads in the same handler, so a shared counter would make each
        # load's bump invalidate the other's in-flight result.
        # tasks_loading drives the FIRST-load skeleton rows (nothing on screen
        # yet); tasks_refreshing is the NON-blanking refresh flag — a filter /
        # search / pagination change keeps the loaded rows mounted and only
        # paints a thin inline progress line above the list.
        # tasks_error holds the reason of the LAST failed page load (nil on
        # success). An error keeps the already-loaded rows untouched and renders
        # a retry affordance.
        page_load_seq: 0,
        tasks_loading: false,
        tasks_refreshing: false,
        tasks_error: nil,
        # Page-level in-flight flag for the async `clear_task_history` mutation
        # (the per-task equivalent lives in `:action_busy`).
        clearing_history: false
      )
      |> assign_new(:focused_task_id, fn -> nil end)
      |> assign_new(:workbench_project, fn -> nil end)
      |> assign_new(:workbench_title, fn -> nil end)
      |> assign_new(:workbench_remote_requested, fn -> false end)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    requested_page = parse_page(params["page"])

    # Capture the node context BEFORE `assign_node/2` so a node switch can clear
    # stale confirmation modals: a cancel/force-kill modal opened on one node
    # must not persist (and potentially get confirmed) after switching to
    # another node. `:tasks_node_loaded` is the dedup-guard assign seeded by
    # NodeAware.on_mount and updated by assign_node/2 only when the context
    # tuple `{current_node_id, current_node}` changes — so pagination/filter
    # push_patches (same node) never clear the modals.
    previous_node_ctx = socket.assigns[:tasks_node_loaded]

    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(workbench_reconnect_params: Map.take(params, ["task"]))
      |> assign(
        focused_task_id: focused_task_id(params["task"]),
        workbench_remote_requested: params["node"] not in [nil, "local"],
        workbench_project: nil,
        workbench_title: nil
      )
      # URL IS STATE: the ONE place the filter assigns are seeded from the query
      # string, so a deep link, browser back/forward and every filter event's
      # `push_patch` converge on this single load (below) instead of an
      # "assign + reload" pair. `show_reflect_tasks` is deliberately NOT here —
      # it is a page-local reveal preference, never URL state.
      |> seed_filters(params)

    # Node-switch URL rule (`LiveHooks.NodeAware.handle_node_selected/2` rebuilds
    # the URL from `@current_path`): this page's state IS its query string, so the
    # assign carries the page's CURRENT url — built by `tasks_url/3`, the page's
    # ONE URL builder, from the filters just seeded — instead of the bare route
    # path, or a node switch would reset `/tasks?status=needs_review` to the
    # default view. No other page needs this: their state is not in the URL the
    # same way, and they intentionally reset on a node switch.
    socket = assign(socket, :current_path, tasks_url(socket, requested_page))

    socket =
      case socket.assigns.focused_task_id do
        nil -> socket
        id -> assign(socket, expanded_task_ids: MapSet.put(socket.assigns.expanded_task_ids, id))
      end

    socket =
      if connected?(socket) do
        # Kick off the page load ONLY on the connected pass: handle_params/3
        # runs on BOTH the disconnected (static HTTP) render and the connected
        # mount, and the disconnected render's async result is discarded —
        # so spawning there would issue a full duplicate query (page SELECT +
        # COUNT + 25-row %TaskInfo{} decode + get_unique_paths) per
        # navigation. The else branch still paints the FIRST-load skeleton rows
        # so the static HTML matches the connected render.
        #
        # Pagination is a push_patch through here, so it must NOT blank the
        # list either: `reload/3` paints the skeleton only when there is
        # nothing to keep. A NODE switch is the one exception — the rows on
        # screen belong to the old node, so they are replaced by the skeleton.
        node_switched? = node_context_changed?(previous_node_ctx, socket)

        reload(socket, requested_page, if(node_switched?, do: true))
      else
        assign(socket, :tasks_loading, true)
      end

    socket =
      if previous_node_ctx != nil and previous_node_ctx != socket.assigns[:tasks_node_loaded] do
        socket
        |> assign(:confirm_cancel_task_id, nil)
        |> assign(:confirm_force_kill_task_id, nil)
        |> assign(:confirm_pause_task_id, nil)
        # The in-flight pause/resume markers belong to the OLD node too: a
        # stale entry would render as a permanently disabled (or spinning)
        # button on the newly-viewed node, which has no such request.
        |> assign(:action_busy, %{})
        # An idle-session modal and the map it confirms against belong to the
        # OLD node — clear both so a close can never hit another node's session.
        |> assign(:confirm_close_session_task_id, nil)
        |> assign(:awaiting_sessions, %{})
        # Page-level in-flight markers belong to the OLD node's requests: their
        # result messages carry no node, so clear them here or a vanished
        # spinner would hang forever on the newly-viewed node.
        |> assign(:clearing_history, false)
        |> assign(:tasks_refreshing, false)
        # Cached per-card details belong to the OLD node: drop them so the
        # expanded cards of the new node fetch their own rows (and stale
        # in-flight results are rejected by TaskDetail's node + entry guards).
        |> assign(:task_details, %{})
      else
        socket
      end

    {:noreply, socket}
  end

  defp focused_task_id(id) when is_binary(id) and byte_size(id) in 1..128, do: id
  defp focused_task_id(_), do: nil

  defp assign_focused_task(%{assigns: %{focused_task_id: id}} = socket, [%{id: id} = task])
       when is_binary(id) do
    opts = task[:opts] || []

    assign(socket,
      workbench_project: task[:project_path],
      workbench_title: opts[:objective] || opts[:prompt]
    )
  end

  defp assign_focused_task(socket, _), do: socket

  @impl true
  def handle_info({:node_selected, node_id}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)
  end

  @impl true
  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)
  end

  @impl true
  def handle_info({:task_updated, task_id, _status, node} = msg, socket) do
    # New-shape task event from the "tasks" PubSub topic (node-identity
    # contract). NodeAware.handle_task_info/2 applies the node filter (drops
    # foreign-node events BEFORE the debounce) and schedules the 300ms
    # debounced :node_aware_reload_tasks. It already returns {:noreply, socket}.
    #
    # The cached per-card detail of the AFFECTED task is stale (status / usage /
    # result changed), so drop it first — only for the viewed node, and only
    # before delegating (the delegation result is passed through unchanged). An
    # expanded card refetches immediately instead of blanking.
    socket =
      if EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?(socket.assigns, node) do
        TaskDetail.invalidate(socket, task_id)
      else
        socket
      end

    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info({:task_deleted, task_id, node} = msg, socket) do
    # New-shape task-deletion event — same node filter + cache invalidation +
    # debounce treatment as {:task_updated, ...} above.
    socket =
      if EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?(socket.assigns, node) do
        TaskDetail.invalidate(socket, task_id)
      else
        socket
      end

    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    # Debounce timer fired: refresh the page task list and the sidebar's
    # running/pending tasks, then clear the debounce-pending flag.
    #
    # Serves BOTH local and remote nodes: NodeAware.handle_task_info/2
    # schedules this (trailing-edge 300ms debounce) after any node-matching
    # {:task_updated, ...} / {:task_deleted, ...} broadcast on the "tasks"
    # topic.
    #
    # The page reload goes through the ASYNC path so the LiveView process
    # never blocks on the (single, serialized) store; show_loading? false
    # keeps the stale rows visible until the fresh page arrives. Repeated
    # broadcast bursts coalesce: each spawn bumps the monotonic
    # :page_load_seq, so a superseded load's result is dropped by the
    # stale-guard in the {:tasks_page_loaded, ...} handler below, and the
    # newest in-flight load always clears :tasks_loading when it applies.
    socket = PageLoad.start(socket, socket.assigns.current_page, false)
    socket = EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.clear_task_reload_pending(socket)}
  end

  @impl true
  def handle_info({:tasks_page_loaded, seq, node, result}, socket) do
    # The thin "Refreshing tasks…" line is cleared on EVERY outcome — stale,
    # successful and failed alike — so a non-blanking refresh can never stick.
    socket = assign(socket, :tasks_refreshing, false)

    if seq < socket.assigns.page_load_seq or node != socket.assigns.current_node do
      # Stale page-load result — a newer page load was started after this one
      # was spawned (or the user switched nodes). Drop it: the newest
      # in-flight load will apply its own result (and clear the loading
      # state). :page_load_seq is bumped ONLY by PageLoad.start/3 —
      # NodeAware's sidebar fetch keeps its own :tasks_load_seq counter, so
      # the two loads a debounced reload spawns never invalidate each other.
      {:noreply, socket}
    else
      socket = assign(socket, :tasks_loading, false)

      case result do
        {:ok, m} ->
          # The ONE post-load choke point: :reflect tasks are excluded
          # client-side (the SQL WHERE builder cannot express "exclude type"),
          # and the third argument keeps the `needs_review` exactness guard
          # live (it drops any landed row whose review decision already
          # exists — no server predicate can be narrowed further from here).
          visible =
            PageLoad.visible_tasks(
              m.tasks,
              socket.assigns.show_reflect_tasks or not is_nil(socket.assigns.focused_task_id),
              socket.assigns.status_filter
            )

          socket =
            socket
            |> assign_focused_task(visible)
            |> assign(:tasks, visible)
            |> assign(:current_page, m.current_page)
            |> assign(:total_count, m.total_count)
            |> assign(:total_pages, m.total_pages)
            |> assign(:project_paths, m.project_paths)
            |> assign(:filtered_tasks, visible)
            # DEFENSIVE: an injected/older page-load result may predate this
            # key — a missing entry means "no idle sessions", never a crash.
            |> assign(:awaiting_sessions, Map.get(m, :awaiting_sessions, %{}))
            |> assign(:tasks_error, nil)
            # Rows are summary maps now (no result/usage/logs/archive): bound
            # the per-card detail cache to THIS page, then refetch the detail
            # of every card that is still expanded so an open card survives a
            # background refresh / pagination round-trip.
            |> TaskDetail.prune(visible)
            |> TaskDetail.ensure_expanded(visible)
            |> put_tasks_stream(visible)

          {:noreply, socket}

        {:error, reason} ->
          # Never clear already-loaded rows on a failed load: a background
          # refresh failure must not blank the page. The reason is a value
          # (SafeCall captured any exit), rendered as a retry-able error state
          # — deliberately not interpolated into the DOM.
          {:noreply, assign(socket, :tasks_error, reason)}
      end
    end
  end

  # Async `session_send_message` result. `SafeCall.start/4` sends its tag
  # VERBATIM, so `{:session_message_sent, task_id}` arrives NESTED; the flat
  # clause is a tolerant alias for a directly sent message. Defined BEFORE the
  # `handle_info(_msg, socket)` catch-all so this result is never dropped.
  @impl true
  def handle_info({{:session_message_sent, task_id}, result}, socket),
    do: {:noreply, session_message_result(socket, task_id, result)}

  @impl true
  def handle_info({:session_message_sent, task_id, result}, socket),
    do: {:noreply, session_message_result(socket, task_id, result)}

  # Async pause/resume results. `SafeCall.start/4` sends its tag VERBATIM, so
  # `{:pause_result, task_id}` / `{:resume_result, task_id}` arrive NESTED as
  # `{{tag, task_id}, result}` and are applied by `pause_resume_result/4`
  # (which ALWAYS clears the task's busy marker, so a button can never wedge).
  # Defined BEFORE the `handle_info(_msg, socket)` catch-all, like the sibling
  # session-message clause above.
  @impl true
  def handle_info({{:pause_result, task_id}, result}, socket),
    do: {:noreply, pause_resume_result(socket, task_id, :pause, result)}

  @impl true
  def handle_info({{:resume_result, task_id}, result}, socket),
    do: {:noreply, pause_resume_result(socket, task_id, :resume, result)}

  # Async results of the five task MUTATIONS that used to call the registry/RPC
  # INLINE (freezing the LiveView for the whole call — up to the 30s :erpc
  # default on a dead remote node). Each runs under `EvoDash.SafeCall.start/4`,
  # which sends its tag VERBATIM, so the tag arrives NESTED as
  # `{{tag, task_id}, result}`; `task_mutation_result/4` ALWAYS clears the
  # task's `:action_busy` marker, so a control can never wedge — and because
  # `SafeCall.start/4` sends NOTHING when the child cannot be started, the
  # spawning arm clears the marker itself on that failure.
  # Defined BEFORE the `handle_info(_msg, socket)` catch-all, like the pause/
  # resume clauses above, so these results are never dropped.
  @impl true
  def handle_info({{:cancel_result, task_id}, result}, socket),
    do: {:noreply, task_mutation_result(socket, :cancel, task_id, result)}

  @impl true
  def handle_info({{:force_kill_result, task_id}, result}, socket),
    do: {:noreply, task_mutation_result(socket, :force_kill, task_id, result)}

  @impl true
  def handle_info({{:close_session_result, task_id}, result}, socket),
    do: {:noreply, task_mutation_result(socket, :close, task_id, result)}

  @impl true
  def handle_info({{:delete_result, task_id}, result}, socket),
    do: {:noreply, task_mutation_result(socket, :delete, task_id, result)}

  # `clear_finished_tasks/1` is a PAGE-level action (no task id), so its busy
  # marker is the page-level `:clearing_history` flag rather than an
  # `:action_busy` entry. Cleared on EVERY outcome.
  @impl true
  def handle_info({{:clear_finished_result}, result}, socket) do
    socket = assign(socket, :clearing_history, false)

    case mutation_result(result) do
      :ok ->
        socket =
          socket
          |> assign(:expanded_task_ids, MapSet.new())
          |> reload(1)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to clear task history: %{reason}", reason: inspect(reason))
         )}
    end
  end

  # Per-card lazy detail result (EvoDashWeb.TasksLive.TaskDetail). The module
  # applies the node + entry + seq guards; a stale/foreign result is dropped.
  @impl true
  def handle_info({:task_detail_loaded, seq, node, task_id, result}, socket) do
    {:noreply,
     socket |> TaskDetail.apply_detail(seq, node, task_id, result) |> refresh_stream_row(task_id)}
  end

  # Per-card lazy archive result — same guarded apply path. The module reads the
  # envelope to decide whether this is the FIRST page or an appended page.
  @impl true
  def handle_info({:task_archive_loaded, seq, node, task_id, result}, socket) do
    {:noreply,
     socket |> TaskDetail.apply_archive(seq, node, task_id, result) |> refresh_stream_row(task_id)}
  end

  # Per-agent lazy archive result (one agent's full entry, its `"result"`
  # included) — same guarded apply path, keyed on the archive's seq.
  @impl true
  def handle_info({:task_archive_agent_loaded, seq, node, task_id, agent_id, result}, socket) do
    {:noreply,
     socket
     |> TaskDetail.apply_archive_agent(seq, node, task_id, agent_id, result)
     |> refresh_stream_row(task_id)}
  end

  # Sync-error fallback for initiate_remote_connect/2: the subsystem is
  # unavailable / the target is unknown / the manager failed to start — NO
  # "remote_connections" broadcast ever arrives on these arms, so the gate can
  # never reconcile; the flash is the surfacing mechanism. Terminal outcomes
  # arrive only via PubSub broadcasts handled by NodeAware.handle_connection_status/2.
  @impl true
  def handle_info({:remote_connect_result, _target_id, {:error, reason}}, socket) do
    message =
      case reason do
        :remote_connection_unavailable ->
          gettext("Remote connect unavailable — the remote connection subsystem is not running.")

        _ ->
          gettext("Remote connect failed: %{reason}", reason: format_remote_reason(reason))
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Every filter / search / reset / clear event computes the new values and
  # `push_patch`es the URL; `handle_params/3` seeds them and runs the ONE load,
  # so no event assigns-and-reloads (exactly one page load per user action).
  @impl true
  def handle_event("filter_tasks", params, socket) do
    # Missing/unknown values (a select that was not part of this change) keep
    # the CURRENT filter rather than resetting it.
    status = whitelisted(params["status_filter"], @status_filters, socket.assigns.status_filter)

    project =
      binary_or(params["project_filter"], socket.assigns.project_filter)

    {:noreply, push_patch(socket, to: tasks_url(socket, 1, status: status, project: project))}
  end

  @impl true
  def handle_event("filter_review", %{"review_filter" => filter}, socket) do
    review = whitelisted(filter, @review_filters, socket.assigns.review_status_filter)

    {:noreply, push_patch(socket, to: tasks_url(socket, 1, review: review))}
  end

  # `replace: true` — a keystroke must not push one history entry per debounce
  # tick, so the back button leaves the search instead of unwinding it.
  @impl true
  def handle_event("search_tasks", %{"search_query" => query}, socket) do
    {:noreply, push_patch(socket, to: tasks_url(socket, 1, q: query), replace: true)}
  end

  # Session-kind filter — whitelist match only (never an atom conversion); an
  # unknown value keeps the current filter. The value travels in the store's
  # `filters` keyword list, where the core's shared WHERE builder applies it
  # (`EvoGit.Store.Operations.Filters.where_session_mode_filter/2`).
  @impl true
  def handle_event("filter_session_mode", %{"session_mode_filter" => mode}, socket)
      when mode in @session_filters do
    {:noreply, push_patch(socket, to: tasks_url(socket, 1, session: mode))}
  end

  @impl true
  def handle_event("filter_session_mode", _params, socket), do: {:noreply, socket}

  # Prevents page reload when pressing Enter in the filter/search form
  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # Retry after a failed page load. The loading placeholder is shown only when
  # there is nothing on screen to keep (a failed background refresh leaves the
  # previous rows visible while the retry runs).
  @impl true
  def handle_event("retry_load", _params, socket) do
    {:noreply, reload(socket, socket.assigns.current_page)}
  end

  # Reveal toggle for :reflect (repo-less Home-chat) tasks, default OFF. The
  # checkbox carries value="true", so a CHECKED box sends "true" and an
  # UNCHECKED box is absent from FormData — anything other than nil/"false"
  # means checked. Deliberately only assigns show_reflect_tasks (the phx-change
  # submits the whole form, but the other filters keep their socket assigns)
  # and reloads through the same async path as the filters. It is the ONE
  # remaining assign + reload path on this page BECAUSE it is a page-local
  # reveal preference, not a narrowing filter: it stays out of the URL (so a
  # shared link never reveals chat tasks) and out of reset_filters.
  @impl true
  def handle_event("toggle_reflect_tasks", params, socket) do
    show = params["show_reflect_tasks"] not in [nil, "false"]

    {:noreply,
     socket
     |> assign(:show_reflect_tasks, show)
     |> reload(1)}
  end

  @impl true
  def handle_event("retry_remote_connection", _params, socket) do
    # Async: initiate_remote_connect/2 spawns a supervised Task on
    # EvoDash.TaskSupervisor that runs the remote connect (NodeContext's
    # connect/1); terminal outcomes arrive via "remote_connections" PubSub
    # broadcasts, sync errors via {:remote_connect_result, target_id, {:error,
    # reason}}. Return immediately — no blocking.
    EvoDashWeb.LiveHooks.NodeAware.initiate_remote_connect(socket, socket.assigns.current_node_id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_to_local", _params, socket) do
    send(self(), {:node_selected, "local"})
    {:noreply, socket}
  end

  # Reset = the bare `/tasks` URL (every filter back to its default). The
  # page-local reveal toggle is NOT part of it.
  @impl true
  def handle_event("reset_filters", _params, socket) do
    {:noreply,
     push_patch(
       socket,
       to:
         tasks_url(socket, 1,
           status: "all",
           project: "all",
           review: "all",
           session: "all",
           q: ""
         )
     )}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "status"}, socket) do
    {:noreply, push_patch(socket, to: tasks_url(socket, 1, status: "all"))}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "project"}, socket) do
    {:noreply, push_patch(socket, to: tasks_url(socket, 1, project: "all"))}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "search"}, socket) do
    {:noreply, push_patch(socket, to: tasks_url(socket, 1, q: ""))}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "review"}, socket) do
    {:noreply, push_patch(socket, to: tasks_url(socket, 1, review: "all"))}
  end

  @impl true
  def handle_event("clear_filter", %{"filter" => "session_mode"}, socket) do
    {:noreply, push_patch(socket, to: tasks_url(socket, 1, session: "all"))}
  end

  @impl true
  def handle_event("goto_page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: tasks_url(socket, page))}
  end

  @impl true
  def handle_event("prev_page", _params, socket) do
    page = max(1, socket.assigns.current_page - 1)
    {:noreply, push_patch(socket, to: tasks_url(socket, page))}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    page = min(socket.assigns.total_pages, socket.assigns.current_page + 1)
    {:noreply, push_patch(socket, to: tasks_url(socket, page))}
  end

  @impl true
  def handle_event("clear_task_history", _params, socket) do
    # ASYNC: clearing a finished-task history is a slow, serialized store write,
    # so the LiveView never waits on it (SafeCall also captures an exit — store
    # timeout / dead store — as a value instead of crashing the page). The
    # page-level :clearing_history flag disables the button AND guards a
    # duplicate submit; the result lands as `{{:clear_finished_result}, result}`
    # (see the handle_info clause, which clears the flag on every outcome).
    if socket.assigns.clearing_history do
      # A clear is already in flight — ignore a duplicate submit.
      {:noreply, socket}
    else
      socket = assign(socket, :clearing_history, true)

      case SafeCall.start(self(), {:clear_finished_result}, fn ->
             EvoDash.NodeContext.clear_finished_tasks(socket.assigns.current_node)
           end) do
        {:ok, _pid} ->
          {:noreply, socket}

        # No child started, so no result message will ever arrive: clear the
        # flag HERE or the button would stay disabled forever.
        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:clearing_history, false)
           |> put_flash(
             :error,
             gettext("Failed to clear task history: %{reason}", reason: inspect(reason))
           )}
      end
    end
  end

  @impl true
  def handle_event("toggle_task_details", %{"task_id" => task_id}, socket) do
    {:noreply, socket |> TaskDetail.toggle(task_id) |> refresh_stream_row(task_id)}
  end

  # Inline "could not load this task" strip → force a refetch of that card's
  # detail (drops the cached :error entry first).
  @impl true
  def handle_event("retry_task_detail", %{"task_id" => task_id}, socket) do
    {:noreply, socket |> TaskDetail.retry(task_id) |> refresh_stream_row(task_id)}
  end

  # The expanded card's archive section asked for its FIRST page → lazy, cached
  # archive fetch (no-op while loading / already loaded).
  @impl true
  def handle_event("load_task_archive", %{"task_id" => task_id}, socket) do
    {:noreply, socket |> TaskDetail.load_archive(task_id) |> refresh_stream_row(task_id)}
  end

  # "Load more" (and its retry) — appends the next 100-entry page.
  @impl true
  def handle_event("load_more_task_archive", %{"task_id" => task_id}, socket) do
    {:noreply, socket |> TaskDetail.load_more_archive(task_id) |> refresh_stream_row(task_id)}
  end

  # "Show result" / its retry — ONE agent's full archive entry, including the
  # heavy `"result"` the paged read deliberately omits.
  @impl true
  def handle_event(
        "load_task_archive_agent_result",
        %{"task_id" => task_id, "agent_id" => agent_id},
        socket
      ) do
    {:noreply,
     socket
     |> TaskDetail.load_agent_result(task_id, agent_id)
     |> refresh_stream_row(task_id)}
  end

  @impl true
  def handle_event("view_full_result", %{"task_id" => task_id}, socket) do
    view_full_result(socket, task_id)
  end

  @impl true
  def handle_event("close_result_modal", _params, socket) do
    close_result_modal(socket)
  end

  @impl true
  def handle_event("view_full_options", %{"task_id" => task_id}, socket) do
    view_full_options(socket, task_id)
  end

  @impl true
  def handle_event("close_options_modal", _params, socket) do
    close_options_modal(socket)
  end

  # Fired by the global ClipboardCopy JS hook after a successful copy.
  @impl true
  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
  end

  @impl true
  def handle_event("open_cancel_modal", %{"task_id" => task_id}, socket) do
    # Two-step graceful cancel: open the confirmation modal (and close the
    # force-kill modal if it was somehow open — only one modal at a time).
    {:noreply,
     socket
     |> assign(:confirm_cancel_task_id, task_id)
     |> assign(:confirm_force_kill_task_id, nil)}
  end

  @impl true
  def handle_event("close_cancel_modal", _params, socket) do
    {:noreply, assign(socket, :confirm_cancel_task_id, nil)}
  end

  @impl true
  def handle_event("confirm_cancel_task", _params, socket) do
    case socket.assigns.confirm_cancel_task_id do
      nil ->
        # Modal was never opened (or already closed) — no-op.
        {:noreply, socket}

      task_id ->
        # ASYNC: a graceful cancel messages every agent of the task (and can
        # block on a dead remote node for the :erpc default), so it runs
        # off-process. The result lands as `{{:cancel_result, task_id}, result}`
        # and `task_mutation_result/4` clears the busy marker and settles the
        # modal exactly as the old synchronous arm did.
        start_task_mutation(socket, :cancel, :cancel_result, task_id, fn ->
          EvoDash.NodeContext.cancel_task(socket.assigns.current_node, task_id)
        end)
    end
  end

  @impl true
  def handle_event("open_force_kill_modal", %{"task_id" => task_id}, socket) do
    # Two-step brutal cancel: open the force-kill confirmation modal (and close
    # the graceful-cancel modal if it was somehow open).
    {:noreply,
     socket
     |> assign(:confirm_force_kill_task_id, task_id)
     |> assign(:confirm_cancel_task_id, nil)}
  end

  @impl true
  def handle_event("close_force_kill_modal", _params, socket) do
    {:noreply, assign(socket, :confirm_force_kill_task_id, nil)}
  end

  @impl true
  def handle_event("confirm_force_kill_task", _params, socket) do
    case socket.assigns.confirm_force_kill_task_id do
      nil ->
        # Modal was never opened (or already closed) — no-op.
        {:noreply, socket}

      task_id ->
        # ASYNC — see confirm_cancel_task/3. Result: `{{:force_kill_result, id}, result}`.
        start_task_mutation(socket, :force_kill, :force_kill_result, task_id, fn ->
          EvoDash.NodeContext.force_kill_task(socket.assigns.current_node, task_id)
        end)
    end
  end

  # An idle (`:awaiting_input`) session's card posts its reply box here. The
  # agent id is resolved from the page load's `:awaiting_sessions` map, so a
  # session that stopped waiting (or a stale card) flashes instead of sending.
  @impl true
  def handle_event("session_send_message", %{"task_id" => task_id, "message" => message}, socket) do
    agent_id = session_agent_id(socket.assigns.awaiting_sessions, task_id)
    node = socket.assigns.current_node
    text = String.trim(message || "")

    cond do
      is_nil(agent_id) or is_nil(node) ->
        {:noreply,
         put_flash(socket, :error, gettext("This session is no longer waiting for input."))}

      text == "" ->
        {:noreply, put_flash(socket, :error, gettext("Type a message before sending."))}

      true ->
        # ASYNC under SafeCall (an exit becomes a value). The result lands as
        # {{:session_message_sent, task_id}, result}.
        EvoDash.SafeCall.start(self(), {:session_message_sent, task_id}, fn ->
          EvoDash.NodeContext.send_session_message(node, agent_id, text, :queue)
        end)

        {:noreply, socket}
    end
  end

  # Only one confirmation modal is open at a time (mirrors open_cancel_modal).
  @impl true
  def handle_event("open_close_session_modal", %{"task_id" => task_id}, socket) do
    {:noreply,
     socket
     |> assign(:confirm_close_session_task_id, task_id)
     |> assign(:confirm_cancel_task_id, nil)
     |> assign(:confirm_force_kill_task_id, nil)}
  end

  @impl true
  def handle_event("close_close_session_modal", _params, socket) do
    {:noreply, assign(socket, :confirm_close_session_task_id, nil)}
  end

  @impl true
  def handle_event("confirm_close_session", _params, socket) do
    task_id = socket.assigns.confirm_close_session_task_id
    agent_id = session_agent_id(socket.assigns.awaiting_sessions, task_id)

    cond do
      is_nil(task_id) ->
        # Modal was never opened (or already closed) — no-op.
        {:noreply, socket}

      is_nil(agent_id) ->
        {:noreply,
         socket
         |> assign(:confirm_close_session_task_id, nil)
         |> put_flash(:error, gettext("This session is no longer waiting for input."))}

      true ->
        # ASYNC — the session close finalizes the task through the core, so it
        # must never block the socket. Result: `{{:close_session_result, id}, result}`.
        start_task_mutation(socket, :close, :close_session_result, task_id, fn ->
          EvoDash.NodeContext.close_session(socket.assigns.current_node, agent_id, :normal)
        end)
    end
  end

  # Task-level pause, step 1: open the confirmation modal. Every OTHER
  # confirmation modal is closed, so exactly one is ever open.
  @impl true
  def handle_event("open_pause_modal", %{"task_id" => task_id}, socket) do
    {:noreply,
     socket
     |> assign(:confirm_pause_task_id, task_id)
     |> assign(:confirm_cancel_task_id, nil)
     |> assign(:confirm_force_kill_task_id, nil)
     |> assign(:confirm_close_session_task_id, nil)}
  end

  @impl true
  def handle_event("close_pause_modal", _params, socket) do
    {:noreply, assign(socket, :confirm_pause_task_id, nil)}
  end

  # Task-level pause, step 2: ASYNC under SafeCall (an exit becomes a value).
  # A pause drains the task's agents at their NEXT TURN BOUNDARY — the agent
  # finishes its current tool call first — so the call is far slower than a
  # status write and must NEVER block the LiveView. The modal is closed, the
  # card collapsed and the busy marker set immediately; the outcome lands as
  # `{{:pause_result, task_id}, result}`.
  @impl true
  def handle_event("confirm_pause_task", _params, socket) do
    case socket.assigns[:confirm_pause_task_id] do
      nil ->
        # Modal was never opened (or already closed) — no-op.
        {:noreply, socket}

      task_id ->
        node = socket.assigns.current_node

        EvoDash.SafeCall.start(self(), {:pause_result, task_id}, fn ->
          EvoDash.NodeContext.pause_task(node, task_id)
        end)

        {:noreply,
         socket
         |> assign(:confirm_pause_task_id, nil)
         |> assign(:expanded_task_ids, MapSet.delete(socket.assigns.expanded_task_ids, task_id))
         |> assign(:action_busy, Map.put(socket.assigns.action_busy, to_string(task_id), :pause))}
    end
  end

  # Task resume: ASYNC for the same reason (the re-enqueue admits the task and
  # spawns its wrapper). Resume needs NO confirmation — the card's control
  # posts here directly, and an unavailable node/task id is a silent no-op.
  @impl true
  def handle_event("resume_task", %{"task_id" => task_id}, socket)
      when is_binary(task_id) and task_id != "" do
    case socket.assigns.current_node do
      nil ->
        {:noreply, socket}

      node ->
        EvoDash.SafeCall.start(self(), {:resume_result, task_id}, fn ->
          EvoDash.NodeContext.resume_task(node, task_id)
        end)

        {:noreply,
         socket
         |> assign(:expanded_task_ids, MapSet.delete(socket.assigns.expanded_task_ids, task_id))
         |> assign(:action_busy, Map.put(socket.assigns.action_busy, to_string(task_id), :resume))}
    end
  end

  def handle_event("resume_task", _params, socket), do: {:noreply, socket}

  # ASYNC: a delete cascades through the task's archives and durable agent
  # state, so it runs off-process. Result: `{{:delete_result, id}, result}`.
  @impl true
  def handle_event("delete_task", %{"task_id" => task_id}, socket) do
    start_task_mutation(socket, :delete, :delete_result, task_id, fn ->
      EvoDash.NodeContext.delete_task(socket.assigns.current_node, task_id)
    end)
  end

  # Helpers

  # Builds the /tasks URL from the CURRENT filter assigns (`overrides` carries
  # the value(s) being changed) — the ONE URL builder for the page, including
  # the `?node=` param so a filter/pagination navigation stays on the same node.
  #
  # Only NON-DEFAULT values are emitted (page 1, status/project/review/session
  # "all", q ""), so the plain list stays a bare `/tasks`. Every value is
  # query-encoded because the project filter is an absolute filesystem path.
  # Never uses `Helpers.with_node_param/2` (it appends "?") and NEVER emits
  # `task`: a filter change while a focused `?task=<id>` view is active DROPS
  # the focus, i.e. focus mode exits instead of silently narrowing to nothing.
  defp tasks_url(socket, page, overrides \\ []) do
    page = page |> to_string() |> parse_page()
    assigns = socket.assigns

    status = Keyword.get(overrides, :status, assigns.status_filter)
    project = Keyword.get(overrides, :project, assigns.project_filter)
    review = Keyword.get(overrides, :review, assigns.review_status_filter)
    session = Keyword.get(overrides, :session, assigns.session_mode_filter)
    query = Keyword.get(overrides, :q, assigns.search_query)

    pairs =
      [
        {"page", if(page > 1, do: page)},
        {"status", non_default(status, "all")},
        {"project", non_default(project, "all")},
        {"review", non_default(review, "all")},
        {"session", non_default(session, "all")},
        {"q", non_default(query, "")},
        {"node", Map.get(assigns, :current_node_id)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join("&", fn {key, value} ->
        "#{key}=#{URI.encode_www_form(to_string(value))}"
      end)

    case pairs do
      "" -> "/tasks"
      query_string -> "/tasks?" <> query_string
    end
  end

  defp non_default(value, default), do: if(value == default, do: nil, else: value)

  # Whitelist one query-string/event value against the option vocabulary; an
  # absent, non-binary or unknown value keeps the fallback (never an atom
  # conversion, never a raise).
  defp whitelisted(value, allowed, fallback) do
    if is_binary(value) and value in allowed, do: value, else: fallback
  end

  # A project filter is an absolute OS path, so there is no static whitelist:
  # any non-empty binary passes, and an absent/blank value keeps the fallback.
  defp binary_or(value, _fallback) when is_binary(value) and value != "", do: value
  defp binary_or(_value, fallback), do: fallback

  # The search query is kept VERBATIM (the query string already decoded it);
  # absent/non-binary means "no search".
  defp seed_query(value) when is_binary(value), do: value
  defp seed_query(_value), do: ""

  # Seeds the five URL-addressed filters. Defaults match what `tasks_url/3`
  # omits, so the URL and the assigns can never disagree.
  defp seed_filters(socket, params) do
    assign(socket,
      status_filter: whitelisted(params["status"], @status_filters, "all"),
      project_filter: binary_or(params["project"], "all"),
      review_status_filter: whitelisted(params["review"], @review_filters, "all"),
      session_mode_filter: whitelisted(params["session"], @session_filters, "all"),
      search_query: seed_query(params["q"])
    )
  end

  # Parses the ?page= query param into a positive integer (default 1).
  # Uses Integer.parse/1 (returns :error for non-integers) — no try/rescue,
  # no String.to_existing_atom.
  defp parse_page(nil), do: 1

  defp parse_page(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  # Returns a windowed range of page numbers around the current page for the
  # pagination button group. Shows up to 7 page buttons centered on the
  # current page, clamped to the valid range 1..total_pages.
  defp page_window(current_page, total_pages) do
    window = 3
    start_page = max(1, current_page - window)
    end_page = min(total_pages, current_page + window)
    Enum.to_list(start_page..end_page)
  end

  # Human label for the active session-kind filter chip (whitelist match, so no
  # atom conversion; gettext-wrapped).
  defp session_mode_label("oneshot"), do: gettext("One-shot tasks")
  defp session_mode_label("interactive"), do: gettext("Interactive sessions")
  defp session_mode_label(_), do: gettext("All task kinds")

  # Human label for the active STATUS filter chip. `needs_review` is the derived
  # triage value, so it has no stored-status label of its own — every other
  # value (a stored status string) delegates to the shared helper.
  defp status_filter_label("needs_review"), do: gettext("Needs review")
  defp status_filter_label(status), do: task_status_label(status)

  # The task count line. `needs_review` is a triage queue, so it counts "tasks
  # that need review" instead of "tasks found"; every other filter keeps the
  # generic wording.
  defp count_line("needs_review", count) do
    dngettext(
      "default",
      "%{count} task needs review",
      "%{count} tasks need review",
      count
    )
  end

  defp count_line(_status_filter, count) do
    dngettext("default", "%{count} task found", "%{count} tasks found", count)
  end

  # Resolves an idle session's agent id from the page load's
  # `%{task_id => agent_id}` map. Tolerant of the KEY TYPE: a card posts its
  # `phx-value-task_id` as a STRING while the loader may key the map by the
  # task's integer id, so both shapes are tried. Unknown → nil.
  defp session_agent_id(sessions, task_id) when is_map(sessions) do
    Map.get(sessions, task_id) ||
      Map.get(sessions, to_string(task_id)) ||
      integer_session_key(sessions, task_id)
  end

  defp session_agent_id(_sessions, _task_id), do: nil

  defp integer_session_key(sessions, task_id) when is_binary(task_id) do
    case Integer.parse(task_id) do
      {id, ""} -> Map.get(sessions, id)
      _ -> nil
    end
  end

  defp integer_session_key(_sessions, _task_id), do: nil

  # Applies an async session-send outcome: success flashes + reloads (the
  # session may have already resumed); every failure shape flashes its reason.
  # All documented shapes are terminal, so a reply box can never wedge.
  defp session_message_result(socket, _task_id, {:ok, :ok}) do
    socket
    |> put_flash(:info, gettext("Message sent"))
    |> PageLoad.start(socket.assigns.current_page, false)
  end

  defp session_message_result(socket, _task_id, {:ok, {:error, reason}}),
    do: put_flash(socket, :error, session_send_error(reason))

  defp session_message_result(socket, _task_id, {:error, reason}),
    do: put_flash(socket, :error, session_send_error(reason))

  defp session_send_error(reason),
    do: gettext("Failed to send message: %{reason}", reason: inspect(reason))

  # Applies an async pause/resume outcome. The task's busy marker is cleared on
  # EVERY arm — success or failure — so a failed action can never leave a
  # permanently disabled/spinning control on the card. Success also collapses
  # the card (its status just changed) and reloads the page ASYNCHRONOUSLY.
  defp pause_resume_result(socket, task_id, action, result) do
    socket =
      socket
      |> assign(:action_busy, Map.delete(socket.assigns.action_busy, to_string(task_id)))
      |> assign(:expanded_task_ids, MapSet.delete(socket.assigns.expanded_task_ids, task_id))

    case result do
      {:ok, :ok} ->
        PageLoad.start(socket, socket.assigns.current_page, false)

      # The documented refusals are VALUES: `NodeContext.pause_task/2` returns
      # `{:error, reason}` for them, while a transport/exit failure arrives as
      # SafeCall's own `{:error, reason}`.
      {:ok, {:error, reason}} ->
        put_flash(socket, :error, pause_resume_error(action, reason))

      {:error, reason} ->
        put_flash(socket, :error, pause_resume_error(action, reason))
    end
  end

  # ONE precise, gettext-wrapped line per documented refusal — an operator can
  # act on these, while a bare `inspect/1` (reserved for the genuinely
  # unexpected default arm) tells them nothing.
  defp pause_resume_error(_action, :not_found), do: gettext("Task not found.")

  defp pause_resume_error(_action, :not_running),
    do: gettext("Only a running task can be paused.")

  # zh_CN: 交互式会话任务不支持暂停（其生命周期由用户驱动）
  defp pause_resume_error(_action, :not_pausable),
    do: gettext("This task cannot be paused (interactive sessions can't be paused).")

  # zh_CN: 未开启持久化 agent 状态的任务没有可恢复的运行记录
  defp pause_resume_error(_action, :not_resumable),
    do: gettext("This task can't be resumed because durable agent state is disabled for it.")

  defp pause_resume_error(_action, :scheduler_unavailable),
    do: gettext("The scheduler is unavailable right now.")

  defp pause_resume_error(_action, :not_paused),
    do: gettext("Only a paused task can be resumed.")

  # A cross-node TRANSPORT failure: `EvoGit.RemoteNode.call_remote/4` wraps an
  # `:erpc` failure as `{:error, {kind, reason}}`, and `EvoDash.SafeCall`
  # captures a local exit/raise/throw the same way. The task's state was never
  # touched, so one generic line is more honest than an inspected tuple.
  defp pause_resume_error(_action, {kind, _reason}) when kind in [:exit, :throw, :error],
    do: gettext("The node could not be reached — the task's state is unchanged.")

  defp pause_resume_error(:pause, reason),
    do: gettext("Failed to pause task: %{reason}", reason: inspect(reason))

  defp pause_resume_error(:resume, reason),
    do: gettext("Failed to resume task: %{reason}", reason: inspect(reason))

  # Normalizes a SafeCall-wrapped mutating store call to `:ok | {:error, reason}`.
  # The `EvoDash.NodeContext` mutating functions return `:ok | {:error, reason}`,
  # so `SafeCall.run/1` yields `{:ok, :ok}` / `{:ok, {:error, reason}}`, while a
  # caught exit/raise (store timeout, dead store) arrives as `{:error, reason}`.
  defp mutation_result({:ok, :ok}), do: :ok
  defp mutation_result({:ok, {:error, reason}}), do: {:error, reason}
  defp mutation_result({:error, reason}), do: {:error, reason}

  # --- Async task mutations -------------------------------------------------
  #
  # The five task mutations (cancel / force kill / close session / delete /
  # clear history) all touch the registry (or a remote node over :erpc), so they
  # NEVER run on the LiveView process. Each spawns through
  # `EvoDash.SafeCall.start/4`, which sends its tag VERBATIM — hence the NESTED
  # `{{tag, task_id}, result}` shape the matching `handle_info` clauses unwrap.

  # ONE spawn path for the four task-keyed mutations. The task id is marked busy
  # in the SAME `:action_busy` map the pause/resume pair uses (string key), which
  # both disables the control and guards a duplicate submit server-side.
  #
  # `SafeCall.start/4` sends NOTHING when the child cannot be started, so the
  # marker is cleared HERE on that arm — otherwise the control would stay
  # disabled forever. Every other outcome is settled by `task_mutation_result/4`.
  defp start_task_mutation(socket, action, tag, task_id, fun) do
    if action_busy?(socket.assigns.action_busy, task_id) do
      # A mutation for this task is already in flight — ignore the duplicate.
      {:noreply, socket}
    else
      socket =
        assign(
          socket,
          :action_busy,
          Map.put(socket.assigns.action_busy, to_string(task_id), action)
        )

      case SafeCall.start(self(), {tag, task_id}, fun) do
        {:ok, _pid} ->
          {:noreply, socket}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(
             :action_busy,
             Map.delete(socket.assigns.action_busy, to_string(task_id))
           )
           |> clear_confirm_assign(action)
           |> put_flash(:error, mutation_error(action, reason))}
      end
    end
  end

  # Settles an async task-mutation outcome. The busy marker and the confirmation
  # modal are cleared on EVERY arm (success, refusal, transport failure alike), so
  # a control can never wedge. Success collapses the card (its status just
  # changed) and reloads the page without blanking the list.
  defp task_mutation_result(socket, action, task_id, result) do
    socket =
      socket
      |> assign(:action_busy, Map.delete(socket.assigns.action_busy, to_string(task_id)))
      |> clear_confirm_assign(action)

    case mutation_result(result) do
      :ok ->
        socket
        |> delete_stream_row(action, task_id)
        |> assign(:expanded_task_ids, MapSet.delete(socket.assigns.expanded_task_ids, task_id))
        |> reload(socket.assigns.current_page)

      {:error, reason} ->
        put_flash(socket, :error, mutation_error(action, reason))
    end
  end

  # The confirmation assign each action was spawned from (delete has none — it is
  # posted directly by the card's dropdown, without a modal).
  defp clear_confirm_assign(socket, :cancel), do: assign(socket, :confirm_cancel_task_id, nil)

  defp clear_confirm_assign(socket, :force_kill),
    do: assign(socket, :confirm_force_kill_task_id, nil)

  defp clear_confirm_assign(socket, :close),
    do: assign(socket, :confirm_close_session_task_id, nil)

  defp clear_confirm_assign(socket, _action), do: socket

  defp mutation_error(:cancel, reason),
    do: gettext("Failed to cancel task: %{reason}", reason: inspect(reason))

  defp mutation_error(:force_kill, reason),
    do: gettext("Failed to force kill task: %{reason}", reason: inspect(reason))

  defp mutation_error(:close, reason),
    do: gettext("Failed to close session: %{reason}", reason: inspect(reason))

  defp mutation_error(:delete, reason),
    do: gettext("Failed to delete task: %{reason}", reason: inspect(reason))

  # Total read of the page's per-task busy map (`%{task_id_string => action}`).
  # nil (no task / no modal open) is never busy.
  defp action_busy?(_busy, nil), do: false
  defp action_busy?(busy, task_id) when is_map(busy), do: Map.has_key?(busy, to_string(task_id))
  defp action_busy?(_busy, _task_id), do: false

  # True when the node context resolved by `NodeAware.assign_node/2` changed
  # since the last page load. The captured `{node_id, node}` tuple is the SAME
  # dedup key NodeAware keeps in `:tasks_node_loaded`; a first load (nil) counts
  # as a change, which is what paints the first-load skeleton.
  defp node_context_changed?(previous_ctx, socket) do
    previous_ctx != {socket.assigns.current_node_id, socket.assigns.current_node}
  end

  # --- The keyed `:tasks` stream -------------------------------------------
  #
  # The rows are a LiveView stream (`phx-update="stream"`, row DOM id exactly
  # `task-<id>`) so an update patches ONE card's DOM node instead of
  # re-rendering the whole list. A landed page load is the ONLY place rows are
  # (re)populated, and it always RESETS — that covers the first load, a filter
  # or page change, a node switch and every background refresh.
  #
  # The plain `:tasks` / `:filtered_tasks` assigns are RETAINED alongside the
  # stream (the count line, the empty state, `ModalHelpers.view_full_options/2`
  # and the page's own tests read those lists) — streams live under
  # `socket.assigns.streams`, so the two coexist.
  defp put_tasks_stream(socket, rows),
    do: stream(socket, :tasks, rows, reset: true, dom_id: &task_dom_id/1)

  # The row's DOM id MUST stay exactly `task-<id>` (the card's inner ids and
  # every `#task-<id>-*` selector assume it), which the `:tasks` stream name
  # would otherwise prefix to `tasks-<id>`. Tolerant of atom/string-keyed rows.
  defp task_dom_id(task) when is_map(task),
    do: "task-#{Map.get(task, :id) || Map.get(task, "id")}"

  # A deleted task's row leaves the stream immediately. `stream_delete/3`
  # raises for a stream that was never created (the pre-first-page-load state),
  # so it only runs once a page load has populated the stream; every other
  # action just reloads, which resets the stream anyway.
  defp delete_stream_row(socket, :delete, task_id) do
    if socket.assigns |> Map.get(:streams, %{}) |> Map.has_key?(:tasks) do
      stream_delete(socket, :tasks, %{id: task_id})
    else
      socket
    end
  end

  defp delete_stream_row(socket, _action, _task_id), do: socket

  # Re-emit ONE row through the stream so a card whose EXPANDED / DETAIL state
  # just changed is patched in place. A stream row is not re-rendered when a
  # plain assign it reads (`@expanded_task_ids`, `@task_details`) changes, so
  # every arm that mutates those inputs must re-insert the affected row.
  # `stream_insert/3` keeps the captured `dom_id` fun, so nothing is re-configured.
  defp refresh_stream_row(socket, task_id) do
    streams = Map.get(socket.assigns, :streams, %{})

    row =
      socket.assigns
      |> Map.get(:tasks, [])
      |> Enum.find(&(Map.get(&1, :id) == task_id))

    if Map.has_key?(streams, :tasks) and is_map(row) do
      stream_insert(socket, :tasks, row)
    else
      socket
    end
  end

  # A stable binary identity of the LIST for the `ListEnter` hook: while it is
  # unchanged, only genuinely new row keys animate; when it changes (node,
  # filter, search, pagination) the hook reseeds a silent baseline so a
  # re-filtered page is not staggered. Built from the existing filter assigns
  # (nothing is atomized) — no extra assign is introduced.
  defp list_enter_scope(assigns) do
    node = assigns.current_node_id || "local"

    "tasks:#{node}:#{assigns.status_filter}:#{assigns.project_filter}:" <>
      "#{assigns.review_status_filter}:#{assigns.search_query}:" <>
      "#{assigns.session_mode_filter}:#{assigns.current_page}:" <>
      "#{assigns.show_reflect_tasks}:#{assigns.focused_task_id}"
  end

  # --- The ONE page-data reload path ---------------------------------------
  #
  # Every filter / search / pagination / session-kind change and every
  # post-mutation refresh goes through here so the list NEVER blanks mid-session.
  # `show_loading?` defaults to the FIRST-LOAD rule (no rows yet): only then is
  # the skeleton placeholder painted; a refresh keeps the mounted rows and raises
  # the thin `:tasks_refreshing` progress line instead (cleared in the
  # `{:tasks_page_loaded, ...}` handler on every outcome).
  defp reload(socket, page, show_loading? \\ nil)

  defp reload(socket, page, nil), do: reload(socket, page, socket.assigns.filtered_tasks == [])

  defp reload(socket, page, show_loading?) do
    socket = assign(socket, :tasks_refreshing, not show_loading?)
    PageLoad.start(socket, page, show_loading?)
  end
end
