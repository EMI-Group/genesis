defmodule EvoGit.Agent.Tools.ElixirEval.Authorization do
  @moduledoc """
  Fail-closed authorization for the local, built-in reflective assistant.
  Role flags in a fresh tool task are deliberately not consulted.
  Registry calls use a one-second deadline and never fetch full task history.
  The context always names the ORIGINAL tool and assistant owner. Trusted broker
  and guardian processes may revalidate that context, but must never replace its
  identities with their own; Broker.start requires the original tool as caller.
  The owning reflective task row is required only when the session carries a
  task id; a task-less interactive root session is admitted by its scheduler
  identity shape alone.
  """

  alias EvoGit.Agent.Tools.ElixirEval.Ancestry
  alias EvoGit.AgentScheduler.{AgentState, SchedMeta}
  alias EvoGit.AgentSpec

  @denied "Elixir evaluation requires a live root reflective assistant on the local node."
  @timeout 1_000

  # SchedMeta statuses of a live assistant agent: `:running` (an exchange is in
  # flight), `:blocked` (parked in a slot queue) and `:awaiting_input` (an idle
  # INTERACTIVE session between exchanges — no worker, no slot, no timer, but
  # its session process, worktree and transcript are alive, so inspecting and
  # driving it is legitimate). Defined once and exposed for the table-driven
  # status-admission test.
  @accepted_agent_statuses [:running, :blocked, :awaiting_input]

  # Statuses of the OWNING task row: `:blocked` is agent-side only, so the task
  # is `:running` while the assistant works and `:awaiting_input` while its
  # interactive session idles between exchanges.
  @accepted_agent_task_statuses [:running, :awaiting_input]

  @doc false
  # SchedMeta statuses accepted for the assistant agent (see the comment above).
  def accepted_agent_statuses, do: @accepted_agent_statuses

  @doc false
  # Statuses accepted for the assistant's owning `:reflect` task row.
  def accepted_agent_task_statuses, do: @accepted_agent_task_statuses

  def authorize(target_node \\ nil) do
    context = %{
      agent_id: Process.get(:evogit_agent_id),
      task_id: Process.get(:evogit_task_id),
      owner_pid: Process.get(:evogit_agent_pid),
      tool_pid: self(),
      target_node: node(),
      registry: EvoGit.TaskRegistry.server()
    }

    with true <- local_target?(target_node),
         true <- Ancestry.includes?(self(), context.owner_pid),
         :ok <- revalidate(context) do
      {:ok, context}
    else
      _ -> {:error, @denied}
    end
  end

  def assistant_owner?, do: match?({:ok, _}, authorize())

  def revalidate(%{
        agent_id: id,
        task_id: task_id,
        owner_pid: owner,
        tool_pid: tool,
        target_node: target,
        registry: registry
      })
      when is_integer(id) and id > 0 and is_binary(task_id) and task_id != "" and
             is_pid(owner) and is_pid(tool) do
    # Central security boundary: ETS can disappear during scheduler restart and
    # GenServer.call exits on timeout/down. Never expose exception terms here.
    try do
      with true <- target == node() and node(owner) == node() and node(tool) == node(),
           true <- Process.alive?(owner) and Process.alive?(tool),
           true <- Ancestry.includes?(tool, owner),
           true <- is_pid(Process.whereis(EvoGit.AgentScheduler)),
           [{^id, %SchedMeta{id: ^id} = meta}] <- :ets.lookup(:evogit_sched_meta, id),
           true <- valid_state?(id),
           true <- valid_agent?(meta, owner, task_id),
           %{id: ^task_id, type: :reflect, status: task_status} <-
             GenServer.call(registry, {:get_task_lite, task_id}, @timeout),
           true <- task_status in @accepted_agent_task_statuses,
           true <- Process.alive?(owner) and Process.alive?(tool),
           [{^id, ^meta}] <- :ets.lookup(:evogit_sched_meta, id),
           true <- valid_state?(id) do
        :ok
      else
        _ -> {:error, @denied}
      end
    rescue
      _ -> {:error, @denied}
    catch
      :exit, _ -> {:error, @denied}
    end
  end

  # Dashboard `/assistant` conversations are started as INTERACTIVE ROOT
  # SESSIONS with no `:task_id` (`EvoDashWeb.HomeLive` → `start_session/1`), so
  # they own no `:reflect` task row and there is nothing to look up in the task
  # registry. Admit exactly that shape, and no looser one: the checks below stay
  # as strict as the task-backed clause (same process ancestry/liveness, same
  # single SchedMeta row, same primary/nil-parent/no-foreign-repos summary state
  # with no cancellation flag), while `valid_task_less_agent?/2` pins the spec
  # to a depth-zero, parent-less, repo-less SelfReflective root in `:interactive`
  # mode with no task, foreign-repo or custom-agent identity in its opts. Any
  # other shape still falls through to the catch-all refusal below.
  def revalidate(%{
        agent_id: id,
        task_id: nil,
        owner_pid: owner,
        tool_pid: tool,
        target_node: target
      })
      when is_integer(id) and id > 0 and is_pid(owner) and is_pid(tool) do
    # Central security boundary: ETS can disappear during scheduler restart and
    # GenServer.call exits on timeout/down. Never expose exception terms here.
    try do
      with true <- target == node() and node(owner) == node() and node(tool) == node(),
           true <- Process.alive?(owner) and Process.alive?(tool),
           true <- Ancestry.includes?(tool, owner),
           true <- is_pid(Process.whereis(EvoGit.AgentScheduler)),
           [{^id, %SchedMeta{id: ^id} = meta}] <- :ets.lookup(:evogit_sched_meta, id),
           true <- valid_state?(id),
           true <- valid_task_less_agent?(meta, owner),
           true <- Process.alive?(owner) and Process.alive?(tool),
           [{^id, ^meta}] <- :ets.lookup(:evogit_sched_meta, id),
           true <- valid_state?(id) do
        :ok
      else
        _ -> {:error, @denied}
      end
    rescue
      _ -> {:error, @denied}
    catch
      :exit, _ -> {:error, @denied}
    end
  end

  def revalidate(_), do: {:error, @denied}

  defp valid_agent?(
         %SchedMeta{
           id: id,
           depth: 0,
           parent_id: nil,
           task_id: task_id,
           session_pid: owner,
           status: status,
           result_sent: false,
           spec: %AgentSpec{
             agent_module: EvoGit.Agents.SelfReflective,
             repo_id: "primary",
             foreign_repos: [],
             phylo_node: nil,
             opts: opts
           }
         },
         owner,
         task_id
       )
       when is_integer(id) and status in @accepted_agent_statuses and is_list(opts) do
    Keyword.keyword?(opts) and Keyword.get(opts, :repo_less) == true and
      Keyword.get(opts, :task_id) == task_id and
      Keyword.get(opts, :foreign_repos, []) == [] and
      Keyword.get(opts, :custom_agent_id) == nil and Keyword.get(opts, :agent) == nil
  end

  defp valid_agent?(_, _, _), do: false

  # Task-less admission, for the dashboard `/assistant` interactive root session
  # described above: an owning `:reflect` task row is required only when the
  # session HAS a task id, so this predicate carries the whole identity check.
  # Everything is required — a depth-zero, parent-less root whose result was not
  # sent, in `:interactive` mode with no task id, owned by this session pid, in
  # an admitted status, running the repo-less SelfReflective agent on the primary
  # repo with no foreign repo, phylo node or custom-agent identity — and the
  # forwarded opts must agree (repo-less, interactive, no task/foreign/custom
  # identity), so a forged or half-migrated row cannot borrow this branch.
  defp valid_task_less_agent?(
         %SchedMeta{
           depth: 0,
           parent_id: nil,
           result_sent: false,
           mode: :interactive,
           task_id: nil,
           session_pid: owner,
           status: status,
           spec: %AgentSpec{
             agent_module: EvoGit.Agents.SelfReflective,
             repo_id: "primary",
             foreign_repos: [],
             phylo_node: nil,
             opts: opts
           }
         },
         owner
       )
       when status in @accepted_agent_statuses and is_list(opts) do
    Keyword.keyword?(opts) and Keyword.get(opts, :repo_less) == true and
      Keyword.get(opts, :session_mode) == :interactive and
      Keyword.get(opts, :task_id) == nil and
      Keyword.get(opts, :foreign_repos, []) == [] and
      Keyword.get(opts, :custom_agent_id) == nil and Keyword.get(opts, :agent) == nil
  end

  defp valid_task_less_agent?(_, _), do: false

  # Project inside ETS: copy only the role/ownership fields of the summary row.
  # A missing row/field never grants access.
  #
  # The cancellation flag is read from the CONTROL PLANE (its single writer is
  # the scheduler's `Store.set_cancel_requested/1`); the summary row does not
  # carry the flag at all.
  defp valid_state?(id) do
    pattern =
      {id,
       %{
         __struct__: AgentState,
         parent_id: nil,
         repo_id: "primary",
         foreign_repos: []
       }}

    match?({[true], _}, :ets.select(:evogit_agent_summary, [{pattern, [], [true]}], 1)) and
      not EvoGit.AgentScheduler.ControlPlane.cancel_requested?(id)
  end

  defp local_target?(target) when target in [nil, :current, :local, "current", "local"], do: true
  defp local_target?(target) when is_binary(target), do: target == Atom.to_string(node())
  defp local_target?(_), do: false
end
