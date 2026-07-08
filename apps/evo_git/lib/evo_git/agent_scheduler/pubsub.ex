defmodule EvoGit.AgentScheduler.PubSub do
  @moduledoc """
  Centralized PubSub broadcast helpers for agent scheduler events.

  Provides both a **throttled** bulk-update signal (`broadcast_agents_updated/0`)
  for backward compatibility, and **enriched delta broadcasts** that carry
  specific change data so subscribers (e.g. the dashboard) can apply incremental
  updates without re-reading entire ETS tables.
  """

  @throttle_ms 200
  @agent_topic "agents"
  @config_topic "scheduler_config"

  # ---------------------------------------------------------------------------
  # Throttle process (internal)
  # ---------------------------------------------------------------------------

  @doc """
  Starts the throttle process under a registered name.

  Called once at application startup. Until the process is started,
  `broadcast_agents_updated/0` degrades gracefully to an immediate broadcast.
  """
  def start_throttle do
    pid = spawn(fn -> throttle_loop(nil) end)
    Process.register(pid, __MODULE__.Throttle)
    :ok
  end

  defp throttle_loop(timer_ref) do
    receive do
      :flush ->
        Phoenix.PubSub.broadcast(EvoGit.PubSub, @agent_topic, {:agents_updated})
        throttle_loop(nil)

      :schedule ->
        if timer_ref, do: Process.cancel_timer(timer_ref)
        new_ref = Process.send_after(self(), :flush, @throttle_ms)
        throttle_loop(new_ref)
    end
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Broadcast that agent state has changed (throttled to every #{@throttle_ms}ms).

  Multiple rapid calls will collapse into a single broadcast. This is a
  backward-compatible fallback — new code should prefer
  `broadcast_agent_registered/2`, `broadcast_agent_updated/2`, and
  `broadcast_agent_removed/1` which carry delta data for incremental frontend
  updates.
  """
  @spec broadcast_agents_updated :: :ok
  def broadcast_agents_updated do
    case Process.whereis(__MODULE__.Throttle) do
      nil ->
        # No throttle process (tests, early startup) — broadcast immediately
        Phoenix.PubSub.broadcast(EvoGit.PubSub, @agent_topic, {:agents_updated})

      pid ->
        send(pid, :schedule)
    end

    :ok
  end

  @doc """
  Broadcast that a new agent has been registered with status `:pending`.

  `meta_summary` is a map with keys:
  - `:status` — always `:pending` for new agents
  - `:depth` — recursion depth
  - `:parent_id` — parent agent ID (or `nil` for top-level)
  - `:task_id` — task identifier string
  - `:task_number` — short integer task number
  - `:objective` — the agent's objective string (from spec)
  """
  @spec broadcast_agent_registered(pos_integer(), map()) :: :ok
  def broadcast_agent_registered(agent_id, meta_summary) do
    Phoenix.PubSub.broadcast(
      EvoGit.PubSub,
      @agent_topic,
      {:agent_registered, agent_id, meta_summary}
    )
  end

  @doc """
  Broadcast that an agent's state has changed, including *what* changed.

  `changed_fields` is a keyword list of field-value pairs, e.g.
  `[status: :running, turn: 5, usage: %Usage{...}]`.

  Subscribers can apply these as incremental patches without re-reading
  the full ETS tables.
  """
  @spec broadcast_agent_updated(pos_integer(), keyword()) :: :ok
  def broadcast_agent_updated(agent_id, changed_fields) do
    Phoenix.PubSub.broadcast(
      EvoGit.PubSub,
      @agent_topic,
      {:agent_updated, agent_id, changed_fields}
    )
  end

  @doc """
  Broadcast that an agent has been removed from the scheduler.

  Called when both the sched-meta and agent-state ETS rows are deleted.
  """
  @spec broadcast_agent_removed(pos_integer()) :: :ok
  def broadcast_agent_removed(agent_id) do
    Phoenix.PubSub.broadcast(EvoGit.PubSub, @agent_topic, {:agent_removed, agent_id})
  end

  @doc """
  Broadcast that scheduler config has changed (config update, pause, or resume).
  """
  def broadcast_config_updated do
    Phoenix.PubSub.broadcast(EvoGit.PubSub, @config_topic, {:scheduler_config_updated})
  end

  @doc "The agents topic name"
  def agent_topic, do: @agent_topic

  @doc "The config topic name"
  def config_topic, do: @config_topic
end
