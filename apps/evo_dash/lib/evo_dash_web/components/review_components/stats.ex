defmodule EvoDashWeb.ReviewComponents.Stats do
  @moduledoc false

  # zh_CN: Commit → "提交"

  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # diff_stats_bar/1 — Files changed, insertions, deletions, and commits count
  # ---------------------------------------------------------------------------

  attr(:files_count, :integer, required: true)
  attr(:additions, :integer, required: true)
  attr(:deletions, :integer, required: true)
  attr(:commits_count, :integer, default: 0)

  def diff_stats_bar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
      <span class="flex items-center gap-1.5">
        <.icon name="hero-clock" class="size-4 text-base-content/70" />
        <%!-- zh_CN: commit → "提交" --%>
        {ngettext("%{count} commit", "%{count} commits", @commits_count, count: @commits_count)}
      </span>
      <span class="flex items-center gap-1.5">
        <.icon name="hero-document-text" class="size-4 text-base-content/70" />
        {gettext("%{count} files changed", count: @files_count)}
      </span>
      <span class="text-success font-semibold flex items-center gap-1">
        <%!-- zh_CN: +新增行数 --%>
        <.icon name="hero-arrow-up" class="size-3.5" />
        {@additions}
      </span>
      <span class="text-error font-semibold flex items-center gap-1">
        <%!-- zh_CN: −删除行数 --%>
        <.icon name="hero-arrow-down" class="size-3.5" />
        {@deletions}
      </span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # commits_list/1 — GitHub-style commit list
  # ---------------------------------------------------------------------------

  attr(:commits, :list, required: true)

  def commits_list(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 overflow-hidden">
      <div class="px-4 py-3 border-b border-base-300 bg-base-200/40">
        <div class="flex items-center gap-2">
          <.icon name="hero-clock" class="size-4 text-base-content/60" />
          <span class="text-sm font-semibold text-base-content/85">
            {ngettext("%{count} commit", "%{count} commits", length(@commits),
              count: length(@commits)
            )}
          </span>
        </div>
      </div>
      <div>
        <%= for commit <- @commits do %>
          <button
            class="flex items-center gap-3 px-4 py-3 text-left w-full hover:bg-base-200/50 transition-colors border-b border-base-200/60 last:border-b-0"
            phx-click="inspect_commit"
            phx-value-sha={commit.sha}
          >
            <span class="badge badge-sm badge-outline border-base-content/20 font-mono rounded-md shrink-0">
              {commit.short_sha}
            </span>
            <span class="text-sm font-medium truncate flex-1" title={commit.message}>
              {commit.message}
            </span>
            <span class="text-sm text-base-content/60 shrink-0 hidden sm:inline">
              {commit.author_name}
            </span>
            <span class="text-sm text-base-content/60 shrink-0">
              {relative_time(commit.date)}
            </span>
            <.icon name="hero-chevron-right" class="size-4 text-base-content/60 shrink-0" />
          </button>
        <% end %>
      </div>
    </div>
    """
  end
end
