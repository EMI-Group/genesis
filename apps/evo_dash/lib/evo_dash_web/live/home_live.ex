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
  `EvoDashWeb.HomeLive.AssistantMessage`.
  """
  use EvoDashWeb, :live_view
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.HomeLive.{AgentStream, ChatState, Messages, Transcript}
  alias EvoDashWeb.LiveHooks.NodeAware

  import EvoDashWeb.HomeLive.AssistantMessage

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
    >
      <div class="flex flex-col h-full min-h-0 max-w-3xl mx-auto w-full">
        <!-- Header: slim top bar with title/subtitle left, one ghost New chat button right -->
        <div class="shrink-0 flex items-center justify-between gap-3 px-4 pt-4 pb-2">
          <div class="min-w-0">
            <h1 class="text-base font-semibold truncate">
              <%!-- zh_CN: "与 Genesis 对话" --%>{gettext("Chat with Genesis")}
            </h1>
            <p class="text-xs text-base-content/50 truncate hidden sm:block">
              <%!-- zh_CN: "向 Genesis 提问、阅读源码、控制任务或获得仪表盘引导" --%>{gettext(
                "Ask about Genesis, inspect the source, control tasks, and get guided through the dashboard."
              )}
            </p>
          </div>
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
            <!-- Empty state: logo mark, greeting, and suggestion chips -->
            <div class="h-full min-h-0 flex flex-col items-center justify-center gap-3 text-center px-6 pb-10">
              <%!-- zh_CN: EvoX Genesis → "天演 · 启元" (天演 · 啟元) --%>
              <img
                src={~p"/images/logo.svg"}
                class="h-14 w-auto dark:hidden"
                alt={gettext("EvoX Genesis")}
              />
              <%!-- zh_CN: EvoX Genesis → "天演 · 启元" (天演 · 啟元) --%>
              <img
                src={~p"/images/logo-alt.svg"}
                class="h-14 w-auto hidden dark:block"
                alt={gettext("EvoX Genesis")}
              />
              <p class="text-[11px] font-semibold uppercase tracking-[0.2em] text-base-content/40">
                <%!-- zh_CN: "开始对话" --%>{gettext("Start a conversation")}
              </p>
              <h2 class="text-2xl sm:text-3xl font-semibold tracking-tight text-base-content">
                <%!-- zh_CN: "今天有什么可以帮你的？" --%>{gettext(
                  "How can I help you today?"
                )}
              </h2>
              <p class="max-w-md text-sm text-base-content/50">
                <%!-- zh_CN: "与 Genesis 助手聊天：询问代码库、探索源码、控制任务，或获得仪表盘引导" --%>{gettext(
                  "Chat with the Genesis assistant: ask about the codebase, explore the source, control running tasks, or get guided through the dashboard."
                )}
              </p>
              <div class="mt-4 grid grid-cols-1 sm:grid-cols-2 gap-2 w-full max-w-xl">
                <%!-- zh_CN: "解释 Genesis 的架构" --%>
                <.suggestion_chip message={gettext("Explain the Genesis architecture")}>
                  <.icon
                    name="hero-light-bulb"
                    class="size-4 mt-0.5 shrink-0 text-primary/70 group-hover:text-primary"
                  />
                </.suggestion_chip>
                <%!-- zh_CN: "任务取消是如何工作的？" --%>
                <.suggestion_chip message={gettext("How does task cancellation work?")}>
                  <.icon
                    name="hero-magnifying-glass"
                    class="size-4 mt-0.5 shrink-0 text-primary/70 group-hover:text-primary"
                  />
                </.suggestion_chip>
                <%!-- zh_CN: "你能帮我做什么？" --%>
                <.suggestion_chip message={gettext("What can you help me with?")}>
                  <.icon
                    name="hero-puzzle-piece"
                    class="size-4 mt-0.5 shrink-0 text-primary/70 group-hover:text-primary"
                  />
                </.suggestion_chip>
                <%!-- zh_CN: "引导我使用仪表盘" --%>
                <.suggestion_chip message={gettext("Guide me through the dashboard")}>
                  <.icon
                    name="hero-map"
                    class="size-4 mt-0.5 shrink-0 text-primary/70 group-hover:text-primary"
                  />
                </.suggestion_chip>
              </div>
            </div>
          <% else %>
            <div class="px-4 py-6 pb-8 space-y-6">
              <%= for {entry, index} <- Enum.with_index(@transcript) do %>
                <div id={"chat-entry-" <> entry.id} class={bubble_wrapper_class(entry)}>
                  <%= case entry.role do %>
                    <% :user -> %>
                      <div class="max-w-[80%] sm:max-w-[75%] rounded-3xl rounded-br-md bg-primary text-primary-content px-4 py-2.5 text-[15px] leading-relaxed whitespace-pre-wrap break-words shadow-sm">
                        {entry.text}
                      </div>
                    <% :assistant -> %>
                      <% is_last = index == last_assistant_index(@transcript) %>
                      <.assistant_message
                        entry={entry}
                        task_status={if is_last, do: @chat_task_status, else: nil}
                        thought_process={if is_last, do: @thought_process, else: []}
                      />
                    <% :error -> %>
                      <div class="flex items-start gap-2 rounded-xl border border-error/25 bg-error/10 px-3.5 py-2.5 text-[13px] leading-relaxed text-error whitespace-pre-wrap break-words">
                        <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
                        {entry.text}
                      </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

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
              class="w-full min-h-[46px] max-h-40 resize-y bg-transparent px-4 py-3 text-[15px] leading-relaxed placeholder:text-base-content/40 focus:outline-none disabled:opacity-50"
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
          <div class="mt-1.5 text-center text-[11px] text-base-content/40">
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
      end

      socket =
        socket
        |> assign(base_assigns())
        |> attach_chat()

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
      current_path: ~p"/help"
    }
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

    socket = assign(socket, current_path: ~p"/help")
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
        # repo-less reflect task on the viewed node. NO :path key.
        result =
          EvoDash.NodeContext.start_task(socket.assigns[:current_node] || node(), :reflect,
            mode: "reflect",
            objective: objective
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
      chat_task_fetch_seq: 0
    )
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

  # Index of the LAST assistant entry in the transcript (the one tied to the
  # current/last chat task — only it gets the task badge + thought process).
  defp last_assistant_index(transcript) do
    transcript
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%{role: :assistant}, index}, _acc -> index
      _, acc -> acc
    end)
  end

  # Bubble wrapper alignment: user entries right-aligned, assistant/error left.
  defp bubble_wrapper_class(entry) do
    case entry.role do
      :user -> "flex justify-end"
      _ -> "flex justify-start"
    end
  end

  attr(:message, :string,
    required: true,
    doc: "Translated suggestion text — used as both the visible label and phx-value-message"
  )

  slot(:inner_block, required: true, doc: "The suggestion chip's icon")

  # Empty-state suggestion chip: a button that sends the message as a chat
  # prompt. The root button keeps the `group` class so the slot icon's
  # `group-hover:` styles keep working.
  defp suggestion_chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="send_message"
      phx-value-message={@message}
      class="group flex items-start gap-2.5 rounded-xl border border-base-300/50 bg-base-100 px-3.5 py-3 text-left text-[13px] leading-snug text-base-content/70 hover:border-primary/40 hover:bg-base-200/70 hover:text-base-content transition-colors"
    >
      {render_slot(@inner_block)}
      {@message}
    </button>
    """
  end
end
