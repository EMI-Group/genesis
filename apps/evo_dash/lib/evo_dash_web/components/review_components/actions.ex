defmodule EvoDashWeb.ReviewComponents.Actions do
  @moduledoc false

  # zh_CN glossary used in this module:
  #   Merge → "合并", Reject → "拒绝", PR → "拉取请求", Repo → "仓库"

  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # task_actions/1 — PRIMARY-scoped TASK-level actions row: "Continue task"
  # (only when can_resume) + the "…" overflow menu. Per-repo merge/reject
  # live in ReviewComponents.RepoCards.repo_cards/1.
  # ---------------------------------------------------------------------------

  attr(:can_resume, :boolean, default: false)
  attr(:loading, :boolean, default: false)
  attr(:branch_exists, :boolean, default: true)
  attr(:has_pr, :boolean, default: false)
  attr(:pr_url, :string, default: nil)
  attr(:show_export, :boolean, default: false)
  attr(:export_url, :string, default: nil)

  def task_actions(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 p-4 flex flex-wrap items-center gap-3">
      <%= if @can_resume do %>
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
    """
  end

  # ---------------------------------------------------------------------------
  # continue_task_button/1 — secondary "Continue task" action (event: resume)
  # ---------------------------------------------------------------------------

  attr(:loading, :boolean, default: false)

  defp continue_task_button(assigns) do
    ~H"""
    <button
      class="btn btn-sm rounded-lg gap-1.5 bg-base-200/60 hover:bg-base-200 border-0"
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
  # Create-View PR / Extract Skills; Export JSON renders when show_export;
  # Ignore is always available as a plain item at the end — no danger-zone
  # divider. Reject is per-repo (RepoCards), not here.
  # ---------------------------------------------------------------------------

  attr(:loading, :boolean, default: false)
  attr(:branch_exists, :boolean, default: true)
  attr(:has_pr, :boolean, default: false)
  attr(:pr_url, :string, default: nil)
  attr(:show_export, :boolean, default: false)
  attr(:export_url, :string, default: nil)

  defp overflow_menu(assigns) do
    ~H"""
    <details class="dropdown dropdown-end dropdown-top ml-auto">
      <summary class="btn btn-sm btn-ghost btn-square rounded-lg">
        <.icon name="hero-ellipsis-vertical" class="size-4" />
      </summary>
      <ul class="menu menu-sm dropdown-content z-50 p-2 shadow-lg bg-base-100 rounded-lg border border-base-200 w-52">
        <%= if @branch_exists do %>
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
        <li>
          <button
            class="rounded-md"
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

  # First ~4 conflicting file names joined with ", ", with a "…" suffix when
  # more exist. Public (delegated from the facade) so
  # RepoCards.merge_status_block/1 can reuse it.
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
