defmodule EvoGit.Agent.Usage do
  @moduledoc """
  Cumulative token and cost usage tracking for agents.
  """

  defstruct input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            input_cost: 0.0,
            output_cost: 0.0,
            total_cost: 0.0,
            cached_tokens: 0,
            cache_creation_tokens: 0

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          input_cost: float(),
          output_cost: float(),
          total_cost: float(),
          cached_tokens: non_neg_integer(),
          cache_creation_tokens: non_neg_integer()
        }

  @doc "Creates a zero-usage struct."
  def zero, do: %__MODULE__{}

  @doc "Creates a Usage from ReqLLM.Response.usage/1 map. Returns zero struct for nil."
  def from_response_usage(nil), do: zero()

  def from_response_usage(%{} = usage) do
    %__MODULE__{
      input_tokens: Map.get(usage, :input_tokens, 0) || 0,
      output_tokens: Map.get(usage, :output_tokens, 0) || 0,
      total_tokens: Map.get(usage, :total_tokens, 0) || 0,
      input_cost: Map.get(usage, :input_cost, 0.0) || 0.0,
      output_cost: Map.get(usage, :output_cost, 0.0) || 0.0,
      total_cost: Map.get(usage, :total_cost, 0.0) || 0.0,
      cached_tokens: Map.get(usage, :cached_tokens, 0) || 0,
      cache_creation_tokens: Map.get(usage, :cache_creation_tokens, 0) || 0
    }
  end

  @archive_usage_keys [
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :input_cost,
    :output_cost,
    :total_cost,
    :cached_tokens,
    :cache_creation_tokens,
    :cache_hit_rate
  ]

  @doc """
  Canonical usage-map keys carried by per-agent archive records.

  `CompleteTask`'s private `format_usage_for_archive/1` (the single writer)
  stores per-agent usage in archive records as a PLAIN MAP with exactly these
  atom keys; after the Store JSON round-trip the same keys are strings.
  `cache_hit_rate` is a derived value (not a `%Usage{}` struct field — see
  `cache_hit_rate/1`). Archive usage NEVER contains a `cost` key (that legacy
  name exists only in the git-note usage shape).
  """
  def archive_usage_keys, do: @archive_usage_keys

  @doc """
  Builds a `%Usage{}` from an archive-record usage map (atom- OR string-keyed).

  Accepts `nil` (→ zero usage), an existing `%Usage{}` (returned unchanged), or
  a plain map in either keying carrying the keys of `archive_usage_keys/0`.
  Missing keys and nil values default to zero, mirroring
  `from_response_usage/1`; the derived `cache_hit_rate` key is ignored (not a
  struct field — recompute via `cache_hit_rate/1`).
  """
  @spec from_archive_map(nil | %__MODULE__{} | map()) :: t()
  def from_archive_map(nil), do: zero()

  def from_archive_map(%__MODULE__{} = usage), do: usage

  def from_archive_map(usage) when is_map(usage) do
    %__MODULE__{
      input_tokens: pick(usage, :input_tokens),
      output_tokens: pick(usage, :output_tokens),
      total_tokens: pick(usage, :total_tokens),
      input_cost: pick(usage, :input_cost),
      output_cost: pick(usage, :output_cost),
      total_cost: pick(usage, :total_cost),
      cached_tokens: pick(usage, :cached_tokens),
      cache_creation_tokens: pick(usage, :cache_creation_tokens)
    }
  end

  defp pick(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || 0
  end

  @doc "Adds two Usage structs together (accumulates tokens and costs)."
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens,
      total_tokens: a.total_tokens + b.total_tokens,
      input_cost: a.input_cost + b.input_cost,
      output_cost: a.output_cost + b.output_cost,
      total_cost: a.total_cost + b.total_cost,
      cached_tokens: a.cached_tokens + b.cached_tokens,
      cache_creation_tokens: a.cache_creation_tokens + b.cache_creation_tokens
    }
  end

  @doc "Computes the cache hit rate as a percentage (0.0 to 100.0)."
  def cache_hit_rate(%__MODULE__{} = usage) do
    if usage.input_tokens > 0 do
      usage.cached_tokens / usage.input_tokens * 100.0
    else
      0.0
    end
  end
end
