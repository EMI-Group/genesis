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
  `:erpc`. Node-aware like every other page: `?node=` selects the viewed node
  and the whole chat state is dropped on a node switch (the old task belongs
  to the old node).
  """
  use EvoDashWeb, :live_view
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.HomeLive.{Transcript, Messages, AgentStream}
  alias EvoDashWeb.LiveHooks.NodeAware

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:dashboard}
      current_node_id={@current_node_id}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      pending_tasks={@pending_tasks}
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
    >
      <div class="flex flex-col h-full min-h-0 max-w-3xl mx-auto w-full">
        <!-- Header row: title + subtitle left; New chat / Stop right -->
        <div class="shrink-0 flex items-center justify-between gap-3 px-4 pt-4 pb-2">
          <div class="min-w-0">
            <h1 class="text-lg font-bold truncate">
              <%!-- zh_CN: "与 Genesis 对话" --%>{gettext("Chat with Genesis")}
            </h1>
            <p class="text-sm text-base-content/50 truncate">
              <%!-- zh_CN: "向 Genesis 提问、阅读源码、控制任务或获得仪表盘引导" --%>{gettext("Ask about Genesis, inspect the source, control tasks, and get guided through the dashboard.")}
            </p>
          </div>
          <div class="flex items-center gap-2 shrink-0">
            <button
              type="button"
              phx-click="new_chat"
              disabled={@chat_status != :idle}
              class="btn btn-sm btn-ghost gap-1 disabled:opacity-50"
            >
              <.icon name="hero-plus" class="size-4" />
              <%!-- zh_CN: "新对话" --%>{gettext("New chat")}
            </button>
            <button
              type="button"
              phx-click="stop"
              disabled={@chat_status != :running}
              class="btn btn-sm btn-ghost gap-1 text-error disabled:opacity-50"
            >
              <.icon name="hero-stop" class="size-4" />
              <%!-- zh_CN: "停止" --%>{gettext("Stop")}
            </button>
          </div>
        </div>

        <!-- Messages container -->
        <div
          id="chat-messages"
          phx-hook="AgentHistoryAutoScroll"
          class="flex-1 min-h-0 overflow-y-auto px-4 py-4"
        >
          <%= if @transcript == [] do %>
            <!-- Empty state -->
            <div class="h-full flex flex-col items-center justify-center gap-2 text-center px-6">
              <.icon name="hero-chat-bubble-left-right" class="size-10 text-base-content/30" />
              <h2 class="text-base font-semibold text-base-content/70">
                <%!-- zh_CN: "开始对话" --%>{gettext("Start a conversation")}
              </h2>
              <p class="text-sm text-base-content/50 max-w-md">
                <%!-- zh_CN: "与 Genesis 助手聊天：询问代码库、探索源码、控制任务，或获得仪表盘引导" --%>{gettext("Chat with the Genesis assistant: ask about the codebase, explore the source, control running tasks, or get guided through the dashboard.")}
              </p>
            </div>
          <% else %>
            <div class="space-y-4">
              <%= for entry <- @transcript do %>
                <div id={"chat-entry-" <> entry.id} class={bubble_wrapper_class(entry)}>
                  <%= case entry.role do %>
                    <% :user -> %>
                      <div class="max-w-[80%] rounded-lg rounded-br-sm bg-primary text-primary-content px-3 py-2 text-sm whitespace-pre-wrap">
                        <%= entry.text %>
                      </div>
                    <% :assistant -> %>
                      <div class="max-w-[80%] rounded-lg rounded-bl-sm bg-base-200 px-3 py-2 text-sm whitespace-pre-wrap">
                        <%= if entry.streaming and entry.text == "" do %>
                          <span class="inline-flex gap-1 py-1">
                            <span class="size-1.5 rounded-full bg-base-content/50 animate-bounce" style="animation-delay:0ms"></span>
                            <span class="size-1.5 rounded-full bg-base-content/50 animate-bounce" style="animation-delay:150ms"></span>
                            <span class="size-1.5 rounded-full bg-base-content/50 animate-bounce" style="animation-delay:300ms"></span>
                          </span>
                        <% else %>
                          <%= entry.text %>
                          <%= if entry.streaming do %>
                            <span class="inline-block size-1.5 rounded-full bg-base-content/50 animate-pulse ml-1 align-middle"></span>
                          <% end %>
                        <% end %>
                      </div>
                    <% :error -> %>
                      <div class="max-w-[80%] rounded-lg border border-error/30 bg-error/10 text-error px-3 py-2 text-sm whitespace-pre-wrap">
                        <%= entry.text %>
                      </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <!-- Input -->
        <form
          id="chat-form"
          phx-submit="send_message"
          phx-change="chat_input"
          class="shrink-0 border-t border-base-200 p-4"
        >
          <div class="flex items-end gap-2">
            <textarea
              name="message"
              value={@chat_draft}
              phx-keydown="chat_keydown"
              phx-keyup="chat_keyup"
              disabled={@chat_status != :idle}
              placeholder={gettext("Message Genesis…")}
              rows="1"
              class="textarea textarea-bordered textarea-sm w-full min-h-[44px] max-h-40 resize-y rounded-lg bg-base-100 focus:outline-none focus:ring-2 focus:ring-primary/40 focus:border-primary disabled:opacity-60"
            ></textarea>
            <button
              type="submit"
              disabled={@chat_status != :idle}
              class="btn btn-primary btn-sm shrink-0 gap-1 disabled:opacity-60"
            >
              <.icon name="hero-paper-airplane" class="size-4" />
              <%!-- zh_CN: "发送" --%>{gettext("Send")}
            </button>
          </div>
        </form>
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
        assign(socket,
          transcript: Transcript.new(),
          chat_draft: "",
          chat_status: :idle,
          chat_task_id: nil,
          chat_agent_id: nil,
          agent_message_count: nil,
          chat_fetch_seq: 0,
          chat_task_fetch_seq: 0,
          shift_down: false,
          current_path: ~p"/"
        )

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    prev_node = socket.assigns[:current_node]
    socket = NodeAware.assign_node(socket, params)

    # Node switch (local↔remote, pending→connected): the old chat task belongs
    # to the old node — drop all chat state so foreign agents/tasks never match.
    socket = if socket.assigns[:current_node] != prev_node, do: reset_chat(socket), else: socket
    socket = assign(socket, current_path: ~p"/")
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
      {:noreply, reset_chat(socket)}
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
            {:noreply, assign(socket, chat_status: :cancelling)}

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

      {:noreply, async_fetch_history(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:agent_updated, id, changed_fields, node}, socket) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         id == socket.assigns[:chat_agent_id] and
         is_list(changed_fields) and :message_count in changed_fields do
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

        {:noreply, async_fetch_history(socket)}
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

          {:noreply, assign(socket, transcript: transcript, agent_message_count: length(msgs))}

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
            chat_status: :running
          )

        # Synchronous per-click mutation (dashboard convention): starts the
        # repo-less reflect task on the viewed node. NO :path key.
        case EvoDash.NodeContext.start_task(socket.assigns[:current_node] || node(), :reflect,
               mode: "reflect",
               objective: objective
             ) do
          {:ok, task} ->
            case AgentStream.task_id_from_start(task) do
              {:ok, id} ->
                socket = assign(socket, chat_task_id: id)
                socket = async_lookup_agent(socket)
                {:noreply, socket}

              {:error, :no_task_id} ->
                socket =
                  socket
                  |> finalize_streaming(gettext("Failed to start the task: no task id returned"))
                  |> assign(:chat_status, :idle)

                {:noreply, socket}
            end

          {:error, reason} ->
            socket =
              socket
              |> finalize_streaming(
                gettext("Failed to start the task: %{reason}", reason: inspect(reason))
              )
              |> assign(:chat_status, :idle)

            {:noreply, socket}
        end
      end
    end
  end

  # Spawns a supervised lookup of the reflect task's root agent on the viewed
  # node. Bumps :chat_fetch_seq so only the latest in-flight result applies.
  defp async_lookup_agent(socket) do
    task_id = socket.assigns[:chat_task_id]
    node = socket.assigns[:current_node] || node()
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

  # Spawns a supervised history fetch for the chat agent. Bumps
  # :chat_fetch_seq (HistoryGate-style: only refetched when the agent's
  # message_count moved).
  defp async_fetch_history(socket) do
    agent_id = socket.assigns[:chat_agent_id]
    node = socket.assigns[:current_node] || node()
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
  # preserved/final result. Bumps :chat_task_fetch_seq (its own counter, so a
  # late history/lookup fetch can never invalidate the terminal result).
  defp async_fetch_task(socket) do
    task_id = socket.assigns[:chat_task_id]
    node = socket.assigns[:current_node] || node()
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
  # and task_id match already checked by the caller).
  defp handle_task_event(socket, task_id, status, node) do
    if NodeAware.event_from_current_node?(socket.assigns, node) and
         task_id == socket.assigns[:chat_task_id] do
      case status do
        :completed ->
          async_fetch_task(socket)

        :cancelled ->
          async_fetch_task(socket)

        :failed ->
          socket
          |> finalize_streaming(gettext("The task failed."))
          |> clear_task_refs()

        :running ->
          if socket.assigns[:chat_agent_id] == nil do
            async_lookup_agent(socket)
          else
            socket
          end

        _ ->
          socket
      end
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
    else
      socket
    end
  end

  # Finalizes the last streaming assistant bubble (or appends a new assistant
  # entry) with `text`.
  defp finalize_streaming(socket, text) do
    assign(socket, transcript: Transcript.finalize_assistant(socket.assigns[:transcript], text))
  end

  # Applies the fetched terminal task to the transcript, then clears the
  # task/agent refs so no further task/agent events can match (the transcript
  # stays visible; New chat is re-enabled).
  defp finalize_terminal(socket, task) do
    socket =
      if task == nil do
        socket
        |> finalize_streaming(gettext("The conversation was deleted."))
      else
        case Map.get(task, :status) do
          :completed -> finalize_completed(socket, Map.get(task, :result))
          :cancelled -> finalize_cancelled(socket, Map.get(task, :result))
          _ -> finalize_streaming(socket, gettext("The task failed."))
        end
      end

    clear_task_refs(socket)
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
  # can match) and re-enables input, keeping the transcript visible.
  defp clear_task_refs(socket) do
    assign(socket,
      chat_task_id: nil,
      chat_agent_id: nil,
      agent_message_count: nil,
      chat_status: :idle
    )
  end

  # Full chat reset (New chat / node switch): clears everything including the
  # transcript.
  defp reset_chat(socket) do
    assign(socket,
      transcript: Transcript.new(),
      chat_draft: "",
      chat_status: :idle,
      chat_task_id: nil,
      chat_agent_id: nil,
      agent_message_count: nil,
      chat_fetch_seq: 0,
      chat_task_fetch_seq: 0
    )
  end

  # Stale-guard for async chat fetches: the result applies only when the node
  # context is unchanged AND no newer fetch was spawned since.
  defp stale?(socket, node, seq) do
    node != socket.assigns[:current_node] or seq != socket.assigns[:chat_fetch_seq]
  end

  # Bubble wrapper alignment: user entries right-aligned, assistant/error left.
  defp bubble_wrapper_class(entry) do
    case entry.role do
      :user -> "flex justify-end"
      _ -> "flex justify-start"
    end
  end
end
