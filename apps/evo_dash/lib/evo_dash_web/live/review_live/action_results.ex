defmodule EvoDashWeb.ReviewLive.ActionResults do
  @moduledoc """
  The async action-result layer of `EvoDashWeb.ReviewLive`.

  Review actions never run in the LiveView process: a store/registry/Git call
  can take many seconds and a `GenServer.call` timeout EXITS the caller. Each
  handler computes a cheap plan, marks the in-progress state, and spawns the
  work through `EvoDashWeb.ReviewLive.Runner.spawn/4`; the outcome arrives as
  `{:review_action_result, task_id, node, action, action_ref, result}` and is
  applied here by `apply/4`, AFTER the in-progress state is cleared by
  `EvoDashWeb.ReviewLive.Runner.clear/3`.

  `apply/4` is the ONE public entry and it is TABLE-DRIVEN through the
  `@handlers` registry below, so an unexpected action shape can never crash the
  page: an unknown action maps to the no-op handler that returns the socket
  unchanged.
  """
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.ReviewLive.Actions
  alias EvoDashWeb.ReviewLive.Diffs
  alias EvoDashWeb.ReviewLive.Runner
  alias EvoDashWeb.ReviewLive.State

  import EvoDashWeb.Helpers, only: [truncate_string: 2]
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2]

  # Action atom → handler. `:resume` and `:ignore` share one tail (both
  # navigate unconditionally), and the two lazy-diff actions share the
  # supersession-guarded diff tail while still telling `Diffs.apply_result/4`
  # which of the two it was.
  @handlers %{
    merge: :merge,
    merge_all: :merge_all,
    reject: :reject,
    resume: :resume_or_ignore,
    ignore: :resume_or_ignore,
    create_pr: :create_pr,
    extract_skills: :extract_skills,
    auto_resolve: :auto_resolve,
    completion: :completion,
    diff: :diff,
    expand_context: :expand_context
  }

  # Applies an action result. `result` is `{:ok, outcome}` (SafeCall's ok
  # wrapping of an `Actions` outcome) or `{:error, reason}` (an exit /
  # exception / throw captured by the boundary).
  def apply(socket, action, ref, result) do
    handler = Map.get(@handlers, action, :noop)
    apply(__MODULE__, handler, [socket, ref, result])
  end

  @doc false
  def merge(socket, ref, result) do
    repo_id = ref.repo_id
    branch = repo_branch(socket, repo_id)

    case result do
      {:ok, {:merged, target}} ->
        settle_repo_action(
          socket,
          repo_id,
          %{state: :merged, target: target},
          merged_flash(target, branch)
        )

      {:ok, {:conflict, details}} ->
        resolve_non_terminal(
          socket,
          repo_id,
          :conflict,
          truncate_string(details, 200),
          gettext(
            "Merge conflict in %{branch}. Resolve it in the repository, or start an auto-resolve task from the primary repo.",
            branch: branch
          )
        )

      other ->
        merge_failure(socket, repo_id, unwrap_error(other))
    end
  end

  @doc false
  def merge_all(socket, _ref, result) do
    case result do
      {:ok, outcomes} when is_list(outcomes) ->
        # One batch: every repo settles on its own card (merged → resolution
        # recorded, conflict/error → non-terminal state) but the flash is a
        # SINGLE summary — no per-repo flashes.
        {socket, merged} = Enum.reduce(outcomes, {socket, 0}, &settle_batch_outcome/2)

        {kind, message} = merge_all_flash(merged, length(outcomes))

        socket
        |> put_flash(kind, message)
        |> maybe_persist_completion()

      _ ->
        put_flash(
          socket,
          :error,
          gettext("Could not merge the repositories — see the repository cards for details.")
        )
    end
  end

  @doc false
  def reject(socket, ref, result) do
    branch = repo_branch(socket, ref.repo_id)

    case result do
      {:ok, :rejected} ->
        settle_repo_action(
          socket,
          ref.repo_id,
          %{state: :rejected},
          gettext("Changes rejected. Branch %{branch} has been deleted.", branch: branch)
        )

      other ->
        reason = inspect(unwrap_error(other))

        resolve_non_terminal(
          socket,
          ref.repo_id,
          :error,
          reason,
          gettext("Failed to reject changes: %{reason}", reason: reason)
        )
    end
  end

  # Resume/ignore navigate UNCONDITIONALLY: the click expresses user intent and
  # the review-status write is advisory. A dead/unknown remote node (or any
  # other write failure) must still take the user to the prepared target, with
  # an error flash carried across the redirect — the previous hard gate left
  # the user stranded on the review page.
  @doc false
  def resume_or_ignore(socket, ref, result) do
    case result do
      {:ok, :ok} ->
        socket
        |> State.invalidate_active_tasks()
        |> put_flash(:info, ref.flash_msg)
        |> push_navigate(to: ref.to)

      other ->
        socket
        |> put_flash(
          :error,
          gettext("Failed to update review status: %{reason}",
            reason: inspect(unwrap_error(other))
          )
        )
        |> push_navigate(to: ref.to)
    end
  end

  @doc false
  def create_pr(socket, _ref, result) do
    case result do
      {:ok, {:pr, url, title}} ->
        socket
        |> assign(has_pr: true, pr_url: url)
        |> put_flash(:success, gettext("Pull request created: %{title}", title: title || url))

      {:ok, :no_pr} ->
        put_flash(
          socket,
          :error,
          gettext(
            "Failed to create pull request. Make sure 'gh' CLI is installed and authenticated."
          )
        )

      other ->
        put_flash(
          socket,
          :error,
          gettext("Failed to create pull request: %{reason}",
            reason: inspect(unwrap_error(other))
          )
        )
    end
  end

  @doc false
  def extract_skills(socket, _ref, result) do
    case result do
      {:ok, {:ok, _task}} ->
        socket
        |> assign(:show_extract_modal, false)
        |> put_flash(
          :info,
          gettext("Skill extraction task started. You can monitor its progress on the dashboard.")
        )

      other ->
        put_flash(
          socket,
          :error,
          gettext("Failed to start skill extraction: %{reason}",
            reason: inspect(unwrap_error(other))
          )
        )
    end
  end

  @doc false
  def auto_resolve(socket, ref, result) do
    case result do
      {:ok, {:ok, _task}} ->
        socket
        |> State.invalidate_active_tasks()
        |> put_flash(
          :success,
          gettext(
            "Auto-resolve task started. It will merge the changes and resolve conflicts; review its result when done."
          )
        )
        |> push_navigate(to: ref.to)

      other ->
        put_flash(
          socket,
          :error,
          gettext("Failed to start auto-resolve: %{reason}",
            reason: inspect(unwrap_error(other))
          )
        )
    end
  end

  @doc false
  def completion(socket, _ref, result) do
    case result do
      {:ok, :ok} ->
        socket

      other ->
        put_flash(
          socket,
          :error,
          gettext("Failed to update review status: %{reason}",
            reason: inspect(unwrap_error(other))
          )
        )
    end
  end

  @doc false
  def diff(socket, ref, result), do: apply_diff(socket, :diff, ref, result)

  @doc false
  def expand_context(socket, ref, result),
    do: apply_diff(socket, :expand_context, ref, result)

  # Lazy file-diff loads (`:diff`) and their context expansions
  # (`:expand_context`): the result is applied only when it is still the CURRENT
  # request for its `{scope, path}` key and the file is still on screen in that
  # scope — see Diffs.apply_result/4.
  defp apply_diff(socket, action, ref, result) do
    key = {Map.get(ref, :repo_id), Map.get(ref, :path)}

    # The in-flight entry holds the seq of the LATEST load started for this
    # {scope, path}. A different value means a newer request superseded this
    # one (and owns the entry), so the stale result is dropped untouched.
    if Map.get(socket.assigns.diff_in_flight, key) != Map.get(ref, :seq) do
      socket
    else
      Diffs.apply_result(socket, action, ref, result)
    end
  end

  # An unexpected action shape must never crash the page.
  @doc false
  def noop(socket, _ref, _result), do: socket

  # One batch outcome: a merged repo records its TERMINAL resolution and counts
  # toward the batch tally; a conflict/error repo lands in its non-terminal
  # state (detail only, no flash — the batch owns the single flash) and does
  # not abort the rest of the batch.
  defp settle_batch_outcome({repo_id, outcome}, {socket, merged}) when is_binary(repo_id) do
    case outcome do
      {:merged, target} ->
        {State.set_repo_resolution(socket, repo_id, %{state: :merged, target: target}),
         merged + 1}

      {:conflict, details} ->
        {State.set_repo_resolution(
           socket,
           repo_id,
           %{state: :conflict, detail: truncate_string(details, 200)}
         ), merged}

      {:error, reason} ->
        {State.set_repo_resolution(socket, repo_id, %{state: :error, detail: inspect(reason)}),
         merged}

      _other ->
        {socket, merged}
    end
  end

  defp settle_batch_outcome(_other, acc), do: acc

  # The batch result's error reason: an `{:error, reason}` wrapper unwraps to
  # `reason`, any other shape passes through for `inspect/1`.
  defp unwrap_error({:error, reason}), do: reason
  defp unwrap_error(other), do: other

  defp merge_failure(socket, repo_id, reason) do
    inspected = inspect(reason)

    resolve_non_terminal(
      socket,
      repo_id,
      :error,
      inspected,
      gettext("Merge failed: %{reason}", reason: inspected)
    )
  end

  # A repo's current branch name (nil when the repo is gone).
  defp repo_branch(socket, repo_id) do
    case State.find_review_repo(socket.assigns.review_repos, repo_id) do
      %{} = repo -> Map.get(repo, :branch_name)
      _ -> nil
    end
  end

  # The batch summary flash for merge_all/1: all merged → success, otherwise an
  # error naming how many landed (the batch puts ONE flash, never per-repo ones).
  defp merge_all_flash(merged, total) when total > 0 and merged == total do
    {:success, gettext("Successfully merged %{count} repositories.", count: total)}
  end

  defp merge_all_flash(0, total) do
    {:error,
     gettext(
       "Could not merge any of the %{total} repositories — see the repository cards for details.",
       total: total
     )}
  end

  defp merge_all_flash(merged, total) do
    # 部分仓库合并失败，其余成功，请查看各仓库卡片
    {:error,
     gettext(
       "Merged %{merged} of %{total} repositories. The remaining repositories could not be merged — see their repository cards for details.",
       merged: merged,
       total: total
     )}
  end

  # Shared tail of a TERMINAL per-repo action (merge/reject succeeded): records
  # the resolution, then either COMPLETES the whole review (every repo TERMINAL
  # → persist the aggregate review_status + invalidate the sidebar hub snapshot)
  # or STAYS on the page with a success flash (other repos still pending).
  # Returns the updated socket.
  defp settle_repo_action(socket, repo_id, resolution, success_flash) do
    socket
    |> State.set_repo_resolution(repo_id, resolution)
    |> put_flash(:success, success_flash)
    |> maybe_persist_completion()
  end

  # Persists the aggregate review status when the review is COMPLETE (every
  # change-bearing repo terminal). The store write runs off-process
  # (`:completion` action, no in-progress marker — it is a background
  # bookkeeping write) and the sidebar hub snapshot is invalidated right away so
  # the destination mount is COLD and re-fetches instead of seeding the
  # pre-action state.
  defp maybe_persist_completion(socket) do
    # Reads the CACHED completion (put_derived/1 runs in set_repo_resolution/3,
    # i.e. before this function in the same action tail) instead of re-walking
    # the repo list.
    case socket.assigns.completion_status do
      nil ->
        socket

      status ->
        {seq, socket} = State.next_action_seq(socket)
        node = socket.assigns.current_node
        task_id = socket.assigns.task_id

        socket
        |> assign(:review_status, status)
        # review_status is one of the three inputs of the aggregate, so the
        # derived values are refreshed once it changed.
        |> State.put_derived()
        |> State.invalidate_active_tasks()
        |> Runner.spawn(:completion, %{status: status, seq: seq}, fn ->
          Actions.set_review_status(node, task_id, status)
        end)
    end
  end

  # Shared tail of a NON-terminal per-repo action (conflict / error): the repo
  # stays retryable, so record the outcome on its own card and STAY on the page.
  # Returns the updated socket (callers wrap it in {:noreply, _}).
  defp resolve_non_terminal(socket, repo_id, state, detail, error_flash) do
    socket = State.set_repo_resolution(socket, repo_id, %{state: state, detail: detail})
    put_flash(socket, :error, error_flash)
  end

  defp merged_flash(target, branch) when is_binary(target) and target != "" do
    gettext("Changes merged successfully into %{target}! Branch %{branch} has been deleted.",
      target: target,
      branch: branch
    )
  end

  defp merged_flash(_target, branch) do
    gettext("Changes merged successfully! Branch %{branch} has been deleted.", branch: branch)
  end
end
