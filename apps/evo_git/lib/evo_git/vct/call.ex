defmodule EvoGit.VCT.Call do
  @moduledoc """
  Internal transport for every `EvoGit.VCT` client function.

  This module is an internal helper of `EvoGit.VCT` and carries no mount state.
  `call/3,4` answers the caller's documented DEGRADATION value instead of an
  exit when the VCT server is missing, dead or slow: it owns the `:exit` catch
  and exactly ONE `Logger.warning` per failed call, naming the server, the
  request it could not serve and the reason.
  `broadcast/3` is the best-effort counterpart — PubSub may be down or
  unreachable, and a broadcast failure must NEVER fail a mutation that already
  persisted.

  The `:evogit_vct_server` process-dictionary seam is resolved in exactly ONE
  place, `EvoGit.VCT.server/0`, and the already-resolved server is passed in
  here, so this module never reads that key and never runs inside the server
  process.
  """

  require Logger

  @call_timeout 30_000

  @doc false
  @spec call(term(), term(), term()) :: term()
  def call(server, request, default), do: call(server, request, default, @call_timeout)

  @doc false
  @spec call(term(), term(), term(), timeout()) :: term()
  def call(server, request, default, timeout) do
    GenServer.call(server, request, timeout)
  catch
    :exit, reason -> transport_failure(server, request, default, reason)
  end

  @doc false
  @spec broadcast(term(), String.t(), term()) :: :ok
  def broadcast(pubsub, topic, message) do
    Phoenix.PubSub.broadcast(pubsub, topic, message)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  # The DEFAULT is the caller's declared degradation, so an error-union read
  # passes `{:error, :vct_unavailable}` and a list/scalar read passes its empty
  # shape; either way a transport failure is announced once and never invented
  # data.
  defp transport_failure(server, request, default, reason) do
    Logger.warning(
      "VCT: #{inspect(server)} unavailable for #{inspect(request)}: #{inspect(reason)}"
    )

    default
  end
end
