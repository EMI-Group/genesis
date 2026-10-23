defmodule EvoDashWeb.AgentsLive.ThresholdCache do
  @moduledoc """
  Per-node cache for the LLM compression threshold used by the Agents page's
  compression % bars.

  The NODE-LEVEL threshold lives at `[:llm, :compression_threshold_tokens]` in
  the FULL resolved config (`EvoGit.Config.resolve/0`). That setting is
  OPTIONAL: a nil/blank/invalid value means "unknown" (the core derives the
  real trigger from each model's context window), which is why
  `@default_threshold` (180_000) is a LAST-RESORT fallback — used only when
  neither the per-agent summary nor the resolved config provides a usable
  threshold.

  Each agent summary from `RemoteAPI.list_agents/0` carries its OWN
  `compression_threshold` (the already-computed per-agent trigger);
  `threshold_for_agent/2` prefers it and falls back to the node-level value.

  The scheduler config (`EvoGit.AgentScheduler.get_config/0` — what
  `EvoDash.NodeContext.get_remote_config/1` returns) has NO `:llm` section, so
  the old remote branch of `safe_compression_threshold/1` always fell back to
  the default. The remote read now goes through `get_resolved_config/1`
  (node-aware) and this cache.

  Cache shape: `{node, threshold, fetched_at_monotonic}` (nil = empty).
  Refreshed at most every `@refresh_interval_ms` (30s) per node. The fetch
  itself runs ONLY inside the async load/refresh tasks spawned by the
  LiveView — never in a `handle_info`/`handle_event` (no cross-node RPC on
  the LiveView process).
  """

  @refresh_interval_ms 30_000
  @default_threshold 180_000

  @doc """
  The LAST-RESORT threshold, used only when neither the per-agent summary nor
  the resolved config provides a usable (positive integer) threshold.
  """
  @spec default_threshold() :: pos_integer()
  def default_threshold, do: @default_threshold

  @doc """
  Reads the cached threshold for `node` when present and fresh (fetched within
  the refresh interval). Returns `{:ok, threshold}` or `:miss`.
  """
  @spec read(nil | {atom(), pos_integer(), integer()}, atom(), integer()) ::
          {:ok, pos_integer()} | :miss
  def read(nil, _node, _now), do: :miss

  def read({node, threshold, fetched_at}, node, now)
      when now - fetched_at <= @refresh_interval_ms do
    {:ok, threshold}
  end

  def read(_cache, _node, _now), do: :miss

  @doc "Records a fresh fetch result for `node` at monotonic time `now`."
  @spec put(any(), atom(), pos_integer(), integer()) :: {atom(), pos_integer(), integer()}
  def put(_old_cache, node, threshold, now), do: {node, threshold, now}

  @doc """
  Extracts the NODE-LEVEL compression threshold from a resolved-config result.

  Accepts the `{:ok, config} | {:error, reason}` shape returned by
  `EvoDash.NodeContext.get_resolved_config/1`. `config` is the atom-keyed full
  resolved config; the threshold is read at `[:llm, :compression_threshold_tokens]`.
  The setting is OPTIONAL, so a missing key, `nil`, or any non-positive /
  non-integer value (a non-map config included) means "unknown" and yields
  `default_threshold/0` — never a crash.
  """
  @spec threshold_from_config(any()) :: pos_integer()
  def threshold_from_config({:ok, config}) when is_map(config) do
    config
    |> Map.get(:llm)
    |> llm_threshold()
    |> usable_threshold()
  end

  def threshold_from_config(_result), do: @default_threshold

  @doc """
  Returns the effective compression threshold for ONE agent.

  Prefers the agent summary's own `compression_threshold` when it is a
  positive integer — the core computes it per agent from the model's context
  window — and otherwise returns `node_threshold` (the node-level
  `[:llm, :compression_threshold_tokens]` value). An unusable node threshold
  (nil/non-positive/non-integer) yields `default_threshold/0`, so a bar never
  divides by nil or zero.

  The summary read is defensive: atom- OR string-keyed maps are accepted and
  an absent/nil/non-integer value falls back. Total — never raises.
  """
  @spec threshold_for_agent(map() | nil, pos_integer() | nil) :: pos_integer()
  def threshold_for_agent(summary, node_threshold) do
    case summary_threshold(summary) do
      threshold when is_integer(threshold) and threshold > 0 -> threshold
      _ -> usable_threshold(node_threshold)
    end
  end

  @doc """
  Fetches the threshold for `node`, using the cache when fresh.

  Runs inside the async tasks ONLY (never in the LiveView process): on a
  cache miss it calls the node-aware resolved-config reader (injectable via
  the `:agents_config_runner` env seam, resolved at call time so tests can
  stub it). Returns `{threshold, updated_cache}`.
  """
  @spec fetch(atom(), nil | {atom(), pos_integer(), integer()}, integer()) ::
          {pos_integer(), {atom(), pos_integer(), integer()}}
  def fetch(node, cache, now) do
    case read(cache, node, now) do
      {:ok, threshold} ->
        {threshold, cache}

      :miss ->
        runner =
          Application.get_env(
            :evo_dash,
            :agents_config_runner,
            &EvoDash.NodeContext.get_resolved_config/1
          )

        threshold = runner.(node) |> threshold_from_config()
        {threshold, {node, threshold, now}}
    end
  end

  # The summary's per-agent threshold (atom key preferred, string key as a
  # defensive fallback for a JSON-shaped summary).
  defp summary_threshold(summary) when is_map(summary) do
    case Map.get(summary, :compression_threshold) do
      nil -> Map.get(summary, "compression_threshold")
      threshold -> threshold
    end
  end

  defp summary_threshold(_summary), do: nil

  # The resolved config's node-level threshold (`:llm` is absent/nil when no
  # LLM profile is configured, in which case the value is unknown).
  defp llm_threshold(%{} = llm) do
    case Map.get(llm, :compression_threshold_tokens) do
      nil -> Map.get(llm, "compression_threshold_tokens")
      threshold -> threshold
    end
  end

  defp llm_threshold(_llm), do: nil

  defp usable_threshold(value) when is_integer(value) and value > 0, do: value
  defp usable_threshold(_value), do: @default_threshold
end
