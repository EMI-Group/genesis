defmodule EvoDashWeb.ReviewLive.Page do
  @moduledoc """
  The `/review` page TEMPLATE — the render layer of `EvoDashWeb.ReviewLive`.

  `EvoDashWeb.ReviewLive.render/1` delegates here, so the LiveView module keeps
  only its state machine (mount / handle_params / handle_event / handle_info)
  and its action plumbing. The markup, DOM ids, classes and gettext strings are
  unchanged from the pre-extraction template, and so are the SCOPED-loading
  affordances (`#review-reload-status`, `review-tab-<tab>`, `wizard-step-enter`,
  `#review-load-error`).
  """
  use EvoDashWeb, :html

  alias EvoDashWeb.RemoteGateComponents
  alias EvoDashWeb.ReviewLive.LoadRequest

  def render(assigns) do
    unresolved_remote? =
      assigns[:workbench_remote_requested] == true and is_nil(assigns.current_node_id)

    scope_ready? = LoadRequest.scope_ready?(assigns)

    assigns =
      assign(assigns,
        remote_gate?: RemoteGateComponents.gate_active?(assigns),
        shell_project: if(scope_ready?, do: assigns.workbench_project),
        shell_title: if(scope_ready?, do: assigns[:objective]),
        shell_task: unless(unresolved_remote?, do: assigns.task_id),
        history_scope_pending?: LoadRequest.history_scope_pending?(assigns)
      )

    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:review}
      config_status={@config_status}
      current_node_id={@current_node_id}
      remote_targets={assigns[:remote_targets] || []}
      connection_statuses={assigns[:connection_statuses] || %{}}
      workbench_project={@shell_project}
      workbench_history_scope_pending?={@history_scope_pending?}
      workbench_git_project={@shell_project}
      workbench_task={@shell_task}
      workbench_title={@shell_title}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      session_list={assigns[:session_list] || []}
      session_list_loading={assigns[:session_list_loading] == true}
      session_list_error={assigns[:session_list_error]}
      current_session_id={assigns[:current_session_id]}
      pending_tasks={@pending_tasks}
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
      accent_color={assigns[:accent_color] || "blue"}
    >
      <%= if @remote_gate? do %>
        {RemoteGateComponents.remote_connection_gate(assigns)}
      <% else %>
        <%= if @error do %>
          <div
            id="review-load-error"
            class="rounded-lg border border-error/30 bg-error/5 p-6 text-center space-y-3"
          >
            <.icon name="hero-exclamation-triangle" class="size-8 text-error mx-auto" />
            <h2 class="text-xl font-semibold text-error">{gettext("Review Not Available")}</h2>
            <p class="text-sm text-base-content/80">{@error}</p>
            <div class="flex flex-wrap items-center justify-center gap-3">
              <button type="button" phx-click="retry_load" class="btn btn-outline px-6 gap-2">
                <.icon name="hero-arrow-path" class="size-4" /> {gettext("Retry")}
              </button>
              <.link
                navigate={with_node_param(~p"/projects", @current_node_id)}
                class="btn btn-primary px-6 gap-2"
              >
                <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to Dashboard")}
              </.link>
            </div>
          </div>
        <% else %>
          <%!-- SCOPED loading: the full-page spinner is the FIRST paint only
               (nothing to keep on screen yet). Once the page has rendered real
               data, a reload keeps the whole shell — header, tabs and the
               current tab body — and only shows the compact refresh strip
               (reload_status/1) below the tabs bar. --%>
          <%= if @loading and not @page_ready? do %>
            <!-- Loading state -->
            <div role="status" class="flex items-center justify-center py-20">
              <span class="loading loading-spinner loading-lg text-primary-standalone"></span>
              <span class="ml-3 text-sm text-base-content/60">{gettext("Loading review data...")}</span>
            </div>
          <% else %>
            <%= if @live_action == :commit do %>
              <div class="space-y-4 pb-8">
                <.reload_status :if={@loading and @page_ready?} />
                <%!-- The commit detail renders only once its header exists: it
                     is nil until this route's load lands, and a SCOPED reload
                     keeps the shell on screen (the strip above says why). --%>
                <%= if @commit_header do %>
                  <EvoDashWeb.ReviewComponents.commit_detail_header
                    commit={@commit_header}
                    back_url={review_commits_path(@task_id, @current_node_id, @inspect_repo_id)}
                    task_title={EvoDashWeb.ReviewComponents.Header.short_title(@title)}
                    unavailable={is_nil(@commit_data)}
                  />
                  <EvoDashWeb.ReviewComponents.commit_diff_layout
                    :if={@commit_data}
                    files={@commit_data.files}
                    expanded_files={@expanded_files}
                    selected_file={@selected_file}
                    file_context_levels={@file_context_levels}
                    expanded_dirs={@tree_expanded_dirs}
                    file_filter={@file_filter}
                    diff_in_flight={@diff_in_flight}
                  />
                <% end %>
              </div>
            <% else %>
              <%!-- Aggregate stats across ALL review repos (primary + foreign):
                   the header stat row, the tab count badges, and the
                   conversation diff-stats bar read the SUMS, never the active
                   repo alone. Header repo fields are PRIMARY-scoped (resolved
                   explicitly, never the active-repo projection).
                   All three are DERIVED ONCE per data mutation
                   (`EvoDashWeb.ReviewLive.Aggregates`, cached by LoadData and
                   `put_derived/1`) — never recomputed in this render. --%>
              <div class="space-y-4 pb-8">
                <EvoDashWeb.ReviewComponents.page_header
                  back_url={with_node_param(~p"/projects", @current_node_id)}
                  title={@title}
                  status={@review_status}
                  task_status={@task_status}
                  task_type={@task_type}
                  task_id={@task_id}
                  repo_path={@primary_repo && @primary_repo.repo_path}
                  branch_name={@primary_repo && @primary_repo.branch_name}
                  merge_target={@primary_repo && @primary_repo.default_merge_target}
                  commit_sha={@primary_repo && @primary_repo.commit_sha}
                  model_id={@model_id}
                  agent_count={@agent_count}
                  started_at={@started_at}
                  finished_at={@finished_at}
                  node_name={@current_node_name}
                  show_review_status={@outcome != :failed}
                  stats={if EvoDashWeb.ReviewLive.Outcome.show_stats?(@stats, @outcome), do: @stats}
                />

                <%!-- The terminal-outcome banner: directly under the header so
                     it is visible on EVERY tab. Renders nothing for a
                     completed task that recorded a report. --%>
                <EvoDashWeb.ReviewComponents.task_outcome_banner
                  outcome={@outcome}
                  task_status={@task_status}
                  task_error={@task_error}
                  has_report={@has_report}
                  has_changes={not @is_no_changes}
                  diagnostics_url={diagnostics_url(@task_id, @current_node_id)}
                />

                <!-- Page tabs (underline bar with count badges) -->
                <%!-- the archive's LABEL size once a page lands; 0/unknown renders no badge.
                     The tab itself only renders for a task that opted into archiving. --%>
                <EvoDashWeb.ReviewComponents.page_tabs
                  active_tab={@review_tab}
                  files_count={@stats.files_count}
                  commits_count={@stats.commits_count}
                  show_archive={@archive_opt_in?}
                  archive_count={@archive_label_total}
                />

                <%!-- A reload keeps the shell on screen and says so here. --%>
                <.reload_status :if={@loading and @page_ready?} />

                <%!-- Re-keyed per tab, so the reduced-motion-safe enter
                     animation replays on every switch (no JS, no keyframes
                     added: `.wizard-step-enter` is the shared CSS). --%>
                <div
                  class="wizard-step-enter"
                  id={"review-tab-" <> to_string(@review_tab)}
                  aria-busy={@loading and @page_ready?}
                >
                  <%= cond do %>
                    <% @review_tab == :conversation -> %>
                      <!-- Readability column (GitHub conversation style); the
                         per-repo cards sit at the BOTTOM of the column. -->
                      <div class="max-w-4xl mx-auto w-full space-y-4">
                        <EvoDashWeb.ReviewComponents.agent_summary
                          summary={@agent_summary}
                          summary_raw={@summary_raw}
                          model_id={@model_id}
                          finished_at={@finished_at}
                        />

                        <EvoDashWeb.ReviewComponents.diff_stats_bar
                          :if={EvoDashWeb.ReviewLive.Outcome.show_stats?(@stats, @outcome)}
                          files_count={@stats.files_count}
                          additions={@stats.additions}
                          deletions={@stats.deletions}
                          commits_count={@stats.commits_count}
                        />

                        <EvoDashWeb.ReviewComponents.task_summary
                          usage={@task_usage}
                          agent_count={@agent_count}
                          task_type={@task_type}
                          status={@task_status}
                          model_id={@model_id}
                          started_at={@started_at}
                          finished_at={@finished_at}
                        />

                        <EvoDashWeb.ReviewComponents.repo_cards
                          repos={@review_repos}
                          completion={@completion_status}
                          back_url={with_node_param(~p"/projects", @current_node_id)}
                          review_action={@review_action}
                          busy_repos={@busy_repos}
                          actions_allowed={EvoDashWeb.ReviewLive.Outcome.actions_allowed?(@outcome)}
                          task_outcome={@outcome}
                        />

                        <EvoDashWeb.ReviewComponents.task_actions
                          can_resume={@can_resume}
                          loading={@action_loading}
                          branch_exists={
                            @branch_exists and
                              EvoDashWeb.ReviewLive.Outcome.actions_allowed?(@outcome)
                          }
                          has_pr={@has_pr}
                          pr_url={@pr_url}
                          show_export={EvoDashWeb.ReviewLive.ArchiveLoad.export_available?(assigns)}
                          export_url={with_node_param("/tasks/#{@task_id}/export", @current_node_id)}
                          no_changes={
                            EvoDashWeb.ReviewLive.Outcome.dismissable?(@outcome, @is_no_changes)
                          }
                        />

                        <EvoDashWeb.ReviewComponents.extract_skills_modal show={@show_extract_modal} />
                      </div>
                    <% @review_tab == :objective -> %>
                      <%!-- Readability column hosting the objective card
                         (moved off the conversation pane; markdown/raw toggle
                         + copy live inside the component header). --%>
                      <div class="max-w-4xl mx-auto w-full space-y-4">
                        <EvoDashWeb.ReviewComponents.objective_section
                          objective={@objective}
                          objective_raw={@objective_raw}
                        />
                      </div>
                    <% @review_tab == :files_changed -> %>
                      <!-- FULL WIDTH (no max-w): the split layout owns the row;
                         repo selection lives in its toolbar. The diff + tree
                         state maps are repo-keyed — read the ACTIVE repo's
                         submap via inline Map.Get. -->
                      <EvoDashWeb.ReviewComponents.split_diff_layout
                        files={@review_data && @review_data.files}
                        expanded_files={Map.get(@expanded_files, @active_repo_id, %{})}
                        selected_file={Map.get(@selected_file || %{}, @active_repo_id)}
                        file_context_levels={Map.get(@file_context_levels, @active_repo_id, %{})}
                        expanded_dirs={Map.get(@tree_expanded_dirs, @active_repo_id, %{})}
                        file_filter={@file_filter}
                        repos={@review_repos}
                        active_repo_id={@active_repo_id}
                        diff_in_flight={@diff_in_flight}
                      />
                    <% @review_tab == :commits -> %>
                      <%!-- Lists the ACTIVE repo's commits (projected by
                         project_active_repo/1). Multi-repo reviews show a repo
                         selector inside commits_list (rendered only when more
                         than one repo) — active_repo_id drives the projection. --%>
                      <EvoDashWeb.ReviewComponents.commits_list
                        commits={@commits}
                        repos={@review_repos}
                        active_repo_id={@active_repo_id}
                        task_id={@task_id}
                        node_id={@current_node_id}
                      />
                    <% @review_tab == :archive -> %>
                      <%!-- Lazy, PAGED archive: the page load is LITE (no
                         archive transfer), so opening this tab triggers a
                         cached on-demand load of the FIRST page; "Load more"
                         appends further pages and each agent's heavy result is
                         fetched on demand. Every state renders inside
                         ArchiveLoad.panel. --%>
                      <EvoDashWeb.ReviewLive.ArchiveLoad.panel
                        state={@archive_state}
                        records={@archive_records}
                        total={@archive_total}
                        opt_in?={@archive_opt_in?}
                        dropped={@archive_dropped}
                        exhausted?={@archive_exhausted?}
                        server_total={@archive_server_total}
                        loading_more?={@archive_loading_more?}
                        more_error={@archive_more_error}
                        agent_results={@archive_agent_results}
                        error={@archive_error}
                        task_id={@task_id}
                        node_id={@current_node_id}
                      />
                  <% end %>
                </div>

                <%= if @branch_exists and is_nil(@review_data) and not @loading do %>
                  <div class="rounded-xl border border-warning/30 bg-warning/10 p-4 text-center space-y-3">
                    <.icon name="hero-exclamation-triangle" class="size-6 text-warning mx-auto" />
                    <p class="text-sm text-warning">
                      {gettext(
                        "Could not load diff data. The branch may have been modified externally."
                      )}
                    </p>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        <% end %>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  # The compact in-shell refresh strip for a SCOPED reload: once the page has
  # rendered real data (`@page_ready?`), a reload keeps the whole shell on
  # screen (header, tabs, current tab body) and only this strip reports that
  # the data on screen is being refreshed.
  #
  # The spinner + the `Loading review data...` text are deliberately the SAME
  # vocabulary the full-page spinner used, because the page's load-settling
  # helpers (`EvoDashWeb.TestHelpers.flush_loading/4` callers) drain a reload by
  # waiting for that exact string.
  defp reload_status(assigns) do
    ~H"""
    <div
      id="review-reload-status"
      role="status"
      class="flex items-center gap-2 text-sm text-base-content/60"
    >
      <span class="loading loading-spinner loading-sm text-primary-standalone"></span>
      <span>{gettext("Loading review data...")}</span>
    </div>
    """
  end

  defp review_commits_path(task_id, node_id, repo_id) do
    params = %{tab: "commits"}
    params = if node_id, do: Map.put(params, :node, node_id), else: params
    params = if repo_id != "primary", do: Map.put(params, :repo, repo_id), else: params
    ~p"/review/#{task_id}?#{params}"
  end

  # The outcome banner's escape hatch to the task's own diagnostics: the Tasks
  # page focuses the task named by `?task=<id>` (and keeps the viewed node).
  defp diagnostics_url(task_id, node_id) do
    params = %{task: task_id}
    params = if node_id, do: Map.put(params, :node, node_id), else: params
    ~p"/tasks?#{params}"
  end
end
