defmodule EvoDashWeb.ReviewComponents do
  @moduledoc """
  Components for the code review page — GitHub PR-style tab layout with split diff viewer.

  Facade module: delegates to the `ReviewComponents.*` sub-modules (Header, Actions,
  Stats, DiffViewer, RepoCards) and locally owns the page-level tab bar (`page_tabs/1`)
  and the archive tree (`archive_review_section/1`).
  """

  # zh_CN: Commit → "提交", Agent → "智能体", Token → "词元"

  use EvoDashWeb, :html
  alias EvoDashWeb.ArchiveHelpers

  # Delegates to sub-modules
  defdelegate page_header(assigns), to: EvoDashWeb.ReviewComponents.Header
  defdelegate task_summary(assigns), to: EvoDashWeb.ReviewComponents.Header
  defdelegate agent_summary(assigns), to: EvoDashWeb.ReviewComponents.Header
  defdelegate objective_section(assigns), to: EvoDashWeb.ReviewComponents.Header
  defdelegate repo_cards(assigns), to: EvoDashWeb.ReviewComponents.RepoCards
  defdelegate task_actions(assigns), to: EvoDashWeb.ReviewComponents.Actions
  defdelegate extract_skills_modal(assigns), to: EvoDashWeb.ReviewComponents.Actions
  defdelegate diff_stats_bar(assigns), to: EvoDashWeb.ReviewComponents.Stats
  defdelegate commits_list(assigns), to: EvoDashWeb.ReviewComponents.Stats
  defdelegate file_tree_sidebar(assigns), to: EvoDashWeb.ReviewComponents.DiffViewer
  defdelegate diff_viewer(assigns), to: EvoDashWeb.ReviewComponents.DiffViewer
  defdelegate split_diff_layout(assigns), to: EvoDashWeb.ReviewComponents.DiffViewer
  defdelegate commit_detail_header(assigns), to: EvoDashWeb.ReviewComponents.DiffViewer
  defdelegate commit_diff_layout(assigns), to: EvoDashWeb.ReviewComponents.DiffViewer
  defdelegate conflict_files_summary(files), to: EvoDashWeb.ReviewComponents.Actions

  # ---------------------------------------------------------------------------
  # page_tabs/1 — GitHub-style underline tab bar
  # (Conversation / Objective / Files changed / Commits / Archive)
  # ---------------------------------------------------------------------------

  attr(:active_tab, :atom, required: true)
  attr(:files_count, :integer, default: 0)
  attr(:commits_count, :integer, default: 0)
  attr(:show_archive, :boolean, default: false)
  # The archive's TRUE size (not the agent count); 0/unknown renders no badge.
  attr(:archive_count, :integer, default: 0)

  def page_tabs(assigns) do
    ~H"""
    <div class="flex items-center gap-1 overflow-x-auto scrollbar-none -mx-1 px-1">
      <button
        phx-click="switch_tab"
        phx-value-tab="conversation"
        class={[
          "flex items-center gap-2 px-3 sm:px-4 py-2.5 text-sm whitespace-nowrap border-b-2 transition-colors",
          (@active_tab == :conversation && "border-primary-standalone text-base-content font-semibold") ||
            "border-transparent text-base-content/70 hover:text-base-content hover:border-base-content/30"
        ]}
      >
        <.icon name="hero-chat-bubble-left-right" class="size-4" />
        <%!-- zh_CN: "Conversation" → 对话/总览（评审页首个标签页：智能体报告总览） --%>
        {gettext("Conversation")}
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="objective"
        class={[
          "flex items-center gap-2 px-3 sm:px-4 py-2.5 text-sm whitespace-nowrap border-b-2 transition-colors",
          (@active_tab == :objective && "border-primary-standalone text-base-content font-semibold") ||
            "border-transparent text-base-content/70 hover:text-base-content hover:border-base-content/30"
        ]}
      >
        <.icon name="hero-chat-bubble-bottom-center-text" class="size-4" />
        <%!-- zh_CN: 目标 — 提交给智能体的任务目标（本任务最初指令文本） --%>
        {gettext("Objective")}
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="files_changed"
        class={[
          "flex items-center gap-2 px-3 sm:px-4 py-2.5 text-sm whitespace-nowrap border-b-2 transition-colors",
          (@active_tab == :files_changed &&
             "border-primary-standalone text-base-content font-semibold") ||
            "border-transparent text-base-content/70 hover:text-base-content hover:border-base-content/30"
        ]}
      >
        <.icon name="hero-code-bracket" class="size-4" />
        {gettext("Files changed")}
        <span class="badge badge-sm bg-base-200 text-base-content/70 font-mono ml-0.5">
          {@files_count}
        </span>
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="commits"
        class={[
          "flex items-center gap-2 px-3 sm:px-4 py-2.5 text-sm whitespace-nowrap border-b-2 transition-colors",
          (@active_tab == :commits && "border-primary-standalone text-base-content font-semibold") ||
            "border-transparent text-base-content/70 hover:text-base-content hover:border-base-content/30"
        ]}
      >
        <.icon name="hero-clock" class="size-4" />
        <%!-- zh_CN: "Commits" → 提交 --%>
        {gettext("Commits")}
        <span class="badge badge-sm bg-base-200 text-base-content/70 font-mono ml-0.5">
          {@commits_count}
        </span>
      </button>
      <%= if @show_archive do %>
        <button
          phx-click="switch_tab"
          phx-value-tab="archive"
          class={[
            "flex items-center gap-2 px-3 sm:px-4 py-2.5 text-sm whitespace-nowrap border-b-2 transition-colors",
            (@active_tab == :archive && "border-primary-standalone text-base-content font-semibold") ||
              "border-transparent text-base-content/70 hover:text-base-content hover:border-base-content/30"
          ]}
        >
          <.icon name="hero-archive-box-arrow-down" class="size-4" />
          <%!-- zh_CN: "Archive" → 归档（智能体执行过程存档） --%>
          {gettext("Archive")}
          <span
            :if={@archive_count > 0}
            class="badge badge-sm bg-base-200 text-base-content/70 font-mono ml-0.5"
          >
            {@archive_count}
          </span>
        </button>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # archive_review_section/1 — Archived agent details with recursive tree
  # ---------------------------------------------------------------------------

  # Caps for the archive section. `@archive_max_records` bounds how many records
  # are normalized/grouped into the tree per render; the two byte limits bound
  # the per-agent text interpolated into the template.
  # Paging is the real bound on memory (the page reads 100 entries at a time and
  # never carries an entry's heavy "result" until it is fetched on demand), so
  # this cap only has to keep ONE render cheap — 300 records still render every
  # record's text through the byte caps below. Measured worst case: a single
  # task carried 7,149 agent records / a 108 MB archive.
  @archive_max_records 300
  @archive_objective_preview_bytes 4_096
  @archive_result_preview_bytes 8_192

  attr(:archive_metadata, :list, required: true)
  attr(:task_id, :string, default: nil)
  # The EFFECTIVE total (paging decisions), falling back to the loaded count.
  attr(:total, :integer, default: nil)
  # The archive's TRUE size for the header label, independent of clamping.
  attr(:server_total, :integer, default: nil)
  # Records evicted by the retention window (older rows are no longer loaded).
  attr(:dropped, :integer, default: 0)
  # The archive is exhausted (a short/empty page arrived), so no pager renders.
  attr(:exhausted?, :boolean, default: false)
  attr(:loading_more?, :boolean, default: false)
  attr(:more_error, :any, default: nil)
  attr(:agent_results, :map, default: %{})

  # Optional node-aware export href (carries `?node=<target_id>` when a remote
  # node is viewed); nil falls back to the plain task export path.
  attr(:export_url, :string, default: nil)

  def archive_review_section(assigns) do
    # The record list can be enormous, so cap it BEFORE normalization/grouping
    # and build the review tree exactly ONCE per render.
    capped =
      ArchiveHelpers.build_review_tree_capped(assigns.archive_metadata, @archive_max_records)

    loaded = length(assigns.archive_metadata)

    # `total` drives the PAGING decision (the archive is paged): it falls back to
    # what is loaded when no total was handed in.
    effective_total =
      case assigns.total do
        total when is_integer(total) and total >= 0 -> total
        _other -> loaded
      end

    # The header LABEL shows the archive's true size even when the page is
    # clamped/exhausted, so `server_total` (when known) wins over the effective
    # total.
    label_total =
      case assigns.server_total do
        total when is_integer(total) and total >= 0 -> total
        _other -> effective_total
      end

    {first, last} = ArchiveHelpers.retained_page_bounds(loaded, assigns.dropped, label_total)

    archive_more? =
      not assigns.exhausted? and
        ArchiveHelpers.more_pages?(loaded, assigns.dropped, effective_total)

    assigns =
      assign(assigns,
        archive_tree: capped.tree,
        archive_shown: capped.shown,
        archive_loaded: loaded,
        archive_total: effective_total,
        archive_label_total: label_total,
        archive_first: first,
        archive_last: last,
        archive_truncated?: capped.truncated?,
        archive_more?: archive_more?
      )

    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 overflow-hidden">
      <!-- Header -->
      <div class="flex items-center justify-between gap-3 p-5 md:p-6 border-b border-base-200/50 bg-base-200/20">
        <div class="flex items-center gap-3">
          <.icon name="hero-archive-box-arrow-down" class="size-5 text-base-content/60" />
          <div>
            <%!-- zh_CN: Agent → "智能体" --%>
            <h3 class="font-semibold text-base">{gettext("Archived Agent Details")}</h3>
            <div class="mt-0.5">
              <EvoDashWeb.ArchiveComponents.archive_count_line
                total={@archive_label_total}
                first={@archive_first}
                last={@archive_last}
                dropped={@dropped}
                more?={@archive_more?}
                exhausted?={@exhausted?}
              />
            </div>
          </div>
        </div>
        <%= if @task_id do %>
          <.link
            href={@export_url || "/tasks/#{@task_id}/export"}
            class="btn btn-sm btn-outline btn-primary gap-2"
            download
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />
            {gettext("Export JSON")}
          </.link>
        <% end %>
      </div>

      <!-- Agent tree -->
      <div class="p-4 sm:p-6 space-y-3">
        <%= if @archive_truncated? do %>
          <p class="text-xs text-base-content/60">
            <%!-- zh_CN: “records” → “条智能体记录”；export JSON → 导出 JSON 以查看完整归档 --%>
            {gettext("Showing %{shown} of %{total} agent records — export JSON for the full archive",
              shown: format_number(@archive_shown),
              total: format_number(@archive_loaded)
            )}
          </p>
        <% end %>
        <%= for {agent, children} <- @archive_tree do %>
          <.archive_tree_node
            agent={agent}
            children={children}
            agent_results={@agent_results}
          />
        <% end %>

        <!-- Paging -->
        <%= if @archive_more? do %>
          <div class="pt-2 flex flex-col items-start gap-2">
            <%= if @more_error do %>
              <p class="text-xs text-error">
                <%!-- zh_CN: 追加加载归档记录失败，可重试 --%>
                {gettext("Could not load more archive records.")}
              </p>
              <button
                type="button"
                phx-click="load_more_archive"
                class="btn btn-outline btn-sm gap-2"
              >
                <.icon name="hero-arrow-path" class="size-4" /> {gettext("Retry")}
              </button>
            <% else %>
              <button
                type="button"
                phx-click="load_more_archive"
                disabled={@loading_more?}
                class="btn btn-outline btn-sm gap-2"
              >
                <%= if @loading_more? do %>
                  <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
                  {gettext("Loading…")}
                <% else %>
                  <.icon name="hero-arrow-down" class="size-4" /> {gettext("Load more")}
                <% end %>
              </button>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:agent, :map, required: true)
  attr(:children, :list, default: [])
  attr(:agent_results, :map, default: %{})

  def archive_tree_node(assigns) do
    # A single agent's objective/result can be a multi-megabyte blob (a 108 MB
    # result has been measured), so compute ONE capped preview per field BEFORE
    # the template — neither value is ever interpolated verbatim. The result is
    # absent from a paged entry until its lazy fetch lands, so `@result_view`
    # carries the resolved state (never the raw blob).
    agent_id = node_text(assigns.agent, :agent_id)
    cached = Map.get(assigns.agent_results, agent_id)
    result_view = result_view(assigns.agent, cached)

    assigns =
      assign(assigns,
        agent_id: agent_id,
        result_view: result_view,
        objective_preview:
          blob_preview(node_text(assigns.agent, :objective), @archive_objective_preview_bytes),
        result_preview: blob_preview(result_view.value, @archive_result_preview_bytes)
      )

    ~H"""
    <div class="ml-0">
      <div class="rounded-lg border border-base-200/80 bg-base-200/30 p-4 sm:p-5">
        <!-- Agent header -->
        <div class="flex flex-wrap items-center gap-2 mb-3">
          <span class="font-mono font-bold text-sm text-base-content">{@agent[:agent_id]}</span>
          <span class="badge badge-sm badge-ghost rounded-full">
            {gettext("Depth")} {@agent[:depth]}
          </span>
          <%= if @agent[:started_at] do %>
            <span class="text-xs text-base-content/60 ml-auto">
              <.icon name="hero-clock" class="size-3.5 mr-1 inline" />
              {relative_time(@agent[:started_at])}
            </span>
          <% end %>
        </div>

        <!-- Objective -->
        <%= if @objective_preview.text != "" do %>
          <div class="mb-3">
            <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide mb-1">
              {gettext("Objective")}
            </p>
            <p class="text-sm text-base-content/80 leading-relaxed">{@objective_preview.text}</p>
            <%= if @objective_preview.truncated? do %>
              <p class="mt-1 text-xs text-base-content/60">
                <%!-- zh_CN: 字节 — 仅显示前若干字节的截断提示 --%>
                {gettext("Showing %{shown} of %{total} bytes",
                  shown: format_number(byte_size(@objective_preview.text)),
                  total: format_number(@objective_preview.total_bytes)
                )}
              </p>
            <% end %>
          </div>
        <% end %>

        <!-- Result (lazy: fetched per agent on demand) -->
        <%= case @result_view.state do %>
          <% :ok -> %>
            <%= if @result_preview.text != "" do %>
              <div class="mb-3">
                <p class="text-xs font-medium text-base-content/60 uppercase tracking-wide mb-1">
                  {gettext("Result")}
                </p>
                <p class="text-sm text-base-content/80 leading-relaxed">{@result_preview.text}</p>
                <%= if @result_preview.truncated? do %>
                  <p class="mt-1 text-xs text-base-content/60">
                    <%!-- zh_CN: 字节 — 仅显示前若干字节的截断提示 --%>
                    {gettext("Showing %{shown} of %{total} bytes",
                      shown: format_number(byte_size(@result_preview.text)),
                      total: format_number(@result_preview.total_bytes)
                    )}
                  </p>
                <% end %>
              </div>
            <% end %>
          <% :loading -> %>
            <div class="mb-3 flex items-center gap-2 text-xs text-base-content/60">
              <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
              {gettext("Loading result…")}
            </div>
          <% :error -> %>
            <div class="mb-3">
              <p class="text-xs text-error">
                <%!-- zh_CN: 该智能体的结果加载失败，可重试 --%>
                {gettext("Could not load this agent's result.")}
              </p>
              <button
                type="button"
                phx-click="load_archive_agent_result"
                phx-value-agent-id={@agent_id}
                class="btn btn-ghost btn-xs mt-1 gap-1"
              >
                <.icon name="hero-arrow-path" class="size-3.5" /> {gettext("Retry")}
              </button>
            </div>
          <% _idle -> %>
            <div class="mb-3">
              <button
                type="button"
                phx-click="load_archive_agent_result"
                phx-value-agent-id={@agent_id}
                class="btn btn-ghost btn-xs gap-1"
              >
                <.icon name="hero-eye" class="size-3.5" />
                <%!-- zh_CN: 懒加载该智能体的完整结果 --%>
                {gettext("Show result")}
              </button>
            </div>
        <% end %>

        <!-- Commits -->
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 mb-3">
          <%= if @agent[:base_commit] do %>
            <div class="flex items-center gap-2">
              <span class="text-xs text-base-content/60 shrink-0"><%!-- zh_CN: Commit → "提交" --%>{gettext(
                "Start Commit"
              )}</span>
              <span class="font-mono text-xs text-base-content/80 bg-base-200/50 rounded-full px-2 py-0.5 truncate">
                {String.slice(@agent[:base_commit], 0..7)}
              </span>
            </div>
          <% end %>
          <%= if @agent[:final_commit] do %>
            <div class="flex items-center gap-2">
              <span class="text-xs text-base-content/60 shrink-0"><%!-- zh_CN: Commit → "提交" --%>{gettext(
                "End Commit"
              )}</span>
              <span class="font-mono text-xs text-base-content/80 bg-base-200/50 rounded-full px-2 py-0.5 truncate">
                {String.slice(@agent[:final_commit], 0..7)}
              </span>
            </div>
          <% end %>
        </div>

        <!-- Archive refs -->
        <%= if @agent[:archive_ref_start] || @agent[:archive_ref_final] do %>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 mb-3">
            <%= if @agent[:archive_ref_start] do %>
              <div class="flex items-center gap-2">
                <span class="text-xs text-base-content/60 shrink-0">{gettext("Archive Start")}</span>
                <span
                  class="font-mono text-xs text-base-content/60 truncate"
                  title={@agent[:archive_ref_start]}
                >
                  {@agent[:archive_ref_start]}
                </span>
              </div>
            <% end %>
            <%= if @agent[:archive_ref_final] do %>
              <div class="flex items-center gap-2">
                <span class="text-xs text-base-content/60 shrink-0">{gettext("Archive End")}</span>
                <span
                  class="font-mono text-xs text-base-content/60 truncate"
                  title={@agent[:archive_ref_final]}
                >
                  {@agent[:archive_ref_final]}
                </span>
              </div>
            <% end %>
          </div>
        <% end %>

        <!-- Token usage -->
        <%= if @agent[:usage] do %>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 mb-3">
            <div class="rounded-lg bg-base-200/40 p-2.5 text-center">
              <%!-- zh_CN: Token → "词元" --%>
              <p class="text-[11px] text-base-content/70 uppercase tracking-wide">
                {gettext("Input Tokens")}
              </p>
              <p class="text-sm font-mono font-semibold text-base-content/80">
                {format_number(@agent[:usage][:input_tokens] || 0)}
              </p>
            </div>
            <div class="rounded-lg bg-base-200/40 p-2.5 text-center">
              <%!-- zh_CN: Token → "词元" --%>
              <p class="text-[11px] text-base-content/70 uppercase tracking-wide">
                {gettext("Output Tokens")}
              </p>
              <p class="text-sm font-mono font-semibold text-base-content/80">
                {format_number(@agent[:usage][:output_tokens] || 0)}
              </p>
            </div>
            <div class="rounded-lg bg-base-200/40 p-2.5 text-center">
              <%!-- zh_CN: Token → "词元" --%>
              <p class="text-[11px] text-base-content/70 uppercase tracking-wide">
                {gettext("Total Tokens")}
              </p>
              <p class="text-sm font-mono font-semibold text-base-content/80">
                {format_number(@agent[:usage][:total_tokens] || 0)}
              </p>
            </div>
            <div class="rounded-lg bg-base-200/40 p-2.5 text-center">
              <p class="text-[11px] text-base-content/70 uppercase tracking-wide">
                {gettext("Cost")}
              </p>
              <p class="text-sm font-mono font-semibold text-base-content/80">
                ${format_cost(@agent[:usage][:total_cost] || 0)}
              </p>
            </div>
          </div>
          <.cost_estimate_notice />
        <% end %>

        <!-- Timestamps -->
        <%= if @agent[:started_at] || @agent[:completed_at] do %>
          <div class="flex flex-wrap items-center gap-4 text-xs text-base-content/60">
            <%= if @agent[:started_at] do %>
              <span class="flex items-center gap-1">
                <.icon name="hero-play-circle" class="size-3.5" />
                {gettext("Started")} {format_datetime(@agent[:started_at])}
              </span>
            <% end %>
            <%= if @agent[:completed_at] do %>
              <span class="flex items-center gap-1">
                <.icon name="hero-check-circle" class="size-3.5" />
                {gettext("Completed")} {format_datetime(@agent[:completed_at])}
              </span>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Children -->
      <%= if @children != [] do %>
        <div class="mt-2 pl-4 sm:pl-6 border-l-2 border-base-300/80 space-y-3">
          <%= for {child_agent, child_children} <- @children do %>
            <.archive_tree_node
              agent={child_agent}
              children={child_children}
              agent_results={@agent_results}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Atom-or-string tolerant read of a tree node field. Archived records are
  # atom-normalized by `ArchiveHelpers`, but a direct caller handing a
  # string-keyed map must not silently lose the value; a non-map node yields
  # nil (which `blob_preview/2` turns into an empty preview).
  defp node_text(agent, key) when is_map(agent) do
    case Map.fetch(agent, key) do
      {:ok, value} -> value
      :error -> Map.get(agent, Atom.to_string(key))
    end
  end

  defp node_text(_agent, _key), do: nil

  # The lazily loaded result of ONE tree node, resolved into exactly one state:
  #
  #   * `:ok` with the result text — the entry itself carries a result (a
  #     `merge_entry/2` fold always lands in the loaded page that way), or the
  #     cached fetch already succeeded;
  #   * `:loading` / `:error` — the in-flight / failed lazy fetch of this agent;
  #   * `:idle` — nothing fetched yet, so the UI offers "Show result".
  #
  # Rendering NEVER triggers a fetch; only the button's `phx-click` does.
  defp result_view(agent, cached) do
    cond do
      ArchiveHelpers.result_loaded?(agent) ->
        %{state: :ok, value: node_text(agent, :result)}

      is_map(cached) and Map.get(cached, :state) == :ok ->
        %{state: :ok, value: node_text(Map.get(cached, :entry), :result)}

      is_map(cached) and Map.get(cached, :state) == :loading ->
        %{state: :loading, value: nil}

      is_map(cached) and Map.get(cached, :state) == :error ->
        %{state: :error, value: nil}

      true ->
        %{state: :idle, value: nil}
    end
  end
end
