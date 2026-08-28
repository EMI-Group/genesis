defmodule EvoDashWeb.ReviewComponents do
  @moduledoc """
  Components for the code review page — GitHub PR-style tab layout with split diff viewer.
  """

  # zh_CN: Commit → "提交", Agent → "智能体", Token → "词元"

  use EvoDashWeb, :html
  alias EvoDashWeb.ArchiveHelpers

  # Delegates to sub-modules
  defdelegate review_header(assigns), to: EvoDashWeb.ReviewComponents.Header
  defdelegate task_summary(assigns), to: EvoDashWeb.ReviewComponents.Header
  defdelegate agent_summary(assigns), to: EvoDashWeb.ReviewComponents.Header
  defdelegate objective_section(assigns), to: EvoDashWeb.ReviewComponents.Header
  defdelegate action_buttons(assigns), to: EvoDashWeb.ReviewComponents.Actions
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
  # review_tabs/1 — Tab bar for switching between Conversation and Files Changed
  # ---------------------------------------------------------------------------

  attr(:active_tab, :atom, required: true)
  attr(:files_count, :integer, default: 0)
  attr(:commits_count, :integer, default: 0)
  attr(:show_archive, :boolean, default: false)
  attr(:agents_count, :integer, default: 0)

  def review_tabs(assigns) do
    ~H"""
    <div class="review-tab-bar flex gap-1 sm:gap-2 py-2 sm:py-3 overflow-x-auto scrollbar-none -mx-4 px-4 sm:mx-0 sm:px-0">
      <button
        phx-click="switch_tab"
        phx-value-tab="conversation"
        class={["review-tab px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap", @active_tab == :conversation && "bg-base-200 text-base-content" || "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"]}
      >
        <.icon name="hero-document-text" class="size-4 mr-2" />
        {gettext("Agent Report")}
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="objective"
        class={["review-tab px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap", @active_tab == :objective && "bg-base-200 text-base-content" || "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"]}
      >
        <.icon name="hero-chat-bubble-bottom-center-text" class="size-4 mr-2" />
        {gettext("Objective")}
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="commits"
        class={["review-tab px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap", @active_tab == :commits && "bg-base-200 text-base-content" || "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"]}
      >
        <.icon name="hero-clock" class="size-4 mr-2" />
        <%!-- zh_CN: Commit → "提交" --%>{gettext("Commits")}
        <span class="badge badge-sm badge-ghost ml-2">{@commits_count}</span>
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="files_changed"
        class={["review-tab px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap", @active_tab == :files_changed && "bg-base-200 text-base-content" || "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"]}
      >
        <.icon name="hero-code-bracket" class="size-4 mr-2" />
        {gettext("Files Changed")}
        <span class="badge badge-sm badge-ghost ml-2">{@files_count}</span>
      </button>
      <%= if @show_archive do %>
        <button
          phx-click="switch_tab"
          phx-value-tab="archive"
          class={["review-tab px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap", @active_tab == :archive && "bg-base-200 text-base-content" || "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"]}
        >
          <.icon name="hero-archive-box-arrow-down" class="size-4 mr-2" />
          {gettext("Archive")}
          <span class="badge badge-sm badge-ghost ml-2">{@agents_count}</span>
        </button>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # repo_tabs/1 — Per-repo tab switcher for multi-repo review
  # ---------------------------------------------------------------------------

  attr(:repos, :list, required: true)
  attr(:active_repo_id, :string, default: "primary")

  def repo_tabs(assigns) do
    ~H"""
    <div class="review-tab-bar flex gap-1 sm:gap-2 py-2 sm:py-3 overflow-x-auto scrollbar-none -mx-4 px-4 sm:mx-0 sm:px-0">
      <button
        :for={repo <- @repos}
        phx-click="switch_repo"
        phx-value-repo_id={repo[:repo_id]}
        class={[
          "review-tab px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap flex items-center gap-2",
          @active_repo_id == repo[:repo_id] && "bg-base-200 text-base-content" ||
            "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"
        ]}
      >
        <span class="badge badge-sm badge-ghost font-mono">{repo[:repo_id]}</span>
        <span class="font-mono text-xs truncate max-w-40">{truncate_path(repo[:repo_path])}</span>
        <%= case repo[:merge_status] do %>
          <% %{state: :clean} -> %>
            <%!-- zh_CN: "Clean merge" → 合并无冲突 --%>
            <span class="size-2 rounded-full bg-success shrink-0" title={gettext("Clean merge")}></span>
          <% %{state: :conflict} -> %>
            <%!-- zh_CN: "Merge conflict" → 合并冲突 --%>
            <span class="size-2 rounded-full bg-warning shrink-0" title={gettext("Merge conflict")}></span>
          <% %{state: :checking} -> %>
            <span class="loading loading-spinner loading-xs shrink-0"></span>
          <% _ -> %>
        <% end %>
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # merge_outcomes_panel/1 — Per-repo broadcast merge outcome report
  # ---------------------------------------------------------------------------

  attr(:outcomes, :list, default: [])

  def merge_outcomes_panel(assigns) do
    ~H"""
    <%= if @outcomes != [] do %>
      <div class="bg-base-100 border rounded-lg p-4">
        <div class="flex items-center gap-3 mb-4">
          <.icon name="hero-arrow-path" class="size-5 text-base-content/60" />
          <%!-- zh_CN: "Merge results" → 合并结果 --%>
          <h3 class="font-semibold text-base">{gettext("Merge results")}</h3>
        </div>
        <div class="space-y-3">
          <%= for outcome <- @outcomes do %>
            <div class="flex items-start gap-3 rounded-lg border border-base-200 bg-base-200/30 p-3">
              <span class="badge badge-sm badge-ghost font-mono shrink-0 mt-0.5">{outcome[:repo_id]}</span>
              <%= case outcome[:status] do %>
                <% :merged -> %>
                  <div class="flex items-start gap-2 min-w-0 text-sm">
                    <.icon name="hero-check-circle" class="size-5 text-success shrink-0 mt-0.5" />
                    <div class="min-w-0">
                      <span class="font-medium text-success">
                        <%= if outcome[:target] do %>
                          <%!-- zh_CN: "Merged into %{target}" → 已合并到 %{target} --%>
                          {gettext("Merged into %{target}", target: outcome[:target])}
                        <% else %>
                          <%!-- zh_CN: "Merged" → 已合并 --%>
                          {gettext("Merged")}
                        <% end %>
                      </span>
                      <%= if is_binary(outcome[:detail]) do %>
                        <span class="font-mono text-xs text-base-content/60 ml-2">
                          {String.slice(outcome[:detail], 0..7)}
                        </span>
                      <% end %>
                    </div>
                  </div>
                <% :conflict -> %>
                  <div class="flex items-start gap-2 min-w-0 text-sm">
                    <.icon name="hero-exclamation-triangle" class="size-5 text-warning shrink-0 mt-0.5" />
                    <div class="min-w-0">
                      <%!-- zh_CN: "Merge conflict" → 合并冲突 --%>
                      <span class="font-medium text-warning">{gettext("Merge conflict")}</span>
                      <%= if is_list(outcome[:detail]) and outcome[:detail] != [] do %>
                        <span class="text-base-content/70 block mt-1 break-words">
                          {conflict_files_summary(outcome[:detail])}
                        </span>
                      <% end %>
                    </div>
                  </div>
                <% :error -> %>
                  <div class="flex items-start gap-2 min-w-0 text-sm">
                    <.icon name="hero-x-circle" class="size-5 text-error shrink-0 mt-0.5" />
                    <div class="min-w-0">
                      <%!-- zh_CN: "Failed: %{detail}" → 失败：%{detail} --%>
                      <span class="font-medium text-error">
                        {gettext("Failed: %{detail}", detail: format_outcome_detail(outcome[:detail]))}
                      </span>
                    </div>
                  </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  # Truncate a repo root path to the last ~40 chars with a leading "…".
  defp truncate_path(path) when is_binary(path) do
    if String.length(path) > 40 do
      "…" <> String.slice(path, -39, 39)
    else
      path
    end
  end

  defp truncate_path(_), do: ""

  # Error outcome details may be any inspected reason term — render binaries
  # as-is, everything else via inspect.
  defp format_outcome_detail(detail) when is_binary(detail), do: detail
  defp format_outcome_detail(detail), do: inspect(detail)

  # ---------------------------------------------------------------------------
  # archive_review_section/1 — Archived agent details with recursive tree
  # ---------------------------------------------------------------------------

  attr(:archive_metadata, :list, required: true)
  attr(:task_id, :string, default: nil)

  def archive_review_section(assigns) do
    tree = ArchiveHelpers.build_archive_tree_for_review(assigns.archive_metadata)

    assigns = assign(assigns, :archive_tree, tree)

    ~H"""
    <div class="bg-base-100 border border-base-200 ">
      <!-- Header -->
      <div class="flex items-center justify-between gap-3 p-5 md:p-6 border-b border-base-200/50 bg-base-200/20">
        <div class="flex items-center gap-3">
          <.icon name="hero-archive-box-arrow-down" class="size-5 text-base-content/60" />
          <%!-- zh_CN: Agent → "智能体" --%><h3 class="font-semibold text-base">{gettext("Archived Agent Details")}</h3>
        </div>
        <%= if @task_id do %>
          <.link href={"/tasks/#{@task_id}/export"} class="btn btn-sm btn-outline btn-primary gap-2" download>
            <.icon name="hero-arrow-down-tray" class="size-4" />
            {gettext("Export JSON")}
          </.link>
        <% end %>
      </div>

      <!-- Agent tree -->
      <div class="p-4 sm:p-6 space-y-3">
        <%= for {agent, children} <- @archive_tree do %>
          <.archive_tree_node agent={agent} children={children} />
        <% end %>
      </div>
    </div>
    """
  end

  attr(:agent, :map, required: true)
  attr(:children, :list, default: [])

  def archive_tree_node(assigns) do
    ~H"""
    <div class="ml-0">
      <div class="bg-base-200/30 border border-base-200/60 p-4 sm:p-5">
        <!-- Agent header -->
        <div class="flex flex-wrap items-center gap-2 mb-3">
          <span class="font-mono font-bold text-sm text-base-content">{@agent[:agent_id]}</span>
          <span class="badge badge-sm badge-ghost rounded-full">
            {gettext("Depth")} {@agent[:depth]}
          </span>
          <%= if @agent[:started_at] do %>
            <span class="text-xs text-base-content/50 ml-auto">
              <.icon name="hero-clock" class="size-3.5 mr-1 inline" />
              {relative_time(@agent[:started_at])}
            </span>
          <% end %>
        </div>

        <!-- Objective -->
        <%= if @agent[:objective] do %>
          <div class="mb-3">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide mb-1">
              {gettext("Objective")}
            </p>
            <p class="text-sm text-base-content/80 leading-relaxed">{@agent[:objective]}</p>
          </div>
        <% end %>

        <!-- Result -->
        <%= if @agent[:result] do %>
          <div class="mb-3">
            <p class="text-xs font-medium text-base-content/50 uppercase tracking-wide mb-1">
              {gettext("Result")}
            </p>
            <p class="text-sm text-base-content/80 leading-relaxed">{@agent[:result]}</p>
          </div>
        <% end %>

        <!-- Commits -->
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 mb-3">
          <%= if @agent[:base_commit] do %>
            <div class="flex items-center gap-2">
              <span class="text-xs text-base-content/50 shrink-0"><%!-- zh_CN: Commit → "提交" --%>{gettext("Start Commit")}</span>
              <span class="font-mono text-xs text-base-content/70 bg-base-200/50 rounded-full px-2 py-0.5 truncate">
                {String.slice(@agent[:base_commit], 0..7)}
              </span>
            </div>
          <% end %>
          <%= if @agent[:final_commit] do %>
            <div class="flex items-center gap-2">
              <span class="text-xs text-base-content/50 shrink-0"><%!-- zh_CN: Commit → "提交" --%>{gettext("End Commit")}</span>
              <span class="font-mono text-xs text-base-content/70 bg-base-200/50 rounded-full px-2 py-0.5 truncate">
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
                <span class="text-xs text-base-content/50 shrink-0">{gettext("Archive Start")}</span>
                <span class="font-mono text-xs text-base-content/60 truncate" title={@agent[:archive_ref_start]}>
                  {@agent[:archive_ref_start]}
                </span>
              </div>
            <% end %>
            <%= if @agent[:archive_ref_final] do %>
              <div class="flex items-center gap-2">
                <span class="text-xs text-base-content/50 shrink-0">{gettext("Archive End")}</span>
                <span class="font-mono text-xs text-base-content/60 truncate" title={@agent[:archive_ref_final]}>
                  {@agent[:archive_ref_final]}
                </span>
              </div>
            <% end %>
          </div>
        <% end %>

        <!-- Token usage -->
        <%= if @agent[:usage] do %>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 mb-3">
            <div class="bg-base-200/40 p-2.5 text-center">
              <%!-- zh_CN: Token → "词元" --%><p class="text-[10px] text-base-content/50 uppercase tracking-wide">{gettext("Input Tokens")}</p>
              <p class="text-sm font-mono font-semibold text-base-content/80">{format_number(@agent[:usage][:input_tokens] || 0)}</p>
            </div>
            <div class="bg-base-200/40 p-2.5 text-center">
              <%!-- zh_CN: Token → "词元" --%><p class="text-[10px] text-base-content/50 uppercase tracking-wide">{gettext("Output Tokens")}</p>
              <p class="text-sm font-mono font-semibold text-base-content/80">{format_number(@agent[:usage][:output_tokens] || 0)}</p>
            </div>
            <div class="bg-base-200/40 p-2.5 text-center">
              <%!-- zh_CN: Token → "词元" --%><p class="text-[10px] text-base-content/50 uppercase tracking-wide">{gettext("Total Tokens")}</p>
              <p class="text-sm font-mono font-semibold text-base-content/80">{format_number(@agent[:usage][:total_tokens] || 0)}</p>
            </div>
            <div class="bg-base-200/40 p-2.5 text-center">
              <p class="text-[10px] text-base-content/50 uppercase tracking-wide">{gettext("Cost")}</p>
              <p class="text-sm font-mono font-semibold text-base-content/80">${format_cost(@agent[:usage][:cost])}</p>
            </div>
          </div>
        <% end %>

        <!-- Timestamps -->
        <%= if @agent[:started_at] || @agent[:completed_at] do %>
          <div class="flex flex-wrap items-center gap-4 text-xs text-base-content/50">
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
        <div class="mt-2 pl-4 sm:pl-6 border-l-2 border-base-200/60 space-y-3">
          <%= for {child_agent, child_children} <- @children do %>
            <.archive_tree_node agent={child_agent} children={child_children} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
