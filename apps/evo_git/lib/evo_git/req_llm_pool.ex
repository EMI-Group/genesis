defmodule EvoGit.ReqLLMPool do
  @moduledoc """
  Dynamic reconciliation of ReqLLM's Finch HTTP connection pool.

  ReqLLM starts a single named Finch (`ReqLLM.Finch`) whose `:default` pool
  configuration (`stream_pool_count` pool processes, each with
  `stream_pool_size: 1` → one concurrent HTTP/1 stream per pool process) is
  read **once at boot** (`config/runtime.exs`). Runtime configuration changes —
  dashboard model-profile saves, `reload_config`, per-task `-m` model ids —
  can raise the effective LLM concurrency above the boot-time pool count, at
  which point `ReqLLM.stream_text/3` calls queue on the fixed-size Finch pool
  and fail with:

      Finch was unable to provide a connection within the timeout due to excess
      queuing for connections...

  This module reconciles the pool at runtime. It is deliberately **grow-only**:
  `Finch.set_pool_count/3` grows by starting new pool processes (safe) but
  shrinks by terminating existing ones (which can kill in-flight streams), so
  this module never reduces a materialized pool below its current size.

  ## Why `get_pool_status/2`?

  Finch materializes pools **lazily per origin** on first request, and pool
  processes are keyed per origin. `Finch.get_pool_status(finch_name, :default)`
  enumerates every materialized origin (map of `%Finch.Pool{}` → list of
  per-pool-process metrics structs; the list length is the current pool-process
  count). Note that this enumeration requires `start_pool_metrics?: true` in the
  pool configuration — without it the pools never register under `:default` and
  `get_pool_status/2` reports `{:error, :not_found}` (a no-op for this module).

  All functions are defensive: none of them raise, regardless of the shape of
  the data returned by Finch.
  """

  require Logger

  # Substrings that identify the Finch "excess queuing" checkout failure.
  # See deps/finch/lib/finch/http1/pool.ex (the reraised RuntimeError message)
  # and ReqLLM's stream error wrapping of it.
  @excess_queuing_markers ["excess queuing", "unable to provide a connection"]

  @doc """
  The desired pool-process count for a given total LLM concurrency.

  Single source of truth for the pool-count formula, used at boot
  (`config/runtime.exs` calls this function) AND at runtime reconciliation
  (`reconcile/2`): `max(total_concurrency + 2, 8)` — a +2 buffer for auxiliary
  (non-slot-gated) LLM calls on top of the summed per-model concurrency
  (`system_check.ex`, `pull_request.ex`), floored at ReqLLM's default pool
  count of 8.
  """
  @spec desired_count(non_neg_integer()) :: pos_integer()
  def desired_count(total_concurrency) when is_integer(total_concurrency) do
    max(total_concurrency + 2, 8)
  end

  @doc """
  The target pool-process count for the excess-queuing error path: up to 1.5x
  the effective LLM concurrency (floored at 8). Used by
  `bump_for_excess_queuing/3` to give a failing pool generous headroom.
  """
  @spec error_target_count(non_neg_integer()) :: pos_integer()
  def error_target_count(total_concurrency) when is_integer(total_concurrency) do
    max(ceil(total_concurrency * 1.5), 8)
  end

  @doc """
  Effective LLM concurrency from a `%{model_id => concurrency}` map.

  When the map is non-empty, returns `max(sum of map values,
  default_concurrency)`; falls back to `default_concurrency` for an empty map
  or `nil` (e.g. when the scheduler has no per-model concurrency map
  configured).

  Why the `max`? Each model profile is an **independent** LLM slot pool
  (see `EvoGit.AgentScheduler.State.concurrency_for/2` and the per-model
  holder MapSets in `EvoGit.AgentScheduler.Slots`), while unknown model ids
  (e.g. a `-m` id with no `[[llm.models]]` profile) share the
  `default_llm_max_concurrency` bucket. Both buckets can be active
  simultaneously, so the effective concurrency the Finch pool must accommodate
  is `max(sum of per-profile concurrencies, default_llm_max_concurrency)` —
  not the sum alone, which would under-size the pool when the default bucket
  exceeds the profile total.
  """
  @spec effective_concurrency(map() | nil, non_neg_integer()) :: non_neg_integer()
  def effective_concurrency(model_concurrency_map, default_concurrency)
      when is_map(model_concurrency_map) and map_size(model_concurrency_map) > 0 do
    max(Enum.sum(Map.values(model_concurrency_map)), default_concurrency)
  end

  def effective_concurrency(_model_concurrency_map, default_concurrency) do
    default_concurrency
  end

  @doc """
  Reconciles every materialized origin's pool-process count up to
  `desired_count(total_concurrency)`.

  Grow-only: origins already at or above the desired count are left untouched.
  Returns `:ok` always — `{:error, :not_found}` from `get_pool_status/2`
  (nothing materialized yet) is a no-op, and individual `set_pool_count/3`
  failures are logged at debug and ignored.
  """
  @spec reconcile(non_neg_integer(), atom()) :: :ok
  def reconcile(total_concurrency, finch_name \\ ReqLLM.Finch) do
    grow_pools_to(desired_count(total_concurrency), finch_name)
  end

  @doc """
  Grows every materialized origin's pool-process count to
  `error_target_count(effective_concurrency(model_concurrency_map,
  default_concurrency))` — the "up to 1.5x" target used when an excess-queuing
  error has been observed (`excess_queuing_error?/1`).

  Grow-only and never raises, like `reconcile/2`.
  """
  @spec bump_for_excess_queuing(map() | nil, non_neg_integer(), atom()) :: :ok
  def bump_for_excess_queuing(
        model_concurrency_map,
        default_concurrency,
        finch_name \\ ReqLLM.Finch
      ) do
    target = error_target_count(effective_concurrency(model_concurrency_map, default_concurrency))
    grow_pools_to(target, finch_name)
  end

  @doc """
  Returns `true` when `reason` indicates Finch's "excess queuing" checkout
  failure.

  Matches:

    * a bare `%RuntimeError{}` whose message contains "excess queuing" (the
      error actually raised by Finch, see deps/finch/lib/finch/http1/pool.ex);
    * a `%ReqLLM.Error.API.Stream{}` whose `reason` or `cause` inspects to
      something containing "excess queuing" / "unable to provide a connection"
      (ReqLLM wraps the Finch error as its stream error);
    * any other term whose `inspect/1` output contains those markers
      (defensive fallback mirroring
      `EvoGit.Agent.TruncationFeedback.is_rate_limit_error?/1`).

  Returns `false` for unrelated errors (rate limits, network timeouts such as
  `:econnrefused`, other `RuntimeError`s, plain strings).
  """
  @spec excess_queuing_error?(term()) :: boolean()
  def excess_queuing_error?(%RuntimeError{message: message}) when is_binary(message) do
    String.contains?(message, @excess_queuing_markers)
  end

  def excess_queuing_error?(%ReqLLM.Error.API.Stream{reason: reason, cause: cause}) do
    String.contains?(inspect(reason), @excess_queuing_markers) or
      String.contains?(inspect(cause), @excess_queuing_markers)
  end

  def excess_queuing_error?(reason) do
    String.contains?(inspect(reason), @excess_queuing_markers)
  end

  # --- Grow-only apply ---

  # Shared grow-only apply for reconcile/2 and bump_for_excess_queuing/3.
  # Never raises: every shape from get_pool_status/2 is matched defensively.
  defp grow_pools_to(desired, finch_name) when is_integer(desired) and desired > 0 do
    # get_pool_status/2 raises ArgumentError ("unknown registry") when the
    # Finch instance is not running. ReqLLM.Finch always starts before
    # :evo_git in the app boot order, but guard anyway to honor the
    # never-raise contract for any caller that may run pre-boot (e.g. the
    # scheduler init/1 reconciliation).
    if Process.whereis(finch_name) do
      case Finch.get_pool_status(finch_name, :default) do
        {:ok, pools} when is_map(pools) ->
          Enum.each(pools, fn {pool_id, metrics} ->
            maybe_grow(finch_name, pool_id, metrics, desired)
          end)

          :ok

        # {:error, :not_found} (nothing materialized) or any unexpected shape.
        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp grow_pools_to(_desired, _finch_name), do: :ok

  # Only list-shaped metrics carry a per-pool-process count; skip anything else
  # (e.g. a hypothetical HTTP/2 map-shaped metrics value) defensively.
  defp maybe_grow(finch_name, pool_id, metrics, desired) when is_list(metrics) do
    old_count = length(metrics)

    if old_count < desired do
      case grow_pool(finch_name, pool_id, desired) do
        :ok ->
          Logger.info(
            "ReqLLMPool: enlarged Finch pool #{inspect(finch_name)} for origin " <>
              "#{inspect(pool_id)} from #{old_count} to #{desired}"
          )

        :error ->
          Logger.debug(
            "ReqLLMPool: could not enlarge Finch pool #{inspect(finch_name)} for origin " <>
              "#{inspect(pool_id)} to #{desired}"
          )
      end
    end

    :ok
  end

  defp maybe_grow(_finch_name, _pool_id, _metrics, _desired), do: :ok

  # Only a %Finch.Pool{} (what get_pool_status/2 returns as map keys) is a
  # usable pool identifier for set_pool_count/3; swallow anything unexpected.
  defp grow_pool(finch_name, %Finch.Pool{} = pool_id, desired) do
    case Finch.set_pool_count(finch_name, pool_id, desired) do
      :ok -> :ok
      {:error, _reason} -> :error
      _ -> :error
    end
  end

  defp grow_pool(_finch_name, _pool_id, _desired), do: :error
end
