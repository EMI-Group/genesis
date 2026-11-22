defmodule EvoDashWeb.AgentsLive.DetailPanel do
  @moduledoc """
  The Agents page RIGHT column: the selected-agent detail panel — header +
  status badge, the details grid (module / model / context path / objective /
  worktree / task / depth / retries / commits / parent / children), the
  collapsible token & cost tiles with the ContextMeter, and the
  "Chat History / Session Memory" block (checkpoint rows plus the live
  `StreamPanel` current-call row).

  Because the region genuinely reads a large slice of the page's assigns — and
  because the two template view helpers it needs
  (`Inspector.selected_inspector_agent/1`, `Inspector.inspector_scope/1`) are
  defined over that whole assigns map — the component takes ONE passthrough
  `assigns` attr instead of a long attr list. It is therefore rendered as
  `<EvoDashWeb.AgentsLive.DetailPanel.detail_panel assigns={assigns} />`, and
  it reads keys LAZILY, exactly where the inline template read them, so a
  render with a partial assigns map behaves as before.

  DOM contract owned here: `#agent-detail-<id>` (its presence is the
  "details open" marker), `#agent-context-meter` and its `data-context-*`
  readouts, the TWO-element history block — the OUTER
  `#agent-history-scroll-<id>` scroller (`AgentHistoryAutoScroll`) wrapping the
  INNER `#agent-history-<id>` (`InspectorMessages`, `data-inspector-scope`) —
  the entry rows `#agent-history-entry-<id>-<index>` with
  `data-inspector-message`, `#inspector-history-error`, and the
  `agent-detail-history` column the panel's flex chain pins.
  """
  use EvoDashWeb, :html

  alias EvoDashWeb.AgentsLive.{ContextMeter, Inspector, StreamPanel}

  attr :assigns, :map, required: true

  def detail_panel(assigns) do
    ~H"""
    <% page = @assigns %>
    <!-- Right Column: Agent Details Panel — full vertical space -->
    <div class="agents-detail-col">
      <div class="card bg-base-100 border border-base-300 rounded-lg">
        <div class="card-body p-4">
          <%= if page.selected_agent_id do %>
            <% agent = Inspector.selected_inspector_agent(page) %>
            <%= if agent do %>
              <div id={"agent-detail-#{agent.id}"} class="agent-detail-content">
                <div class="flex flex-wrap items-center justify-between gap-2 mb-3">
                  <div class="flex min-w-0 flex-wrap items-center gap-2">
                    <h3 class="card-title text-base font-semibold">
                      <.icon name="hero-identification" class="size-5" />
                      #{agent.task_local_id || agent.id}
                    </h3>
                    <div class={["badge badge-md", agent_status_bg(agent.status)]}>
                      <.icon
                        name={agent_status_icon(agent.status)}
                        class={"size-4 mr-1 #{agent_status_color(agent.status)}"}
                      />
                      <span class={agent_status_color(agent.status)}>{String.upcase(
                        agent_status_label(agent.status)
                      )}</span>
                    </div>
                  </div>
                  <div class="flex items-center gap-1">
                    <%= if agent.status in [:running, :waiting, :pending, :blocked] do %>
                      <button
                        class="btn btn-sm btn-ghost btn-circle tooltip"
                        data-tip={gettext("Send Message")}
                        phx-click="open_send_message"
                        phx-value-id={agent.id}
                      >
                        <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" />
                      </button>
                    <% end %>
                    <button
                      class="btn btn-sm btn-ghost btn-circle"
                      phx-click="close_details"
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </div>
                </div>

                <!-- Details -->
                <div class="space-y-4">
                  <!-- Agent Module + Context Path on a single row -->
                  <div class="flex flex-wrap items-start gap-x-6 gap-y-3">
                    <div class="shrink-0 min-w-[130px]">
                      <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                        {gettext("Agent Module")}
                      </h4>
                      <code class="text-xs bg-base-200/60 border border-base-300 px-2 py-1 rounded block break-all">
                        {inspect(agent.agent_module)}
                      </code>
                    </div>
                    <div class="shrink-0 min-w-[130px]">
                      <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                        {gettext("Model")}
                      </h4>
                      <code class="text-xs bg-base-200/60 border border-base-300 px-2 py-1 rounded block break-all">
                        {agent.model_label || gettext("N/A")}
                      </code>
                    </div>
                    <div class="flex-1 min-w-[150px]">
                      <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                        {gettext("Context Path")}
                      </h4>
                      <code class="text-xs bg-base-200/60 border border-base-300 px-2 py-1 rounded block break-all w-full">
                        {agent.context_path || gettext("N/A")}
                      </code>
                    </div>
                  </div>

                  <div>
                    <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                      {gettext("Objective")}
                    </h4>
                    <p class="text-sm bg-base-200/50 border border-base-300 p-3 rounded">
                      {String.slice(agent.objective, 0, 150)}{if String.length(agent.objective) >
                                                                   150,
                                                                 do: "..."}
                      <%= if String.length(agent.objective) > 150 do %>
                        <button
                          class="btn btn-xs btn-ghost px-2 ml-2 text-base-content/70 hover:text-base-content"
                          phx-click="view_full_objective"
                          title={gettext("View Full Objective")}
                        >
                          <.icon name="hero-arrows-pointing-out" class="size-3" />
                        </button>
                      <% end %>
                    </p>
                  </div>

                  <div>
                    <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                      {gettext("Worktree")}
                    </h4>
                    <code class="text-xs bg-base-200/60 border border-base-300 px-2 py-1 rounded block break-all">
                      {agent.worktree || gettext("Not assigned")}
                    </code>
                  </div>

                  <!-- Task ID, Depth, Retries (compact) + Base/Current Commit (wide) on a single row -->
                  <div class="flex flex-wrap items-start gap-x-6 gap-y-3">
                    <div class="shrink-0">
                      <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                        {gettext("Task ID")}
                      </h4>
                      <span class="text-sm">#{agent.task_number || agent.task_id}</span>
                    </div>

                    <div class="shrink-0">
                      <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                        {gettext("Depth")}
                      </h4>
                      <span class="text-sm">{agent.depth}</span>
                    </div>

                    <div class="shrink-0">
                      <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                        {gettext("Retries")}
                      </h4>
                      <span class="text-sm">{agent.retries}</span>
                    </div>

                    <%= if agent.base_commit do %>
                      <div class="flex-1 min-w-0">
                        <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                          <.icon name="hero-circle-stack" class="size-3 inline mr-1" /> {gettext(
                            "Base Commit"
                          )}
                        </h4>
                        <code
                          class="text-xs font-mono bg-base-200/60 border border-base-300 px-2 py-1 rounded block truncate w-full"
                          title={agent.base_commit}
                        >
                          {shorten_sha(agent.base_commit)}
                        </code>
                      </div>
                    <% end %>

                    <%= if agent.current_commit do %>
                      <div class="flex-1 min-w-0">
                        <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                          <.icon name="hero-circle-stack" class="size-3 inline mr-1" /> {gettext(
                            "Current Commit"
                          )}
                        </h4>
                        <code
                          class={"text-xs font-mono px-2 py-1 rounded block truncate w-full " <> commit_bg_class(agent)}
                          title={agent.current_commit}
                        >
                          {shorten_sha(agent.current_commit)}
                        </code>
                      </div>
                    <% end %>
                  </div>

                  <div class="flex flex-col sm:flex-row gap-4">
                    <div class="shrink-0">
                      <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                        {gettext("Parent")}
                      </h4>
                      <%= if agent.parent_id do %>
                        <button
                          class="btn btn-sm btn-ghost btn-xs"
                          phx-click="select_agent"
                          phx-value-id={agent.parent_id}
                        >
                          #{page.id_to_display[agent.parent_id] || agent.parent_id}
                        </button>
                      <% else %>
                        <span class="text-sm text-base-content/70">{gettext("None")}</span>
                      <% end %>
                    </div>

                    <div class="flex-1 min-w-0">
                      <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                        {gettext("Children")}
                      </h4>
                      <%= if agent.has_children do %>
                        <div class="flex flex-wrap gap-1">
                          <%= for {child_id, child_status} <- agent.children do %>
                            <button
                              class={[
                                "badge badge-sm btn-xs cursor-pointer badge-outline",
                                agent_status_border(child_status),
                                agent_status_color(child_status)
                              ]}
                              phx-click="select_agent"
                              phx-value-id={child_id}
                            >
                              #{page.id_to_display[child_id] || child_id}
                            </button>
                          <% end %>
                        </div>
                      <% else %>
                        <span class="text-sm text-base-content/70">{gettext("None")}</span>
                      <% end %>
                    </div>

                    <div class="shrink-0">
                      <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-1">
                        &nbsp;
                      </h4>
                      <button
                        class="cursor-pointer text-xs font-semibold uppercase text-base-content/70 flex items-center gap-1.5 select-none outline-none hover:text-base-content transition-colors"
                        phx-click="toggle_usage"
                      >
                        <.icon name="hero-currency-dollar" class="size-3.5" />
                        {gettext("Token and Cost")}
                        <.icon
                          name="hero-chevron-down"
                          class={"size-3 opacity-50 transition-transform #{if page.show_usage, do: "rotate-180"}"}
                        />
                      </button>
                    </div>
                  </div>
                </div>

                <%= if page.show_usage do %>
                  <div class="mt-2">
                    <div class="grid grid-cols-3 gap-2 mt-2">
                      <div class="bg-base-200/50 border border-base-300 rounded-lg p-3">
                        <div class="text-xs text-base-content/70">
                          {gettext("Input Tokens")}
                        </div>
                        <div class="text-sm font-semibold">
                          {format_number(agent.usage.input_tokens)}
                        </div>
                      </div>
                      <div class="bg-base-200/50 border border-base-300 rounded-lg p-3">
                        <div class="text-xs text-base-content/70">
                          {gettext("Output Tokens")}
                        </div>
                        <div class="text-sm font-semibold">
                          {format_number(agent.usage.output_tokens)}
                        </div>
                      </div>
                      <div class="bg-base-200/50 border border-base-300 rounded-lg p-3">
                        <div class="text-xs text-base-content/70">
                          {gettext("Total Tokens")}
                        </div>
                        <div class="text-sm font-semibold">
                          {format_number(agent.usage.total_tokens)}
                        </div>
                      </div>
                    </div>
                    <div class="mt-4 pt-4 border-t border-base-300">
                      <div class="grid grid-cols-2 gap-2 mt-2">
                        <div class="bg-base-200/50 border border-base-300 rounded-lg p-3">
                          <div class="text-xs text-base-content/70">
                            {gettext("Cached Tokens")}
                          </div>
                          <div class="text-sm font-semibold">
                            {format_number(Map.get(agent.usage, :cached_tokens, 0))}
                          </div>
                        </div>
                        <div class="bg-base-200/50 border border-base-300 rounded-lg p-3">
                          <div class="text-xs text-base-content/70">
                            {gettext("Cache Hit Rate")}
                          </div>
                          <div class="text-sm font-semibold text-success">
                            {format_cache_hit_rate(agent.usage)}
                          </div>
                          <progress
                            class="progress progress-success w-full mt-1"
                            value={
                              if agent.usage.input_tokens > 0,
                                do:
                                  min(
                                    round(
                                      Map.get(agent.usage, :cached_tokens, 0) /
                                        agent.usage.input_tokens * 100
                                    ),
                                    100
                                  ),
                                else: 0
                            }
                            max="100"
                          ></progress>
                        </div>
                      </div>
                      <% meter = ContextMeter.build(agent) %>
                      <% context_label =
                        if meter.threshold_tokens,
                          do:
                            "#{format_number(meter.current_tokens)} / #{format_number(meter.threshold_tokens)}",
                          else: format_number(meter.current_tokens) %>
                      <% compression_label =
                        "#{meter.compression_count} (#{agent.compression_pct}%)" %>
                      <div class="mt-2 bg-base-200/50 border border-base-300 rounded-lg p-3">
                        <div class="flex items-baseline justify-between gap-2">
                          <div class="text-xs text-base-content/70">
                            {gettext("Context")}
                          </div>
                          <div class="text-xs font-semibold text-base-content/80">
                            {context_label}
                          </div>
                        </div>
                        <div
                          id="agent-context-meter"
                          class="relative mt-2"
                          data-context-fill-pct={meter.fill_label}
                          data-context-tick-pct={meter.tick_label}
                          data-context-zone={meter.zone}
                          data-context-window-tokens={meter.window_tokens}
                          data-context-threshold-tokens={meter.threshold_tokens}
                          data-context-current-tokens={meter.current_tokens}
                        >
                          <div class="h-1.5 w-full overflow-hidden rounded-full bg-base-300">
                            <div
                              class={["h-full rounded-full", meter.fill_class]}
                              style={"width: #{meter.fill_label}%"}
                            >
                            </div>
                          </div>
                          <%= if meter.tick_pct do %>
                            <div
                              class="absolute inset-y-0 w-2 -translate-x-1/2 cursor-default"
                              style={"left: #{meter.tick_label}%"}
                              title={
                                gettext("Compression triggers at %{tokens} tokens",
                                  tokens: format_number(meter.threshold_tokens)
                                )
                              }
                            >
                              <div class={[
                                "absolute inset-y-0 left-1/2 w-0.5 -translate-x-1/2 rounded-full",
                                meter.tick_class
                              ]}>
                              </div>
                              <div class={[
                                "absolute -top-1 left-1/2 h-1.5 w-1.5 -translate-x-1/2 rotate-45 rounded-[1px]",
                                meter.tick_class
                              ]}>
                              </div>
                            </div>
                          <% end %>
                        </div>
                        <div class="mt-1.5 flex items-center justify-between gap-2 text-xs text-base-content/70">
                          <span>
                            <%= if meter.tick_pct do %>
                              {gettext("Compression at %{tokens}",
                                tokens: format_number(meter.threshold_tokens)
                              )}
                            <% else %>
                              {gettext("Compression threshold unknown")}
                            <% end %>
                          </span>
                          <% # zh_CN: 括号内的百分比 = 当前上下文占压缩阈值的比例 %>
                          <span class="whitespace-nowrap">
                            {gettext("Compressions")}: {compression_label}
                          </span>
                        </div>
                      </div>
                    </div>
                    <div class="mt-4 pt-4 border-t border-base-300">
                      <div class="grid grid-cols-3 gap-2 mt-2">
                        <div class="bg-base-200/50 border border-base-300 rounded-lg p-3">
                          <div class="text-xs text-base-content/70">
                            {gettext("Input Cost")}
                          </div>
                          <div class="text-sm font-semibold">
                            ${format_cost(agent.usage.input_cost)}
                          </div>
                        </div>
                        <div class="bg-base-200/50 border border-base-300 rounded-lg p-3">
                          <div class="text-xs text-base-content/70">
                            {gettext("Output Cost")}
                          </div>
                          <div class="text-sm font-semibold">
                            ${format_cost(agent.usage.output_cost)}
                          </div>
                        </div>
                        <div class="bg-base-200/50 border border-base-300 rounded-lg p-3">
                          <div class="text-xs text-base-content/70">
                            {gettext("Total Cost")}
                          </div>
                          <div class="text-sm font-semibold text-primary-standalone">
                            ${format_cost(agent.usage.total_cost)}
                          </div>
                        </div>
                      </div>
                      <.cost_estimate_notice />
                    </div>
                  </div>
                <% end %>

                <!-- Chat History -->
                <div class="agent-detail-history mt-6">
                  <h4 class="text-xs font-semibold uppercase text-base-content/70 mb-2">
                    {gettext("Chat History / Session Memory")}
                  </h4>
                  <% history_entries = Inspector.merged_history(agent, page.optimistic_messages) %>
                  <%!-- TWO elements, ONE hook each: the OUTER `.agent-history-scroll`
                       is the scroller (`AgentHistoryAutoScroll` drives an instant
                       stick-to-bottom and CSS pins it as the panel's flex child),
                       the INNER `#agent-history-<id>` keeps `InspectorMessages`
                       for the new-row entrance. `divide-y` lives on the inner
                       element so the legacy entry-animation selector
                       `.agent-history-scroll > .divide-y > div` still matches. --%>
                  <div
                    id={"agent-history-scroll-#{page.selected_agent_id}"}
                    class="agent-history-scroll overflow-y-auto bg-base-200/50 border border-base-300 rounded-lg"
                    phx-hook="AgentHistoryAutoScroll"
                  >
                    <div
                      id={"agent-history-#{page.selected_agent_id}"}
                      class="divide-y divide-base-300"
                      phx-hook="InspectorMessages"
                      data-inspector-scope={Inspector.inspector_scope(page)}
                    >
                      <div
                        :if={page.inspector_history_error}
                        id="inspector-history-error"
                        role="alert"
                        class="flex items-center gap-2 p-3 text-xs text-error"
                      >
                        <span>{gettext(
                          "Could not refresh checkpoint history. Live excerpts are preserved."
                        )}</span>
                        <button
                          type="button"
                          class="btn btn-xs btn-ghost"
                          phx-click="retry_inspector_history"
                          disabled={page.history_loading_agent_id == agent.id}
                        >
                          {gettext("Retry")}
                        </button>
                      </div>
                      <%= if history_entries != [] do %>
                        <%= for {entry, index} <- Enum.with_index(history_entries) do %>
                          <div
                            id={"agent-history-entry-#{page.selected_agent_id}-#{index}"}
                            class="p-3 hover:bg-base-300/40"
                            data-inspector-message={Inspector.inspector_message_marker(entry, index)}
                          >
                            <div class="flex flex-wrap items-center gap-2 mb-1">
                              <.icon
                                name={history_entry_icon(entry.type)}
                                class="size-4 shrink-0"
                              />
                              <span class={[
                                "text-xs font-semibold",
                                history_entry_color(entry.type)
                              ]}>
                                {entry.type}
                              </span>
                              <button
                                class="btn btn-xs btn-ghost px-2 ml-2 text-base-content/70 hover:text-base-content"
                                phx-click="view_full_message"
                                phx-value-index={index}
                                title={gettext("View Full Message")}
                              >
                                <.icon name="hero-arrows-pointing-out" class="size-3" />
                              </button>
                              <span class="text-xs text-base-content/70 ml-auto flex items-center gap-2">
                                {format_turn(entry.turn)}
                                <%= if timestamp = format_history_timestamp(entry.timestamp) do %>
                                  <span class="text-base-content/70">{timestamp}</span>
                                <% end %>
                              </span>
                            </div>
                            <EvoDashWeb.AgentsLive.HistoryEntry.history_entry_body
                              entry={entry}
                              surface={:row}
                            />
                          </div>
                        <% end %>
                      <% else %>
                        <%= if page.history_loading_agent_id == agent.id do %>
                          <div class="text-sm text-base-content/70 bg-base-200/50 border border-base-300 p-4 rounded-lg text-center flex items-center justify-center gap-2">
                            <.icon name="hero-arrow-path" class="size-4 animate-spin" />
                            <%!-- 对话历史加载中提示：选中智能体后异步拉取历史时的过渡态 --%>
                            <span>{gettext("Loading history…")}</span>
                          </div>
                        <% else %>
                          <div class="text-sm text-base-content/70 bg-base-200/50 border border-base-300 p-4 rounded-lg text-center">
                            {gettext("No history recorded yet")}
                          </div>
                        <% end %>
                      <% end %>
                      <StreamPanel.stream_panel stream={page.inspector_stream} />
                    </div>
                  </div>
                </div>
              </div>
            <% else %>
              <p class="text-sm text-base-content/70">{gettext("Agent not found")}</p>
            <% end %>
          <% else %>
            <div class="text-center py-16">
              <.icon
                name="hero-finger-pointing"
                class="size-10 mx-auto mb-4 text-base-content/40"
              />
              <p class="text-lg text-base-content">
                {gettext("Select an agent to view details")}
              </p>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # The uncommitted-changes warn chip on the current-commit line.
  defp commit_bg_class(agent) do
    if agent.current_commit != agent.base_commit do
      # Uncommitted changes on this agent's branch — warning-family highlight
      # (semantic meaning preserved) on the hairline commit chip.
      "bg-warning/20 border border-warning/30"
    else
      "bg-base-200/60 border border-base-300"
    end
  end

  defp shorten_sha(sha) when is_binary(sha) do
    if String.length(sha) > 8 do
      String.slice(sha, 0, 8) <> "…"
    else
      sha
    end
  end

  defp shorten_sha(other), do: other
end
