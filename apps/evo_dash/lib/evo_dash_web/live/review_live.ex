defmodule EvoDashWeb.ReviewLive do
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
            <.link navigate={~p"/"} class="btn btn-ghost rounded-full btn-sm gap-1 px-4">
              <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back")}
            </.link>
          </div>

          <!-- Loading state -->
          <%= if @loading do %>
            <div class="flex items-center justify-center py-20">
              <span class="loading loading-spinner loading-lg text-primary"></span>
              <span class="ml-3 text-base-content/60">{gettext("Loading review data...")}</span>
            </div>
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
                    </div>

                  <% @review_tab == :commits -> %>
                    <EvoDashWeb.ReviewComponents.commits_list commits={@commits} />

                  <% @review_tab == :files_changed -> %>
                    <%= if @review_data do %>
                      <EvoDashWeb.ReviewComponents.split_diff_layout
                        files={@review_data.files}
                        expanded_files={@expanded_files}
                        selected_file={@selected_file}
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
        </div>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(%{"task_id" => task_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
    end

    config_status =
      try do
        EvoGit.Config.config_status()
      rescue
        _ -> %{missing: [], warnings: [], ok?: true}
      catch
        _, _ -> %{missing: [], warnings: [], ok?: true}
      end

    socket =
      socket
      |> assign(:config_status, config_status)
      |> assign(:task_id, task_id)
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:action_loading, false)
      |> assign(:selected_file, nil)
      |> assign(:expanded_files, %{})
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
      |> assign(:repo_path, nil)
      |> assign(:base_sha, nil)
      |> assign(:objective, nil)
      |> load_task_data(task_id)

    {:ok, socket}
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

    TaskRegistry.set_review_status(task_id, :continued)

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("Continuing from branch %{branch} at %{sha}",
         branch: branch_name,
         sha: String.slice(commit_sha || "", 0..7)
       )
     )
     |> push_navigate(to: ~p"/?starting_commit=#{commit_sha}")}
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

        review_data =
          if branch_exists && repo_path do
            case Review.load_review_metadata(repo_path, branch_name) do
              {:ok, data} -> data
              _ -> nil
            end
          else
            nil
          end

        base_sha = if review_data, do: review_data.base_sha, else: nil

        commits =
          if branch_exists && repo_path do
            {:ok, commits} = Review.list_commits(repo_path, branch_name)
            commits
          else
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
        |> assign(:selected_file, nil)
        |> assign(:repo_path, repo_path)
        |> assign(:objective, objective)
        |> assign(:commits, commits)
    end
  end

  defp maybe_load_diff(socket, path) do
    review_data = socket.assigns.review_data
    file = review_data && Enum.find(review_data.files, &(&1.path == path))

    if file && is_nil(file.diff) do
      %{base_sha: base_sha, commit_sha: commit_sha, repo_path: repo_path} = socket.assigns

      case Review.load_file_diff(repo_path, base_sha, commit_sha, path) do
        {:ok, diff_string} ->
          updated_files =
            Enum.map(review_data.files, fn f ->
              if f.path == path, do: %{f | diff: diff_string}, else: f
            end)

          updated_review_data = %{review_data | files: updated_files}
          expanded_files = Map.put(socket.assigns.expanded_files, path, true)

          {:noreply,
           socket
           |> assign(:review_data, updated_review_data)
           |> assign(:expanded_files, expanded_files)}

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

  defp truncate_string(nil, _len), do: ""
  defp truncate_string(str, len) when byte_size(str) <= len, do: str
  defp truncate_string(str, len), do: String.slice(str, 0, len) <> "..."

  defp file_path_to_id(path) do
    path
    |> String.replace(~r{[^a-zA-Z0-9_-]}, "-")
    |> String.trim("-")
  end
end
