defmodule EvoDashWeb.TaskCardComponents do
  @moduledoc """
  The dashboard's task card — the `task_card/1` HEEx template plus its
  presentation helpers (status/tint/accent mapping, bounded in-card previews,
  review candidacy).

  ## Where the rest of the card helpers live

  The cohesive helper families behind the card live in
  `EvoDashWeb.TaskCardComponents.*` submodules:

    * `TaskCardComponents.Options` — `objective_text/1`, `render_options/1,2`,
      `render_options_full/1`;
    * `TaskCardComponents.ResultRender` — `render_result/1,2`,
      `render_result_full/1`, `result_copy_text/1`;
    * `TaskCardComponents.Repos` — `result_repos/1`, `task_repos/2`,
      `result_repos_badges/1`;
    * `TaskCardComponents.Archive` — the lazy archive-envelope readers;
    * `TaskCardComponents.Errors` — the structured failure-record readers.

  Every public function of those submodules is re-exported here through
  `defdelegate`, so call sites keep using `EvoDashWeb.TaskCardComponents.<fun>`;
  the submodule readers this template calls directly are imported below.

  ## Card inputs — summary map + lazily-fetched detail

  `task_card/1` is fed the lightweight 16-key task SUMMARY map
  (`id, status, review_status, started_at, finished_at, type, project_path,
  opts, branch_name, model_id, agent_count, base_sha, commit_sha,
  lease_expires_at, updated_at, error`). It deliberately carries NO
  `result` / `usage` / `logs` / `archive_metadata` — those heavy payloads
  arrive separately through the `detail` attr (see below), so a big task blob
  never rides a task-list render.

  `detail` is `nil` (not requested yet) or:

      %{state: :loading | :ok | :error,
        task: %EvoGit.TaskInfo{} | nil,      # only meaningful when state == :ok
        error: term() | nil,                 # only when state == :error
        seq: pos_integer(),
        archive: nil | %{state: :loading | :ok | :error,
                          entries: [map()], total: non_neg_integer(),
                          next_offset: non_neg_integer(),
                          loading_more?: boolean(), more_error: term() | nil,
                          error: term() | nil, seq: pos_integer(),
                          agent_results: %{agent_id => %{state:, entry:, error:}}}}

  Only the EXPANDED view reads `detail.task`; the collapsed card renders from
  the summary alone (`task_repos/2` derives its repo badges from the summary's
  `commit_sha`/`branch_name` + `opts[:foreign_repos]`, enriched by the detail
  result's `repos` map when it has landed).

  ## Why the preview helpers stay HERE

  The card template and its bounded-preview helpers (`text_preview/2`,
  `log_preview/1`, `copy_payload/1`, the byte/row caps) are one contract: the
  caps exist precisely because this template interpolates the payloads, so
  they live together instead of being spread across modules. The moved
  result/option renderers reuse them through this module (see below).
  """

  # zh_CN: Agent → "智能体", Token → "词元"

  use EvoDashWeb, :html

  alias EvoDashWeb.TaskCardComponents.{Options, Repos, ResultRender}

  # Card readers implemented in the submodules and called directly by the
  # template below.
  import EvoDashWeb.TaskCardComponents.Archive,
    only: [
      archive_state: 1,
      archive_records: 1,
      archive_total: 1,
      archive_dropped: 1,
      archive_exhausted?: 1,
      archive_server_total: 1,
      archive_agent_results: 1,
      archive_loading_more?: 1,
      archive_more_error: 1,
      archive_opt?: 1
    ]

  import EvoDashWeb.TaskCardComponents.Errors,
    only: [
      task_error: 1,
      error_field: 2,
      error_message: 1,
      error_stacktrace: 1,
      collapsed_error_text: 1
    ]

  # ---------------------------------------------------------------------------
  # task_card/1 — Compact card with accent bar, relative timestamps
  # ---------------------------------------------------------------------------

  attr(:task, :map, required: true)
  attr(:show_details, :boolean, default: false)
  attr(:current_node_id, :any, default: nil)
  # nil | %{state: :loading | :ok | :error, task:, error:, seq:, archive:} —
  # the lazily-fetched heavy payload (see the moduledoc). nil = not loaded.
  attr(:detail, :map, default: nil)

  def task_card(assigns) do
    ~H"""
    <%!-- `lite` = the lazily-fetched FULL %TaskInfo{} (result/usage/logs/
         archive_metadata). nil until the detail load succeeds — the expanded
         heavy sections are gated on it, so the card NEVER dot-accesses a nil
         detail. `archive` = the separately-fetched archive records envelope. --%>
    <% lite =
      case @detail do
        %{state: :ok, task: task} when is_map(task) -> task
        _ -> nil
      end %>
    <% archive =
      case @detail do
        %{archive: archive} when is_map(archive) -> archive
        _ -> nil
      end %>
    <% detail_state =
      case @detail do
        %{state: state} -> state
        _ -> nil
      end %>
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
             section). Derived by `task_repos/2`: primary repo from the SUMMARY
             (`commit_sha`/`branch_name`), foreign repos from the summary's
             `opts[:foreign_repos]`, optionally enriched by the detail result's
             `repos` map once it has landed. nil (single-repo tasks, legacy
             rows) renders nothing. -->
        <% collapsed_repos = if @show_details, do: nil, else: task_repos(@task, @detail) %>
        <%= if collapsed_repos do %>
          <div class="-mt-3">
            <EvoDashWeb.TaskCardComponents.result_repos_badges repos={collapsed_repos} />
          </div>
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
                <%!-- The result lives on the lazily-fetched FULL TaskInfo
                     (`detail.task`), never on the summary map — so this grid
                     cell simply does not render until the detail load lands. --%>
                <% card_result = if lite, do: Map.get(lite, :result), else: nil %>
                <%= if card_result do %>
                  <!-- Agent Message card — full result content (scrollable) + badges -->
                  <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
                    <div class="flex items-center justify-between mb-4">
                      <h4 class="text-sm font-bold flex items-center gap-2">
                        <.icon name="hero-chat-bubble-left-ellipsis" class="size-4.5 text-success" />
                        <%!-- zh_CN: 智能体的最终消息 --%>{gettext("Agent Message")}
                      </h4>
                      <div class="flex items-center gap-2">
                        <% result_copy = copy_payload(result_copy_text(card_result)) %>
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
                    {render_result(card_result)}
                  </div>
                <% end %>
              </div>

              <%!-- Heavy sections below (usage / agents / logs / archive) all
                   need the lazily-fetched FULL TaskInfo (`detail.task`). While
                   it is missing we render exactly ONE compact placeholder:
                   the retry-able error strip when the load FAILED, otherwise a
                   spinner — never an endless silent gap, never a crash. --%>
              <%= cond do %>
                <% detail_state == :error -> %>
                  <div
                    id={"task-#{@task.id}-detail-error"}
                    class="flex items-center gap-2 bg-error/10 border border-error/20 rounded-lg px-3 py-2 min-w-0"
                  >
                    <.icon name="hero-exclamation-triangle" class="size-4 text-error shrink-0" />
                    <span class="text-xs font-medium text-error truncate min-w-0">
                      {gettext("Could not load task details.")}
                    </span>
                    <button
                      class="btn btn-xs btn-ghost rounded-md ml-auto shrink-0"
                      phx-click="retry_task_detail"
                      phx-value-task_id={@task.id}
                    >
                      <.icon name="hero-arrow-path" class="size-3.5 mr-1" /> {gettext("Retry")}
                    </button>
                  </div>
                <% lite == nil -> %>
                  <div
                    id={"task-#{@task.id}-detail-loading"}
                    class="flex items-center gap-2 bg-base-200/40 border border-base-200/80 rounded-lg px-3 py-2"
                  >
                    <span class="loading loading-spinner loading-xs text-base-content/60 shrink-0"></span>
                    <span class="text-xs font-medium text-base-content/70">
                      {gettext("Loading task details…")}
                    </span>
                  </div>
                <% true -> %>
                  <% usage = Map.get(lite, :usage) %>
                  <%= if usage do %>
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
                            {format_number(usage.input_tokens)}
                          </div>
                        </div>
                        <div>
                          <div class="text-xs text-base-content/70 mb-1">
                            <%!-- zh_CN: Token → "词元" --%>{gettext("Output Tokens")}
                          </div>
                          <div class="text-sm font-semibold">
                            {format_number(usage.output_tokens)}
                          </div>
                        </div>
                        <div>
                          <div class="text-xs text-base-content/70 mb-1">
                            <%!-- zh_CN: Token → "词元" --%>{gettext("Total Tokens")}
                          </div>
                          <div class="text-sm font-semibold">
                            {format_number(usage.total_tokens)}
                          </div>
                        </div>
                      </div>
                      <%= if Map.get(usage, :cached_tokens, 0) > 0 or Map.get(usage, :cache_creation_tokens, 0) > 0 do %>
                        <div class="mt-4 pt-4 border-t border-base-200">
                          <div class="grid grid-cols-3 gap-3">
                            <div>
                              <div class="text-xs text-base-content/70 mb-1">
                                <%!-- zh_CN: Token → "词元" --%>{gettext("Cached Tokens")}
                              </div>
                              <div class="text-sm font-semibold">
                                {format_number(Map.get(usage, :cached_tokens, 0))}
                              </div>
                            </div>
                            <div>
                              <div class="text-xs text-base-content/70 mb-1">
                                {gettext("Cache Creation")}
                              </div>
                              <div class="text-sm font-semibold">
                                {format_number(Map.get(usage, :cache_creation_tokens, 0))}
                              </div>
                            </div>
                            <div>
                              <div class="text-xs text-base-content/70 mb-1">
                                {gettext("Cache Hit Rate")}
                              </div>
                              <div class="text-sm font-semibold text-success">
                                {format_cache_hit_rate(usage)}
                              </div>
                              <progress
                                class="progress progress-success w-full mt-1"
                                value={
                                  if usage.input_tokens > 0,
                                    do:
                                      min(
                                        round(
                                          Map.get(usage, :cached_tokens, 0) /
                                            usage.input_tokens * 100
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
                            <div class="text-xs text-base-content/70 mb-1">
                              {gettext("Input Cost")}
                            </div>
                            <div class="text-sm font-semibold">
                              ${format_cost(usage.input_cost)}
                            </div>
                          </div>
                          <div>
                            <div class="text-xs text-base-content/70 mb-1">
                              {gettext("Output Cost")}
                            </div>
                            <div class="text-sm font-semibold">
                              ${format_cost(usage.output_cost)}
                            </div>
                          </div>
                          <div>
                            <div class="text-xs text-base-content/70 mb-1">
                              {gettext("Total Cost")}
                            </div>
                            <div class="text-sm font-semibold text-primary-standalone">
                              ${format_cost(usage.total_cost)}
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
                    logs live on the FULL %TaskInfo{} (`detail.task`) — never on
                    the summary map. Map.get keeps this total; the section is
                    only reached when `lite` is present anyway.
                  --%>
                  <% logs = Map.get(lite, :logs) %>
                  <%= if logs not in [nil, []] do %>
                    <% logs_preview = log_preview(logs) %>
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

                  <%!--
                    Archive — LAZY, PAGED disclosure. The summary map cannot tell
                    whether archive records exist, so the section appears when
                    the task was started with the `:archive` opt
                    (`opts[:archive]`) OR when the archive has already been
                    fetched. The FIRST page (100 entries, results omitted) is
                    loaded on demand via the `load_task_archive` event (button
                    below); further pages append through
                    `load_more_task_archive` and one agent's result through
                    `load_task_archive_agent_result` — both fired from
                    ArchiveComponents' own markup.
                  --%>
                  <%= if archive_opt?(@task.opts) or archive != nil do %>
                    <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
                      <div class="flex items-center justify-between gap-2">
                        <h4 class="text-sm font-bold flex items-center gap-2">
                          <.icon name="hero-archive-box" class="size-4.5 text-base-content/70" />
                          <%!-- zh_CN: Agent → "智能体" --%>{gettext("Archived Agent Details")}
                        </h4>
                        <%= if archive == nil do %>
                          <button
                            class="btn btn-xs btn-ghost rounded-md"
                            phx-click="load_task_archive"
                            phx-value-task_id={@task.id}
                          >
                            <.icon name="hero-archive-box-arrow-down" class="size-3.5 mr-1" />
                            <%!-- zh_CN: 加载并展开归档（按需加载） --%>{gettext(
                              "Show archive"
                            )}
                          </button>
                        <% end %>
                      </div>
                      <%= cond do %>
                        <% archive == nil -> %>
                          <p class="text-xs text-base-content/60 mt-3">
                            <%!-- zh_CN: 归档记录按需加载（点击按钮后才读取） --%>{gettext(
                              "The archive loads on demand."
                            )}
                          </p>
                        <% archive_state(archive) == :loading -> %>
                          <div class="flex items-center gap-2 mt-3">
                            <span class="loading loading-spinner loading-xs text-base-content/60 shrink-0"></span>
                            <span class="text-xs font-medium text-base-content/70">
                              {gettext("Loading archive…")}
                            </span>
                          </div>
                        <% archive_state(archive) == :error -> %>
                          <div class="flex items-center gap-2 bg-error/10 border border-error/20 rounded-lg px-3 py-2 mt-3 min-w-0">
                            <.icon
                              name="hero-exclamation-triangle"
                              class="size-4 text-error shrink-0"
                            />
                            <span class="text-xs font-medium text-error truncate min-w-0">
                              {gettext("Could not load the task archive.")}
                            </span>
                            <button
                              class="btn btn-xs btn-ghost rounded-md ml-auto shrink-0"
                              phx-click="load_task_archive"
                              phx-value-task_id={@task.id}
                            >
                              <.icon name="hero-arrow-path" class="size-3.5 mr-1" /> {gettext("Retry")}
                            </button>
                          </div>
                        <% archive_records(archive) == [] -> %>
                          <p class="text-xs text-base-content/60 mt-3">
                            <%!-- zh_CN: 该任务没有任何已归档的智能体记录 --%>{gettext(
                              "No archived agents for this task."
                            )}
                          </p>
                        <% true -> %>
                          <% records = archive_records(archive) %>
                          <div class="mt-4">
                            <EvoDashWeb.ArchiveComponents.archive_details
                              archive_metadata={records}
                              total={archive_total(archive)}
                              dropped={archive_dropped(archive)}
                              exhausted?={archive_exhausted?(archive)}
                              server_total={archive_server_total(archive)}
                              agent_results={archive_agent_results(archive)}
                              loading_more?={archive_loading_more?(archive)}
                              more_error={archive_more_error(archive)}
                              task_id={@task.id}
                              export_url={
                                with_node_param("/tasks/#{@task.id}/export", @current_node_id)
                              }
                            />
                          </div>
                      <% end %>
                    </div>
                  <% end %>
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
  # caller (a binary result, or `inspect/2` of a non-binary term). Public
  # because the moved renderers (`render_options/2`, `render_result/2`) cap
  # their bodies through it — one cap, one implementation.
  def text_preview(text, true), do: blob_preview(text, @in_card_blob_limit)

  def text_preview(text, false) when is_binary(text),
    do: %{text: text, truncated?: false, total_bytes: byte_size(text)}

  def text_preview(_text, false), do: %{text: "", truncated?: false, total_bytes: 0}

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
  # bytes (a complete payload renders no note at all). Public because the moved
  # renderers render it after their own previews.
  attr(:preview, :map, required: true)

  def preview_limit_note(assigns) do
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
  # Public API re-exported from the `task_card_components/` submodules
  # ---------------------------------------------------------------------------
  #
  # Call sites (`tasks_live.ex`, tests, the card template) keep calling these
  # through `EvoDashWeb.TaskCardComponents`; only the implementations moved.

  defdelegate objective_text(opts), to: Options
  defdelegate render_options(opts), to: Options
  defdelegate render_options(opts, render_opts), to: Options
  defdelegate render_options_full(opts), to: Options

  defdelegate result_repos(data), to: Repos
  defdelegate task_repos(task, detail), to: Repos
  defdelegate result_repos_badges(assigns), to: Repos

  defdelegate render_result(data), to: ResultRender
  defdelegate render_result(data, opts), to: ResultRender
  defdelegate render_result_full(assigns), to: ResultRender
  defdelegate result_copy_text(result), to: ResultRender

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
