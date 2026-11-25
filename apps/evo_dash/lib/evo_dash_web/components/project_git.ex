defmodule EvoDashWeb.ProjectGit do
  @moduledoc "The selected project's source control panel."
  use EvoDashWeb, :live_component

  alias EvoDash.ProjectGit, as: Git
  alias EvoDashWeb.ReviewComponents.DiffViewer
  alias EvoDashWeb.WorkbenchComponent

  @file_groups [:conflicted, :staged, :unstaged, :untracked]
  @file_limit 30
  @branch_limit 60

  attr(:github_status, :map,
    default: nil,
    doc:
      "the project's GitHub upstream status (`%{state: :ok, owner:, repo:}`) — the " <>
        "GitHub block renders ONLY from this assign and never issues its own RPC"
  )

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       scope: nil,
       file_limit: @file_limit,
       shown_files: %{},
       branch_limit: @branch_limit,
       head: nil,
       snapshot: nil,
       snapshots_by_project: %{},
       section: "changes",
       query: "",
       branch: nil,
       history: nil,
       preview: nil,
       lines: [],
       clipped?: false,
       omitted: 0,
       busy: nil,
       preview_loading?: false,
       preview_error: nil,
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    project_scope = {assigns.target, assigns.node_id, assigns.project}
    changed? = not match?({^project_scope, _}, socket.assigns.scope)
    socket = assign(socket, assigns)

    socket =
      if changed? do
        cached = socket.assigns.snapshots_by_project[project_scope]

        socket
        |> assign(
          scope: {project_scope, make_ref()},
          head: display_head(get_in(cached, [:snapshot, :branch])),
          snapshot: cached[:snapshot],
          branch: nil,
          query: "",
          error: cached[:error],
          history: nil,
          shown_files: %{}
        )
        |> assign(busy: nil)
        |> clear_preview()
        |> load_head()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("git_refresh", _, socket), do: {:noreply, refresh(socket)}

  def handle_event("git_section", %{"section" => section}, socket)
      when section in ["changes", "branches", "commits"],
      do: {:noreply, socket |> assign(section: section, error: nil) |> load_history()}

  def handle_event("git_more_commits", _, socket),
    do: {:noreply, load_history(socket, :more)}

  def handle_event("git_retry_history", _, socket),
    do: {:noreply, load_history(socket, :retry)}

  def handle_event("git_commit", %{"sha" => sha}, socket) do
    %{snapshot: snapshot, target: target, history: history} = socket.assigns

    case Enum.find(history[:rows] || [], &(&1.sha == sha)) do
      nil ->
        {:noreply, socket}

      commit ->
        preview = %{
          kind: :commit,
          item: commit,
          title: commit.short,
          heading: commit.subject,
          subtitle: meta_line([commit.short, commit.author, date_label(commit.date)])
        }

        {:noreply,
         open_preview(socket, preview, fn -> Git.commit_diff(target, snapshot.root, sha) end)}
    end
  end

  def handle_event("git_search", %{"query" => query}, socket) do
    {:noreply, assign(socket, query: String.slice(query, 0, 200), branch: nil)}
  end

  def handle_event("git_more_files", %{"kind" => name}, socket) do
    case Enum.find(@file_groups, &(Atom.to_string(&1) == name)) do
      nil ->
        {:noreply, socket}

      kind ->
        shown = Map.update(socket.assigns.shown_files, kind, @file_limit * 2, &(&1 + @file_limit))
        {:noreply, assign(socket, shown_files: shown)}
    end
  end

  def handle_event("git_branch", %{"ref" => ref}, socket) do
    branch = Enum.find(branches(socket.assigns.snapshot), &(&1.ref == ref))
    {:noreply, assign(socket, branch: branch, error: nil)}
  end

  def handle_event("git_switch", %{"ref" => ref}, socket) do
    {:noreply, branch_action(socket, :switch, ref, &Git.switch_branch/3)}
  end

  def handle_event("git_start_task", %{"ref" => ref}, socket) do
    {:noreply, branch_action(socket, :start_task, ref, &Git.starting_commit/3)}
  end

  def handle_event("git_file", %{"index" => index}, socket) do
    with %{changes: changes, root: root} <- socket.assigns.snapshot,
         {index, ""} when index >= 0 <- Integer.parse(index),
         %{} = file <- Enum.at(changes, index),
         %{target: target} <- socket.assigns do
      path = String.replace_invalid(file.path)
      title = Path.basename(path)
      subtitle = meta_line([group_label(file.kind), if(path != title, do: path)])
      preview = %{kind: :file, item: file, title: title, heading: title, subtitle: subtitle}
      {:noreply, open_preview(socket, preview, fn -> Git.diff(target, root, file) end)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("git_close_diff", _, socket),
    do: {:noreply, socket |> cancel_async({:preview, socket.assigns.scope}) |> clear_preview()}

  @impl true
  def handle_async({:head, scope}, {:ok, {:ok, head}}, %{assigns: %{scope: scope}} = socket),
    do: {:noreply, assign(socket, head: display_head(head))}

  def handle_async(
        {:snapshot, {project_scope, _} = scope},
        {:ok, {:ok, snapshot}},
        %{assigns: %{scope: scope}} = socket
      ) do
    branch =
      if socket.assigns.branch,
        do: Enum.find(snapshot.branches, &(&1.ref == socket.assigns.branch.ref))

    {:noreply,
     socket
     |> assign(
       snapshot: snapshot,
       snapshots_by_project:
         Map.put(socket.assigns.snapshots_by_project, project_scope, %{snapshot: snapshot}),
       head: display_head(snapshot[:branch]),
       branch: branch,
       busy: nil,
       error: nil
     )
     |> load_history()}
  end

  def handle_async(
        {:snapshot, {project_scope, _} = scope},
        result,
        %{assigns: %{scope: scope}} = socket
      ) do
    error = error_message(result)

    cache =
      if result == {:ok, {:error, :not_a_repository}},
        do: Map.put(socket.assigns.snapshots_by_project, project_scope, %{error: error}),
        else: Map.delete(socket.assigns.snapshots_by_project, project_scope)

    {:noreply,
     assign(socket,
       snapshot: nil,
       head: nil,
       busy: nil,
       error: error,
       snapshots_by_project: cache
     )}
  end

  def handle_async(
        {:switch, scope, _branch},
        {:ok, {:ok, _}},
        %{assigns: %{scope: scope}} = socket
      ),
      do: {:noreply, socket |> assign(busy: nil, branch: nil) |> refresh()}

  def handle_async(
        {:start_task, scope, branch},
        {:ok, {:ok, commit}},
        %{assigns: %{scope: scope}} = socket
      ) do
    href =
      WorkbenchComponent.navigation_path("/projects", socket.assigns.node_id,
        project: socket.assigns.project,
        wb_task: "1",
        wb_git_branch: String.replace_invalid(branch),
        starting_commit: commit
      )

    {:noreply, socket |> assign(busy: nil) |> push_navigate(to: href)}
  end

  def handle_async({operation, scope, _branch}, result, %{assigns: %{scope: scope}} = socket)
      when operation in [:switch, :start_task],
      do: {:noreply, assign(socket, busy: nil, error: error_message(result))}

  def handle_async(
        {:preview, scope},
        {:ok, {:ok, patch}},
        %{assigns: %{scope: scope, preview: %{}}} = socket
      ) do
    {lines, omitted} = DiffViewer.parse_diff_lines_bounded(%{diff: patch.text})

    {:noreply,
     assign(socket,
       lines: lines,
       clipped?: patch.clipped?,
       preview_loading?: false,
       omitted: omitted
     )}
  end

  def handle_async({:preview, scope}, result, %{assigns: %{scope: scope, preview: %{}}} = socket),
    do: {:noreply, assign(socket, preview_loading?: false, preview_error: error_message(result))}

  def handle_async(
        {:history, scope},
        {:ok, {:ok, data}},
        %{assigns: %{scope: scope}} = socket
      ) do
    rows = (socket.assigns.history[:rows] || []) ++ data.rows
    history = %{data | rows: rows}

    {:noreply, assign(socket, history: history)}
  end

  def handle_async({:history, scope}, result, %{assigns: %{scope: scope}} = socket) do
    history =
      Map.merge(socket.assigns.history || %{}, %{loading?: false, error: error_message(result)})

    {:noreply, assign(socket, history: history)}
  end

  def handle_async(_, _, socket), do: {:noreply, socket}

  defp load_history(socket, mode \\ :initial)

  defp load_history(
         %{
           assigns: %{
             snapshot: %{root: root} = snapshot,
             target: target,
             scope: scope,
             section: "commits",
             busy: busy
           }
         } = socket,
         mode
       )
       when busy != :snapshot do
    cached = socket.assigns.history

    cond do
      cached && cached[:loading?] ->
        socket

      mode == :initial && cached ->
        socket

      mode == :more && (!cached || !cached[:more?]) ->
        socket

      true ->
        previous = cached || %{}
        offset = length(previous[:rows] || [])

        socket
        |> assign(history: Map.merge(previous, %{loading?: true, error: nil}))
        |> start_async({:history, scope}, fn ->
          Git.commits(target, root, snapshot[:commit], offset)
        end)
    end
  end

  defp load_history(socket, _), do: socket

  defp open_preview(socket, preview, run) do
    operation = {:preview, socket.assigns.scope}

    socket
    |> cancel_async(operation)
    |> clear_preview()
    |> assign(preview: preview, preview_loading?: true)
    |> start_async(operation, run)
  end

  defp load_head(socket) do
    %{target: target, project: project, scope: scope} = socket.assigns

    if connected?(socket) and target != nil and is_binary(project) do
      start_async(socket, {:head, scope}, fn -> Git.head(target, project) end)
    else
      socket
    end
  end

  defp refresh(
         %{
           assigns: %{
             busy: nil,
             target: target,
             project: project,
             scope: {project_scope, _} = scope
           }
         } = socket
       )
       when not is_nil(target) and is_binary(project) do
    socket
    |> cancel_async({:head, scope})
    |> cancel_async({:preview, scope})
    |> cancel_async({:history, scope})
    |> clear_preview()
    |> assign(
      busy: :snapshot,
      error: get_in(socket.assigns.snapshots_by_project, [project_scope, :error]),
      history: nil
    )
    |> start_async({:snapshot, scope}, fn -> Git.snapshot(target, project) end)
  end

  defp refresh(socket), do: socket

  defp branch_action(socket, operation, ref, action) do
    with %{busy: nil, snapshot: %{root: root, branches: branches}, target: target, scope: scope} <-
           socket.assigns,
         %{} = branch <- Enum.find(branches, &(&1.ref == ref)) do
      socket
      |> assign(busy: operation, error: nil)
      |> start_async({operation, scope, branch.name}, fn -> action.(target, root, branch) end)
    else
      _ -> socket
    end
  end

  defp clear_preview(socket),
    do:
      assign(socket,
        preview: nil,
        lines: [],
        omitted: 0,
        clipped?: false,
        preview_error: nil,
        preview_loading?: false
      )

  defp display_head(branch) when is_binary(branch), do: String.replace_invalid(branch)
  defp display_head(_), do: nil

  defp branches(nil), do: []
  defp branches(snapshot), do: snapshot.branches

  defp error_message({:ok, {:error, :node_unavailable}}),
    do: gettext("Git is unavailable on the selected server.")

  defp error_message({:ok, {:error, :project_unavailable}}),
    do: gettext("Select a project to see its Git status.")

  defp error_message({:ok, {:error, :not_a_repository}}),
    do: gettext("This project does not have a Git repository.")

  defp error_message({:ok, {:error, {_reason, detail}}}) when is_binary(detail),
    do: detail |> String.replace_invalid() |> String.slice(0, 1600)

  defp error_message(_), do: gettext("Git operation failed. Refresh and try again.")

  defp group_label(:conflicted), do: gettext("Conflicts")
  defp group_label(:staged), do: gettext("Staged")
  defp group_label(:unstaged), do: gettext("Unstaged")
  defp group_label(:untracked), do: gettext("Untracked")

  defp kind_label(:local), do: gettext("Local branch")
  defp kind_label(:remote), do: gettext("Remote branch")

  defp file_groups(changes) do
    indexed = changes |> Enum.with_index() |> Enum.group_by(fn {file, _} -> file.kind end)
    for kind <- @file_groups, group = Map.get(indexed, kind), do: {kind, group}
  end

  defp matches_branch?(branch, query),
    do:
      String.contains?(
        String.downcase(String.replace_invalid(branch.name)),
        String.downcase(String.trim(query))
      )

  defp short_commit(nil), do: nil
  defp short_commit(commit), do: String.slice(commit, 0, 9)

  defp date_label(date) when is_binary(date), do: String.slice(date, 0, 10)
  defp date_label(_), do: nil

  defp meta_line(parts), do: parts |> Enum.filter(&(&1 not in [nil, ""])) |> Enum.join(" · ")

  # Ahead/behind arrive as strings ("0" is truthy in Elixir), so a zero count is
  # rendered as absent rather than as a noisy "↑0".
  defp tracking_count(snapshot, key) when is_map(snapshot) do
    case snapshot[key] do
      count when is_binary(count) and count not in ["", "0"] -> count
      _ -> nil
    end
  end

  defp tracking_count(_snapshot, _key), do: nil

  # The 2-char status chip is tinted by the git status letter (index/worktree
  # short code); anything unknown keeps the neutral base-content tint.
  defp code_tint(code) when is_binary(code) do
    case String.trim(code) do
      "A" <> _ -> "bg-success/15 text-success"
      "D" <> _ -> "bg-error/15 text-error"
      "M" <> _ -> "bg-warning/15 text-warning"
      "R" <> _ -> "bg-info/15 text-info"
      "C" <> _ -> "bg-info/15 text-info"
      "U" <> _ -> "bg-error/15 text-error"
      _ -> "bg-base-content/10 text-base-content/70"
    end
  end

  defp code_tint(_code), do: "bg-base-content/10 text-base-content/70"

  defp current_branch?(branch, snapshot),
    do: branch.kind == :local && branch.name == snapshot[:branch]

  defp branch_meta(branch, snapshot) do
    if current_branch?(branch, snapshot),
      do: gettext("Current branch"),
      else: kind_label(branch.kind)
  end

  # The GitHub block renders ONLY from the parent's upstream status — no RPC of
  # its own — and disappears entirely for a project without an upstream.
  defp github_slug(%{state: :ok, owner: owner, repo: repo})
       when is_binary(owner) and is_binary(repo) and owner != "" and repo != "",
       do: "#{owner}/#{repo}"

  defp github_slug(_status), do: nil

  defp branch_count_label(total, limit) when total > limit,
    do: gettext("%{shown} of %{total} branches", shown: limit, total: total)

  defp branch_count_label(total, _limit),
    do: ngettext("%{count} branch", "%{count} branches", total)

  attr(:label, :string, required: true)
  attr(:status, :string, required: true)

  defp section_heading(assigns) do
    ~H"""
    <h3 class="mx-2 mb-2 flex items-baseline justify-between gap-2 text-sm font-semibold">
      <span>{@label}</span>
      <span class="workbench-git-count text-xs text-base-content/70">{@status}</span>
    </h3>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="workbench-git-content"
      phx-hook="WorkbenchSection"
      data-workbench-git-head={@head || ""}
      data-workbench-git-diff={@preview && @preview.title}
      data-workbench-git-scope={
        if @project, do: WorkbenchComponent.navigation_path("/", @node_id, project: @project)
      }
      data-workbench-git-target={if @target, do: Atom.to_string(@target)}
    >
      <header class="workbench-section-heading workbench-git-heading">
        <div class="min-w-0 flex-1">
          <p class="workbench-git-eyebrow text-2xs uppercase">{gettext("Source control")}</p>
          <h2 class="truncate text-sm font-semibold" title={@project}>
            {if @project, do: Path.basename(@project), else: gettext("No project")}
          </h2>
          <div :if={@snapshot || @head} class="workbench-git-branchbar">
            <button
              type="button"
              class="workbench-git-chip min-h-(--control-h-sm) pointer-coarse:min-h-(--touch-target)"
              phx-click="git_section"
              phx-value-section="branches"
              phx-target={@myself}
              title={gettext("Browse branches")}
            >
              <.icon name="hero-code-bracket" class="size-3.5 shrink-0" />
              <span class="min-w-0 truncate">{@head || gettext("Detached HEAD")}</span>
              <span
                :if={tracking_count(@snapshot, :ahead)}
                class="workbench-git-delta"
                title={gettext("Ahead of upstream")}
              >↑{tracking_count(@snapshot, :ahead)}</span>
              <span
                :if={tracking_count(@snapshot, :behind)}
                class="workbench-git-delta"
                title={gettext("Behind upstream")}
              >↓{tracking_count(@snapshot, :behind)}</span>
            </button>
          </div>
        </div>
        <div class="flex shrink-0 items-center gap-1">
          <button
            type="button"
            id="workbench-git-refresh"
            class="workbench-icon-button"
            phx-click="git_refresh"
            phx-target={@myself}
            disabled={@busy != nil or @target == nil}
            aria-label={gettext("Refresh Git status")}
            title={gettext("Refresh Git status")}
          >
            <.icon name="hero-arrow-path" class="size-4" />
          </button>
          <button
            type="button"
            data-workbench-close-git
            class="workbench-icon-button"
            aria-label={gettext("Close Git panel")}
            title={gettext("Close Git panel")}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </header>

      <div
        :if={@snapshot && (@snapshot[:commit] || @snapshot[:upstream])}
        class="workbench-git-summary flex-none"
        title={@snapshot.root}
      >
        <p :if={@snapshot[:commit]} class="workbench-git-summary-line">
          <code class="workbench-git-summary-sha font-mono">{short_commit(@snapshot.commit)}</code>
          <span class="min-w-0 flex-1 truncate" title={@snapshot.subject}>{@snapshot.subject}</span>
        </p>
        <%!-- Git 术语：当前分支跟踪的上游引用。 --%>
        <p :if={@snapshot[:upstream]} class="workbench-git-summary-line">
          <span class="sr-only">{gettext("Upstream")}: </span>
          <.icon name="hero-arrow-up-right" class="size-3.5 shrink-0 self-center" />
          <span class="min-w-0 flex-1 truncate" title={@snapshot.upstream}>{@snapshot.upstream}</span>
        </p>
      </div>

      <%!-- Keep the three columns; their row height is independent of the scroller. --%>
      <div
        :if={@snapshot}
        class="workbench-segmented workbench-git-views mt-2 flex-none"
        role="group"
        aria-label={gettext("Git views")}
      >
        <button
          :for={
            {section, label} <- [
              {"changes", gettext("Changes")},
              {"branches", gettext("Branches")},
              {"commits", gettext("Commits")}
            ]
          }
          type="button"
          class="min-h-(--control-h-sm) pointer-coarse:min-h-(--touch-target)"
          aria-pressed={to_string(@section == section)}
          phx-click="git_section"
          phx-target={@myself}
          phx-value-section={section}
        >
          <span class="wrap-anywhere text-xs">{label}</span>
        </button>
      </div>

      <.form
        :if={@snapshot && @section == "branches"}
        for={%{}}
        id="workbench-git-search"
        class="mt-2 flex-none"
        phx-change="git_search"
        phx-target={@myself}
      >
        <.input
          type="search"
          name="query"
          id="workbench-git-query"
          value={@query}
          autocomplete="off"
          aria-controls="workbench-git-branches"
          aria-label={gettext("Search branches")}
          placeholder={gettext("Search branches")}
          class="workbench-git-search"
        />
      </.form>

      <p :if={@target == nil} class="workbench-hint">
        {gettext("Connect to see the project's Git status.")}
      </p>
      <p :if={@busy == :snapshot && !@error} class="workbench-hint" role="status">
        {if @snapshot, do: gettext("Refreshing Git status…"), else: gettext("Loading Git status…")}
      </p>
      <p :if={@error} class="workbench-git-error" role="alert">{@error}</p>

      <div class="workbench-git-body content-start" aria-busy={to_string(@busy != nil)}>
        <EvoDashWeb.Components.Skeleton.row
          :if={@busy == :snapshot && !@snapshot && !@error}
          count={3}
          class="px-1.5"
        />

        <div :if={@snapshot && @section == "changes"} id="workbench-git-changes">
          <% change_count = length(@snapshot.changes) %>
          <%!-- Git 术语：当前签出的文件及其改动。 --%>
          <.section_heading
            :if={change_count > 0}
            label={gettext("Working tree")}
            status={ngettext("%{count} change", "%{count} changes", change_count)}
          />
          <p :if={change_count == 0} class="workbench-hint">
            {gettext("Working tree is clean.")}
          </p>
          <section :for={{kind, files} <- file_groups(@snapshot.changes)} class="workbench-git-group">
            <% limit = Map.get(@shown_files, kind, @file_limit) %>
            <h3 class="workbench-git-group-heading">
              <span>{group_label(kind)}</span>
              <span class="workbench-git-count">{length(files)}</span>
            </h3>
            <button
              :for={{file, index} <- Enum.take(files, limit)}
              type="button"
              class="workbench-row workbench-git-file"
              aria-pressed={
                to_string((@preview && @preview.kind == :file && @preview.item == file) || false)
              }
              data-workbench-git-file
              data-workbench-git-preview
              phx-click="git_file"
              phx-value-index={index}
              phx-target={@myself}
              title={String.replace_invalid(file.path)}
            >
              <span class="workbench-git-file-icon" aria-hidden="true">
                <.icon name="hero-document" class="size-3.5" />
              </span>
              <span class="min-w-0 flex-1 truncate text-sm">{String.replace_invalid(file.path)}</span>
              <span
                class={["workbench-git-code font-mono", code_tint(file.code)]}
                aria-hidden="true"
              >{file.code}</span>
            </button>
            <button
              :if={length(files) > limit}
              type="button"
              class="workbench-git-more min-h-(--control-h-sm) pointer-coarse:min-h-(--touch-target)"
              phx-click="git_more_files"
              phx-value-kind={kind}
              phx-target={@myself}
            >
              {gettext("Show more files")}
            </button>
          </section>
        </div>

        <div :if={@snapshot && @section == "commits"} id="workbench-git-history">
          <% history = @history || %{} %>
          <% rows = history[:rows] || [] %>
          <.section_heading
            :if={rows != []}
            label={gettext("Commit history")}
            status={ngettext("%{count} commit loaded", "%{count} commits loaded", length(rows))}
          />
          <p :if={history[:loading?]} class="workbench-hint" role="status">{gettext("Loading…")}</p>
          <EvoDashWeb.Components.Skeleton.row
            :if={history[:loading?] && rows == []}
            count={3}
            class="px-1.5 pt-1"
          />
          <div :if={history[:error]} class="workbench-git-error" role="alert">
            <p>{history.error}</p>
            <button
              type="button"
              class="workbench-git-more min-h-(--control-h-sm) pointer-coarse:min-h-(--touch-target)"
              phx-click="git_retry_history"
              phx-target={@myself}
            >
              {gettext("Retry")}
            </button>
          </div>
          <p
            :if={history[:rows] == [] && !history[:loading?] && !history[:error]}
            class="workbench-hint"
          >
            {gettext("No commits on this branch.")}
          </p>
          <button
            :for={commit <- rows}
            type="button"
            class="workbench-row workbench-git-history-entry"
            aria-pressed={
              to_string(
                (@preview && @preview.kind == :commit && @preview.item.sha == commit.sha) || false
              )
            }
            data-workbench-git-preview
            phx-click="git_commit"
            phx-target={@myself}
            phx-value-sha={commit.sha}
            title={commit.subject}
          >
            <span class="truncate text-sm">{commit.subject}</span>
            <span class="workbench-git-entry-meta truncate text-xs font-mono">
              {meta_line([commit.short, commit.author, date_label(commit.date)])}
            </span>
          </button>
          <button
            :if={history[:more?] && !history[:loading?]}
            type="button"
            class="workbench-git-more min-h-(--control-h-sm) pointer-coarse:min-h-(--touch-target)"
            phx-click="git_more_commits"
            phx-target={@myself}
          >{gettext("Show more commits")}</button>
        </div>

        <.portal :if={@preview} id="workbench-git-diff-portal" target="#workbench-git-diff-host">
          <section
            id="workbench-git-diff"
            class="workbench-git-diff"
            aria-labelledby="workbench-git-diff-title"
            phx-hook="WorkbenchSection"
          >
            <header>
              <div class="min-w-0">
                <h1
                  id="workbench-git-diff-title"
                  tabindex="-1"
                  class="truncate"
                  title={@preview.heading}
                >
                  {@preview.heading}
                </h1>
                <p class="truncate" title={@preview.subtitle}>{@preview.subtitle}</p>
              </div>
              <button
                type="button"
                class="workbench-icon-button"
                aria-label={gettext("Close diff")}
                title={gettext("Close diff")}
                data-workbench-close-git-diff
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </header>
            <p :if={@preview_loading?} class="workbench-hint" role="status">
              {gettext("Loading…")}
            </p>
            <p :if={@preview_error} class="workbench-git-error" role="alert">{@preview_error}</p>
            <p
              :if={!@preview_loading? && !@preview_error && @lines == []}
              class="workbench-hint"
            >
              {gettext("No diff to display.")}
            </p>
            <div
              :if={@lines != []}
              class="workbench-git-diff-lines"
              tabindex="0"
              aria-label={gettext("Diff")}
            >
              <code :for={line <- @lines} data-diff-type={line.type}>{line.prefix}{line.content}</code>
            </div>
            <p :if={@clipped? || @omitted > 0} class="workbench-hint">
              {gettext("Diff preview truncated.")}
            </p>
          </section>
        </.portal>

        <div :if={@snapshot && @section == "branches"} id="workbench-git-branches">
          <% matches = Enum.filter(@snapshot.branches, &matches_branch?(&1, @query)) %>
          <% match_count = length(matches) %>
          <.section_heading
            :if={match_count > 0}
            label={gettext("Branch list")}
            status={branch_count_label(match_count, @branch_limit)}
          />

          <div :if={@branch} class="workbench-git-branch-actions">
            <code title={String.replace_invalid(@branch.name)}>{String.replace_invalid(@branch.name)}</code>
            <button
              :if={@branch.kind == :remote || @branch.name != @snapshot[:branch]}
              type="button"
              class="btn btn-sm btn-primary"
              phx-click="git_switch"
              phx-target={@myself}
              phx-value-ref={@branch.ref}
              disabled={@busy != nil}
            >{if @branch.kind == :remote,
              do: gettext("Check out tracking branch"),
              else: gettext("Switch project branch")}</button>
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="git_start_task"
              phx-target={@myself}
              phx-value-ref={@branch.ref}
              disabled={@busy != nil}
            >{gettext("Start task from branch")}</button>
          </div>

          <p :if={match_count == 0} class="workbench-hint">{gettext("No matching branches.")}</p>
          <button
            :for={branch <- Enum.take(matches, @branch_limit)}
            type="button"
            class="workbench-row workbench-git-branch"
            aria-pressed={to_string(@branch == branch)}
            phx-click="git_branch"
            phx-target={@myself}
            phx-value-ref={branch.ref}
            title={String.replace_invalid(branch.name)}
          >
            <span class="workbench-git-file-icon" aria-hidden="true">
              <.icon name="hero-code-bracket" class="size-3.5" />
            </span>
            <span class="grid min-w-0 flex-1">
              <span class="truncate text-sm">{String.replace_invalid(branch.name)}</span>
              <span class="workbench-git-entry-meta truncate">{branch_meta(branch, @snapshot)}</span>
            </span>
            <span
              :if={current_branch?(branch, @snapshot)}
              class="workbench-git-current-mark"
              title={gettext("Current branch")}
            >
              <.icon name="hero-check" class="size-3.5" />
            </span>
          </button>
          <p :if={match_count > @branch_limit} class="workbench-hint">
            {gettext("Search to narrow the branch list.")}
          </p>
        </div>
      </div>

      <section
        :if={github_slug(@github_status)}
        class="workbench-git-github"
        aria-label={gettext("GitHub")}
      >
        <p class="workbench-git-github-slug">
          <.icon name="brand-github" class="size-4 shrink-0" />
          <span class="min-w-0 truncate font-mono text-xs">{github_slug(@github_status)}</span>
        </p>
        <button
          type="button"
          class="workbench-row workbench-git-github-issues"
          phx-click="open_github_issues"
          title={"#{gettext("Open GitHub Issues")} · #{github_slug(@github_status)}"}
        >
          <.icon name="hero-chat-bubble-left-right" class="size-4 shrink-0" />
          <span class="min-w-0 flex-1 truncate text-sm">{gettext("Issues")}</span>
          <.icon name="hero-chevron-right" class="size-4 shrink-0" />
        </button>
      </section>
    </section>
    """
  end
end
