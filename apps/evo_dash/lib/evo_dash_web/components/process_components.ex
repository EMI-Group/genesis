defmodule EvoDashWeb.ProcessComponents do
  @moduledoc """
  Reusable rendering for the managed-process platform — the status badge, the
  executions table row (plus its expansion detail row), the action buttons,
  the compact rows embedded in the `/agents` detail panel, and the reasoned
  confirmation modal for destructive control actions.

  Every function here is PURE and TOTAL: no data loading, no socket/assigns
  mutation, no I/O. An execution arrives EITHER as the core's own
  `%EvoGit.ProcessManager.Execution{}` struct OR as a plain atom-keyed map
  (PubSub payloads, tests), so its fields are read with `Map.get/2` — structs do
  NOT implement Access, and `record[:key]` raises on them. Formatting goes
  through `EvoDashWeb.ProcessesLive.Format`, which tolerates atom- OR
  string-keyed maps and never raises, so a malformed event payload renders a
  placeholder instead of breaking a render.

  The page owns state (`expanded`, the pending confirmation, the reason text);
  these components only render it and emit the event names passed in as attrs,
  so the same row markup serves the Processes page and (in its compact form)
  the agents panel.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.ProcessesLive.Format

  @doc """
  Status badge of an execution, following the dashboard's locked status scheme
  (busy = amber family, good = success, bad = error, paused = info,
  neutral = gray).
  """
  attr(:status, :atom, default: nil)
  attr(:class, :string, default: nil)

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm gap-1.5 border whitespace-nowrap",
      Format.status_badge_class(@status),
      @class
    ]}>
      <span class={["inline-block size-1.5 rounded-full shrink-0", Format.status_dot_class(@status)]}></span>
      {status_text(@status)}
    </span>
    """
  end

  @doc """
  ONE execution as two table rows: the clickable summary row plus, when
  `expanded`, a full-width detail row (full command, cwd, repo root, reason and
  the whole control log).

  `node_id` makes the Agent/Task cells node-aware links; the action event names
  are attrs so the page keeps ownership of its handlers.
  """
  attr(:execution, :map, required: true)
  attr(:expanded, :boolean, default: false)

  attr(:entering, :boolean,
    default: false,
    doc: "adds the `process-row-enter` class (rows that just joined the top of the table)"
  )

  attr(:node_id, :string, default: nil)
  attr(:row_event, :string, default: "toggle_process_row")
  attr(:pause_event, :string, default: "pause_process")
  attr(:resume_event, :string, default: "resume_process")
  attr(:terminate_event, :string, default: "open_terminate")
  attr(:kill_event, :string, default: "open_kill")

  attr(:agents_path, :string, default: nil, doc: "overrides the node-aware /agents link")
  attr(:tasks_path, :string, default: nil, doc: "overrides the node-aware /tasks link")

  def execution_row(assigns) do
    execution = assigns.execution
    status = field(execution, :status)
    command = Format.command_text(execution)
    tool = Format.tool_name(execution)
    id = field(execution, :id)

    assigns =
      assigns
      |> assign(:id, id)
      |> assign(:status, status)
      |> assign(:command, command)
      |> assign(:tool, tool)
      |> assign(:agent_id, field(execution, :agent_id))
      |> assign(:task_id, field(execution, :task_id))
      |> assign(:runtime, runtime_text(field(execution, :runtime)))
      |> assign(:backend, backend_text(field(execution, :backend)))
      |> assign(:live?, Format.live?(status) and is_binary(id))
      |> assign(:paused?, status == :paused)
      |> assign(:running?, status == :running)
      |> assign(
        :agents_link,
        assigns.agents_path || with_node_param(~p"/agents", assigns.node_id)
      )
      |> assign(:tasks_link, assigns.tasks_path || with_node_param(~p"/tasks", assigns.node_id))
      |> assign(:row_attrs, [
        {"phx-click", assigns.row_event},
        {"phx-value-id", id || ""}
      ])

    ~H"""
    <tr
      id={"process-row-#{@id || "unknown"}"}
      class={[
        "border-b border-base-300/60 align-top hover:bg-base-200/50",
        @entering && "process-row-enter"
      ]}
    >
      <td class="py-2 pl-2 pr-2" {@row_attrs}>
        <div class="flex items-center gap-1">
          <span class="inline-flex w-3.5 shrink-0 text-base-content/40" aria-hidden="true">
            <.icon
              name={if @expanded, do: "hero-chevron-down", else: "hero-chevron-right"}
              class="size-3.5"
            />
          </span>
          {status_badge(%{status: @status})}
        </div>
      </td>
      <td class="py-2 pr-2 whitespace-nowrap">
        <%= if present?(@agent_id) do %>
          <.link navigate={@agents_link} class="link link-hover text-xs font-mono">
            #{Format.id_string(@agent_id)}
          </.link>
        <% else %>
          <span class="text-xs text-base-content/50">—</span>
        <% end %>
      </td>
      <td class="py-2 pr-2 whitespace-nowrap">
        <%= if present?(@task_id) do %>
          <.link navigate={@tasks_link} class="link link-hover text-xs font-mono">
            #{Format.id_string(@task_id)}
          </.link>
        <% else %>
          <span class="text-xs text-base-content/50">—</span>
        <% end %>
      </td>
      <td class="py-2 pr-2 max-w-[22rem]" {@row_attrs}>
        <div class="flex flex-col gap-0.5 min-w-0">
          <%= if @tool do %>
            <span class="badge badge-ghost badge-xs w-fit font-mono">{@tool}</span>
          <% end %>
          <code class="text-xs block truncate" title={@command}>
            {truncate_string(@command, 90)}
          </code>
        </div>
      </td>
      <td class="py-2 pr-2 text-xs whitespace-nowrap" {@row_attrs}>
        {@runtime}
      </td>
      <td class="py-2 pr-2 text-xs whitespace-nowrap" {@row_attrs}>
        {@backend}
      </td>
      <td
        class="py-2 pr-2 text-xs font-mono whitespace-nowrap"
        title={Format.target_label(@execution)}
        {@row_attrs}
      >
        {Format.target_label(@execution)}
      </td>
      <td class="py-2 pr-2 text-xs whitespace-nowrap" {@row_attrs}>{Format.uptime(@execution)}</td>
      <td class="py-2 pr-2 text-xs text-right whitespace-nowrap" {@row_attrs}>
        {Format.cpu_label(@execution)}
      </td>
      <td class="py-2 pr-2 text-xs text-right whitespace-nowrap" {@row_attrs}>
        {Format.memory_label(@execution)}
      </td>
      <td class="py-2 pr-2 text-xs text-right whitespace-nowrap" {@row_attrs}>
        {Format.exit_label(@execution)}
      </td>
      <td class="py-2 pl-2 pr-2">
        <%!--
          The summary cells toggle expansion; the action cluster deliberately has
          no row handler, so a Pause/Terminate click can never also toggle the row.
          Terminate = send TERM and ask the process to exit gracefully;
          Kill = force-terminate (TERM, then SIGKILL after a grace period).
          A built-in (in-BEAM) execution has NO OS process, so it renders no
          action cluster at all — there is nothing to signal.
          zh_CN: Terminate = 发送 TERM 信号请求进程正常退出（可被进程捕获并清理）；
          Kill = 立即强制终止（TERM 后在宽限期内升级为 KILL），未保存的工作会丢失。
        --%>
        <div :if={Format.external?(@execution)} class="flex items-center justify-end gap-0.5">
          <button
            :if={@running? and @live?}
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            title={gettext("Pause (SIGSTOP)")}
            aria-label={gettext("Pause")}
            phx-click={@pause_event}
            phx-value-id={@id}
          >
            <.icon name="hero-pause" class="size-3.5" />
          </button>
          <button
            :if={@paused? and @live?}
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            title={gettext("Resume (SIGCONT)")}
            aria-label={gettext("Resume")}
            phx-click={@resume_event}
            phx-value-id={@id}
          >
            <.icon name="hero-play" class="size-3.5" />
          </button>
          <button
            :if={@live?}
            type="button"
            class="btn btn-ghost btn-xs btn-square text-warning"
            title={gettext("Terminate — asks the process to exit gracefully (TERM)")}
            aria-label={gettext("Terminate")}
            phx-click={@terminate_event}
            phx-value-id={@id}
          >
            <.icon name="hero-x-circle" class="size-3.5" />
          </button>
          <button
            :if={@live?}
            type="button"
            class="btn btn-ghost btn-xs btn-square text-error"
            title={gettext("Kill — force-terminates the process (TERM, then KILL)")}
            aria-label={gettext("Kill")}
            phx-click={@kill_event}
            phx-value-id={@id}
          >
            <.icon name="hero-trash" class="size-3.5" />
          </button>
        </div>
      </td>
    </tr>
    <tr :if={@expanded} class="border-b border-base-300/60 bg-base-200/30">
      <td colspan="12" class="px-4 py-3">
        <%!-- Must go through the component call syntax: `execution_details/1`
        runs `assign/3`, which needs Phoenix's assigns change-tracking wrapper
        (a hand-built `%{execution: ...}` map raises on expansion). --%>
        <.execution_details execution={@execution} />
      </td>
    </tr>
    """
  end

  @doc """
  The expanded detail block of one execution: identity/OS context, the FULL
  command, and the operator control log.
  """
  attr(:execution, :map, required: true)

  def execution_details(assigns) do
    execution = assigns.execution

    assigns =
      assigns
      |> assign(:log, Format.control_log(execution))
      |> assign(:command, Format.command_text(execution))
      |> assign(:cwd, field(execution, :cwd))
      |> assign(:repo_root, field(execution, :repo_root))
      |> assign(:runtime, runtime_text(field(execution, :runtime)))
      |> assign(:backend, backend_text(field(execution, :backend)))
      |> assign(:exit_code, Format.exit_code_label(execution))
      |> assign(:target, Format.target_label(execution))
      |> assign(:reason, reason_text(field(execution, :reason)))
      |> assign(:started_at, format_time(field(execution, :started_at)))
      |> assign(:ended_at, format_time(field(execution, :ended_at)))

    ~H"""
    <div class="grid gap-3 md:grid-cols-2">
      <div class="space-y-2 min-w-0">
        <div>
          <h5 class="text-xs font-semibold uppercase text-base-content/70 mb-0.5">
            {gettext("Full Command")}
          </h5>
          <pre class="text-xs bg-base-100 border border-base-300 rounded p-2 overflow-x-auto whitespace-pre-wrap break-all"><%= @command %></pre>
        </div>
        <div class="grid grid-cols-1 gap-1.5">
          <.detail_field label={gettext("Working Directory")} value={@cwd} mono />
          <.detail_field label={gettext("Repository Root")} value={@repo_root} mono />
          <.detail_field label={gettext("Target")} value={@target} mono />
          <.detail_field label={gettext("Exit Code")} value={@exit_code} />
          <.detail_field label={gettext("Reason")} value={@reason} />
          <.detail_field label={gettext("Runtime")} value={@runtime} />
          <.detail_field label={gettext("Backend")} value={@backend} />
          <.detail_field label={gettext("Started")} value={@started_at} />
          <.detail_field label={gettext("Ended")} value={@ended_at} />
        </div>
      </div>
      <div class="min-w-0">
        <h5 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
          {gettext("Control Log")}
        </h5>
        <%= if @log == [] do %>
          <p class="text-xs text-base-content/60 italic">{gettext("No control actions recorded.")}</p>
        <% else %>
          <div class="overflow-x-auto border border-base-300 rounded bg-base-100">
            <table class="table table-xs">
              <thead>
                <tr class="text-base-content/60">
                  <th>{gettext("Time")}</th>
                  <th>{gettext("Action")}</th>
                  <th>{gettext("Signal")}</th>
                  <th>{gettext("Reason")}</th>
                  <th>{gettext("Actor")}</th>
                </tr>
              </thead>
              <tbody>
                <%= for entry <- @log do %>
                  <tr>
                    <td class="whitespace-nowrap font-mono">{Format.entry_time(entry)}</td>
                    <td class="whitespace-nowrap">
                      {Format.action_label(Format.entry_action(entry))}
                    </td>
                    <td class="whitespace-nowrap font-mono">{Format.signal_label(entry)}</td>
                    <td class="break-words">{Format.entry_reason(entry)}</td>
                    <td class="whitespace-nowrap">
                      {Format.actor_label(Format.entry_get(entry, :actor))}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:mono, :boolean, default: false)

  defp detail_field(assigns) do
    ~H"""
    <div class="min-w-0">
      <span class="text-xs text-base-content/60">{@label}: </span>
      <span class={["text-xs break-all", @mono && "font-mono"]}>{blank_text(@value)}</span>
    </div>
    """
  end

  @doc """
  Compact execution rows for an embedded panel (the `/agents` agent detail
  panel): status, tool/command, OS target and memory. Total over the list.
  """
  attr(:executions, :list, required: true)

  def compact_rows(assigns) do
    rows =
      assigns.executions
      |> List.wrap()
      |> Enum.map(&compact_row/1)

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <div class="space-y-1">
      <%= for row <- @rows do %>
        <div
          id={"agent-process-#{row.id || "unknown"}"}
          class="flex items-center gap-2 rounded border border-base-300/60 bg-base-200/30 px-2 py-1"
        >
          {status_badge(%{status: row.status, class: "badge-xs"})}
          <code class="text-xs truncate flex-1 min-w-0" title={row.command}>
            {truncate_string(row.command, 60)}
          </code>
          <span class="text-xs font-mono text-base-content/70 whitespace-nowrap">
            {row.target}
          </span>
          <span class="text-xs text-base-content/70 whitespace-nowrap">
            {row.memory}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  # One compact row's render-bound values, computed once from the record (a
  # struct or a plain atom-keyed map).
  defp compact_row(execution) do
    %{
      id: field(execution, :id),
      status: field(execution, :status),
      command: Format.command_text(execution),
      target: Format.target_label(execution),
      memory: Format.memory_label(execution)
    }
  end

  @doc """
  Reasoned confirmation modal for a destructive control action.

  `confirm` is `%{id:, action: :terminate | :kill, execution: map}`. The reason
  input is REQUIRED by the page (a blank reason performs no control call);
  `error` renders the page's validation message and `reason` preserves the
  operator's text across the failed submit.
  """
  attr(:confirm, :map, required: true)
  attr(:reason, :string, default: "")
  attr(:error, :string, default: nil)
  attr(:close_event, :string, default: "close_confirm")
  attr(:submit_event, :string, default: "confirm_control")

  def confirm_modal(assigns) do
    action = Map.get(assigns.confirm, :action)
    execution = Map.get(assigns.confirm, :execution) || %{}

    assigns =
      assigns
      |> assign(:action, action)
      |> assign(:command, Format.command_text(execution))
      |> assign(:target, Format.target_label(execution))
      |> assign(:title, confirm_title(action))
      |> assign(:description, confirm_description(action))
      |> assign(:submit_label, confirm_submit_label(action))

    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center p-4" id="process-confirm-modal">
      <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click={@close_event}></div>
      <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-300 max-w-lg w-full p-6">
        <div class="flex items-center gap-3 mb-3">
          <.icon
            name={if @action == :kill, do: "hero-exclamation-triangle", else: "hero-x-circle"}
            class={"size-5 #{if @action == :kill, do: "text-error", else: "text-warning"}"}
          />
          <h3 class="text-lg font-bold">{@title}</h3>
        </div>
        <p class="text-sm text-base-content/70 mb-3 leading-relaxed">{@description}</p>
        <div class="rounded border border-base-300 bg-base-200/40 p-2 mb-3">
          <div class="text-xs text-base-content/60">{gettext("Target")}</div>
          <code class="text-xs font-mono block break-all" title={@command}>{@command}</code>
          <div class="mt-1 flex items-center gap-3 text-xs text-base-content/60">
            <span class="font-mono">{@target}</span>
            <span>{gettext("Actor")}: {Format.actor_label(:remote)}</span>
          </div>
        </div>
        <form phx-submit={@submit_event} id="process-confirm-form">
          <label class="text-xs font-semibold uppercase text-base-content/70" for="process-reason">
            {gettext("Reason (required)")}
          </label>
          <textarea
            id="process-reason"
            name="reason"
            rows="2"
            class="textarea textarea-bordered w-full rounded-md mt-1 text-sm"
            placeholder={gettext("Why are you doing this? It is recorded in the control log.")}
          >{@reason}</textarea>
          <p :if={@error} class="text-xs text-error mt-1">{@error}</p>
          <div class="flex justify-end gap-2 pt-4">
            <button type="button" class="btn btn-ghost btn-sm rounded-md" phx-click={@close_event}>
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class={"btn btn-sm rounded-md gap-2 #{if @action == :kill, do: "btn-error", else: "btn-warning"}"}
            >
              <.icon name="hero-x-circle" class="size-4" />
              {@submit_label}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp confirm_title(:kill), do: gettext("Kill process?")
  defp confirm_title(_action), do: gettext("Terminate process?")

  defp confirm_description(:kill) do
    gettext(
      "Immediately kills the process: a TERM signal is sent, then SIGKILL after a short grace period. Unsaved work is lost."
    )
  end

  defp confirm_description(_action) do
    gettext(
      "Sends a TERM signal asking the process to exit gracefully. A process may ignore it, and work in flight may be interrupted."
    )
  end

  defp confirm_submit_label(:kill), do: gettext("Kill")
  defp confirm_submit_label(_action), do: gettext("Terminate")

  defp status_text(:starting), do: gettext("Starting")
  defp status_text(:running), do: gettext("Running")
  defp status_text(:paused), do: gettext("Paused")
  defp status_text(:completed), do: gettext("Completed")
  defp status_text(:failed), do: gettext("Failed")
  defp status_text(:killed), do: gettext("Killed")
  defp status_text(_status), do: gettext("Unknown")

  # Translatable labels live in the render layer: `Format` stays gettext-free
  # (it is pure and also feeds a gettext-less path), so the English literals it
  # returns are wrapped/overridden here.
  defp runtime_text(:foreground), do: gettext("Foreground")
  defp runtime_text(:background), do: gettext("Background")
  defp runtime_text(other), do: Format.runtime_label(other)

  # zh_CN: `:builtin` 表示内置工具在 BEAM 内部执行，没有操作系统进程。
  # Backend product names (`systemd`/`bwrap`/`sandbox-exec`) are technical
  # identifiers and must NOT be translated — only the built-in case is.
  defp backend_text(:builtin), do: gettext("In-process (built-in)")
  defp backend_text(other), do: Format.backend_label(other)

  # Mirrors `Format.reason_text/1`, but translatable.
  defp reason_text(:exited), do: gettext("Exited")
  defp reason_text(:timeout), do: gettext("Timeout")
  defp reason_text(:invalid_arguments), do: gettext("Invalid arguments")
  # zh_CN: 发起该调用的 agent 进程已退出，执行因此被终止。
  defp reason_text(:owner_died), do: gettext("Owner died")
  # zh_CN: 该执行没有操作系统进程句柄，因此无法发送信号。
  defp reason_text(:no_os_process), do: gettext("No OS process")

  # zh_CN: 由哪个 agent / 操作者终止。
  defp reason_text({:killed_by, actor}),
    do: gettext("Killed by %{actor}", actor: Format.term_text(actor))

  defp reason_text({:crashed, detail}),
    do: gettext("Crashed: %{detail}", detail: Format.term_text(detail))

  defp reason_text(other), do: Format.reason_text(other)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  # Process records reach these components BOTH ways: a
  # `%EvoGit.ProcessManager.Execution{}` struct (the registry's own records,
  # which do NOT implement Access) and a plain atom-keyed map (PubSub payloads,
  # tests). `Map.get/2` reads both; dot-access and `record[key]` do not. Total:
  # a non-map yields nil, so a malformed payload renders a placeholder.
  defp field(record, key) when is_map(record), do: Map.get(record, key)
  defp field(_record, _key), do: nil

  defp blank_text(nil), do: "—"

  defp blank_text(value) when is_binary(value),
    do: if(String.trim(value) == "", do: "—", else: value)

  defp blank_text(value), do: Format.term_text(value)

  defp format_time(%DateTime{} = at), do: format_datetime(at)
  defp format_time(value) when is_binary(value), do: format_datetime(value)
  defp format_time(value), do: blank_text(value)
end
