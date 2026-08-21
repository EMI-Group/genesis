defmodule EvoDashWeb.SystemLive.SourceCard do
  @moduledoc """
  Genesis Source card support for `EvoDashWeb.SystemLive`.

  Mirrors the `update_card.ex` support-module pattern: the single-page
  LiveView stays lean while this module hosts the status/clone/update flows
  backed by the `EvoGit.SelfReflectiveSource` backend module. That module is
  built by a parallel workstream and may be absent at compile time, so every
  default runner is guarded with `Code.ensure_loaded?/1` and degrades
  gracefully to `{:unavailable, :module_missing}` when it is not compiled in.

  The card is local-only by design: a remote `genesis_remote` daemon's
  self-reflective agent reads the REMOTE host's filesystem, so clone/update
  must never act on a remote node (`visible?/1`).

  ## Runner seam contract

  Each spawn function resolves its runner from the application env INSIDE the
  spawned task (at spawn/execution time, never stored in LiveView assigns) so
  tests can stub it via `Application.put_env(:evo_dash, ...)`. Runners are
  1-arity functions receiving the node the request was spawned for (always the
  local node in practice — the card is local-only):

  - `:source_status_runner` — returns the raw status map (backend `status/0`
    shape: `%{dir:, exists:, is_git_repo:, valid:, commit:, branch:, version:,
    remote_url:, reference:, is_reference:}`) or `{:unavailable, reason}`.
  - `:source_clone_runner` / `:source_update_runner` — return
    `{:ok, status_map} | {:error, reason} | {:unavailable, reason}`.

  Every spawn rescues at the async boundary and reports
  `{:unavailable, :runner_error}` so a crashing runner can never wedge the
  card's loading/busy state.
  """

  @doc "Whether the Genesis Source card should render for the given node context."
  def visible?(node), do: node in [nil, node()]

  @doc """
  Spawns an async status load on `EvoDash.TaskSupervisor` and reports the
  result to `view_pid` as `{:source_status_loaded, seq, node, result}`.
  """
  def spawn_status_load(view_pid, seq, node) do
    runner = Application.get_env(:evo_dash, :source_status_runner) || (&default_status/1)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      try do
        result = runner.(node)
        send(view_pid, {:source_status_loaded, seq, node, result})
      rescue
        # A crashing runner must not wedge the loading state.
        _ -> send(view_pid, {:source_status_loaded, seq, node, {:unavailable, :runner_error}})
      end
    end)

    :ok
  end

  @doc """
  Spawns an async clone on `EvoDash.TaskSupervisor` and reports the result to
  `view_pid` as `{:source_clone_result, seq, node, result}`.
  """
  def spawn_clone(view_pid, seq, node) do
    runner = Application.get_env(:evo_dash, :source_clone_runner) || (&default_clone/1)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      try do
        result = runner.(node)
        send(view_pid, {:source_clone_result, seq, node, result})
      rescue
        # A crashing runner must not wedge the busy state.
        _ -> send(view_pid, {:source_clone_result, seq, node, {:unavailable, :runner_error}})
      end
    end)

    :ok
  end

  @doc """
  Spawns an async update on `EvoDash.TaskSupervisor` and reports the result to
  `view_pid` as `{:source_update_result, seq, node, result}`.
  """
  def spawn_update(view_pid, seq, node) do
    runner = Application.get_env(:evo_dash, :source_update_runner) || (&default_update/1)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      try do
        result = runner.(node)
        send(view_pid, {:source_update_result, seq, node, result})
      rescue
        # A crashing runner must not wedge the busy state.
        _ -> send(view_pid, {:source_update_result, seq, node, {:unavailable, :runner_error}})
      end
    end)

    :ok
  end

  # --- Default runners (guarded against the optionally-absent backend) ---

  # The `node` argument is ignored: `EvoGit.SelfReflectiveSource` acts on the
  # LOCAL filesystem and the card is local-only (`visible?/1`). The backend is
  # invoked via `apply/3` (not a direct call) so a build without the module
  # compiles warning-free — a direct call to a missing module's function emits
  # an "undefined function" compile warning even inside an ensure_loaded branch.
  defp default_status(_node) do
    if Code.ensure_loaded?(EvoGit.SelfReflectiveSource) do
      apply(EvoGit.SelfReflectiveSource, :status, [])
    else
      {:unavailable, :module_missing}
    end
  end

  defp default_clone(_node) do
    if Code.ensure_loaded?(EvoGit.SelfReflectiveSource) do
      apply(EvoGit.SelfReflectiveSource, :clone, [])
    else
      {:unavailable, :module_missing}
    end
  end

  defp default_update(_node) do
    if Code.ensure_loaded?(EvoGit.SelfReflectiveSource) do
      apply(EvoGit.SelfReflectiveSource, :update, [])
    else
      {:unavailable, :module_missing}
    end
  end
end
