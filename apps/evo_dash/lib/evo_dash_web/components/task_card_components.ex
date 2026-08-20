defmodule EvoDashWeb.TaskCardComponents do
  @moduledoc """
  Task card components for the dashboard — status display, metatags,
  expandable details, result rendering, and option rendering helpers.
  """

  # zh_CN: Agent → "智能体", Token → "词元"

  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # task_card/1 — Compact card with accent bar, relative timestamps
  # ---------------------------------------------------------------------------

  attr(:task, :map, required: true)
  attr(:show_details, :boolean, default: false)
  attr(:current_node_id, :any, default: nil)

  def task_card(assigns) do
    ~H"""
    <div class={[
      "bg-base-100 rounded-lg shadow-sm hover:shadow-md transition-shadow border border-base-200/60 relative z-10 group has-[[open]]:z-30",
      task_card_tint(@task)
    ]}>
      <!-- Accent Top Border — clipped by inner wrapper so it respects rounded corners -->
      <div class="absolute inset-0 rounded-lg overflow-hidden pointer-events-none">
        <div class={["absolute top-0 left-0 right-0 h-1 opacity-80", task_accent_color(@task)]}></div>
      </div>

      <div class="p-4 flex flex-col gap-5">
        <!-- Top row: Metatags & Status -->
        <div class="flex flex-col sm:flex-row sm:items-start justify-between gap-4">
          <div class="flex flex-wrap items-center gap-2.5 mt-1">
            <span class="text-xs font-bold tracking-widest uppercase text-base-content/50">{@task.type}</span>
            <span class="w-1 h-1 rounded-full bg-base-content/20"></span>
            <span class="text-xs font-mono font-medium text-base-content/50">{@task.opts[:mode]}</span>
            <span class="w-1 h-1 rounded-full bg-base-content/20"></span>
            <span class="text-xs font-mono text-base-content/40">#{String.slice(@task.id, 0, 8)}</span>
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <%= if Map.get(@task, :review_status) do %>
              <span class={[
                "badge border-0 font-medium px-2.5 py-2 rounded-md",
                review_status_badge(Map.get(@task, :review_status))
              ]}>
                <.icon
                  name={review_status_icon(Map.get(@task, :review_status))}
                  class="size-4 mr-1.5"
                />
                {review_status_label(Map.get(@task, :review_status))}
              </span>
            <% end %>
            <span class={[
              "badge",
              task_status_badge(@task.status),
              "font-medium border-0 px-2.5 py-2 rounded-md"
            ]}>
              <%= if @task.status == :running do %>
                <span class="relative flex h-2.5 w-2.5 mr-2">
                  <span
                    class="animate-ping absolute inline-flex h-full w-full rounded-full bg-warning opacity-75"
                    style="animation-duration: 2s"
                  ></span>
                  <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-warning"></span>
                </span>
              <% end %>
              <%= if @task.status == :finalizing do %>
                <span class="loading loading-spinner loading-xs mr-2"></span>
              <% end %>
              <%= if @task.status == :cancelling do %>
                <span class="relative flex h-2.5 w-2.5 mr-2">
                  <span
                    class="animate-ping absolute inline-flex h-full w-full rounded-full bg-violet-500 opacity-75"
                    style="animation-duration: 2s"
                  ></span>
                  <span class="relative inline-flex rounded-full h-2.5 w-2.5 bg-violet-500"></span>
                </span>
              <% end %>
              <%= cond do %>
                <% @task.status == :finalizing -> %>
                  Finalizing
                <% @task.status == :cancelling -> %>
                  {gettext("Cancelling…")}
                <% true -> %>
                  {@task.status}
              <% end %>
            </span>
          </div>
        </div>

        <!-- Middle row: Objective text -->
        <div class="pr-2 -mt-2">
          <% objective_text = objective_text(@task.opts) %>
          <%= if objective_text != "" do %>
            <p
              class="text-base text-base-content/90 font-medium leading-relaxed line-clamp-2"
              title={objective_text}
            >
              {objective_text}
            </p>
          <% else %>
            <p
              class="text-base text-base-content/90 font-medium leading-relaxed line-clamp-2"
              title={task_description(@task)}
            >
              {task_description(@task)}
            </p>
          <% end %>
        </div>

        <!-- Bottom row: Time, Actions, Menu -->
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 pt-4 border-t border-base-200/60">
          <div class="flex items-center gap-4 text-xs font-medium text-base-content/50">
            <span class="flex items-center gap-1.5">
              <.icon name="hero-play" class="size-4 opacity-60" />
              {gettext("Started")} {relative_time(@task.started_at)}
            </span>
            <%= if Map.get(@task, :finished_at) do %>
              <span class="flex items-center gap-1.5">
                <.icon name="hero-stop" class="size-4 opacity-60" />
                {gettext("Finished")} {relative_time(@task.finished_at)}
              </span>
            <% end %>
            <%= if Map.get(@task, :agent_count) do %>
              <span class="flex items-center gap-1.5">
                <.icon name="hero-user-group" class="size-4 opacity-60" />
                <%!-- zh_CN: Agent → "智能体" --%>{gettext("%{count} Agents",
                  count: @task.agent_count
                )}
              </span>
            <% end %>
          </div>

          <div class="flex items-center gap-2 sm:gap-3">
            <%= if @task.status in [:pending, :running] do %>
              <button
                class="btn btn-sm btn-outline border-base-300 hover:border-info hover:bg-info/10 hover:text-info rounded-md px-4"
                phx-click="open_cancel_modal"
                phx-value-task_id={@task.id}
              >
                <.icon name="hero-x-mark" class="size-4 mr-1" /> {gettext("Cancel")}
              </button>
            <% end %>

            <%!-- The Review button is node-aware: the link below carries ?node=
                (via with_node_param) so remote-node tasks land on the review
                page with the correct node context. --%>
            <%= if show_review_button?(@task) do %>
              <.link
                navigate={with_node_param(~p"/review/#{@task.id}", @current_node_id)}
                class="btn btn-sm btn-primary rounded-md px-5 shadow-sm hover:shadow-md hover:-translate-y-0.5 transition-all"
              >
                <.icon name="hero-eye" class="size-4 mr-1" /> {gettext("Review")}
              </.link>
            <% end %>

            <button
              class={[
                "btn btn-sm rounded-md px-4 font-medium transition-all",
                (@show_details && "btn-neutral shadow-sm") ||
                  "btn-ghost bg-base-200/50 hover:bg-base-200"
              ]}
              phx-click="toggle_task_details"
              phx-value-task_id={@task.id}
            >
              <%= if @show_details do %>
                {gettext("Hide Details")} <.icon name="hero-chevron-up" class="size-4 ml-1.5" />
              <% else %>
                {gettext("Details")} <.icon name="hero-chevron-down" class="size-4 ml-1.5" />
              <% end %>
            </button>

            <details class="dropdown dropdown-end dropdown-top sm:dropdown-bottom">
              <summary class="btn btn-sm btn-ghost btn-circle rounded-md hover:bg-base-200">
                <.icon name="hero-ellipsis-vertical" class="size-4" />
              </summary>
              <ul class="menu menu-sm dropdown-content mt-1 z-50 p-2 shadow-lg bg-base-100 rounded-lg w-44 border border-base-200">
                <%= if @task.status in [:running, :cancelling] do %>
                  <li>
                    <button
                      class="text-error hover:bg-error/10 hover:text-error rounded-md"
                      phx-click="open_force_kill_modal"
                      phx-value-task_id={@task.id}
                    >
                      <.icon name="hero-bolt" class="size-4 mr-2" /> {gettext("Force kill")}
                    </button>
                  </li>
                  <li class="menu-title px-3 py-1 text-[10px] uppercase tracking-wide text-base-content/40">
                    {gettext("Danger zone")}
                  </li>
                <% end %>
                <li>
                  <button
                    class="text-error hover:bg-error/10 hover:text-error rounded-md"
                    phx-click="delete_task"
                    phx-value-task_id={@task.id}
                    phx-confirm={gettext("Delete this task?")}
                  >
                    <.icon name="hero-trash" class="size-4 mr-2" /> {gettext("Delete")}
                  </button>
                </li>
              </ul>
            </details>
          </div>
        </div>

        <%= if @show_details do %>
          <div class="border-t border-base-200 pt-3 mt-1">
            <div class="space-y-4">
              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <!-- Objective card — full objective text (scrollable) + mode/path badges -->
                <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
                  <div class="flex items-center justify-between mb-4">
                    <h4 class="text-sm font-bold flex items-center gap-2">
                      <.icon name="hero-chat-bubble-left-ellipsis" class="size-4.5 text-primary" />
                      {gettext("Objective")}
                    </h4>
                    <div class="flex items-center gap-2">
                      <button
                        id={"task-#{@task.id}-objective-copy"}
                        phx-hook="ClipboardCopy"
                        data-content={objective_text(@task.opts)}
                        class="btn btn-xs btn-ghost rounded-md"
                      >
                        <.icon name="hero-clipboard-document" class="size-3.5 mr-1" />
                        <%!-- zh_CN: 复制按钮 --%>{gettext("Copy")}
                      </button>
                      <button
                        class="btn btn-xs btn-ghost rounded-md"
                        phx-click="view_full_options"
                        phx-value-task_id={@task.id}
                      >
                        <.icon name="hero-arrows-pointing-out" class="size-3.5 mr-1" /> {gettext(
                          "Full"
                        )}
                      </button>
                    </div>
                  </div>
                  {render_options(@task.opts)}
                </div>
                <%= if Map.get(@task, :result) do %>
                  <!-- Agent Message card — full result content (scrollable) + badges -->
                  <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
                    <div class="flex items-center justify-between mb-4">
                      <h4 class="text-sm font-bold flex items-center gap-2">
                        <.icon name="hero-chat-bubble-left-ellipsis" class="size-4.5 text-success" />
                        <%!-- zh_CN: 智能体的最终消息 --%>{gettext("Agent Message")}
                      </h4>
                      <div class="flex items-center gap-2">
                        <button
                          id={"task-#{@task.id}-result-copy"}
                          phx-hook="ClipboardCopy"
                          data-content={result_copy_text(@task.result)}
                          class="btn btn-xs btn-ghost rounded-md"
                        >
                          <.icon name="hero-clipboard-document" class="size-3.5 mr-1" />
                          <%!-- zh_CN: 复制按钮 --%>{gettext("Copy")}
                        </button>
                        <button
                          class="btn btn-xs btn-ghost rounded-md"
                          phx-click="view_full_result"
                          phx-value-task_id={@task.id}
                        >
                          <.icon name="hero-arrows-pointing-out" class="size-3.5 mr-1" /> {gettext(
                            "Full"
                          )}
                        </button>
                      </div>
                    </div>
                    {render_result(@task.result)}
                  </div>
                <% end %>
              </div>

              <%= if Map.get(@task, :usage) do %>
                <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
                  <h4 class="text-sm font-bold flex items-center gap-2 mb-4">
                    <.icon name="hero-currency-dollar" class="size-4.5 text-primary" />
                    <%!-- zh_CN: Token → "词元" --%>{gettext("Token & Cost Usage")}
                  </h4>
                  <div class="grid grid-cols-3 gap-3">
                    <div>
                      <div class="text-xs text-base-content/50 mb-1">
                        <%!-- zh_CN: Token → "词元" --%>{gettext("Input Tokens")}
                      </div>
                      <div class="text-sm font-semibold">
                        {format_number(@task.usage.input_tokens)}
                      </div>
                    </div>
                    <div>
                      <div class="text-xs text-base-content/50 mb-1">
                        <%!-- zh_CN: Token → "词元" --%>{gettext("Output Tokens")}
                      </div>
                      <div class="text-sm font-semibold">
                        {format_number(@task.usage.output_tokens)}
                      </div>
                    </div>
                    <div>
                      <div class="text-xs text-base-content/50 mb-1">
                        <%!-- zh_CN: Token → "词元" --%>{gettext("Total Tokens")}
                      </div>
                      <div class="text-sm font-semibold">
                        {format_number(@task.usage.total_tokens)}
                      </div>
                    </div>
                  </div>
                  <%= if Map.get(@task.usage, :cached_tokens, 0) > 0 or Map.get(@task.usage, :cache_creation_tokens, 0) > 0 do %>
                    <div class="mt-4 pt-4 border-t border-base-200">
                      <div class="grid grid-cols-3 gap-3">
                        <div>
                          <div class="text-xs text-base-content/50 mb-1">
                            <%!-- zh_CN: Token → "词元" --%>{gettext("Cached Tokens")}
                          </div>
                          <div class="text-sm font-semibold">
                            {format_number(Map.get(@task.usage, :cached_tokens, 0))}
                          </div>
                        </div>
                        <div>
                          <div class="text-xs text-base-content/50 mb-1">
                            {gettext("Cache Creation")}
                          </div>
                          <div class="text-sm font-semibold">
                            {format_number(Map.get(@task.usage, :cache_creation_tokens, 0))}
                          </div>
                        </div>
                        <div>
                          <div class="text-xs text-base-content/50 mb-1">
                            {gettext("Cache Hit Rate")}
                          </div>
                          <div class="text-sm font-semibold text-success">
                            {format_cache_hit_rate(@task.usage)}
                          </div>
                          <progress
                            class="progress progress-success w-full mt-1"
                            value={
                              if @task.usage.input_tokens > 0,
                                do:
                                  min(
                                    round(
                                      Map.get(@task.usage, :cached_tokens, 0) /
                                        @task.usage.input_tokens * 100
                                    ),
                                    100
                                  ),
                                else: 0
                            }
                            max="100"
                          ></progress>
                        </div>
                      </div>
                    </div>
                  <% end %>
                  <div class="mt-4 pt-4 border-t border-base-200">
                    <div class="grid grid-cols-3 gap-3">
                      <div>
                        <div class="text-xs text-base-content/50 mb-1">{gettext("Input Cost")}</div>
                        <div class="text-sm font-semibold">
                          ${format_cost(@task.usage.input_cost)}
                        </div>
                      </div>
                      <div>
                        <div class="text-xs text-base-content/50 mb-1">{gettext("Output Cost")}</div>
                        <div class="text-sm font-semibold">
                          ${format_cost(@task.usage.output_cost)}
                        </div>
                      </div>
                      <div>
                        <div class="text-xs text-base-content/50 mb-1">{gettext("Total Cost")}</div>
                        <div class="text-sm font-semibold text-primary">
                          ${format_cost(@task.usage.total_cost)}
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>

              <%= if Map.get(@task, :agent_count) do %>
                <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
                  <h4 class="text-sm font-bold flex items-center justify-between gap-2 mb-4">
                    <span class="flex items-center gap-2">
                      <.icon name="hero-user-group" class="size-4.5 text-primary" />
                      <%!-- zh_CN: Agent → "智能体" --%>{gettext("Agents Spawned")}
                    </span>
                    <%= if @task.model_id do %>
                      <span class="text-xs font-medium text-base-content/50">
                        {gettext("Model")}: {@task.model_id}
                      </span>
                    <% end %>
                  </h4>
                  <div class="flex items-center gap-3">
                    <span class="text-2xl font-bold text-primary">{format_number(@task.agent_count)}</span>
                    <span class="text-xs text-base-content/50"><%!-- zh_CN: agent → "智能体" --%>{gettext(
                      "total agents (incl. subagents)"
                    )}</span>
                  </div>
                </div>
              <% end %>

              <%!--
                logs is NOT in the summary-map contract (TaskRegistry.list_tasks_summary).
                Map.get keeps this safe for both full %TaskInfo{} structs (TasksLive,
                paginated full loads) and summary maps (missing key → nil → section
                hidden, no KeyError).
              --%>
              <%= if Map.get(@task, :logs) not in [nil, []] do %>
                <% log_count = length(Map.get(@task, :logs, [])) %>
                <details class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors group/logs">
                  <summary class="cursor-pointer text-sm font-bold flex items-center gap-2 select-none outline-none">
                    <.icon
                      name="hero-command-line"
                      class="size-4.5 text-base-content/70 group-hover/logs:text-primary transition-colors"
                    />
                    {gettext("Execution Logs")}
                    <span class="text-xs font-medium text-base-content/50 bg-base-300 px-2 py-0.5 rounded-md ml-2">
                      {if log_count > 20,
                        do: gettext("last 20 of %{count}", count: log_count),
                        else: gettext("%{count}", count: log_count)}
                    </span>
                  </summary>
                  <div class="bg-neutral text-neutral-content p-4 rounded-md max-h-72 overflow-y-auto text-xs font-mono space-y-1 mt-4 shadow-inner">
                    <%= for {log, idx} <- Enum.with_index(Enum.reverse(Map.get(@task, :logs, []))) do %>
                      <div class={[
                        "flex items-start gap-3 p-1.5 rounded transition-colors",
                        rem(idx, 2) == 0 && "bg-black/10",
                        log.level == :error && "text-error-content bg-error/20",
                        log.level == :warn && "text-warning-content bg-warning/20"
                      ]}>
                        <span class="opacity-50 shrink-0 select-none">
                          [{format_datetime(log.timestamp, :time)}]
                        </span>
                        <span class={[
                          "font-bold shrink-0 w-12 select-none",
                          log.level == :error && "text-error",
                          log.level == :warn && "text-warning",
                          log.level == :info && "text-info"
                        ]}>
                          {String.upcase(to_string(log.level))}
                        </span>
                        <span class="break-words font-medium opacity-90">
                          {log.message}
                        </span>
                      </div>
                    <% end %>
                  </div>
                </details>
              <% end %>

              <%= if Map.get(@task, :archive_metadata) not in [nil, []] do %>
                <EvoDashWeb.ArchiveComponents.archive_details
                  archive_metadata={Map.get(@task, :archive_metadata)}
                  task_id={@task.id}
                />
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers — accent color for task_card status bar
  # ---------------------------------------------------------------------------

  defp status_accent_color(:running), do: "bg-warning"
  defp status_accent_color(:finalizing), do: "bg-orange-500"
  defp status_accent_color(:cancelling), do: "bg-violet-500"
  defp status_accent_color(:completed), do: "bg-info"
  defp status_accent_color(:failed), do: "bg-error"
  defp status_accent_color(:cancelled), do: "bg-warning"
  defp status_accent_color(_), do: "bg-base-300"

  defp task_accent_color(%{status: :completed, review_status: :merged}), do: "bg-success"
  defp task_accent_color(%{status: :completed, review_status: :rejected}), do: "bg-error"
  defp task_accent_color(%{status: :completed, review_status: :continued}), do: "bg-secondary"
  defp task_accent_color(%{status: :completed, review_status: :ignored}), do: "bg-base-300"
  defp task_accent_color(%{status: status}), do: status_accent_color(status)

  defp task_card_tint(%{status: :running}), do: "bg-warning/5 shadow-warning/10 border-warning/20"

  defp task_card_tint(%{status: :completed, review_status: :merged}),
    do: "bg-success/5 shadow-success/10 border-success/20"

  defp task_card_tint(%{status: :completed, review_status: :rejected}),
    do: "bg-error/5 shadow-error/10 border-error/20"

  defp task_card_tint(%{status: :completed, review_status: :continued}),
    do: "bg-secondary/5 shadow-secondary/10 border-secondary/20"

  defp task_card_tint(%{status: :completed, review_status: :ignored}),
    do: "bg-base-200/40 shadow-base-300/10 border-base-300/20"

  defp task_card_tint(%{status: :completed}), do: "bg-info/5 shadow-info/10 border-info/20"

  defp task_card_tint(%{status: :finalizing}),
    do: "bg-orange-500/5 shadow-orange-500/10 border-orange-500/20"

  defp task_card_tint(%{status: :cancelling}),
    do: "bg-violet-500/5 shadow-violet-500/10 border-violet-500/20"

  defp task_card_tint(%{status: :failed}), do: "bg-error/5 shadow-error/10 border-error/20"
  defp task_card_tint(_), do: ""

  # ---------------------------------------------------------------------------
  # Public helpers — render_options/2
  # ---------------------------------------------------------------------------

  @doc """
  Returns the objective text for a task's opts (the `:prompt`, falling back to
  `:objective`), trimmed of surrounding whitespace. Shared by the collapsed-card
  preview, the expanded Objective card (including its copy button), and
  `render_options/2`.
  """
  def objective_text(opts) do
    (opts[:prompt] || opts[:objective] || "") |> String.trim()
  end

  def render_options(opts, render_opts \\ []) do
    # `truncate: true` = the expanded-card body (scrollable, full text);
    # `truncate: false` = the zoomed view (the modal's own container scrolls).
    truncate = Keyword.get(render_opts, :truncate, true)
    primary_text = objective_text(opts)
    mode = opts[:mode] || ""
    path = opts[:path] || ""

    assigns = %{
      primary_text: primary_text,
      mode: mode,
      path: path,
      truncate: truncate
    }

    ~H"""
    <div class="space-y-3">
      <div class="bg-base-100 p-3 rounded-lg border border-base-200 shadow-inner">
        <div class={[
          "text-sm whitespace-pre-wrap break-words",
          if(@truncate, do: "max-h-48 overflow-y-auto", else: "")
        ]}>
          {@primary_text}
        </div>
      </div>
      <div class="flex flex-wrap gap-2 text-xs">
        <%= if @mode != "" do %>
          <span class="badge badge-primary font-mono">
            <.icon name="hero-cog-6-tooth" class="size-3 mr-1" />
            {@mode}
          </span>
        <% end %>
        <%= if @path != "" do %>
          <span class="badge badge-ghost font-mono">
            <.icon name="hero-folder" class="size-3 mr-1" />
            {@path}
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Public API — render_options_full/1 renders task options without truncation
  # ---------------------------------------------------------------------------

  def render_options_full(opts) do
    render_options(opts, truncate: false)
  end

  # ---------------------------------------------------------------------------
  # Public helpers — render_result/2
  # ---------------------------------------------------------------------------

  def render_result(data) do
    render_result(data, [])
  end

  def render_result({:ok, %{result: result} = data}, opts) when is_binary(result) do
    render_result(data, opts)
  end

  def render_result({:error, reason}, opts) do
    # `truncate: true` = expanded-card body (full text, scrollable);
    # `truncate: false` = zoomed view (the modal's own container scrolls).
    truncate = Keyword.get(opts, :truncate, true)
    size_class = if truncate, do: "text-xs", else: "text-sm"
    scroll_class = if truncate, do: "max-h-48 overflow-y-auto", else: ""

    wrapper_class =
      if truncate,
        do: "bg-error/10 border border-error/20 p-3 rounded-lg",
        else: "bg-error/10 border border-error/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto"

    assigns = %{
      reason: inspect(reason, limit: :infinity),
      size_class: size_class,
      wrapper_class: wrapper_class,
      scroll_class: scroll_class
    }

    ~H"""
    <div class={@wrapper_class}>
      <h5 class="text-xs font-bold text-error mb-2 uppercase tracking-wide flex items-center gap-1.5">
        <.icon name="hero-x-circle" class="size-3" /> {gettext("Error")}
      </h5>
      <pre class={["whitespace-pre-wrap break-words", @size_class, @scroll_class]}><%= @reason %></pre>
    </div>
    """
  end

  def render_result({:exit, reason}, opts) do
    # `truncate: true` = expanded-card body (full text, scrollable);
    # `truncate: false` = zoomed view (the modal's own container scrolls).
    truncate = Keyword.get(opts, :truncate, true)
    size_class = if truncate, do: "text-xs", else: "text-sm"
    scroll_class = if truncate, do: "max-h-48 overflow-y-auto", else: ""

    wrapper_class =
      if truncate,
        do: "bg-error/10 border border-error/20 p-3 rounded-lg",
        else: "bg-error/10 border border-error/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto"

    assigns = %{
      reason: inspect(reason, limit: :infinity),
      size_class: size_class,
      wrapper_class: wrapper_class,
      scroll_class: scroll_class
    }

    ~H"""
    <div class={@wrapper_class}>
      <h5 class="text-xs font-bold text-error mb-2 uppercase tracking-wide flex items-center gap-1.5">
        <.icon name="hero-x-circle" class="size-3" /> {gettext("Crashed")}
      </h5>
      <pre class={["whitespace-pre-wrap break-words", @size_class, @scroll_class]}><%= @reason %></pre>
    </div>
    """
  end

  def render_result(%{result: result, no_changes: true} = _data, opts) when is_binary(result) do
    truncate = Keyword.get(opts, :truncate, true)

    assigns = %{
      result: result,
      truncate: truncate
    }

    ~H"""
    <div class={if @truncate, do: "space-y-3", else: "space-y-4"}>
      <%= if @truncate do %>
        <div class="bg-base-100 p-3 rounded-lg border border-base-200 shadow-inner">
          <div class="text-sm whitespace-pre-wrap break-words max-h-48 overflow-y-auto">
            {@result}
          </div>
        </div>
        <div class="bg-warning/10 border border-warning/20 p-3 rounded-lg">
          <h5 class="text-xs font-bold text-warning mb-2 uppercase tracking-wide flex items-center gap-1.5">
            <.icon name="hero-information-circle" class="size-3" /> {gettext("No Changes")}
          </h5>
          <p class="text-sm text-warning">
            <%!-- zh_CN: agent → "智能体" --%>{gettext(
              "The agent completed without making any changes to the codebase."
            )}
          </p>
        </div>
      <% else %>
        <div class="bg-warning/10 border border-warning/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
          <h5 class="text-xs font-bold text-warning mb-2 uppercase tracking-wide flex items-center gap-1.5">
            <.icon name="hero-information-circle" class="size-3" /> {gettext("No Changes")}
          </h5>
          <p class="text-sm text-warning">
            <%!-- zh_CN: agent → "智能体" --%>{gettext(
              "The agent completed without making any changes to the codebase."
            )}
          </p>
        </div>
        <div class="bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto">
          <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
            <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" />
            <%!-- zh_CN: Agent → "智能体" --%>{gettext("Agent Message")}
          </h5>
          <pre class="text-sm whitespace-pre-wrap break-words"><%= @result %></pre>
        </div>
      <% end %>
    </div>
    """
  end

  def render_result(%{result: result, commit_sha: commit_sha} = data, opts)
      when is_binary(result) do
    truncate = Keyword.get(opts, :truncate, true)

    assigns = %{
      result: result,
      commit_sha: commit_sha,
      tag: Map.get(data, :tag),
      branch_name: Map.get(data, :branch_name),
      pr_url: Map.get(data, :pr_url),
      truncate: truncate
    }

    ~H"""
    <div class={if @truncate, do: "space-y-3", else: "space-y-4"}>
      <%= if !@truncate do %>
        <div class="flex flex-wrap gap-2 mb-4">
          <%= if @branch_name do %>
            <span class="badge badge-primary font-mono text-sm">
              <.icon name="hero-code-bracket-square" class="size-4 mr-1" />
              {@branch_name}
            </span>
          <% end %>
          <%= if @commit_sha do %>
            <span class="badge badge-ghost font-mono text-sm">
              <.icon name="hero-code-bracket" class="size-4 mr-1" />
              {String.slice(@commit_sha, 0..7)}
            </span>
          <% end %>
          <%= if @tag do %>
            <span class="badge badge-ghost font-mono text-sm">
              <.icon name="hero-tag" class="size-4 mr-1" />
              {@tag}
            </span>
          <% end %>
          <%= if @pr_url do %>
            <a
              href={@pr_url}
              target="_blank"
              class="badge badge-success font-mono text-sm hover:opacity-80 transition-opacity"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4 mr-1" />
              {gettext("View PR")}
            </a>
          <% end %>
        </div>
      <% end %>
      <div class={
        if @truncate,
          do: "bg-base-100 p-3 rounded-lg border border-base-200 shadow-inner",
          else: "bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto"
      }>
        <%= if !@truncate do %>
          <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
            <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> {gettext("Agent Message")}
          </h5>
        <% end %>
        <%= if @truncate do %>
          <div class="text-sm whitespace-pre-wrap break-words max-h-48 overflow-y-auto">
            {@result}
          </div>
        <% else %>
          <pre class="text-sm whitespace-pre-wrap break-words"><%= @result %></pre>
        <% end %>
      </div>
      <%= if @truncate do %>
        <div class="flex flex-wrap gap-2 text-xs">
          <%= if @commit_sha do %>
            <span class="badge badge-ghost font-mono">
              <.icon name="hero-code-bracket" class="size-3 mr-1" />
              {String.slice(@commit_sha, 0..7)}
            </span>
          <% end %>
          <%= if @tag do %>
            <span class="badge badge-ghost font-mono">
              <.icon name="hero-tag" class="size-3 mr-1" />
              {@tag}
            </span>
          <% end %>
          <%= if @branch_name do %>
            <span class="badge badge-primary font-mono">
              <.icon name="hero-code-bracket-square" class="size-3 mr-1" />
              {@branch_name}
            </span>
          <% end %>
          <%= if @pr_url do %>
            <a
              href={@pr_url}
              target="_blank"
              class="badge badge-success font-mono hover:opacity-80 transition-opacity"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3 mr-1" />
              {gettext("View PR")}
            </a>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  def render_result(%{result: result}, opts) do
    truncate = Keyword.get(opts, :truncate, true)
    size_class = if truncate, do: "text-xs", else: "text-sm"
    scroll_class = if truncate, do: "max-h-48 overflow-y-auto", else: ""

    wrapper_class =
      if truncate,
        do: "bg-base-100 p-3 rounded-lg border border-base-200",
        else: "bg-success/10 border border-success/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto"

    assigns = %{
      result: inspect(result, pretty: true, limit: :infinity),
      size_class: size_class,
      wrapper_class: wrapper_class,
      scroll_class: scroll_class
    }

    ~H"""
    <pre class={["overflow-x-auto", @size_class, @wrapper_class, @scroll_class]}><%= @result %></pre>
    """
  end

  def render_result(result, opts) do
    truncate = Keyword.get(opts, :truncate, true)
    size_class = if truncate, do: "text-xs", else: "text-sm"
    scroll_class = if truncate, do: "max-h-48 overflow-y-auto", else: ""

    wrapper_class =
      if truncate,
        do: "bg-base-100 p-3 rounded-lg border border-base-200 overflow-x-auto shadow-inner",
        else: "bg-base-200 rounded-lg p-4 max-h-[70vh] overflow-y-auto"

    assigns = %{
      result: inspect(result, pretty: true, limit: :infinity),
      size_class: size_class,
      wrapper_class: wrapper_class,
      scroll_class: scroll_class
    }

    ~H"""
    <pre class={["overflow-x-auto", @size_class, @wrapper_class, @scroll_class]}><%= @result %></pre>
    """
  end

  # ---------------------------------------------------------------------------
  # Public API — render_result_full/1 renders full task result without truncation
  # ---------------------------------------------------------------------------

  def render_result_full(assigns) do
    render_result(assigns, truncate: false)
  end

  @doc """
  Returns the copyable plain-text representation of a task result value.

  Used by both the unzoomed "Agent Message" card copy button and the zoomed
  Full Result modal copy button (`tasks_live.ex`). Success/no-changes results
  copy the raw agent message; error/crash results copy the inspected reason
  (unlimited); anything else falls back to a pretty-inspected representation.
  """
  def result_copy_text({:ok, %{result: result}}) when is_binary(result), do: result
  def result_copy_text({:error, reason}), do: inspect(reason, limit: :infinity)
  def result_copy_text({:exit, reason}), do: inspect(reason, limit: :infinity)
  def result_copy_text(%{result: result}) when is_binary(result), do: result
  def result_copy_text(result), do: inspect(result, pretty: true, limit: :infinity)

  defp show_review_button?(%{status: :completed, result: {:ok, %{branch_name: branch}}})
       when is_binary(branch) and branch != "", do: true

  defp show_review_button?(%{status: :cancelled, result: {:ok, %{branch_name: branch}}})
       when is_binary(branch) and branch != "", do: true

  defp show_review_button?(%{status: :completed, result: {:ok, %{no_changes: true}}}), do: true

  defp show_review_button?(%{status: :cancelled, result: {:ok, %{no_changes: true}}}), do: true

  defp show_review_button?(_), do: false
end
