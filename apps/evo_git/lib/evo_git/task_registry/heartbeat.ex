defmodule EvoGit.TaskRegistry.Heartbeat do
  @moduledoc """
  The lease HEARTBEAT's one batched renewal pass for `EvoGit.TaskRegistry`.

  Every 60 s the registry renews the leases of the tasks it OWNS (the keys of its
  in-memory `task_refs`), so it stays the authoritative owner and the one-shot
  `:lease_sweep` never mistakes a live run for a leaked one.

  The tick used to cost TWO store round trips PER OWNED TASK (a
  `get_task_status` read plus an `update_lease_expires_at` write) inside the
  GenServer every dashboard call is queued on. It now costs at most TWO STORE
  CALLS TOTAL:

    1. ONE `EvoGit.Store.select_task_statuses/2` for the whole owned set;
    2. ONE `EvoGit.Store.renew_leases/3` for the renewable subset — skipped
       entirely when nothing is renewable.

  ## What is renewable

  `EvoGit.TaskRegistry.Lease.lease_renewable?/1` is the ONE classification (it
  lives beside the sweep's `leaked?/3` so the two can never drift): a live
  status (`:running | :pending | :cancelling | :awaiting_input | :pausing`) OR a
  row that EXISTS with an unreadable status text (`{:unknown, raw}`) — renewing
  is always the conservative answer for a row we cannot read. An ABSENT id (not
  a key in the status map) and every terminal status renew nothing; `:paused` is
  deliberately NOT renewable (a paused task has no wrapper and no lease).

  ## Degradation

  A failed status read (`StoreGuard.read/3` → `%{}`) renews NOTHING and writes
  nothing: the existing, documented degradation is that a store outage lets the
  leases expire on schedule, after which the sweep handles the rows. A failed
  renewal write is logged ONCE for the whole pass, naming the task COUNT (never
  one warning per task): a heartbeat is fire-and-forget, so disk-full or an
  unavailable store simply means this tick did not renew.

  Purely renewal — the heartbeat NEVER sweeps and never changes a status.
  """

  require Logger

  alias EvoGit.TaskRegistry.Lease
  alias EvoGit.TaskRegistry.StoreGuard

  @doc """
  Renews the lease of every RENEWABLE task among `task_ids` in ONE batched read
  plus (at most) ONE batched write. Always answers `:ok` — a heartbeat tick has
  no caller to fail.
  """
  @spec renew(GenServer.server(), [String.t()], integer()) :: :ok
  def renew(_store, [], _expires_at), do: :ok

  def renew(store, task_ids, expires_at) when is_list(task_ids) and is_integer(expires_at) do
    statuses =
      StoreGuard.read("heartbeat select_task_statuses", %{}, fn ->
        EvoGit.Store.select_task_statuses(store, task_ids)
      end)

    task_ids
    |> Enum.filter(&Lease.lease_renewable?(Map.get(statuses, &1)))
    |> renew_leases(store, expires_at)
  end

  defp renew_leases([], _store, _expires_at), do: :ok

  defp renew_leases(renewable_ids, store, expires_at) do
    case StoreGuard.write("heartbeat renew_leases", fn ->
           EvoGit.Store.renew_leases(store, renewable_ids, expires_at)
         end) do
      :ok ->
        :ok

      {:error, :disk_full} ->
        # Fire-and-forget renewal: the leases simply expire on schedule if they
        # cannot be renewed, and the sweep then treats the tasks as orphaned.
        Logger.warning(
          "TaskRegistry: disk full — #{length(renewable_ids)} task lease(s) could not be " <>
            "renewed on this heartbeat tick"
        )

        :ok

      {:error, :store_unavailable} ->
        # StoreGuard already logged the fault — nothing was renewed.
        :ok
    end
  end
end
