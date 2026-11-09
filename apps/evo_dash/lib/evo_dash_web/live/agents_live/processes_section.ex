defmodule EvoDashWeb.AgentsLive.ProcessesSection do
  @moduledoc """
  The **Processes** section of the `/agents` page's selected-agent detail panel:
  a compact, READ-ONLY view of the managed OS executions (agent tool calls and
  background jobs) that `EvoGit.ProcessManager` tracks for ONE agent.

  This module owns the section's asynchronous state machine so the LiveView
  handlers stay one-liners:

    * `start/2` bumps a monotonic `:processes_seq`, puts the section into its
      loading state and runs the fetch in an `EvoDash.TaskSupervisor` child via
      `EvoDash.SafeCall.start/4` — the LiveView never blocks on the (possibly
      cross-node) `:erpc` read. The guarded call ALWAYS replies, so the loading
      flag can never stick.
    * `handle_result/5` applies the reply only when it is still current
      (seq + viewed node + selected agent); older in-flight replies are dropped.
    * `process_event/2` is the whole reaction to a `"processes"` PubSub event:
      foreign-node events and a cleared selection are ignored, otherwise the
      selected agent's section is refetched asynchronously (no polling).
    * `clear/1` resets the section (agent deselected / node switched).

  The runner seam is `Application.get_env(:evo_dash, :agents_processes_runner, &load/2)`
  — a 2-arity `(node, agent_id)` function resolved at spawn time, so tests can
  inject a fake. `section/1` is a pure render of that state and never loads
  anything itself.
  """

  use EvoDashWeb, :html

  alias EvoDash.SafeCall
  alias EvoDashWeb.LiveHooks.NodeAware
  alias EvoDashWeb.ProcessComponents
  alias EvoDashWeb.ProcessesLive.Format

  @empty %{agent_id: nil, executions: nil, loading: false, error: nil}

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------

  @doc """
  The cleared section state (no agent, nothing loaded, not loading, no error).

  Seeded in `AgentsLive.mount/3` and assigned by `clear/1`.
  """
  def empty_state, do: @empty

  @doc """
  Production fetch: the agent's tracked executions on `node`, scoped by id.

  `EvoDash.NodeContext.list_processes/2` is total (`[]` when the node or the
  process manager is unreachable), so a broken remote read degrades to an empty
  list instead of a crash.
  """
  def load(node, agent_id), do: EvoDash.NodeContext.list_processes(node, agent_id: agent_id)

  @doc """
  Starts an ASYNC fetch of `agent_id`'s processes and puts the section in its
  loading state. Returns the socket.

  The result arrives as `{{:agent_processes_loaded, seq, node, agent_id}, result}`
  (`SafeCall.start/4` sends its tag VERBATIM, so the multi-element tag stays ONE
  nested tuple) and is applied by `handle_result/5`. If the supervisor refuses
  to start the child, no reply can ever arrive, so the section settles on an
  error state here instead of spinning forever.
  """
  def start(socket, agent_id) do
    seq = (socket.assigns[:processes_seq] || 0) + 1
    node = socket.assigns.current_node
    runner = processes_runner()

    socket =
      assign(socket,
        processes_seq: seq,
        agent_processes: %{agent_id: agent_id, executions: nil, loading: true, error: nil}
      )

    case SafeCall.start(self(), {:agent_processes_loaded, seq, node, agent_id}, fn ->
           runner.(node, agent_id)
         end) do
      {:ok, _pid} ->
        socket

      {:error, reason} ->
        assign(socket, :agent_processes, %{
          agent_id: agent_id,
          executions: nil,
          loading: false,
          error: Format.term_text(reason)
        })
    end
  end

  @doc "Clears the section (no agent selected, or the viewed node changed)."
  def clear(socket), do: assign(socket, :agent_processes, @empty)

  @doc """
  Applies an async fetch result. Dropped unless the result is still current:
  same monotonic seq, same viewed node, and the same agent the section is
  currently showing.
  """
  def handle_result(socket, seq, node, agent_id, result) do
    state = Map.get(socket.assigns, :agent_processes) || @empty

    stale? =
      seq != Map.get(socket.assigns, :processes_seq) or
        node != Map.get(socket.assigns, :current_node) or
        agent_id != Map.get(state, :agent_id)

    if stale? do
      socket
    else
      case normalize_result(result) do
        {:ok, executions} ->
          assign(socket, :agent_processes, %{
            agent_id: agent_id,
            executions: executions,
            loading: false,
            error: nil
          })

        {:error, reason} ->
          assign(socket, :agent_processes, %{
            agent_id: agent_id,
            executions: nil,
            loading: false,
            error: Format.term_text(reason)
          })
      end
    end
  end

  @doc """
  Reacts to ONE `"processes"` PubSub event: foreign-node events and a cleared
  selection are ignored; otherwise the selected agent's section is refetched
  asynchronously (seq-guarded, never a poll). The event payload is intentionally
  not inspected — every managed-process event is cheap and the refetch is
  idempotent, so a malformed payload can never crash the page.
  """
  def process_event(socket, node) do
    selected = Map.get(socket.assigns, :selected_agent_id)

    cond do
      not is_atom(node) -> socket
      is_nil(selected) -> socket
      not NodeAware.event_from_current_node?(socket.assigns, node) -> socket
      true -> start(socket, selected)
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  attr(:agent_processes, :map, required: true)
  attr(:current_node_id, :string, default: nil)
  attr(:selected_agent_id, :any, default: nil)

  @doc """
  The compact Processes block: heading + count badge, loading state, error
  line, the executions (via `ProcessComponents.compact_rows/1`), a readable
  empty state, and a node-aware "View in Processes" link.
  """
  def section(assigns) do
    state = assigns.agent_processes || @empty
    raw_executions = Map.get(state, :executions)
    executions = if is_list(raw_executions), do: Enum.filter(raw_executions, &is_map/1), else: []

    # A plain function component receives a BARE assigns map (no `__changed__`
    # tracking), so `Phoenix.Component.assign/3` would raise here — plain
    # `Map.put/3` derives the local render values instead.
    assigns =
      assigns
      |> Map.put(:agent_id, Map.get(state, :agent_id) || Map.get(assigns, :selected_agent_id))
      |> Map.put(:executions, executions)
      |> Map.put(:count, length(executions))
      |> Map.put(:loaded, not is_nil(raw_executions))
      |> Map.put(:loading, Map.get(state, :loading) == true)
      |> Map.put(:error, Map.get(state, :error))

    ~H"""
    <div id="agent-processes-section" class="agent-detail-processes mt-6">
      <div class="flex items-center justify-between gap-2 mb-2">
        <h4 class="flex items-center gap-2 text-xs font-semibold uppercase text-base-content/70">
          <% # zh_CN: 该代理正在执行的受管 OS 进程（工具调用 / 后台任务），非应用内进程 %>
          {gettext("Processes")}
          <span
            :if={@loaded}
            class="badge badge-sm border-base-300 bg-base-200/50 text-base-content/70"
          >
            {@count}
          </span>
        </h4>
        <a
          :if={@agent_id}
          href={processes_link(@agent_id, @current_node_id)}
          class="inline-flex items-center gap-1 text-xs text-primary-standalone hover:underline"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
          {gettext("View in Processes")}
        </a>
      </div>

      <p :if={@loading} class="flex items-center gap-2 text-xs text-base-content/60">
        <span class="loading loading-spinner loading-xs"></span>
        {gettext("Loading processes…")}
      </p>

      <p
        :if={@error}
        class="rounded border border-error/30 bg-error/5 px-2 py-1 text-xs text-error break-words"
      >
        {gettext("Failed to load processes: %{reason}", reason: @error)}
      </p>

      <ProcessComponents.compact_rows
        :if={not @loading and @executions != []}
        executions={@executions}
      />

      <p
        :if={not @loading and is_nil(@error) and @executions == []}
        class="text-xs text-base-content/60"
      >
        {gettext("No processes for this agent.")}
      </p>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp processes_runner do
    Application.get_env(:evo_dash, :agents_processes_runner, &load/2)
  end

  # The guarded call's value is whatever the runner returned; the default
  # runner answers a bare list. A bare list is therefore accepted as a success
  # (the already-unwrapped legacy shape), everything else is an error.
  defp normalize_result(executions) when is_list(executions), do: {:ok, executions}
  defp normalize_result({:ok, executions}) when is_list(executions), do: {:ok, executions}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(other), do: {:error, {:unexpected_processes_result, other}}

  # ⚠️ `EvoDashWeb.Helpers.with_node_param/2` appends with "?" — wrong for a URL
  # that already carries a query string, so the node param is appended manually
  # with "&" (the documented gotcha).
  defp processes_link(agent_id, node_id) do
    base = ~p"/processes" <> "?agent_id=#{agent_id}"

    case node_id do
      nil -> base
      "" -> base
      node_id -> base <> "&node=" <> URI.encode_www_form(to_string(node_id))
    end
  end
end
