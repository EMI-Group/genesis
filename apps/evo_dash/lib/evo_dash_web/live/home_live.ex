defmodule EvoDashWeb.HomeLive do
  @moduledoc """
  ChatGPT-style chat page wired to the repo-less `:reflect` self-reflective
  agent.

  The user talks to Genesis itself: the page starts a `:reflect` task on the
  current node (`EvoDash.NodeContext.start_task/3` with `mode: "reflect"` and
  NO `:path`), tracks the task's root agent (`EvoGit.Agents.SelfReflective`)
  and streams its assistant turns into chat bubbles, and lets the user stop
  the conversation gracefully (which preserves the final result).

  Everything is push-based: `"tasks"` and `"agents"` PubSub broadcasts drive
  the transcript (task lifecycle events + agent message-count changes), and
  every cross-node data fetch runs in a `Task.Supervisor` child with a
  monotonic `:chat_fetch_seq` stale-guard — the LiveView never blocks on
  `:erpc`. Node-aware like every other page: `?node=` selects the viewed node.

  Chats survive remounts: the full chat state is persisted in-memory via
  `EvoDash.ChatHistory` (local-node only, see `home_live/CONTEXT.md`) and a
  connected mount restores the current chat with a ONE-SHOT reconciliation
  fetch (no polling). A node switch starts a NEW persisted chat — the old chat
  stays in memory (its task belongs to the old node; events are node-filtered
  anyway).

  The most recent assistant entry renders as a mini "task card" (task status
  badge + streamed text + collapsible "Thought process" section) — see
  `EvoDashWeb.HomeLive.AssistantMessage`. Finalized (non-streaming) assistant
  text renders as Markdown (`EvoDash.MarkdownRender`), and each assistant
  message carries a hover-revealed raw/markdown toggle + copy-text action
  group at its bottom-right corner. The message surface (empty state +
  transcript list) lives in `EvoDashWeb.HomeLive.ChatMessages`; the user
  bubble lives in `EvoDashWeb.HomeLive.UserMessage`.
  """
  use EvoDashWeb, :live_view
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.HomeLive.{AgentStream, ChatState, Messages, ModelSelect, Transcript}
  alias EvoDashWeb.LiveHooks.NodeAware

  import EvoDashWeb.HomeLive.ChatMessages
  import EvoDashWeb.HomeLive.ApprovalCard

  # Statuses that END a task (finalize the transcript + clear refs). All other
  # statuses mean the task is still alive: badge-only updates, refs kept.
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
      <div class="flex flex-col h-full min-h-0 max-w-3xl mx-auto w-full">
        <!-- Header: slim top bar with title/subtitle left, one ghost New chat button right -->
        <div class="shrink-0 flex items-center justify-between gap-3 px-4 pt-4 pb-2">
          <div class="min-w-0">
            <h1 class="text-base font-semibold truncate">
              <%!-- zh_CN: "与 Genesis 对话" --%>{gettext("Chat with Genesis")}
            </h1>
            <p class="text-xs text-base-content/60 truncate hidden sm:block">
              <%!-- zh_CN: "向 Genesis 提问、阅读源码、控制任务或获得仪表盘引导" --%>{gettext(
                "Ask about Genesis, inspect the source, control tasks, and get guided through the dashboard."
              )}
            </p>
          </div>
          <%= if @model_profiles != [] do %>
            <select
              name="model_id"
              phx-change="select_chat_model"
              aria-label={gettext("Chat model")}
              class="shrink-0 max-w-44 rounded-full border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium text-base-content/70 hover:border-primary/40 hover:bg-base-200/70 focus:outline-none focus:ring-2 focus:ring-primary/20"
            >
              <%!-- zh_CN: 自动选择模型 — 配置了模型选择脚本时按规则/脚本自动选择，否则使用默认模型 --%>
              <option value="" selected={@selected_model_id in [nil, ""]}>
                <%= if @model_selection_enabled do %>
                  <%!-- zh_CN: Auto → "自动"（按模型选择规则/脚本自动选择模型） --%>
                  {gettext("Auto (by rules)")}
                <% else %>
                  <%!-- zh_CN: Auto → "自动"（未配置模型选择脚本，使用默认模型） --%>
                  {gettext("Auto")}
                <% end %>
              </option>
              <%= for profile <- @model_profiles do %>
                <option value={profile.id} selected={@selected_model_id == profile.id}>
                  {profile.id}
                </option>
              <% end %>
            </select>
          <% end %>
          <button
            type="button"
            phx-click="new_chat"
            disabled={@chat_status != :idle}
            class="inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-sm font-medium text-base-content/70 hover:bg-base-200 hover:text-base-content transition-colors disabled:opacity-40 disabled:pointer-events-none shrink-0"
          >
            <.icon name="hero-plus" class="size-4" />
            <%!-- zh_CN: "新对话" --%>{gettext("New chat")}
          </button>
        </div>

        <!-- Messages container (the AgentHistoryAutoScroll hook scrolls this element) -->
        <div
          id="chat-messages"
          phx-hook="AgentHistoryAutoScroll"
          class="flex-1 min-h-0 overflow-y-auto scrollbar-thin"
        >
          <%= if @transcript == [] do %>
            <.empty_state />
          <% else %>
            <.message_list
              transcript={@transcript}
              chat_task_status={@chat_task_status}
              thought_process={@thought_process}
              raw_entry_ids={@raw_entry_ids}
            />
          <% end %>
        </div>

        <!-- Pending command approvals (security levels 2 & 3): the reflect
             agent is BLOCKED mid-turn on a run_command approval until the user
             decides. Render one ApprovalCard per pending request, pinned
             between the messages scroller and the composer so they stay
             visible while the transcript scrolls. The area scrolls internally
             if several requests ever pend at once. -->
        <%= if @pending_approvals != [] do %>
          <div class="shrink-0 max-h-44 overflow-y-auto scrollbar-thin">
            <%= for request <- @pending_approvals do %>
              <.approval_card request={request} />
            <% end %>
          </div>
        <% end %>

        <!-- Composer: pinned bottom, outside the messages scroller -->
        <div class="shrink-0 px-4 pt-2 pb-3 bg-gradient-to-t from-base-100 from-60% to-transparent">
          <form
            id="chat-form"
            phx-submit="send_message"
            phx-change="chat_input"
            class="help-composer flex items-end gap-2"
          >
            <textarea
              name="message"
              value={@chat_draft}
              phx-keydown="chat_keydown"
              phx-keyup="chat_keyup"
              disabled={@chat_status != :idle}
              placeholder={gettext("Message Genesis…")}
              rows="1"
              class="w-full min-h-[46px] max-h-40 resize-y bg-transparent px-4 py-3 text-base leading-relaxed placeholder:text-base-content/50 focus:outline-none disabled:opacity-50"
            ></textarea>
            <!-- Send → Stop morph: exactly one button is visible at a time; both
                 stay in the DOM (the hidden one disabled) so the Stop button's
                 presence/disabled state remains assertable on idle. -->
            <button
              type="submit"
              disabled={@chat_status != :idle}
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
          </form>
          <div class="mt-1.5 text-center text-xs text-base-content/60">
            <%!-- zh_CN: "回车发送 · Shift+回车换行" --%>{gettext(
              "Enter to send · Shift+Enter for a new line"
            )}
            <%= if @chat_status == :idle and @transcript == [] do %>
              <br />
              <%!-- zh_CN: "Genesis 可能会出错，请核实重要信息。" --%>{gettext(
                "Genesis can make mistakes. Verify important information."
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
    # On the dead render (initial HTTP request), redirect first-time users to
    # /welcome (same pattern as ProjectsLive). Runs ONLY on the dead render;
    # connected mounts skip it to avoid redirect loops.
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
        # Run-command approvals (security levels 2 & 3): the reflect agent is
        # blocked mid-turn until the user decides on the request card.
        Phoenix.PubSub.subscribe(EvoGit.PubSub, "approvals")
      end

      socket =
        socket
        |> assign(base_assigns())
        |> attach_chat()
        |> assign_model_select()

      {:ok, socket}
    end
  end

  # Seed assigns for every mount (fresh state; `attach_chat/1` then overlays
  # the persisted chat on connected mounts). Includes the live-chat keys added
  # by the ChatHistory persistence + the assistant task-card (`chat_id`,
  # `chat_node`, `chat_task_status`, `thought_process`).
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
      chat_fetch_seq: 0,
      chat_task_fetch_seq: 0,
      shift_down: false,
      selected_model_id: nil,
      # Ephemeral UI state: transcript entry ids currently shown in RAW (plain
      # text) view instead of the markdown render. Never persisted — entries
      # are cleared with the transcript on reset_chat.
      raw_entry_ids: MapSet.new(),
      # Ephemeral UI state: pending run-command approval requests (security
      # levels 2 & 3) for THIS chat's task/agent, each waiting for the user's
      # Confirm/Deny on its ApprovalCard. Never persisted — a page refresh
      # clears them (the backend resolves stragglers with a timeout
      # :approval_resolved broadcast); cleared on reset_chat too.
      pending_approvals: [],
      model_profiles: [],
      model_selection_enabled: false,
      current_path: ~p"/help"
    }
  end

  # Loads the node's model profiles + model-selection-script state for the
  # header model selector (node-aware; degrades to {[], false} on RPC failure —
  # see ModelSelect.load/1). Re-run on every handle_params so a `?node=` switch
  # reloads for the resolved target. Only assigns `model_profiles` /
  # `model_selection_enabled` — the `selected_model_id` pin (restored by
  # ChatState, kept across new chats / node switches) is never touched here.
  defp assign_model_select(socket) do
    {model_profiles, model_selection_enabled} =
      ModelSelect.load(socket.assigns[:current_node] || node())

    assign(socket,
      model_profiles: model_profiles,
      model_selection_enabled: model_selection_enabled
    )
  end

  @impl true
  def handle_params(params, _url, socket) do
    prev_node = socket.assigns[:current_node]
    socket = NodeAware.assign_node(socket, params)

    # Node switch: the old chat's task belongs to the old node. Start a NEW
    # persisted chat (the old one stays in memory under ChatHistory; its
    # events are node-filtered anyway) and reset all live chat state.
    #
    # Two switch shapes:
    #   * mid-session switch — `prev_node` was already resolved and changed;
    #   * fresh load on a different node — the restored chat carries the node
    #     it was created on (`:chat_node`); a mismatch means the chat is stale
    #     for the viewed node.
    # `prev_node == nil` on the FIRST handle_params (mount → params) must NOT
    # count as a switch: `assign_node` resolves local to `node()`, and wiping
    # the just-restored chat there would defeat the persistence.
    node_changed = prev_node != nil and socket.assigns[:current_node] != prev_node

    chat_node_mismatch =
      socket.assigns[:chat_node] != nil and
        socket.assigns[:chat_node] != socket.assigns[:current_node]

    socket =
      if node_changed or chat_node_mismatch do
        start_new_chat(socket)
      else
        socket
      end

    # Re-load the model profiles / selection-script state for the RESOLVED
    # node (a `?node=` switch may have landed on a different target).
    socket =
      socket
      |> assign_model_select()
      |> assign(current_path: ~p"/help")

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", %{"message" => text}, socket), do: send_chat(socket, text)

  @impl true
  def handle_event("send_message", _params, socket),
    do: send_chat(socket, socket.assigns[:chat_draft])

  @impl true
  def handle_event("chat_input", %{"message" => text}, socket) do
    {:noreply, assign(socket, chat_draft: text || "")}
  end

  @impl true
  def handle_event("chat_keydown", %{"key" => key}, socket) do
    case key do
      "Shift" ->
        {:noreply, assign(socket, shift_down: true)}

      "Enter" ->
        if socket.assigns[:shift_down] do
          # Shift held — let the browser insert the newline; do not submit.
          {:noreply, socket}
        else
          send_chat(socket, socket.assigns[:chat_draft])
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("chat_keyup", %{"key" => key}, socket) do
    case key do
      "Shift" -> {:noreply, assign(socket, shift_down: false)}
      _ -> {:noreply, socket}
    end
  end

  # Form-less phx-change on the header model select may arrive keyed either by
  # the select's `name` ("model_id") or by the generic "value" — handle both.
  # The empty "" (Auto option) normalizes to nil via ChatState.normalize_model_id/1.
  @impl true
  def handle_event("select_chat_model", %{"model_id" => id}, socket) do
    {:noreply,
     socket
     |> assign(selected_model_id: ChatState.normalize_model_id(id))
     |> persist_state()}
  end

  @impl true
  def handle_event("select_chat_model", %{"value" => id}, socket) do
    {:noreply,
     socket
     |> assign(selected_model_id: ChatState.normalize_model_id(id))
     |> persist_state()}
  end

  # Per-message raw/markdown toggle on an assistant entry (phx-click from the
  # AssistantMessage hover action group). The entry id is a generated binary —
  # used only as a MapSet key, no atom conversion. Ephemeral UI state: kept in
  # :raw_entry_ids, never persisted.
  @impl true
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

  # Fired by the global ClipboardCopy JS hook after a successful copy (same
  # flash pattern as tasks_live.ex / review_live.ex).
  @impl true
  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
  end

  @impl true
  def handle_event("new_chat", _params, socket) do
    if socket.assigns[:chat_status] == :idle do
      {:noreply, start_new_chat(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("stop", _params, socket) do
    case socket.assigns[:chat_task_id] do
      nil ->
        {:noreply, socket}

      task_id ->
        # Graceful cancel: :pending → immediate :cancelled; :running →
        # :cancelling (agents save + exit, result preserved). The :cancelled
        # task event completes the transition and finalizes the transcript.
        case EvoDash.NodeContext.cancel_task(socket.assigns[:current_node] || node(), task_id) do
          :ok ->
            {:noreply,
             socket
             |> assign(chat_status: :cancelling, chat_task_status: :cancelling)
             |> persist_state()}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Failed to stop: %{reason}", reason: inspect(reason))
             )}
        end
    end
  end

  # Command-approval decision (Confirm/Deny on an ApprovalCard — security
  # levels 2 & 3). Validates the decision, resolves the target node from the
  # pending request map (it may differ from the viewed node if the request
  # raced a node switch), routes the response through the call-time
  # :approval_responder seam, and OPTIMISTICALLY removes the card regardless
  # of the outcome (the :approval_resolved broadcast is the backstop). Total:
  # the responder contract is `:ok | {:error, reason}` and every clause keeps
  # the LiveView alive.
  @impl true
  def handle_event(
        "approval_response",
        %{"request_id" => request_id, "decision" => decision},
        socket
      )
      when decision in ["approve", "deny"] and is_binary(request_id) and request_id != "" do
    pending =
      case socket.assigns[:pending_approvals] do
        list when is_list(list) -> list
        _ -> []
      end

    # The request's OWN node wins when still pending; the viewed node is the
    # fallback once the card is gone (double click / already resolved).
    node =
      case Enum.find(pending, &(Map.get(&1, :request_id) == request_id)) do
        %{node: req_node} when not is_nil(req_node) -> req_node
        _ -> socket.assigns[:current_node] || node()
      end

    # Call-time test seam (dashboard idiom — mirrors :review_merge_runner /
    # :update_check_runner): tests inject `:approval_responder` to capture the
    # args deterministically while the backend responder lands.
    responder =
      Application.get_env(:evo_dash, :approval_responder, &EvoDash.NodeContext.approval_response/3)

    socket = assign(socket, pending_approvals: drop_approval(pending, request_id))

    case responder.(node, request_id, decision) do
      :ok ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           # zh_CN: 审批响应失败（本地/远程审批通道出错；卡片已收起，超时会兜底清理）
           gettext("Failed to respond: %{reason}", reason: inspect(reason))
         )}

      _other ->
        # Total guard: an unexpected return shape must never crash the
        # LiveView — the card is already removed, nothing more to do.
        {:noreply, socket}
    end
  end

  # Missing params / invalid decision (or a blank request id) — no-op.
  @impl true
  def handle_event("approval_response", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:task_updated, task_id, status, node} = msg, socket) do
    # NodeAware.handle_task_info/2 applies the node filter (drops foreign-node
    # events BEFORE the debounce) and schedules the 300ms debounced
    # :node_aware_reload_tasks; it returns {:noreply, socket}. We extract the
    # socket and then run the chat-specific handling for our own task.
    {:noreply, socket} = NodeAware.handle_task_info(socket, msg)
    {:noreply, handle_task_event(socket, task_id, status, node)}
  end

  @impl true
  def handle_info({:task_deleted, task_id, node} = msg, socket) do
    {:noreply, socket} = NodeAware.handle_task_info(socket, msg)
    {:noreply, handle_task_deleted(socket, task_id, node)}
  end

  @impl true
  def handle_info({:agent_registered, id, summary, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         Map.get(summary, :task_id) == socket.assigns[:chat_task_id] do
      socket =
        assign(socket,
          chat_agent_id: id,
          agent_message_count: AgentStream.message_count(summary)
        )

      {:noreply, socket |> persist_state() |> async_fetch_history()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:agent_updated, id, changed_fields, node}, socket) do
    # `changed_fields` is a KEYWORD LIST in real core broadcasts (e.g.
    # `[message_count: n, ...]` from `EvoGit.AgentScheduler.Store.put_agent_state`),
    # so membership must be tested with `Keyword.has_key?/2` — the same
    # pattern AgentsLive uses (agents_live.ex). The core guarantees
    # `:message_count` in changed_fields whenever the agent's context changed;
    # no other field change triggers a refetch (HistoryGate choice: refetch
    # only when the conversation actually moved).
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         id == socket.assigns[:chat_agent_id] and
         is_list(changed_fields) and Keyword.has_key?(changed_fields, :message_count) do
      {:noreply, async_fetch_history(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:agent_removed, _id, _node}, socket) do
    # The terminal task event (task_updated :completed/:cancelled/:failed or
    # task_deleted) finalizes the transcript — no action needed here.
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agents_updated, node}, socket) do
    # Fallback when an agent_registered broadcast was missed: if a task is
    # running but no agent is known yet, re-look it up.
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         socket.assigns[:chat_task_id] != nil and socket.assigns[:chat_agent_id] == nil do
      {:noreply, async_lookup_agent(socket)}
    else
      {:noreply, socket}
    end
  end

  # A run-command approval was requested by the reflect agent (security levels
  # 2 & 3 — level 1 executes immediately and never broadcasts). Keep ONLY
  # requests that belong to THIS chat's task/agent AND THIS node — everything
  # else (other chats/tasks/agents, other nodes) is ignored. On match the
  # request map is upserted into :pending_approvals (deduped by request_id — a
  # duplicate REPLACES the earlier entry). Ephemeral UI state — never
  # persisted.
  @impl true
  def handle_info({:approval_requested, request}, socket) do
    if own_request?(socket, request) do
      pending =
        case socket.assigns[:pending_approvals] do
          list when is_list(list) -> list
          _ -> []
        end

      {:noreply, assign(socket, pending_approvals: upsert_approval(pending, request))}
    else
      {:noreply, socket}
    end
  end

  # An approval was resolved somewhere (approve/deny by the user, or
  # :cancelled / :timed_out by the backend) — drop its card. Total: unknown
  # request ids filter to a no-op.
  @impl true
  def handle_info({:approval_resolved, request_id, _decision}, socket) do
    pending =
      case socket.assigns[:pending_approvals] do
        list when is_list(list) -> list
        _ -> []
      end

    {:noreply, assign(socket, pending_approvals: drop_approval(pending, request_id))}
  end

  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    socket =
      socket
      |> NodeAware.reload_tasks()
      |> NodeAware.clear_task_reload_pending()

    {:noreply, socket}
  end

  @impl true
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

        {:noreply, socket |> persist_state() |> async_fetch_history()}
      else
        # Agent not registered yet — wait for agent_registered / agents_updated
        # to retrigger the lookup.
        {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_info({:chat_history_loaded, node, seq, agent_id, result}, socket) do
    if stale?(socket, node, seq) or agent_id != socket.assigns[:chat_agent_id] do
      {:noreply, socket}
    else
      case result do
        msgs when is_list(msgs) ->
          text = Messages.assistant_text(msgs)

          transcript =
            if text == "" do
              socket.assigns[:transcript]
            else
              Transcript.put_streaming_text(socket.assigns[:transcript], text)
            end

          {:noreply,
           socket
           |> assign(
             transcript: transcript,
             agent_message_count: length(msgs),
             thought_process: Messages.to_entries(msgs)
           )
           |> persist_state()}

        _ ->
          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_info({:chat_task_loaded, node, seq, task_id, task}, socket) do
    if node != socket.assigns[:current_node] or
         seq != socket.assigns[:chat_task_fetch_seq] or
         task_id != socket.assigns[:chat_task_id] do
      {:noreply, socket}
    else
      {:noreply, finalize_terminal(socket, task)}
    end
  end

  @impl true
  def handle_info({:node_selected, node_id}, socket) do
    NodeAware.handle_node_selected(socket, node_id)
  end

  @impl true
  def handle_info({:remote_connection_status, target_id, status}, socket) do
    NodeAware.handle_connection_status(socket, {:remote_connection_status, target_id, status})
  end

  @impl true
  def handle_info(_msg, socket) do
    # Catch-all — NodeAware's attached hook passes other messages through.
    {:noreply, socket}
  end

  # Shared submit path for the Send button and the Enter key. Returns
  # {:noreply, socket}.
  defp send_chat(socket, text) do
    if socket.assigns[:chat_status] != :idle do
      # Defensive — the input is disabled while running anyway.
      {:noreply, socket}
    else
      text = String.trim(text || "")

      if text == "" do
        {:noreply, socket}
      else
        objective =
          case Transcript.build_preamble(socket.assigns[:transcript]) do
            {:ok, preamble} -> preamble <> "New message: " <> text
            :empty -> text
          end

        # Optimistic bubbles: the user message + an empty streaming assistant
        # bubble (pulsing dots) appear immediately.
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

        # Synchronous per-click mutation (dashboard convention): starts the
        # repo-less reflect task on the viewed node. NO :path key. The pinned
        # model (if any) is threaded via ModelSelect.task_opts/2 — :model_id +
        # :model_id_locked when the header selector pinned a profile, nothing
        # on Auto (the runtime's model-selection script or default decides).
        result =
          EvoDash.NodeContext.start_task(socket.assigns[:current_node] || node(), :reflect,
            ModelSelect.task_opts(socket.assigns[:selected_model_id],
              mode: "reflect",
              objective: objective
            )
          )

        case result do
          {:ok, _task} ->
            case AgentStream.task_id_from_start(result) do
              {:ok, id} ->
                socket =
                  socket
                  |> assign(chat_task_id: id, chat_task_status: :pending)
                  |> persist_state()
                  |> async_lookup_agent()

                {:noreply, socket}

              {:error, :no_task_id} ->
                socket =
                  socket
                  |> finalize_streaming(gettext("Failed to start the task: no task id returned"))
                  |> assign(:chat_status, :idle)
                  |> persist_state()

                {:noreply, socket}
            end

          {:error, reason} ->
            socket =
              socket
              |> finalize_streaming(
                gettext("Failed to start the task: %{reason}", reason: inspect(reason))
              )
              |> assign(:chat_status, :idle)
              |> persist_state()

            {:noreply, socket}
        end
      end
    end
  end

  # Spawns a supervised lookup of the reflect task's root agent. `node_override`
  # targets a specific node (mount reconciliation uses the chat's OWN
  # `:chat_node`); the default is the viewed node. Bumps :chat_fetch_seq so
  # only the latest in-flight result applies.
  defp async_lookup_agent(socket, node_override \\ nil) do
    task_id = socket.assigns[:chat_task_id]
    node = node_override || socket.assigns[:current_node] || node()
    seq = socket.assigns[:chat_fetch_seq] + 1
    pid = self()

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      agents =
        try do
          EvoDash.NodeContext.list_agents(node)
        rescue
          # Justified async-boundary rescue: this closure runs OUTSIDE the
          # LiveView process, so an unexpected exception must never crash the
          # supervised task silently (the result message would never be sent
          # and the lookup would be lost). Report [] — the caller then waits
          # for the agent_registered / agents_updated retrigger.
          _ -> []
        end

      agent = AgentStream.find_root_agent(agents, task_id)
      send(pid, {:chat_agent_lookup, node, seq, task_id, agent})
    end)

    assign(socket, chat_fetch_seq: seq)
  end

  # Spawns a supervised history fetch for the chat agent. `node_override`
  # targets a specific node (see async_lookup_agent/2). Bumps :chat_fetch_seq
  # (HistoryGate-style: only refetched when the agent's message_count moved).
  defp async_fetch_history(socket, node_override \\ nil) do
    agent_id = socket.assigns[:chat_agent_id]
    node = node_override || socket.assigns[:current_node] || node()
    seq = socket.assigns[:chat_fetch_seq] + 1
    pid = self()

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result =
        try do
          EvoDash.NodeContext.get_agent_history(node, agent_id)
        rescue
          # Justified async-boundary rescue (same rationale as
          # async_lookup_agent): report [] so the LiveView's case falls to the
          # unchanged branch instead of wedging.
          _ -> []
        end

      send(pid, {:chat_history_loaded, node, seq, agent_id, result})
    end)

    assign(socket, chat_fetch_seq: seq)
  end

  # Spawns a supervised task fetch used to finalize the transcript with the
  # preserved/final result (also the ONE-SHOT mount reconciliation fetch).
  # Bumps :chat_task_fetch_seq (its own counter, so a late history/lookup
  # fetch can never invalidate the terminal result).
  defp async_fetch_task(socket, node_override \\ nil) do
    task_id = socket.assigns[:chat_task_id]
    node = node_override || socket.assigns[:current_node] || node()
    seq = socket.assigns[:chat_task_fetch_seq] + 1
    pid = self()

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      task =
        try do
          EvoDash.NodeContext.get_task(node, task_id)
        rescue
          # Justified async-boundary rescue (same rationale as
          # async_lookup_agent): report nil so finalize_terminal treats it as
          # deleted instead of wedging.
          _ -> nil
        end

      send(pid, {:chat_task_loaded, node, seq, task_id, task})
    end)

    assign(socket, chat_task_fetch_seq: seq)
  end

  # Chat-specific handling of a task lifecycle event for OUR task (node filter
  # and task_id match already checked by the caller). Every status updates the
  # badge assign (`:chat_task_status`); `nil` = review-only mutation → no-op.
  defp handle_task_event(socket, task_id, status, node) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         task_id == socket.assigns[:chat_task_id] do
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

          nil ->
            socket

          _ ->
            socket
        end

      persist_state(socket)
    else
      socket
    end
  end

  # The chat task was deleted. Finalize with a marker and clear the task refs
  # (the transcript stays visible so the user sees the history).
  defp handle_task_deleted(socket, task_id, node) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         task_id == socket.assigns[:chat_task_id] do
      socket
      |> finalize_streaming(gettext("The conversation was deleted."))
      |> clear_task_refs()
      |> persist_state()
    else
      socket
    end
  end

  # Finalizes the last streaming assistant bubble (or appends a new assistant
  # entry) with `text`.
  defp finalize_streaming(socket, text) do
    assign(socket, transcript: Transcript.finalize_assistant(socket.assigns[:transcript], text))
  end

  # Applies a fetched task to the transcript. Terminal statuses finalize the
  # transcript and clear the task/agent refs (the transcript AND the final
  # badge stay visible; New chat is re-enabled). Non-terminal statuses (e.g. a
  # mount-reconciliation fetch that found a still-alive task) only refresh the
  # badge/status assigns — the task is still alive, so the refs MUST stay for
  # further task/agent events to match (no finalization, no clearing).
  defp finalize_terminal(socket, task) do
    cond do
      task == nil ->
        socket
        |> finalize_streaming(gettext("The conversation was deleted."))
        |> clear_task_refs()
        |> persist_state()

      is_map(task) ->
        case Map.get(task, :status) do
          status when status in @terminal_statuses ->
            socket = assign(socket, chat_task_status: status)

            socket =
              case status do
                :completed -> finalize_completed(socket, Map.get(task, :result))
                :cancelled -> finalize_cancelled(socket, Map.get(task, :result))
                :failed -> finalize_streaming(socket, gettext("The task failed."))
              end

            socket
            |> clear_task_refs()
            |> persist_state()

          :cancelling ->
            socket
            |> assign(chat_task_status: :cancelling, chat_status: :cancelling)
            |> persist_state()

          status when status in [:running, :pending, :finalizing] ->
            socket
            |> assign(chat_task_status: status)
            |> persist_state()

          _ ->
            # Missing/unknown status on a live task: nothing to apply — keep
            # refs and current state (a later broadcast will finalize).
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
    # Graceful cancel preserves the final result when the agent completed.
    case AgentStream.extract_final_text(result) do
      {:ok, text} -> finalize_streaming(socket, text)
      _ -> finalize_streaming(socket, gettext("Stopped."))
    end
  end

  # Terminal state: drops the task/agent refs (no further task/agent events
  # can match) and re-enables input, keeping the transcript AND the final
  # `:chat_task_status` badge (and thought process) visible on the card.
  defp clear_task_refs(socket) do
    assign(socket,
      chat_task_id: nil,
      chat_agent_id: nil,
      agent_message_count: nil,
      chat_status: :idle
    )
  end

  # Full live-chat reset (New chat / node switch): clears everything including
  # the transcript. The persisted chat (if any) is untouched —
  # `start_new_chat/1` owns creating + persisting the fresh empty chat.
  defp reset_chat(socket) do
    assign(socket,
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
      # The user's pinned model choice SURVIVES a new chat (and a node switch):
      # only a fresh mount with no restored chat seeds `selected_model_id: nil`
      # (base_assigns). ChatState persists/restores it per chat, so the choice
      # keeps threading into sends after a new chat.
      #
      # `raw_entry_ids` (per-entry raw-view flags) IS cleared here — the
      # transcript entries it refers to are gone with the reset.
      raw_entry_ids: MapSet.new(),
      # Pending approval cards belong to the OLD chat's task — cleared here
      # too (the backend resolves stragglers with a timeout broadcast).
      pending_approvals: []
    )
  end

  # Own-request filter for `{:approval_requested, request}` broadcasts. A
  # request belongs to this chat when it carries a usable request_id AND
  # (its task_id matches OUR chat task OR its agent_id matches OUR chat
  # agent) AND its node matches the chat's node (the chat's own `:chat_node`,
  # falling back to the viewed node; a nil request node matches everything —
  # the backend always stamps it, but stay lenient). Type tolerance: agent
  # ids may be integers in the core while the request contract says strings →
  # compared via `to_string/1`; task ids are binaries on both sides
  # (`chat_task_id` is normalized to a binary by `ChatState.restore/1` and
  # `AgentStream.task_id_from_start/1` only accepts binaries). Total — the
  # assigns may be nil/absent on fresh sockets.
  defp own_request?(socket, request) do
    is_map(request) and
      is_binary(Map.get(request, :request_id)) and
      (own_task_request?(socket, request) or own_agent_request?(socket, request)) and
      own_node_request?(socket, request)
  end

  defp own_task_request?(socket, request) do
    req_task_id = Map.get(request, :task_id)
    chat_task_id = socket.assigns[:chat_task_id]
    req_task_id != nil and chat_task_id != nil and req_task_id == chat_task_id
  end

  defp own_agent_request?(socket, request) do
    req_agent_id = Map.get(request, :agent_id)
    chat_agent_id = socket.assigns[:chat_agent_id]
    req_agent_id != nil and chat_agent_id != nil and to_string(req_agent_id) == to_string(chat_agent_id)
  end

  defp own_node_request?(socket, request) do
    req_node = Map.get(request, :node)
    chat_node = socket.assigns[:chat_node] || socket.assigns[:current_node]
    req_node == nil or req_node == chat_node
  end

  # Upserts a request into the pending list (newest first): any earlier entry
  # with the same request_id is dropped (replaced) so duplicates never stack.
  defp upsert_approval(pending, request) do
    [request | Enum.reject(pending, &(Map.get(&1, :request_id) == Map.get(request, :request_id)))]
  end

  # Drops the pending entry with the given request_id (no-op when absent).
  # Total — request_id may be any term.
  defp drop_approval(pending, request_id) do
    Enum.reject(pending, &(Map.get(&1, :request_id) == request_id))
  end

  # Starts a NEW persisted chat (old chats stay in ChatHistory — there is no
  # chat-switching UI yet) and resets all live chat state, persisting the
  # fresh empty state. The store mutation is connected-only: a dead-render
  # handle_params with `?node=` must not create a chat per HTTP request.
  # Prune cap: keep the newest 10 chats (bounded memory).
  defp start_new_chat(socket) do
    socket =
      if connected?(socket) do
        chat_id = EvoDash.ChatHistory.new_chat()
        EvoDash.ChatHistory.prune(10)
        assign(socket, chat_id: chat_id)
      else
        socket
      end

    socket
    |> reset_chat()
    |> persist_state()
  end

  # Connected mounts attach to the persisted current chat (creating one when
  # none exists) and restore its state. The dead render deliberately SKIPS the
  # store — the initial HTTP request must not create a chat per page load.
  defp attach_chat(socket) do
    if connected?(socket) do
      chat_id = EvoDash.ChatHistory.current_chat_id() || EvoDash.ChatHistory.new_chat()

      socket =
        socket
        |> assign(chat_id: chat_id)
        |> assign(ChatState.restore(EvoDash.ChatHistory.get_state(chat_id)))

      reconcile_chat(socket)
    else
      socket
    end
  end

  # ONE-SHOT reconciliation (NOT polling): a chat that was mid-flight when the
  # page was left missed its terminal task events. Re-fetch the task once — a
  # terminal status finalizes the transcript, a live status just refreshes the
  # badge — and re-link the agent stream (a single history refetch, or a
  # lookup when the agent was never observed). All fetches target the chat's
  # OWN node (`:chat_node`), not the viewed node — the chat's task lives there.
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

  # Persists the full chat state into ChatHistory (in-memory, opaque per-chat
  # map — the LiveView owns the shape via ChatState). Skipped on dead renders
  # (no chat attached yet). Persist points: send, stop, every task/agent
  # status event, the async lookup/history/task results, finalize paths, New
  # chat, and node switches. The `chat_input` draft is NOT persisted per
  # keystroke (documented choice).
  defp persist_state(socket) do
    if connected?(socket) and socket.assigns[:chat_id] != nil do
      EvoDash.ChatHistory.put_state(socket.assigns[:chat_id], ChatState.build(socket.assigns))
    end

    socket
  end

  # Stale-guard for async chat fetches: the result applies only when the node
  # context is unchanged AND no newer fetch was spawned since.
  defp stale?(socket, node, seq) do
    node != socket.assigns[:current_node] or seq != socket.assigns[:chat_fetch_seq]
  end
end
