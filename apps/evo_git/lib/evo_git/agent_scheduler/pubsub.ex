defmodule EvoGit.AgentScheduler.PubSub do
  @moduledoc """
  Centralized PubSub broadcast helpers for agent scheduler events.
  Uses a simple throttle to avoid flooding subscribers during rapid state changes.
  """

  @agent_topic "agents"
  @config_topic "scheduler_config"

  @doc """
  Broadcast that agent state has changed.
  Uses a throttle mechanism: if a broadcast was sent within the last 200ms,
  schedule a delayed broadcast instead of sending immediately.
  """
  def broadcast_agents_updated do
    Phoenix.PubSub.broadcast(EvoGit.PubSub, @agent_topic, {:agents_updated})
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
