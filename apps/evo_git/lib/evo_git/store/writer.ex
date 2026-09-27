defmodule EvoGit.Store.Writer do
  @moduledoc """
  The dedicated WRITER process of one `EvoGit.Store` instance.

  ## Why this exists

  Every store write used to run INLINE in the `EvoGit.Store` GenServer, so a
  single slow write blocked that GenServer's mailbox for EVERY other handler:
  `Operations.Tasks.put_task/2` is one `:immediate` delete + full-row insert
  that costs ~137 ms when the row carries a multi-megabyte `result`, and the
  cleanup paths issue hundreds of chunked statements in a burst. While such a
  write ran, single-row reads, counts, id projections AND the 60 s
  `TaskRegistry` heartbeat pair (`get_task_status` + `update_lease_expires_at`
  per owned task) all waited behind it.

  The facade therefore no longer executes writes: it FORWARDS each one here
  (`submit/3`) and immediately returns `{:noreply, state}`. This process runs
  the operation and `GenServer.reply/2`s the ORIGINAL caller's `from` once the
  operation has completed.

  ## Invariants this process owns

    * **Strict serialization, arrival order.** The facade forwards a write the
      moment it dequeues its own mailbox (it never waits on the write), so the
      messages arrive here in the facade's own arrival order — Erlang
      guarantees pairwise ordering — and this process handles one at a time.
      Writes are therefore executed strictly one after another, in exactly the
      order a single GenServer would have produced (a delete that arrives after
      an update still wins).
    * **Reply-after-commit.** The reply is sent only AFTER the operation has
      returned — i.e. after its transaction committed — so a caller that has
      seen its reply (or that issues a later write) reads its own write back.
    * **Crash semantics, unchanged.** No blanket try/rescue anywhere on this
      process's path: an operation that raises kills this process with the
      operation's own `{exception, stacktrace}` reason, and the LINK to the
      store kills the store with exactly that reason. To the caller, the
      supervisor, and `terminate/2` this is indistinguishable from the old
      inline raise (verified: `GenServer` does not trap exits, so the exit
      signal propagates verbatim). The ONE rescue on the write path stays the
      disk-full choke point (`EvoGit.Store`'s `write_call/2`) — the facade
      hands its closure to THIS process, so the adapter's raise and the
      `{:error, :disk_full}` conversion both happen where the write runs.
    * **Correct dynamic repo instance.** Every `EvoGit.Store.Operations.*`
      function binds the store's UNNAMED dynamic `EvoGit.Repo` instance itself
      through `EvoGit.Store.RepoScope.with_repo/2` in the CALLING process —
      this one — so the write addresses the right database with no state
      threaded through here (same mechanism the offloaded read Task uses).
    * **No leaks.** `init/1` MONITORS the store: whatever reason the store
      exits with — a crash, a supervisor `:shutdown`, or the `:normal` of
      `GenServer.stop/1` (a reason a linked, non-trapping process IGNORES) —
      this process stops as well. `EvoGit.Store.terminate/2` additionally asks
      for a bounded graceful drain so no write is in flight while the repo
      instance is being closed.

  ## What this changes for READS

  Reads are untouched (they are already served off the facade's mailbox), but
  they now reach the pool while a write is running instead of queueing behind
  it in the facade's inbox. With a single pooled connection that means a read
  simply WAITS for the connection (measured: ~190 ms behind a 12 MB `put_task`)
  and then sees the committed row; with more than one connection it is served
  concurrently. A store that must keep serving readers during long writes
  therefore wants `pool_size > 1` — the offload makes the pool, not the facade
  inbox, the read/write contention point.

  Not a registered name: it is per-store and addressed by pid only, exactly
  like the store's dynamic repo instance.
  """

  use GenServer

  @doc """
  Starts the writer for `store` (the `EvoGit.Store` process), LINKED to it.

  ## Options

    * `:store` — (required) the pid of the `EvoGit.Store` process this writer
      serves; monitored so the writer follows the store down.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :store))
  end

  @doc """
  Forwards one write to the writer process.

  `fun` is the operation closure (built by the facade, capturing this store's
  repo pid), `from` is the ORIGINAL caller's `GenServer.from/0` — the writer
  replies to that caller directly once `fun` has returned.

  Returns `:ok` immediately: this call never blocks on the write, so the
  facade's mailbox is free while the write is running.
  """
  @spec submit(pid(), GenServer.from(), (-> term())) :: :ok
  def submit(writer, from, fun) when is_pid(writer) and is_function(fun, 0) do
    GenServer.cast(writer, {:write, from, fun})
  end

  ## GenServer callbacks

  @impl true
  def init(store) do
    {:ok, %{store_ref: Process.monitor(store)}}
  end

  # Run the write, then reply to the ORIGINAL caller. A raise here is
  # deliberately NOT caught: it kills this process (and, through the link, the
  # store) exactly like the old inline handler did.
  @impl true
  def handle_cast({:write, from, fun}, state) do
    GenServer.reply(from, fun.())
    {:noreply, state}
  end

  # The store is gone (any reason) — there is nothing left to write for.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{store_ref: ref} = state) do
    {:stop, :normal, state}
  end
end
