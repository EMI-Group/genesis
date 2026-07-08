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
  defdelegate action_buttons(assigns), to: EvoDashWeb.ReviewComponents.Actions
  defdelegate extract_skills_modal(assigns), to: EvoDashWeb.ReviewComponents.Actions
  defdelegate diff_stats_bar(assigns), to: EvoDashWeb.ReviewComponents.Stats
  defdelegate commits_list(assigns), to: EvoDashWeb.ReviewComponents.Stats
  defdelegate file_tree_sidebar(assigns), to: EvoDashWeb.ReviewComponents.DiffViewer
  defdelegate diff_viewer(assigns), to: EvoDashWeb.ReviewComponents.DiffViewer
  defdelegate split_diff_layout(assigns), to: EvoDashWeb.ReviewComponents.DiffViewer
  defdelegate commit_detail_header(assigns), to: EvoDashWeb.ReviewComponents.DiffViewer
  defdelegate commit_diff_layout(assigns), to: EvoDashWeb.ReviewComponents.DiffViewer

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
        class={["review-tab rounded-md px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap", @active_tab == :conversation && "bg-base-200 text-base-content shadow-sm ring-1 ring-base-content/5" || "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"]}
      >
        <.icon name="hero-chat-bubble-left-right" class="size-4 mr-2" />
        {gettext("Conversation")}
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="commits"
        class={["review-tab rounded-md px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap", @active_tab == :commits && "bg-base-200 text-base-content shadow-sm ring-1 ring-base-content/5" || "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"]}
      >
        <.icon name="hero-clock" class="size-4 mr-2" />
        <%!-- zh_CN: Commit → "提交" --%>{gettext("Commits")}
        <span class="badge badge-sm badge-ghost rounded-md ml-2">{@commits_count}</span>
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="files_changed"
        class={["review-tab rounded-md px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap", @active_tab == :files_changed && "bg-base-200 text-base-content shadow-sm ring-1 ring-base-content/5" || "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"]}
      >
        <.icon name="hero-code-bracket" class="size-4 mr-2" />
        {gettext("Files Changed")}
        <span class="badge badge-sm badge-ghost rounded-md ml-2">{@files_count}</span>
      </button>
      <%= if @show_archive do %>
        <button
          phx-click="switch_tab"
          phx-value-tab="archive"
          class={["review-tab rounded-md px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap", @active_tab == :archive && "bg-base-200 text-base-content shadow-sm ring-1 ring-base-content/5" || "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"]}
        >
          <.icon name="hero-archive-box-arrow-down" class="size-4 mr-2" />
          {gettext("Archive")}
          <span class="badge badge-sm badge-ghost rounded-md ml-2">{@agents_count}</span>
        </button>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # archive_review_section/1 — Archived agent details with recursive tree
  # ---------------------------------------------------------------------------

  attr(:archive_metadata, :list, required: true)
  attr(:task_id, :string, default: nil)

  def archive_review_section(assigns) do
    tree = ArchiveHelpers.build_archive_tree_for_review(assigns.archive_metadata)

    assigns = assign(assigns, :archive_tree, tree)

    ~H"""
    <div class="bg-base-100 rounded-lg shadow-sm border border-base-200/60 overflow-hidden">
      <!-- Header -->
      <div class="flex items-center justify-between gap-3 p-5 md:p-6 border-b border-base-200/50 bg-base-200/20">
        <div class="flex items-center gap-3">
          <.icon name="hero-archive-box-arrow-down" class="size-5 text-base-content/60" />
          <%!-- zh_CN: Agent → "智能体" --%><h3 class="font-semibold text-base">{gettext("Archived Agent Details")}</h3>
        </div>
        <%= if @task_id do %>
          <.link href={"/tasks/#{@task_id}/export"} class="btn btn-sm btn-outline btn-primary rounded-md gap-2" download>
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
      <div class="bg-base-200/30 rounded-lg border border-base-200/60 p-4 sm:p-5">
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
            <div class="bg-base-200/40 rounded-xl p-2.5 text-center">
              <%!-- zh_CN: Token → "词元" --%><p class="text-[10px] text-base-content/50 uppercase tracking-wide">{gettext("Input Tokens")}</p>
              <p class="text-sm font-mono font-semibold text-base-content/80">{format_number(@agent[:usage][:input_tokens] || 0)}</p>
            </div>
            <div class="bg-base-200/40 rounded-xl p-2.5 text-center">
              <%!-- zh_CN: Token → "词元" --%><p class="text-[10px] text-base-content/50 uppercase tracking-wide">{gettext("Output Tokens")}</p>
              <p class="text-sm font-mono font-semibold text-base-content/80">{format_number(@agent[:usage][:output_tokens] || 0)}</p>
            </div>
            <div class="bg-base-200/40 rounded-xl p-2.5 text-center">
              <%!-- zh_CN: Token → "词元" --%><p class="text-[10px] text-base-content/50 uppercase tracking-wide">{gettext("Total Tokens")}</p>
              <p class="text-sm font-mono font-semibold text-base-content/80">{format_number(@agent[:usage][:total_tokens] || 0)}</p>
            </div>
            <div class="bg-base-200/40 rounded-xl p-2.5 text-center">
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
