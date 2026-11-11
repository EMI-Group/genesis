defmodule EvoDashWeb.ServerStatusController do
  @moduledoc """
  Unauthenticated local operator probe (`GET /server/status`).

  A sibling of `EvoDashWeb.HealthController`: the headless server CLI's
  self-updater calls it, and like `/health` it is mounted OUTSIDE every
  pipeline — no session, no CSRF token, no authentication and no HTML content
  negotiation, so a plain HTTP GET is all a caller needs.

  The CLI needs it because an upgrade is a stop→swap→start of the whole server:
  before touching a running instance the updater asks how much work is in
  flight and only proceeds when the server is idle. A wrong answer is therefore
  worse than no answer — reporting a zero while tasks are running would let the
  updater stop the server out from under them.

  Response: `200` with `application/json`,
  `{"status":"ok","version":"<evo_git vsn>","active_tasks":<integer>}`.

  `active_tasks` is the number of task ids in a live state (`:running`,
  `:pending`, `:cancelling`, `:finalizing`) and nothing else: this endpoint
  deliberately exposes ONLY that COUNT — never task ids, titles, objectives or
  repo paths. When the task read fails (raises, exits/times out, or returns a
  non-list) the value degrades to `-1`, which the CLI reads as "unknown" and
  handles with a warning rather than treating the server as idle.

  The BUSY set is exactly those four statuses, and `:awaiting_input` is
  deliberately EXCLUDED from it. `:awaiting_input` marks an idle interactive
  session waiting for the user, which holds no worker, no LLM slot, no tool slot
  and no timer, so winding such a session down during an upgrade is safe and
  expected rather than a loss of work. An idle session is therefore not busy,
  and it is never reported as an error or an unknown either: it simply does not
  contribute to `active_tasks`. `:finalizing` stays included because a task in
  that phase still owns its worktree and its merge-back work.
  """

  use EvoDashWeb, :controller

  alias EvoDash.SafeCall

  # The live-state ids are counted. `:finalizing` is included on purpose: a task
  # in that phase still owns its worktree and its merge-back work.
  #
  # `:awaiting_input` is deliberately EXCLUDED: it marks an idle interactive
  # session waiting for the user, which holds no worker, no LLM slot, no tool
  # slot and no timer, so winding it down during an upgrade is safe and
  # expected. An idle session is not busy, and it is never an error or an
  # unknown either — it simply does not contribute to the count.
  @active_statuses [:running, :pending, :cancelling, :finalizing]

  @doc """
  Renders the status document. Never raises: an unreadable app version degrades
  to `"unknown"` and a failed task read to `-1`.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, %{status: "ok", version: version(), active_tasks: active_tasks()})
  end

  # `Application.spec/2` returns `nil` for an app that is not loaded. The
  # version is read from `:evo_git` (NOT `:evo_dash`) because that is the
  # identity the headless server CLI reports and compares.
  defp version do
    case Application.spec(:evo_git, :vsn) do
      vsn when is_list(vsn) or is_binary(vsn) -> to_string(vsn)
      _other -> "unknown"
    end
  end

  # Resolved at call time so tests can inject a fake read (same seam style as
  # the `:task_export_*` runners).
  defp task_runner do
    Application.get_env(
      :evo_dash,
      :server_status_task_runner,
      fn -> EvoGit.TaskRegistry.list_task_ids(@active_statuses) end
    )
  end

  # `SafeCall.run/1` is the codebase's single exit-safe boundary: the registry
  # read is a `GenServer.call`, which EXITS (not raises) on a timeout or a dead
  # process, so a bare `rescue` would not cover it.
  #
  # Swallowing the failure is safe here ONLY because the degraded value is a
  # sentinel rather than a plausible count: the self-updater treats a negative
  # value as "unknown" and only WARNS instead of proceeding. A fallback of `0`
  # would be indistinguishable from an idle server and would let the updater
  # stop→swap→start the server while tasks are still running.
  defp active_tasks do
    runner = task_runner()

    case SafeCall.run(fn -> runner.() end) do
      {:ok, ids} when is_list(ids) -> length(ids)
      _failure -> -1
    end
  end
end
