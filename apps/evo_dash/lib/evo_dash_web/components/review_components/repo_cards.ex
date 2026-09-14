defmodule EvoDashWeb.ReviewComponents.RepoCards do
  @moduledoc false

  # zh_CN glossary used in this module:
  #   Merge → "合并", Reject → "拒绝", Repo → "仓库"

  use EvoDashWeb, :html

  alias EvoDashWeb.ReviewComponents.Actions

  # ---------------------------------------------------------------------------
  # repo_cards/1 — one CARD per repository. Each card owns its own merge/reject
  # controls and its own resolution state (merged / rejected / handled /
  # error / conflict). An optional completion banner sits above the cards.
  # ---------------------------------------------------------------------------

  attr(:repos, :list, required: true)
  attr(:completion, :atom, default: nil)
  attr(:back_url, :string, default: nil)

  def repo_cards(assigns) do
    ~H"""
    <div id="review-repo-cards" class="space-y-4">
      <%= if @completion != nil do %>
        <.completion_banner completion={@completion} back_url={@back_url} />
      <% end %>

      <%= if show_merge_all?(@repos) do %>
        <div id="merge-all-toolbar" class="flex flex-wrap items-center gap-3">
          <button
            id="merge-all-repositories"
            class="btn btn-success btn-sm rounded-lg gap-1.5"
            phx-click="merge_all"
            phx-confirm={
              gettext(
                "Merge ALL remaining repositories into their target branches? This cannot be undone."
              )
            }
          >
            <.icon name="hero-check" class="size-4" />
            <%!-- zh_CN: 一次合并所有仍未处理的仓库（接受全部） --%>
            {gettext("Merge all repositories")}
          </button>
        </div>
      <% end %>

      <.repo_card :for={repo <- @repos} repo={repo} />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # completion_banner/1 — review-complete strip (merged / rejected) with the
  # back-to-projects escape hatch. Rendered only when completion != nil.
  # ---------------------------------------------------------------------------

  attr(:completion, :atom, required: true)
  attr(:back_url, :string, default: nil)

  defp completion_banner(assigns) do
    ~H"""
    <div
      id="review-completion-banner"
      class={[
        "rounded-xl border p-4 flex flex-wrap items-center gap-3",
        completion_banner_class(@completion)
      ]}
    >
      <.icon
        name={completion_banner_icon(@completion)}
        class={"size-5 shrink-0 " <> completion_banner_text_class(@completion)}
      />
      <span class={"text-sm font-medium " <> completion_banner_text_class(@completion)}>
        {completion_banner_text(@completion)}
      </span>
      <.link
        navigate={@back_url}
        id="review-completion-back"
        class="btn btn-sm rounded-lg gap-1.5 ml-auto"
      >
        <.icon name="hero-arrow-left" class="size-4" />
        <%!-- zh_CN: 返回项目页 --%>
        {gettext("Back to Projects")}
      </.link>
    </div>
    """
  end

  defp completion_banner_class(:merged), do: "border-success/30 bg-success/10"
  defp completion_banner_class(:rejected), do: "border-error/30 bg-error/10"
  defp completion_banner_class(_), do: "border-base-300 bg-base-200/30"

  defp completion_banner_text_class(:merged), do: "text-success"
  defp completion_banner_text_class(:rejected), do: "text-error"
  defp completion_banner_text_class(_), do: "text-base-content/80"

  defp completion_banner_icon(:merged), do: "hero-check-circle"
  defp completion_banner_icon(:rejected), do: "hero-x-circle"
  defp completion_banner_icon(_), do: "hero-information-circle"

  defp completion_banner_text(:merged), do: gettext("All repositories merged.")
  defp completion_banner_text(:rejected), do: gettext("All repositories rejected.")
  defp completion_banner_text(_), do: gettext("Review complete.")

  # ---------------------------------------------------------------------------
  # repo_card/1 — one repository card: header (id / path / branch / diff stat /
  # resolution badge / jump-to-diff) + a body driven by the resolution state
  # machine and branch_exists.
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)

  defp repo_card(assigns) do
    repo = assigns.repo

    assigns =
      assigns
      |> assign(:repo_id, field(repo, :repo_id, "primary"))
      |> assign(:repo_path, field(repo, :repo_path))
      |> assign(:branch_name, field(repo, :branch_name))
      |> assign(:branch_exists, field(repo, :branch_exists, true))
      |> assign(:review_data, field(repo, :review_data))
      |> assign(:merge_targets, field(repo, :merge_targets) || [])
      |> assign(:default_merge_target, field(repo, :default_merge_target))
      |> assign(:merge_status, field(repo, :merge_status))
      |> assign(:resolution, field(repo, :resolution))

    ~H"""
    <% state = resolution_state(@resolution) %>
    <% target = @default_merge_target || List.first(@merge_targets) %>
    <div id={"repo-card-" <> @repo_id} class="rounded-xl border border-base-300 bg-base-100">
      <div class="p-3 sm:p-4 border-b border-base-300 bg-base-200/30 rounded-t-xl flex flex-wrap items-center gap-3">
        <div class="flex items-center gap-2 min-w-0">
          <%!-- heroicons has no folder-stack glyph; rectangle-stack is the closest stacked-repositories icon --%>
          <.icon name="hero-rectangle-stack" class="size-4 shrink-0 text-base-content/50" />
          <span class="text-sm font-semibold text-base-content/80 whitespace-nowrap">
            <%= if @repo_id == "primary" do %>
              <%!-- zh_CN: 主仓库（任务的主项目仓库） --%>
              {gettext("Primary repository")}
            <% else %>
              <span class="font-mono">{@repo_id}</span>
            <% end %>
          </span>
          <span class="text-xs font-mono text-base-content/60 truncate" title={@repo_path}>
            {truncate_repo_path(@repo_path)}
          </span>
        </div>

        <%= if @branch_name do %>
          <span class="badge badge-sm border-0 bg-base-200 font-mono min-w-0 max-w-[14rem] md:max-w-none truncate">
            {@branch_name}
          </span>
        <% end %>

        <span id={"repo-resolution-" <> @repo_id} class={resolution_badge_class(state)}>
          {resolution_badge_text(@resolution)}
        </span>

        <div class="ml-auto flex items-center gap-3">
          <%= if @review_data do %>
            <% files_count = review_stat(@review_data, :changed_files_count) %>
            <span class="flex items-center gap-2 text-xs whitespace-nowrap">
              <span class="font-mono text-success">+{review_stat(@review_data, :total_additions)}</span>
              <span class="font-mono text-error">−{review_stat(@review_data, :total_deletions)}</span>
              <span class="text-base-content/60">
                {ngettext("%{count} file", "%{count} files", files_count, count: files_count)}
              </span>
            </span>
          <% end %>
          <button
            class="btn btn-ghost btn-xs rounded-lg gap-1"
            phx-click="open_repo_diff"
            phx-value-repo_id={@repo_id}
          >
            <.icon name="hero-code-bracket" class="size-3.5" />
            <%!-- zh_CN: 查看该仓库的代码差异 --%>
            {gettext("View diff")}
          </button>
        </div>
      </div>

      <div class="p-4 sm:p-5">
        <%= cond do %>
          <% state in [:merged, :rejected, :handled] -> %>
            <div class="flex items-center gap-2 text-sm text-base-content/70">
              <.icon name="hero-check-circle" class="size-4 shrink-0 text-success" />
              <span>{resolution_badge_text(@resolution)}</span>
            </div>
          <% state in [:error, :conflict] -> %>
            <.resolution_detail resolution={@resolution} state={state} />
            <.repo_action_row
              repo_id={@repo_id}
              merge_targets={@merge_targets}
              target={target}
            />
          <% !@branch_exists -> %>
            <.branch_inactive_notice branch_name={@branch_name} />
          <% true -> %>
            <%= if @merge_status != nil do %>
              <div class="rounded-lg border border-base-300 bg-base-200/30 p-3 mb-3">
                <.merge_status_block status={@merge_status} />
              </div>
            <% end %>
            <.repo_action_row
              repo_id={@repo_id}
              merge_targets={@merge_targets}
              target={target}
            />
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # resolution_detail/1 — non-terminal resolution report (:error / :conflict),
  # tinted with the semantic token (never -content on a tint).
  # ---------------------------------------------------------------------------

  attr(:resolution, :map, default: nil)
  attr(:state, :atom, required: true)

  defp resolution_detail(assigns) do
    assigns = assign(assigns, :detail, resolution_detail_text(assigns.resolution))

    ~H"""
    <%= if @detail do %>
      <div class={["rounded-lg border p-3 mb-3 text-sm font-medium", resolution_detail_class(@state)]}>
        {@detail}
      </div>
    <% end %>
    """
  end

  defp resolution_detail_class(:error), do: "border-error/20 bg-error/10 text-error"
  defp resolution_detail_class(:conflict), do: "border-warning/20 bg-warning/10 text-warning"
  defp resolution_detail_class(_), do: "border-base-300 bg-base-200/30 text-base-content/80"

  # ---------------------------------------------------------------------------
  # branch_inactive_notice/1 — informational only (branch_exists: false), no
  # actions: no-changes (branch_name nil) vs branch-gone.
  # ---------------------------------------------------------------------------

  attr(:branch_name, :string, default: nil)

  defp branch_inactive_notice(assigns) do
    ~H"""
    <div class={[
      "rounded-lg border p-4 flex items-center gap-3",
      if(@branch_name, do: "border-warning/30 bg-warning/10", else: "border-info/30 bg-info/10")
    ]}>
      <.icon
        name={if @branch_name, do: "hero-exclamation-triangle", else: "hero-information-circle"}
        class={"size-5 shrink-0 " <> if(@branch_name, do: "text-warning", else: "text-info")}
      />
      <span class={["text-sm font-medium", if(@branch_name, do: "text-warning", else: "text-info")]}>
        <%= if @branch_name do %>
          {gettext("This branch no longer exists.")}
        <% else %>
          {gettext(
            "The agent completed without making any code changes. You can resume from this investigation or dismiss it."
          )}
        <% end %>
      </span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # repo_action_row/1 — per-repo Merge (target select form, or a form-less
  # button when no targets) + Reject, both scoped by phx-value-repo_id.
  # ---------------------------------------------------------------------------

  attr(:repo_id, :string, required: true)
  attr(:merge_targets, :list, default: [])
  attr(:target, :string, default: nil)

  defp repo_action_row(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <%= if @merge_targets != [] do %>
        <%!-- Form-level phx-change: a form-less input-level phx-change never delivers its event (pushInput throws "form events require the input to be inside a form"); class="contents" keeps the children flowing inline in the parent flex row. --%>
        <form
          id={"merge-form-" <> @repo_id}
          phx-submit="merge"
          phx-change="merge_target_change"
          class="contents"
        >
          <input type="hidden" name="repo_id" value={@repo_id} />
          <label class="flex items-center gap-2">
            <%!-- zh_CN: 合并到（选择合并目标分支的标签） --%>
            <span class="text-sm text-base-content/60 whitespace-nowrap">{gettext("Merge into")}</span>
            <select
              name="target_branch"
              class="select select-sm rounded-lg border-base-300"
              aria-label={gettext("Merge into branch")}
              phx-value-repo_id={@repo_id}
            >
              <option :for={name <- @merge_targets} value={name} selected={name == @target}>
                {name}
              </option>
            </select>
          </label>
          <button
            type="submit"
            class="btn btn-success btn-sm rounded-lg gap-1.5"
            phx-confirm={gettext("Merge these changes into %{target}?", target: @target)}
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
        >
          <.icon name="hero-check" class="size-4" />
          {gettext("Merge")}
        </button>
      <% end %>

      <button
        class="btn btn-outline btn-error btn-sm rounded-lg gap-1.5"
        phx-click="reject"
        phx-value-repo_id={@repo_id}
        phx-confirm={gettext("Reject and delete these changes? This cannot be undone.")}
      >
        <.icon name="hero-x-mark" class="size-4" />
        <%!-- zh_CN: 拒绝并删除该仓库分支的全部变更（不可恢复） --%>
        {gettext("Reject")}
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # merge_status_block/1 — async merge-check result (checking / clean /
  # conflict). The conflict case's "Auto-resolve" is primary-scoped (no
  # repo_id). Moved here from Actions.
  # ---------------------------------------------------------------------------

  attr(:status, :map, required: true)

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
                files: Actions.conflict_files_summary(files)
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
  # Helpers
  # ---------------------------------------------------------------------------

  # Defensive read: atom key first, then the string-keyed variant, then default.
  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key), default)
    end
  end

  defp field(_map, _key, default), do: default

  defp review_stat(review_data, key) when is_map(review_data) do
    Map.get(review_data, key, Map.get(review_data, to_string(key), 0)) || 0
  end

  defp review_stat(_review_data, _key), do: 0

  defp resolution_state(resolution) when is_map(resolution), do: Map.get(resolution, :state)
  defp resolution_state(_resolution), do: nil

  # Accept-all shortcut gate: only meaningful when the task has at least two
  # repositories AND at least two of them are still unresolved (resolution nil).
  # `field/3` tolerates a missing `:resolution` key and `resolution_state(nil)`
  # is nil, so nil/absent resolutions both count as unresolved.
  defp show_merge_all?(repos) when is_list(repos) do
    length(repos) >= 2 and
      Enum.count(repos, &(resolution_state(field(&1, :resolution)) == nil)) >= 2
  end

  defp show_merge_all?(_repos), do: false

  defp resolution_badge_class(nil), do: []

  defp resolution_badge_class(:merged),
    do: ["badge", "badge-sm", "border-0", "bg-success/10", "text-success"]

  defp resolution_badge_class(:rejected),
    do: ["badge", "badge-sm", "border-0", "bg-error/10", "text-error"]

  defp resolution_badge_class(:handled),
    do: ["badge", "badge-sm", "border-0", "bg-base-content/10", "text-base-content/70"]

  defp resolution_badge_class(:error),
    do: ["badge", "badge-sm", "border-0", "bg-error/10", "text-error"]

  defp resolution_badge_class(:conflict),
    do: ["badge", "badge-sm", "border-0", "bg-warning/10", "text-warning"]

  defp resolution_badge_class(_), do: ["badge", "badge-sm"]

  defp resolution_badge_text(nil), do: nil

  defp resolution_badge_text(%{state: :merged, target: target}) when is_binary(target),
    do: gettext("Merged into %{target}", target: target)

  defp resolution_badge_text(%{state: :merged}), do: gettext("Merged")
  defp resolution_badge_text(%{state: :rejected}), do: gettext("Rejected")
  defp resolution_badge_text(%{state: :handled}), do: gettext("Already handled")
  defp resolution_badge_text(%{state: :error}), do: gettext("Merge failed")
  defp resolution_badge_text(%{state: :conflict}), do: gettext("Merge conflict")
  defp resolution_badge_text(_), do: nil

  defp resolution_detail_text(resolution) when is_map(resolution) do
    case Map.get(resolution, :detail) do
      detail when is_binary(detail) -> detail
      nil -> resolution_detail_fallback(Map.get(resolution, :state))
      other -> inspect(other)
    end
  end

  defp resolution_detail_text(_resolution), do: nil

  defp resolution_detail_fallback(:error), do: gettext("Merge failed. You can retry.")
  defp resolution_detail_fallback(:conflict), do: gettext("Merge conflict. You can retry.")
  defp resolution_detail_fallback(_), do: nil

  # Repo root path for the header label — keep the last ~30 chars with a
  # leading "…" (the tail of the path is the discriminating part).
  defp truncate_repo_path(path) when is_binary(path) do
    if String.length(path) > 30 do
      "…" <> String.slice(path, -29, 29)
    else
      path
    end
  end

  defp truncate_repo_path(_), do: ""
end
