defmodule EvoDashWeb.AgentsLive.ThresholdCache do
  @moduledoc """
  Per-node cache for the LLM compression threshold used by the Agents page's
  compression % bars.

  The threshold lives at `[:llm, :compression_threshold_tokens]` in the FULL
  resolved config (`EvoGit.Config.resolve/0`, default 100_000). The scheduler
  config (`EvoGit.AgentScheduler.get_config/0` — what
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
  @default_threshold 100_000

  @doc "The fallback threshold when the config value is absent."
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
  Extracts the compression threshold from a resolved-config result.

  Accepts the `{:ok, config} | {:error, reason}` shape returned by
  `EvoDash.NodeContext.get_resolved_config/1`. `config` is the atom-keyed full
  resolved config; the threshold is read at `[:llm, :compression_threshold_tokens]`
  (default 100_000).
  """
  @spec threshold_from_config({:ok, map()} | {:error, term()}) :: pos_integer()
  def threshold_from_config({:ok, config}) do
    get_in(config, [:llm, :compression_threshold_tokens]) || @default_threshold
  end

  def threshold_from_config({:error, _reason}), do: @default_threshold

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
end
