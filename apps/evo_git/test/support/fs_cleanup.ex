defmodule EvoGit.TestSupport.FsCleanup do
  @moduledoc """
  Deadline-bounded recursive removal for test-owned temporary trees.

  `File.rm_rf/1` is not safe against a LIVE writer. It lists a directory, deletes
  what it listed and only then `rmdir`s the parent, so a process that (re)creates
  an entry in between makes the final `rmdir` fail with `{:error, :eexist, _}`
  (this host's filesystem; `:enotempty` on others). `File.rm_rf!/1` then RAISES,
  and ExUnit attributes the `File.Error` to whichever test's `on_exit` lost the
  race — never to the process that actually did the writing. Under load a shared
  `EvoGit.TaskSupervisor` child (an agent exchange worker, a `TaskRegistry` read
  worker, a `TaskExecutor` task) can be starved for seconds, which is exactly how
  long the race takes to lose.

  `rm_rf!/2` therefore retries the removal until ONE bounded deadline instead of
  a fixed attempt count: a transient error (`:eexist`, `:enotempty`) is retried
  after a short cadence (and after the caller's `:before_attempt` hook, which
  the config-dir seam uses to drain its supervised writers), while every other
  error — and a transient error that outlives the deadline — is raised as a
  `File.Error`, so a directory that genuinely cannot be removed still fails
  loudly.

  This is the shared primitive for every test teardown that removes a temporary
  tree a live process may touch; do not hand-roll a retry loop next to it.
  """

  # Overall budget for one removal, drain included. It is paid ONLY when a
  # writer keeps racing: the healthy path is a single `File.rm_rf/1` call.
  @budget_ms 10_000
  # Cadence between removal attempts. The re-creator this defends against is a
  # scheduled process writing a few bytes, so a short wait is enough; it exists
  # to let the writer run, not to "wait out" the machine.
  @retry_delay_ms 20
  # The transient errnos: `rmdir` of a directory that was non-empty when it was
  # called. On this host's filesystem `:file.del_dir/1` answers `:eexist`; other
  # filesystems answer `:enotempty`. Both mean "a writer won a race", not
  # "this tree cannot be removed".
  @transient_reasons [:eexist, :enotempty]

  @doc """
  Removes `path` recursively, retrying transient races until a bounded deadline.

  Returns `:ok`. Raises `File.Error` when the tree cannot be removed — a
  non-transient error immediately, a transient one only once the deadline is
  exhausted, with a `Logger.error` naming the root, the residual entries and
  (when the caller provided one) the drain result.

  Options:

    * `:budget_ms` — the overall deadline (default #{@budget_ms} ms);
    * `:retry_delay_ms` — the cadence between attempts (default #{@retry_delay_ms} ms);
    * `:before_attempt` — a `(remaining_ms -> any)` hook run before EVERY
      attempt, including the first (the config-dir seam drains its supervised
      writers here).
  """
  @spec rm_rf!(Path.t(), keyword()) :: :ok
  def rm_rf!(path, opts \\ []) do
    budget_ms = Keyword.get(opts, :budget_ms, @budget_ms)
    retry_delay_ms = Keyword.get(opts, :retry_delay_ms, @retry_delay_ms)
    before_attempt = Keyword.get(opts, :before_attempt, fn _remaining -> :ok end)

    path = to_string(path)
    deadline = System.monotonic_time(:millisecond) + budget_ms
    remove(path, deadline, retry_delay_ms, before_attempt)
  end

  defp remove(path, deadline, retry_delay_ms, before_attempt) do
    before_attempt.(max(deadline - System.monotonic_time(:millisecond), 0))

    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, reason, failed} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if reason in @transient_reasons and remaining > 0 do
          Process.sleep(min(retry_delay_ms, remaining))
          remove(path, deadline, retry_delay_ms, before_attempt)
        else
          abandon(path, reason, failed)
        end
    end
  end

  # A genuine failure: say WHAT is left behind and raise `File.Error`, the same
  # exception `File.rm_rf!/1` would have raised (so a suite that only cares that
  # teardown failed keeps seeing the familiar error).
  defp abandon(path, reason, failed) do
    require Logger

    Logger.error(
      "EvoGit.TestSupport.FsCleanup: could not remove #{inspect(path)} " <>
        "(#{inspect(reason)} at #{inspect(failed)}); residual: " <>
        "#{inspect(Path.wildcard(Path.join(path, "**"), match_dot: true), limit: 40)}"
    )

    raise File.Error,
      reason: reason,
      path: failed,
      action: "remove files and directories recursively from"
  end
end
