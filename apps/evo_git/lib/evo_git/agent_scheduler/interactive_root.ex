defmodule EvoGit.AgentScheduler.InteractiveRoot do
  @moduledoc """
  The ONE definition of the interactive-root SESSION SHAPE.

  A dashboard `/assistant` conversation is a TASK-LESS interactive root:
  `EvoGit.AgentScheduler.start_session/1` mints a task id for it while the
  dashboard creates no `tasks` row, so no task-backed admission can apply.
  Two independent gates must agree on the shape that is legitimate anyway:

  - `EvoGit.Agent.Tools.ElixirEval.Authorization` admits `elixir_eval` for such
    a session instead of a task-backed identity; and
  - `EvoGit.CommandApproval.request_eval/5` admits the write/sudo approval
    request instead of denying it on the missing task row — otherwise the user
    never sees an approval dialog for an `/assistant` conversation.

  Both call the predicates below, so the shape is defined exactly once.

  ## Purity and failure isolation

  Every predicate here is a TOTAL read of the scheduler's ETS tables
  (`:evogit_sched_meta` / `:evogit_agent_summary`) in the CALLER — never a
  GenServer call and never inside the approval GenServer, which must stay
  answerable. A missing table, a missing row or a dying scheduler answers
  `false` instead of raising: tables are created by `EvoGit.Application` and
  can vanish during a scheduler restart, and `:ets` exits must never escape
  into admission logic.

  The double read of the SchedMeta row (`session_meta?/3` before and after the
  summary check) is deliberate: a session that ends or is recycled between the
  two reads is refused, exactly like the authorization gate's double read.
  """

  alias EvoGit.AgentScheduler.{AgentState, ControlPlane, SchedMeta}
  alias EvoGit.AgentSpec

  # SchedMeta statuses of a live interactive root: `:running` (an exchange is in
  # flight), `:blocked` (parked in a slot queue) and `:awaiting_input` (an idle
  # session between exchanges — no worker, no slot, no timer, but its session
  # process, worktree and transcript are alive, so inspecting and driving it is
  # legitimate). Defined once here and exposed for the admission tests.
  @accepted_statuses [:running, :blocked, :awaiting_input]

  @doc false
  # SchedMeta statuses accepted for a live interactive root session.
  @spec accepted_statuses() :: [atom()]
  def accepted_statuses, do: @accepted_statuses

  @doc false
  # Does this SchedMeta row have the interactive-root session shape?
  #
  # Everything is required — a depth-zero, parent-less root whose result was not
  # sent, in `:interactive` mode, carrying this very task id, owned by a LIVE
  # session pid (the expected owner when one is supplied), in an admitted
  # status, running the repo-less SelfReflective agent on the primary repo with
  # no foreign repo, phylo node or custom-agent identity — and the forwarded
  # opts must agree (repo-less, interactive, NO `:task_id` key at all, no
  # foreign or custom identity), so a forged or half-migrated row cannot borrow
  # this branch. `expected_owner` is a pid to pin the row's session, or `:any`
  # to check liveness only.
  @spec session_meta?(term(), String.t() | nil, pid() | :any) :: boolean()
  def session_meta?(meta, task_id, expected_owner \\ :any)

  def session_meta?(
        %SchedMeta{
          depth: 0,
          parent_id: nil,
          result_sent: false,
          mode: :interactive,
          task_id: task_id,
          session_pid: session_pid,
          status: status,
          spec: %AgentSpec{
            agent_module: EvoGit.Agents.SelfReflective,
            repo_id: "primary",
            foreign_repos: [],
            phylo_node: nil,
            opts: opts
          }
        },
        task_id,
        expected_owner
      )
      when is_binary(task_id) and task_id != "" and status in @accepted_statuses and
             is_list(opts) do
    Keyword.keyword?(opts) and Keyword.get(opts, :repo_less) == true and
      Keyword.get(opts, :session_mode) == :interactive and
      not Keyword.has_key?(opts, :task_id) and
      Keyword.get(opts, :foreign_repos, []) == [] and
      Keyword.get(opts, :custom_agent_id) == nil and
      Keyword.get(opts, :agent) == nil and
      is_pid(session_pid) and Process.alive?(session_pid) and
      owner_matches?(session_pid, expected_owner)
  end

  def session_meta?(_meta, _task_id, _expected_owner), do: false

  @doc false
  # Is `agent_id` the live interactive root session that owns `task_id`?
  #
  # Reads the scheduler tables directly (no registry call, no approval-service
  # round trip) and checks, in this order: a usable agent/task identity pair, ONE
  # exact SchedMeta row, the interactive-root shape for that very task id, the
  # summary row's primary/nil-parent/no-foreign-repos state with no cancellation
  # flag, then the SAME SchedMeta row and summary state again. Every failure,
  # race or missing table answers `false`. `expected_owner` is a pid to pin the
  # session, or `:any` to check liveness only.
  @spec live?(term(), String.t() | nil, pid() | :any) :: boolean()
  def live?(agent_id, task_id, expected_owner \\ :any) do
    try do
      is_integer(agent_id) and agent_id > 0 and is_binary(task_id) and task_id != "" and
        case :ets.lookup(:evogit_sched_meta, agent_id) do
          [{^agent_id, meta}] ->
            session_meta?(meta, task_id, expected_owner) and summary_admits?(agent_id) and
              :ets.lookup(:evogit_sched_meta, agent_id) == [{agent_id, meta}] and
              summary_admits?(agent_id)

          _missing_or_malformed ->
            false
        end
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  defp owner_matches?(_session_pid, :any), do: true
  defp owner_matches?(session_pid, expected_owner), do: session_pid == expected_owner

  # Project inside ETS: copy only the role/ownership fields of the summary row.
  # A missing row/field never grants access.
  #
  # The cancellation flag is read from the CONTROL PLANE (its single writer is
  # the scheduler's `Store.set_cancel_requested/1`); the summary row does not
  # carry the flag at all.
  defp summary_admits?(agent_id) do
    pattern =
      {agent_id,
       %{
         __struct__: AgentState,
         parent_id: nil,
         repo_id: "primary",
         foreign_repos: []
       }}

    match?({[true], _}, :ets.select(:evogit_agent_summary, [{pattern, [], [true]}], 1)) and
      not ControlPlane.cancel_requested?(agent_id)
  end
end
