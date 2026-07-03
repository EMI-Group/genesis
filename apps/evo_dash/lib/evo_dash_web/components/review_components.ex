defmodule EvoDashWeb.ReviewComponents do
  @moduledoc """
  Components for the code review page — GitHub PR-style tab layout with split diff viewer.
  """
  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # review_header/1 — Page header with PR title, badges, and metadata
  # ---------------------------------------------------------------------------

  attr(:title, :string, required: true)
  attr(:task_type, :atom, required: true)
  attr(:branch_name, :string, default: nil)
  attr(:commit_sha, :string, default: nil)
  attr(:status, :atom, default: :open)

  def review_header(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-100 overflow-hidden">
      <div class="p-4">
        <div class="flex items-start gap-3">
          <.icon name="hero-code-bracket-square" class="size-5 text-base-content/50 shrink-0 mt-0.5" />
          <div class="flex-1 min-w-0">
            <h1 class="text-lg font-bold leading-tight truncate">{@title}</h1>
            <div class="flex flex-wrap items-center gap-2 mt-2">
              <span class={["badge badge-sm rounded-md px-2 py-1.5", review_status_badge(@status)]}>
                <.icon name={review_status_icon(@status)} class="size-3.5 mr-1.5" />
                {review_status_label(@status)}
              </span>
              <span class="badge badge-sm badge-ghost rounded-md px-2 py-1.5 capitalize">{@task_type}</span>
              <%= if @branch_name do %>
                <span class="badge badge-sm badge-primary rounded-md px-2 py-1.5 font-mono">
                  <.icon name="hero-code-bracket-square" class="size-3.5 mr-1.5" />
                  {@branch_name}
                </span>
              <% end %>
              <%= if @commit_sha do %>
                <span class="badge badge-sm badge-ghost rounded-md px-2 py-1.5 font-mono">
                  <.icon name="hero-code-bracket" class="size-3.5 mr-1.5" />
                  {String.slice(@commit_sha, 0..7)}
                </span>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # task_summary/1 — Compact stats strip showing token/cost usage and agent count
  # ---------------------------------------------------------------------------

  attr(:usage, :map, default: nil)
  attr(:agent_count, :integer, default: nil)
  attr(:task_type, :atom, default: nil)
  attr(:status, :atom, default: nil)
  attr(:started_at, :any, default: nil)
  attr(:finished_at, :any, default: nil)

  def task_summary(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-100 p-3">
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <%= if @usage do %>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-cpu-chip" class="size-3.5" /> {gettext("Total Tokens")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5">
              {format_number(Map.get(@usage, :total_tokens, 0))}
            </span>
          </div>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-currency-dollar" class="size-3.5" /> {gettext("Total Cost")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5">
              {format_cost(Map.get(@usage, :total_cost, 0))}
            </span>
          </div>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-bolt" class="size-3.5" /> {gettext("Cache Hit Rate")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5">
              {format_cache_hit_rate(@usage)}
            </span>
          </div>
        <% end %>
        <%= if @agent_count do %>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-user-group" class="size-3.5" /> {gettext("Agents")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5">{@agent_count}</span>
          </div>
        <% end %>
        <%= if @status do %>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-signal" class="size-3.5" /> {gettext("Status")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5 capitalize">{@status}</span>
          </div>
        <% end %>
        <%= if @task_type do %>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-cube" class="size-3.5" /> {gettext("Task Type")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5 capitalize">{@task_type}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

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
        {gettext("Commits")}
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
    tree = build_archive_tree(assigns.archive_metadata)

    assigns = assign(assigns, :archive_tree, tree)

    ~H"""
    <div class="bg-base-100 rounded-lg shadow-sm border border-base-200/60 overflow-hidden">
      <!-- Header -->
      <div class="flex items-center justify-between gap-3 p-5 md:p-6 border-b border-base-200/50 bg-base-200/20">
        <div class="flex items-center gap-3">
          <.icon name="hero-archive-box-arrow-down" class="size-5 text-base-content/60" />
          <h3 class="font-semibold text-base">{gettext("Archived Agent Details")}</h3>
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
              <span class="text-xs text-base-content/50 shrink-0">{gettext("Start Commit")}</span>
              <span class="font-mono text-xs text-base-content/70 bg-base-200/50 rounded-full px-2 py-0.5 truncate">
                {String.slice(@agent[:base_commit], 0..7)}
              </span>
            </div>
          <% end %>
          <%= if @agent[:final_commit] do %>
            <div class="flex items-center gap-2">
              <span class="text-xs text-base-content/50 shrink-0">{gettext("End Commit")}</span>
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
              <p class="text-[10px] text-base-content/50 uppercase tracking-wide">{gettext("Input Tokens")}</p>
              <p class="text-sm font-mono font-semibold text-base-content/80">{format_number(@agent[:usage][:input_tokens] || 0)}</p>
            </div>
            <div class="bg-base-200/40 rounded-xl p-2.5 text-center">
              <p class="text-[10px] text-base-content/50 uppercase tracking-wide">{gettext("Output Tokens")}</p>
              <p class="text-sm font-mono font-semibold text-base-content/80">{format_number(@agent[:usage][:output_tokens] || 0)}</p>
            </div>
            <div class="bg-base-200/40 rounded-xl p-2.5 text-center">
              <p class="text-[10px] text-base-content/50 uppercase tracking-wide">{gettext("Total Tokens")}</p>
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

  # ---------------------------------------------------------------------------
  # agent_summary/1 — Collapsible panel showing agent result
  # ---------------------------------------------------------------------------

  attr(:summary, :string, required: true)
  attr(:open, :boolean, default: true)

  def agent_summary(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-lg shadow-sm border border-base-200/60 overflow-hidden">
      <div class="relative">
        <details open={@open}>
          <summary class="p-5 md:p-6 cursor-pointer hover:bg-base-200/30 transition-colors flex items-center gap-4 list-none">
            <div class="bg-success/15 text-success p-2.5 rounded-md">
              <.icon name="hero-chat-bubble-left-ellipsis" class="size-5" />
            </div>
            <span class="font-semibold text-base-content/80">{gettext("Agent Summary")}</span>
            <div class="flex-1"></div>
            <.icon name="hero-chevron-down" class="size-4 text-base-content/40" />
          </summary>
          <div class="px-5 md:px-6 pb-5 md:pb-6">
            <div class="md-content text-sm leading-relaxed">
              {raw(EvoDash.MarkdownRender.render(@summary))}
            </div>
          </div>
        </details>
        <button
          id="summary-copy-btn"
          class="btn btn-ghost btn-sm rounded-md btn-square absolute top-4 right-4 z-10"
          phx-hook="ClipboardCopy"
          data-content={@summary}
          title={gettext("Copy agent summary")}
        >
          <.icon name="hero-clipboard" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # diff_stats_bar/1 — Files changed, insertions, deletions, and commits count
  # ---------------------------------------------------------------------------

  attr(:files_count, :integer, required: true)
  attr(:additions, :integer, required: true)
  attr(:deletions, :integer, required: true)
  attr(:commits_count, :integer, default: 0)

  def diff_stats_bar(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-lg shadow-sm border border-base-200/60 px-5 py-4 md:px-6 md:py-4">
      <div class="flex items-center gap-4 flex-wrap text-sm">
        <div class="flex items-center gap-2.5">
          <.icon name="hero-document-text" class="size-4.5 text-base-content/50" />
          <span class="font-medium text-base-content/80">
            {gettext("%{count} files changed", count: @files_count)}
          </span>
        </div>
        <div class="flex items-center gap-3 bg-base-200/50 rounded-full px-3 py-1">
          <span class="text-success font-semibold flex items-center gap-1.5">
            <.icon name="hero-plus" class="size-3.5" /> {@additions}
          </span>
          <span class="text-error font-semibold flex items-center gap-1.5">
            <.icon name="hero-minus" class="size-3.5" /> {@deletions}
          </span>
        </div>
        <span class="text-base-content/30 hidden sm:inline">·</span>
        <div class="flex items-center gap-2.5">
          <.icon name="hero-clock" class="size-4.5 text-base-content/50" />
          <span class="font-medium text-base-content/80">
            {ngettext("%{count} commit", "%{count} commits", @commits_count, count: @commits_count)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # commits_list/1 — GitHub-style commit list
  # ---------------------------------------------------------------------------

  attr(:commits, :list, required: true)

  def commits_list(assigns) do
    ~H"""
    <div>
      <div class="p-5 md:p-6 border-b border-base-200/50 bg-base-200/20">
        <div class="flex items-center gap-3">
          <.icon name="hero-clock" class="size-5 text-base-content/60" />
          <span class="font-semibold text-base">
            {ngettext("%{count} commit", "%{count} commits", length(@commits), count: length(@commits))}
          </span>
        </div>
      </div>
      <div class="divide-y divide-base-200/50">
        <%= for {commit, _i} <- Enum.with_index(@commits) do %>
          <button
            class="commit-row flex items-center gap-4 w-full px-5 md:px-6 py-4 text-left"
            phx-click="inspect_commit"
            phx-value-sha={commit.sha}
          >
            <span class="badge badge-sm badge-ghost rounded-full font-mono text-xs px-2.5 py-3 shrink-0">
              {commit.short_sha}
            </span>
            <span class="text-sm font-medium flex-1 truncate" title={commit.message}>
              {commit.message}
            </span>
            <span class="text-sm text-base-content/50 shrink-0 hidden sm:inline">
              {commit.author_name}
            </span>
            <span class="text-sm text-base-content/50 shrink-0">
              {relative_time(commit.date)}
            </span>
            <.icon name="hero-chevron-right" class="size-4 text-base-content/30 shrink-0" />
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # action_buttons/1 — Merge, Reject, Continue, Create PR, and Extract Skills
  # ---------------------------------------------------------------------------

  attr(:branch_exists, :boolean, default: true)
  attr(:has_pr, :boolean, default: false)
  attr(:pr_url, :string, default: nil)
  attr(:loading, :boolean, default: false)

  def action_buttons(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-lg shadow-sm border border-base-200/60 p-5 md:p-6">
      <div class="flex items-center gap-3 mb-5">
        <.icon name="hero-hand-raised" class="size-5 text-base-content/60" />
        <h3 class="font-semibold text-base">{gettext("Actions")}</h3>
      </div>
      <div class="flex flex-wrap gap-3">
        <%= if @branch_exists do %>
          <button
            class="btn btn-success rounded-full px-6 gap-2 shadow-sm"
            phx-click="merge"
            phx-confirm={gettext("Merge these changes into the current branch?")}
            disabled={@loading}
          >
            <.icon name="hero-check" class="size-4.5" />
            {gettext("Merge Changes")}
          </button>
          <button
            class="btn btn-outline btn-error rounded-full px-6 gap-2"
            phx-click="reject"
            phx-confirm={gettext("Reject and delete these changes? This cannot be undone.")}
            disabled={@loading}
          >
            <.icon name="hero-x-mark" class="size-4.5" />
            {gettext("Reject Changes")}
          </button>
          <button
            class="btn btn-outline btn-info rounded-full px-6 gap-2"
            phx-click="continue"
            disabled={@loading}
          >
            <.icon name="hero-arrow-path" class="size-4.5" />
            {gettext("Continue from Here")}
          </button>
          <div class="divider divider-horizontal mx-2 hidden lg:block before:bg-base-200/50 after:bg-base-200/50"></div>
        <% end %>
        <%= if @branch_exists and not @has_pr do %>
          <button
            class="btn btn-outline rounded-full px-6 gap-2"
            phx-click="create_pr"
            disabled={@loading}
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4.5" />
            {gettext("Create GitHub PR")}
          </button>
        <% end %>
        <%= if @has_pr and @pr_url do %>
          <a href={@pr_url} target="_blank" class="btn btn-outline btn-success rounded-full px-6 gap-2">
            <.icon name="hero-arrow-top-right-on-square" class="size-4.5" />
            {gettext("View GitHub PR")}
          </a>
        <% end %>
        <%= if @branch_exists do %>
          <div class="divider divider-horizontal mx-2 hidden lg:block before:bg-base-200/50 after:bg-base-200/50"></div>
          <button
            class="btn btn-outline btn-secondary rounded-full px-6 gap-2"
            phx-click="extract_skills"
            disabled={@loading}
          >
            <.icon name="hero-academic-cap" class="size-4.5" />
            {gettext("Extract Skills")}
          </button>
        <% end %>
        <%= if not @branch_exists do %>
          <div class="bg-warning/10 border border-warning/20 rounded-lg p-5 w-full">
            <div class="flex items-center gap-3">
              <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
              <span class="text-sm text-warning font-medium">{gettext("This branch no longer exists. You can dismiss it with Ignore.")}</span>
            </div>
          </div>
        <% end %>
        <button
          class="btn btn-outline btn-warning rounded-full px-6 gap-2"
          phx-click="ignore"
          phx-confirm={gettext("Ignore this review? It will be dismissed from pending reviews.")}
          disabled={@loading}
        >
          <.icon name="hero-eye-slash" class="size-4.5" />
          {gettext("Ignore")}
        </button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # extract_skills_modal/1 — Modal for extracting skills from a PR
  # ---------------------------------------------------------------------------

  attr(:show, :boolean, default: false)

  def extract_skills_modal(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="cancel_extract_skills"></div>
        <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-200 max-w-lg w-full p-6 md:p-8">
          <div class="flex items-center gap-3 mb-4">
            <div class="flex items-center justify-center size-10 rounded-md bg-secondary/10">
              <.icon name="hero-academic-cap" class="size-5 text-secondary" />
            </div>
            <h3 class="text-lg font-bold">{gettext("Extract Skills")}</h3>
          </div>

          <p class="text-sm text-base-content/70 mb-5">
            {gettext("Analyze the changes in this PR and distill reusable knowledge into EvoGit skills. The agent will examine the diff, identify valuable patterns, and create skill files in .agents/skills/.")}
          </p>

          <.form for={%{}} phx-submit="confirm_extract_skills" class="space-y-4">
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">
                  {gettext("Optional: Note for the skill extraction agent")}
                </span>
              </label>
              <textarea
                class="textarea textarea-bordered h-24 rounded-lg text-sm"
                name="user_note"
                placeholder={gettext("e.g., Focus on the deployment workflow and database migration patterns discovered in this PR.")}
              ></textarea>
              <p class="text-xs text-base-content/50 mt-1">
                {gettext("Provide specific instructions on what knowledge should be captured as skills.")}
              </p>
            </div>

            <div class="flex justify-end gap-3 pt-2">
              <button type="button" class="btn btn-ghost rounded-full px-6" phx-click="cancel_extract_skills">
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-secondary rounded-full px-6 gap-2">
                <.icon name="hero-academic-cap" class="size-4.5" />
                {gettext("Extract Skills")}
              </button>
            </div>
          </.form>
        </div>
      </div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # file_tree_sidebar/1 — Sidebar file list for the split-pane layout
  # ---------------------------------------------------------------------------

  attr(:files, :list, required: true)
  attr(:selected_file, :string, default: nil)

  def file_tree_sidebar(assigns) do
    ~H"""
    <div class="diff-file-sidebar">
      <div class="p-3 border-b border-base-200 bg-base-200/30 sticky top-0 z-10">
        <h3 class="font-semibold text-xs text-base-content/60 uppercase tracking-wider">
          {gettext("Changed Files")}
        </h3>
      </div>
      <%= for {group, files} <- group_files_by_dir(@files) do %>
        <%= if group == :root do %>
          <%= for file <- files do %>
            <button
              phx-click="select_file"
              phx-value-path={file.path}
              class={["file-item", @selected_file == file.path && "file-selected"]}
            >
              <.icon name={file_status_icon(file.status)} class={"size-3.5 shrink-0 #{file_status_color(file.status)}"} />
              <span class="font-mono truncate flex-1 text-xs" title={file.path}>
                {Path.basename(file.path)}
              </span>
              <span class="text-[10px] text-success font-mono leading-none">+{file.additions}</span>
              <span class="text-[10px] text-error font-mono leading-none">-{file.deletions}</span>
            </button>
          <% end %>
        <% else %>
          <details open class="dir-group">
            <summary class="dir-group-header">
              <span class="dir-icon">📁</span>
              <span class="dir-name font-mono text-xs truncate" title={group}>{group}/</span>
              <% {group_additions, group_deletions} = dir_stats(files) %>
              <span class="dir-stats">
                {ngettext("%{count} file", "%{count} files", length(files), count: length(files))}
                <span class="text-success">+{group_additions}</span>
                <span class="text-error">-{group_deletions}</span>
              </span>
            </summary>
            <div class="dir-files">
              <%= for file <- files do %>
                <button
                  phx-click="select_file"
                  phx-value-path={file.path}
                  class={["file-item file-item-indented", @selected_file == file.path && "file-selected"]}
                >
                  <.icon name={file_status_icon(file.status)} class={"size-3.5 shrink-0 #{file_status_color(file.status)}"} />
                  <span class="font-mono truncate flex-1 text-xs" title={file.path}>
                    {Path.basename(file.path)}
                  </span>
                  <span class="text-[10px] text-success font-mono leading-none">+{file.additions}</span>
                  <span class="text-[10px] text-error font-mono leading-none">-{file.deletions}</span>
                </button>
              <% end %>
            </div>
          </details>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # diff_viewer/1 — GitHub-style diff viewer with proper syntax highlighting
  # ---------------------------------------------------------------------------

  attr(:files, :list, required: true)
  attr(:expanded_files, :map, default: %{})
  attr(:selected_file, :string, default: nil)
  attr(:file_context_levels, :map, default: %{})

  def diff_viewer(assigns) do
    ~H"""
    <div class="diff-main-content" id="diff-viewer" phx-hook="ScrollToFile">
      <%= for file <- @files do %>
        <div class="diff-file-section" id={"file-section-#{file_path_to_id(file.path)}"}>
          <button
            phx-click="toggle_file_expansion"
            phx-value-path={file.path}
            class="diff-file-header w-full text-left"
          >
            <.icon
              name="hero-chevron-right"
              class={"size-3.5 transition-transform shrink-0 #{if Map.get(@expanded_files, file.path, false), do: "rotate-90", else: ""}"}
            />
            <.icon name={file_status_icon(file.status)} class={"size-3.5 #{file_status_color(file.status)}"} />
            <span class="truncate flex-1">{file.path}</span>
            <span class="text-[10px] text-success font-mono">+{file.additions}</span>
            <span class="text-[10px] text-error font-mono">-{file.deletions}</span>
          </button>
          <%= if Map.get(@expanded_files, file.path, false) do %>
            <div class="overflow-x-auto">
              <% context_level = Map.get(@file_context_levels, file.path, 3) %>
              {render_diff_content(file, file.path, context_level)}
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # split_diff_layout/1 — Full split layout with sidebar + diff
  # ---------------------------------------------------------------------------

  attr(:files, :list, required: true)
  attr(:expanded_files, :map, default: %{})
  attr(:selected_file, :string, default: nil)
  attr(:file_context_levels, :map, default: %{})

  def split_diff_layout(assigns) do
    ~H"""
    <div class="diff-fullscreen-layout">
      <.file_tree_sidebar files={@files} selected_file={@selected_file} />
      <.diff_viewer
        files={@files}
        expanded_files={@expanded_files}
        selected_file={@selected_file}
        file_context_levels={@file_context_levels}
      />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # commit_detail_header/1 — Header for a commit inspection view
  # ---------------------------------------------------------------------------

  attr(:commit, :map, required: true)

  def commit_detail_header(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-100 overflow-hidden">
      <div class="p-4">
        <div class="flex items-start gap-3">
          <.icon name="hero-code-bracket-square" class="size-5 text-base-content/50 shrink-0 mt-0.5" />
          <div class="flex-1 min-w-0">
            <h1 class="text-lg font-bold leading-tight">{@commit.message}</h1>
            <div class="flex flex-wrap items-center gap-2 mt-2">
              <span class="badge badge-sm badge-ghost rounded-md px-2 py-1.5 font-mono">
                <.icon name="hero-code-bracket" class="size-3.5 mr-1.5" />
                {String.slice(@commit.sha, 0..7)}
              </span>
              <span class="text-sm text-base-content/50">{@commit.author_name}</span>
              <span class="text-sm text-base-content/30">·</span>
              <span class="text-sm text-base-content/50">{relative_time(@commit.date)}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # commit_diff_layout/1 — Commit detail view with sidebar + diff viewer
  # ---------------------------------------------------------------------------

  attr(:files, :list, required: true)
  attr(:expanded_files, :map, default: %{})
  attr(:selected_file, :string, default: nil)
  attr(:file_context_levels, :map, default: %{})

  def commit_diff_layout(assigns) do
    ~H"""
    <div class="diff-fullscreen-layout">
      <.file_tree_sidebar files={@files} selected_file={@selected_file} />
      <.diff_viewer
        files={@files}
        expanded_files={@expanded_files}
        selected_file={@selected_file}
        file_context_levels={@file_context_levels}
      />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp render_diff_content(file, file_path, context_level) do
    assigns = %{file: file, file_path: file_path, context_level: context_level}

    ~H"""
    <div class="text-xs font-mono">
      <%= if is_nil(@file.diff) do %>
        <div class="flex items-center justify-center py-8 gap-2 text-base-content/50">
          <span class="loading loading-spinner loading-sm"></span>
          <span><%= gettext("Loading diff...") %></span>
        </div>
      <% else %>
        <% lines = parse_diff_lines(@file) %>
        <% {hunk_starts, _} =
            Enum.reduce(lines, {[], 0}, fn line, {acc, idx} ->
              if line.type == :hunk, do: {[idx | acc], idx + 1}, else: {acc, idx + 1}
            end) %>
        <% hunk_indices = Enum.reverse(hunk_starts) %>
        <% show_top_expand = length(hunk_indices) > 0 %>
        <% show_bottom_expand = @context_level != :all %>
        <%= if show_top_expand do %>
          <.diff_expand_bar path={@file_path} context_level={@context_level} />
        <% end %>
        <%= for {line, i} <- Enum.with_index(lines) do %>
          <%= if i in hunk_indices and i > 0 do %>
            <.diff_expand_bar path={@file_path} context_level={@context_level} />
          <% end %>
          <div class={["diff-line", diff_line_class(line.type)]}>
            <span class="diff-line-gutter">{line.line_number}</span>
            <span class={["diff-line-prefix", diff_prefix_color(line.type)]}>{line.prefix}</span>
            <span class="diff-line-content" phx-no-format>{if line.type in [:addition, :deletion, :context], do: highlight_line_content(line.content, @file.language), else: line.content}</span>
          </div>
        <% end %>
        <%= if show_bottom_expand do %>
          <.diff_expand_bar path={@file_path} context_level={@context_level} />
        <% end %>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # diff_expand_bar/1 — Expandable context bar at hunk edges
  # ---------------------------------------------------------------------------

  attr(:path, :string, required: true)
  attr(:context_level, :any, default: nil)

  def diff_expand_bar(assigns) do
    ~H"""
    <%= if @context_level != :all do %>
      <div class="diff-expand-bar">
        <button
          class="diff-expand-btn"
          phx-click="expand_context"
          phx-value-path={@path}
        >
          <.icon name="hero-chevron-double-down" class="size-3.5" />
        </button>
      </div>
    <% end %>
    """
  end

  # Map line types to CSS classes
  defp diff_line_class(:addition), do: "diff-line-addition"
  defp diff_line_class(:deletion), do: "diff-line-deletion"
  defp diff_line_class(:hunk), do: "diff-line-hunk"
  defp diff_line_class(:context), do: "diff-line-context"
  defp diff_line_class(:header), do: "diff-line-meta"
  defp diff_line_class(:meta), do: "diff-line-meta"
  defp diff_line_class(_), do: ""

  defp diff_prefix_color(:addition), do: "text-success/70"
  defp diff_prefix_color(:deletion), do: "text-error/70"
  defp diff_prefix_color(_), do: ""

  # Parse diff lines into structured data
  defp parse_diff_lines(file) do
    file.diff
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, idx} ->
      cond do
        String.starts_with?(line, "+++") ->
          %{line_number: idx, prefix: " ", content: line, type: :header}

        String.starts_with?(line, "---") ->
          %{line_number: idx, prefix: " ", content: line, type: :header}

        String.starts_with?(line, "@@") ->
          %{line_number: idx, prefix: " ", content: line, type: :hunk}

        String.starts_with?(line, "+") ->
          content = String.slice(line, 1..-1//1) || ""
          %{line_number: idx, prefix: "+", content: content, type: :addition}

        String.starts_with?(line, "-") ->
          content = String.slice(line, 1..-1//1) || ""
          %{line_number: idx, prefix: "-", content: content, type: :deletion}

        String.starts_with?(line, "diff ") ->
          %{line_number: idx, prefix: " ", content: line, type: :meta}

        String.starts_with?(line, "index ") ->
          %{line_number: idx, prefix: " ", content: line, type: :meta}

        true ->
          content = if String.length(line) > 0, do: String.slice(line, 1..-1//1), else: ""
          %{line_number: idx, prefix: " ", content: content, type: :context}
      end
    end)
  end

  # Syntax highlighting using Lumis multi-themes for light/dark support.
  # Strips the <pre>/<code> wrappers since we render lines individually.
  #
  # This try/rescue is JUSTIFIED:
  #   - Lumis.highlight!/2 raises on invalid/unexpected input (malformed code,
  #     unsupported language, binary-encoded edge cases). The non-bang variant
  #     Lumis.highlight/2 also raises internally (it does NOT return {:error, _}
  #     despite what the docs suggest), so case/with cannot cleanly replace it.
  #   - This is called per-line in a diff viewer, so offloading to a separate
  #     process (Task/async) is impractical — it would spawn one task per line.
  #   - Falling back to the raw (un-highlighted) content is the correct graceful
  #     degradation: the line is still visible, just without syntax coloring.
  defp highlight_line_content(content, language) do
    if content && String.length(content) > 0 do
      try do
        Lumis.highlight!(content,
          formatter:
            {:html_multi_themes,
             language: language,
             themes: [light: "github_light", dark: "github_dark"],
             default_theme: "light-dark()"}
        )
        |> strip_lumis_wrappers()
        |> raw()
      rescue
        _ -> content
      end
    else
      ""
    end
  end

  # Strip <pre class="lumis" ...><code ...>...</code></pre> wrappers,
  # keeping only the inner <span> elements with syntax colors.
  defp strip_lumis_wrappers(html) do
    html
    |> String.replace(~r/^<pre[^>]*><code[^>]*>/, "")
    |> String.replace(~r/<\/code><\/pre>$/, "")
  end

  # Convert a file path to a valid HTML id (replace / and . with -)
  defp file_path_to_id(path) do
    path
    |> String.replace(~r{[^a-zA-Z0-9_-]}, "-")
    |> String.trim("-")
  end

  # Build a nested tree from a flat list of archive metadata maps.
  # Groups agents by parent_id; roots are those with nil parent_id.
  # Returns [{agent, [{child, [...]}, ...]}, ...].
  #
  # The input maps may have either atom keys (in-memory) or string keys (after
  # a DB round-trip through Jason.decode). We normalize to atom keys first so
  # both the tree-building and the HEEx renderers work uniformly. A visited-set
  # guard makes the recursion bounded and total — it can never infinite-loop on
  # cyclic or malformed data.
  defp build_archive_tree(agents) do
    agents = Enum.map(agents, &normalize_agent_keys/1)

    by_parent =
      Enum.group_by(
        agents,
        fn agent ->
          case agent_key(agent, :parent_id) do
            nil -> nil
            id when is_binary(id) -> id
            _ -> nil
          end
        end
      )

    build_children = fn parent_id, visited, recurse ->
      (by_parent[parent_id] || [])
      |> Enum.filter(fn agent ->
        id = agent_key(agent, :agent_id)
        id not in [nil, ""] and not MapSet.member?(visited, id)
      end)
      |> Enum.map(fn agent ->
        id = agent_key(agent, :agent_id)
        {agent, recurse.(id, MapSet.put(visited, id), recurse)}
      end)
    end

    build_children.(nil, MapSet.new(), build_children)
  end

  # Read a value from an agent map regardless of whether keys are atoms or strings.
  defp agent_key(agent, key) when is_atom(key) do
    case Map.fetch(agent, key) do
      {:ok, v} -> v
      :error -> Map.get(agent, Atom.to_string(key))
    end
  end

  # Normalize an agent map's top-level string keys to atoms so that both
  # tree-building and the HEEx renderers (which use atom-key access) work
  # uniformly. Only known keys (in the whitelist below) are converted; unknown
  # string keys are left as-is. This avoids both dynamic atom creation and the
  # try/rescue around String.to_existing_atom/1.
  #
  # The data originates from the runtime archive_records (in-memory, atom keys)
  # or after a DB round-trip through Jason.decode (string keys). The whitelist
  # enumerates every key actually consumed by the tree-building and rendering
  # code in this module.
  @known_agent_keys %{
    "agent_id" => :agent_id,
    "parent_id" => :parent_id,
    "depth" => :depth,
    "started_at" => :started_at,
    "completed_at" => :completed_at,
    "objective" => :objective,
    "result" => :result,
    "base_commit" => :base_commit,
    "final_commit" => :final_commit,
    "archive_ref_start" => :archive_ref_start,
    "archive_ref_final" => :archive_ref_final,
    "branch_name" => :branch_name,
    "usage" => :usage,
    "input_tokens" => :input_tokens,
    "output_tokens" => :output_tokens,
    "total_tokens" => :total_tokens,
    "cost" => :cost,
    "model" => :model,
    "spec" => :spec
  }

  defp normalize_agent_keys(agent) when is_map(agent) do
    Map.new(agent, fn
      {key, value} when is_atom(key) ->
        {key, value}

      {key, value} when is_binary(key) ->
        {Map.get(@known_agent_keys, key, key), value}
    end)
  end

  defp normalize_agent_keys(agent), do: agent

  defp review_status_badge(:open), do: "badge-warning"
  defp review_status_badge(:merged), do: "badge-success"
  defp review_status_badge(:rejected), do: "badge-error"
  defp review_status_badge(:ignored), do: "badge-ghost"
  defp review_status_badge(:no_changes), do: "badge-ghost"
  defp review_status_badge(_), do: "badge-ghost"

  defp review_status_icon(:open), do: "hero-clock"
  defp review_status_icon(:merged), do: "hero-check-circle"
  defp review_status_icon(:rejected), do: "hero-x-circle"
  defp review_status_icon(:ignored), do: "hero-eye-slash"
  defp review_status_icon(:no_changes), do: "hero-information-circle"
  defp review_status_icon(_), do: "hero-question-mark-circle"

  defp review_status_label(:open), do: gettext("Open")
  defp review_status_label(:merged), do: gettext("Merged")
  defp review_status_label(:rejected), do: gettext("Rejected")
  defp review_status_label(:ignored), do: gettext("Ignored")
  defp review_status_label(:no_changes), do: gettext("No Changes")
  defp review_status_label(_), do: gettext("Unknown")

  defp file_status_icon("added"), do: "hero-plus-circle"
  defp file_status_icon("deleted"), do: "hero-minus-circle"
  defp file_status_icon("modified"), do: "hero-pencil-square"
  defp file_status_icon(_), do: "hero-document"

  defp file_status_color("added"), do: "text-success"
  defp file_status_color("deleted"), do: "text-error"
  defp file_status_color("modified"), do: "text-info"
  defp file_status_color(_), do: "text-base-content/50"

  # Group files by their parent directory. Returns a list of {group_key, files} tuples
  # sorted alphabetically, with :root first for files at the top level.
  defp group_files_by_dir(files) do
    files
    |> Enum.group_by(fn file ->
      case Path.dirname(file.path) do
        "." -> :root
        dir -> dir
      end
    end)
    |> Enum.sort_by(fn
      {:root, _} -> {0, ""}
      {dir, _} -> {1, dir}
    end)
  end

  # Calculate total additions and deletions for a group of files
  defp dir_stats(files) do
    additions = Enum.sum(Enum.map(files, & &1.additions))
    deletions = Enum.sum(Enum.map(files, & &1.deletions))
    {additions, deletions}
  end
end
