defmodule EvoGit.AgentScheduler.RemoteAPI do
  @moduledoc """
  RPC-accessible read-only API over scheduler ETS state.

  This module exposes pure functions that read the scheduler's global ETS
  tables (`:evogit_sched_meta` and `:evogit_agent_state`) and return
  **native Elixir terms** (atoms, structs, maps, lists, tuples). It is
  designed to be invoked from a local dashboard process via
  `:erpc.call(remote_node, EvoGit.AgentScheduler.RemoteAPI, function, args)`.

  ## Native term transfer via :erpc

  The `:erpc.call/5` mechanism used for cross-node RPC transfers all native
  BEAM terms (atoms, structs, maps, lists, tuples, PIDs) natively across
  Erlang distribution. There is no JSON/HTTP serialization boundary, so no
  conversion to "plain maps" is needed. Module atoms, `%Usage{}` structs,
  `ReqLLM.Message` structs, and `%ValidationError{}` structs are all
  transferred as-is. **No serialization safety conversion is performed.**

  ## Non-crashing access pattern

  ETS table reads are guarded with `:ets.whereis/1` (returns `:undefined`
  before the scheduler has started). No `try/rescue` blocks are used.
  """

  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Returns a list of agent summary maps.

  Joins `:evogit_sched_meta` (master list) with `:evogit_agent_state` on
  `agent_id`. Each map contains native Elixir terms:

    * `:id` — agent ID (integer)
    * `:task_local_id` — per-task agent number (integer | nil)
    * `:repo_id` — repo identifier string (`"primary"` or a foreign id)
    * `:status` — `:pending | :running | :waiting | :ready | :blocked`
    * `:depth` — recursion depth (integer)
    * `:parent_id` — parent agent ID (integer | nil)
    * `:usage` — `%Usage{}` struct (native)
    * `:total_tokens` — cumulative tokens since last compression (integer)
    * `:compression_count` — context compression count (integer)
    * `:objective` — the agent's objective string
    * `:result` — `nil` (no clean source in sched_meta)
    * `:agent_module` — module atom (e.g. `EvoGit.Agents.Manager`)
    * `:started_at` — `nil` (no direct field)
    * `:model_id` — model profile id string

  Returns `[]` when no agents are registered or the ETS tables don't exist yet.
  """
  @spec list_agents() :: [map()]
  def list_agents do
    sched_metas = read_table(:evogit_sched_meta)
    agent_states = read_table(:evogit_agent_state)

    states_by_id = Map.new(agent_states, fn {id, state} -> {id, state} end)

    Enum.map(sched_metas, fn {id, meta} ->
      build_agent_summary(id, meta, Map.get(states_by_id, id))
    end)
  end

  @doc """
  Returns the conversation history for an agent as a list of native
  `ReqLLM.Message` structs.

  Because `:erpc.call/5` transfers all BEAM terms natively, the messages
  are returned directly without any conversion.

  Returns `[]` if the agent has no context yet or doesn't exist.
  """
  @spec get_agent_history(agent_id :: pos_integer()) :: [ReqLLM.Message.t()]
  def get_agent_history(agent_id) do
    case lookup_agent_state(agent_id) do
      nil ->
        []

      %AgentState{context: nil} ->
        []

      %AgentState{context: %ReqLLM.Context{messages: messages}} ->
        messages
    end
  end

  @doc """
  Returns the native `%AgentState{}` struct for the given id.

  The `:context` field is dropped (it can be large — use
  `get_agent_history/1` for conversation access). All other fields are kept
  as native structs.

  Returns `nil` if the agent doesn't exist.
  """
  @spec get_agent_state(agent_id :: pos_integer()) :: AgentState.t() | nil
  def get_agent_state(agent_id) do
    case lookup_agent_state(agent_id) do
      nil -> nil
      %AgentState{} = state -> %{state | context: nil}
    end
  end

  @doc """
  Returns the current resolved scheduler configuration as a map.

  Delegates to `EvoGit.AgentScheduler.get_config/0` (a `GenServer.call`).
  Called on the remote node, so the result is already local to that node.
  """
  @spec get_config() :: map()
  def get_config do
    EvoGit.AgentScheduler.get_config()
  end

  @doc """
  Returns the config health status.

  Delegates to `EvoGit.Config.config_status/0` and returns it directly.
  The `:validation_errors` field contains `%ValidationError{}` structs,
  which are transferred natively via `:erpc.call/5`.

  The returned map has:
    * `:missing` — list of missing config keys (atoms)
    * `:warnings` — list of human-readable warning strings
    * `:ok?` — boolean
    * `:validation_errors` — list of `%ValidationError{}` structs
  """
  @spec get_config_status() :: map()
  def get_config_status do
    EvoGit.Config.config_status()
  end

  @doc """
  Returns `true` if the scheduler is paused, `false` otherwise.

  Delegates to `EvoGit.AgentScheduler.paused?/0` (a `GenServer.call`).
  """
  @spec paused?() :: boolean()
  def paused? do
    EvoGit.AgentScheduler.paused?()
  end

  # ── Private: ETS access ────────────────────────────────────────────

  # Reads all `{key, value}` pairs from a named ETS table.
  # Returns `[]` when the table doesn't exist yet (e.g. before scheduler start).
  defp read_table(name) do
    case :ets.whereis(name) do
      :undefined -> []
      _ -> :ets.tab2list(name)
    end
  end

  # Looks up a single agent state by id.
  # Returns `%AgentState{}` or `nil` (table missing or key not found).
  defp lookup_agent_state(agent_id) do
    case :ets.whereis(:evogit_agent_state) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(:evogit_agent_state, agent_id) do
          [{^agent_id, state}] -> state
          [] -> nil
        end
    end
  end

  # ── Private: agent summary builder ─────────────────────────────────

  defp build_agent_summary(id, %SchedMeta{} = meta, nil) do
    # Agent registered in sched_meta but not yet dispatched (no agent_state).
    %{
      id: id,
      task_local_id: nil,
      repo_id: nil,
      status: meta.status,
      depth: meta.depth,
      parent_id: meta.parent_id,
      usage: Usage.zero(),
      total_tokens: 0,
      compression_count: 0,
      objective: meta.spec.objective,
      result: nil,
      agent_module: meta.spec.agent_module,
      started_at: nil,
      model_id: nil
    }
  end

  defp build_agent_summary(id, %SchedMeta{} = meta, %AgentState{} = state) do
    usage = state.usage || Usage.zero()
    objective = state.objective || meta.spec.objective

    %{
      id: id,
      task_local_id: state.task_local_id,
      repo_id: state.repo_id,
      status: meta.status,
      depth: meta.depth,
      parent_id: meta.parent_id,
      usage: usage,
      total_tokens: state.total_tokens,
      compression_count: state.compression_count,
      objective: objective,
      result: nil,
      agent_module: meta.spec.agent_module,
      started_at: nil,
      model_id: state.model_id
    }
  end
end
