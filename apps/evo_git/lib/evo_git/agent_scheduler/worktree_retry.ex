defmodule EvoGit.AgentScheduler.WorktreeRetry do
  @moduledoc """
  Retry helpers for transient filesystem failures in the worktree lifecycle.

  Windows file lockers and anti-virus scanners transiently fail file
  operations with `:eacces` / `:eperm` / `:eexist` (and friends). A single
  immediate failure is usually a false alarm — the operation succeeds on
  retry. All retry logic for the worktree lifecycle lives here (single shared
  implementation, no duplicated loops); the delays come exclusively from the
  `retry` library's delay streams (`Retry.DelayStreams`).

  ## Retry policy

  Modest by design — the worktree lifecycle must stay responsive
  (`destroy_worktree/3` runs inside the `WorktreeManager` GenServer process,
  and the create pipeline inside the offloaded create task, both of which
  must not block for long):

  - **4 total attempts** (first attempt immediate, then 3 retries) with
    exponential backoff 50ms → 100ms → 200ms (capped at 200ms) — at most
    350ms of sleeping per operation.
  - The first attempt always runs immediately (a `0` "run now" delay is
    prepended to the delay stream, mirroring the `retry` macro's own
    behavior).

  ## Failure semantics

  The functions never raise on their own: success/error tuples are returned
  as-is and the caller decides loud-vs-tolerate. Exceptions raised by the
  wrapped fun propagate immediately (fail fast — nothing is rescued here,
  equivalent to the `retry` macro's `rescue_only: []`). Filesystem and git
  failures in this lifecycle arrive as error tuples, not exceptions, so
  retrying a raised exception would only mask real bugs.

  ## Options

  All functions accept `opts`:

  - `:delays` — enumerable of millisecond delays between retries (a leading
    `0` "first attempt now" delay is always prepended). Defaults to
    `exponential_backoff(50, 2) |> cap(200) |> take(3)` → 4 total attempts.
    Pass `[0, 0, 0]` for a zero-sleep 4-attempt stream (hermetic tests), or
    `[]` for a single attempt.
  """

  # Transient filesystem error reasons worth retrying. Windows anti-virus
  # scanners and file lockers commonly surface these. `:enoent` is
  # deliberately absent — "not found" means the goal is already met
  # (`rm_rf_retry/2` normalizes it to success rather than retrying).
  @transient_reasons [:eacces, :eperm, :eexist, :enotempty, :ebusy, :again, :eintr]

  @doc """
  Retries `File.rm_rf/1` on transient failures.

  `{:error, :enoent, file}` counts as SUCCESS (the directory is already
  gone) and is normalized to `{:ok, []}`. Non-transient reasons fail fast
  (single attempt). After retries are exhausted, the final error tuple is
  returned.
  """
  @spec rm_rf_retry(Path.t(), keyword()) :: {:ok, [Path.t()]} | {:error, atom(), Path.t()}
  def rm_rf_retry(path, opts \\ []) do
    case retry_on_transient(fn -> File.rm_rf(path) end, opts) do
      # Directory already gone — the goal is met.
      {:error, :enoent, _file} -> {:ok, []}
      result -> result
    end
  end

  @doc """
  Retries `File.mkdir_p/1` on transient failures.

  Non-transient reasons fail fast (single attempt); after retries are
  exhausted the final error tuple is returned. Callers decide loud-vs-tolerate
  (see `WorktreeManager.maybe_init_repo/2`, which raises like `File.mkdir_p!`
  on the final error).
  """
  @spec mkdir_p_retry(Path.t(), keyword()) :: :ok | {:error, atom()}
  def mkdir_p_retry(path, opts \\ []) do
    retry_on_transient(fn -> File.mkdir_p(path) end, opts)
  end

  @doc """
  Runs `fun` retrying only transient failures, returning its final result.

  Retryable results:

  - `{:error, reason, _file}` where `reason` is transient (see
    `retryable_reason?/1`) — `File.rm_rf/1` error shape
  - `{:error, reason}` where `reason` is a transient atom —
    `File.mkdir_p/1` error shape
  - `{:error, {_tag, _output}}` — git adapter error tuples, EXCEPT when the
    repo itself is gone (`:enoent` tag, or "not a git repository" output —
    see `repo_gone_output?/1`) — those are non-transient and fail fast
  - `{:error, output}` where `output` is a binary —
    `Worktrees.delete_branch_tolerant/2` error shape (repo-gone outputs are
    mapped to `:ok` inside that helper already, so this clause is defensive)

  Everything else (including the success shapes `:ok` and `{:ok, _}`) halts
  immediately. On retry exhaustion the last error result is returned as-is.
  """
  @spec retry_on_transient((-> term()), keyword()) :: term()
  def retry_on_transient(fun, opts \\ []) do
    Stream.concat([0], delay_stream(opts))
    |> Enum.reduce_while(nil, fn delay, _last ->
      :timer.sleep(delay)
      result = fun.()

      if retryable?(result) do
        {:cont, result}
      else
        {:halt, result}
      end
    end)
  end

  @doc """
  Returns whether the given POSIX error reason is considered transient
  (worth retrying): `:eacces`, `:eperm`, `:eexist`, `:enotempty`, `:ebusy`,
  `:again`, `:eintr`.
  """
  @spec retryable_reason?(atom()) :: boolean()
  def retryable_reason?(reason), do: reason in @transient_reasons

  @doc """
  Returns whether a git error output indicates the repository itself is
  gone: the adapter's "Repository path does not exist" pre-check message
  (`Git.run/2`) or git's own "not a git repository" fatal. Both mean the
  repo vanished mid-operation (e.g. stale `:DOWN` cleanup after a teardown
  removed the repo) — non-transient within the retry window, and for delete
  operations the goal ("branch is gone") is already met. Shared by the retry
  classification here and by `Worktrees.delete_branch_tolerant/2`.
  """
  @spec repo_gone_output?(String.t()) :: boolean()
  def repo_gone_output?(output) do
    String.contains?(output, "Repository path does not exist") or
      String.contains?(output, "not a git repository")
  end

  defp delay_stream(opts) do
    Keyword.get(opts, :delays, default_delays())
  end

  defp default_delays do
    Retry.DelayStreams.exponential_backoff(50, 2)
    |> Retry.DelayStreams.cap(200)
    |> Stream.take(3)
  end

  # Success shapes (`:ok`, `{:ok, _}`) are not retryable → halt. Everything
  # else (non-transient `{:error, reason, file}`, `{:error, reason}` with a
  # non-binary reason, ...) fails fast — retrying would only mask real bugs.
  # Note: `File.mkdir_p/1` returns 2-tuples `{:error, reason}` (atom reason),
  # `File.rm_rf/1` returns 3-tuples `{:error, reason, file}` — both shapes
  # are classified by `retryable_reason?/1`.
  #
  # Git failure tuples are retried — except when the repo itself is gone
  # (see `repo_gone_output?/1`): `Git.run/2` returns `{:error, {:enoent, ...}}`
  # when the repo path does not exist, and git exits with "fatal: not a git
  # repository" when the repo metadata vanished mid-operation (e.g. stale
  # :DOWN cleanup after a test/teardown removed the repo). Neither is
  # transient within the retry window — the repo is not coming back — and
  # retrying would only burn the delay budget while blocking the
  # WorktreeManager GenServer. `Worktrees.delete_branch_tolerant/2` maps
  # these to `:ok` itself (goal already met), so the binary clause below is
  # defensive for other binary-shape callers; an empty output binary carries
  # no diagnostic and is likewise fail-fast (a race artifact, not a
  # transient lock).
  defp retryable?({:error, reason, _file}), do: retryable_reason?(reason)
  defp retryable?({:error, reason}) when is_atom(reason), do: retryable_reason?(reason)
  defp retryable?({:error, {:enoent, _output}}), do: false

  defp retryable?({:error, {_tag, output}}) when is_binary(output),
    do: not repo_gone_output?(output)

  defp retryable?({:error, {_tag, _output}}), do: true

  defp retryable?({:error, output}) when is_binary(output),
    do: output != "" and not repo_gone_output?(output)

  defp retryable?(_), do: false
end
