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
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
      accent_color={assigns[:accent_color] || "blue"}
    >
      <%= if EvoDashWeb.RemoteGateComponents.gate_active?(assigns) do %>
        {EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns)}
      <% else %>
        <%= if @error do %>
          <div class="rounded-lg border border-error/30 bg-error/5 p-6 text-center">
            <.icon name="hero-exclamation-triangle" class="size-8 text-error mx-auto mb-4" />
            <h2 class="text-xl font-bold text-error mb-2">{gettext("Review Not Available")}</h2>
            <p class="text-sm text-base-content/80 mb-4">{@error}</p>
            <.link
              navigate={with_node_param(~p"/projects", @current_node_id)}
              class="btn btn-primary px-6 gap-2"
            >
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
                <.link
                  navigate={with_node_param(~p"/projects", @current_node_id)}
                  class="btn btn-ghost btn-sm gap-1 px-4"
                >
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
                  <%= if @merge_outcomes != [] do %>
                    <EvoDashWeb.ReviewComponents.merge_outcomes_panel outcomes={@merge_outcomes} />
                  <% end %>
                  <%= if length(@review_repos) > 1 do %>
                    <EvoDashWeb.ReviewComponents.repo_tabs
                      repos={@review_repos}
                      active_repo_id={@active_repo_id}
                    />
                  <% end %>
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
                            repo_id={@active_repo_id}
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
                            expanded_files={Map.get(@expanded_files, @active_repo_id, %{})}
                            selected_file={Map.get(@selected_file || %{}, @active_repo_id)}
                            file_context_levels={Map.get(@file_context_levels, @active_repo_id, %{})}
                          />
                        <% else %>
                          <div class="p-8 text-center">
                            <.icon
                              name="hero-document-magnifying-glass"
                              class="size-10 text-base-content/50 mx-auto mb-3"
                            />
                            <p class="text-sm text-base-content/70">
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
                              class="size-10 text-base-content/50 mx-auto mb-3"
                            />
                            <p class="text-sm text-base-content/70">
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
        merge_status: nil,
        review_repos: [],
        active_repo_id: "primary",
        merge_outcomes: [],
        load_generation: 0,
        last_broadcast_task_id: nil
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
    # load too. Dedup guard: the load runs once per (node, route) context —
    # a node change (pending→connected transition, manual ?node= switch) or a
    # push_patch between the review and commit routes warrants a refetch. The
    # load itself runs asynchronously (see start_async_load/2); the result
    # arrives later as a {:review_data_loaded, ...} message.
    socket =
      if Map.get(socket.assigns, :tasks_loaded_for) ==
           {socket.assigns.current_node, socket.assigns.live_action, params["commit_sha"]} do
        socket
      else
        socket
        |> start_async_load(params["commit_sha"])
        |> assign(
          :tasks_loaded_for,
          {socket.assigns.current_node, socket.assigns.live_action, params["commit_sha"]}
        )
      end

    {:noreply, socket}
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
  def handle_event("switch_repo", %{"repo_id" => repo_id}, socket) do
    # Whitelist-validate the submitted repo id against the known review repos
    # (never String.to_atom on client input). Per-repo diff state is keyed by
    # repo_id and persists across switches — only the active id and the flat
    # projections change.
    if repo_id in Enum.map(socket.assigns.review_repos, & &1.repo_id) do
      {:noreply, socket |> assign(:active_repo_id, repo_id) |> project_active_repo()}
    else
      {:noreply, socket}
    end
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
      if socket.assigns.live_action == :commit do
        # :commit route keeps today's legacy flat path-keyed state.
        assign(socket,
          selected_file: path,
          review_tab: :files_changed
        )
      else
        # SHOW route: per-repo selection map keyed by repo_id — selecting a
        # file in one repo must not clobber another repo's selection.
        selected =
          Map.put(socket.assigns.selected_file || %{}, socket.assigns.active_repo_id, path)

        socket
        |> assign(selected_file: selected, review_tab: :files_changed)
        |> project_active_repo()
      end
      |> push_event("scroll_to_file", %{target_id: target_id})

    # Trigger diff loading if file diff is nil
    maybe_load_diff(socket, path)
  end

  @impl true
  def handle_event("toggle_file_expansion", %{"path" => path}, socket) do
    if socket.assigns.live_action == :commit do
      # :commit route keeps today's legacy flat path-keyed behavior.
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
    else
      # SHOW route: per-repo expansion map keyed by repo_id — toggle only the
      # ACTIVE repo's submap.
      expanded = socket.assigns.expanded_files || %{}
      sub = Map.get(expanded, socket.assigns.active_repo_id, %{})

      sub =
        if Map.get(sub, path, false), do: Map.delete(sub, path), else: Map.put(sub, path, true)

      expanded = Map.put(expanded, socket.assigns.active_repo_id, sub)

      socket =
        socket
        |> assign(:expanded_files, expanded)
        |> project_active_repo()

      # If expanding a file whose diff is nil, trigger lazy load
      maybe_load_diff(socket, path)
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
    # SHOW route reads the context level from the ACTIVE repo's submap;
    # :commit keeps today's legacy flat path-keyed state.
    current_level =
      if socket.assigns.live_action == :commit do
        Map.get(socket.assigns.file_context_levels, path, 3)
      else
        socket.assigns.file_context_levels
        |> Map.get(socket.assigns.active_repo_id, %{})
        |> Map.get(path, 3)
      end

    new_level =
      cond do
        current_level == :all -> :all
        current_level >= 30 -> :all
        true -> current_level + 20
      end

    opts = if new_level == :all, do: [context: :all], else: [context: new_level]

    case load_file_diff_for_mode(socket, path, opts) do
      {:ok, diff_string} ->
        # Context expansion only changes the diff context window.
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
  def handle_event("merge", params, socket) do
    %{task_id: task_id, review_repos: review_repos} = socket.assigns

    # The submitting repo comes from the merge form's hidden `repo_id` input
    # (falling back to the currently active repo, then "primary"); whitelist
    # against the known review-repo ids — never String.to_atom on client input.
    submitting_repo_id =
      case params["repo_id"] do
        repo_id when is_binary(repo_id) and repo_id != "" -> repo_id
        _ -> socket.assigns.active_repo_id
      end

    submitting_repo_id =
      if Enum.any?(review_repos, &(&1.repo_id == submitting_repo_id)) do
        submitting_repo_id
      else
        "primary"
      end

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

    # Per-repo merge plan: the submitting repo uses the form target (validated
    # against ITS known branch list, falling back to ITS resolved default);
    # every other repo merges into its own resolved default (nil → the 3-arity
    # default-resolving path).
    plan =
      Enum.map(review_repos, fn repo ->
        if repo.repo_id == submitting_repo_id do
          # Sanity check: when a known branch list was loaded, only accept a
          # submitted target that is a member of it; otherwise fall back to the
          # repo's resolved default (or no target).
          resolved_target =
            if target != nil and repo.merge_targets != [] and target not in repo.merge_targets do
              repo.default_merge_target
            else
              target
            end

          {repo, resolved_target}
        else
          {repo, repo.default_merge_target}
        end
      end)

    # The effective target (explicitly chosen or the resolved default) for the
    # SUBMITTING repo is what its merge actually used — mention it in the
    # success flash.
    {submitting_repo, effective_target} =
      Enum.find(plan, fn {repo, _target} -> repo.repo_id == submitting_repo_id end)

    # All review git operations run on the node being viewed: local → direct
    # call, remote → RPC to the remote daemon's filesystem. RemoteNode returns
    # the verbatim underlying value in both paths. Test seam: the merge runner
    # is resolved from application env at CALL time (mirrors MergeCheck's
    # :merge_check_runner) so tests can stub out the real repo-touching merge.
    node = socket.assigns.current_node

    merge_fun =
      case Application.get_env(:evo_dash, :review_merge_runner, nil) do
        nil ->
          fn node, repo_path, branch_name, merge_target ->
            if merge_target do
              EvoDash.NodeContext.merge_branch(node, repo_path, branch_name, merge_target)
            else
              EvoDash.NodeContext.merge_branch(node, repo_path, branch_name)
            end
          end

        fun ->
          fun
      end

    results =
      Enum.map(plan, fn {repo, merge_target} ->
        result = merge_fun.(node, repo.repo_path, repo.branch_name, merge_target)
        {repo.repo_id, merge_target, result}
      end)

    if Enum.all?(results, fn {_repo_id, _target, result} -> match?({:ok, _sha}, result) end) do
      EvoDash.NodeContext.set_review_status(node, task_id, :merged)

      success_flash =
        if effective_target do
          gettext(
            "Changes merged successfully into %{target}! Branch %{branch} has been deleted.",
            target: effective_target,
            branch: submitting_repo.branch_name
          )
        else
          gettext("Changes merged successfully! Branch %{branch} has been deleted.",
            branch: submitting_repo.branch_name
          )
        end

      {:noreply,
       socket
       |> put_flash(:success, success_flash)
       |> push_navigate(to: with_node_param(~p"/projects", socket.assigns.current_node_id))}
    else
      # Partial success / any failure: report every repo's outcome (merged
      # ones too — partial-success visibility) and STAY on the page. Never
      # navigate away from a partially applied merge.
      outcomes =
        Enum.map(results, fn {repo_id, merge_target, result} ->
          case result do
            {:ok, sha} ->
              %{repo_id: repo_id, status: :merged, detail: to_string(sha), target: merge_target}

            {:conflict, details} ->
              %{
                repo_id: repo_id,
                status: :conflict,
                detail: truncate_string(details, 200),
                target: merge_target
              }

            {:error, reason} ->
              %{repo_id: repo_id, status: :error, detail: inspect(reason), target: merge_target}
          end
        end)

      failed_count =
        Enum.count(results, fn {_repo_id, _target, result} -> not match?({:ok, _sha}, result) end)

      {:noreply,
       socket
       |> assign(:merge_outcomes, outcomes)
       |> put_flash(
         :error,
         gettext(
           "Merge failed in %{count} of %{total} repositories. See the merge results below.",
           count: failed_count,
           total: length(results)
         )
       )}
    end
  end

  @impl true
  def handle_event("merge_target_change", params, socket) do
    # The merge form's target-branch select changed: the support module
    # updates the changed repo's default target and re-runs its async dry-run
    # merge check. Re-project afterwards so action_buttons reads the ACTIVE
    # repo's flat @merge_status / @default_merge_target.
    socket = EvoDashWeb.ReviewLive.MergeCheck.handle_target_change(socket, params)
    {:noreply, project_active_repo(socket)}
  end

  @impl true
  def handle_event("auto_resolve", _params, socket) do
    # Starts a merge-resolution task (guarded on a detected conflict) —
    # see EvoDashWeb.ReviewLive.MergeCheck.handle_auto_resolve/1.
    {:noreply, EvoDashWeb.ReviewLive.MergeCheck.handle_auto_resolve(socket)}
  end

  @impl true
  def handle_event("reject", _params, socket) do
    %{task_id: task_id, review_repos: review_repos} = socket.assigns

    # Reject (delete) the agent branch in EVERY review repo — the same
    # broadcast semantics as merge. All review git operations run on the node
    # being viewed (local → direct call, remote → RPC). Test seam mirrors
    # :review_merge_runner, resolved at call time.
    node = socket.assigns.current_node

    reject_fun =
      Application.get_env(:evo_dash, :review_reject_runner) ||
        (&EvoDash.NodeContext.reject_branch/3)

    results =
      Enum.map(review_repos, fn repo ->
        result = reject_fun.(node, repo.repo_path, repo.branch_name)
        {repo.repo_id, result}
      end)

    if Enum.all?(results, fn {_repo_id, result} -> result == :ok end) do
      EvoDash.NodeContext.set_review_status(node, task_id, :rejected)

      branch_names =
        review_repos
        |> Enum.map(& &1.branch_name)
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")

      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("Changes rejected. Branch %{branch} has been deleted.", branch: branch_names)
       )
       |> push_navigate(to: with_node_param(~p"/projects", socket.assigns.current_node_id))}
    else
      # Partial reject: report every repo's outcome and STAY on the page —
      # never dismiss a partially applied reject silently.
      outcomes =
        Enum.map(results, fn {repo_id, result} ->
          case result do
            :ok ->
              %{repo_id: repo_id, status: :rejected}

            {:error, reason} ->
              %{repo_id: repo_id, status: :error, detail: inspect(reason)}
          end
        end)

      failed_count = Enum.count(results, fn {_repo_id, result} -> result != :ok end)

      {:noreply,
       socket
       |> assign(:merge_outcomes, outcomes)
       |> put_flash(
         :error,
         # zh_CN: 多仓库评审中拒绝（删除分支）失败——"repositories" 指所有可写仓库，下方面板展示各仓库的拒绝结果
         gettext(
           "Failed to reject changes in %{count} of %{total} repositories. See the merge results below.",
           count: failed_count,
           total: length(results)
         )
       )}
    end
  end

  @impl true
  def handle_event("resume", _params, socket) do
    # PRIMARY-scoped (documented limitation): repo-scoped fields come from the
    # "primary" entry explicitly, never from the flat (active-repo-projected)
    # assigns — a foreign repo tab must not change what resume prepares.
    primary = Enum.find(socket.assigns.review_repos, &(&1.repo_id == "primary"))

    commit_sha = primary && primary.commit_sha
    branch_name = primary && primary.branch_name
    task_id = socket.assigns.task_id
    repo_path = primary && primary.repo_path

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
        nil -> ~p"/projects?#{query}"
        node_id -> ~p"/projects?#{query}" <> "&node=" <> node_id
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
     |> push_navigate(to: with_node_param(~p"/projects", socket.assigns.current_node_id))}
  end

  @impl true
  def handle_event("create_pr", _params, socket) do
    # PRIMARY-scoped (documented limitation): see the resume handler.
    primary = Enum.find(socket.assigns.review_repos, &(&1.repo_id == "primary"))

    repo_path = primary && primary.repo_path
    branch_name = primary && primary.branch_name

    %{objective: objective, agent_summary: result} = socket.assigns

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
    # PRIMARY-scoped (documented limitation): repo-scoped fields (incl. the
    # commit history for the PR description) come from the "primary" entry
    # explicitly, never from the flat (active-repo-projected) assigns.
    primary = Enum.find(socket.assigns.review_repos, &(&1.repo_id == "primary"))

    %{
      title: title,
      objective: objective,
      agent_summary: summary
    } = socket.assigns

    repo_path = primary && primary.repo_path
    base_sha = primary && primary.base_sha
    commit_sha = primary && primary.commit_sha
    commits = (primary && primary.commits) || []

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
  def handle_info({:task_updated, task_id, _status, node} = msg, socket) do
    # Node filter FIRST: only a broadcast from the viewed node can be
    # attributed to the reviewed task. Foreign-node events must NOT stash the
    # task id — the debounced reload only re-fetches the review data when THIS
    # task's broadcasts caused it (see the broadcast guard in
    # :node_aware_reload_tasks). handle_task_info/2 re-applies the same node
    # filter for the sidebar reload and returns {:noreply, socket}.
    socket =
      if EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?(socket.assigns, node) do
        assign(socket, :last_broadcast_task_id, task_id)
      else
        socket
      end

    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info({:task_deleted, _task_id, _node} = msg, socket) do
    # A deleted task can never be the reviewed task (there is nothing left to
    # review), so the stash is never set here — only the sidebar reload runs,
    # and only when the event's node matches the viewed node (NodeAware
    # filters foreign-node events before scheduling the debounce).
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    # Debounce timer fired: always refresh the sidebar's running/pending
    # tasks (reload_tasks/1 also clears the debounce-pending flag). The
    # review-data reload is broadcast-guarded — only a `{:task_updated, ...}`
    # broadcast for the reviewed task itself (stashed by the node-filtered
    # clause above) warrants re-fetching the page; other tasks' activity only
    # refreshes the sidebar.
    socket = EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)

    socket =
      if Map.get(socket.assigns, :last_broadcast_task_id, nil) == socket.assigns.task_id do
        start_async_load(socket, Map.get(socket.assigns, :inspect_commit_sha))
      else
        socket
      end

    # Stash lifecycle: reset after the guarded decision (whether or not it
    # matched) so each 300ms debounce window evaluates only the latest event's
    # stash — every event in the new contract carries a task id, so the stash
    # is unambiguous until this handler consumes it.
    socket = assign(socket, :last_broadcast_task_id, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:review_data_loaded, task_id, node, generation, result}, socket) do
    # Async review-data load finished. Stale-guard: drop results for a
    # different task/node or from an older load generation (a newer load was
    # started since — `load_generation` only grows, so `generation < current`
    # means stale).
    stale? =
      task_id != socket.assigns.task_id or node != socket.assigns.current_node or
        generation < Map.get(socket.assigns, :load_generation, 0)

    if stale? do
      {:noreply, socket}
    else
      case result do
        {:ok, assigns_map} ->
          socket =
            socket
            |> assign(assigns_map)
            # Stale merge outcomes must not survive a reload (a re-fetched page
            # starts with a clean per-repo outcome report).
            |> assign(:merge_outcomes, [])

          # The merge check MUST be sequenced here, after the loaded assigns
          # (merge_targets/branch_name/branch_exists/...) are in place. load_data
          # projects the primary flat assigns from the loaded data, but maybe_start
          # then marks the repos :checking — re-project so the flat @merge_status
          # reflects that immediately.
          {:noreply,
           socket
           |> EvoDashWeb.ReviewLive.MergeCheck.maybe_start()
           |> project_active_repo()}

        {:error, reason} ->
          socket =
            assign(socket,
              loading: false,
              error: reason,
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

          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_info({:merge_check_result, task_id, node, repo_id, target, result}, socket) do
    # Async dry-run merge check finished (tagged per repo). Result-shape
    # validation and stale-message guarding live in the support module;
    # re-project afterwards so action_buttons reads the ACTIVE repo's flat
    # @merge_status.
    {:noreply,
     socket
     |> EvoDashWeb.ReviewLive.MergeCheck.handle_result(task_id, node, repo_id, target, result)
     |> project_active_repo()}
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

  # Spawns the async review-data load in a supervised Task (same pattern as
  # `MergeCheck.start/5` and SettingsLive's LLM connection test) and marks the
  # page as loading. The result arrives later as a
  # `{:review_data_loaded, task_id, node, generation, result}` message;
  # `load_generation` is monotonic (incremented per start), so stale results
  # from superseded loads are dropped by the handle_info stale-guard.
  defp start_async_load(socket, inspect_commit_sha) do
    parent = self()
    node = socket.assigns.current_node
    task_id = socket.assigns.task_id
    live_action = socket.assigns.live_action
    gen = Map.get(socket.assigns, :load_generation, 0) + 1

    socket = assign(socket, loading: true, error: nil, load_generation: gen)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result =
        try do
          EvoDashWeb.ReviewLive.LoadData.load(node, task_id,
            live_action: live_action,
            inspect_commit_sha: inspect_commit_sha
          )
        rescue
          # (1) Do we expect this error? YES — the load crosses the node
          #     boundary: the RPC target may be a dead/disappearing remote
          #     daemon, or the task may be deleted mid-load.
          # (2) Is try/rescue the cleanest approach? YES — the alternative is
          #     the page wedging at the loading state forever with no message;
          #     mirrors the justified rescue in merge_check.ex:211-218.
          _ -> {:error, gettext("Failed to load review data.")}
        end

      send(parent, {:review_data_loaded, task_id, node, gen, result})
    end)

    socket
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
      node = socket.assigns.current_node

      case EvoDash.NodeContext.load_file_diff(node, repo_path, base_sha, commit_sha, path) do
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
      node = socket.assigns.current_node

      case EvoDash.NodeContext.load_commit_file_diff(node, repo_path, commit_sha, path) do
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

  # Updates a file's diff in the appropriate data source (commit_data or
  # review_data) and sets the context level and expanded state. On the SHOW
  # route the diff is written into the ACTIVE repo's entry inside
  # @review_repos, and the diff-state maps (selected_file / expanded_files /
  # file_context_levels) are updated for that repo; the :commit route keeps
  # today's legacy flat path-keyed behavior.
  defp update_file_diff_in_socket(socket, path, diff_string, context_level) do
    if socket.assigns.live_action == :commit do
      data = socket.assigns.commit_data

      updated_files =
        Enum.map(data.files, fn f ->
          if f.path == path do
            %{f | diff: diff_string}
          else
            f
          end
        end)

      updated_data = %{data | files: updated_files}
      expanded_files = Map.put(socket.assigns.expanded_files, path, true)
      file_context_levels = Map.put(socket.assigns.file_context_levels, path, context_level)

      assign(socket, [
        {:commit_data, updated_data},
        {:expanded_files, expanded_files},
        {:file_context_levels, file_context_levels}
      ])
    else
      repo_id = socket.assigns.active_repo_id

      review_repos =
        Enum.map(socket.assigns.review_repos, fn repo ->
          if repo.repo_id == repo_id do
            case repo.review_data do
              nil ->
                repo

              data ->
                updated_files =
                  Enum.map(data.files, fn f ->
                    if f.path == path, do: %{f | diff: diff_string}, else: f
                  end)

                %{repo | review_data: %{data | files: updated_files}}
            end
          else
            repo
          end
        end)

      expanded = socket.assigns.expanded_files || %{}
      expanded_sub = Map.put(Map.get(expanded, repo_id, %{}), path, true)
      expanded = Map.put(expanded, repo_id, expanded_sub)

      levels = socket.assigns.file_context_levels || %{}
      levels_sub = Map.put(Map.get(levels, repo_id, %{}), path, context_level)
      levels = Map.put(levels, repo_id, levels_sub)

      socket
      |> assign(
        review_repos: review_repos,
        selected_file: Map.put(socket.assigns.selected_file || %{}, repo_id, path),
        expanded_files: expanded,
        file_context_levels: levels
      )
      |> project_active_repo()
    end
  end

  # Projects the ACTIVE repo's per-repo data onto the flat assigns the template
  # and action components read (repo_path/branch_name/commit_sha/base_sha/
  # branch_exists/review_data/commits/merge_targets/default_merge_target/
  # merge_status). The :commit route is a NO-OP — it keeps today's legacy flat
  # path-keyed state (single repo, no review_repos). The diff-state maps
  # (selected_file / expanded_files / file_context_levels) are NOT re-projected
  # here: they hold the canonical repo-keyed per-repo state, and the template
  # reads the ACTIVE repo's submap via inline Map.get (see the :files_changed
  # tab in render/1). Falls back to the primary entry when the active id is not
  # found (defensive — switch_repo whitelists, so this only guards reloads).
  defp project_active_repo(socket) do
    if socket.assigns.live_action == :commit do
      socket
    else
      active_repo_id = socket.assigns.active_repo_id

      repo =
        Enum.find(socket.assigns.review_repos, &(&1.repo_id == active_repo_id)) ||
          Enum.find(socket.assigns.review_repos, &(&1.repo_id == "primary"))

      assign(socket,
        repo_path: repo && repo.repo_path,
        branch_name: repo && repo.branch_name,
        commit_sha: repo && repo.commit_sha,
        base_sha: repo && repo.base_sha,
        branch_exists: (repo && repo.branch_exists) || false,
        review_data: repo && repo.review_data,
        commits: (repo && repo.commits) || [],
        merge_targets: (repo && repo.merge_targets) || [],
        default_merge_target: repo && repo.default_merge_target,
        merge_status: repo && repo.merge_status
      )
    end
  end

  defp file_path_to_id(path) do
    path
    |> String.replace(~r{[^a-zA-Z0-9_-]}, "-")
    |> String.trim("-")
  end
end
