defmodule EvoDashWeb.HomeLive do
  @moduledoc """
  ChatGPT-style chat page wired to the repo-less `:reflect` self-reflective
  agent.
  The user talks to Genesis itself: the page starts a `:reflect` task on the
  current node (`NodeContext.start_task/3` with `mode: "reflect"` and
  NO `:path`), tracks the task's root agent (`EvoGit.Agents.SelfReflective`)
  and streams its assistant turns into chat bubbles, and lets the user stop
  the conversation gracefully (which preserves the final result).
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
    Messages,
    ModelSelect,
    SessionActions,
    SessionList,
    SourceGate,
    Transcript
  }

  alias EvoDash.{ChatHistory, NodeContext, SafeCall, TaskSupervisor}
  alias EvoDashWeb.LiveHooks.NodeAware
  alias EvoDashWeb.LLMSelection
  import EvoDashWeb.LLMSelectionComponents, only: [llm_selection: 1]
  import EvoDashWeb.HomeLive.ChatMessages
  import EvoDashWeb.HomeLive.ApprovalCard
  import EvoDashWeb.HomeLive.SourceGate
  @terminal_statuses [:completed, :cancelled, :failed]

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:help}
      current_node_id={@current_node_id}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      pending_tasks={@pending_tasks}
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
      accent_color={assigns[:accent_color] || "blue"}
    >
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
            disabled={@chat_status != :idle}
            class="ml-auto inline-flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium text-base-content/70 hover:bg-base-200 hover:text-base-content transition-colors focus-visible:outline-2 focus-visible:outline-primary-standalone disabled:opacity-40 disabled:pointer-events-none shrink-0"
          >
            <.icon name="hero-plus" class="size-4" />
            <%!-- zh_CN: "新对话" --%>{gettext("New chat")}
          </button>
        </div>
        <!-- Genesis-source gate: the /help chat runs a repo-less `:reflect`
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
          <%= if @transcript == [] do %>
            <.empty_state source_gate?={SourceGate.blocked?(assigns)} />
          <% else %>
            <.message_list
              transcript={@transcript}
              chat_task_status={@chat_task_status}
              thought_process={@thought_process}
              raw_entry_ids={@raw_entry_ids}
            />
          <% end %>
        </div>
        <!-- Pending evaluator and legacy command approvals block the reflect
             agent until the user decides. Cards stay visible while a response
             is in flight and on failure, between transcript and composer. -->
        <%= if @pending_approvals != [] do %>
          <div class="shrink-0 max-h-[min(11rem,25dvh)] overflow-y-auto overscroll-contain scrollbar-thin">
            <%= for request <- @pending_approvals do %>
              <.approval_card
                request={request}
                busy={ApprovalWorkflow.busy?(assigns, request.request_id)}
              />
            <% end %>
          </div>
        <% end %>
        <%= case @approval_error do %>
          <% {:recovery, reason} -> %>
            <div
              id="approval-recovery-error"
              role="alert"
              class="shrink-0 rounded-lg border border-warning/30 bg-warning/10 p-3 text-sm text-base-content"
            >
              <p>
                {gettext("Could not load pending approvals: %{reason}", reason: inspect(reason))}
              </p>
              <p class="mt-1 text-base-content/70">
                {gettext("Existing requests are kept. Retry to check for pending approvals.")}
              </p>
              <button
                type="button"
                phx-click="retry_approvals"
                disabled={@approval_recovering}
                class="btn btn-sm btn-outline mt-2"
              >
                {gettext("Retry approvals")}
              </button>
            </div>
          <% {:response, request_id, reason} -> %>
            <%= if Enum.any?(@pending_approvals, &(&1.request_id == request_id)) do %>
              <div
                id="approval-response-error"
                role="alert"
                class="shrink-0 rounded-lg border border-warning/30 bg-warning/10 p-3 text-sm text-base-content"
              >
                <p>{gettext("Failed to respond: %{reason}", reason: inspect(reason))}</p>
                <p class="mt-1 text-base-content/70">
                  {gettext("The request is still pending. Use its decision buttons to try again.")}
                </p>
              </div>
            <% end %>
          <% _ -> %>
        <% end %>
        <!-- Composer: pinned bottom, outside the messages scroller. ONE form:
             the textarea row, then a control bar holding the shared
             provider/model/reasoning capsule on the left and Send/Stop on the
             right (the /projects toolbar shape). `#chat-form` owns the
             textarea's `chat_input` draft handler; the capsule needs NO form
             owner (every control emits `phx-click` + `phx-value-*`, so its
             selections never reach `chat_input`) and NO form may ever be
             nested here. -->
        <div class="shrink-0 px-3 pt-2 pb-3 sm:px-4 bg-base-100">
          <p
            :if={@model_select_load_error || @model_selection_error}
            role="alert"
            class="mb-1.5 text-xs text-error"
          >
            {gettext("Model selection is unavailable. Choose a valid model or reconnect to the node.")}
          </p>
          <form
            id="chat-form"
            phx-submit="send_message"
            phx-change="chat_input"
            class="help-composer flex flex-col gap-1 rounded-2xl p-1"
          >
            <textarea
              name="message"
              value={@chat_draft}
              phx-keydown="chat_keydown"
              phx-keyup="chat_keyup"
              disabled={@chat_status != :idle or SourceGate.blocked?(assigns)}
              placeholder={gettext("Message Genesis Assistant…")}
              rows="1"
              aria-label={gettext("Message Genesis Assistant…")}
              class="w-full min-w-0 min-h-[46px] max-h-[min(10rem,25dvh)] resize-y bg-transparent px-4 py-3 text-base leading-relaxed placeholder:text-base-content/50 focus:outline-none disabled:opacity-50"
            ></textarea>
            <!-- Composer control bar: picker left, send/stop right. -->
            <div id="chat-composer-controls" class="help-composer-controls">
              <.llm_selection
                id="chat-llm-selection"
                provider_profiles={@provider_profiles}
                model_selections={@model_selections}
                model_spec={@model_spec || %{}}
                show_auto_option={@model_selection_enabled}
                disabled={@model_select_loading or is_nil(@model_snapshot)}
                compact
                class="min-w-0"
              />
              <div class="ml-auto flex shrink-0 items-center gap-2">
                <!-- Send → Stop morph: exactly one button is visible at a time; both
                     stay in the DOM (the hidden one disabled) so the Stop button's
                     presence/disabled state remains assertable on idle. -->
                <button
                  type="submit"
                  disabled={
                    @chat_status != :idle or SourceGate.blocked?(assigns) or
                      is_nil(@model_snapshot) or not is_nil(@model_selection_error)
                  }
                  class={"help-send-btn flex size-9 shrink-0 items-center justify-center rounded-full bg-primary text-primary-content transition hover:opacity-90 active:scale-95 disabled:opacity-40 disabled:pointer-events-none " <> if(@chat_status == :running, do: "hidden", else: "")}
                >
                  <.icon name="hero-paper-airplane" class="size-4" />
                  <span class="sr-only"><%!-- zh_CN: "发送" --%>{gettext("Send")}</span>
                </button>
                <button
                  type="button"
                  phx-click="stop"
                  disabled={@chat_status != :running}
                  class={"flex size-9 shrink-0 items-center justify-center rounded-full bg-base-content text-base-100 transition hover:opacity-90 active:scale-95 disabled:opacity-40 disabled:pointer-events-none " <> if(@chat_status != :running, do: "hidden", else: "")}
                >
                  <.icon name="hero-stop" class="size-4" />
                  <span class="sr-only"><%!-- zh_CN: "停止" --%>{gettext("Stop")}</span>
                </button>
              </div>
            </div>
          </form>
          <div class="mt-1.5 text-center text-xs text-base-content/60">
            <%!-- zh_CN: "回车发送 · Shift+回车换行" --%>{gettext(
              "Enter to send · Shift+Enter for a new line"
            )}
            <%= if @chat_status == :idle and @transcript == [] do %>
              <br />
              <%!-- zh_CN: Genesis Assistant 可能会出错，请核实重要信息。 --%>{gettext(
                "Genesis Assistant can make mistakes. Verify important information."
              )}
            <% end %>
          </div>
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
      session_list: [],
      session_list_loading: false,
      session_list_error: nil,
      session_list_seq: 0,
      pending_attachments: Attachments.new(),
      attach_unavailable: false,
      chat_fetch_seq: 0,
      chat_task_fetch_seq: 0,
      shift_down: false,
      selected_model_id: nil,
      raw_entry_ids: MapSet.new(),
      # after handle_params resolves the node, never against mount's local seed.
      approval_context: nil,
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
      current_path: ~p"/help"
    }
  end

  defp assign_model_select(socket) do
    {_target_id, target_node} = selection_scope(socket)
    seq = socket.assigns.model_select_seq + 1

    socket =
      assign(socket,
        model_select_seq: seq,
        model_snapshot: nil,
        model_selection_bundle: nil,
        provider_profiles: [],
        model_selections: [],
        model_selection_enabled: false,
        model_select_loading: false,
        model_select_load_error: nil
      )

    cond do
      pending_remote?(socket) ->
        assign(socket, model_select_load_error: :remote_not_connected)

      target_node == node() ->
        apply_model_snapshot(socket, ModelSelect.load(target_node))

      connected?(socket) ->
        case SafeCall.start(self(), {:model_select_loaded, seq, target_node}, fn ->
               ModelSelect.load(target_node)
             end) do
          {:ok, _pid} ->
            assign(socket, model_select_loading: true)

          {:error, reason} ->
            apply_model_snapshot(socket, {:error, reason})
        end

      true ->
        socket
    end
  end

  defp apply_model_snapshot(socket, {:ok, %{node: target_node} = snapshot}) do
    if target_node == elem(selection_scope(socket), 1) and not pending_remote?(socket) do
      bundle = LLMSelection.from_config(snapshot.config, snapshot.model_selection_enabled)

      socket
      |> assign(
        model_snapshot: snapshot,
        model_selection_bundle: bundle,
        provider_profiles: bundle.provider_profiles,
        model_selections: bundle.model_selections,
        model_selection_enabled: bundle.model_selection_enabled,
        model_select_loading: false,
        model_select_load_error: nil
      )
      |> reconcile_model_selection()
    else
      socket
    end
  end

  defp apply_model_snapshot(socket, {:error, reason}) do
    assign(socket, model_select_loading: false, model_select_load_error: reason)
  end

  defp reconcile_model_selection(socket) do
    if socket.assigns.model_selection_error do
      socket
    else
      candidate =
        if is_nil(socket.assigns.model_spec),
          do: socket.assigns.selected_model_id,
          else: socket.assigns.model_spec

      spec = LLMSelection.reconcile(socket.assigns.model_selection_bundle, candidate)

      socket
      |> assign(model_spec: spec, selected_model_id: nil)
      |> ChatState.persist()
    end
  end

  defp update_model_selection(socket, operation, value) do
    bundle = socket.assigns.model_selection_bundle

    result =
      if is_nil(bundle) or pending_remote?(socket) do
        {:error, :model_selection_not_loaded}
      else
        apply(LLMSelection, operation, [bundle, socket.assigns.model_spec, value])
      end

    case result do
      {:ok, spec} ->
        {:noreply,
         socket
         |> assign(
           model_spec: spec,
           selected_model_id: nil,
           model_selection_error: nil,
           model_selection_scope: selection_scope(socket)
         )
         |> ChatState.persist()}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Choose a valid provider profile, model and reasoning effort.")
         )}
    end
  end

  defp selection_scope(socket) do
    {socket.assigns[:current_node_id], socket.assigns[:current_node] || node()}
  end

  defp pending_remote?(socket) do
    {target_id, target_node} = selection_scope(socket)
    not is_nil(target_id) and target_node == node()
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
  end

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

  defp spawn_attach(socket, session_id) do
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
    entries = Messages.to_entries(messages)
    text = Messages.assistant_text(messages)

    transcript =
      cond do
        rebuild? -> history_transcript(entries, text)
        text == "" -> socket.assigns[:transcript]
        true -> Transcript.put_streaming_text(socket.assigns[:transcript], text)
      end

    assign(socket,
      transcript: transcript,
      agent_message_count: length(messages),
      thought_process: entries
    )
  end

  defp apply_history(socket, _messages, _rebuild?), do: socket

  defp history_transcript(entries, text) do
    transcript =
      entries
      |> Enum.map(&entry_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(Transcript.new(), fn text, acc ->
        Transcript.append(acc, Transcript.entry(:user, text))
      end)

    if text == "",
      do: transcript,
      else: Transcript.append(transcript, Transcript.entry(:assistant, text))
  end

  defp entry_text(entry) when is_map(entry) do
    case Map.get(entry, :data) do
      %{content: content} when is_binary(content) -> content
      _other -> ""
    end
  end

  defp entry_text(_entry), do: ""

  defp maybe_load_sessions(socket) do
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

    scope = selection_scope(socket)
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
      |> assign_model_select()
      |> assign(current_path: ~p"/help")
      |> maybe_check_source()
      |> maybe_recover_approvals()
      |> maybe_load_sessions()

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
    update_model_selection(socket, :select_provider, id)
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    update_model_selection(socket, :select_model, model)
  end

  def handle_event("select_reasoning_effort", %{"reasoning_effort" => index}, socket) do
    update_model_selection(socket, :select_reasoning_effort, index)
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
    if socket.assigns[:chat_status] == :idle do
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

  def handle_event(
        "approval_response",
        %{"request_id" => request_id, "decision" => decision},
        socket
      ) do
    {:noreply, ApprovalWorkflow.respond(socket, request_id, decision)}
  end

  def handle_event("retry_approvals", _params, socket) do
    {:noreply, recover_approvals(socket)}
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

    finish_chat(
      socket,
      fn -> SessionActions.close(node, agent_id, :normal) end,
      [chat_status: :cancelling, queued_echoes: []],
      true
    )
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

      {:noreply,
       socket |> ChatState.persist() |> async_fetch_history() |> maybe_recover_approvals()}
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

      {:noreply, async_fetch_history(socket)}
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
    {:noreply, ApprovalWorkflow.requested(socket, request)}
  end

  def handle_info({:approval_resolved, request_id, _decision, source_node}, socket) do
    {:noreply, ApprovalWorkflow.resolved(socket, request_id, source_node)}
  end

  def handle_info({:approval_resolved, request_id, _decision}, socket) do
    {:noreply, ApprovalWorkflow.resolved(socket, request_id)}
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
          {:noreply, socket |> apply_history(msgs, false) |> ChatState.persist()}

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
    {:noreply, ApprovalWorkflow.recovered(socket, tag, result)}
  end

  def handle_info({{:approval_workflow_response, _seq, _scope, _id} = tag, result}, socket) do
    {:noreply, ApprovalWorkflow.responded(socket, tag, result)}
  end

  def handle_info({{:model_select_loaded, seq, target_node}, result}, socket) do
    if target_node != elem(selection_scope(socket), 1) or
         seq != socket.assigns.model_select_seq or pending_remote?(socket) do
      {:noreply, socket}
    else
      case result do
        {:ok, snapshot_result} ->
          {:noreply, apply_model_snapshot(socket, snapshot_result)}

        {:error, reason} ->
          {:noreply, apply_model_snapshot(socket, {:error, reason})}
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

  def handle_info({{:session_list_loaded, seq, node}, result}, socket) do
    {:noreply, SessionList.applied(socket, seq, node, result)}
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

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp send_chat(socket, text), do: send_draft(socket, text, :queue)
  # button are disabled in the same state, so this is the defensive backstop for
  defp send_draft(socket, text, policy) do
    cond do
      pending_remote?(socket) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Connect to the remote node before sending a message.")
         )}

      SourceGate.blocked?(socket.assigns) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Download the Genesis source before sending a message.")
         )}

      true ->
        do_send_chat(socket, text, policy)
    end
  end

  defp do_send_chat(socket, text, policy) do
    text = String.trim(text || "")

    cond do
      not sendable_status?(socket) ->
        # Defensive — the composer disables Send in these states anyway.
        {:noreply, socket}

      text == "" ->
        {:noreply, socket}

      true ->
        {message, attachments} =
          Attachments.to_message(text, socket.assigns[:pending_attachments])

        opts =
          if is_nil(socket.assigns[:session_id]) do
            [mode: "reflect", objective: reflect_objective(socket, message)]
          else
            []
          end

        case ModelSelect.task_opts(
               socket.assigns.model_snapshot,
               socket.assigns,
               selection_scope(socket),
               opts
             ) do
          {:ok, task_opts} ->
            dispatch_send(socket, message, attachments, task_opts, policy)

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, gettext("Choose a valid model before sending a message."))}
        end
    end
  end

  defp sendable_status?(socket) do
    if is_nil(socket.assigns[:session_id]) do
      socket.assigns[:chat_status] == :idle
    else
      socket.assigns[:chat_status] in [:idle, :running, :awaiting_input]
    end
  end

  defp reflect_objective(socket, text) do
    case Transcript.build_preamble(socket.assigns[:transcript]) do
      {:ok, preamble} -> preamble <> "New message: " <> text
      :empty -> text
    end
  end

  defp dispatch_send(socket, text, attachments, task_opts, policy) do
    if is_nil(socket.assigns[:session_id]) do
      start_session_chat(socket, text, attachments, task_opts)
    else
      queue_session_message(socket, text, attachments, policy)
    end
  end

  # is shown as a transient echo (never as a second answer bubble).
  defp queue_session_message(socket, text, attachments, policy) do
    node = socket.assigns[:current_node] || node()
    agent_id = socket.assigns[:session_id]
    queued? = socket.assigns[:chat_status] == :running

    result =
      SafeCall.run(fn ->
        SessionActions.send_message(node, agent_id, text, attachments, policy)
      end)

    case normalize_send(result) do
      :ok ->
        transcript =
          Transcript.append(socket.assigns[:transcript], Transcript.entry(:user, text))

        transcript =
          if queued?, do: transcript, else: Transcript.put_streaming_text(transcript, "")

        socket =
          socket
          |> assign(
            transcript: transcript,
            chat_draft: "",
            pending_attachments: Attachments.clear(),
            chat_status: :running
          )
          |> ChatState.persist()

        {:noreply, if(queued?, do: push_queued_echo(socket, text), else: socket)}

      {:error, reason} ->
        {:noreply, send_failure(socket, reason)}
    end
  end

  defp normalize_send({:ok, :ok}), do: :ok
  defp normalize_send({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_send({:error, reason}), do: {:error, reason}
  defp normalize_send({:ok, other}), do: {:error, {:unexpected_send_result, other}}

  defp push_queued_echo(socket, text) do
    echo = %{
      id: System.unique_integer([:positive]) |> Integer.to_string(),
      text: text,
      at: System.system_time(:millisecond)
    }

    echoes = (socket.assigns[:queued_echoes] || []) ++ [echo]

    socket
    |> assign(queued_echoes: Enum.take(echoes, -20))
    |> ChatState.persist()
  end

  defp message_count_grew?(socket, changed_fields) do
    case Keyword.get(changed_fields, :message_count) do
      count when is_integer(count) ->
        case socket.assigns[:agent_message_count] do
          nil -> true
          previous when is_integer(previous) -> count > previous
          _other -> true
        end

      _other ->
        false
    end
  end

  defp drop_echoes(socket), do: assign(socket, queued_echoes: [])

  defp send_failure(socket, reason) do
    if SessionActions.session_ended?(reason) do
      socket
      |> assign(chat_status: :ended, queued_echoes: [])
      |> ChatState.persist()
      |> put_flash(
        :error,
        gettext("This conversation has ended. Start a new chat to continue.")
      )
    else
      put_flash(
        socket,
        :error,
        gettext("Failed to send the message: %{reason}", reason: inspect(reason))
      )
    end
  end

  # error — never a silent Auto, never a fallback on a transport error.
  defp start_session_chat(socket, text, attachments, task_opts) do
    node = socket.assigns[:current_node] || node()

    opts =
      SessionActions.session_opts(text,
        model_spec: Keyword.get(task_opts, :model_spec),
        attachments: attachments
      )

    case SafeCall.run(fn -> SessionActions.start(node, opts) end) do
      {:ok, {:ok, agent_id}} ->
        adopt_session(socket, agent_id, text)

      {:ok, {:error, reason}} ->
        start_failure(socket, reason, text, task_opts)

      {:error, reason} ->
        start_failure(socket, {:transport, reason}, text, task_opts)

      {:ok, other} ->
        start_failure(socket, {:unexpected_start_result, other}, text, task_opts)
    end
  end

  defp start_failure(socket, reason, text, task_opts) do
    if SessionActions.session_unavailable?(reason) do
      {:noreply, fallback_socket} =
        start_chat(assign(socket, session_mode: :one_shot), text, task_opts)

      {:noreply,
       put_flash(
         fallback_socket,
         :info,
         gettext(
           "Interactive sessions are unavailable here. This conversation runs in one-shot mode."
         )
       )}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Failed to start the conversation: %{reason}", reason: inspect(reason))
       )}
    end
  end

  defp adopt_session(socket, agent_id, text) do
    node = socket.assigns[:current_node] || node()

    transcript =
      socket.assigns[:transcript]
      |> Transcript.append(Transcript.entry(:user, text))
      |> Transcript.put_streaming_text("")

    socket =
      socket
      |> assign(
        session_id: agent_id,
        current_session_id: agent_id,
        chat_id: agent_id,
        session_mode: :interactive,
        chat_agent_id: agent_id,
        chat_node: node,
        chat_task_id: nil,
        chat_task_status: :running,
        agent_message_count: nil,
        chat_status: :running,
        chat_draft: "",
        queued_echoes: [],
        pending_attachments: Attachments.clear(),
        transcript: transcript
      )
      |> ChatState.persist()
      |> ApprovalWorkflow.init()
      |> maybe_recover_approvals()
      |> spawn_attach(agent_id)
      |> maybe_load_sessions()

    {:noreply,
     push_patch(socket, to: SessionActions.url(socket.assigns[:current_node_id], agent_id))}
  end

  defp start_chat(socket, text, task_opts) do
    transcript =
      socket.assigns[:transcript]
      |> Transcript.append(Transcript.entry(:user, text))
      |> Transcript.put_streaming_text("")

    socket =
      assign(socket,
        transcript: transcript,
        chat_draft: "",
        chat_status: :running,
        chat_node: socket.assigns[:current_node] || node()
      )

    result =
      case SafeCall.run(fn ->
             NodeContext.start_task(
               socket.assigns[:current_node] || node(),
               :reflect,
               task_opts
             )
           end) do
        {:ok, start_result} -> start_result
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, _task} ->
        case AgentStream.task_id_from_start(result) do
          {:ok, id} ->
            socket =
              socket
              |> assign(chat_task_id: id, chat_task_status: :pending)
              |> ChatState.persist()
              |> async_lookup_agent()
              |> maybe_recover_approvals()

            {:noreply, socket}

          {:error, :no_task_id} ->
            socket =
              socket
              |> finalize_streaming(gettext("Failed to start the task: no task id returned"))
              |> assign(:chat_status, :idle)
              |> ChatState.persist()

            {:noreply, socket}
        end

      {:error, reason} ->
        socket =
          socket
          |> finalize_streaming(
            gettext("Failed to start the task: %{reason}", reason: inspect(reason))
          )
          |> assign(:chat_status, :idle)
          |> ChatState.persist()

        {:noreply, socket}
    end
  end

  defp async_lookup_agent(socket, node_override \\ nil) do
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

    Task.Supervisor.start_child(TaskSupervisor, fn ->
      result =
        SafeCall.run(fn -> NodeContext.get_agent_history(node, agent_id) end, [])

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
          |> async_fetch_history(socket.assigns[:chat_node])

        status == :cancelling ->
          assign(socket, chat_task_status: :cancelling, chat_status: :cancelling)

        status in [:running, :pending, :finalizing] ->
          assign(socket, chat_task_status: status)

        true ->
          socket
      end

    ChatState.persist(socket)
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

  defp finalize_streaming(socket, text) do
    assign(socket, transcript: Transcript.finalize_assistant(socket.assigns[:transcript], text))
  end

  defp finalize_terminal(socket, task) do
    cond do
      task == nil ->
        socket
        |> finalize_streaming(gettext("The conversation was deleted."))
        |> clear_task_refs()
        |> ChatState.persist()

      is_map(task) ->
        case Map.get(task, :status) do
          status when status in @terminal_statuses ->
            socket = assign(socket, chat_task_status: status)

            socket =
              case status do
                :completed -> finalize_completed(socket, Map.get(task, :result))
                :cancelled -> finalize_cancelled(socket, Map.get(task, :result))
                :failed -> finalize_failed(socket, Map.get(task, :error))
              end

            socket
            |> clear_task_refs()
            |> ChatState.persist()

          :cancelling ->
            socket
            |> assign(chat_task_status: :cancelling, chat_status: :cancelling)
            |> ChatState.persist()

          status when status in [:running, :pending, :finalizing] ->
            socket
            |> assign(chat_task_status: status)
            |> ChatState.persist()

          _ ->
            socket
        end

      true ->
        socket
    end
  end

  defp finalize_completed(socket, result) do
    case AgentStream.extract_final_text(result) do
      {:ok, text} -> finalize_streaming(socket, text)
      :empty -> finalize_streaming(socket, gettext("No response."))
      :error -> finalize_streaming(socket, gettext("The task failed."))
    end
  end

  defp finalize_cancelled(socket, result) do
    case AgentStream.extract_final_text(result) do
      {:ok, text} -> finalize_streaming(socket, text)
      _ -> finalize_streaming(socket, gettext("Stopped."))
    end
  end

  defp finalize_failed(socket, error) do
    case AgentStream.extract_failed_message(error) do
      nil -> finalize_streaming(socket, gettext("The task failed."))
      message -> finalize_streaming(socket, message)
    end
  end

  defp clear_task_refs(socket) do
    socket
    |> assign(
      chat_task_id: nil,
      chat_agent_id: nil,
      agent_message_count: nil,
      chat_status: :idle
    )
    |> ApprovalWorkflow.init()
  end

  defp reset_chat(socket) do
    socket
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
      approval_context: nil
    )
    |> ApprovalWorkflow.init()
  end

  defp maybe_recover_approvals(socket) do
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
end
