defmodule EvoDashWeb.GitHubComponents do
  @moduledoc """
  GitHub issue integration UI for the dashboard.

  `issues_modal/1` is the custom fixed-overlay modal listing the active
  project's GitHub issues, with an open/closed/all state filter and a
  per-issue "Fix" button that launches an `:evolve` task. Rendered by
  `EvoDashWeb.ProjectsLive` when `@github_modal_open` is true; all events
  (`open_github_issues`, `close_github_modal`, `github_filter_state`,
  `github_fix_issue`) are handled by the parent LiveView through
  `EvoDashWeb.ProjectsLive.GitHub`.

  This module performs NO direct gh/git calls — the issue data arrives via
  the node-aware `EvoDash.NodeContext` and is passed in through assigns.
  """

  use EvoDashWeb, :html

  attr(:github_status, :map,
    default: nil,
    doc: "async upstream-detection status (owner/repo display)"
  )

  attr(:issues, :map,
    required: true,
    doc:
      "%{status: :idle | :loading | :ok | :error, error: nil, state_filter: String.t(), issues: [map()]}"
  )

  attr(:fixing, :integer,
    default: nil,
    doc: "issue number whose markdown is currently being fetched"
  )

  def issues_modal(assigns) do
    ~H"""
    <div
      id="github-issues-modal"
      class="fixed inset-0 z-50 flex items-center justify-center p-4 sm:p-6"
      role="dialog"
      aria-modal="true"
      aria-label={gettext("GitHub Issues")}
      phx-window-keydown="close_github_modal"
      phx-key="Escape"
    >
      <!-- Backdrop: click outside closes -->
      <div
        class="absolute inset-0 bg-black/30 backdrop-blur-sm"
        phx-click="close_github_modal"
        aria-hidden="true"
      >
      </div>

      <!-- Panel -->
      <div class="relative w-full max-w-2xl max-h-[80vh] flex flex-col rounded-xl border border-base-200 bg-base-100 shadow-2xl overflow-hidden">
        <!-- Header -->
        <div class="flex items-center gap-3 px-5 py-4 border-b border-base-200 shrink-0">
          <span class="rounded-lg bg-base-200/60 p-2 shrink-0">
            <.icon name="brand-github" class="size-5" />
          </span>
          <div class="min-w-0 flex-1">
            <h2 class="text-base font-semibold">{gettext("GitHub Issues")}</h2>
            <p
              :if={repo_label(@github_status) != ""}
              class="text-xs font-mono text-base-content/60 truncate"
            >
              {repo_label(@github_status)}
            </p>
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square shrink-0"
            phx-click="close_github_modal"
            title={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <!-- Body -->
        <div class="flex-1 min-h-0 overflow-y-auto p-4">
          <%= case @issues.status do %>
            <% :loading -> %>
              <div class="flex flex-col items-center justify-center gap-3 py-16">
                <span class="loading loading-spinner loading-lg text-info"></span>
                <p class="text-sm text-base-content/60">{gettext("Loading issues…")}</p>
              </div>

            <% :error -> %>
              <div role="alert" class="alert alert-error">
                <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
                <p class="text-sm min-w-0 break-words">{error_message(@issues.error)}</p>
              </div>

            <% :ok -> %>
              <!-- State filter (open/closed/all) -->
              <div class="flex items-center gap-1 rounded-lg border border-base-200 bg-base-200/50 p-1 w-fit mb-3">
                <%= for {state, label} <- state_filter_options() do %>
                  <button
                    type="button"
                    phx-click="github_filter_state"
                    phx-value-state={state}
                    class={[
                      "px-3 py-1.5 rounded-md text-xs font-medium cursor-pointer transition-colors whitespace-nowrap",
                      @issues.state_filter == state && "bg-base-100 shadow-sm text-base-content",
                      @issues.state_filter != state &&
                        "text-base-content/70 hover:text-base-content hover:bg-base-200/80"
                    ]}
                  >
                    {label}
                  </button>
                <% end %>
              </div>

              <%= if @issues.issues == [] do %>
                <div class="flex flex-col items-center justify-center gap-2 py-14 text-center">
                  <.icon name="hero-inbox" class="size-10 text-base-content/60" />
                  <p class="text-sm text-base-content/70">{empty_message(@issues.state_filter)}</p>
                </div>
              <% else %>
                <ul class="flex flex-col gap-2">
                  <%= for issue <- @issues.issues do %>
                    <li class="flex items-center gap-3 rounded-xl border border-base-200 bg-base-100/60 px-3 py-2.5 transition-colors hover:border-base-300">
                      <div class="min-w-0 flex-1">
                        <div class="flex items-center gap-2 min-w-0">
                          <span class="font-mono text-xs text-base-content/60 shrink-0">
                            ##{issue.number}
                          </span>
                          <span class={["badge badge-sm shrink-0", state_badge_class(issue.state)]}>
                            {state_label(issue.state)}
                          </span>
                          <span class="text-sm font-medium truncate">{issue.title}</span>
                        </div>
                        <div class="mt-1.5 flex items-center gap-1.5 flex-wrap">
                          <%= for label <- issue.labels do %>
                            <span class="badge badge-outline badge-xs">{label}</span>
                          <% end %>
                          <span class="text-xs text-base-content/60 truncate">
                            {issue.author}<%= if issue.author != "" and created_date(issue.created_at) != "" do %> · {created_date(issue.created_at)}<% end %>
                          </span>
                        </div>
                      </div>

                      <a
                        href={issue.url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="btn btn-ghost btn-sm btn-square shrink-0"
                        title={gettext("Open issue on GitHub")}
                      >
                        <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                      </a>

                      <%!-- 修复/解决：点击后启动一个 agent 任务来修复该 issue（非“固定”之意） --%>
                      <button
                        type="button"
                        phx-click="github_fix_issue"
                        phx-value-number={issue.number}
                        disabled={@fixing == issue.number}
                        class="btn btn-primary btn-sm gap-1.5 shrink-0"
                        title={gettext("Fix this issue")}
                      >
                        <span :if={@fixing == issue.number} class="loading loading-spinner loading-xs"></span>
                        <.icon :if={@fixing != issue.number} name="hero-wrench-screwdriver" class="size-3.5" />
                        {gettext("Fix")}
                      </button>
                    </li>
                  <% end %>
                </ul>
              <% end %>

            <% _ -> %>
              <%!-- :idle is a transient state — the parent only renders this
                   modal with :loading assigned, so nothing to show. --%>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Surfaces a GitHub fetch error as a user-facing message: `{:gh, code,
  output}` shows the gh CLI's trimmed output (e.g. "gh auth login
  required"); anything else gets a generic message.
  """
  def error_message({:gh, _code, output}) when is_binary(output) do
    case String.trim(output) do
      "" -> generic_error_message()
      message -> message
    end
  end

  def error_message(_reason), do: generic_error_message()

  defp generic_error_message do
    gettext(
      "Could not load GitHub issues. Make sure the GitHub CLI (gh) is installed and authenticated."
    )
  end

  defp repo_label(%{owner: owner, repo: repo}) when is_binary(owner) and is_binary(repo),
    do: "#{owner}/#{repo}"

  defp repo_label(_), do: ""

  defp state_filter_options do
    [
      # 筛选：未关闭的 issue
      {"open", gettext("Open")},
      # 筛选：已关闭的 issue
      {"closed", gettext("Closed")},
      # 筛选：全部状态的 issue
      {"all", gettext("All")}
    ]
  end

  defp empty_message("open"), do: gettext("No open issues")
  defp empty_message("closed"), do: gettext("No closed issues")
  defp empty_message(_), do: gettext("No issues")

  defp state_label("open"), do: gettext("Open")
  defp state_label("closed"), do: gettext("Closed")
  defp state_label(other), do: other

  defp state_badge_class("open"), do: "badge-success"
  defp state_badge_class(_), do: "badge-ghost"

  # gh reports `createdAt` as ISO-8601; show the date part only (compact).
  defp created_date(created_at) when is_binary(created_at) do
    case Regex.run(~r/^\d{4}-\d{2}-\d{2}/, created_at) do
      [date] -> date
      nil -> created_at
    end
  end

  defp created_date(_), do: ""
end
