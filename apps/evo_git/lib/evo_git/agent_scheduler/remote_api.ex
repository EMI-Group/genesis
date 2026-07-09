defmodule EvoGit.AgentScheduler.RemoteAPI do
  @moduledoc """
  RPC-accessible read-only API over scheduler ETS state.

  This module exposes pure functions that read the scheduler's global ETS
  tables (`:evogit_sched_meta` and `:evogit_agent_state`) and return
  **serialization-safe** plain maps, lists, and scalars. It is designed to be
  invoked from a local dashboard process via
  `:erpc.call(remote_node, EvoGit.AgentScheduler.RemoteAPI, function, args)`.

  ## Serialization safety

  All return values are plain maps/lists/scalars — NO struct references, NO
  PIDs, and NO atoms that don't exist on the calling node. Structs are
  converted to plain maps via `Map.from_struct/1`, module references are
  stringified via `inspect/1`, and non-serializable fields (e.g. `:context`,
  GenServer `from` destinations, `%Task{}` refs) are dropped.

  ## Non-crashing access pattern

  ETS table reads are guarded with `:ets.whereis/1` (returns `:undefined`
  before the scheduler has started). No `try/rescue` blocks are used.
  """

  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Returns a serializable list of agent summary maps.

  Joins `:evogit_sched_meta` (master list) with `:evogit_agent_state` on
  `agent_id`. Each map contains plain values safe for cross-node RPC:

    * `:id` — agent ID (integer)
    * `:task_local_id` — per-task agent number (integer | nil)
    * `:repo_id` — repo identifier string (`"primary"` or a foreign id)
    * `:status` — `:pending | :running | :waiting | :ready | :blocked`
    * `:depth` — recursion depth (integer)
    * `:parent_id` — parent agent ID (integer | nil)
    * `:usage` — plain map of token/cost usage (never a struct)
    * `:total_tokens` — cumulative tokens since last compression (integer)
    * `:compression_count` — context compression count (integer)
    * `:objective` — the agent's objective string
    * `:result` — `nil` (no clean source in sched_meta)
    * `:agent_module` — module name as a string (e.g. `"EvoGit.Agents.Manager"`)
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
  Returns the conversation history for an agent as a list of plain message
  maps.

  Each message map contains:

    * `:role` — string (`"user"`, `"assistant"`, `"system"`, `"tool"`)
    * `:content_summary` — joined text of all non-nil ContentPart text fields
    * `:tool_calls` — list of plain `%{id, name, arguments}` maps, or `nil`
    * `:turn` — turn number from message metadata, or `nil`

  Returns `[]` if the agent has no context yet or doesn't exist.
  """
  @spec get_agent_history(agent_id :: pos_integer()) :: [map()]
  def get_agent_history(agent_id) do
    case lookup_agent_state(agent_id) do
      nil ->
        []

      %AgentState{context: nil} ->
        []

      %AgentState{context: %ReqLLM.Context{messages: messages}} ->
        Enum.map(messages, &message_to_map/1)
    end
  end

  @doc """
  Returns a plain-map snapshot of the full agent state for the given id.

  The `:context` field is stripped (it contains non-serializable ReqLLM
  structs — use `get_agent_history/1` for conversation access). The `:usage`
  field is converted to a plain map. Struct fields (`:context_node`,
  `:phylo_node`, `:foreign_repos`) are converted to plain maps.

  Returns `nil` if the agent doesn't exist.
  """
  @spec get_agent_state(agent_id :: pos_integer()) :: map() | nil
  def get_agent_state(agent_id) do
    case lookup_agent_state(agent_id) do
      nil -> nil
      %AgentState{} = state -> state_to_map(state)
    end
  end

  @doc """
  Returns the current resolved scheduler configuration as a plain map.

  Delegates to `EvoGit.AgentScheduler.get_config/0` (a `GenServer.call`).
  Called on the remote node, so the result is already local to that node.
  """
  @spec get_config() :: map()
  def get_config do
    EvoGit.AgentScheduler.get_config()
  end

  @doc """
  Returns the config health status as a plain map.

  Delegates to `EvoGit.Config.config_status/0` and converts
  `:validation_errors` (which contain `%ValidationError{}` structs) into
  plain maps so they are safe to serialize cross-node.

  The returned map has:
    * `:missing` — list of missing config keys (atoms)
    * `:warnings` — list of human-readable warning strings
    * `:ok?` — boolean
    * `:validation_errors` — list of plain maps
  """
  @spec get_config_status() :: map()
  def get_config_status do
    status = EvoGit.Config.config_status()

    %{status | validation_errors: convert_validation_errors(status.validation_errors)}
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
      usage: Map.from_struct(Usage.zero()),
      total_tokens: 0,
      compression_count: 0,
      objective: meta.spec.objective,
      result: nil,
      agent_module: inspect(meta.spec.agent_module),
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
      usage: Map.from_struct(usage),
      total_tokens: state.total_tokens,
      compression_count: state.compression_count,
      objective: objective,
      result: nil,
      agent_module: inspect(meta.spec.agent_module),
      started_at: nil,
      model_id: state.model_id
    }
  end

  # ── Private: message conversion ────────────────────────────────────

  defp message_to_map(%ReqLLM.Message{} = msg) do
    %{
      role: Atom.to_string(msg.role),
      content_summary: summarize_content(msg.content),
      tool_calls: convert_tool_calls(msg.tool_calls),
      turn: get_turn(msg.metadata)
    }
  end

  defp summarize_content(content) when is_list(content) do
    content
    |> Enum.map(fn part -> Map.get(part, :text) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp summarize_content(_), do: ""

  defp get_turn(metadata) when is_map(metadata) do
    Map.get(metadata, :turn) || Map.get(metadata, "turn")
  end

  defp get_turn(_), do: nil

  defp convert_tool_calls(nil), do: nil

  defp convert_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, &convert_tool_call/1)
  end

  defp convert_tool_call(%ReqLLM.ToolCall{} = tc) do
    ReqLLM.ToolCall.to_map(tc)
  end

  defp convert_tool_call(%{} = map) when not is_struct(map) do
    ReqLLM.ToolCall.from_map(map)
  end

  defp convert_tool_call(other), do: inspect(other)

  # ── Private: agent state conversion ────────────────────────────────

  defp state_to_map(%AgentState{} = state) do
    usage = state.usage || Usage.zero()

    state
    |> Map.from_struct()
    |> Map.drop([:context])
    |> Map.put(:usage, Map.from_struct(usage))
    |> Map.put(:foreign_repos, Enum.map(state.foreign_repos, &Map.from_struct/1))
    |> Map.put(:llm_generation_params, convert_keyword(state.llm_generation_params))
    |> maybe_convert_struct_field(:llm_model)
    |> maybe_convert_struct_field(:context_node)
    |> maybe_convert_struct_field(:phylo_node)
  end

  defp convert_keyword(keyword) when is_list(keyword) do
    if Keyword.keyword?(keyword) do
      Map.new(keyword)
    else
      keyword
    end
  end

  defp convert_keyword(other), do: other

  # Converts a struct value in the map to a plain map. Leaves nil/primitives
  # untouched.
  defp maybe_convert_struct_field(map, key) do
    case Map.get(map, key) do
      value when is_struct(value) -> Map.put(map, key, Map.from_struct(value))
      _ -> map
    end
  end

  # ── Private: config status conversion ──────────────────────────────

  defp convert_validation_errors(errors) when is_list(errors) do
    Enum.map(errors, fn
      value when is_struct(value) -> Map.from_struct(value)
      other -> other
    end)
  end

  defp convert_validation_errors(other), do: other
end
