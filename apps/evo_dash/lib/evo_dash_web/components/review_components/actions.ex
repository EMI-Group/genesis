defmodule EvoDashWeb.ReviewComponents.Actions do
  @moduledoc false
  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # action_buttons/1 — Merge, Reject, Resume, Create PR, and Extract Skills
  # ---------------------------------------------------------------------------

  attr(:branch_exists, :boolean, default: true)
  attr(:has_pr, :boolean, default: false)
  attr(:pr_url, :string, default: nil)
  attr(:loading, :boolean, default: false)
  attr(:can_resume, :boolean, default: false)
  attr(:is_no_changes, :boolean, default: false)
  attr(:merge_targets, :list, default: [])
  attr(:default_merge_target, :string, default: nil)
  attr(:merge_status, :map, default: nil)
  attr(:repo_id, :string, default: "primary")

  def action_buttons(assigns) do
    ~H"""
    <div class="bg-base-100 border-b border-base-200 p-5 md:p-6">
      <div class="flex items-center gap-3 mb-5">
        <.icon name="hero-hand-raised" class="size-5 text-base-content/60" />
        <h3 class="font-semibold text-base">{gettext("Actions")}</h3>
      </div>
      <div class="flex flex-wrap gap-3">
        <%= if @merge_status do %>
          <.merge_status_block status={@merge_status} loading={@loading} />
        <% end %>
        <%= if @branch_exists do %>
          <%= if @merge_targets != [] do %>
            <form id="merge-form" phx-submit="merge" phx-change="merge_target_change" class="contents">
              <input type="hidden" name="repo_id" value={@repo_id} />
              <label class="flex items-center gap-2">
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
                class="btn btn-success rounded-full px-6 gap-2 shadow-sm"
                phx-confirm={
                  gettext("Merge these changes into %{target}?", target: @default_merge_target)
                }
                disabled={@loading}
              >
                <.icon name="hero-check" class="size-4.5" />
                {gettext("Merge")}
              </button>
            </form>
          <% else %>
            <button
              class="btn btn-success rounded-full px-6 gap-2 shadow-sm"
              phx-click="merge"
              phx-value-repo_id={@repo_id}
              phx-confirm={gettext("Merge these changes into the current branch?")}
              disabled={@loading}
            >
              <.icon name="hero-check" class="size-4.5" />
              {gettext("Merge")}
            </button>
          <% end %>
          <button
            class="btn btn-outline btn-error rounded-full px-6 gap-2"
            phx-click="reject"
            phx-confirm={gettext("Reject and delete these changes? This cannot be undone.")}
            disabled={@loading}
          >
            <.icon name="hero-x-mark" class="size-4.5" />
            {gettext("Reject")}
          </button>
          <button
            class="btn btn-outline btn-secondary rounded-full px-6 gap-2"
            phx-click="resume"
            disabled={@loading}
          >
            <.icon name="hero-arrow-path" class="size-4.5" />
            {gettext("Resume")}
          </button>
          <div class="divider divider-horizontal mx-2 hidden lg:block before:bg-base-200/50 after:bg-base-200/50">
          </div>
        <% end %>
        <%= if @branch_exists and not @has_pr do %>
          <button
            class="btn btn-outline rounded-full px-6 gap-2"
            phx-click="create_pr"
            disabled={@loading}
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4.5" />
            {gettext("Create PR")}
          </button>
        <% end %>
        <%= if @has_pr and @pr_url do %>
          <a
            href={@pr_url}
            target="_blank"
            class="btn btn-outline btn-success rounded-full px-6 gap-2"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4.5" />
            {gettext("View PR")}
          </a>
        <% end %>
        <%= if @branch_exists do %>
          <div class="divider divider-horizontal mx-2 hidden lg:block before:bg-base-200/50 after:bg-base-200/50">
          </div>
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
          <div class={[
            "rounded-lg p-5 w-full",
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
        <% end %>
        <%= if not @branch_exists and @can_resume do %>
          <button
            class="btn btn-outline btn-secondary rounded-full px-6 gap-2"
            phx-click="resume"
            disabled={@loading}
          >
            <.icon name="hero-arrow-path" class="size-4.5" />
            {gettext("Resume")}
          </button>
        <% end %>
        <button
          class="btn btn-outline btn-ghost rounded-full px-6 gap-2"
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
            class="btn btn-warning rounded-full px-6 gap-2 shrink-0 sm:ml-auto"
            phx-click="auto_resolve"
            phx-confirm={
              gettext(
                "This starts a new agent task that will merge the changes and resolve the conflicts. The current task will be marked as continued."
              )
            }
            disabled={@loading}
          >
            <.icon name="hero-bolt" class="size-4.5" />
            {gettext("Auto-resolve conflict")}
          </button>
        </div>
      <% _ -> %>
    <% end %>
    """
  end

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
        <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-200 max-w-lg w-full p-6 md:p-8">
          <div class="flex items-center gap-3 mb-4">
            <div class="flex items-center justify-center size-10 rounded-md bg-secondary/10">
              <.icon name="hero-academic-cap" class="size-5 text-secondary" />
            </div>
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
              <p class="text-xs text-base-content/50 mt-1">
                {gettext(
                  "Provide specific instructions on what knowledge should be captured as skills."
                )}
              </p>
            </div>

            <div class="flex justify-end gap-3 pt-2">
              <button
                type="button"
                class="btn btn-ghost rounded-full px-6"
                phx-click="cancel_extract_skills"
              >
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
end
