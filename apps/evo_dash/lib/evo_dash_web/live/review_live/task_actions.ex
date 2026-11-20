defmodule EvoDashWeb.ReviewLive.TaskActions do
  @moduledoc """
  Task-level review ACTIONS of `EvoDashWeb.ReviewLive` — resume, ignore, create
  PR, and the Extract Skills modal flow — plus the commit-history formatter they
  share.

  Every action function here is an event handler in the shape the page's
  dispatcher expects — `(socket, params)` in, `{:noreply, socket}` out. The work
  itself never runs in the LiveView process: each handler validates the submit,
  records the in-progress state and spawns the I/O through
  `EvoDashWeb.ReviewLive.Runner.spawn/4`; the outcome lands in
  `EvoDashWeb.ReviewLive.ActionResults`.
  """
  use Gettext, backend: EvoDashWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: EvoDashWeb.Endpoint,
    router: EvoDashWeb.Router,
    statics: EvoDashWeb.static_paths()

  alias EvoDashWeb.ReviewLive.Actions
  alias EvoDashWeb.ReviewLive.Runner
  alias EvoDashWeb.ReviewLive.State

  import EvoDashWeb.Helpers, only: [with_node_param: 2]
  import Phoenix.Component, only: [assign: 3]

  def resume(socket, _params) do
    # PRIMARY-scoped (documented limitation): repo-scoped fields come from the
    # "primary" entry explicitly, never from the flat (active-repo-projected)
    # assigns — a foreign repo tab must not change what resume prepares. The
    # entry itself is the CACHED derived assign (Aggregates.primary/1), so this
    # handler never re-walks the repo list. The review-status write runs
    # off-process (Actions.set_review_status/3); the navigation happens when
    # its result lands.
    primary = socket.assigns.primary_repo

    commit_sha = primary && primary.commit_sha
    branch_name = primary && primary.branch_name
    task_id = socket.assigns.task_id
    repo_path = primary && primary.repo_path

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

    if socket.assigns.review_action do
      {:noreply, socket}
    else
      {seq, socket} = State.next_action_seq(socket)

      socket =
        socket
        |> assign(:review_action, %{kind: :resume, seq: seq})
        |> assign(:action_loading, true)

      node = socket.assigns.current_node

      {:noreply,
       Runner.spawn(socket, :resume, %{to: to, flash_msg: flash_msg, seq: seq}, fn ->
         Actions.set_review_status(node, task_id, :continued)
       end)}
    end
  end

  def ignore(socket, _params) do
    task_id = socket.assigns.task_id

    if socket.assigns.review_action do
      {:noreply, socket}
    else
      {seq, socket} = State.next_action_seq(socket)

      socket =
        socket
        |> assign(:review_action, %{kind: :ignore, seq: seq})
        |> assign(:action_loading, true)

      node = socket.assigns.current_node

      {:noreply,
       Runner.spawn(
         socket,
         :ignore,
         %{
           to: with_node_param(~p"/projects", socket.assigns.current_node_id),
           flash_msg: gettext("Review ignored and dismissed."),
           seq: seq
         },
         fn -> Actions.set_review_status(node, task_id, :ignored) end
       )}
    end
  end

  def create_pr(socket, _params) do
    # PRIMARY-scoped (documented limitation): see the resume handler.
    primary = socket.assigns.primary_repo

    repo_path = primary && primary.repo_path
    branch_name = primary && primary.branch_name

    %{objective: objective, agent_summary: result} = socket.assigns

    if socket.assigns.review_action do
      {:noreply, socket}
    else
      {seq, socket} = State.next_action_seq(socket)

      socket =
        socket
        |> assign(:review_action, %{kind: :create_pr, seq: seq})
        |> assign(:action_loading, true)

      node = socket.assigns.current_node

      {:noreply,
       Runner.spawn(socket, :create_pr, %{seq: seq}, fn ->
         Actions.create_pr(node, repo_path, branch_name, objective || "", result || "")
       end)}
    end
  end

  def extract_skills(socket, _params) do
    {:noreply, assign(socket, :show_extract_modal, true)}
  end

  def cancel_extract_skills(socket, _params) do
    {:noreply, assign(socket, :show_extract_modal, false)}
  end

  def confirm_extract_skills(socket, %{"user_note" => user_note}) do
    # PRIMARY-scoped (documented limitation): repo-scoped fields (incl. the
    # commit history for the PR description) come from the "primary" entry
    # explicitly, never from the flat (active-repo-projected) assigns.
    primary = socket.assigns.primary_repo

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

    if socket.assigns.review_action do
      {:noreply, socket}
    else
      {seq, socket} = State.next_action_seq(socket)

      socket =
        socket
        |> assign(:review_action, %{kind: :extract_skills, seq: seq})
        |> assign(:action_loading, true)

      # Skill extraction runs on the node being viewed (local → direct call,
      # remote → RPC), so the git ops inside start_task execute against the
      # repo on the correct host. The modal stays open until the success
      # result lands.
      node = socket.assigns.current_node

      {:noreply,
       Runner.spawn(socket, :extract_skills, %{seq: seq}, fn ->
         Actions.start_task(node, :extract_skills, opts)
       end)}
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
end
