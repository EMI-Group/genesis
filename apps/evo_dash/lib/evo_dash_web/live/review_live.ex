defmodule EvoDashWeb.ReviewLive do
  @moduledoc """
  Code review page for completed tasks.

  Displays agent-produced changes as a GitHub-style diff with merge,
  reject, and continue actions, plus optional GitHub PR creation.
  """
  use EvoDashWeb, :live_view
  alias EvoDash.TaskRegistry
  alias EvoGit.Review

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:review} config_status={@config_status}>
      <%= if @error do %>
        <div class="bg-error/10 border border-error/20 rounded-3xl p-8 text-center">
          <.icon name="hero-exclamation-triangle" class="size-12 text-error mx-auto mb-4" />
          <h2 class="text-xl font-bold text-error mb-2">{gettext("Review Not Available")}</h2>
          <p class="text-sm text-base-content/60 mb-4">{@error}</p>
          <.link navigate={~p"/"} class="btn btn-primary rounded-full px-6 gap-2">
            <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to Dashboard")}
          </.link>
        </div>
      <% else %>
        <div class="space-y-4">
          <!-- Back button -->
          <div class="flex items-center gap-3">
            <%= if @live_action == :commit do %>
              <.link navigate={~p"/review/#{@task_id}"} class="btn btn-ghost rounded-full btn-sm gap-1 px-4">
                <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to Review")}
              </.link>
            <% else %>
              <.link navigate={~p"/"} class="btn btn-ghost rounded-full btn-sm gap-1 px-4">
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

              <!-- Unified review card: tab bar + content -->
              <div class="review-card">
                <!-- Tab Bar (sticky header of the card) -->
                <div class="review-card-tabs">
                  <EvoDashWeb.ReviewComponents.review_tabs
                    active_tab={@review_tab}
                    files_count={if @review_data, do: @review_data.changed_files_count, else: 0}
                    commits_count={length(@commits)}
                  />
                </div>

                <!-- Content area -->
                <div class="review-card-content">
                  <%= cond do %>
                    <% @review_tab == :conversation -> %>
                      <div class="space-y-4 p-4 sm:p-6 lg:p-8">
                        <!-- Agent Summary -->
                        <%= if @agent_summary do %>
                          <EvoDashWeb.ReviewComponents.agent_summary summary={@agent_summary} />
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
                          has_pr={@has_pr}
                          pr_url={@pr_url}
                          loading={@action_loading}
                        />
                        <EvoDashWeb.ReviewComponents.extract_skills_modal
                          show={@show_extract_modal}
                        />
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
                          <.icon name="hero-document-magnifying-glass" class="size-10 text-base-content/30 mx-auto mb-3" />
                          <p class="text-sm text-base-content/50">{gettext("No diff data available for this review.")}</p>
                        </div>
                      <% end %>
                  <% end %>
                </div>
              </div>

              <%= if @branch_exists and is_nil(@review_data) and not @loading do %>
                <div class="bg-warning/10 border border-warning/20 rounded-3xl p-6 text-center">
                  <.icon name="hero-exclamation-triangle" class="size-8 text-warning mx-auto mb-3" />
                  <p class="text-sm text-warning">{gettext("Could not load diff data. The branch may have been modified externally.")}</p>
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

    config_status = safe_config_status()

    socket =
      socket
      |> assign(:config_status, config_status)
      |> assign(:task_id, task_id)
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:action_loading, false)
      |> assign(:selected_file, nil)
      |> assign(:expanded_files, %{})
      |> assign(:file_context_levels, %{})
      |> assign(:review_tab, :conversation)
      |> assign(:review_data, nil)
      |> assign(:title, "")
      |> assign(:task_type, :unknown)
      |> assign(:branch_name, nil)
      |> assign(:commit_sha, nil)
      |> assign(:agent_summary, nil)
      |> assign(:review_status, :open)
      |> assign(:branch_exists, false)
      |> assign(:has_pr, false)
      |> assign(:pr_url, nil)
      |> assign(:show_extract_modal, false)
      |> assign(:repo_path, nil)
      |> assign(:base_sha, nil)
      |> assign(:objective, nil)
      |> assign(:inspect_commit_sha, params["commit_sha"])
      |> assign(:commit_data, nil)
      |> assign(:commit_header, nil)
      |> load_task_data(task_id)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
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

  def handle_event("switch_tab", %{"tab" => "files_changed"}, socket) do
    {:noreply, assign(socket, :review_tab, :files_changed)}
  end

  def handle_event("switch_tab", %{"tab" => "commits"}, socket) do
    {:noreply, assign(socket, :review_tab, :commits)}
  end

  def handle_event("switch_tab", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_file", %{"path" => path}, socket) do
    target_id = "file-section-#{file_path_to_id(path)}"

    socket =
      socket
      |> assign(:selected_file, path)
      |> assign(:review_tab, :files_changed)
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
        {:noreply, update_file_diff_in_socket(socket, path, diff_string, new_level)}

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
  def handle_event("merge", _params, socket) do
    %{repo_path: repo_path, branch_name: branch_name, task_id: task_id} = socket.assigns

    case Review.merge_branch(repo_path, branch_name) do
      {:ok, _sha} ->
        TaskRegistry.set_review_status(task_id, :merged)

        {:noreply,
         socket
         |> put_flash(
           :success,
           gettext("Changes merged successfully! Branch %{branch} has been deleted.",
             branch: branch_name
           )
         )
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

    query = [starting_commit: commit_sha]
    # Include project query param so the dashboard re-opens the correct project
    query = if repo_path, do: Keyword.put(query, :project, repo_path), else: query

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("Continuing from branch %{branch} at %{sha}",
         branch: branch_name,
         sha: String.slice(commit_sha || "", 0..7)
       )
     )
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
  def handle_info({:tasks_updated}, socket) do
    {:noreply, load_task_data(socket, socket.assigns.task_id)}
  end

  @impl true
  def handle_info({:task_status, _task_id, _status}, socket) do
    {:noreply, load_task_data(socket, socket.assigns.task_id)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Private Helpers ---

  defp load_task_data(socket, task_id) do
    case TaskRegistry.get_task(task_id) do
      nil ->
        socket
        |> assign(:loading, false)
        |> assign(:error, gettext("Task not found. It may have been deleted."))
        |> assign(:repo_path, nil)
        |> assign(:objective, nil)

      task ->
        result = task.result
        repo_path = task.opts[:path]

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

        objective = task.opts[:prompt] || task.opts[:objective]

        title = pr_title || objective || branch_name || gettext("Review Changes")

        branch_exists = branch_name && repo_path && Review.branch_exists?(repo_path, branch_name)

        rs = Map.get(task, :review_status)

        review_status =
          cond do
            branch_name == nil -> :no_changes
            rs != nil -> rs
            not branch_exists -> :open
            true -> :open
          end

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

        socket
        |> assign(:loading, false)
        |> assign(:error, nil)
        |> assign(:title, title)
        |> assign(:task_type, task.type)
        |> assign(:branch_name, branch_name)
        |> assign(:commit_sha, commit_sha)
        |> assign(:base_sha, base_sha)
        |> assign(:agent_summary, agent_summary)
        |> assign(:review_status, review_status)
        |> assign(:branch_exists, branch_exists || false)
        |> assign(:has_pr, pr_url != nil)
        |> assign(:pr_url, pr_url)
        |> assign(:review_data, review_data)
        |> assign(:expanded_files, %{})
        |> assign(:file_context_levels, %{})
        |> assign(:selected_file, nil)
        |> assign(:repo_path, repo_path)
        |> assign(:objective, objective)
        |> assign(:commits, commits)
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
          {:noreply, update_file_diff_in_socket(socket, path, diff_string, 3)}

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
          {:noreply, update_file_diff_in_socket(socket, path, diff_string, 3)}

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

  # Updates a file's diff in the appropriate data source (commit_data or review_data)
  # and sets the context level and expanded state.
  defp update_file_diff_in_socket(socket, path, diff_string, context_level) do
    data_key =
      if socket.assigns.live_action == :commit, do: :commit_data, else: :review_data

    data = Map.get(socket.assigns, data_key)

    updated_files =
      Enum.map(data.files, fn f ->
        if f.path == path, do: %{f | diff: diff_string}, else: f
      end)

    updated_data = %{data | files: updated_files}
    expanded_files = Map.put(socket.assigns.expanded_files, path, true)
    file_context_levels = Map.put(socket.assigns.file_context_levels, path, context_level)

    socket
    |> assign(data_key, updated_data)
    |> assign(:expanded_files, expanded_files)
    |> assign(:file_context_levels, file_context_levels)
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

    socket
    |> assign(:inspect_commit_sha, commit_sha)
    |> assign(:commit_header, commit_header)
    |> assign(:commit_data, commit_data)
    |> assign(:expanded_files, %{})
    |> assign(:file_context_levels, %{})
    |> assign(:selected_file, nil)
  end

  defp file_path_to_id(path) do
    path
    |> String.replace(~r{[^a-zA-Z0-9_-]}, "-")
    |> String.trim("-")
  end
end
