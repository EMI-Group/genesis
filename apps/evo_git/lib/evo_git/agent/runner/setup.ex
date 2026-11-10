defmodule EvoGit.Agent.Runner.Setup do
  @moduledoc """
  The dispatch-context installation an agent's `run/2` performs BEFORE its first
  turn.

  This module is a THIN delegation: the implementation lives in
  `EvoGit.Agent.Session.Setup`, the ONE shared implementation used by both this
  Runner driver and the future `EvoGit.Agent.Session` process. The process
  dictionary it installs is a DERIVED projection of `%EvoGit.Agent.State{}`,
  never authoritative.

  `setup/1` installs the agent's identity on the process dictionary, provisions
  the agent's worktree (skipped entirely for a repo-less agent), applies the
  crash-retry sleep and resolves/installs the managed per-task scratch directory.
  `EvoGit.Agent.Runner.setup_dispatch_context/1` delegates here; the runtime
  state itself is built by `EvoGit.Agent.Runner.InitialState`.
  """

  @doc """
  Installs the dispatch context for THIS agent process.

  The `ctx` keyword list is the scheduler's `dispatch_ctx`: it drives process-dict
  initialization, worktree setup and retry handling before the agent loop.
  """
  def setup(ctx) do
    EvoGit.Agent.Session.Setup.bind_worktree(ctx, self())
    task_tmpdir = EvoGit.Agent.Session.Setup.ensure_tmpdir(ctx)
    EvoGit.Agent.Session.Setup.install_process_context(ctx, task_tmpdir, self())
  end
end
