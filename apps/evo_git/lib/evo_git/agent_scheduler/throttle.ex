defmodule EvoGit.AgentScheduler.PubSub.Throttle do
  @moduledoc """
  GenServer backing the throttled `{:agents_updated}` broadcast.

  Coalesces rapid `:schedule` casts into a single flush broadcast at most
  `@throttle_ms` milliseconds after the last schedule — the same semantics as
  the original bare-spawn receive loop. Runs under
  `EvoGit.AgentScheduler.PubSub.ThrottleSupervisor` (started by
  `EvoGit.AgentScheduler.PubSub.start_throttle/0`) with a `:permanent`
  restart strategy, so a crash restarts it instead of silently degrading to
  unthrottled broadcasts forever.
  """

  use GenServer

  @throttle_ms 200

  @doc "Starts the throttle GenServer, registered under `__MODULE__`."
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(timer_ref) do
    {:ok, timer_ref}
  end

  @impl true
  def handle_cast(:schedule, timer_ref) do
    if timer_ref, do: Process.cancel_timer(timer_ref)
    new_ref = Process.send_after(self(), :flush, @throttle_ms)
    {:noreply, new_ref}
  end

  @impl true
  def handle_info(:flush, _timer_ref) do
    Phoenix.PubSub.broadcast(
      EvoGit.PubSub,
      EvoGit.AgentScheduler.PubSub.agent_topic(),
      {:agents_updated}
    )

    {:noreply, nil}
  end
end
