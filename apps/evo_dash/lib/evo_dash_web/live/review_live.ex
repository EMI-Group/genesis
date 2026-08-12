defmodule EvoDashWeb.ReviewLive do
  @moduledoc """
  Code review page for completed tasks.

  Displays agent-produced changes as a GitHub-style diff with merge,
  reject, and resume actions, plus optional GitHub PR creation.
  """
  use EvoDashWeb, :live_view

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
      <%= if EvoDashWeb.RemoteGateComponents.gate_active?(assigns) do %>
        <%= EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns) %>
      <% else %>
      <%= if @error do %>
        <div class="rounded-lg border border-error/30 bg-error/5 p-6 text-center">
          <.icon name="hero-exclamation-triangle" class="size-8 text-error mx-auto mb-4" />
          <h2 class="text-xl font-bold text-error mb-2">{gettext("Review Not Available")}</h2>
          <p class="text-sm text-base-content/60 mb-4">{@error}</p>
          <.link navigate={with_node_param(~p"/", @current_node_id)} class="btn btn-primary px-6 gap-2">
            <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to Dashboard")}
          </.link>
        </div>
      <% else %>
        <div class="space-y-4">
          <!-- Back button -->
          <div class="flex items-center gap-3">
            <%= if @live_action == :commit do %>
              <.link
                navigate={with_node_param(~p"/review/#{@task_id}", @current_node_id)}
                class="btn btn-ghost btn-sm gap-1 px-4"
              >
                <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to Review")}
              </.link>
            <% else %>
              <.link navigate={with_node_param(~p"/", @current_node_id)} class="btn btn-ghost btn-sm gap-1 px-4">
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
                          can_resume={@can_resume}
                          has_pr={@has_pr}
                          pr_url={@pr_url}
                          loading={@action_loading}
                          is_no_changes={@is_no_changes}
                          merge_targets={@merge_targets}
                          default_merge_target={@default_merge_target}
                          merge_status={@merge_status}
                        />
                        <%= if @archive_metadata not in [nil, []] do %>
                          <.link
                            href={with_node_param("/tasks/#{@task_id}/export", @current_node_id)}
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
        can_resume: false,
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
        default_merge_target: nil,
        merge_status: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:current_path, ~p"/review/#{socket.assigns.task_id}")

    # Node-aware task load. `@current_node` is only resolved by assign_node
    # above (at mount time it is still the on_mount local default), so the
    # task fetch MUST live here — handle_params runs after mount on initial
    # load too. Dedup guard: the task id is fixed for the page lifetime, so
    # only a node change warrants a refetch (e.g. a pending→connected
    # transition that push_patch-es this path, or a manual ?node= switch).
    socket =
      if Map.get(socket.assigns, :tasks_loaded_for) == socket.assigns.current_node do
        socket
      else
        socket
        |> load_task_data(socket.assigns.task_id)
        |> assign(:tasks_loaded_for, socket.assigns.current_node)
        |> maybe_start_merge_check()
      end

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
  def handle_event("retry_remote_connection", _params, socket) do
    EvoDash.NodeContext.connect(socket.assigns.current_node_id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_to_local", _params, socket) do
    send(self(), {:node_selected, "local"})
    {:noreply, socket}
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

    # All review git operations run on the node being viewed: local → direct
    # call, remote → RPC to the remote daemon's filesystem. RemoteNode
    # returns the verbatim underlying value in both paths, so the existing
    # pattern matches below are unchanged.
    node = socket.assigns.current_node

    result =
      if target do
        EvoDash.NodeContext.merge_branch(node, repo_path, branch_name, target)
      else
        EvoDash.NodeContext.merge_branch(node, repo_path, branch_name)
      end

    case result do
      {:ok, _sha} ->
        EvoDash.NodeContext.set_review_status(node, task_id, :merged)

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
         |> push_navigate(to: with_node_param(~p"/", socket.assigns.current_node_id))}

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
  def handle_event("merge_target_change", params, socket) do
    # The merge form's target-branch select changed: update the default target
    # and re-run the async dry-run merge check against the new target.
    target = params["target_branch"]

    %{
      merge_targets: merge_targets,
      branch_name: branch_name,
      repo_path: repo_path,
      current_node: current_node,
      task_id: task_id
    } = socket.assigns

    if is_binary(target) and target in merge_targets and is_binary(branch_name) and
         repo_available?(socket, repo_path) do
      socket = assign(socket, :default_merge_target, target)

      {:noreply, start_merge_check(socket, current_node, repo_path, branch_name, target, task_id)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("auto_resolve", _params, socket) do
    %{
      merge_status: merge_status,
      repo_path: repo_path,
      commit_sha: commit_sha,
      task_id: task_id,
      current_node: current_node
    } = socket.assigns

    case merge_status do
      %{state: :conflict, target: target} when is_binary(target) ->
        # Mirror the resume flow: mark the original task continued before
        # spawning the merge-resolution task.
        EvoDash.NodeContext.set_review_status(current_node, task_id, :continued)

        opts = [
          path: repo_path,
          mode: "simple",
          # The objective is an agent prompt — plain string interpolation,
          # NOT gettext.
          objective:
            "Merge the completed task's changes into the #{target} branch and resolve all merge conflicts, producing a fully integrated result.",
          starting_commit: commit_sha,
          merge_from: task_id,
          merge_target: target
        ]

        case EvoDash.NodeContext.start_task(current_node, :evolve, opts) do
          {:ok, _task} ->
            {:noreply,
             socket
             |> put_flash(
               :success,
               gettext(
                 "Auto-resolve task started. It will merge the changes and resolve conflicts; review its result when done."
               )
             )
             |> push_navigate(to: with_node_param(~p"/", socket.assigns.current_node_id))}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(
               :error,
               gettext("Failed to start auto-resolve: %{reason}", reason: inspect(reason))
             )}
        end

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Auto-resolve unavailable — no merge conflict detected.")
         )}
    end
  end

  @impl true
  def handle_event("reject", _params, socket) do
    %{repo_path: repo_path, branch_name: branch_name, task_id: task_id} = socket.assigns

    node = socket.assigns.current_node

    case EvoDash.NodeContext.reject_branch(node, repo_path, branch_name) do
      :ok ->
        EvoDash.NodeContext.set_review_status(node, task_id, :rejected)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Changes rejected. Branch %{branch} has been deleted.", branch: branch_name)
         )
         |> push_navigate(to: with_node_param(~p"/", socket.assigns.current_node_id))}

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
  def handle_event("resume", _params, socket) do
    commit_sha = socket.assigns.commit_sha
    branch_name = socket.assigns.branch_name
    task_id = socket.assigns.task_id
    repo_path = socket.assigns.repo_path

    EvoDash.NodeContext.set_review_status(socket.assigns.current_node, task_id, :continued)

    query = [resume_from: task_id]
    query = if commit_sha, do: Keyword.put(query, :starting_commit, commit_sha), else: query
    # Include project query param so the dashboard re-opens the correct project
    query = if repo_path, do: Keyword.put(query, :project, repo_path), else: query

    # The target URL already carries a query string, so with_node_param's `?`
    # append does not apply — a manual `&node=` suffix preserves the node
    # context (same pattern as project_flow.ex's project_url/2).
    to =
      case socket.assigns.current_node_id do
        nil -> ~p"/?#{query}"
        node_id -> ~p"/?#{query}" <> "&node=" <> node_id
      end

    flash_msg =
      if commit_sha do
        gettext("Resuming from branch %{branch} at %{sha}",
          branch: branch_name,
          sha: String.slice(commit_sha, 0..7)
        )
      else
        gettext(
          "Resuming from investigation task. A new evolve task form has been prepared for you."
        )
      end

    {:noreply,
     socket
     |> put_flash(:info, flash_msg)
     |> push_navigate(to: to)}
  end

  @impl true
  def handle_event("ignore", _params, socket) do
    task_id = socket.assigns.task_id

    EvoDash.NodeContext.set_review_status(socket.assigns.current_node, task_id, :ignored)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Review ignored and dismissed."))
     |> push_navigate(to: with_node_param(~p"/", socket.assigns.current_node_id))}
  end

  @impl true
  def handle_event("create_pr", _params, socket) do
    %{repo_path: repo_path, branch_name: branch_name, objective: objective, agent_summary: result} =
      socket.assigns

    socket = assign(socket, :action_loading, true)

    case EvoDash.NodeContext.create_github_pr(
           socket.assigns.current_node,
           repo_path,
           branch_name,
           objective || "",
           result || ""
         ) do
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

    # Skill extraction runs on the node being viewed (local → direct call,
    # remote → RPC), so the git ops inside start_task execute against the
    # repo on the correct host.
    case EvoDash.NodeContext.start_task(socket.assigns.current_node, :extract_skills, opts) do
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
    socket = maybe_start_merge_check(socket)
    socket = EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.clear_task_reload_pending(socket)}
  end

  @impl true
  def handle_info({:merge_check_result, task_id, node, target, {:ok, :clean}}, socket) do
    apply_merge_check_result(socket, task_id, node, target, %{
      state: :clean,
      target: target,
      files: []
    })
  end

  def handle_info({:merge_check_result, task_id, node, target, {:ok, {:conflict, files}}}, socket)
      when is_list(files) do
    apply_merge_check_result(socket, task_id, node, target, %{
      state: :conflict,
      target: target,
      files: files
    })
  end

  def handle_info({:merge_check_result, task_id, node, target, {:error, _reason}}, socket) do
    apply_merge_check_result(socket, task_id, node, target, %{state: :error, target: target})
  end

  # Safety net: ignore any unmatched merge-check-result shape.
  def handle_info({:merge_check_result, _, _, _, _}, socket) do
    {:noreply, socket}
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
    # All review operations run on the node being viewed: local → direct
    # call, remote → RPC to the remote daemon (its own TaskRegistry + its own
    # filesystem). RemoteNode returns the verbatim underlying value in both
    # paths, so the pattern matches below are identical for local and remote.
    node = socket.assigns.current_node

    case EvoDash.NodeContext.get_task(node, task_id) do
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
          finished_at: nil,
          merge_status: nil
        )

      task ->
        result = task.result
        repo_path = task.opts[:path]

        # Merge-target branch selector: list local branches and resolve the
        # default merge target. Degrades gracefully to [] / nil when branches
        # cannot be listed (e.g. missing repo or unreachable remote node) —
        # plain case on the tuple returns, no try/rescue.
        {merge_targets, default_merge_target} =
          if repo_available?(socket, repo_path) do
            targets =
              case EvoDash.NodeContext.list_branches(node, repo_path) do
                {:ok, names} -> Enum.filter(names, &(is_binary(&1) and String.trim(&1) != ""))
                _ -> []
              end

            default =
              case EvoDash.NodeContext.default_merge_target(node, repo_path) do
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
          !!(branch_name && repo_available?(socket, repo_path) &&
               branch_exists_on_node?(socket, repo_path, branch_name))

        can_resume =
          repo_available?(socket, repo_path) && (commit_sha != nil || branch_name == nil)

        rs = task.review_status

        review_status =
          cond do
            branch_name == nil -> :no_changes
            rs != nil -> rs
            not branch_exists -> :open
            true -> :open
          end

        is_no_changes = branch_name == nil && task.status in [:completed, :cancelled]

        commit_sha = commit_sha || task.commit_sha

        review_data =
          cond do
            # Normal case: branch still exists
            branch_exists && repo_path ->
              case EvoDash.NodeContext.load_review_metadata(node, repo_path, branch_name) do
                {:ok, data} -> data
                _ -> nil
              end

            # Post-merge/reject case: branch gone but SHAs persisted
            not branch_exists && repo_path && task.base_sha && commit_sha ->
              case EvoDash.NodeContext.load_review_metadata_from_shas(
                     node,
                     repo_path,
                     task.base_sha,
                     commit_sha
                   ) do
                {:ok, data} -> data
                _ -> nil
              end

            true ->
              nil
          end

        base_sha = if review_data, do: review_data.base_sha, else: task.base_sha

        # Persist SHAs when loading from branch (for future post-merge access)
        if (branch_exists && review_data && is_nil(task.base_sha)) and base_sha do
          EvoDash.NodeContext.set_review_metadata(node, task_id, base_sha, commit_sha)
        end

        commits =
          cond do
            branch_exists && repo_path ->
              case EvoDash.NodeContext.list_commits(node, repo_path, branch_name) do
                {:ok, commits} -> commits
                # Graceful degradation (missing repo, unreachable remote
                # node): render an empty commit list instead of crashing.
                _ -> []
              end

            not branch_exists && repo_path && task.base_sha && commit_sha ->
              case EvoDash.NodeContext.list_commits_from_shas(
                     node,
                     repo_path,
                     task.base_sha,
                     commit_sha
                   ) do
                {:ok, commits} -> commits
                _ -> []
              end

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
          can_resume: can_resume || false,
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
          default_merge_target: default_merge_target,
          merge_status: nil
        )
    end
  end

  # Local repos are gated on a cheap File.dir?/1 check (avoids git errors on
  # missing paths). Remote repos live on the remote host's filesystem — no
  # local check is possible, so availability is derived from the RPC results
  # themselves (an {:error, _} return — missing repo or transport failure —
  # degrades to the empty/disabled state below).
  defp repo_available?(socket, repo_path) do
    if socket.assigns.current_node == node() do
      repo_path != nil && File.dir?(repo_path)
    else
      repo_path != nil
    end
  end

  # Branch existence on the current node. For the local node this is
  # `EvoGit.Review.branch_exists?/2` (a raw boolean). For remote nodes it is
  # the RPC result, which may be `{:error, {kind, reason}}` on transport
  # failure — treated as branch-not-determinable (false) so the page degrades
  # to the existing post-merge/reject state instead of crashing.
  defp branch_exists_on_node?(socket, repo_path, branch_name) do
    EvoDash.NodeContext.branch_exists?(socket.assigns.current_node, repo_path, branch_name) ==
      true
  end

  # Kicks off the async dry-run merge check after a successful task-data load,
  # under the same gates action_buttons uses to render the merge form (branch
  # exists, merge targets known, repo available). The result arrives later as
  # a {:merge_check_result, ...} message.
  defp maybe_start_merge_check(socket) do
    %{
      task_id: task_id,
      current_node: current_node,
      repo_path: repo_path,
      branch_name: branch_name,
      branch_exists: branch_exists,
      merge_targets: merge_targets,
      default_merge_target: default_target,
      merge_status: merge_status
    } = socket.assigns

    target = default_target || List.first(merge_targets)

    if branch_exists and merge_targets != [] and is_binary(target) and
         repo_available?(socket, repo_path) do
      case merge_status do
        %{state: :checking, target: ^target} ->
          # Already checking this exact target — don't spawn a duplicate.
          socket

        _ ->
          start_merge_check(socket, current_node, repo_path, branch_name, target, task_id)
      end
    else
      socket
    end
  end

  # Spawns the dry-run merge check for `target` in a supervised Task (same
  # async pattern as SettingsLive's LLM connection test) and immediately marks
  # the status as :checking.
  defp start_merge_check(socket, current_node, repo_path, branch_name, target, task_id) do
    parent = self()

    socket =
      assign(socket, :merge_status, %{state: :checking, target: target, files: []})

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result = EvoDash.NodeContext.check_merge(current_node, repo_path, branch_name, target)
      send(parent, {:merge_check_result, task_id, current_node, target, result})
    end)

    socket
  end

  # Applies an async merge-check result, ignoring stale results (different
  # task/node, or a target that no longer matches the current merge_status
  # target — a nil status has no target to mismatch, so a matching task/node
  # result is still accepted).
  defp apply_merge_check_result(socket, task_id, node, target, status) do
    %{task_id: current_task_id, current_node: current_node, merge_status: merge_status} =
      socket.assigns

    current_target = merge_status_target(merge_status)

    stale? =
      task_id != current_task_id or node != current_node or
        (current_target != nil and current_target != target)

    if stale? do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :merge_status, status)}
    end
  end

  defp merge_status_target(%{target: target}) when is_binary(target), do: target
  defp merge_status_target(_), do: nil

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
      node = socket.assigns.current_node

      case EvoDash.NodeContext.load_file_diff(node, repo_path, base_sha, commit_sha, path) do
        {:ok, diff_string} ->
          full_new =
            content_or_nil(
              EvoDash.NodeContext.get_file_content(node, repo_path, commit_sha, path)
            )

          full_old =
            content_or_nil(EvoDash.NodeContext.get_file_content(node, repo_path, base_sha, path))

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
      node = socket.assigns.current_node

      case EvoDash.NodeContext.load_commit_file_diff(node, repo_path, commit_sha, path) do
        {:ok, diff_string} ->
          full_new =
            content_or_nil(
              EvoDash.NodeContext.get_file_content(node, repo_path, commit_sha, path)
            )

          full_old =
            content_or_nil(
              EvoDash.NodeContext.get_file_content(node, repo_path, "#{commit_sha}~1", path)
            )

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
    node = socket.assigns.current_node

    if socket.assigns.live_action == :commit do
      %{inspect_commit_sha: commit_sha} = socket.assigns

      EvoDash.NodeContext.load_file_diff(
        node,
        repo_path,
        "#{commit_sha}~1",
        commit_sha,
        path,
        opts
      )
    else
      %{base_sha: base_sha, commit_sha: commit_sha} = socket.assigns
      EvoDash.NodeContext.load_file_diff(node, repo_path, base_sha, commit_sha, path, opts)
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
      case EvoDash.NodeContext.load_commit_files(
             socket.assigns.current_node,
             repo_path,
             commit_sha
           ) do
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
