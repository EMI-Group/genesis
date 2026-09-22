defmodule EvoGit.Store.RepoScope do
  @moduledoc """
  Scoped dynamic-repo binding for `EvoGit.Repo`.

  `EvoGit.Repo` resolves the caller's target instance through the
  PROCESS-DICTIONARY binding `EvoGit.Repo.put_dynamic_repo/1` /
  `get_dynamic_repo/0`. A process that never set the binding transparently
  addresses the canonical NAMED instance; a per-store UNNAMED dynamic instance
  (see `EvoGit.Store.Boot.start_dynamic/1`) has NO name, so its PID is the only
  way to address it — the binding is therefore the single routing surface for
  every `EvoGit.Repo.*` call made by a process working on a dynamic instance.

  The binding is sticky: once set it silently applies to every later repo call
  in that process. `with_repo/2` SCOPES it — bind to `pid`, run `fun`, and
  ALWAYS restore the previous binding afterwards (even when `fun` raises), so
  a helper that peeks at another instance can never leak its binding into the
  caller. This mirrors the set/try/after-restore pattern of
  `EvoGit.Store.Boot.run_migrations/1`.

  Nesting composes naturally: the inner `with_repo/2` restores the outer
  `with_repo/2`'s binding, so only the outermost call returns the process to
  its original state.

  Pure process-local helper — no GenServer, no I/O, no global state.
  """

  @doc """
  Runs `fun` with the caller's dynamic repo bound to `pid`, restoring the
  previous binding afterwards — even when `fun` raises or throws.

  Returns `fun`'s result unchanged.
  """
  @spec with_repo(pid(), (-> result)) :: result when result: var
  def with_repo(pid, fun) when is_pid(pid) and is_function(fun, 0) do
    previous = EvoGit.Repo.put_dynamic_repo(pid)

    try do
      fun.()
    after
      EvoGit.Repo.put_dynamic_repo(previous)
    end
  end
end
