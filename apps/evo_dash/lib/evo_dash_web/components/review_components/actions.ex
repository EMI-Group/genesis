defmodule EvoDashWeb.ReviewComponents.Actions do
  @moduledoc false

  # zh_CN glossary used in this module:
  #   Merge → "合并", Reject → "拒绝", PR → "拉取请求", Repo → "仓库"

  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # merge_box/1 — GitHub-style merge box: async merge-check strip + actions row
  # (merge / continue / overflow menu). Replaces the old action_buttons/1.
  # ---------------------------------------------------------------------------

  attr(:repo_id, :string, default: "primary")
  attr(:branch_exists, :boolean, default: true)
  attr(:can_resume, :boolean, default: false)
  attr(:has_pr, :boolean, default: false)
  attr(:pr_url, :string, default: nil)
  attr(:loading, :boolean, default: false)
  attr(:is_no_changes, :boolean, default: false)
  attr(:merge_targets, :list, default: [])
  attr(:default_merge_target, :string, default: nil)
  attr(:merge_status, :map, default: nil)
  attr(:repos, :list, default: [])
  attr(:active_repo_id, :string, default: "primary")
  attr(:show_export, :boolean, default: false)
  attr(:export_url, :string, default: nil)

  def merge_box(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 overflow-hidden">
      <%= if @merge_status do %>
        <div class="p-3 sm:p-4 border-b border-base-300 bg-base-200/30">
          <.merge_status_block status={@merge_status} loading={@loading} />
        </div>
      <% end %>

      <%= if @branch_exists do %>
        <div class="p-4 sm:p-5 flex flex-wrap items-center gap-3">
          <%= if length(@repos) > 1 do %>
            <%!-- zh_CN: 切换评审仓库（多仓库任务的下拉切换器） --%>
            <select
              name="repo_id"
              phx-change="switch_repo"
              class="select select-sm select-bordered rounded-lg max-w-56"
              aria-label={gettext("Repository")}
            >
              <option
                :for={repo <- @repos}
                value={repo[:repo_id]}
                selected={repo[:repo_id] == @active_repo_id}
              >
                {repo[:repo_id]} — {truncate_repo_path(Map.get(repo, :repo_path))}
              </option>
            </select>
          <% end %>

          <%= if @merge_targets != [] do %>
            <form id="merge-form" phx-submit="merge" phx-change="merge_target_change" class="contents">
              <input type="hidden" name="repo_id" value={@repo_id} />
              <label class="flex items-center gap-2">
                <%!-- zh_CN: 合并到（选择合并目标分支的标签） --%>
                <span class="text-sm text-base-content/60 whitespace-nowrap">{gettext("Merge into")}</span>
                <select
                  name="target_branch"
                  class="select select-sm select-bordered rounded-lg"
                  aria-label={gettext("Merge into branch")}
                  phx-value-repo_id={@repo_id}
                >
                  <option
                    :for={name <- @merge_targets}
                    value={name}
                    selected={name == @default_merge_target}
                  >
                    {name}
                  </option>
                </select>
              </label>
              <button
                type="submit"
                class="btn btn-success btn-sm rounded-lg gap-1.5"
                phx-confirm={
                  gettext("Merge these changes into %{target}?", target: @default_merge_target)
                }
                disabled={@loading}
              >
                <.icon name="hero-check" class="size-4" />
                {gettext("Merge")}
              </button>
            </form>
          <% else %>
            <button
              class="btn btn-success btn-sm rounded-lg gap-1.5"
              phx-click="merge"
              phx-value-repo_id={@repo_id}
              phx-confirm={gettext("Merge these changes into the current branch?")}
              disabled={@loading}
            >
              <.icon name="hero-check" class="size-4" />
              {gettext("Merge")}
            </button>
          <% end %>

          <%= if @can_resume or @branch_exists do %>
            <.continue_task_button loading={@loading} />
          <% end %>

          <.overflow_menu
            loading={@loading}
            branch_exists={@branch_exists}
            has_pr={@has_pr}
            pr_url={@pr_url}
            show_export={@show_export}
            export_url={@export_url}
          />
        </div>
      <% else %>
        <div class="p-4 sm:p-5 flex flex-wrap items-center gap-3">
          <div class={[
            "rounded-lg p-4 w-full",
            if(@is_no_changes,
              do: "bg-info/10 border border-info/20",
              else: "bg-warning/10 border border-warning/20"
            )
          ]}>
            <div class="flex items-center gap-3">
              <.icon
                name={
                  if @is_no_changes, do: "hero-information-circle", else: "hero-exclamation-triangle"
                }
                class={"size-5 " <> if(@is_no_changes, do: "text-info", else: "text-warning")}
              />
              <span class={[
                "text-sm font-medium",
                if(@is_no_changes, do: "text-info", else: "text-warning")
              ]}>
                <%= if @is_no_changes do %>
                  {gettext(
                    "The agent completed without making any code changes. You can resume from this investigation or dismiss it."
                  )}
                <% else %>
                  {gettext("This branch no longer exists. You can dismiss it with Ignore.")}
                <% end %>
              </span>
            </div>
          </div>

          <%= if @can_resume do %>
            <.continue_task_button loading={@loading} />
          <% end %>

          <.overflow_menu
            loading={@loading}
            branch_exists={false}
            show_export={@show_export}
            export_url={@export_url}
          />
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # merge_status_block/1 — async merge-check result (clean/conflict/checking)
  # ---------------------------------------------------------------------------

  attr(:status, :map, required: true)
  attr(:loading, :boolean, default: false)

  defp merge_status_block(assigns) do
    ~H"""
    <%= case @status do %>
      <% %{state: :checking} -> %>
        <div class="flex items-center gap-2 w-full text-sm text-base-content/60">
          <span class="loading loading-spinner loading-xs"></span>
          {gettext("Checking if merge is clean…")}
        </div>
      <% %{state: :clean} -> %>
        <div class="flex items-center gap-2 w-full rounded-lg border border-success/30 bg-success/10 p-3 text-sm text-success">
          <.icon name="hero-check-circle" class="size-5 shrink-0" />
          {gettext("Merge check passed — clean merge.")}
        </div>
      <% %{state: :conflict, files: files} -> %>
        <% count = length(files) %>
        <div class="flex flex-col sm:flex-row sm:items-center gap-3 w-full rounded-lg border border-warning/30 bg-warning/10 p-4">
          <div class="flex items-start gap-3 min-w-0">
            <.icon name="hero-exclamation-triangle" class="size-5 text-warning shrink-0 mt-0.5" />
            <span class="text-sm text-warning break-words">
              {ngettext(
                "Merge conflict detected in %{count} file: %{files}",
                "Merge conflict detected in %{count} files: %{files}",
                count,
                count: count,
                files: conflict_files_summary(files)
              )}
            </span>
          </div>
          <button
            class="btn btn-warning rounded-lg px-6 gap-2 shrink-0 sm:ml-auto"
            phx-click="auto_resolve"
            phx-confirm={
              gettext(
                "This starts a new agent task that will merge the changes and resolve the conflicts. The current task will be marked as continued."
              )
            }
            disabled={@loading}
          >
            <.icon name="hero-bolt" class="size-4.5" />
            <%!-- zh_CN: 自动解决合并冲突（启动新的合并智能体任务） --%>
            {gettext("Auto-resolve conflict")}
          </button>
        </div>
      <% _ -> %>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # continue_task_button/1 — secondary "Continue task" action (event: resume)
  # ---------------------------------------------------------------------------

  attr(:loading, :boolean, default: false)

  defp continue_task_button(assigns) do
    ~H"""
    <button
      class="btn btn-sm btn-outline rounded-lg gap-1.5"
      phx-click="resume"
      disabled={@loading}
    >
      <.icon name="hero-arrow-path" class="size-4" />
      <%!-- zh_CN: 继续任务 — 从该任务的提交继续演化 --%>
      {gettext("Continue task")}
    </button>
    """
  end

  # ---------------------------------------------------------------------------
  # overflow_menu/1 — "…" dropdown pinned right. When branch_exists it carries
  # Reject / Create-View PR / Extract Skills; Export JSON + the danger-zone
  # Ignore entry are always available (Export only when show_export).
  # ---------------------------------------------------------------------------

  attr(:loading, :boolean, default: false)
  attr(:branch_exists, :boolean, default: true)
  attr(:has_pr, :boolean, default: false)
  attr(:pr_url, :string, default: nil)
  attr(:show_export, :boolean, default: false)
  attr(:export_url, :string, default: nil)

  defp overflow_menu(assigns) do
    ~H"""
    <details class="dropdown dropdown-end ml-auto">
      <summary class="btn btn-sm btn-ghost btn-square rounded-lg">
        <.icon name="hero-ellipsis-vertical" class="size-4" />
      </summary>
      <ul class="menu menu-sm dropdown-content z-50 p-2 shadow-lg bg-base-100 rounded-lg border border-base-200 w-52">
        <%= if @branch_exists do %>
          <li>
            <button
              class="text-error hover:bg-error/10 hover:text-error rounded-md"
              phx-click="reject"
              phx-confirm={gettext("Reject and delete these changes? This cannot be undone.")}
              disabled={@loading}
            >
              <.icon name="hero-x-mark" class="size-4 mr-2" />
              <%!-- zh_CN: 拒绝并删除该分支的全部变更（不可恢复） --%>
              {gettext("Reject")}
            </button>
          </li>
          <%= if not @has_pr do %>
            <li>
              <button class="rounded-md" phx-click="create_pr" disabled={@loading}>
                <.icon name="hero-arrow-top-right-on-square" class="size-4 mr-2" />
                <%!-- zh_CN: 在 GitHub 上创建拉取请求 --%>
                {gettext("Create GitHub PR")}
              </button>
            </li>
          <% end %>
        <% end %>
        <%= if @branch_exists and @has_pr and @pr_url do %>
          <li>
            <a
              href={@pr_url}
              target="_blank"
              class={["rounded-md", @loading && "pointer-events-none opacity-50"]}
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4 mr-2" />
              <%!-- zh_CN: 在 GitHub 上查看该拉取请求 --%>
              {gettext("View PR")}
            </a>
          </li>
        <% end %>
        <%= if @branch_exists do %>
          <li>
            <button class="rounded-md" phx-click="extract_skills" disabled={@loading}>
              <.icon name="hero-academic-cap" class="size-4 mr-2" />
              <%!-- zh_CN: 提炼技能 — 从该变更中总结可复用的技能文件 --%>
              {gettext("Extract Skills")}
            </button>
          </li>
        <% end %>
        <%= if @show_export do %>
          <li>
            <a
              href={@export_url}
              download
              class={["rounded-md", @loading && "pointer-events-none opacity-50"]}
            >
              <.icon name="hero-arrow-down-tray" class="size-4 mr-2" />
              <%!-- zh_CN: 导出该任务的归档 JSON --%>
              {gettext("Export JSON")}
            </a>
          </li>
        <% end %>
        <%!-- zh_CN: 危险操作区（不可逆操作的分组标题） --%>
        <li class="menu-title px-3 py-1 text-xs uppercase tracking-wide text-base-content/60">
          {gettext("Danger zone")}
        </li>
        <li>
          <button
            class="text-error hover:bg-error/10 hover:text-error rounded-md"
            phx-click="ignore"
            phx-confirm={gettext("Ignore this review? It will be dismissed from pending reviews.")}
            disabled={@loading}
          >
            <.icon name="hero-eye-slash" class="size-4 mr-2" />
            <%!-- zh_CN: 忽略该评审并从待评审列表中移除 --%>
            {gettext("Ignore")}
          </button>
        </li>
      </ul>
    </details>
    """
  end

  # Repo root path for the switcher label — keep the last ~30 chars with a
  # leading "…" (the tail of the path is the discriminating part).
  defp truncate_repo_path(path) when is_binary(path) do
    if String.length(path) > 30 do
      "…" <> String.slice(path, -29, 29)
    else
      path
    end
  end

  defp truncate_repo_path(_), do: ""

  # First ~4 conflicting file names joined with ", ", with a "…" suffix when
  # more exist. Public so review_components.ex (merge_outcomes_panel/1) can
  # reuse it via defdelegate.
  def conflict_files_summary(files) do
    shown = Enum.take(files, 4)

    case Enum.drop(files, 4) do
      [] -> Enum.join(shown, ", ")
      _ -> Enum.join(shown, ", ") <> "…"
    end
  end

  # ---------------------------------------------------------------------------
  # extract_skills_modal/1 — Modal for extracting skills from a PR
  # ---------------------------------------------------------------------------

  attr(:show, :boolean, default: false)

  def extract_skills_modal(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="cancel_extract_skills">
        </div>
        <div class="relative bg-base-100 rounded-xl shadow-2xl border border-base-300 max-w-lg w-full p-6 md:p-8">
          <div class="flex items-center gap-3 mb-4">
            <div class="flex items-center justify-center size-10 rounded-md bg-secondary/10">
              <.icon name="hero-academic-cap" class="size-5 text-secondary" />
            </div>
            <%!-- zh_CN: 提炼技能 — 从变更中总结可复用的技能文件 --%>
            <h3 class="text-lg font-bold">{gettext("Extract Skills")}</h3>
          </div>

          <p class="text-sm text-base-content/70 mb-5">
            {gettext(
              "Analyze the changes in this PR and distill reusable knowledge into EvoGit skills. The agent will examine the diff, identify valuable patterns, and create skill files in .agents/skills/."
            )}
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
                placeholder={
                  gettext(
                    "e.g., Focus on the deployment workflow and database migration patterns discovered in this PR."
                  )
                }
              ></textarea>
              <p class="text-xs text-base-content/60 mt-1">
                {gettext(
                  "Provide specific instructions on what knowledge should be captured as skills."
                )}
              </p>
            </div>

            <div class="flex justify-end gap-3 pt-2">
              <button
                type="button"
                class="btn btn-ghost rounded-lg px-6"
                phx-click="cancel_extract_skills"
              >
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-secondary rounded-lg px-6 gap-2">
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
end
