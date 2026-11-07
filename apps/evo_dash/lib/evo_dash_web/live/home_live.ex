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
  the LiveView process NEVER blocks on a store / cross-node call: every
  store/RPC call is either a guarded per-click mutation (`EvoDash.SafeCall.run/1`
  — send / stop) or a supervised task (`EvoDash.SafeCall.start/4` or
  `Task.Supervisor` + `EvoDash.SafeCall.run/1` inside the body — the remote
  model-profile load, approval responses, and every agent / history / task
  fetch) with a monotonic seq stale-guard. `EvoDash.SafeCall` is the exit-safe
  boundary (a `GenServer.call` timeout or an `:erpc` to an unreachable node
  EXITS the caller, which `rescue` cannot catch). Node-aware like every other
  page: `?node=` selects the viewed node.

  Chats survive remounts: the full chat state is persisted in-memory via
  `EvoDash.ChatHistory` (local-node only, see `home_live/CONTEXT.md`) and a
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
    ChatState,
    Messages,
    ModelSelect,
    SourceGate,
    Transcript
  }

  alias EvoDashWeb.LiveHooks.NodeAware
  alias EvoDashWeb.LLMSelection

  import EvoDashWeb.LLMSelectionComponents, only: [llm_selection: 1]

  import EvoDashWeb.HomeLive.ChatMessages
  import EvoDashWeb.HomeLive.ApprovalCard
  import EvoDashWeb.HomeLive.SourceGate

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
      <div class="flex h-full min-h-0 w-full min-w-0 max-w-3xl flex-col mx-auto">
        <!-- The header, answers and composer share one reading column. -->
        <div class="shrink-0 flex flex-wrap items-center gap-x-3 gap-y-2 border-b border-base-300 px-3 pt-3 pb-3 sm:px-4 sm:pt-4">
          <div class="min-w-0 basis-full sm:basis-auto sm:flex-1">
            <h1 class="text-base font-semibold truncate">
              <%!-- zh_CN: Genesis Assistant 是此对话助手的名称 --%>{gettext(
                "Genesis Assistant"
              )}
            </h1>
          </div>
          <form id="chat-llm-selection-form" class="basis-full order-last">
            <.llm_selection
              id="chat-llm-selection"
              provider_profiles={@provider_profiles}
              model_selections={@model_selections}
              model_spec={@model_spec || %{}}
              show_auto_option={@model_selection_enabled}
              disabled={@model_select_loading or is_nil(@model_snapshot)}
              compact
            />
          </form>
          <p
            :if={@model_select_load_error || @model_selection_error}
            role="alert"
            class="basis-full order-last text-xs text-error"
          >
            {gettext("Model selection is unavailable. Choose a valid model or reconnect to the node.")}
          </p>
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

        <!-- Composer: pinned bottom, outside the messages scroller -->
        <div class="shrink-0 px-3 pt-2 pb-3 sm:px-4 bg-base-100">
          <form
            id="chat-form"
            phx-submit="send_message"
            phx-change="chat_input"
            class="help-composer flex items-end gap-2 rounded-2xl p-1"
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
        # Evaluator and legacy command approvals both use this topic. Recovery
        # starts only after this subscription, chat restoration and node resolution.
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
      # The last approval scope reconciled on this connection. Recovery starts
      # after handle_params resolves the node, never against mount's local seed.
      # ApprovalWorkflow owns all ephemeral cards, response tokens and errors.
      approval_context: nil,
      provider_profiles: [],
      model_selections: [],
      model_spec: nil,
      model_selection_scope: nil,
      model_selection_error: nil,
      model_selection_restore: nil,
      model_selection_resolved: false,
      model_selection_enabled: false,
      # Config snapshots/bundles are server-only and never enter ChatState.
      model_snapshot: nil,
      model_selection_bundle: nil,
      model_select_loading: false,
      model_select_load_error: nil,
      # Monotonic stale-guard for the ASYNC remote model-profile load (a remote
      # node resolves its profiles via an `:erpc` config fetch, so the load is
      # NEVER run in the LiveView process — see assign_model_select/1). Monotonic
      # and never reset (a reset could make an older in-flight result apply).
      model_select_seq: 0,
      # Genesis-source gate (EPHEMERAL — never persisted to ChatState): the
      # /help chat needs the managed Genesis source checkout, which is usually
      # absent on a fresh install. `source_available` = the latest availability
      # result (`nil` unknown | `true` | `false` | `{:unavailable, reason}`) —
      # only a KNOWN `false` blocks sending; `source_check_loading` mirrors the
      # in-flight check window; `source_check_seq` is the monotonic stale-guard
      # counter (SEPARATE from chat_fetch_seq/chat_task_fetch_seq); `source_busy`
      # is a truthy marker while a download runs. Local-node only.
      source_available: nil,
      source_check_loading: false,
      source_check_seq: 0,
      source_busy: nil,
      current_path: ~p"/help"
    }
  end

  # Only the resolved node may supply a snapshot. Pending targets must never
  # read local config; every load invalidates earlier async results, including
  # a switch between two pending targets that share the local node fallback.
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
        case EvoDash.SafeCall.start(self(), {:model_select_loaded, seq, target_node}, fn ->
               ModelSelect.load(target_node)
             end) do
          {:ok, _pid} ->
            assign(socket, model_select_loading: true)

          {:error, reason} ->
            # No result message is sent when the supervisor cannot start the task.
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
    # Malformed persisted specs remain visibly invalid until the user chooses
    # again. Valid-but-stale choices are reconciled by the shared helper.
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
      |> persist_state()
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
         |> persist_state()}

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

  # Genesis-source availability check (LOCAL node only, connected socket only).
  # Bumps the monotonic `:source_check_seq` BEFORE spawning (captured into the
  # message, so only the latest in-flight result applies), flags the loading
  # window, and spawns the guarded runner on EvoDash.TaskSupervisor — the
  # LiveView never blocks on the filesystem probe. Returns the socket.
  #
  # `node()` cannot be called from a guard, so the local-node test reuses the
  # shared `SourceGate.visible?/1` predicate (`current_node in [nil, node()]`,
  # mirroring EvoDashWeb.SystemLive.SourceCard.visible?/1).
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

    # Node switch: the old chat's task belongs to the old node. Start a NEW
    # persisted chat (the old one stays in memory under ChatHistory; its
    # events are node-filtered anyway) and reset all live chat state.
    #
    # Two switch shapes:
    #   * mid-session switch — `prev_node` was already resolved and changed;
    #   * fresh load on a different node — the restored chat carries the node
    #     it was created on (`:chat_node`); a mismatch means the chat is stale
    #     for the viewed node.
    # The first handle_params resolves the mount seed, not a user switch.
    # Preserve a matching restored scope there; later target-id changes reset
    # even if both targets currently share the same fallback BEAM node.
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

    # Re-load the model profiles / selection-script state for the RESOLVED
    # node (a `?node=` switch may have landed on a different target).
    socket =
      socket
      |> assign_model_select()
      |> assign(current_path: ~p"/help")
      # Genesis-source availability for the resolved node context: fires on the
      # connected mount AND on every node-context change (this is the same place
      # the page reacts to `?node=` switches). Local-node only + connected-only
      # (a dead render must not spawn a task that sends into a dying process).
      |> maybe_check_source()
      # Subscriptions and restoration are complete, and the viewed node is
      # resolved. This also reconciles reconnects routed here by NodeAware.
      |> maybe_recover_approvals()

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
  def handle_event("select_provider_profile", %{"provider_profile_id" => id}, socket) do
    update_model_selection(socket, :select_provider, id)
  end

  @impl true
  def handle_event("select_model", %{"model" => model}, socket) do
    update_model_selection(socket, :select_model, model)
  end

  @impl true
  def handle_event("select_reasoning_effort", %{"reasoning_effort" => index}, socket) do
    update_model_selection(socket, :select_reasoning_effort, index)
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

  # Genesis-source gate: "Download source" on the gate banner. No-op while a
  # download is already in flight; otherwise mark `source_busy` and spawn the
  # clone on EvoDash.TaskSupervisor (the runner seam is resolved AT SPAWN TIME
  # inside SourceGate.spawn_clone/2). The result arrives as an async message —
  # see the {:source_clone_result, node, result} handle_info clause.
  @impl true
  def handle_event("download_source", _params, socket) do
    if socket.assigns[:source_busy] != nil do
      {:noreply, socket}
    else
      SourceGate.spawn_clone(self(), socket.assigns[:current_node] || node())
      {:noreply, assign(socket, source_busy: :clone)}
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
        #
        # Guarded per-click mutation: `EvoDash.SafeCall.run/1` converts a store
        # failure / cross-node `:erpc` exit (a call timeout to an unreachable
        # node EXITS the caller) into an error value, so a dead node flashes
        # instead of crashing the page.
        result =
          EvoDash.SafeCall.run(fn ->
            EvoDash.NodeContext.cancel_task(socket.assigns[:current_node] || node(), task_id)
          end)

        case result do
          {:ok, :ok} ->
            {:noreply,
             socket
             |> assign(chat_status: :cancelling, chat_task_status: :cancelling)
             |> persist_state()}

          {:ok, {:error, reason}} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Failed to stop: %{reason}", reason: inspect(reason))
             )}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Failed to stop: %{reason}", reason: inspect(reason))
             )}

          {:ok, _other} ->
            # Any other non-error return is still a successful cancel request.
            {:noreply,
             socket
             |> assign(chat_status: :cancelling, chat_task_status: :cancelling)
             |> persist_state()}
        end
    end
  end

  # Both evaluator and legacy command decisions use the same scoped async
  # workflow. Keep the card busy until success; failures retain it for retry.
  @impl true
  def handle_event(
        "approval_response",
        %{"request_id" => request_id, "decision" => decision},
        socket
      ) do
    {:noreply, ApprovalWorkflow.respond(socket, request_id, decision)}
  end

  @impl true
  def handle_event("retry_approvals", _params, socket) do
    {:noreply, recover_approvals(socket)}
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

      {:noreply, socket |> persist_state() |> async_fetch_history() |> maybe_recover_approvals()}
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

  # The workflow applies chat/source-node ownership and snapshot race guards
  # for evaluator requests and legacy command approvals alike.
  @impl true
  def handle_info({:approval_requested, request}, socket) do
    {:noreply, ApprovalWorkflow.requested(socket, request)}
  end

  @impl true
  def handle_info({:approval_resolved, request_id, _decision, source_node}, socket) do
    {:noreply, ApprovalWorkflow.resolved(socket, request_id, source_node)}
  end

  @impl true
  def handle_info({:approval_resolved, request_id, _decision}, socket) do
    {:noreply, ApprovalWorkflow.resolved(socket, request_id)}
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

        {:noreply,
         socket |> persist_state() |> async_fetch_history() |> maybe_recover_approvals()}
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

  # Genesis-source availability result (from SourceGate.spawn_availability_check/3).
  # Stale-guarded: applies only when no newer check was spawned (source_check_seq)
  # AND the node the check ran for is still the viewed node. `{:unavailable, _}`
  # is treated as "unknown" by the gate (never blocks). TOTAL — any result shape
  # is stored verbatim, so a stray message can never leak or crash the page.
  @impl true
  def handle_info({:source_availability_loaded, seq, node, result}, socket) do
    if seq == socket.assigns[:source_check_seq] and is_atom(node) and
         NodeAware.event_from_current_node?(socket.assigns, node) do
      {:noreply, assign(socket, source_available: result, source_check_loading: false)}
    else
      {:noreply, socket}
    end
  end

  # Genesis-source download result (from SourceGate.spawn_clone/2). Node-filtered
  # and TOTAL: `{:ok, _}` clears the busy marker + re-runs the availability check
  # (the gate clears on success); `{:error, reason}` clears it + surfaces the
  # failure; `{:unavailable, _}` clears it and resets the gate to "unknown" with
  # NO error flash (a backend the user cannot act on); any other shape is a
  # quiet no-op that still clears the busy marker.
  @impl true
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

  # SafeCall preserves tuple tags as ONE nested element. The workflow rejects
  # stale scopes/tokens and keeps cards on recovery or response failures.
  @impl true
  def handle_info({{:approval_pending_loaded, _seq, _scope} = tag, result}, socket) do
    {:noreply, ApprovalWorkflow.recovered(socket, tag, result)}
  end

  @impl true
  def handle_info({{:approval_workflow_response, _seq, _scope, _id} = tag, result}, socket) do
    {:noreply, ApprovalWorkflow.responded(socket, tag, result)}
  end

  # SafeCall keeps the ModelSelect result nested inside its own tagged result.
  # Sequence equality also rejects a stale result for a different target id
  # whose resolved BEAM node happens to be the same.
  @impl true
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
  #
  # Genesis-source gate: when the GENESIS source is known to be missing on a
  # LOCAL node, a send would only start a doomed `:reflect` task — block it
  # (no optimistic bubbles, no start_task, no seq bump) and point the user at
  # the Download button. Only a KNOWN `false` blocks (see
  # SourceGate.blocked?/1); the textarea/Send button are disabled in the same
  # state, so this is the defensive backstop for the Enter-key path.
  defp send_chat(socket, text) do
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
        do_send_chat(socket, text)
    end
  end

  defp do_send_chat(socket, text) do
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

        # Validate before touching the transcript/draft. A missing, stale or
        # wrong-node snapshot must not create a bubble or silently submit Auto.
        case ModelSelect.task_opts(
               socket.assigns.model_snapshot,
               socket.assigns,
               selection_scope(socket),
               mode: "reflect",
               objective: objective
             ) do
          {:ok, task_opts} ->
            start_chat(socket, text, task_opts)

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, gettext("Choose a valid model before sending a message."))}
        end
      end
    end
  end

  defp start_chat(socket, text, task_opts) do
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

    # Guarded per-click mutation on the viewed node. Options were validated
    # against its ephemeral snapshot before the optimistic transcript update.
    # No :path or legacy :model_id is submitted.
    # `EvoDash.SafeCall.run/1` normalizes the store/RPC outcome: an
    # unreachable remote node EXITS its caller (an `:erpc` failure a rescue
    # cannot catch), so it becomes `{:error, reason}` and lands on the
    # "Failed to start the task" bubble instead of crashing the page.
    result =
      case EvoDash.SafeCall.run(fn ->
             EvoDash.NodeContext.start_task(
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
              |> persist_state()
              |> async_lookup_agent()
              |> maybe_recover_approvals()

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

  # Spawns a supervised lookup of the reflect task's root agent. `node_override`
  # targets a specific node (mount reconciliation uses the chat's OWN
  # `:chat_node`); the default is the viewed node. Bumps :chat_fetch_seq so
  # only the latest in-flight result applies.
  #
  # The RPC runs through `EvoDash.SafeCall.run/2` INSIDE the task: an `:erpc`
  # to a remote node EXITS the caller (a rescue cannot catch an exit), and a
  # dying child would never send its result message — the lookup would be lost.
  # Normalized to `[]` on any error, so the caller simply waits for the
  # agent_registered / agents_updated retrigger.
  defp async_lookup_agent(socket, node_override \\ nil) do
    task_id = socket.assigns[:chat_task_id]
    node = node_override || socket.assigns[:current_node] || node()
    seq = socket.assigns[:chat_fetch_seq] + 1
    pid = self()

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      agents = EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.list_agents(node) end, [])
      agent = AgentStream.find_root_agent(agents, task_id)
      send(pid, {:chat_agent_lookup, node, seq, task_id, agent})
    end)

    assign(socket, chat_fetch_seq: seq)
  end

  # Spawns a supervised history fetch for the chat agent. `node_override`
  # targets a specific node (see async_lookup_agent/2). Bumps :chat_fetch_seq
  # (HistoryGate-style: only refetched when the agent's message_count moved).
  # Same guarded-task contract: any call failure degrades to `[]` (the
  # handler's unchanged branch) and the result message is always sent.
  defp async_fetch_history(socket, node_override \\ nil) do
    agent_id = socket.assigns[:chat_agent_id]
    node = node_override || socket.assigns[:current_node] || node()
    seq = socket.assigns[:chat_fetch_seq] + 1
    pid = self()

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result =
        EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.get_agent_history(node, agent_id) end, [])

      send(pid, {:chat_history_loaded, node, seq, agent_id, result})
    end)

    assign(socket, chat_fetch_seq: seq)
  end

  # Spawns a supervised task fetch used to finalize the transcript with the
  # preserved/final result (also the ONE-SHOT mount reconciliation fetch).
  # Bumps :chat_task_fetch_seq (its own counter, so a late history/lookup
  # fetch can never invalidate the terminal result). Uses the lite read (no
  # archive blob — the terminal path reads only status/result/error). A
  # failed/timed-out fetch degrades to `nil`, which finalize_terminal/2 treats
  # as deleted.
  defp async_fetch_task(socket, node_override \\ nil) do
    task_id = socket.assigns[:chat_task_id]
    node = node_override || socket.assigns[:current_node] || node()
    seq = socket.assigns[:chat_task_fetch_seq] + 1
    pid = self()

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      task = EvoDash.SafeCall.run(fn -> EvoDash.NodeContext.get_task_lite(node, task_id) end, nil)

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
                :failed -> finalize_failed(socket, Map.get(task, :error))
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

  # Finalizes a :failed task (the fetched-task terminal path). When the decoded
  # TaskInfo carries a structured error payload, its `error.message` (e.g.
  # "Task force-killed by user") is the explanation shown to the user; a nil /
  # non-map / blank error falls back to the generic failure placeholder.
  # Total: AgentStream.extract_failed_message/1 never raises on malformed data.
  defp finalize_failed(socket, error) do
    case AgentStream.extract_failed_message(error) do
      nil -> finalize_streaming(socket, gettext("The task failed."))
      message -> finalize_streaming(socket, message)
    end
  end

  # Terminal state: drops the task/agent refs (no further task/agent events
  # can match) and re-enables input, keeping the transcript AND the final
  # `:chat_task_status` badge (and thought process) visible on the card.
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

  # Full live-chat reset (New chat / node switch): clears everything including
  # the transcript. The persisted chat (if any) is untouched —
  # `start_new_chat/1` owns creating + persisting the fresh empty chat.
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
      # Selection survives New chat only within its resolved target scope;
      # handle_params clears cross-node/target selections before this reset.
      # Per-entry raw-view flags are cleared with their transcript entries.
      raw_entry_ids: MapSet.new(),
      approval_context: nil
    )
    |> ApprovalWorkflow.init()
  end

  # Compare only chat/node refs, not draft/history changes. A fresh connected
  # mount reconciles once after restoration and node resolution; root lookup,
  # task start and reconnect/node changes reconcile only when their scope moves.
  # The workflow performs the usable-ref and pending-remote checks itself.
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

      saved_state = EvoDash.ChatHistory.get_state(chat_id)

      socket =
        socket
        |> assign(chat_id: chat_id, model_selection_restore: saved_state || %{})
        |> assign(ChatState.restore(saved_state))

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
