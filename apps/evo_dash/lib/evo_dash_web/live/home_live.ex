defmodule EvoDashWeb.HomeLive do
  @moduledoc """
  ChatGPT-style chat page for the Genesis Assistant, driven by ONE long-lived
  interactive agent session per conversation.
  The user talks to Genesis itself: the first message starts a repo-less
  `EvoGit.Agents.SelfReflective` session on the current node through
  `NodeContext.start_session/2`, every later message goes to that same agent
  id through `NodeContext.send_session_message/4`, and the conversation is
  addressed in the URL as `?session=<agent_id>`
  (`EvoDashWeb.HomeLive.SessionActions`).
  When interactive sessions are unavailable on the node, the page falls back
  to the legacy one-shot `:reflect` task path (`NodeContext.start_task/3` with
  `mode: "reflect"` and NO `:path`) — one task per message.
  Either path tracks the chat task's root agent
  (`EvoGit.Agents.SelfReflective`) and streams its assistant turns into chat
  bubbles, and the user can stop the conversation gracefully (which preserves
  the final result).
  Everything is push-based: `"tasks"` and `"agents"` PubSub broadcasts drive
  the transcript (task lifecycle events + agent message-count changes), and
  the LiveView process NEVER blocks on a store / cross-node call: every
  store/RPC call is either a guarded per-click mutation (`SafeCall.run/1`
  — send / stop) or a supervised task (`SafeCall.start/4` or
  `Task.Supervisor` + `SafeCall.run/1` inside the body — the remote
  model-profile load, approval responses, and every agent / history / task
  fetch) with a monotonic seq stale-guard. `SafeCall` is the exit-safe
  boundary (a `GenServer.call` timeout or an `:erpc` to an unreachable node
  EXITS the caller, which `rescue` cannot catch). Node-aware like every other
  page: `?node=` selects the viewed node.
  Chats survive remounts: the full chat state is persisted in-memory via
  `ChatHistory` (local-node only, see `home_live/CONTEXT.md`) and a
  connected mount restores the current chat with a ONE-SHOT reconciliation
  fetch (no polling). A node switch starts a NEW persisted chat — the old chat
  stays in memory (its task belongs to the old node; events are node-filtered
  anyway).
  The most recent assistant entry renders as an answer-first column (task
  status + streamed text + collapsible "Thought process" section) — see
  `EvoDashWeb.HomeLive.AssistantMessage`. Finalized (non-streaming) assistant
  text renders as Markdown (`EvoDash.MarkdownRender`), and each assistant
  message carries a raw/markdown toggle + copy-text action row below the answer. The message surface (empty state +
  transcript list) lives in `EvoDashWeb.HomeLive.ChatMessages`; the user
  bubble lives in `EvoDashWeb.HomeLive.UserMessage`.
  """
  use EvoDashWeb, :live_view
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.HomeLive.{
    ApprovalDialogState,
    ApprovalWorkflow,
    AttachPipeline,
    AttachmentPipeline,
    ChatBootstrap,
    SendPath,
    SessionResolution,
    StreamFold,
    TaskEvents,
    TaskPicker,
    TaskTracking,
    Watch,
    WorkbenchScope,
    Workspace
  }

  import EvoDashWeb.HomeLive.ChatMessages
  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:workspace, fn -> nil end)
      # Seeded by the global on-mount hooks (`NodeAware` seeds the node
      # bookkeeping, `Appearance` the accent), so these are no-ops in the real
      # mount path and cover a direct template render with a partial assign map.
      |> assign_new(:remote_targets, fn -> [] end)
      |> assign_new(:connection_statuses, fn -> %{} end)
      |> assign_new(:accent_color, fn -> "blue" end)
      |> assign(:draft_project, Workspace.draft_project(assigns))
      |> assign(:stream_error, Watch.failure(assigns))
      |> assign(:approval_host, ApprovalWorkflow.notification_host(assigns))
      |> assign(
        :approval_strip_open,
        EvoDashWeb.HomeLive.ApprovalDialogState.approval_strip_open?(assigns)
      )

    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:assistant}
      current_node_id={@current_node_id}
      remote_targets={@remote_targets}
      connection_statuses={@connection_statuses}
      workbench_project={(@workspace && @workspace.path) || @draft_project}
      workbench_git_project={@workspace && @workspace.path}
      workbench_draft={assigns[:workbench_draft]}
      workbench_draft_project={@draft_project}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      pending_tasks={@pending_tasks}
      session_list={@session_list}
      session_list_loading={@session_list_loading}
      session_list_error={@session_list_error}
      current_session_id={@current_session_id}
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
      accent_color={@accent_color}
    >
      <div id="assistant-surface" class="assistant-surface h-full min-h-0 w-full">
        <div class={[
          "assistant-column relative mx-auto flex h-full min-h-0 w-full max-w-[58rem] flex-col",
          (@transcript == [] and @chat_status != :ended) && "is-empty justify-center"
        ]}>
          <!-- The header, answers and composer share one reading column. -->
          <div
            id="chat-header"
            class="assistant-page-header"
          >
            <div class="min-w-0 basis-full sm:basis-auto sm:flex-1">
              <h1 class={
                if @transcript == [], do: "sr-only", else: "text-sm font-medium text-base-content/60"
              }>
                <%!-- zh_CN: Genesis Assistant 是此对话助手的名称 --%>{gettext(
                  "Genesis Assistant"
                )}
              </h1>
            </div>
            <button
              :if={@transcript != []}
              type="button"
              phx-click={if !@workspace, do: "new_chat"}
              data-workbench-new-conversation={if @workspace, do: ""}
              disabled={is_nil(@workspace) and @chat_status not in [:idle, :ended]}
              class="ml-auto inline-flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium text-base-content/70 hover:bg-base-200 hover:text-base-content transition-colors focus-visible:outline-2 focus-visible:outline-primary-standalone disabled:opacity-40 disabled:pointer-events-none shrink-0"
            >
              <.icon name="hero-plus" class="size-4" />
              <%!-- zh_CN: "新对话" --%>{gettext("New chat")}
            </button>
          </div>
          {EvoDashWeb.HomeLive.TaskCard.cards(assigns)}
          <div
            :if={@stream_error != nil and @stream_error != {:not_found, :session_not_found}}
            id="chat-stream-error"
            role="alert"
            class="shrink-0 flex items-center gap-2 px-3 py-2 text-xs text-warning sm:px-4"
          >
            <span class="flex-1">
              {gettext(
                "Live updates are unavailable. The conversation may still be running. Retry to reconnect."
              )}
            </span>
            <button
              type="button"
              phx-click="retry_chat_stream"
              class="btn btn-ghost btn-xs"
            >
              {gettext("Retry")}
            </button>
          </div>
          <!-- Messages container (the AgentHistoryAutoScroll hook scrolls this element) -->
          <div
            id="chat-messages"
            phx-hook="AgentHistoryAutoScroll"
            class="assistant-messages scrollbar-thin"
          >
            <!-- An EMPTY transcript shows one of two empty states: the ended
               session (the session is gone AND nothing was cached, so the
               greeting's suggestion chips could only start a doomed send) or
               the normal greeting. -->
            <%= cond do %>
              <% @transcript == [] and @chat_status == :ended -> %>
                <.session_ended_state scoped?={not is_nil(@workspace)} />
              <% @transcript == [] -> %>
                <.empty_state />
              <% true -> %>
                <.message_list
                  transcript={@transcript}
                  chat_task_status={@chat_task_status}
                  raw_entry_ids={@raw_entry_ids}
                  stream_meta={@chat_stream_meta}
                  stream_unavailable={@stream_error != nil}
                />
            <% end %>
            <!-- Transient queued-message echoes are NOT transcript entries: they
               render AFTER the last entry, inside the scroller. -->
            {EvoDashWeb.HomeLive.Composer.queued_echoes(assigns)}
          </div>
          <!-- Approval surface: ONE fixed-height status strip. Its height is
             reserved whether or not anything is pending, so a request arriving
             or being resolved never reflows the transcript column (the
             historical cause of the chat "shaking" at the end of a turn).
             Decisions happen in the single-request dialog below, opened from
             the strip's Review button or automatically for a NEW live request.
             The strip stays MOUNTED and collapses through the shared
             `motion-collapse-grid` helper (`data-motion-open`), so showing and
             hiding it both animate instead of jumping the column. -->
          <div
            id="assistant-notifications"
            phx-hook="BrowserNotifications"
            class="motion-collapse-grid shrink-0"
            data-motion-open={to_string(@approval_strip_open)}
            data-approval-request-ids={Jason.encode!(@approval_host.request_ids)}
            data-approval-scope={@approval_host.scope}
            data-notification-label-unsupported={gettext("Notifications unavailable")}
            data-notification-label-default={gettext("Notifications not enabled")}
            data-notification-label-denied={gettext("Notifications blocked")}
            data-notification-label-granted={gettext("Notifications enabled")}
            data-notification-label-requesting={gettext("Requesting notification permission…")}
            data-notification-label-error={gettext("Notifications failed — review approvals here")}
          >
            <!-- The grid helper collapses/expands its DIRECT children only, and
               animates grid rows — never a raw height — so the whole visible
               strip lives in this one `h-10` child. -->
            <div class="flex h-10 items-center">
              <div class="min-w-0 flex-1">
                {EvoDashWeb.HomeLive.ApprovalDialog.approval_bar(assigns)}
              </div>
              <!-- Permission is requested only by this explicit user control.
                 The end slot shares the approval strip's reserved height. -->
              <div class="flex shrink-0 items-center gap-1 pr-3 sm:pr-4">
                <button
                  type="button"
                  data-enable-notifications
                  class="btn btn-ghost btn-xs btn-square"
                  aria-label={gettext("Enable notifications")}
                  title={gettext("Enable notifications")}
                >
                  <.icon name="hero-bell" class="size-3.5" />
                </button>
                <span
                  data-notification-status
                  role="status"
                  aria-label={gettext("Notification permission status")}
                  class="max-w-16 truncate text-[10px] text-base-content/60 sm:max-w-24"
                >
                  {gettext("Notifications not enabled")}
                </span>
              </div>
            </div>
          </div>
          <%= if @approval_dialog_open do %>
            {EvoDashWeb.HomeLive.ApprovalDialog.approval_dialog(assigns)}
          <% end %>
          <!-- Interrupt affordance: sits with the composer while a turn runs.
             It NEVER halts a chunk — the draft is delivered at the next turn
             boundary (gettext("Send now (interrupt turn)")). The slot keeps a
             CONSTANT height so the affordance disappearing at the end of a turn
             cannot reflow the column. -->
          <div class={[
            "shrink-0 flex h-7 items-center justify-between gap-2 px-3 sm:px-4",
            @transcript == [] and @pending_approvals == [] and "hidden!"
          ]}>
            <div class="min-w-0 flex-1">
              <EvoDashWeb.HomeLive.ExecutionIndicator.execution_indicator
                chat_status={@chat_status}
                chat_task_status={@chat_task_status}
                chat_stream={assigns[:chat_stream]}
                pending_approval_count={length(@approval_host.request_ids)}
              />
            </div>
            <div class="shrink-0">
              {EvoDashWeb.HomeLive.Composer.interrupt_button(assigns)}
            </div>
          </div>
          <!-- Composer: pinned bottom, outside the messages scroller. ONE form
             owns the textarea's `chat_input` draft handler, the pending
             attachment chips, the shared provider/model/reasoning capsule and
             the Send/Stop controls; the attach affordance and its manual-path
             fallback sit outside it because no form may ever be nested. -->
          {EvoDashWeb.HomeLive.Composer.composer(assigns)}
          <.quick_actions :if={@transcript == [] and @chat_status != :ended} />
        </div>
      </div>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, :page_title, gettext("Genesis Assistant"))

    onboarding_needed =
      !connected?(socket) and
        if Code.ensure_loaded?(EvoGit.Config.VersionState) do
          EvoGit.Config.VersionState.onboarding_needed?()
        else
          false
        end

    cond do
      connected?(socket) and static_changed?(socket) ->
        # Reconnect with matching CSS/JS before rendering the updated assistant.
        {:ok,
         redirect(socket,
           to: ~p"/assistant?#{Map.take(params, ~w(node session wb_project wb_draft))}"
         )}

      onboarding_needed ->
        {:ok, push_navigate(socket, to: "/welcome")}

      true ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "agents")
          Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")
        end

        socket =
          socket
          |> assign(ChatBootstrap.base_assigns())
          |> ChatBootstrap.init()

        {:ok, socket}
    end
  end

  @doc "Every assign the page owns at mount time — `EvoDashWeb.HomeLive.ChatBootstrap`."
  defdelegate base_assigns(), to: ChatBootstrap

  # The `handle_params/3` pipeline (node context, chat scope, model selection and
  # the `?session=` / `?wb_draft=` conversation resolution).
  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, SessionResolution.run(socket, params)}
  end

  # Hand-offs `EvoDashWeb.HomeLive.SendPath` calls back into the page for.
  defdelegate maybe_recover_approvals(socket), to: ApprovalDialogState
  defdelegate spawn_attach(socket, session_id), to: AttachPipeline
  defdelegate attach_stream(socket), to: StreamFold
  defdelegate maybe_load_sessions(socket), to: AttachPipeline
  defdelegate async_lookup_agent(socket, node_override \\ nil), to: AttachPipeline

  @impl true
  def handle_event("workspace_toggle", _params, socket),
    do: WorkbenchScope.workspace_toggle(socket)

  def handle_event("workspace_close", _params, socket), do: WorkbenchScope.workspace_close(socket)

  def handle_event("workspace_clear", _params, socket), do: WorkbenchScope.workspace_clear(socket)

  def handle_event("workspace_path", params, socket),
    do: WorkbenchScope.workspace_path(socket, params)

  def handle_event("workspace_open", params, socket),
    do: WorkbenchScope.workspace_open(socket, params)

  def handle_event("workspace_select", params, socket),
    do: WorkbenchScope.workspace_select(socket, params)

  def handle_event("workspace_pick", params, socket),
    do: WorkbenchScope.workspace_pick(socket, params)

  def handle_event("workspace_expand", params, socket),
    do: WorkbenchScope.workspace_expand(socket, params)

  def handle_event("assistant_task_picker_open", _params, socket),
    do: {:noreply, TaskPicker.load(socket, TaskPicker.view(socket.assigns).query)}

  def handle_event("assistant_task_picker_search", %{"query" => query}, socket),
    do: {:noreply, TaskPicker.load(socket, query)}

  def handle_event("assistant_task_picker_more", _params, socket),
    do: {:noreply, TaskPicker.load(socket, TaskPicker.view(socket.assigns).query, true)}

  def handle_event("assistant_follow_task", %{"task_id" => id}, socket),
    do: TaskTracking.follow(socket, id)

  def handle_event("assistant_task_message", %{"task_id" => id, "message" => message}, socket),
    do:
      TaskTracking.action(socket, "genesis_send_message", %{"task_id" => id, "message" => message})

  def handle_event("assistant_task_cancel", %{"task_id" => id}, socket),
    do: TaskTracking.action(socket, "genesis_cancel_task", %{"task_id" => id})

  def handle_event("send_message", %{"message" => text}, socket), do: send_chat(socket, text)

  def handle_event("send_message", _params, socket),
    do: send_chat(socket, socket.assigns[:chat_draft])

  def handle_event("chat_input", params, socket), do: ChatBootstrap.chat_input(socket, params)

  def handle_event("select_provider_profile", params, socket),
    do: WorkbenchScope.select_provider(socket, params)

  def handle_event("select_model", params, socket),
    do: WorkbenchScope.select_model(socket, params)

  def handle_event("select_reasoning_effort", params, socket),
    do: WorkbenchScope.select_reasoning_effort(socket, params)

  def handle_event("toggle_assistant_raw", params, socket),
    do: ChatBootstrap.toggle_assistant_raw(socket, params)

  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
  end

  def handle_event("download_source", _params, socket),
    do: WorkbenchScope.download_source(socket)

  def handle_event("retry_chat_stream", _params, socket) do
    if Watch.failure(socket.assigns) != nil do
      {:noreply, attach_stream(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("new_chat", _params, socket), do: ChatBootstrap.new_chat(socket)

  def handle_event("stop", _params, socket) do
    cond do
      ChatBootstrap.interactive_session?(socket) -> TaskEvents.stop_reply(socket)
      not is_nil(socket.assigns[:chat_task_id]) -> TaskEvents.cancel_chat_task(socket)
      true -> {:noreply, socket}
    end
  end

  def handle_event("interrupt_turn", _params, socket) do
    if socket.assigns[:chat_status] == :running do
      send_draft(socket, socket.assigns[:chat_draft], :interrupt)
    else
      {:noreply, socket}
    end
  end

  def handle_event("chat_upload_validate", _params, socket),
    do: AttachmentPipeline.upload_validate(socket)

  def handle_event("chat_upload_cancel", params, socket),
    do: AttachmentPipeline.upload_cancel(socket, params)

  def handle_event("chat_upload_clear_error", _params, socket),
    do: AttachmentPipeline.upload_clear_error(socket)

  def handle_event("chat_attach", params, socket),
    do: AttachmentPipeline.chat_attach(socket, params)

  def handle_event("chat_attach_manual", params, socket),
    do: AttachmentPipeline.chat_attach_manual(socket, params)

  def handle_event("chat_attachment_remove", params, socket),
    do: AttachmentPipeline.remove_attachment(socket, params)

  def handle_event("approval_response", params, socket),
    do: ApprovalDialogState.respond(socket, params)

  def handle_event("retry_approvals", _params, socket), do: ApprovalDialogState.retry(socket)

  def handle_event("review_approval_notification", params, socket),
    do: ApprovalDialogState.notification_clicked(socket, params)

  def handle_event("open_approval_dialog", _params, socket),
    do: ApprovalDialogState.open_dialog(socket)

  def handle_event("dialog_closed", _params, socket),
    do: ApprovalDialogState.dialog_closed(socket)

  def handle_event("prev_approval", _params, socket), do: ApprovalDialogState.prev(socket)

  def handle_event("next_approval", _params, socket), do: ApprovalDialogState.next(socket)

  @impl true
  def handle_info({:task_updated, _task_id, _status, _node} = msg, socket),
    do: TaskEvents.task_updated(socket, msg)

  def handle_info({:task_deleted, _task_id, _node} = msg, socket),
    do: TaskEvents.task_deleted(socket, msg)

  def handle_info({:agent_registered, _id, _summary, _node} = msg, socket),
    do: TaskEvents.agent_registered(socket, msg)

  def handle_info({:agent_updated, _id, _changed_fields, _node} = msg, socket),
    do: TaskEvents.agent_updated(socket, msg)

  def handle_info({:agent_removed, _id, _node} = msg, socket),
    do: TaskEvents.agent_removed(socket, msg)

  def handle_info({:agents_updated, _node} = msg, socket),
    do: TaskEvents.agents_updated(socket, msg)

  def handle_info({:approval_requested, request}, socket),
    do: ApprovalDialogState.requested(socket, request)

  def handle_info({:approval_resolved, request_id, _decision, source_node}, socket),
    do: ApprovalDialogState.resolved(socket, request_id, source_node)

  def handle_info({:approval_resolved, request_id, _decision}, socket),
    do: ApprovalDialogState.resolved(socket, request_id)

  def handle_info(:node_aware_reload_tasks, socket),
    do: TaskEvents.node_aware_reload_tasks(socket)

  def handle_info({:chat_agent_lookup, _node, _seq, _task_id, _stream_seq, _agent} = msg, socket),
    do: AttachPipeline.handle_info(socket, msg)

  def handle_info(
        {:chat_history_loaded, _node, _seq, _agent_id, _stream_seq, _result} = msg,
        socket
      ),
      do: AttachPipeline.handle_info(socket, msg)

  def handle_info({:chat_task_loaded, _node, _seq, _task_id, _task} = msg, socket),
    do: TaskEvents.chat_task_loaded(socket, msg)

  # The async send answer keeps its own monotonic generation plus the identity it
  # was issued for, so a superseded answer is DROPPED instead of mutating a
  # different chat (`SendPath.apply_send_result/3`).
  def handle_info({{:chat_send_result, seq}, result}, socket) do
    {:noreply, SendPath.apply_send_result(socket, seq, result)}
  end

  def handle_info({{:chat_stop_result, _seq, _node, _session_id}, _result} = msg, socket),
    do: TaskEvents.chat_stop_result(socket, msg)

  def handle_info(
        {{:chat_finish_result, _seq, _node, _task_id, _assigns, _reload?}, _result} = msg,
        socket
      ),
      do: TaskEvents.chat_finish_result(socket, msg)

  def handle_info(
        {{:assistant_workspace_loaded, seq, scope, chat_id, kind}, result},
        socket
      ),
      do: SessionResolution.workspace_loaded(socket, seq, scope, chat_id, kind, result)

  def handle_info({:assistant_action_reconcile, _scope} = msg, socket),
    do: TaskEvents.assistant_action_reconcile(socket, msg)

  def handle_info({{:assistant_action_status, _scope, _id}, _result} = msg, socket),
    do: TaskEvents.assistant_action_status(socket, msg)

  def handle_info({{:assistant_follow_result, _scope}, _result} = msg, socket),
    do: TaskEvents.assistant_follow_result(socket, msg)

  def handle_info({{:assistant_task_choices, _seq, _scope, _offset}, _result} = msg, socket),
    do: TaskEvents.assistant_task_choices(socket, msg)

  def handle_info(:assistant_tasks_tick, socket),
    do: TaskEvents.assistant_tasks_tick(socket, :assistant_tasks_tick)

  def handle_info({{:assistant_tasks_loaded, _seq, _scope}, _result} = msg, socket),
    do: TaskEvents.assistant_tasks_loaded(socket, msg)

  def handle_info({{:assistant_task_action, _scope, _id}, _result} = msg, socket),
    do: TaskEvents.assistant_task_action(socket, msg)

  def handle_info({:source_availability_loaded, _seq, _node, _result} = msg, socket),
    do: WorkbenchScope.source_availability_loaded(socket, msg)

  def handle_info({:source_clone_result, _node, _result} = msg, socket),
    do: WorkbenchScope.source_clone_result(socket, msg)

  # A recovery snapshot mutates `pending_approvals` too, so the dialog cursor is
  # re-derived: an empty result closes the dialog instead of leaving it "open".
  def handle_info({{:approval_pending_loaded, _seq, _scope} = tag, result}, socket),
    do: ApprovalDialogState.pending_loaded(socket, tag, result)

  def handle_info({{:approval_workflow_response, _seq, _scope, _id} = tag, result}, socket),
    do: ApprovalDialogState.workflow_response(socket, tag, result)

  def handle_info({{:model_select_loaded, _seq, _target_node}, _result} = msg, socket),
    do: WorkbenchScope.model_select_loaded(socket, msg)

  def handle_info(
        {{:session_attached, _seq, _node, _session_id, _stream_seq}, _result} = msg,
        socket
      ),
      do: AttachPipeline.handle_info(socket, msg)

  def handle_info({:node_selected, _node_id} = msg, socket),
    do: WorkbenchScope.node_selected(socket, msg)

  def handle_info({:remote_connection_status, _target_id, _status} = msg, socket),
    do: WorkbenchScope.remote_connection_status(socket, msg)

  def handle_info({:directory_picker_result, _picker_id, _result} = msg, socket),
    do: AttachmentPipeline.handle_info(socket, msg)

  # Watch owns sequence gating, registration-time buffering and failed watches.
  def handle_info({:agent_delta, _agent_id, _seq, _batch} = msg, socket),
    do: StreamFold.handle_info(socket, msg)

  def handle_info({:agent_stream_closed, _agent_id, _snapshot, _seq} = msg, socket),
    do: StreamFold.handle_info(socket, msg)

  def handle_info({:chat_stream_ready, _node, _seq, _agent_id, _result} = msg, socket),
    do: StreamFold.handle_info(socket, msg)

  def handle_info({:DOWN, _ref, :process, _pid, _reason} = msg, socket),
    do: StreamFold.handle_info(socket, msg)

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # The composer send path lives in `EvoDashWeb.HomeLive.SendPath`; these thin
  # delegations keep every call site (handle_event / handle_info) unchanged.
  defp send_chat(socket, text), do: SendPath.send_chat(socket, text)

  defp send_draft(socket, text, policy), do: SendPath.send_draft(socket, text, policy)

  # Best-effort unwatch on page teardown. The REAL reaper is the session's own
  # monitor on the LiveView pid (a `:DOWN` removes the watcher set entry), so a
  # lost/failed unregister here costs nothing.
  @impl true
  def terminate(_reason, socket) do
    _ = Watch.detach(socket)
    :ok
  end
end
