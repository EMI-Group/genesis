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
            <span class="text-xs font-bold tracking-widest uppercase text-base-content/70">{@task.type}</span>
            <span class="w-1 h-1 rounded-full bg-base-content/20"></span>
            <span class="text-xs font-mono font-medium text-base-content/70">{@task.opts[:mode]}</span>
            <span class="w-1 h-1 rounded-full bg-base-content/20"></span>
            <span class="text-xs font-mono text-base-content/60">#{String.slice(@task.id, 0, 8)}</span>
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
              <%= if @task.status in [:running, :cancelling] do %>
                <span class="relative flex h-2.5 w-2.5 mr-2">
                  <span
                    class={[
                      "animate-ping absolute inline-flex h-full w-full rounded-full opacity-75",
                      task_status_dot_class(@task.status)
                    ]}
                    style="animation-duration: 2s"
                  ></span>
                  <span class={[
                    "relative inline-flex rounded-full h-2.5 w-2.5",
                    task_status_dot_class(@task.status)
                  ]}></span>
                </span>
              <% end %>
              <%= if @task.status == :finalizing do %>
                <span class="loading loading-spinner loading-xs mr-2"></span>
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

        <!-- Middle row: Objective text. DISPLAY-only cap (no limit note — it is
             a 2-line clamped teaser): a multi-MB objective would otherwise ride
             the `title` attribute + body of EVERY card render. The full text
             stays in the Objective card below (capped, with a note) and in the
             Copy payload (`objective_text/1`, full). -->
        <div class="pr-2 -mt-2">
          <% objective_preview = text_preview(objective_text(@task.opts), true) %>
          <%= if objective_preview.text != "" do %>
            <p
              class="text-base text-base-content/90 font-medium leading-relaxed line-clamp-2"
              title={objective_preview.text}
            >
              {objective_preview.text}
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

        <!-- Multi-repo indicator — compact per-repo badges on the COLLAPSED
             card only (the expanded detail view shows the full per-repo
             section). Guarded by result_repos/1: legacy results / summary
             maps without a `repos` key render nothing. -->
        <%= if !@show_details do %>
          <% repos = result_repos(Map.get(@task, :result)) %>
          <%= if repos do %>
            <div class="-mt-3">
              <EvoDashWeb.TaskCardComponents.result_repos_badges repos={repos} />
            </div>
          <% end %>
        <% end %>

        <!-- Compact structured-failure line — COLLAPSED failed card only (the
             expanded view shows the full-detail block instead). Renders the
             truncated error.message in an error-tinted strip. Guarded: fires
             ONLY for status == :failed with a map `error` record (see
             task_error/1) — legacy failed rows (`error` nil/non-map) and all
             non-failed statuses render nothing, byte-identical to the
             pre-feature card. -->
        <%= if !@show_details do %>
          <% error = task_error(@task) %>
          <%= if error do %>
            <div class="flex items-center gap-2 bg-error/10 border border-error/20 rounded-lg px-3 py-2 min-w-0">
              <.icon name="hero-x-circle" class="size-4 text-error shrink-0" />
              <span
                class="text-xs font-medium text-error truncate min-w-0"
                title={error_message(error) || ""}
              >
                {collapsed_error_text(error)}
              </span>
            </div>
          <% end %>
        <% end %>

        <!-- Bottom row: Time, Actions, Menu -->
        <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 pt-4 border-t border-base-200/60">
          <div class="flex items-center gap-4 text-xs font-medium text-base-content/70">
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
                  <li class="menu-title px-3 py-1 text-xs uppercase tracking-wide text-base-content/60">
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
              <!-- Full-detail structured failure block — EXPANDED failed card
                   only (the collapsed card shows the compact line instead).
                   Caption chips = kind + source labels (Helpers
                   task_error_kind_label/1 / task_error_source_label/1), then
                   the full untruncated error.message and the LAST ≤8
                   stacktrace frames as monospace lines. Same guard as the
                   collapsed line: status == :failed AND a map `error` record;
                   anything else renders nothing. The legacy `{:error, _}` /
                   `{:exit, _}` RESULT (if any) renders separately in the
                   Agent Message card below — both records may coexist and are
                   both legitimately informative. -->
              <% error = task_error(@task) %>
              <%= if error do %>
                <div class="bg-error/10 border border-error/20 rounded-lg p-4">
                  <div class="flex flex-wrap items-center gap-x-4 gap-y-1.5 mb-3">
                    <span class="inline-flex items-center gap-1.5 text-xs font-bold text-error uppercase tracking-wide">
                      <.icon name="hero-x-circle" class="size-4" />
                      {task_error_kind_label(error_field(error, :kind))}
                    </span>
                    <span class="inline-flex items-center gap-1.5 text-xs font-medium text-base-content/70">
                      <.icon name="hero-bolt" class="size-3.5" />
                      <%!-- zh_CN: 失败错误的来源（检测到失败的位置） --%>{gettext(
                        "Source"
                      )}: {task_error_source_label(error_field(error, :source))}
                    </span>
                  </div>
                  <% message = error_message(error) %>
                  <%= if message do %>
                    <pre class="text-xs whitespace-pre-wrap break-words max-h-48 overflow-y-auto"><%= message %></pre>
                  <% end %>
                  <% frames = error_stacktrace(error) %>
                  <%= if frames do %>
                    <div class="mt-3 bg-base-100 border border-error/20 rounded-md p-3 overflow-x-auto">
                      <div class="text-xs font-bold uppercase tracking-wide text-error mb-1.5">
                        <%!-- zh_CN: 堆栈跟踪 --%>{gettext("Stacktrace")}
                      </div>
                      <pre class="text-xs font-mono leading-relaxed whitespace-pre-wrap break-words"><%= Enum.join(frames, "\n") %></pre>
                    </div>
                  <% end %>
                </div>
              <% end %>
              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <!-- Objective card — full objective text (scrollable) + mode/path badges -->
                <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
                  <div class="flex items-center justify-between mb-4">
                    <h4 class="text-sm font-bold flex items-center gap-2">
                      <.icon
                        name="hero-chat-bubble-left-ellipsis"
                        class="size-4.5 text-primary-standalone"
                      />
                      {gettext("Objective")}
                    </h4>
                    <div class="flex items-center gap-2">
                      <% objective_copy = copy_payload(objective_text(@task.opts)) %>
                      <button
                        id={"task-#{@task.id}-objective-copy"}
                        phx-hook="ClipboardCopy"
                        data-content={objective_copy.text}
                        title={copy_payload_title(objective_copy)}
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
                        <% result_copy = copy_payload(result_copy_text(@task.result)) %>
                        <button
                          id={"task-#{@task.id}-result-copy"}
                          phx-hook="ClipboardCopy"
                          data-content={result_copy.text}
                          title={copy_payload_title(result_copy)}
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
                    <.icon name="hero-currency-dollar" class="size-4.5 text-primary-standalone" />
                    <%!-- zh_CN: Token → "词元" --%>{gettext("Token & Cost Usage")}
                  </h4>
                  <div class="grid grid-cols-3 gap-3">
                    <div>
                      <div class="text-xs text-base-content/70 mb-1">
                        <%!-- zh_CN: Token → "词元" --%>{gettext("Input Tokens")}
                      </div>
                      <div class="text-sm font-semibold">
                        {format_number(@task.usage.input_tokens)}
                      </div>
                    </div>
                    <div>
                      <div class="text-xs text-base-content/70 mb-1">
                        <%!-- zh_CN: Token → "词元" --%>{gettext("Output Tokens")}
                      </div>
                      <div class="text-sm font-semibold">
                        {format_number(@task.usage.output_tokens)}
                      </div>
                    </div>
                    <div>
                      <div class="text-xs text-base-content/70 mb-1">
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
                          <div class="text-xs text-base-content/70 mb-1">
                            <%!-- zh_CN: Token → "词元" --%>{gettext("Cached Tokens")}
                          </div>
                          <div class="text-sm font-semibold">
                            {format_number(Map.get(@task.usage, :cached_tokens, 0))}
                          </div>
                        </div>
                        <div>
                          <div class="text-xs text-base-content/70 mb-1">
                            {gettext("Cache Creation")}
                          </div>
                          <div class="text-sm font-semibold">
                            {format_number(Map.get(@task.usage, :cache_creation_tokens, 0))}
                          </div>
                        </div>
                        <div>
                          <div class="text-xs text-base-content/70 mb-1">
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
                        <div class="text-xs text-base-content/70 mb-1">{gettext("Input Cost")}</div>
                        <div class="text-sm font-semibold">
                          ${format_cost(@task.usage.input_cost)}
                        </div>
                      </div>
                      <div>
                        <div class="text-xs text-base-content/70 mb-1">{gettext("Output Cost")}</div>
                        <div class="text-sm font-semibold">
                          ${format_cost(@task.usage.output_cost)}
                        </div>
                      </div>
                      <div>
                        <div class="text-xs text-base-content/70 mb-1">{gettext("Total Cost")}</div>
                        <div class="text-sm font-semibold text-primary-standalone">
                          ${format_cost(@task.usage.total_cost)}
                        </div>
                      </div>
                    </div>
                    <.cost_estimate_notice />
                  </div>
                </div>
              <% end %>

              <%= if Map.get(@task, :agent_count) do %>
                <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
                  <h4 class="text-sm font-bold flex items-center justify-between gap-2 mb-4">
                    <span class="flex items-center gap-2">
                      <.icon name="hero-user-group" class="size-4.5 text-primary-standalone" />
                      <%!-- zh_CN: Agent → "智能体" --%>{gettext("Agents Spawned")}
                    </span>
                    <%= if @task.model_id do %>
                      <span class="text-xs font-medium text-base-content/70">
                        {gettext("Model")}: {@task.model_id}
                      </span>
                    <% end %>
                  </h4>
                  <div class="flex items-center gap-3">
                    <span class="text-2xl font-bold text-primary-standalone">{format_number(
                      @task.agent_count
                    )}</span>
                    <span class="text-xs text-base-content/70"><%!-- zh_CN: agent → "智能体" --%>{gettext(
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
                <% logs_preview = log_preview(Map.get(@task, :logs)) %>
                <% log_count = logs_preview.total %>
                <details class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors group/logs">
                  <summary class="cursor-pointer text-sm font-bold flex items-center gap-2 select-none outline-none">
                    <.icon
                      name="hero-command-line"
                      class="size-4.5 text-base-content/70 group-hover/logs:text-primary-standalone transition-colors"
                    />
                    {gettext("Execution Logs")}
                    <span class="text-xs font-medium bg-base-200 text-base-content/70 px-2 py-0.5 rounded-md ml-2">
                      {log_summary_label(log_count)}
                    </span>
                  </summary>
                  <%= if logs_preview.truncated? do %>
                    <p class="text-xs text-base-content/60 mt-3">
                      <%!-- zh_CN: log entries → "日志条目"（日志被截断时的说明） --%>{gettext(
                        "Showing the last %{shown} of %{total} log entries",
                        shown: format_number(length(logs_preview.items)),
                        total: format_number(logs_preview.total)
                      )}
                    </p>
                  <% end %>
                  <div class="bg-base-200 text-base-content p-4 rounded-md max-h-72 overflow-y-auto text-xs font-mono space-y-1 mt-4 shadow-inner">
                    <%= for {log, idx} <- Enum.with_index(logs_preview.items) do %>
                      <div class={[
                        "flex items-start gap-3 p-1.5 rounded transition-colors",
                        rem(idx, 2) == 0 && "bg-base-content/5",
                        log.level == :error && "bg-error/15 text-error",
                        log.level == :warn && "bg-warning/15 text-warning"
                      ]}>
                        <span class="text-base-content/60 shrink-0 select-none">
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
  # Private helpers — structured failure record (`error`) guarded reads
  # ---------------------------------------------------------------------------
  #
  # Failed tasks persist a structured error record on the decoded TaskInfo
  # `error` field: `%{kind:, source:, message:, stacktrace:}` — ATOM keys after
  # the lenient Store Codec decode (`Codec.decode_error/1`, applied to BOTH the
  # full `%TaskInfo{}` path and the 16-key summary projection); nil unless
  # `status == :failed`. This is a NEW record SEPARATE from the legacy
  # `{:error, _}` task RESULT rendered by render_result/2 — a failed task may
  # carry either, both, or neither. Every read below is guarded and
  # atom/string-key tolerant: legacy failed rows (`error` nil/non-map) and all
  # non-failed statuses return nil, so every render site stays byte-identical
  # to the pre-feature behavior for them.

  # Returns the structured error map only when the task is failed AND the
  # `error` value is a map; nil otherwise (legacy rows, non-failed statuses,
  # bad shapes — summary maps and full structs both safe).
  defp task_error(task) do
    with true <- is_map(task),
         true <- Map.get(task, :status) in [:failed, "failed"],
         error when is_map(error) <- Map.get(task, :error) do
      error
    else
      _ -> nil
    end
  end

  # Atom/string-key tolerant read of one error-record field (the Codec emits
  # atom keys, but some consumer paths may hand string-keyed maps).
  defp error_field(error, key) do
    Map.get(error, key) || Map.get(error, to_string(key))
  end

  # `message` is a String.t() by contract, but decoded data is untrusted —
  # only non-empty binaries are usable; nil otherwise (graceful fallback).
  defp error_message(error) do
    case error_field(error, :message) do
      message when is_binary(message) and message != "" -> message
      _ -> nil
    end
  end

  # `stacktrace` is [String.t()] by contract; defensively keep only binary
  # frames and show the LAST ≤8 (most recent) frames in the expanded block.
  defp error_stacktrace(error) do
    case error_field(error, :stacktrace) do
      frames when is_list(frames) ->
        case Enum.filter(frames, &is_binary/1) do
          [] -> nil
          frames -> Enum.take(frames, -8)
        end

      _ ->
        nil
    end
  end

  # Collapsed-line text: the truncated error.message (~160 chars); when the
  # message is not a usable binary, fall back to the kind label so a failed
  # card without a message still communicates why it failed.
  defp collapsed_error_text(error) do
    case error_message(error) do
      nil -> task_error_kind_label(error_field(error, :kind))
      message -> truncate_string(message, 160)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers — accent color for task_card status bar
  # ---------------------------------------------------------------------------

  # Top accent bar color for the task-card status bar — delegates to the
  # shared semantic dot mapping (LOCKED task-status table: transitional/busy →
  # warning amber, completed → success, failed → error, pending/cancelled →
  # neutral gray). Review-status overrides for completed tasks are handled in
  # task_accent_color/1 (a distinct review-outcome dimension).
  defp status_accent_color(status), do: task_status_dot_class(status)

  defp task_accent_color(%{status: :completed, review_status: :merged}), do: "bg-success"
  defp task_accent_color(%{status: :completed, review_status: :rejected}), do: "bg-error"
  defp task_accent_color(%{status: :completed, review_status: :continued}), do: "bg-secondary"
  defp task_accent_color(%{status: :completed, review_status: :ignored}), do: "bg-base-300"
  defp task_accent_color(%{status: status}), do: status_accent_color(status)

  # Card tint — completed+review_status variants stay distinct (review
  # outcome is a separate semantic dimension); every other task status
  # delegates to the shared semantic tint (LOCKED mapping).
  defp task_card_tint(%{status: :completed, review_status: :merged}),
    do: "bg-success/5 shadow-success/10 border-success/20"

  defp task_card_tint(%{status: :completed, review_status: :rejected}),
    do: "bg-error/5 shadow-error/10 border-error/20"

  defp task_card_tint(%{status: :completed, review_status: :continued}),
    do: "bg-secondary/5 shadow-secondary/10 border-secondary/20"

  defp task_card_tint(%{status: :completed, review_status: :ignored}),
    do: "bg-base-200/40 shadow-base-300/10 border-base-300/20"

  defp task_card_tint(%{status: status}), do: task_status_tint(status)

  # ---------------------------------------------------------------------------
  # Private helpers — bounded in-card payload previews
  # ---------------------------------------------------------------------------
  #
  # The EXPANDED card must never hand a multi-MB blob (or an unbounded list) to
  # the template: one live task carried a 108 MB `result` and a 108 MB
  # `archive_metadata`, and interpolating the raw value froze the browser/server
  # on every rerender (a rerender happens on each debounced task reload while
  # the card stays expanded). Every in-card text payload therefore renders a
  # CAPPED preview (`Helpers.blob_preview/2`) plus a dim byte-count note, and
  # the logs list renders only its newest `@in_card_log_limit` entries.
  #
  # `truncate: false` is deliberately NOT capped: that is the Full Result /
  # Full Objective MODAL path (`render_result_full/1` / `render_options_full/1`),
  # reached only by an explicit user action (`view_full_result` /
  # `view_full_options`) and scrolled by the modal's own container.
  @in_card_blob_limit 16_384
  @in_card_log_limit 200
  @copy_payload_limit 1_048_576

  # Text preview for an in-card payload; `text` is already stringified by the
  # caller (a binary result, or `inspect/2` of a non-binary term).
  defp text_preview(text, true), do: blob_preview(text, @in_card_blob_limit)

  defp text_preview(text, false) when is_binary(text),
    do: %{text: text, truncated?: false, total_bytes: byte_size(text)}

  defp text_preview(_text, false), do: %{text: "", truncated?: false, total_bytes: 0}

  # Newest-first capped view of the task's logs: one reverse pass, then
  # `Helpers.list_preview/2` (also yields the total, so no extra `length/1`).
  # Total for nil/non-list, so a malformed `logs` value yields no rows instead
  # of crashing `Enum.reverse/1`.
  defp log_preview(logs) when is_list(logs),
    do: list_preview(Enum.reverse(logs), @in_card_log_limit)

  defp log_preview(_logs), do: %{items: [], total: 0, truncated?: false}

  # Summary-badge label for the logs section — the "shown" number MUST match the
  # rendered cap (`@in_card_log_limit`, the same limit the body honours), so the
  # badge never contradicts the visible rows. `count` stays the TOTAL entries.
  defp log_summary_label(count) when is_integer(count) and count > @in_card_log_limit do
    # zh_CN: 日志摘要（只显示最后 N 条，N 与正文实际渲染条数一致）
    gettext("last %{shown} of %{count}", shown: @in_card_log_limit, count: count)
  end

  defp log_summary_label(count), do: gettext("%{count}", count: count)

  # The card's Copy buttons hand their payload to the ClipboardCopy hook through
  # `data-content`, which IS materialized in the rendered HTML — so it must be
  # bounded like the visible body: 1 MiB keeps every normal result/objective
  # verbatim while a pathological blob stays reachable via the explicit Full
  # Result / Full Objective modal. `text` is already stringified by the caller.
  defp copy_payload(text), do: blob_preview(text, @copy_payload_limit)

  # Only a TRUNCATED payload gets a title explaining the cap; a complete payload
  # renders no title at all (nil attributes are omitted from the markup).
  defp copy_payload_title(%{truncated?: true}),
    do: gettext("Copy is limited to the first 1 MB — open Full for the complete text")

  defp copy_payload_title(_payload), do: nil

  # Dim "showing X of Y" note — rendered ONLY when a preview actually dropped
  # bytes (a complete payload renders no note at all).
  attr(:preview, :map, required: true)

  defp preview_limit_note(assigns) do
    ~H"""
    <p :if={@preview.truncated?} class="text-xs text-base-content/60 mt-2">
      <%!-- zh_CN: bytes → "字节"（预览被截断时的说明） --%>{gettext(
        "Showing %{shown} of %{total} bytes",
        shown: format_number(byte_size(@preview.text)),
        total: format_number(@preview.total_bytes)
      )}
    </p>
    """
  end

  # ---------------------------------------------------------------------------
  # Public helpers — render_options/2
  # ---------------------------------------------------------------------------

  @doc """
  Returns the objective text for a task's opts (the `:prompt`, falling back to
  `:objective`), trimmed of surrounding whitespace. Shared by the collapsed-card
  preview, the expanded Objective card (including its copy button), and
  `render_options/2`.

  Deliberately returns the COMPLETE text — the card's Copy button bounds it at
  render time (`copy_payload/1`, 1 MiB cap on the HTML-materialized
  `data-content`), while the in-card RENDERING path (`render_options/2` with
  `truncate: true`) caps it to a preview.
  """
  def objective_text(opts) do
    (opts[:prompt] || opts[:objective] || "") |> String.trim()
  end

  def render_options(opts, render_opts \\ []) do
    # `truncate: true` = the expanded-card body (scrollable, CAPPED preview);
    # `truncate: false` = the zoomed Full Objective modal (own container
    # scrolls, full text).
    truncate = Keyword.get(render_opts, :truncate, true)
    primary_text = objective_text(opts)
    mode = opts[:mode] || ""
    path = opts[:path] || ""

    assigns = %{
      primary_text: text_preview(primary_text, truncate),
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
          {@primary_text.text}
        </div>
        <.preview_limit_note preview={@primary_text} />
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

  # `truncate: false` = the Full Objective MODAL body: the complete, uncapped
  # objective text — reached only by an explicit user action
  # (`view_full_options`) and scrolled by the modal's own container.
  def render_options_full(opts) do
    render_options(opts, truncate: false)
  end

  # ---------------------------------------------------------------------------
  # Public helpers — result_repos/1 (multi-repo "repos" result key)
  # ---------------------------------------------------------------------------

  @doc """
  Normalizes the `repos` result key into a deterministic list of per-repo
  entries `%{id:, commit_sha:, branch_name:}` — the `"primary"` repo first,
  then writable foreign repos sorted by id. Returns `nil` when the result
  carries no usable `repos` map (legacy results, error/crash results, summary
  maps) so callers can guard with `if repos = result_repos(...) do` and render
  nothing — legacy behavior stays byte-identical.

  Shape notes (see `EvoGit.Runtime.Helpers.report_map/5` + the Store Codec):
  the `repos` value is `%{repo_id => %{"commit_sha" => sha, "branch_name" =>
  branch | nil}}` with STRING keys — after the `EvoGit.Store.Codec` round trip
  the top-level `"repos"` key is NOT in `@result_data_fields`, so it stays a
  string key with string-keyed inner maps (unknown keys are never atomized).
  Both atom and string keys are read defensively so in-memory (pre-encode)
  results work identically. Non-map entries are dropped; `branch_name` nil
  means "no changes" for the primary repo (or a failed branch creation for a
  foreign repo).
  """
  def result_repos({:ok, data}) when is_map(data), do: result_repos(data)

  def result_repos(data) when is_map(data) do
    case Map.get(data, :repos) || Map.get(data, "repos") do
      repos when is_map(repos) and map_size(repos) > 0 ->
        entries =
          Enum.flat_map(repos, fn
            {id, entry} when is_map(entry) ->
              [
                %{
                  id: to_string(id),
                  commit_sha: Map.get(entry, :commit_sha) || Map.get(entry, "commit_sha"),
                  branch_name: Map.get(entry, :branch_name) || Map.get(entry, "branch_name")
                }
              ]

            _ ->
              []
          end)

        case entries do
          [] -> nil
          entries -> primary_first(entries)
        end

      _ ->
        nil
    end
  end

  def result_repos(_), do: nil

  # `"primary"` first (contract: always present), then foreign repos sorted by
  # id for deterministic rendering.
  defp primary_first(entries) do
    {primary, foreign} = Enum.split_with(entries, &(&1.id == "primary"))
    primary ++ Enum.sort_by(foreign, & &1.id)
  end

  attr(:repos, :list, required: true)
  attr(:size_class, :string, default: "text-xs")

  @doc """
  Renders the per-repo commit/branch badges for a task result carrying the
  `repos` key (see `result_repos/1`): one compact row per repo —
  `id: <short_sha> (<branch>)` — primary first, foreign repos sorted by id.
  A nil branch renders just the short sha, plus a muted "no changes" hint for
  the primary repo (its nil branch means the primary produced no commits).
  """
  def result_repos_badges(assigns) do
    ~H"""
    <div class={["flex flex-wrap items-center gap-x-3 gap-y-1.5", @size_class]}>
      <%= for repo <- @repos do %>
        <span class="inline-flex items-center gap-1.5 min-w-0">
          <span class="badge badge-ghost font-mono font-medium">
            {repo.id}:
          </span>
          <%= if repo.commit_sha do %>
            <span class="badge badge-ghost font-mono">
              <.icon name="hero-code-bracket" class="size-3 mr-1 opacity-60" />
              {String.slice(repo.commit_sha, 0..6)}
            </span>
          <% end %>
          <%= if repo.branch_name do %>
            <span class={branch_badge_class()}>
              <.icon name="hero-code-bracket-square" class="size-3 mr-1 shrink-0" />
              <span class="truncate min-w-0">{repo.branch_name}</span>
            </span>
          <% else %>
            <%= if repo.id == "primary" do %>
              <span class="badge badge-ghost font-mono opacity-60">
                <%!-- zh_CN: 主仓库本次无改动 --%>{gettext("no changes")}
              </span>
            <% end %>
          <% end %>
        </span>
      <% end %>
    </div>
    """
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
    # `truncate: true` = expanded-card body (capped preview of the inspected
    # reason); `truncate: false` = zoomed view (the modal's own container
    # scrolls, full text).
    truncate = Keyword.get(opts, :truncate, true)
    size_class = if truncate, do: "text-xs", else: "text-sm"
    scroll_class = if truncate, do: "max-h-48 overflow-y-auto", else: ""

    wrapper_class =
      if truncate,
        do: "bg-error/10 border border-error/20 p-3 rounded-lg",
        else: "bg-error/10 border border-error/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto"

    assigns = %{
      reason: text_preview(inspect(reason, limit: :infinity), truncate),
      size_class: size_class,
      wrapper_class: wrapper_class,
      scroll_class: scroll_class
    }

    ~H"""
    <div class={@wrapper_class}>
      <h5 class="text-xs font-bold text-error mb-2 uppercase tracking-wide flex items-center gap-1.5">
        <.icon name="hero-x-circle" class="size-3" /> {gettext("Error")}
      </h5>
      <pre class={["whitespace-pre-wrap break-words", @size_class, @scroll_class]}><%= @reason.text %></pre>
      <.preview_limit_note preview={@reason} />
    </div>
    """
  end

  def render_result({:exit, reason}, opts) do
    # `truncate: true` = expanded-card body (capped preview of the inspected
    # reason); `truncate: false` = zoomed view (the modal's own container
    # scrolls, full text).
    truncate = Keyword.get(opts, :truncate, true)
    size_class = if truncate, do: "text-xs", else: "text-sm"
    scroll_class = if truncate, do: "max-h-48 overflow-y-auto", else: ""

    wrapper_class =
      if truncate,
        do: "bg-error/10 border border-error/20 p-3 rounded-lg",
        else: "bg-error/10 border border-error/20 rounded-lg p-4 max-h-[70vh] overflow-y-auto"

    assigns = %{
      reason: text_preview(inspect(reason, limit: :infinity), truncate),
      size_class: size_class,
      wrapper_class: wrapper_class,
      scroll_class: scroll_class
    }

    ~H"""
    <div class={@wrapper_class}>
      <h5 class="text-xs font-bold text-error mb-2 uppercase tracking-wide flex items-center gap-1.5">
        <.icon name="hero-x-circle" class="size-3" /> {gettext("Crashed")}
      </h5>
      <pre class={["whitespace-pre-wrap break-words", @size_class, @scroll_class]}><%= @reason.text %></pre>
      <.preview_limit_note preview={@reason} />
    </div>
    """
  end

  def render_result(%{result: result, no_changes: true} = data, opts) when is_binary(result) do
    truncate = Keyword.get(opts, :truncate, true)

    assigns = %{
      result: text_preview(result, truncate),
      repos: result_repos(data),
      truncate: truncate
    }

    ~H"""
    <div class={if @truncate, do: "space-y-3", else: "space-y-4"}>
      <%= if @truncate do %>
        <div class="bg-base-100 p-3 rounded-lg border border-base-200 shadow-inner">
          <div class="text-sm whitespace-pre-wrap break-words max-h-48 overflow-y-auto">
            {@result.text}
          </div>
          <.preview_limit_note preview={@result} />
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
          <pre class="text-sm whitespace-pre-wrap break-words"><%= @result.text %></pre>
        </div>
      <% end %>
      <%= if @repos do %>
        <div>
          <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
            <.icon name="hero-server-stack" class="size-3" />
            <%!-- zh_CN: 各仓库（主仓库与可写外部仓库）的提交与分支 --%>{gettext(
              "Repositories"
            )}
          </h5>
          <EvoDashWeb.TaskCardComponents.result_repos_badges
            repos={@repos}
            size_class={if @truncate, do: "text-xs", else: "text-sm"}
          />
        </div>
      <% end %>
    </div>
    """
  end

  def render_result(%{result: result, commit_sha: commit_sha} = data, opts)
      when is_binary(result) do
    truncate = Keyword.get(opts, :truncate, true)

    assigns = %{
      result: text_preview(result, truncate),
      commit_sha: commit_sha,
      tag: Map.get(data, :tag),
      branch_name: Map.get(data, :branch_name),
      pr_url: Map.get(data, :pr_url),
      repos: result_repos(data),
      truncate: truncate
    }

    ~H"""
    <div class={if @truncate, do: "space-y-3", else: "space-y-4"}>
      <%= if !@truncate do %>
        <div class="flex flex-wrap gap-2 mb-4">
          <%= if @branch_name do %>
            <span class={[branch_badge_class(), "text-sm"]}>
              <.icon name="hero-code-bracket-square" class="size-4 mr-1 shrink-0" />
              <span class="truncate min-w-0">{@branch_name}</span>
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
        <%= if @repos do %>
          <div class="mb-4">
            <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
              <.icon name="hero-server-stack" class="size-3" />
              <%!-- zh_CN: 各仓库（主仓库与可写外部仓库）的提交与分支 --%>{gettext(
                "Repositories"
              )}
            </h5>
            <EvoDashWeb.TaskCardComponents.result_repos_badges repos={@repos} size_class="text-sm" />
          </div>
        <% end %>
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
            {@result.text}
          </div>
          <.preview_limit_note preview={@result} />
        <% else %>
          <pre class="text-sm whitespace-pre-wrap break-words"><%= @result.text %></pre>
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
            <span class={branch_badge_class()}>
              <.icon name="hero-code-bracket-square" class="size-3 mr-1 shrink-0" />
              <span class="truncate min-w-0">{@branch_name}</span>
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
        <%= if @repos do %>
          <div>
            <h5 class="text-xs font-bold text-base-content/70 mb-2 uppercase tracking-wide flex items-center gap-1.5">
              <.icon name="hero-server-stack" class="size-3" />
              <%!-- zh_CN: 各仓库（主仓库与可写外部仓库）的提交与分支 --%>{gettext(
                "Repositories"
              )}
            </h5>
            <EvoDashWeb.TaskCardComponents.result_repos_badges repos={@repos} />
          </div>
        <% end %>
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
      result: text_preview(inspect(result, pretty: true, limit: :infinity), truncate),
      size_class: size_class,
      wrapper_class: wrapper_class,
      scroll_class: scroll_class
    }

    ~H"""
    <pre class={["overflow-x-auto", @size_class, @wrapper_class, @scroll_class]}><%= @result.text %></pre>
    <.preview_limit_note preview={@result} />
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
      result: text_preview(inspect(result, pretty: true, limit: :infinity), truncate),
      size_class: size_class,
      wrapper_class: wrapper_class,
      scroll_class: scroll_class
    }

    ~H"""
    <pre class={["overflow-x-auto", @size_class, @wrapper_class, @scroll_class]}><%= @result.text %></pre>
    <.preview_limit_note preview={@result} />
    """
  end

  # ---------------------------------------------------------------------------
  # Public API — render_result_full/1 renders full task result without truncation
  # ---------------------------------------------------------------------------

  # `truncate: false` = the Full Result MODAL body: THE complete, uncapped text
  # (no byte cap, no limit note) — reached only by an explicit user action
  # (`view_full_result`) and scrolled by the modal's own container.
  def render_result_full(assigns) do
    render_result(assigns, truncate: false)
  end

  @doc """
  Returns the copyable plain-text representation of a task result value.

  Used by both the unzoomed "Agent Message" card copy button and the zoomed
  Full Result modal copy button (`tasks_live.ex`). Success/no-changes results
  copy the raw agent message; error/crash results copy the inspected reason
  (unlimited); anything else falls back to a pretty-inspected representation.

  Deliberately returns the COMPLETE text — this function itself never truncates
  so the Full Result modal (`tasks_live.ex`) can copy the whole thing. The
  in-card copy button deliberately does NOT use the raw value: it bounds its
  HTML-materialized `data-content` through `copy_payload/1` (1 MiB) and renders
  only a preview in the body (`render_result/2` with `truncate: true`).
  """
  def result_copy_text({:ok, %{result: result}}) when is_binary(result), do: result
  def result_copy_text({:error, reason}), do: inspect(reason, limit: :infinity)
  def result_copy_text({:exit, reason}), do: inspect(reason, limit: :infinity)
  def result_copy_text(%{result: result}) when is_binary(result), do: result
  def result_copy_text(result), do: inspect(result, pretty: true, limit: :infinity)

  # Shared truncation classes for branch-name badges (all 3 render sites).
  # daisyUI `.badge` is `display: inline-flex; width: fit-content` with no
  # wrapping, so a long unbreakable branch name (`genesis/agent_<id>`) would
  # force the badge wider than the card. `min-w-0` lets the badge (a flex
  # item) shrink below its content width, the responsive `max-w-*` caps it at
  # narrow widths only (`md:max-w-none` = full name on desktop), and the text
  # itself is wrapped in a `truncate` span — text-overflow ellipsis does NOT
  # apply on the flex badge container itself, only on a block container.
  defp branch_badge_class do
    "badge badge-primary font-mono min-w-0 max-w-[10rem] sm:max-w-[14rem] md:max-w-none"
  end

  # Review candidacy is deliberately RESULT-AGNOSTIC: EVERY completed/cancelled
  # task is reviewable. A task may have made no changes in its PRIMARY repo but
  # did change writable FOREIGN repos (multi-repo), so detecting a non-empty
  # branch_name / `no_changes` here would hide legitimate review candidates.
  # The only exclusion is `:reflect` (repo-less) tasks — no code to review.
  # `:type` is read defensively (`Map.get/2`) so summary maps without it stay
  # KeyError-safe.
  defp show_review_button?(%{status: :completed} = task), do: Map.get(task, :type) != :reflect

  defp show_review_button?(%{status: :cancelled} = task), do: Map.get(task, :type) != :reflect

  defp show_review_button?(_), do: false
end
