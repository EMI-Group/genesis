defmodule EvoGit.Runtime.Assistant do
  @moduledoc """
  Interactive (repo-less) Assistant phase: ONE long-lived agent session that a
  caller drives message by message.

  This phase is used ONLY when a caller explicitly asks for an interactive
  session (`session_mode: "interactive"` in the task opts); nothing switches a
  task to it implicitly, and an explicit `"oneshot"` is rejected here.
  `EvoGit.Runtime.SelfReflective` remains the one-shot plain-reflect phase.

  ## Lifecycle

  1. Build the SAME repo-less spec `EvoGit.Runtime.SelfReflective.build_spec/2`
     builds — one source of truth for the source-root/context-tree chain — and
     force `session_mode: :interactive` on it.
  2. `EvoGit.AgentScheduler.start_session/1` returns the agent id WITHOUT
     blocking on the session. The id is the handle every later message and the
     close use (`send_session_message/3`, `close_session/1`).
  3. The phase awaits the session's CLOSE for the whole session lifetime
     (`EvoGit.AgentScheduler.await_close/2` with an explicit `:infinity`): an
     interactive session ends only when it is closed, gracefully cancelled or
     force killed — deliberately no idle timeout. The task wrapper's own
     cancellation path is what ends a session whose caller went away.
  4. A terminal `%EvoGit.Agent.Result{}` is reported EXACTLY ONCE:
     `notify_finalizing/1` (the same pre-finalization broadcast every other
     phase fires) followed by the repo-less `merge_and_report/3` — no branch, no
     merge — returning the same report shape `SelfReflective.run/2` returns.
     A start failure or a session that ends without a result returns the error
     verbatim and performs NO finalization.

  ## Sessions are in-memory only

  A session lives in the BEAM node that owns it: a restart loses it and the task
  fails (no transcript is persisted, no resume exists). Boot reconciliation marks
  the abandoned task failed.
  """

  alias EvoGit.Agent.Result
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.SessionOpts
  alias EvoGit.Runtime.Helpers
  alias EvoGit.Runtime.SelfReflective

  require Logger

  @doc """
  Runs an interactive Assistant session. Two entry arities:

    * `run(opts)` — opts keyword; objective read from `opts[:objective]` (default "")
    * `run(objective, opts)` — objective positional

  Blocks until the session closes, then returns
  `{:ok, %{result: ..., commit_sha: nil, branch_name: nil, tag: nil}}` (the
  repo-less report shape) or `{:error, reason}` — a start failure, an
  unsupported session mode, or the session's own error term.
  """
  def run(opts) when is_list(opts) do
    run(Keyword.get(opts, :objective, ""), opts)
  end

  def run(objective, opts) when is_binary(objective) and is_list(opts) do
    ensure_interactive!(opts)

    opts = Keyword.put_new(opts, :node_path, "./")
    task_id = Keyword.get(opts, :task_id)

    Logger.info(
      "Assistant: Starting interactive session for objective: #{objective} " <>
        "(node: #{opts[:node_path]}, task: #{inspect(task_id)})"
    )

    spec = objective |> SelfReflective.build_spec(opts) |> interactive_spec()

    case AgentScheduler.start_session(spec) do
      {:ok, agent_id} ->
        Logger.info("Assistant: Session #{agent_id} started (task #{inspect(task_id)})")
        finalize(agent_id, task_id)

      {:error, reason} = error ->
        Logger.error("Assistant: failed to start an interactive session: #{inspect(reason)}")
        error
    end
  end

  # --- spec ---

  # The repo-less spec plus the ONE session-only opt. It is put AFTER
  # `build_spec/2` so it always wins over a caller value: this phase is the
  # interactive one.
  defp interactive_spec(spec) do
    %{spec | opts: Keyword.put(spec.opts || [], :session_mode, :interactive)}
  end

  # An explicit non-interactive mode belongs to the one-shot phase; anything
  # else (absent, or "interactive") is this phase's own business.
  defp ensure_interactive!(opts) do
    case SessionOpts.fetch_session_mode(opts) do
      {:ok, :oneshot} ->
        raise ArgumentError,
              "EvoGit.Runtime.Assistant is the interactive phase: " <>
                "session_mode \"oneshot\" belongs to EvoGit.Runtime.SelfReflective " <>
                "(pass session_mode: \"interactive\" or omit it)"

      _other ->
        :ok
    end
  end

  # --- await + finalize ---

  defp finalize(agent_id, task_id) do
    case AgentScheduler.await_close(agent_id, :infinity) do
      {:ok, %Result{} = result} ->
        # Same order as every other phase: the broadcast fires once, then the
        # finalization step runs once.
        Helpers.notify_finalizing(task_id)
        Helpers.merge_and_report(nil, result, "assistant")

      {:ok, other} ->
        Logger.error("Assistant: session #{agent_id} returned a non-result: #{inspect(other)}")
        {:error, {:unexpected_session_result, other}}

      {:error, reason} = error ->
        Logger.error("Assistant: session #{agent_id} ended without a result: #{inspect(reason)}")
        error
    end
  end
end
