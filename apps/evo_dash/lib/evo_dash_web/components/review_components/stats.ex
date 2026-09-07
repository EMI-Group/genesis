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
  attr(:repos, :list, default: [])
  attr(:active_repo_id, :string, default: "primary")

  def commits_list(assigns) do
    ~H"""
    <div>
      <%= if length(@repos) > 1 do %>
        <%!-- zh_CN: "Repository" → 仓库（提交页签的仓库切换条，多仓库评审时选择当前查看的仓库） --%>
        <%!-- Form-level phx-change: an input-level phx-change with no owning form never delivers its event (phoenix_live_view pushInput throws "form events require the input to be inside a form"); the select serializes by its name=repo_id into %{"repo_id" => ...}. --%>
        <form
          id="commits-repo-switch-form"
          phx-change="switch_repo"
          class="flex items-center gap-3 px-4 py-2.5 rounded-xl border border-base-300 bg-base-100 mb-3"
        >
          <%!-- heroicons has no folder-stack glyph; rectangle-stack is the closest stacked-repositories icon --%>
          <.icon name="hero-rectangle-stack" class="size-4 shrink-0 text-base-content/50" />
          <span class="text-sm text-base-content/60 whitespace-nowrap">{gettext("Repository")}</span>
          <select
            name="repo_id"
            phx-change="switch_repo"
            aria-label={gettext("Repository")}
            class="select select-sm rounded-lg border-base-300 max-w-56"
          >
            <option
              :for={repo <- @repos}
              value={repo[:repo_id]}
              selected={repo[:repo_id] == @active_repo_id}
            >
              {EvoDashWeb.ReviewComponents.DiffViewer.repo_option_label(repo)}
            </option>
          </select>
        </form>
      <% end %>
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
              <span class="badge badge-sm bg-base-200 border-0 font-mono rounded-md shrink-0">
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
    </div>
    """
  end
end
