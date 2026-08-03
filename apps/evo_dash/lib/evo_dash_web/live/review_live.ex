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
  def render(%{live_action: :simple} = assigns) do
    ~H"""
    <EvoDashWeb.Layouts.simple flash={@flash}>
      <div class="min-h-screen flex flex-col">
        <%!-- Thin top bar: back to the tree + task title --%>
        <div class="flex items-center gap-3 px-4 h-11 shrink-0 border-b border-slate-200 bg-white sticky top-0 z-40">
          <.link
            id="simple-review-back"
            navigate={~p"/tree/review"}
            class="flex items-center gap-1 text-xs text-slate-500 hover:text-slate-800 transition-colors shrink-0"
          >
            <.icon name="hero-arrow-left" class="size-4" />
            {gettext("Back")}
          </.link>
          <span class="text-sm font-medium text-slate-900 truncate">{@title}</span>
        </div>

        <div class="flex-1 w-full max-w-5xl mx-auto px-4 py-6">
          <%= cond do %>
            <% @error -> %>
              <div class="rounded-2xl border border-slate-200 bg-white p-8 text-center">
                <.icon
                  name="hero-exclamation-triangle"
                  class="size-8 text-red-500 mx-auto mb-4"
                />
                <h2 class="text-lg font-bold text-slate-900 mb-2">
                  {gettext("Review Not Available")}
                </h2>
                <p class="text-sm text-slate-500 mb-5">{@error}</p>
                <.link navigate={~p"/tree/review"} class="text-sm text-slate-500 underline">
                  {gettext("Back")}
                </.link>
              </div>
            <% @loading -> %>
              <div class="flex items-center justify-center py-20 text-slate-400">
                <span class="loading loading-spinner loading-md"></span>
                <span class="ml-3 text-sm">{gettext("Loading review data...")}</span>
              </div>
            <% true -> %>
              <%= if @agent_summary do %>
                <EvoDashWeb.ReviewComponents.agent_summary
                  summary={@agent_summary}
                  summary_raw={@summary_raw}
                />
              <% end %>

              <%= if @review_data do %>
                <div class="mt-4">
                  <EvoDashWeb.ReviewComponents.diff_stats_bar
                    files_count={@review_data.changed_files_count}
                    additions={@review_data.total_additions}
                    deletions={@review_data.total_deletions}
                    commits_count={length(@commits)}
                  />
                </div>
              <% end %>

              <%!-- Mini agent tree: pure static SVG, lines + circles only,
                   no zoom/pan/click — just the task's topology. --%>
              <%= if @mini_tree_agents do %>
                <% mt = mini_tree_layout(@mini_tree_agents) %>
                <div class="mt-4">
                  <p class="text-[11px] font-semibold uppercase tracking-wide text-slate-400 mb-2">
                    {gettext("Task tree")}
                  </p>
                  <div class="review-mini-tree">
                    <svg viewBox={"0 0 #{mt.w} #{mt.h}"} width={mt.w} height={mt.h} class="block max-w-full" role="img">
                      <%= for edge <- mt.edges do %>
                        <path d={mt_curve(edge)} class="mt-edge" />
                      <% end %>
                      <%= for n <- mt.nodes do %>
                        <circle cx={n.x} cy={n.y} r={n.r} class={["mt-node", n.root? && "mt-root"]}>
                          <title>{n.label}</title>
                        </circle>
                      <% end %>
                    </svg>
                  </div>
                </div>
              <% end %>

              <%!-- Mini change tree: full tree for new projects, old+new trees
                   for refactors (modified=red, added=green) --%>
              <%= if @change_tree do %>
                <div class="mt-4 rounded-2xl border border-slate-200 bg-white p-4">
                  <%= cond do %>
                    <% @change_tree[:full] -> %>
                      <p class="text-[11px] font-semibold uppercase tracking-wide text-slate-400 mb-2">
                        {gettext("Project structure")}
                      </p>
                      <div class="max-h-72 overflow-y-auto">
                        <.change_tree_nodes nodes={@change_tree.full} />
                      </div>
                    <% true -> %>
                      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                        <div>
                          <p class="text-[11px] font-semibold uppercase tracking-wide text-slate-400 mb-2">
                            {gettext("Before")}
                          </p>
                          <div class="max-h-72 overflow-y-auto">
                            <.change_tree_nodes nodes={@change_tree.old} />
                          </div>
                        </div>
                        <div>
                          <p class="text-[11px] font-semibold uppercase tracking-wide text-slate-400 mb-2">
                            {gettext("After")}
                          </p>
                          <div class="max-h-72 overflow-y-auto">
                            <.change_tree_nodes nodes={@change_tree.new} />
                          </div>
                        </div>
                      </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Minimal actions: adopt / discard up front, pro actions folded away --%>
              <div class="mt-4 rounded-2xl border border-slate-200 bg-white p-4">
                <%= if @branch_exists do %>
                  <div class="flex flex-wrap items-center gap-3">
                    <button
                      id="simple-merge-btn"
                      class="btn rounded-full px-6 bg-slate-900 text-white hover:bg-slate-700 border-none"
                      phx-click="merge"
                      phx-confirm={gettext("Merge these changes into the current branch?")}
                      disabled={@action_loading}
                    >
                      {gettext("Apply these changes")}
                    </button>
                    <button
                      id="simple-reject-btn"
                      class="btn btn-outline rounded-full px-6"
                      phx-click="reject"
                      phx-confirm={gettext("Reject and delete these changes? This cannot be undone.")}
                      disabled={@action_loading}
                    >
                      {gettext("Discard these changes")}
                    </button>

                    <details class="dropdown">
                      <summary class="btn btn-ghost btn-sm rounded-full text-slate-500">
                        {gettext("More actions")}
                      </summary>
                      <div class="dropdown-content z-50 mt-2 w-56 rounded-xl border border-slate-200 bg-white shadow-lg p-2 flex flex-col gap-1">
                        <button
                          :if={@can_continue}
                          class="btn btn-ghost btn-sm justify-start"
                          phx-click="continue"
                          disabled={@action_loading}
                        >
                          {gettext("Continue from Here")}
                        </button>
                        <button
                          :if={not @has_pr}
                          class="btn btn-ghost btn-sm justify-start"
                          phx-click="create_pr"
                          disabled={@action_loading}
                        >
                          {gettext("Create GitHub PR")}
                        </button>
                        <button
                          class="btn btn-ghost btn-sm justify-start"
                          phx-click="ignore"
                          phx-confirm={gettext("Ignore this review? It will be dismissed from pending reviews.")}
                          disabled={@action_loading}
                        >
                          {gettext("Ignore")}
                        </button>
                      </div>
                    </details>
                  </div>
                  <p class="text-[11px] text-slate-400 mt-2">
                    {gettext("Apply merges the changes into your project; discard removes them permanently.")}
                  </p>
                <% else %>
                  <div class="flex flex-wrap items-center gap-3">
                    <button
                      :if={@can_continue}
                      class="btn btn-outline rounded-full px-6"
                      phx-click="continue"
                      disabled={@action_loading}
                    >
                      {gettext("Continue from Here")}
                    </button>
                    <button
                      class="btn btn-ghost rounded-full px-6"
                      phx-click="ignore"
                      phx-confirm={gettext("Ignore this review? It will be dismissed from pending reviews.")}
                      disabled={@action_loading}
                    >
                      {gettext("Ignore")}
                    </button>
                  </div>
                  <p class="text-[11px] text-slate-400 mt-2">
                    {gettext("This branch no longer exists. You can dismiss it with Ignore.")}
                  </p>
                <% end %>

                <div :if={@next_review_id} class="mt-3 pt-3 border-t border-slate-100 flex justify-end">
                  <.link
                    id="simple-next-review"
                    navigate={~p"/tree/review/#{@next_review_id}"}
                    class="flex items-center gap-1 text-xs text-slate-400 hover:text-slate-700 transition-colors"
                  >
                    {gettext("Next pending review")}
                    <.icon name="hero-arrow-right" class="size-3.5" />
                  </.link>
                </div>
              </div>

              <div class="mt-6">
                <%= if @review_data do %>
                  <EvoDashWeb.ReviewComponents.split_diff_layout
                    files={@review_data.files}
                    expanded_files={@expanded_files}
                    selected_file={@selected_file}
                    file_context_levels={@file_context_levels}
                  />
                <% else %>
                  <div class="rounded-2xl border border-slate-200 bg-white p-8 text-center">
                    <p class="text-sm text-slate-400">
                      {gettext("No diff data available for this review.")}
                    </p>
                  </div>
                <% end %>
              </div>
          <% end %>
        </div>

        <EvoDashWeb.Layouts.simple_corner navigate={~p"/review/#{@task_id}"} />
      </div>
    </EvoDashWeb.Layouts.simple>
    """
  end

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
  def mount(%{"task_id" => _} = params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
    end

    {:ok, init_review(socket, params)}
  end

  # Full (re)initialization for a review page. Called from mount and again
  # from handle_params when live-navigating to another task's review.
  defp init_review(socket, params) do
    task_id = params["task_id"]

    socket
    |> assign(
      config_status: config_status(),
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
      next_review_id: nil
    )
    |> load_task_data(task_id)
    |> assign_next_review()
  end

  # Queue navigation: the pending review right after this one in list order.
  defp assign_next_review(socket) do
    ids = Enum.map(EvoDashWeb.SimpleLive.Reviews.pending(), & &1.id)

    next =
      case Enum.find_index(ids, &(&1 == socket.assigns.task_id)) do
        nil -> nil
        idx -> Enum.at(ids, idx + 1)
      end

    assign(socket, :next_review_id, next)
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket = EvoDashWeb.LiveHooks.NodeAware.assign_node(socket, params)

    socket =
      if is_binary(params["task_id"]) and params["task_id"] != socket.assigns.task_id do
        init_review(socket, params)
      else
        socket
      end

    socket = assign(socket, :current_path, ~p"/review/#{socket.assigns.task_id}")

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
  def handle_event("merge", _params, socket) do
    %{repo_path: repo_path, branch_name: branch_name, task_id: task_id} = socket.assigns

    case Review.merge_branch(repo_path, branch_name) do
      {:ok, _sha} ->
        TaskRegistry.set_review_status(task_id, :merged)

        msg =
          if socket.assigns.live_action == :simple do
            gettext("Changes applied to your project.")
          else
            gettext("Changes merged successfully! Branch %{branch} has been deleted.",
              branch: branch_name
            )
          end

        {:noreply,
         socket
         |> put_flash(:success, msg)
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

        msg =
          if socket.assigns.live_action == :simple do
            gettext("Changes discarded.")
          else
            gettext("Changes rejected. Branch %{branch} has been deleted.", branch: branch_name)
          end

        {:noreply,
         socket
         |> put_flash(:info, msg)
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
  def handle_info({:tasks_updated}, socket) do
    socket = load_task_data(socket, socket.assigns.task_id)
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.load_running_and_pending_tasks(socket)}
  end

  @impl true
  def handle_info({:task_status, _task_id, _status}, socket) do
    socket = load_task_data(socket, socket.assigns.task_id)
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.load_running_and_pending_tasks(socket)}
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

        mini_tree_agents =
          case Enum.find(EvoDash.AshTrees.list(), &(&1.task_id == task_id)) do
            nil -> nil
            ash -> ash.agents
          end

        change_tree =
          build_change_tree(
            socket.assigns.live_action,
            task.type,
            repo_path,
            review_data,
            commit_sha,
            review_data && review_data.base_sha
          )

        assign(socket,
          loading: false,
          error: nil,
          change_tree: change_tree,
          mini_tree_agents: mini_tree_agents,
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
          finished_at: task.finished_at
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
  # ── Mini task tree (static SVG topology) ─────────────────────────────────

  # 横向层距 75；纵向节点边界间距 = 直径(14)的 70%（圆心距 = 直径 + 边界间距 = 23.8）
  @mt_gap_x 75
  @mt_gap_y 23.8
  @mt_pad 24

  # Horizontal S-curve for a parent→child edge (same feel as the main graph).
  defp mt_curve({x1, y1, x2, y2}) do
    mx = (x1 + x2) / 2
    "M #{x1} #{y1} C #{mx} #{y1}, #{mx} #{y2}, #{x2} #{y2}"
  end

  # Tidy layout: leaves get consecutive y slots, parents centered. Returns
  # %{nodes: [...], edges: [...], w: w, h: h} for direct SVG rendering.
  defp mini_tree_layout(agents) do
    by_parent = Enum.group_by(agents, & &1.parent_id)
    roots = (by_parent[nil] || []) |> Enum.sort_by(& &1.id)

    {nodes, edges, _next_y, _min_y} =
      Enum.reduce(roots, {[], [], 0, %{}}, fn root, acc ->
        mt_place(root, by_parent, 0, acc)
      end)

    if nodes == [] do
      %{nodes: [], edges: [], w: @mt_pad * 2, h: @mt_pad * 2}
    else
      xs = Enum.map(nodes, & &1.x)
      ys = Enum.map(nodes, & &1.y)
      {min_x, max_x} = {Enum.min(xs), Enum.max(xs)}
      {min_y, max_y} = {Enum.min(ys), Enum.max(ys)}

      nodes =
        Enum.map(nodes, fn n ->
          %{n | x: n.x - min_x + @mt_pad, y: n.y - min_y + @mt_pad}
        end)

      edges =
        Enum.map(edges, fn {x1, y1, x2, y2} ->
          {x1 - min_x + @mt_pad, y1 - min_y + @mt_pad, x2 - min_x + @mt_pad, y2 - min_y + @mt_pad}
        end)

      %{nodes: nodes, edges: edges, w: max_x - min_x + @mt_pad * 2, h: max_y - min_y + @mt_pad * 2}
    end
  end

  # min_y: 每个深度已占用的最小可用 y（圆心距下限），保证同层节点不相贴
  defp mt_place(agent, by_parent, depth, {nodes, edges, next_y, min_y}) do
    children =
      (by_parent[agent.id] || [])
      |> Enum.sort_by(& &1.id)

    {nodes, edges, next_y, min_y} =
      Enum.reduce(children, {nodes, edges, next_y, min_y}, fn child, acc ->
        mt_place(child, by_parent, depth + 1, acc)
      end)

    x = depth * @mt_gap_x
    floor_y = Map.get(min_y, depth, 0)

    y =
      case children do
        [] ->
          max(next_y + @mt_gap_y, floor_y)

        _ ->
          ys =
            children
            |> Enum.map(fn c -> Enum.find(nodes, &(&1.id == c.id)) end)
            |> Enum.filter(& &1)
            |> Enum.map(& &1.y)

          center = if ys == [], do: next_y + @mt_gap_y, else: (Enum.min(ys) + Enum.max(ys)) / 2
          max(center, floor_y)
      end

    min_y = Map.put(min_y, depth, y + @mt_gap_y)

    node = %{
      id: agent.id,
      x: x,
      y: y,
      r: if(depth == 0, do: 9, else: 7),
      root?: depth == 0,
      label: agent.objective || ""
    }

    edges =
      edges ++
        Enum.map(children, fn c ->
          child = Enum.find(nodes, &(&1.id == c.id))
          {x + node.r, y, child.x - child.r, child.y}
        end)

    {nodes ++ [node], edges, y, min_y}
  end

  # ── Change tree (review page mini diagram) ──────────────────────────────
  # 新项目: 全部文件(全部为新增, 绿); 改造项目: 原状树(删除=红) + 修改后树
  # (修改=红, 新增=绿). 只有实线连线和圆圈.
  defp build_change_tree(:simple, task_type, repo_path, review_data, commit_sha, base_sha) do
    cond do
      not is_binary(repo_path) or is_nil(commit_sha) ->
        nil

      # 新项目：显示全部树（全部文件，全部按新增标记）
      task_type == :genesis ->
        leaves = full_project_tree(repo_path, commit_sha) |> Enum.take(120)
        statuses = Map.new(leaves, &{&1, "added"})
        %{full: paths_to_tree(leaves, statuses)}

      # 改造项目：原状树（删除=红）+ 修改后树（修改=红，新增=绿）
      true ->
        statuses = if review_data, do: Map.new(review_data.files, &{&1.path, &1.status}), else: %{}

        old_paths =
          case is_binary(base_sha) && EvoGit.Adapters.Git.ls_tree_names(repo_path, base_sha) do
            {:ok, paths} -> MapSet.new(paths)
            _ -> MapSet.new()
          end

        new_paths =
          case EvoGit.Adapters.Git.ls_tree_names(repo_path, commit_sha) do
            {:ok, paths} -> MapSet.new(paths)
            _ -> MapSet.new()
          end

        old_leaves =
          statuses
          |> Map.keys()
          |> Enum.filter(&MapSet.member?(old_paths, &1))
          |> Enum.sort()

        new_leaves =
          statuses
          |> Map.keys()
          |> Enum.filter(&MapSet.member?(new_paths, &1))
          |> Enum.sort()

        if old_leaves == [] and new_leaves == [] do
          nil
        else
          %{old: paths_to_tree(old_leaves, statuses), new: paths_to_tree(new_leaves, statuses)}
        end
    end
  end

  defp build_change_tree(_, _, _, _, _, _), do: nil

  # 新项目的完整文件列表
  defp full_project_tree(repo_path, commit_sha) do
    case EvoGit.Adapters.Git.ls_tree_names(repo_path, commit_sha) do
      {:ok, paths} -> paths
      _ -> []
    end
  end

  defp paths_to_tree(paths, statuses) do
    paths
    |> Enum.reduce([], fn path, acc -> insert_path(acc, Path.split(path), path, statuses) end)
    |> sort_nodes()
  end

  defp insert_path(nodes, [name], full, statuses) do
    status = Map.get(statuses, full, "modified")

    if Enum.any?(nodes, &(&1.name == name and &1.leaf?)) do
      nodes
    else
      nodes ++ [%{name: name, leaf?: true, status: status, children: []}]
    end
  end

  defp insert_path(nodes, [name | rest], full, statuses) do
    case Enum.find_index(nodes, &(&1.name == name and not &1.leaf?)) do
      nil ->
        nodes ++ [%{name: name, leaf?: false, status: nil, children: insert_path([], rest, full, statuses)}]

      idx ->
        node = Enum.at(nodes, idx)
        List.replace_at(nodes, idx, %{node | children: insert_path(node.children, rest, full, statuses)})
    end
  end

  defp sort_nodes(nodes) do
    nodes
    |> Enum.sort_by(fn n -> {n.leaf?, String.downcase(n.name)} end)
    |> Enum.map(fn n -> %{n | children: sort_nodes(n.children)} end)
  end

  attr(:nodes, :list, required: true)

  defp change_tree_nodes(assigns) do
    ~H"""
    <ul class="change-tree">
      <%= for node <- @nodes do %>
        <li>
          <span class={["ct-dot", node.leaf? && "ct-#{node.status || "dir"}", !node.leaf? && "ct-dir"]}>
          </span>
          <span class={["ct-name", node.status == "deleted" && "ct-deleted"]}>{node.name}</span>
          <%= if node.children != [] do %>
            <.change_tree_nodes nodes={node.children} />
          <% end %>
        </li>
      <% end %>
    </ul>
    """
  end

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
