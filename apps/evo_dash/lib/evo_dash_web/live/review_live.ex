defmodule EvoDashWeb.ReviewLive do
  @moduledoc """
  Code review page for completed tasks.

  Displays agent-produced changes as a GitHub-style diff with merge,
  reject, and continue actions, plus optional GitHub PR creation.
  """
  use EvoDashWeb, :live_view
  alias EvoGit.TaskRegistry
  alias EvoGit.Review

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:review}
      config_status={@config_status}
      current_node_id={@current_node_id}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      pending_tasks={@pending_tasks}
    >
      <%= if @error do %>
        <div class="rounded-lg border border-error/30 bg-error/5 p-6 text-center">
          <.icon name="hero-exclamation-triangle" class="size-8 text-error mx-auto mb-4" />
          <h2 class="text-xl font-bold text-error mb-2">{gettext("Review Not Available")}</h2>
          <p class="text-sm text-base-content/60 mb-4">{@error}</p>
          <.link navigate={~p"/"} class="btn btn-primary px-6 gap-2">
            <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to Dashboard")}
          </.link>
        </div>
      <% else %>
        <div class="space-y-4">
          <!-- Back button -->
          <div class="flex items-center gap-3">
            <%= if @live_action == :commit do %>
              <.link navigate={~p"/review/#{@task_id}"} class="btn btn-ghost btn-sm gap-1 px-4">
                <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to Review")}
              </.link>
            <% else %>
              <.link navigate={~p"/"} class="btn btn-ghost btn-sm gap-1 px-4">
                <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
              </.link>
            <% end %>
          </div>

          <!-- Loading state -->
          <%= if @loading do %>
            <div class="flex items-center justify-center py-20">
              <span class="loading loading-spinner loading-lg text-primary"></span>
              <span class="ml-3 text-base-content/60">{gettext("Loading review data...")}</span>
            </div>
          <% else %>
            <%= if @live_action == :commit and @commit_data do %>
              <!-- Commit detail view -->
              <EvoDashWeb.ReviewComponents.commit_detail_header commit={@commit_header} />
              <EvoDashWeb.ReviewComponents.commit_diff_layout
                files={@commit_data.files}
                expanded_files={@expanded_files}
                selected_file={@selected_file}
                file_context_levels={@file_context_levels}
              />
            <% else %>
              <!-- Review Header (always at top) -->
              <EvoDashWeb.ReviewComponents.review_header
                title={@title}
                task_type={@task_type}
                branch_name={@branch_name}
                commit_sha={@commit_sha}
                status={@review_status}
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

              <!-- Unified review card: tab bar + content -->
              <div class="review-card">
                <!-- Tab Bar (sticky header of the card) -->
                <div class="review-card-tabs">
                  <EvoDashWeb.ReviewComponents.review_tabs
                    active_tab={@review_tab}
                    files_count={if @review_data, do: @review_data.changed_files_count, else: 0}
                    commits_count={length(@commits)}
                    show_archive={@archive_metadata not in [nil, []]}
                    agents_count={if @archive_metadata, do: length(@archive_metadata), else: 0}
                  />
                </div>

                <!-- Content area -->
                <div class="review-card-content">
                  <%= cond do %>
                    <% @review_tab == :conversation -> %>
                      <div class="space-y-4 p-4 sm:p-6 lg:p-8">
                        <!-- Agent Summary -->
                        <%= if @agent_summary do %>
                          <EvoDashWeb.ReviewComponents.agent_summary
                            summary={@agent_summary}
                            summary_raw={@summary_raw}
                          />
                        <% end %>

                        <!-- Diff Stats -->
                        <%= if @review_data do %>
                          <EvoDashWeb.ReviewComponents.diff_stats_bar
                            files_count={@review_data.changed_files_count}
                            additions={@review_data.total_additions}
                            deletions={@review_data.total_deletions}
                            commits_count={length(@commits)}
                          />
                        <% end %>

                        <!-- Action Buttons -->
                        <EvoDashWeb.ReviewComponents.action_buttons
                          branch_exists={@branch_exists}
                          can_continue={@can_continue}
                          has_pr={@has_pr}
                          pr_url={@pr_url}
                          loading={@action_loading}
                          is_no_changes={@is_no_changes}
                          merge_targets={@merge_targets}
                          default_merge_target={@default_merge_target}
                        />
                        <%= if @archive_metadata not in [nil, []] do %>
                          <.link
                            href={"/tasks/#{@task_id}/export"}
                            class="btn btn-sm btn-outline btn-primary gap-2"
                            download
                          >
                            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext(
                              "Export JSON"
                            )}
                          </.link>
                        <% end %>
                        <EvoDashWeb.ReviewComponents.extract_skills_modal show={@show_extract_modal} />
                      </div>
                    <% @review_tab == :objective -> %>
                      <div class="p-4 sm:p-6 lg:p-8">
                        <EvoDashWeb.ReviewComponents.objective_section objective={@objective} />
                      </div>
                    <% @review_tab == :commits -> %>
                      <EvoDashWeb.ReviewComponents.commits_list commits={@commits} />
                    <% @review_tab == :files_changed -> %>
                      <%= if @review_data do %>
                        <EvoDashWeb.ReviewComponents.split_diff_layout
                          files={@review_data.files}
                          expanded_files={@expanded_files}
                          selected_file={@selected_file}
                          file_context_levels={@file_context_levels}
                        />
                      <% else %>
                        <div class="p-8 text-center">
                          <.icon
                            name="hero-document-magnifying-glass"
                            class="size-10 text-base-content/30 mx-auto mb-3"
                          />
                          <p class="text-sm text-base-content/50">
                            {gettext("No diff data available for this review.")}
                          </p>
                        </div>
                      <% end %>
                    <% @review_tab == :archive -> %>
                      <%= if @archive_metadata not in [nil, []] do %>
                        <div class="p-4 sm:p-6 lg:p-8">
                          <EvoDashWeb.ReviewComponents.archive_review_section
                            archive_metadata={@archive_metadata}
                            task_id={@task_id}
                          />
                        </div>
                      <% else %>
                        <div class="p-8 text-center">
                          <.icon
                            name="hero-archive-box-x-mark"
                            class="size-10 text-base-content/30 mx-auto mb-3"
                          />
                          <p class="text-sm text-base-content/50">
                            {gettext("No archived agent data available for this task.")}
                          </p>
                        </div>
                      <% end %>
                  <% end %>
                </div>
              </div>

              <%= if @branch_exists and is_nil(@review_data) and not @loading do %>
                <div class="rounded-lg border border-warning/30 bg-warning/5 p-4 text-center">
                  <.icon name="hero-exclamation-triangle" class="size-6 text-warning mx-auto mb-3" />
                  <p class="text-sm text-warning">
                    {gettext(
                      "Could not load diff data. The branch may have been modified externally."
                    )}
                  </p>
                </div>
              <% end %>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(%{"task_id" => task_id} = params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
    end

    config_status = config_status()

    socket =
      socket
      |> assign(
        config_status: config_status,
        task_id: task_id,
        loading: true,
        error: nil,
        action_loading: false,
        selected_file: nil,
        expanded_files: %{},
        file_context_levels: %{},
        review_tab: :conversation,
        review_data: nil,
        title: "",
        task_type: :unknown,
        branch_name: nil,
        commit_sha: nil,
        agent_summary: nil,
        review_status: :open,
        branch_exists: false,
        can_continue: false,
        is_no_changes: false,
        has_pr: false,
        pr_url: nil,
        show_extract_modal: false,
        repo_path: nil,
        base_sha: nil,
        objective: nil,
        inspect_commit_sha: params["commit_sha"],
        commit_data: nil,
        commit_header: nil,
        archive_metadata: nil,
        task_usage: nil,
        agent_count: nil,
        task_status: nil,
        model_id: nil,
        summary_raw: false,
        started_at: nil,
        finished_at: nil,
        merge_targets: [],
        default_merge_target: nil
      )
      |> load_task_data(task_id)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/review/#{socket.assigns.task_id}")

    case {socket.assigns.live_action, params["commit_sha"]} do
      {:commit, commit_sha} when is_binary(commit_sha) ->
        {:noreply, load_commit_inspection(socket, commit_sha)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => "conversation"}, socket) do
    {:noreply, assign(socket, :review_tab, :conversation)}
  end

  def handle_event("switch_tab", %{"tab" => "objective"}, socket) do
    {:noreply, assign(socket, :review_tab, :objective)}
  end

  def handle_event("switch_tab", %{"tab" => "files_changed"}, socket) do
    {:noreply, assign(socket, :review_tab, :files_changed)}
  end

  def handle_event("switch_tab", %{"tab" => "commits"}, socket) do
    {:noreply, assign(socket, :review_tab, :commits)}
  end

  def handle_event("switch_tab", %{"tab" => "archive"}, socket) do
    {:noreply, assign(socket, :review_tab, :archive)}
  end

  def handle_event("switch_tab", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_summary_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :summary_raw, mode == "raw")}
  end

  @impl true
  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
  end

  @impl true
  def handle_event("select_file", %{"path" => path}, socket) do
    target_id = "file-section-#{file_path_to_id(path)}"

    socket =
      assign(socket,
        selected_file: path,
        review_tab: :files_changed
      )
      |> push_event("scroll_to_file", %{target_id: target_id})

    # Trigger diff loading if file diff is nil
    maybe_load_diff(socket, path)
  end

  @impl true
  def handle_event("toggle_file_expansion", %{"path" => path}, socket) do
    expanded_files = socket.assigns.expanded_files
    current = Map.get(expanded_files, path, false)
    new_expanded = Map.put(expanded_files, path, !current)
    socket = assign(socket, :expanded_files, new_expanded)

    # If expanding a file whose diff is nil, trigger lazy load
    if !current do
      maybe_load_diff(socket, path)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("load_file_diff", %{"path" => path}, socket) do
    maybe_load_diff(socket, path)
  end

  @impl true
  def handle_event("inspect_commit", %{"sha" => sha}, socket) do
    {:noreply, push_patch(socket, to: ~p"/review/#{socket.assigns.task_id}/commit/#{sha}")}
  end

  @impl true
  def handle_event("expand_context", %{"path" => path}, socket) do
    current_level = Map.get(socket.assigns.file_context_levels, path, 3)

    new_level =
      cond do
        current_level == :all -> :all
        current_level >= 30 -> :all
        true -> current_level + 20
      end

    opts = if new_level == :all, do: [context: :all], else: [context: new_level]

    case load_file_diff_for_mode(socket, path, opts) do
      {:ok, diff_string} ->
        # Context expansion doesn't change the file content — preserve the
        # full_new_content/full_old_content already fetched on the initial
        # lazy-load so file-level highlighting stays effective.
        {:noreply,
         update_file_diff_in_socket(socket, path, diff_string, new_level, :preserve, :preserve)}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to expand context: %{reason}", reason: inspect(reason))
         )}
    end
  end

  @impl true
  def handle_event("merge", params, socket) do
    %{
      repo_path: repo_path,
      branch_name: branch_name,
      task_id: task_id,
      merge_targets: merge_targets,
      default_merge_target: default_merge_target
    } = socket.assigns

    # The target branch comes from the merge form's `target_branch` select;
    # a plain `phx-click="merge"` (legacy path) submits no params.
    target =
      case params do
        %{"target_branch" => target} when is_binary(target) ->
          case String.trim(target) do
            "" -> nil
            trimmed -> trimmed
          end

        _ ->
          nil
      end

    # Sanity check: when a known branch list was loaded, only accept a
    # submitted target that is a member of it; otherwise fall back to the
    # resolved default (or no target).
    target =
      if target != nil and merge_targets != [] and target not in merge_targets do
        default_merge_target
      else
        target
      end

    # The effective target (explicitly chosen or the resolved default) is
    # what the merge actually used — mention it in the success flash.
    effective_target = target || default_merge_target

    result =
      if target do
        Review.merge_branch(repo_path, branch_name, target)
      else
        Review.merge_branch(repo_path, branch_name)
      end

    case result do
      {:ok, _sha} ->
        TaskRegistry.set_review_status(task_id, :merged)

        success_flash =
          if effective_target do
            gettext(
              "Changes merged successfully into %{target}! Branch %{branch} has been deleted.",
              target: effective_target,
              branch: branch_name
            )
          else
            gettext("Changes merged successfully! Branch %{branch} has been deleted.",
              branch: branch_name
            )
          end

        {:noreply,
         socket
         |> put_flash(:success, success_flash)
         |> push_navigate(to: ~p"/")}

      {:conflict, details} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Merge conflict! Please resolve manually. %{details}",
             details: truncate_string(details, 200)
           )
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Merge failed: %{reason}", reason: inspect(reason)))}
    end
  end

  @impl true
  def handle_event("reject", _params, socket) do
    %{repo_path: repo_path, branch_name: branch_name, task_id: task_id} = socket.assigns

    case Review.reject_branch(repo_path, branch_name) do
      :ok ->
        TaskRegistry.set_review_status(task_id, :rejected)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Changes rejected. Branch %{branch} has been deleted.", branch: branch_name)
         )
         |> push_navigate(to: ~p"/")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Failed to reject changes: %{reason}", reason: inspect(reason))
         )}
    end
  end

  @impl true
  def handle_event("continue", _params, socket) do
    commit_sha = socket.assigns.commit_sha
    branch_name = socket.assigns.branch_name
    task_id = socket.assigns.task_id
    repo_path = socket.assigns.repo_path

    TaskRegistry.set_review_status(task_id, :continued)

    query = [resume_from: task_id]
    query = if commit_sha, do: Keyword.put(query, :starting_commit, commit_sha), else: query
    # Include project query param so the dashboard re-opens the correct project
    query = if repo_path, do: Keyword.put(query, :project, repo_path), else: query

    flash_msg =
      if commit_sha do
        gettext("Continuing from branch %{branch} at %{sha}",
          branch: branch_name,
          sha: String.slice(commit_sha, 0..7)
        )
      else
        gettext(
          "Continuing from investigation task. A new evolve task form has been prepared for you."
        )
      end

    {:noreply,
     socket
     |> put_flash(:info, flash_msg)
     |> push_navigate(to: ~p"/?#{query}")}
  end

  @impl true
  def handle_event("ignore", _params, socket) do
    task_id = socket.assigns.task_id

    TaskRegistry.set_review_status(task_id, :ignored)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Review ignored and dismissed."))
     |> push_navigate(to: ~p"/")}
  end

  @impl true
  def handle_event("create_pr", _params, socket) do
    %{repo_path: repo_path, branch_name: branch_name, objective: objective, agent_summary: result} =
      socket.assigns

    socket = assign(socket, :action_loading, true)

    case Review.create_github_pr(repo_path, branch_name, objective || "", result || "") do
      {pr_url, pr_title} when is_binary(pr_url) ->
        {:noreply,
         socket
         |> assign(:action_loading, false)
         |> assign(:has_pr, true)
         |> assign(:pr_url, pr_url)
         |> put_flash(
           :success,
           gettext("Pull request created: %{title}", title: pr_title || pr_url)
         )}

      {nil, nil} ->
        {:noreply,
         socket
         |> assign(:action_loading, false)
         |> put_flash(
           :error,
           gettext(
             "Failed to create pull request. Make sure 'gh' CLI is installed and authenticated."
           )
         )}
    end
  end

  @impl true
  def handle_event("extract_skills", _params, socket) do
    {:noreply, assign(socket, :show_extract_modal, true)}
  end

  @impl true
  def handle_event("cancel_extract_skills", _params, socket) do
    {:noreply, assign(socket, :show_extract_modal, false)}
  end

  @impl true
  def handle_event("confirm_extract_skills", %{"user_note" => user_note}, socket) do
    %{
      repo_path: repo_path,
      title: title,
      objective: objective,
      agent_summary: summary,
      base_sha: base_sha,
      commit_sha: commit_sha,
      commits: commits
    } = socket.assigns

    # Build the commit history string from the CommitInfo list
    commit_history = format_commit_history(commits)

    opts = [
      path: repo_path,
      pr_title: title,
      pr_objective: objective,
      pr_summary: summary,
      pr_commit_history: commit_history,
      base_sha: base_sha,
      commit_sha: commit_sha
    ]

    opts =
      if user_note && user_note != "", do: Keyword.put(opts, :user_note, user_note), else: opts

    case TaskRegistry.start_task(:extract_skills, opts) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> assign(:show_extract_modal, false)
         |> put_flash(
           :info,
           gettext(
             "Skill extraction task started. You can monitor its progress on the dashboard."
           )
         )}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to start skill extraction: %{reason}", reason: inspect(reason))
         )}
    end
  end

  @impl true
  def handle_info({:tasks_updated} = msg, socket) do
    # Debounced via NodeAware — the task-data reload + sidebar reload happen once
    # in handle_info(:node_aware_reload_tasks, socket) when the timer fires.
    # handle_task_info/2 already returns {:noreply, socket}.
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info({:task_status, _task_id, _status} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    # Debounce timer fired: reload the reviewed task's data and the sidebar's
    # running/pending tasks, then clear the debounce-pending flag.
    socket = load_task_data(socket, socket.assigns.task_id)
    socket = EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.clear_task_reload_pending(socket)}
  end

  @impl true
  def handle_info({:node_selected, node_id}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)
  end

  @impl true
  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Private Helpers ---

  defp load_task_data(socket, task_id) do
    case TaskRegistry.get_task(task_id) do
      nil ->
        assign(socket,
          loading: false,
          error: gettext("Task not found. It may have been deleted."),
          repo_path: nil,
          objective: nil,
          task_usage: nil,
          agent_count: nil,
          task_status: nil,
          model_id: nil,
          started_at: nil,
          finished_at: nil
        )

      task ->
        result = task.result
        repo_path = task.opts[:path]

        # Merge-target branch selector: list local branches and resolve the
        # default merge target. Degrades gracefully to [] / nil when branches
        # cannot be listed (e.g. missing repo) — plain case on the tuple
        # returns, no try/rescue.
        {merge_targets, default_merge_target} =
          if repo_path && File.dir?(repo_path) do
            targets =
              case Review.list_branches(repo_path) do
                {:ok, names} -> Enum.filter(names, &(is_binary(&1) and String.trim(&1) != ""))
                _ -> []
              end

            default =
              case Review.default_merge_target(repo_path) do
                {:ok, name} -> name
                _ -> nil
              end

            {targets, default}
          else
            {[], nil}
          end

        {commit_sha, branch_name, agent_summary, pr_url, pr_title} =
          case result do
            {:ok,
             %{
               commit_sha: sha,
               branch_name: branch,
               result: summary,
               pr_url: url,
               pr_title: title
             }} ->
              {sha, branch, summary, url, title}

            _ ->
              {nil, nil, nil, nil, nil}
          end

        objective = (task.opts[:prompt] || task.opts[:objective]) |> to_string() |> String.trim()

        title = pr_title || objective || branch_name || gettext("Review Changes")

        branch_exists =
          !!(branch_name && repo_path && File.dir?(repo_path) &&
               Review.branch_exists?(repo_path, branch_name))

        can_continue =
          repo_path != nil && File.dir?(repo_path) && (commit_sha != nil || branch_name == nil)

        rs = task.review_status

        review_status =
          cond do
            branch_name == nil -> :no_changes
            rs != nil -> rs
            not branch_exists -> :open
            true -> :open
          end

        is_no_changes = branch_name == nil && task.status == :completed

        commit_sha = commit_sha || task.commit_sha

        review_data =
          cond do
            # Normal case: branch still exists
            branch_exists && repo_path ->
              case Review.load_review_metadata(repo_path, branch_name) do
                {:ok, data} -> data
                _ -> nil
              end

            # Post-merge/reject case: branch gone but SHAs persisted
            not branch_exists && repo_path && task.base_sha && commit_sha ->
              case Review.load_review_metadata_from_shas(repo_path, task.base_sha, commit_sha) do
                {:ok, data} -> data
                _ -> nil
              end

            true ->
              nil
          end

        base_sha = if review_data, do: review_data.base_sha, else: task.base_sha

        # Persist SHAs when loading from branch (for future post-merge access)
        if (branch_exists && review_data && is_nil(task.base_sha)) and base_sha do
          TaskRegistry.set_review_metadata(task_id, base_sha, commit_sha)
        end

        commits =
          cond do
            branch_exists && repo_path ->
              {:ok, commits} = Review.list_commits(repo_path, branch_name)
              commits

            not branch_exists && repo_path && task.base_sha && commit_sha ->
              {:ok, commits} = Review.list_commits_from_shas(repo_path, task.base_sha, commit_sha)
              commits

            true ->
              []
          end

        assign(socket,
          loading: false,
          error: nil,
          title: title,
          task_type: task.type,
          branch_name: branch_name,
          commit_sha: commit_sha,
          base_sha: base_sha,
          agent_summary: agent_summary,
          review_status: review_status,
          branch_exists: branch_exists || false,
          can_continue: can_continue || false,
          is_no_changes: is_no_changes,
          has_pr: pr_url != nil,
          pr_url: pr_url,
          review_data: review_data,
          expanded_files: %{},
          file_context_levels: %{},
          selected_file: nil,
          repo_path: repo_path,
          objective: objective,
          commits: commits,
          archive_metadata: task.archive_metadata,
          task_usage: task.usage,
          agent_count: task.agent_count,
          task_status: task.status,
          model_id: task.model_id,
          started_at: task.started_at,
          finished_at: task.finished_at,
          merge_targets: merge_targets,
          default_merge_target: default_merge_target
        )
    end
  end

  defp format_commit_history([]), do: nil

  defp format_commit_history(commits) do
    commits
    |> Enum.map(fn commit ->
      "#{commit.short_sha || commit.sha} (#{commit.author_name}, #{commit.date}): #{commit.message}"
    end)
    |> Enum.join("\n")
  end

  defp maybe_load_diff(socket, path) do
    if socket.assigns.live_action == :commit do
      maybe_load_commit_diff(socket, path)
    else
      maybe_load_review_diff(socket, path)
    end
  end

  defp maybe_load_review_diff(socket, path) do
    review_data = socket.assigns.review_data
    file = review_data && Enum.find(review_data.files, &(&1.path == path))

    if file && is_nil(file.diff) do
      %{base_sha: base_sha, commit_sha: commit_sha, repo_path: repo_path} = socket.assigns

      case Review.load_file_diff(repo_path, base_sha, commit_sha, path) do
        {:ok, diff_string} ->
          full_new = content_or_nil(Review.get_file_content(repo_path, commit_sha, path))
          full_old = content_or_nil(Review.get_file_content(repo_path, base_sha, path))
          {:noreply, update_file_diff_in_socket(socket, path, diff_string, 3, full_new, full_old)}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to load diff for %{path}: %{reason}",
               path: path,
               reason: inspect(reason)
             )
           )}
      end
    else
      {:noreply, socket}
    end
  end

  defp maybe_load_commit_diff(socket, path) do
    commit_data = socket.assigns.commit_data
    file = commit_data && Enum.find(commit_data.files, &(&1.path == path))

    if file && is_nil(file.diff) do
      %{repo_path: repo_path, inspect_commit_sha: commit_sha} = socket.assigns

      case Review.load_commit_file_diff(repo_path, commit_sha, path) do
        {:ok, diff_string} ->
          full_new = content_or_nil(Review.get_file_content(repo_path, commit_sha, path))
          full_old = content_or_nil(Review.get_file_content(repo_path, "#{commit_sha}~1", path))
          {:noreply, update_file_diff_in_socket(socket, path, diff_string, 3, full_new, full_old)}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to load diff for %{path}: %{reason}",
               path: path,
               reason: inspect(reason)
             )
           )}
      end
    else
      {:noreply, socket}
    end
  end

  # Loads a file diff using the appropriate mode (commit vs review).
  defp load_file_diff_for_mode(socket, path, opts) do
    %{repo_path: repo_path} = socket.assigns

    if socket.assigns.live_action == :commit do
      %{inspect_commit_sha: commit_sha} = socket.assigns
      Review.load_file_diff(repo_path, "#{commit_sha}~1", commit_sha, path, opts)
    else
      %{base_sha: base_sha, commit_sha: commit_sha} = socket.assigns
      Review.load_file_diff(repo_path, base_sha, commit_sha, path, opts)
    end
  end

  # Unwrap a {:ok, content} result from Review.get_file_content/3, returning nil
  # for any error (file doesn't exist at that commit — e.g. added/deleted files).
  defp content_or_nil({:ok, content}), do: content
  defp content_or_nil(_), do: nil

  # Updates a file's diff in the appropriate data source (commit_data or review_data)
  # and sets the context level and expanded state.
  #
  # `full_new`/`full_old` accept either content strings, nil, or the sentinel
  # `:preserve` (which carries over the existing file's full-content fields —
  # used by context-expansion where the file content does not change).
  defp update_file_diff_in_socket(socket, path, diff_string, context_level, full_new, full_old) do
    data_key =
      if socket.assigns.live_action == :commit, do: :commit_data, else: :review_data

    data = Map.get(socket.assigns, data_key)

    updated_files =
      Enum.map(data.files, fn f ->
        if f.path == path do
          {new_val, old_val} =
            case {full_new, full_old} do
              {:preserve, :preserve} ->
                {f.full_new_content, f.full_old_content}

              {:preserve, old} ->
                {f.full_new_content, old}

              {neww, :preserve} ->
                {neww, f.full_old_content}

              {neww, old} ->
                {neww, old}
            end

          %{f | diff: diff_string, full_new_content: new_val, full_old_content: old_val}
        else
          f
        end
      end)

    updated_data = %{data | files: updated_files}
    expanded_files = Map.put(socket.assigns.expanded_files, path, true)
    file_context_levels = Map.put(socket.assigns.file_context_levels, path, context_level)

    assign(socket, [
      {data_key, updated_data},
      {:expanded_files, expanded_files},
      {:file_context_levels, file_context_levels}
    ])
  end

  # Loads commit inspection data (file list) for a specific commit.
  defp load_commit_inspection(socket, commit_sha) do
    %{repo_path: repo_path, commits: commits} = socket.assigns

    commit_header =
      Enum.find(commits, &(&1.sha == commit_sha)) ||
        %EvoGit.Review.CommitInfo{
          sha: commit_sha,
          short_sha: String.slice(commit_sha, 0..7),
          message: gettext("Commit details"),
          author_name: "",
          date: DateTime.utc_now()
        }

    commit_data =
      case Review.load_commit_files(repo_path, commit_sha) do
        {:ok, data} -> data
        _ -> nil
      end

    assign(socket,
      inspect_commit_sha: commit_sha,
      commit_header: commit_header,
      commit_data: commit_data,
      expanded_files: %{},
      file_context_levels: %{},
      selected_file: nil
    )
  end

  defp file_path_to_id(path) do
    path
    |> String.replace(~r{[^a-zA-Z0-9_-]}, "-")
    |> String.trim("-")
  end
end
