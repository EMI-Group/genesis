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
    AgentStream,
    ApprovalWorkflow,
    Attachments,
    ChatState,
    Delta,
    Messages,
    ModelSelection,
    SendPath,
    SessionActions,
    SessionList,
    SourceGate,
    Transcript,
    Watch
  }

  alias EvoDash.{
    AttachedFile,
    ChatHistory,
    DirectoryPicker,
    NodeContext,
    SafeCall,
    TaskSupervisor
  }

  alias EvoDashWeb.LiveHooks.NodeAware
  import EvoDashWeb.HomeLive.ChatMessages
  import EvoDashWeb.HomeLive.SourceGate
  @terminal_statuses [:completed, :cancelled, :failed]

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:assistant}
      current_node_id={@current_node_id}
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
      accent_color={assigns[:accent_color] || "blue"}
    >
      <div class="flex h-full min-h-0 w-full min-w-0">
        <div class="flex h-full min-h-0 w-full min-w-0 max-w-3xl flex-col mx-auto">
          <!-- The header, answers and composer share one reading column. -->
          <div
            id="chat-header"
            class="shrink-0 flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-base-300 px-3 pt-3 pb-3 sm:px-4 sm:pt-4"
          >
            <div class="min-w-0 basis-full sm:basis-auto sm:flex-1">
              <h1 class="text-base font-semibold truncate">
                <%!-- zh_CN: Genesis Assistant 是此对话助手的名称 --%>{gettext(
                  "Genesis Assistant"
                )}
              </h1>
            </div>
            <button
              type="button"
              phx-click="new_chat"
              disabled={@chat_status not in [:idle, :ended]}
              class="ml-auto inline-flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium text-base-content/70 hover:bg-base-200 hover:text-base-content transition-colors focus-visible:outline-2 focus-visible:outline-primary-standalone disabled:opacity-40 disabled:pointer-events-none shrink-0"
            >
              <.icon name="hero-plus" class="size-4" />
              <%!-- zh_CN: "新对话" --%>{gettext("New chat")}
            </button>
          </div>
          <!-- Genesis-source gate: the /assistant chat runs a repo-less `:reflect`
             agent whose reference is the managed Genesis source checkout. On a
             fresh install it is usually not downloaded yet, so a send would only
             start a doomed task. Pinned BETWEEN the header and the message
             scroller so it shows for the empty state AND a restored transcript.
             Local-node only (EvoDashWeb.HomeLive.SourceGate.blocked?/1). -->
          <%= if SourceGate.blocked?(assigns) do %>
            <.source_gate source_busy={@source_busy} current_node_id={@current_node_id} />
          <% end %>
          <!-- Messages container (the AgentHistoryAutoScroll hook scrolls this element) -->
          <div
            id="chat-messages"
            phx-hook="AgentHistoryAutoScroll"
            class="flex-1 min-h-0 min-w-0 overflow-y-auto overscroll-contain scrollbar-thin"
          >
            <!-- An EMPTY transcript shows one of two empty states: the ended
               session (the session is gone AND nothing was cached, so the
               greeting's suggestion chips could only start a doomed send) or
               the normal greeting. -->
            <%= cond do %>
              <% @transcript == [] and @chat_status == :ended -> %>
                <.session_ended_state />
              <% @transcript == [] -> %>
                <.empty_state source_gate?={SourceGate.blocked?(assigns)} />
              <% true -> %>
                <.message_list
                  transcript={@transcript}
                  chat_task_status={@chat_task_status}
                  thought_process={@thought_process}
                  raw_entry_ids={@raw_entry_ids}
                  stream_meta={@chat_stream_meta}
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
             the strip's Review button or automatically for a NEW live request. -->
          {EvoDashWeb.HomeLive.ApprovalDialog.approval_bar(assigns)}
          <%= if @approval_dialog_open do %>
            {EvoDashWeb.HomeLive.ApprovalDialog.approval_dialog(assigns)}
          <% end %>
          <!-- Browser-notification sink for a genuinely new approval request:
             the BrowserNotifications hook notifies only while the window is
             hidden/unfocused and dedupes by tag. -->
          <div
            id="assistant-notifications"
            phx-hook="BrowserNotifications"
            class="hidden"
            aria-hidden="true"
          >
          </div>
          <!-- Interrupt affordance: sits with the composer while a turn runs.
             It NEVER halts a chunk — the draft is delivered at the next turn
             boundary (gettext("Send now (interrupt turn)")). The slot keeps a
             CONSTANT height so the affordance disappearing at the end of a turn
             cannot reflow the column. -->
          <div class="shrink-0 flex h-7 items-center justify-end px-3 sm:px-4">
            {EvoDashWeb.HomeLive.Composer.interrupt_button(assigns)}
          </div>
          <!-- Composer: pinned bottom, outside the messages scroller. ONE form
             owns the textarea's `chat_input` draft handler, the pending
             attachment chips, the shared provider/model/reasoning capsule and
             the Send/Stop controls; the attach affordance and its manual-path
             fallback sit outside it because no form may ever be nested. -->
          {EvoDashWeb.HomeLive.Composer.composer(assigns)}
        </div>
      </div>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    onboarding_needed =
      !connected?(socket) and
        if Code.ensure_loaded?(EvoGit.Config.VersionState) do
          EvoGit.Config.VersionState.onboarding_needed?()
        else
          false
        end

    if onboarding_needed do
      {:ok, push_navigate(socket, to: "/welcome")}
    else
      if connected?(socket) do
        Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
        Phoenix.PubSub.subscribe(EvoGit.PubSub, "agents")
        Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")
      end

      socket =
        socket
        |> assign(base_assigns())
        |> ApprovalWorkflow.init()
        |> attach_chat()

      {:ok, socket}
    end
  end

  defp base_assigns do
    %{
      transcript: Transcript.new(),
      chat_draft: "",
      chat_status: :idle,
      chat_task_id: nil,
      chat_agent_id: nil,
      agent_message_count: nil,
      chat_task_status: nil,
      thought_process: [],
      chat_node: nil,
      chat_id: nil,
      session_id: nil,
      current_session_id: nil,
      session_mode: nil,
      queued_echoes: [],
      session_attach_seq: 0,
      # Push-only delta stream state (`EvoDashWeb.HomeLive.Watch`): the
      # subscribed agent + its seeded `%Delta{}` (nil until the registration
      # snapshot lands), that snapshot's turn meta, and the monotonic attach seq.
      chat_stream: nil,
      chat_stream_meta: nil,
      stream_attach_seq: 0,
      # `:session_list` / `:session_list_loading` / `:session_list_error` /
      # `:session_list_seq` are seeded (and loaded) by
      # `EvoDashWeb.LiveHooks.NodeAware` — the layout sidebar owns the
      # Conversations section on every page, including this one.
      pending_attachments: Attachments.new(),
      attach_unavailable: false,
      chat_fetch_seq: 0,
      chat_task_fetch_seq: 0,
      shift_down: false,
      selected_model_id: nil,
      raw_entry_ids: MapSet.new(),
      # after handle_params resolves the node, never against mount's local seed.
      approval_context: nil,
      # Purely local view state for the approval review dialog; ApprovalWorkflow
      # owns the requests themselves and never touches these two.
      approval_dialog_open: false,
      approval_dialog_index: 0,
      provider_profiles: [],
      model_selections: [],
      model_spec: nil,
      model_selection_scope: nil,
      model_selection_error: nil,
      model_selection_restore: nil,
      model_selection_resolved: false,
      model_selection_enabled: false,
      model_snapshot: nil,
      model_selection_bundle: nil,
      model_select_loading: false,
      model_select_load_error: nil,
      model_select_seq: 0,
      source_available: nil,
      source_check_loading: false,
      source_check_seq: 0,
      source_busy: nil,
      current_path: ~p"/assistant"
    }
  end

  defp interactive_session?(socket) do
    socket.assigns[:session_mode] == :interactive and not is_nil(socket.assigns[:session_id])
  end

  defp resolve_session(socket, param) do
    case SessionActions.parse_session(param) do
      {:ok, id} ->
        if id == socket.assigns[:session_id], do: socket, else: reattach_session(socket, id)

      :none ->
        leave_session(socket)
    end
  end

  defp reattach_session(socket, id) do
    restored =
      if connected?(socket) do
        ChatState.restore(ChatHistory.get_state(id))
      else
        ChatState.restore(nil)
      end

    socket
    |> assign(
      session_id: id,
      current_session_id: id,
      chat_id: id,
      session_mode: :interactive,
      chat_agent_id: id,
      chat_node: socket.assigns[:current_node],
      chat_task_id: nil,
      chat_task_status: nil,
      agent_message_count: nil,
      queued_echoes: [],
      thought_process: restored.thought_process,
      raw_entry_ids: MapSet.new(),
      pending_attachments: Attachments.clear(),
      chat_draft: "",
      transcript: restored.transcript,
      chat_status: restore_status(restored.chat_status)
    )
    |> ApprovalWorkflow.init()
    |> maybe_recover_approvals()
    |> spawn_attach(id)
    |> attach_stream()
  end

  @doc """
  Attaches the page to the current `?session=` agent's PUSH-ONLY delta stream.

  The stream is seeded by a snapshot from `EvoDashWeb.HomeLive.Watch`, which
  also owns the consumer-local PubSub subscription; `SendPath.adopt_session/3`
  calls this for a freshly started session (whose URL push short-circuits
  `resolve_session/2`, so `reattach_session/2` never runs for it).
  """
  def attach_stream(socket), do: Watch.attach(socket)

  # `ChatState.restore/1` already whitelists the stored status; this defensive
  defp restore_status(status)
       when status in [:idle, :running, :cancelling, :awaiting_input, :ended],
       do: status

  defp restore_status(_status), do: :idle

  defp leave_session(socket) do
    if is_nil(socket.assigns[:session_id]) do
      socket
    else
      socket
      |> reset_chat()
      |> attach_chat()
      |> assign(
        session_id: nil,
        current_session_id: nil,
        session_mode: nil,
        queued_echoes: [],
        pending_attachments: Attachments.clear()
      )
      |> ChatState.persist()
    end
  end

  def spawn_attach(socket, session_id) do
    if connected?(socket) do
      seq = (socket.assigns[:session_attach_seq] || 0) + 1
      node = socket.assigns[:current_node]

      case SafeCall.start(self(), {:session_attached, seq, node, session_id}, fn ->
             SessionActions.load_attach(node, session_id)
           end) do
        {:ok, _pid} ->
          assign(socket, session_attach_seq: seq)

        {:error, reason} ->
          settle_attach(socket, {:error, reason})
      end
    else
      socket
    end
  end

  defp apply_attach(socket, {:ok, %{summary: summary, awaiting?: awaiting?, history: history}}) do
    status = SessionActions.status_from(summary, awaiting?)

    socket
    |> assign(
      chat_task_id: summary_value(summary, :task_id),
      chat_task_status: summary_value(summary, :status),
      agent_message_count: summary_value(summary, :message_count)
    )
    |> apply_history(history, true)
    |> assign(chat_status: attach_status(summary, awaiting?, status))
    |> ChatState.persist()
    |> maybe_load_sessions()
    |> maybe_recover_approvals()
  end

  defp apply_attach(socket, {:error, reason}), do: settle_attach(socket, {:error, reason})

  defp apply_attach(socket, _other),
    do: settle_attach(socket, {:error, :unexpected_attach_result})

  defp settle_attach(socket, _result) do
    status = if socket.assigns[:transcript] == [], do: :ended, else: :idle

    socket
    |> assign(chat_status: status)
    |> ChatState.persist()
  end

  defp attach_status(nil, false, _status), do: :ended

  defp attach_status(_summary, _awaiting?, status)
       when status in [:idle, :running, :cancelling],
       do: status

  defp attach_status(_summary, _awaiting?, _status), do: :ended
  # tolerated defensively for a foreign/legacy row).
  defp summary_value(summary, key) when is_map(summary) do
    case Map.fetch(summary, key) do
      {:ok, value} -> value
      :error -> Map.get(summary, Atom.to_string(key))
    end
  end

  defp summary_value(_summary, _key), do: nil

  defp apply_history(socket, messages, rebuild?) when is_list(messages) do
    %{transcript: built, entries: entries} = Messages.transcript(messages)
    text = Messages.assistant_text(messages)

    # A REBUILD from an EMPTY fetched history means the session is gone with
    # nothing to replay, so a non-empty locally cached transcript (and its
    # reasoning) is KEPT and rendered read-only instead of being wiped by `[]`.
    # A non-empty history always wins, and a first-ever attach with no cache
    # stays empty (the ended state).
    keep_cache? = rebuild? and messages == [] and socket.assigns[:transcript] not in [nil, []]

    transcript =
      cond do
        keep_cache? -> socket.assigns[:transcript]
        rebuild? -> built
        text == "" -> socket.assigns[:transcript]
        true -> Transcript.put_streaming_text(socket.assigns[:transcript], text)
      end

    assign(socket,
      transcript: transcript,
      agent_message_count: length(messages),
      thought_process: if(keep_cache?, do: socket.assigns[:thought_process] || [], else: entries)
    )
  end

  defp apply_history(socket, _messages, _rebuild?), do: socket

  def maybe_load_sessions(socket) do
    if connected?(socket) do
      SessionList.spawn_load(socket, socket.assigns[:current_node])
    else
      socket
    end
  end

  defp maybe_check_source(socket) do
    if connected?(socket) and SourceGate.visible?(socket.assigns[:current_node]) do
      seq = socket.assigns[:source_check_seq] + 1
      node = socket.assigns[:current_node] || node()
      SourceGate.spawn_availability_check(self(), seq, node)
      assign(socket, source_check_seq: seq, source_check_loading: true)
    else
      socket
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    prev_node = socket.assigns[:current_node]
    prev_node_id = socket.assigns[:current_node_id]
    socket = NodeAware.assign_node(socket, params)

    node_changed =
      socket.assigns.model_selection_resolved and
        (socket.assigns[:current_node] != prev_node or
           socket.assigns[:current_node_id] != prev_node_id)

    chat_node_mismatch =
      socket.assigns[:chat_node] != nil and
        socket.assigns[:chat_node] != socket.assigns[:current_node]

    scope = ModelSelection.selection_scope(socket)
    saved_selection = socket.assigns.model_selection_restore || socket.assigns

    saved_scope =
      if is_map(saved_selection), do: Map.get(saved_selection, :model_selection_scope)

    selection_scope_mismatch = not is_nil(saved_scope) and saved_scope != scope

    socket =
      socket
      |> assign(ChatState.restore_selection(saved_selection, scope))
      |> assign(model_selection_restore: nil, model_selection_resolved: true)

    socket =
      cond do
        node_changed or chat_node_mismatch or selection_scope_mismatch ->
          start_new_chat(socket)

        true ->
          socket
      end

    socket =
      socket
      |> resolve_session(params["session"])
      |> ModelSelection.assign_model_select()
      |> assign(current_path: ~p"/assistant")
      |> maybe_check_source()
      |> maybe_recover_approvals()

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", %{"message" => text}, socket), do: send_chat(socket, text)

  def handle_event("send_message", _params, socket),
    do: send_chat(socket, socket.assigns[:chat_draft])

  def handle_event("chat_input", %{"message" => text}, socket) do
    {:noreply, assign(socket, chat_draft: text || "")}
  end

  def handle_event("chat_keydown", %{"key" => key}, socket) do
    case key do
      "Shift" ->
        {:noreply, assign(socket, shift_down: true)}

      "Enter" ->
        if socket.assigns[:shift_down] do
          {:noreply, socket}
        else
          send_chat(socket, socket.assigns[:chat_draft])
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("chat_keyup", %{"key" => key}, socket) do
    case key do
      "Shift" -> {:noreply, assign(socket, shift_down: false)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("select_provider_profile", %{"provider_profile_id" => id}, socket) do
    ModelSelection.update_model_selection(socket, :select_provider, id)
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    ModelSelection.update_model_selection(socket, :select_model, model)
  end

  def handle_event("select_reasoning_effort", %{"reasoning_effort" => index}, socket) do
    ModelSelection.update_model_selection(socket, :select_reasoning_effort, index)
  end

  def handle_event("toggle_assistant_raw", %{"id" => id}, socket) when is_binary(id) do
    raw = socket.assigns[:raw_entry_ids] || MapSet.new()

    raw =
      if MapSet.member?(raw, id) do
        MapSet.delete(raw, id)
      else
        MapSet.put(raw, id)
      end

    {:noreply, assign(socket, raw_entry_ids: raw)}
  end

  def handle_event("toggle_assistant_raw", _params, socket), do: {:noreply, socket}

  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
  end

  def handle_event("download_source", _params, socket) do
    if socket.assigns[:source_busy] != nil do
      {:noreply, socket}
    else
      SourceGate.spawn_clone(self(), socket.assigns[:current_node] || node())
      {:noreply, assign(socket, source_busy: :clone)}
    end
  end

  def handle_event("new_chat", _params, socket) do
    if socket.assigns[:chat_status] in [:idle, :ended] do
      had_session? = not is_nil(socket.assigns[:session_id])

      socket =
        socket
        |> assign(session_id: nil, current_session_id: nil, session_mode: nil)
        |> start_new_chat()
        |> maybe_load_sessions()

      socket =
        if had_session? do
          push_patch(socket, to: SessionActions.url(socket.assigns[:current_node_id], nil))
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("stop", _params, socket) do
    cond do
      not is_nil(socket.assigns[:chat_task_id]) -> cancel_chat_task(socket)
      interactive_session?(socket) -> close_chat_session(socket)
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

  # ── Composer attachments ──
  # The attach affordance dispatches ONE whitelisted kind (pattern match, never
  # an atom conversion). The native picker runs on the LOCAL node only and
  # reports asynchronously ({:directory_picker_result, picker_id, result});
  # when it is unavailable the composer reveals its manual-path fallback.
  def handle_event("chat_attach", %{"kind" => kind}, socket) do
    {:noreply, begin_attach(socket, kind)}
  end

  def handle_event("chat_attach", _params, socket), do: {:noreply, socket}

  def handle_event("chat_attach_manual", %{"path" => path}, socket) do
    {:noreply, attach_manual(socket, path)}
  end

  def handle_event("chat_attach_manual", _params, socket), do: {:noreply, socket}

  def handle_event("chat_attachment_remove", %{"index" => index}, socket) do
    socket =
      case parse_attachment_index(index) do
        nil ->
          socket

        idx ->
          socket
          |> assign(
            pending_attachments: Attachments.remove(socket.assigns[:pending_attachments], idx)
          )
          |> ChatState.persist()
      end

    {:noreply, socket}
  end

  def handle_event("chat_attachment_remove", _params, socket), do: {:noreply, socket}

  def handle_event(
        "approval_response",
        %{"request_id" => request_id, "decision" => decision},
        socket
      ) do
    # The decision payload stays exactly the request id plus the whitelisted
    # decision — ApprovalWorkflow re-validates both. The dialog cursor is
    # re-derived from the (possibly shorter) request list afterwards.
    socket = ApprovalWorkflow.respond(socket, request_id, decision)
    {:noreply, sync_approval_dialog(socket)}
  end

  def handle_event("retry_approvals", _params, socket) do
    {:noreply, recover_approvals(socket)}
  end

  def handle_event("open_approval_dialog", _params, socket) do
    {:noreply, open_approval_dialog(socket)}
  end

  def handle_event("dialog_closed", _params, socket) do
    {:noreply, assign(socket, approval_dialog_open: false)}
  end

  def handle_event("prev_approval", _params, socket) do
    {:noreply, step_approval_dialog(socket, -1)}
  end

  def handle_event("next_approval", _params, socket) do
    {:noreply, step_approval_dialog(socket, 1)}
  end

  def handle_event("approval_response", _params, socket), do: {:noreply, socket}

  defp cancel_chat_task(socket) do
    node = socket.assigns[:current_node] || node()

    finish_chat(
      socket,
      fn -> NodeContext.cancel_task(node, socket.assigns[:chat_task_id]) end,
      [chat_status: :cancelling, chat_task_status: :cancelling, queued_echoes: []],
      false
    )
  end

  defp close_chat_session(socket) do
    node = socket.assigns[:current_node] || node()
    agent_id = socket.assigns[:session_id]

    case SafeCall.run(fn -> SessionActions.close(node, agent_id, :normal) end) do
      {:ok, {:error, reason}} ->
        {:noreply, stop_flash(socket, reason)}

      {:error, reason} ->
        {:noreply, stop_flash(socket, reason)}

      {:ok, _ok} ->
        # A closed session emits nothing further: finalize the in-flight bubble
        # and unwatch. The assign values stay EXACTLY what `stop_ok/3` sets.
        {:noreply,
         socket
         |> stop_ok([chat_status: :cancelling, queued_echoes: []], true)
         |> finalize_bubble()
         |> Watch.detach()
         |> ChatState.persist()}
    end
  end

  defp finish_chat(socket, fun, assigns, reload?) do
    case SafeCall.run(fun) do
      {:ok, {:error, reason}} -> {:noreply, stop_flash(socket, reason)}
      {:error, reason} -> {:noreply, stop_flash(socket, reason)}
      {:ok, _ok} -> {:noreply, stop_ok(socket, assigns, reload?)}
    end
  end

  defp stop_ok(socket, assigns, reload?) do
    socket = assign(socket, assigns)
    socket = if reload?, do: maybe_load_sessions(socket), else: socket
    ChatState.persist(socket)
  end

  # Justification: transport/exit reasons are untrusted terms, inspected for the operator.
  defp stop_flash(socket, reason) do
    put_flash(socket, :error, gettext("Failed to stop: %{reason}", reason: inspect(reason)))
  end

  ## Composer attachments

  # Picker id → attachment kind (the ONE place the mapping lives). Both the
  # picker ids and the 4-attachment / 15 MiB caps belong to
  # `EvoDashWeb.HomeLive.Attachments`, so they are read at call time.
  defp attach_kind(picker_id) do
    cond do
      picker_id == Attachments.picker_id() -> "text"
      picker_id == Attachments.picker_id_image() -> "image"
      picker_id == Attachments.picker_id_audio() -> "audio"
      true -> nil
    end
  end

  defp picker_id_for("text"), do: Attachments.picker_id()
  defp picker_id_for("image"), do: Attachments.picker_id_image()
  defp picker_id_for("audio"), do: Attachments.picker_id_audio()

  # Attachments are read from THIS node's filesystem, so the picker is local
  # only; a remote/pending target reveals the manual-path fallback instead of
  # attaching a file the agent could never see.
  defp begin_attach(socket, kind) when kind in ["text", "image", "audio"] do
    cond do
      not local_attach_node?(socket) ->
        assign(socket, attach_unavailable: true)

      at_attachment_cap?(socket) ->
        attachment_flash(socket, :too_many, nil)

      true ->
        case DirectoryPicker.pick(self(), picker_id_for(kind), :file) do
          :ok -> socket
          # No native picker here (headless server, OTP without wx, a dialog
          # already open): reveal the manual-path fallback.
          {:error, _reason} -> assign(socket, attach_unavailable: true)
        end
    end
  end

  defp begin_attach(socket, _kind), do: socket

  defp local_attach_node?(socket), do: socket.assigns[:current_node] == node()

  defp at_attachment_cap?(socket) do
    Attachments.count(socket.assigns[:pending_attachments]) >= Attachments.max_attachments()
  end

  # Manual fallback: a TEXT file read from this node's filesystem (the native
  # picker is unavailable, but the read itself is a plain local file read).
  defp attach_manual(socket, path) do
    path = path |> to_string() |> String.trim()

    cond do
      not local_attach_node?(socket) ->
        assign(socket, attach_unavailable: true)

      path == "" ->
        put_flash(socket, :error, gettext("Enter a file path to attach."))

      not File.regular?(path) ->
        attachment_flash(socket, :enoent, path)

      true ->
        stage_text_attachment(socket, path)
    end
  end

  defp handle_attach_result(socket, "text", {:ok, path}), do: stage_text_attachment(socket, path)

  defp handle_attach_result(socket, kind, {:ok, path}) when kind in ["image", "audio"],
    do: stage_binary_attachment(socket, kind, path)

  defp handle_attach_result(socket, _kind, :cancelled), do: socket

  defp handle_attach_result(socket, _kind, :unavailable),
    do: assign(socket, attach_unavailable: true)

  defp handle_attach_result(socket, _kind, {:unavailable, _reason}),
    do: assign(socket, attach_unavailable: true)

  defp handle_attach_result(socket, _kind, _other), do: socket

  # A TEXT attachment stays OUT of the composer draft: `Attachments.to_message/2`
  # appends its Markdown block to the outgoing body exactly once at send time.
  defp stage_text_attachment(socket, path) do
    case AttachedFile.read(path) do
      {:ok, content} ->
        case Attachments.stage_text(socket.assigns[:pending_attachments], path, content) do
          {:ok, pending} -> store_pending_attachments(socket, pending)
          {:error, :too_many} -> attachment_flash(socket, :too_many, path)
        end

      {:error, reason} ->
        attachment_flash(socket, reason, path)
    end
  end

  # Image/audio files are staged as RAW bytes (base64 happens once, inside
  # `Attachments.to_message/2`); the extension allowlist and the 15 MiB
  # per-file cap live in `EvoDash.AttachedFile.read_kind/2`.
  defp stage_binary_attachment(socket, kind, path) do
    case Attachments.stage_binary(socket.assigns[:pending_attachments], path, kind) do
      {:ok, pending} -> store_pending_attachments(socket, pending)
      {:error, reason} -> attachment_flash(socket, reason, path)
    end
  end

  defp attachment_flash(socket, reason, path) do
    put_flash(socket, :error, Attachments.describe_error(reason, path))
  end

  defp store_pending_attachments(socket, pending) do
    socket
    |> assign(pending_attachments: pending)
    |> ChatState.persist()
  end

  defp parse_attachment_index(index) when is_integer(index), do: if(index >= 0, do: index)

  defp parse_attachment_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {idx, ""} when idx >= 0 -> idx
      _other -> nil
    end
  end

  defp parse_attachment_index(_index), do: nil

  @impl true
  def handle_info({:task_updated, task_id, status, node} = msg, socket) do
    {:noreply, socket} = NodeAware.handle_task_info(socket, msg)
    {:noreply, handle_task_event(socket, task_id, status, node)}
  end

  def handle_info({:task_deleted, task_id, node} = msg, socket) do
    {:noreply, socket} = NodeAware.handle_task_info(socket, msg)
    {:noreply, handle_task_deleted(socket, task_id, node)}
  end

  def handle_info({:agent_registered, id, summary, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         Map.get(summary, :task_id) == socket.assigns[:chat_task_id] do
      socket =
        assign(socket,
          chat_agent_id: id,
          agent_message_count: AgentStream.message_count(summary)
        )

      socket =
        if Watch.stream_active?(socket) do
          ChatState.persist(socket)
        else
          socket |> ChatState.persist() |> async_fetch_history()
        end

      {:noreply, maybe_recover_approvals(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:agent_updated, id, changed_fields, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         id == socket.assigns[:chat_agent_id] and
         is_list(changed_fields) and Keyword.has_key?(changed_fields, :message_count) do
      socket =
        if message_count_grew?(socket, changed_fields), do: drop_echoes(socket), else: socket

      # A WATCHED session is driven by its delta stream: refetching the whole
      # history per message-count change IS the poll this feature removes.
      socket =
        if Watch.stream_active?(socket) do
          ChatState.persist(socket)
        else
          async_fetch_history(socket)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:agent_removed, _id, _node}, socket) do
    {:noreply, socket}
  end

  def handle_info({:agents_updated, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         socket.assigns[:chat_task_id] != nil and socket.assigns[:chat_agent_id] == nil do
      {:noreply, async_lookup_agent(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:approval_requested, request}, socket) do
    # A genuinely NEW live request (never a recovery snapshot) opens the review
    # dialog when it is not already open and raises a native notification, so
    # the user does not have to be looking at the tab to notice it. Both
    # surfaces are gated on the SAME ownership predicate the workflow applies
    # (ApprovalWorkflow.own_request?/2): a page that ignores a request for
    # another task/agent/node must never notify about an approval it cannot
    # act on.
    socket = ApprovalWorkflow.requested(socket, request)

    if ApprovalWorkflow.own_request?(socket.assigns, request) do
      {:noreply,
       socket
       |> auto_open_approval_dialog()
       |> push_event("task_notification", %{
         title: gettext("Approval needed"),
         body: gettext("Genesis is waiting for your approval."),
         tag: "genesis-approval"
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:approval_resolved, request_id, _decision, source_node}, socket) do
    socket = ApprovalWorkflow.resolved(socket, request_id, source_node)
    {:noreply, sync_approval_dialog(socket)}
  end

  def handle_info({:approval_resolved, request_id, _decision}, socket) do
    socket = ApprovalWorkflow.resolved(socket, request_id)
    {:noreply, sync_approval_dialog(socket)}
  end

  def handle_info(:node_aware_reload_tasks, socket) do
    socket =
      socket
      |> NodeAware.reload_tasks()
      |> NodeAware.clear_task_reload_pending()
      |> maybe_load_sessions()

    {:noreply, socket}
  end

  def handle_info({:chat_agent_lookup, node, seq, task_id, agent}, socket) do
    if stale?(socket, node, seq) or task_id != socket.assigns[:chat_task_id] do
      {:noreply, socket}
    else
      if is_map(agent) do
        socket =
          assign(socket,
            chat_agent_id: Map.get(agent, :id),
            agent_message_count: AgentStream.message_count(agent)
          )

        {:noreply,
         socket |> ChatState.persist() |> async_fetch_history() |> maybe_recover_approvals()}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_info({:chat_history_loaded, node, seq, agent_id, result}, socket) do
    if stale?(socket, node, seq) or agent_id != socket.assigns[:chat_agent_id] do
      {:noreply, socket}
    else
      case result do
        msgs when is_list(msgs) ->
          socket = socket |> apply_history(msgs, false) |> ChatState.persist()

          # No writer is left once the session stopped, so a reply that just
          # landed from history must not stay rendered as still streaming.
          socket =
            if socket.assigns[:chat_status] in [:ended, :idle],
              do: finalize_bubble(socket),
              else: socket

          {:noreply, socket}

        _ ->
          {:noreply, socket}
      end
    end
  end

  def handle_info({:chat_task_loaded, node, seq, task_id, task}, socket) do
    if node != socket.assigns[:current_node] or
         seq != socket.assigns[:chat_task_fetch_seq] or
         task_id != socket.assigns[:chat_task_id] do
      {:noreply, socket}
    else
      {:noreply, finalize_terminal(socket, task)}
    end
  end

  def handle_info({:source_availability_loaded, seq, node, result}, socket) do
    if seq == socket.assigns[:source_check_seq] and is_atom(node) and
         NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, assign(socket, source_available: result, source_check_loading: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:source_clone_result, node, result}, socket) do
    if is_atom(node) and NodeAware.event_from_current_node?(socket.assigns, node) do
      case result do
        {:ok, _status} ->
          {:noreply, socket |> assign(source_busy: nil) |> maybe_check_source()}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(source_busy: nil)
           |> put_flash(
             :error,
             gettext("Failed to download the Genesis source: %{reason}",
               reason: inspect(reason)
             )
           )}

        {:unavailable, _reason} ->
          {:noreply, assign(socket, source_busy: nil, source_available: nil)}

        _other ->
          {:noreply, assign(socket, source_busy: nil)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({{:approval_pending_loaded, _seq, _scope} = tag, result}, socket) do
    # A recovery snapshot mutates `pending_approvals` too, so the dialog cursor
    # is re-derived: an empty result closes the dialog instead of leaving it
    # "open" with nothing to show.
    {:noreply, socket |> ApprovalWorkflow.recovered(tag, result) |> sync_approval_dialog()}
  end

  def handle_info({{:approval_workflow_response, _seq, _scope, _id} = tag, result}, socket) do
    # Success / not-found removes the request: sync closes the dialog when it
    # was the last one and clamps the cursor to what remains.
    {:noreply, socket |> ApprovalWorkflow.responded(tag, result) |> sync_approval_dialog()}
  end

  def handle_info({{:model_select_loaded, seq, target_node}, result}, socket) do
    if target_node != elem(ModelSelection.selection_scope(socket), 1) or
         seq != socket.assigns.model_select_seq or ModelSelection.pending_remote?(socket) do
      {:noreply, socket}
    else
      case result do
        {:ok, snapshot_result} ->
          {:noreply, ModelSelection.apply_model_snapshot(socket, snapshot_result)}

        {:error, reason} ->
          {:noreply, ModelSelection.apply_model_snapshot(socket, {:error, reason})}
      end
    end
  end

  def handle_info({{:session_attached, seq, node, session_id}, result}, socket) do
    if seq == socket.assigns[:session_attach_seq] and
         node == socket.assigns[:current_node] and
         session_id == socket.assigns[:session_id] do
      {:noreply, apply_attach(socket, result)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:node_selected, node_id}, socket) do
    {:noreply, socket} = NodeAware.handle_node_selected(socket, node_id)
    {:noreply, maybe_load_sessions(socket)}
  end

  def handle_info({:remote_connection_status, target_id, status}, socket) do
    {:noreply, socket} =
      NodeAware.handle_connection_status(socket, {:remote_connection_status, target_id, status})

    {:noreply, maybe_load_sessions(socket)}
  end

  # Async native-picker results for the composer's three attach ids; any other
  # picker id keeps the page's existing ignore behaviour (the catch-all below).
  def handle_info({:directory_picker_result, picker_id, result}, socket)
      when is_binary(picker_id) do
    case attach_kind(picker_id) do
      nil -> {:noreply, socket}
      kind -> {:noreply, handle_attach_result(socket, kind, result)}
    end
  end

  # Push-only delta stream (`EvoDashWeb.HomeLive.Watch`). A batch is applied ONLY
  # for the currently watched + snapshot-seeded agent: a nil/foreign stream and
  # a pre-snapshot delta are dropped silently (the snapshot's seq covers the
  # subscribe→snapshot gap, so nothing is lost).
  def handle_info({:agent_delta, agent_id, seq, batch}, socket) do
    case socket.assigns[:chat_stream] do
      %{agent_id: ^agent_id, delta: %Delta{seq: snapshot_seq}} when is_integer(snapshot_seq) ->
        if EvoGit.Agent.Stream.stale?(seq, snapshot_seq) do
          {:noreply, socket}
        else
          stream = socket.assigns[:chat_stream]

          %{
            delta: delta,
            transcript: transcript,
            thought_process: thought_process,
            meta: meta,
            outcome: outcome
          } =
            Delta.apply_batch(
              stream.delta,
              socket.assigns[:transcript],
              socket.assigns[:thought_process] || [],
              socket.assigns[:chat_stream_meta] || Delta.meta(),
              batch
            )

          # Layout stability: only re-assign what actually CHANGED. The reducer
          # returns a fresh (but usually value-equal) transcript / thought
          # process / meta map for every ~75 ms batch, and re-assigning them
          # unconditionally re-rendered the transcript column and the meta line
          # on every batch — the source of the visible "shaking" while
          # streaming and at the end of a turn. The stream cursor is ALWAYS
          # advanced because the stale check depends on it.
          prev_transcript = socket.assigns[:transcript]
          prev_thought_process = socket.assigns[:thought_process]
          prev_meta = socket.assigns[:chat_stream_meta]

          socket =
            socket
            |> assign(chat_stream: %{stream | delta: %{delta | seq: seq}})
            |> maybe_assign_changed(:transcript, transcript, prev_transcript)
            |> maybe_assign_changed(:thought_process, thought_process, prev_thought_process)
            |> maybe_assign_changed(:chat_stream_meta, meta, prev_meta)
            |> fold_stream_outcome(outcome)
            |> maybe_refresh_finished_turn(outcome, delta)
            |> ChatState.persist()

          {:noreply, socket}
        end

      _other ->
        {:noreply, socket}
    end
  end

  # The watcher registration + snapshot landed. Only the CURRENT attach (seq +
  # node + session + watched agent all agree) may apply it: the snapshot then
  # seeds the delta (its seq is the reconciliation baseline) and rebuilds the
  # transcript through the existing `apply_history/3` funnel.
  def handle_info({:chat_stream_ready, node, seq, agent_id, result}, socket) do
    stream = socket.assigns[:chat_stream]

    if seq == socket.assigns[:stream_attach_seq] and
         node == socket.assigns[:current_node] and
         agent_id == socket.assigns[:session_id] and
         is_map(stream) and Map.get(stream, :agent_id) == agent_id do
      case Watch.snapshot_result(result, agent_id, node) do
        {:ok, %{snapshot: snapshot, delta: delta, meta: meta}} ->
          socket =
            if in_flight_streaming?(socket.assigns[:transcript]) do
              # A reply is still streaming into the transcript, so rebuilding it
              # from the snapshot would DISCARD that in-flight text: only the
              # delta baseline (and its message count) is refreshed here.
              socket
              |> assign(
                chat_stream: %{agent_id: agent_id, node: node, delta: delta},
                chat_stream_meta: meta,
                agent_message_count: snapshot_message_count(snapshot, socket)
              )
              |> ChatState.persist()
            else
              socket
              |> apply_history(snapshot.messages, true)
              |> assign(
                chat_stream: %{agent_id: agent_id, node: node, delta: delta},
                chat_stream_meta: meta
              )
              |> ChatState.persist()
            end

          {:noreply, socket}

        {:error, _reason} ->
          {:noreply, assign(socket, chat_stream: nil, chat_stream_meta: nil)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Assign a value only when it differs from what the socket already holds:
  # a value-equal re-assign still re-renders that subtree, which is what made
  # the transcript column jitter on every ~75 ms delta batch.
  defp maybe_assign_changed(socket, _key, new_value, new_value), do: socket
  defp maybe_assign_changed(socket, key, new_value, _previous), do: assign(socket, key, new_value)

  # Whether the transcript still carries an in-flight (streaming) assistant
  # bubble — the local answer that a snapshot must NOT rebuild over.
  defp in_flight_streaming?(transcript) do
    is_list(transcript) and
      Enum.any?(transcript, fn entry ->
        is_map(entry) and Map.get(entry, :role) == :assistant and
          Map.get(entry, :streaming) == true
      end)
  end

  # The attach snapshot's message count (the `:agent_message_count` gate), or
  # the current value when the payload carries no message list.
  defp snapshot_message_count(%{messages: messages}, _current) when is_list(messages),
    do: length(messages)

  defp snapshot_message_count(_snapshot, current), do: current

  # The deltas of a FINAL attempt can be suppressed: the core gates text and
  # thinking chunks on the watcher count at the START of an LLM attempt, so a
  # short closing turn may finish with nothing streamed. A finish with no
  # streamed text therefore reconciles ONCE from the core's own history.
  defp maybe_refresh_finished_turn(socket, {:finished, _status}, delta) do
    if socket.assigns[:chat_agent_id] != nil and Delta.streamed_text?(delta) == false do
      async_fetch_history(socket, socket.assigns[:chat_node])
    else
      socket
    end
  end

  defp maybe_refresh_finished_turn(socket, _outcome, _delta), do: socket

  # The outcome a delta batch reported: a yield parks the session (idle, waiting
  # for input), a finish ends it, and anything else terminal-looking fails it.
  defp fold_stream_outcome(socket, nil), do: socket

  defp fold_stream_outcome(socket, :yield) do
    assign(socket, chat_status: :idle, chat_task_status: :awaiting_input, queued_echoes: [])
  end

  defp fold_stream_outcome(socket, {:finished, :completed}) do
    assign(socket, chat_status: :ended, chat_task_status: :completed, queued_echoes: [])
  end

  defp fold_stream_outcome(socket, {:finished, status}) when status in @terminal_statuses do
    assign(socket, chat_status: :ended, chat_task_status: status, queued_echoes: [])
  end

  defp fold_stream_outcome(socket, _outcome) do
    assign(socket, chat_status: :ended, chat_task_status: :failed, queued_echoes: [])
  end

  # The composer send path and the one-shot finalize block live in
  # `EvoDashWeb.HomeLive.SendPath`; these thin delegations keep every call site
  # (handle_event / handle_info / task-event handlers) unchanged.
  defp send_chat(socket, text), do: SendPath.send_chat(socket, text)
  defp send_draft(socket, text, policy), do: SendPath.send_draft(socket, text, policy)

  defp message_count_grew?(socket, changed_fields),
    do: SendPath.message_count_grew?(socket, changed_fields)

  defp drop_echoes(socket), do: assign(socket, queued_echoes: [])

  defp finalize_streaming(socket, text), do: SendPath.finalize_streaming(socket, text)
  defp finalize_terminal(socket, task), do: SendPath.finalize_terminal(socket, task)
  defp clear_task_refs(socket), do: SendPath.clear_task_refs(socket)

  def async_lookup_agent(socket, node_override \\ nil) do
    task_id = socket.assigns[:chat_task_id]
    node = node_override || socket.assigns[:current_node] || node()
    seq = socket.assigns[:chat_fetch_seq] + 1
    pid = self()

    Task.Supervisor.start_child(TaskSupervisor, fn ->
      agents = SafeCall.run(fn -> NodeContext.list_agents(node) end, [])
      agent = AgentStream.find_root_agent(agents, task_id)
      send(pid, {:chat_agent_lookup, node, seq, task_id, agent})
    end)

    assign(socket, chat_fetch_seq: seq)
  end

  defp async_fetch_history(socket, node_override \\ nil) do
    agent_id = socket.assigns[:chat_agent_id]
    node = node_override || socket.assigns[:current_node] || node()
    seq = socket.assigns[:chat_fetch_seq] + 1
    pid = self()

    runner =
      Application.get_env(:evo_dash, :home_agent_history_runner, &NodeContext.get_agent_history/2)

    Task.Supervisor.start_child(TaskSupervisor, fn ->
      result =
        SafeCall.run(fn -> runner.(node, agent_id) end, [])

      send(pid, {:chat_history_loaded, node, seq, agent_id, result})
    end)

    assign(socket, chat_fetch_seq: seq)
  end

  defp async_fetch_task(socket, node_override \\ nil) do
    task_id = socket.assigns[:chat_task_id]
    node = node_override || socket.assigns[:current_node] || node()
    seq = socket.assigns[:chat_task_fetch_seq] + 1
    pid = self()

    Task.Supervisor.start_child(TaskSupervisor, fn ->
      task = SafeCall.run(fn -> NodeContext.get_task_lite(node, task_id) end, nil)
      send(pid, {:chat_task_loaded, node, seq, task_id, task})
    end)

    assign(socket, chat_task_fetch_seq: seq)
  end

  defp handle_task_event(socket, task_id, status, node) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         task_id == socket.assigns[:chat_task_id] do
      if interactive_session?(socket) do
        session_task_event(socket, status)
      else
        one_shot_task_event(socket, status)
      end
    else
      socket
    end
  end

  defp session_task_event(socket, status) do
    socket =
      cond do
        status in @terminal_statuses ->
          socket
          |> assign(chat_task_status: status, chat_status: :ended, queued_echoes: [])
          |> finalize_bubble()
          |> Watch.detach()
          |> async_fetch_history(socket.assigns[:chat_node])

        status == :cancelling ->
          # No more text is coming, but the session is still alive: finalize the
          # bubble and KEEP the watcher.
          socket
          |> assign(chat_task_status: :cancelling, chat_status: :cancelling)
          |> finalize_bubble()

        status in [:running, :pending, :finalizing] ->
          assign(socket, chat_task_status: status)

        true ->
          socket
      end

    ChatState.persist(socket)
  end

  # The terminal half of an interactive session: the in-flight assistant bubble
  # is CLOSED (an empty placeholder is dropped) so it never stays stuck
  # "streaming" with no writer left.
  defp finalize_bubble(socket) do
    assign(socket, transcript: Transcript.close_streaming(socket.assigns[:transcript]))
  end

  defp one_shot_task_event(socket, status) do
    socket =
      case status do
        :completed ->
          async_fetch_task(assign(socket, chat_task_status: :completed))

        :cancelled ->
          async_fetch_task(assign(socket, chat_task_status: :cancelled))

        :failed ->
          socket
          |> assign(chat_task_status: :failed)
          |> finalize_streaming(gettext("The task failed."))
          |> clear_task_refs()

        :running ->
          socket = assign(socket, chat_task_status: :running)

          if socket.assigns[:chat_agent_id] == nil do
            async_lookup_agent(socket)
          else
            socket
          end

        :cancelling ->
          assign(socket, chat_task_status: :cancelling, chat_status: :cancelling)

        :pending ->
          assign(socket, chat_task_status: :pending)

        :finalizing ->
          assign(socket, chat_task_status: :finalizing)

        _ ->
          socket
      end

    ChatState.persist(socket)
  end

  defp handle_task_deleted(socket, task_id, node) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         task_id == socket.assigns[:chat_task_id] do
      if interactive_session?(socket) do
        socket
        |> assign(
          chat_task_id: nil,
          chat_task_status: nil,
          chat_status: :ended,
          queued_echoes: []
        )
        |> ChatState.persist()
      else
        socket
        |> finalize_streaming(gettext("The conversation was deleted."))
        |> clear_task_refs()
        |> ChatState.persist()
      end
    else
      socket
    end
  end

  defp reset_chat(socket) do
    socket
    |> Watch.detach()
    |> assign(
      transcript: Transcript.new(),
      chat_draft: "",
      chat_status: :idle,
      chat_task_id: nil,
      chat_agent_id: nil,
      agent_message_count: nil,
      chat_task_status: nil,
      thought_process: [],
      chat_node: nil,
      chat_fetch_seq: 0,
      chat_task_fetch_seq: 0,
      raw_entry_ids: MapSet.new(),
      session_id: nil,
      current_session_id: nil,
      session_mode: nil,
      queued_echoes: [],
      pending_attachments: Attachments.clear(),
      approval_context: nil,
      approval_dialog_open: false,
      approval_dialog_index: 0
    )
    |> ApprovalWorkflow.init()
  end

  ## Approval review dialog -------------------------------------------------
  #
  # `approval_dialog_open` / `approval_dialog_index` are LOCAL VIEW state: the
  # requests themselves belong to ApprovalWorkflow, and every decision still
  # travels through it as the request id plus a whitelisted decision. The
  # helpers below only keep the cursor sane as the request list changes.

  defp pending_approvals(socket), do: socket.assigns[:pending_approvals] || []

  # A genuinely NEW live request (never a recovery snapshot) surfaces the review
  # dialog when it is not already open, so the user is asked in place instead of
  # having to notice a banner. When it IS open, only the cursor is re-synced.
  defp auto_open_approval_dialog(socket) do
    if socket.assigns[:approval_dialog_open] do
      sync_approval_dialog(socket)
    else
      open_approval_dialog(socket)
    end
  end

  defp open_approval_dialog(socket) do
    case pending_approvals(socket) do
      [] ->
        assign(socket, approval_dialog_open: false, approval_dialog_index: 0)

      _ ->
        assign(socket,
          approval_dialog_open: true,
          approval_dialog_index:
            clamp_dialog_index(socket.assigns[:approval_dialog_index], socket)
        )
    end
  end

  defp sync_approval_dialog(socket) do
    case pending_approvals(socket) do
      [] ->
        assign(socket, approval_dialog_open: false, approval_dialog_index: 0)

      _ ->
        assign(socket,
          approval_dialog_index:
            clamp_dialog_index(socket.assigns[:approval_dialog_index], socket)
        )
    end
  end

  defp step_approval_dialog(socket, step) do
    case pending_approvals(socket) do
      [] ->
        assign(socket, approval_dialog_open: false, approval_dialog_index: 0)

      requests ->
        count = length(requests)
        index = clamp_dialog_index(socket.assigns[:approval_dialog_index], socket)
        assign(socket, approval_dialog_index: integer_mod(index + step, count))
    end
  end

  defp clamp_dialog_index(index, socket) do
    count = length(pending_approvals(socket))

    cond do
      count == 0 -> 0
      not is_integer(index) or index < 0 -> 0
      index >= count -> count - 1
      true -> index
    end
  end

  defp integer_mod(value, count) when count > 0 do
    rem(rem(value, count) + count, count)
  end

  def maybe_recover_approvals(socket) do
    context =
      Map.take(socket.assigns, [
        :chat_id,
        :current_node_id,
        :current_node,
        :chat_node,
        :chat_task_id,
        :chat_agent_id
      ])

    if connected?(socket) and context != socket.assigns[:approval_context] do
      socket
      |> assign(approval_context: context)
      |> recover_approvals()
    else
      socket
    end
  end

  defp recover_approvals(socket) do
    if connected?(socket), do: ApprovalWorkflow.recover(socket), else: socket
  end

  defp start_new_chat(socket) do
    socket =
      if connected?(socket) do
        chat_id = ChatHistory.new_chat()
        ChatHistory.prune(10)
        assign(socket, chat_id: chat_id)
      else
        socket
      end

    socket
    |> reset_chat()
    |> ChatState.persist()
  end

  defp attach_chat(socket) do
    if connected?(socket) do
      chat_id = ChatHistory.current_chat_id() || ChatHistory.new_chat()
      saved_state = ChatHistory.get_state(chat_id)

      socket =
        socket
        |> assign(chat_id: chat_id, model_selection_restore: saved_state || %{})
        |> assign(ChatState.restore(saved_state))

      reconcile_chat(socket)
    else
      socket
    end
  end

  defp reconcile_chat(socket) do
    if socket.assigns[:chat_status] in [:running, :cancelling] and
         socket.assigns[:chat_task_id] != nil do
      socket = async_fetch_task(socket, socket.assigns[:chat_node])

      if socket.assigns[:chat_agent_id] != nil do
        async_fetch_history(socket, socket.assigns[:chat_node])
      else
        async_lookup_agent(socket, socket.assigns[:chat_node])
      end
    else
      socket
    end
  end

  defp stale?(socket, node, seq) do
    node != socket.assigns[:current_node] or seq != socket.assigns[:chat_fetch_seq]
  end

  # Best-effort unwatch on page teardown. The REAL reaper is the session's own
  # monitor on the LiveView pid (a `:DOWN` removes the watcher set entry), so a
  # lost/failed unregister here costs nothing.
  @impl true
  def terminate(_reason, socket) do
    _ = Watch.detach(socket)
    :ok
  end
end
