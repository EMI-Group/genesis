defmodule EvoDashWeb.AgentsLive.HistoryGate do
  @moduledoc """
  Pure history-fetch gating for the Agents page.

  `RemoteAPI.list_agents/0` summaries carry a `:message_count` field (the
  number of messages in the agent's session-memory context). The Agents page
  uses it to avoid re-transferring full agent message histories over the
  node boundary when nothing changed: an agent needs a `get_agent_history`
  fetch only when its last-seen message count differs from the fresh summary
  count (a nil last-seen entry = brand-new agent = must fetch).

  The gate state is a plain `%{agent_id => message_count}` map stored in the
  `:history_gate` socket assign (seeded `%{}` in mount, reset on node switch —
  agent ids are per-node). A gate entry therefore ALSO means "the gate already
  observed this agent on the CURRENT node": the gate's absence distinguishes a
  brand-new agent — or a leftover row from a PREVIOUS node — from an agent the
  gate already knows (see `known?/2`).
  """

  @doc """
  Whether the agent needs a fresh history fetch given the last-seen counts.

  `last_seen[agent_id]` is the message count the last fetched history
  corresponded to. A nil entry means we have never fetched this agent's
  history (must fetch); a count mismatch means the conversation grew since
  the last fetch (must fetch); an equal count means the history we already
  have is current (no fetch — the payload fix).
  """
  @spec need_fetch?(map(), integer(), integer() | nil) :: boolean()
  def need_fetch?(last_seen, agent_id, message_count) do
    Map.get(last_seen, agent_id) != message_count
  end

  @doc """
  Whether the gate already knows this agent on the CURRENT node.

  A `true` result means the gate holds an entry for `agent_id` (the agent was
  observed on the current node — an entry is written by `record/3` once a
  history fetch lands); `false` means either a brand-new agent, or a leftover
  row from a PREVIOUS node. The gate is reset on a node switch while the
  mounted `@agents` list is deliberately kept, and agent ids are per-node, so
  a same-id row from the previous node must not be mistaken for a same-node
  one. Used by `AgentsLive.apply_agents_result/2` to carry already-fetched
  history over ONLY for same-node agents, so cross-node agent ids never leak
  another node's history.
  """
  @spec known?(map(), integer()) :: boolean()
  def known?(last_seen, agent_id), do: Map.has_key?(last_seen, agent_id)

  @doc """
  Records the message count a fetched history corresponds to.

  Returns the updated last-seen map. The count should be the agent's
  message_count from the most recent `list_agents` summary — the history
  stored in the agents list then corresponds to that count, and the poll
  will not re-fetch it while the count is unchanged.
  """
  @spec record(map(), integer(), integer() | nil) :: map()
  def record(last_seen, agent_id, message_count) do
    Map.put(last_seen, agent_id, message_count)
  end
end
