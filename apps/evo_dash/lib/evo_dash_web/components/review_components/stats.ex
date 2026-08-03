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
    <div class="bg-base-100 border-b border-base-200 px-5 py-4 md:px-6 md:py-4">
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
            <%!-- zh_CN: commit → "提交" --%> {ngettext(
              "%{count} commit",
              "%{count} commits",
              @commits_count,
              count: @commits_count
            )}
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
            {ngettext("%{count} commit", "%{count} commits", length(@commits),
              count: length(@commits)
            )}
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
end
