defmodule EvoDashWeb.AgentsLive.LoadData do
  @moduledoc """
  Data loading for the Agents page, extracted so it can run inside async
  tasks.

  All functions here are called from Task.Supervisor children spawned by
  `EvoDashWeb.AgentsLive` — never from the LiveView process — so cross-node
  RPCs (`:erpc` to a remote `genesis_remote` daemon, or local ETS-backed
  RemoteAPI reads) never block the page. `list_agents/1` and the threshold
  fetch use env seams (`:agents_list_runner` / `:agents_config_runner`)
  resolved at call time so tests can inject fakes.
  """

  alias EvoDashWeb.AgentsLive.ThresholdCache

  @doc """
  Full page load: agent summaries + the node's config status (layout banner)
  + a refreshed threshold cache. Returns `{:ok, %{agents:, config_status:,
  threshold_cache:}}` — the task caller wraps this in a node-boundary
  try/rescue (see `AgentsLive.start_async_load/1`).
  """
  @spec load(atom(), nil | tuple()) ::
          {:ok, %{agents: [map()], config_status: term(), threshold_cache: tuple()}}
  def load(node, threshold_cache) do
    now = System.monotonic_time(:millisecond)
    {threshold, threshold_cache} = ThresholdCache.fetch(node, threshold_cache, now)
    agents = build_agents(list_agents(node), threshold)
    config_status = node_config_status(node)

    {:ok, %{agents: agents, config_status: config_status, threshold_cache: threshold_cache}}
  end

  @doc """
  Lightweight refresh (poll / broadcast path): agent summaries + a refreshed
  threshold cache, no config_status (the layout banner is only loaded by the
  page-load path). Returns `{agents, threshold_cache}` — the task caller wraps
  this in a node-boundary try/rescue (see `AgentsLive.spawn_agents_refresh/1`).
  """
  @spec refresh(atom(), nil | tuple()) :: {[map()], tuple()}
  def refresh(node, threshold_cache) do
    now = System.monotonic_time(:millisecond)
    {threshold, threshold_cache} = ThresholdCache.fetch(node, threshold_cache, now)
    {build_agents(list_agents(node), threshold), threshold_cache}
  end

  @doc """
  Children of `parent_id` as `{agent_id, status}` pairs, sorted by id. Used to
  populate the `children`/`has_children` fields of agent maps (public so
  `AgentsLive`'s in-memory incremental paths reuse it).
  """
  @spec find_children_from_agents(integer() | nil, [map()]) :: [{integer(), atom()}]
  def find_children_from_agents(parent_id, agents) do
    agents
    |> Enum.filter(fn a -> a.parent_id == parent_id end)
    |> Enum.map(fn a -> {a.id, a.status} end)
    |> Enum.sort_by(fn {id, _} -> id end)
  end

  # Loads all agents for the given node. Reads scheduler state via
  # `EvoDash.NodeContext.list_agents/1`, which returns summary maps. On the
  # local node this reads the local ETS-backed RemoteAPI directly (no :erpc);
  # on a remote node it routes through :erpc.call/5, which transfers native
  # Elixir terms (atoms, structs) directly — no serialization boundary.
  #
  # The RPC summaries provide the fields the rendering code expects, including
  # the agent metadata fields (repo_root, context_path, current_commit,
  # base_commit, worktree, task_id, task_number, retries) which are now exposed
  # by the RemoteAPI summary layer. Fields not in the summary are read via
  # bracket access (summary[:field]) so they default to nil gracefully.
  defp list_agents(node) do
    runner =
      Application.get_env(:evo_dash, :agents_list_runner, &EvoDash.NodeContext.list_agents/1)

    runner.(node)
  end

  # Builds the rich agent maps the template consumes from the RPC summaries.
  # `message_count` is carried through from the summary (`RemoteAPI.list_agents`
  # provides it) — the history gate uses it to decide whether a
  # `get_agent_history` fetch is needed, so the poll never re-transfers
  # unchanged histories.
  defp build_agents(summaries, compression_threshold) do
    # Minimal {id, parent_id, status} list used for children computation.
    parent_lookup = summaries_to_agents(summaries)

    summaries
    |> Enum.map(fn summary ->
      total_tokens = summary[:total_tokens] || 0
      compression_count = summary[:compression_count] || 0

      compression_pct =
        trunc(min(total_tokens / max(compression_threshold, 1) * 100, 100))

      %{
        id: summary[:id],
        task_local_id: summary[:task_local_id],
        repo_id: summary[:repo_id] || "primary",
        repo_root: summary[:repo_root],
        task_id: summary[:task_id],
        task_number: summary[:task_number],
        status: summary[:status] || :pending,
        depth: summary[:depth] || 0,
        parent_id: summary[:parent_id],
        worktree: summary[:worktree],
        retries: summary[:retries] || 0,
        agent_module: parse_agent_module(summary[:agent_module]),
        model_id: summary[:model_id],
        objective: summary[:objective] || "",
        context_path: summary[:context_path],
        current_commit: summary[:current_commit],
        base_commit: summary[:base_commit],
        # children/has_children are computed after the full list is built
        children: [],
        has_children: false,
        pending_sub_agents: [],
        sub_agent_results: %{},
        task_ref: nil,
        result_sent: false,
        history: [],
        usage: normalize_usage(summary[:usage]),
        total_tokens: total_tokens,
        compression_count: compression_count,
        compression_threshold: compression_threshold,
        compression_pct: compression_pct,
        # History-gate input: number of messages in the agent's session-memory
        # context (0 for not-yet-dispatched agents). NOT the history itself —
        # the full history is fetched lazily and only when this count changes.
        message_count: summary[:message_count]
      }
    end)
    # Compute children from the full list using parent_id relationships.
    |> Enum.map(fn agent ->
      children = find_children_from_agents(agent.id, parent_lookup)
      %{agent | children: children, has_children: length(children) > 0}
    end)
    |> Enum.sort_by(&{&1.depth, &1.id})
  end

  # Builds a minimal agent list (only id/parent_id/status) from the RPC
  # summaries, used by find_children_from_agents/2 which keys off parent_id.
  defp summaries_to_agents(summaries) do
    Enum.map(summaries, fn s ->
      %{id: s[:id], parent_id: s[:parent_id], status: s[:status] || :pending}
    end)
  end

  # RemoteAPI returns agent_module as a native module atom
  # (e.g. EvoGit.Agents.Manager), transferred directly by :erpc.call/5.
  # The rendering code calls inspect/1 on it; return the atom so it displays
  # correctly. Returns nil when absent.
  defp parse_agent_module(nil), do: nil
  defp parse_agent_module(module) when is_atom(module), do: module

  # Normalizes the usage value from an agent summary into a struct so the
  # rendering code (which reads usage.input_tokens etc.) works uniformly.
  # :erpc.call/5 transfers the native %EvoGit.Agent.Usage{} struct directly —
  # no serialization boundary — so we just return it (with a nil → zero
  # fallback for agents that have no usage yet).
  defp normalize_usage(nil), do: EvoGit.Agent.Usage.zero()

  defp normalize_usage(%EvoGit.Agent.Usage{} = usage), do: usage

  defp normalize_usage(_), do: EvoGit.Agent.Usage.zero()

  # Reads the config health status for the given node. On the local node this
  # resolves the local config directly; on a remote node it fetches the remote
  # config status via RPC. The layout config banner uses this to show the
  # correct status for the node being viewed (not stale local status). Runs
  # inside the async page-load task (never in the LiveView process).
  defp node_config_status(node) do
    if node == node() do
      EvoGit.Config.config_status()
    else
      EvoDash.NodeContext.get_remote_config_status(node)
    end
  end
end
