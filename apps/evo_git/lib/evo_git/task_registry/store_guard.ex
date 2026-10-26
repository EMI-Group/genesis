defmodule EvoGit.TaskRegistry.StoreGuard do
  @moduledoc """
  Fault isolation for `EvoGit.TaskRegistry`'s synchronous `EvoGit.Store` calls.

  The registry is the GenServer every dashboard LiveView subscribes to, so a
  failing store call must degrade THAT ONE operation — it must never take the
  registry (and with it every subscriber) down.

  `EvoGit.Store` itself already isolates its reads (a failed read answers with
  the empty value of its own shape) and converts disk-full writes to
  `{:error, :disk_full}`. Two failure classes still reach the CALLER, and this
  guard covers them:

    * the store process is dead or restarting — `GenServer.call/3` EXITS with
      `:noproc` / `:normal` / `:shutdown` / `{:timeout, _}`. This is exactly
      the production crash chain: the store (and its writer) died, the
      registry's in-flight call exited with the dead-server reason, and the
      registry died with it, blocking every LiveView;
    * an unexpected raise (or throw) inside a store call — a store
      implementation change, a mock, a corrupted repo instance.

  Both are logged at `:error` with the operation name, and the caller receives
  the documented degraded value.

  ## Guards are PER CALL SITE, not a blanket `try`

  The degraded value must match the operation's own shape (`nil`, `[]`, `0`,
  `{[], 0}`, `:ok`, …), and a blanket rescue around a whole handler would also
  hide bugs in the registry's own logic. Each call site therefore names its
  operation and passes its degraded value explicitly.

  ## The two helpers

    * `read(op, degraded, fun)` — `fun.()`'s value, or `degraded` on exit /
      raise / throw.
    * `write(op, fun)` — `fun.()`'s value, or `{:error, :store_unavailable}` on
      exit / raise / throw. Write call sites handle that EXACTLY like
      `{:error, :disk_full}` (log + continue with the in-memory behavior): the
      registry never exits from a store call.
  """

  require Logger

  @degraded_write_error {:error, :store_unavailable}

  @doc """
  The value `write/2` returns when the store call failed without a store result.

  Call sites treat it exactly like `{:error, :disk_full}`: the in-memory
  behavior proceeds, the row simply is not persisted.
  """
  @spec degraded_write_error() :: {:error, :store_unavailable}
  def degraded_write_error, do: @degraded_write_error

  @doc """
  Runs a store READ, returning `degraded` (the read's own empty shape) instead
  of exiting/raising when the store call fails. Never raises, never exits.
  """
  @spec read(String.t(), term(), (-> term())) :: term()
  def read(op, degraded, fun) when is_binary(op) and is_function(fun, 0) do
    fun.()
  rescue
    exception ->
      log_failure(op, {:error, exception, __STACKTRACE__})
      degraded
  catch
    kind, reason ->
      log_failure(op, {kind, reason})
      degraded
  end

  @doc """
  Runs a store WRITE, returning `{:error, :store_unavailable}` instead of
  exiting/raising when the store call fails. Never raises, never exits.
  """
  @spec write(String.t(), (-> term())) :: term() | {:error, :store_unavailable}
  def write(op, fun) when is_binary(op) and is_function(fun, 0) do
    fun.()
  rescue
    exception ->
      log_failure(op, {:error, exception, __STACKTRACE__})
      @degraded_write_error
  catch
    kind, reason ->
      log_failure(op, {kind, reason})
      @degraded_write_error
  end

  defp log_failure(op, {:error, exception, stacktrace}) do
    Logger.error(
      "TaskRegistry: store operation #{op} FAILED — continuing with the degraded value " <>
        "(the registry stays alive; the store may be restarting): " <>
        Exception.format(:error, exception, Enum.take(stacktrace, 5))
    )
  end

  defp log_failure(op, {kind, reason}) do
    Logger.error(
      "TaskRegistry: store operation #{op} FAILED (#{kind}: #{inspect(reason)}) — " <>
        "continuing with the degraded value (the registry stays alive)"
    )
  end
end
