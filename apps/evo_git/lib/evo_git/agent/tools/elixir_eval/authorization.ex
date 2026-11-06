defmodule EvoGit.Agent.Tools.ElixirEval.Authorization do
  @moduledoc """
  Fail-closed authorization for the local, built-in reflective assistant.
  Role flags in a fresh tool task are deliberately not consulted.
  Registry calls use a one-second deadline and never fetch full task history.
  The context always names the ORIGINAL tool and assistant owner. Trusted broker
  and guardian processes may revalidate that context, but must never replace its
  identities with their own; Broker.start requires the original tool as caller.
  """

  alias EvoGit.Agent.Tools.ElixirEval.Ancestry
  alias EvoGit.AgentScheduler.{AgentState, SchedMeta}
  alias EvoGit.AgentSpec

  @denied "Elixir evaluation requires a live root reflective assistant on the local node."
  @timeout 1_000

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
           %{id: ^task_id, type: :reflect, status: :running} <-
             GenServer.call(registry, {:get_task_lite, task_id}, @timeout),
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
           task_ref: %Task{pid: owner},
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
       when is_integer(id) and status in [:running, :blocked] and is_list(opts) do
    Keyword.keyword?(opts) and Keyword.get(opts, :repo_less) == true and
      Keyword.get(opts, :task_id) == task_id and
      Keyword.get(opts, :foreign_repos, []) == [] and
      Keyword.get(opts, :custom_agent_id) == nil and Keyword.get(opts, :agent) == nil
  end

  defp valid_agent?(_, _, _), do: false

  # Project inside ETS: do not copy the agent's conversation or generation
  # parameters just to check its role. A missing row/field never grants access.
  defp valid_state?(id) do
    pattern =
      {id,
       %{
         __struct__: AgentState,
         parent_id: nil,
         repo_id: "primary",
         foreign_repos: [],
         cancel_requested: :"$1"
       }}

    # The scheduler represents an unset/cleared cancellation flag as nil.
    guards = [{:orelse, {:"=:=", :"$1", false}, {:"=:=", :"$1", nil}}]
    match?({[true], _}, :ets.select(:evogit_agent_state, [{pattern, guards, [true]}], 1))
  end

  defp local_target?(target) when target in [nil, :current, :local, "current", "local"], do: true
  defp local_target?(target) when is_binary(target), do: target == Atom.to_string(node())
  defp local_target?(_), do: false
end
