defmodule EvoGit.BackgroundJobs.RegistryClient do
  @moduledoc """
  The ONE transport boundary between `EvoGit.BackgroundJobs`' public API and its registry process.

  Every request is a `GenServer.call/3` whose exit means the registry is DEAD, absent or wedged — never that the requested job does not exist.
  Collapsing that exit into a per-site answer (`:not_found`, `[]`, `:ok`) at the transport layer is what once told an agent "no such background job" while its jobs were still running; so this module answers exactly ONE failure shape, `{:error, :registry_unavailable}`, and each public function in `EvoGit.BackgroundJobs` maps the two shapes to its own documented reply in one visible place.
  A failing call logs exactly ONE `Logger.warning` naming the request (`request_tag/1`); a request that actually answered — including a semantic `{:error, :not_found}` reply — never logs.
  """

  require Logger

  @type reply :: {:ok, term()} | {:error, :registry_unavailable}

  @doc """
  Sends `message` to `server` and returns `{:ok, reply}`, or `{:error, :registry_unavailable}` when the call exits (a dead, absent or wedged registry, or the explicit `timeout` expiring).

  The two-tuple is deliberate: a registry reply is itself often a `{:error, reason}` tuple, so wrapping keeps "the registry answered" distinguishable from "there was no registry to answer".
  """
  @spec call(GenServer.server(), term(), timeout()) :: reply()
  def call(server, message, timeout) do
    {:ok, GenServer.call(server, message, timeout)}
  catch
    # Justified boundary: this IS the transport boundary — a `GenServer.call/3`
    # exit is how an unreachable registry reports itself, and every public caller
    # needs a value instead of an exit.
    :exit, reason ->
      Logger.warning(
        "BackgroundJobs: registry call #{request_tag(message)} failed: #{inspect(reason)}"
      )

      {:error, :registry_unavailable}
  end

  @doc "Names a request for the failure log line: the message's tag atom (or the whole message when it has none), inspected."
  @spec request_tag(term()) :: String.t()
  def request_tag(message) when is_tuple(message), do: inspect(elem(message, 0))
  def request_tag(message), do: inspect(message)
end
