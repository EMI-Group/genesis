defmodule EvoDash.ChatGPTLogin.Flow do
  @moduledoc """
  ONE short-lived Sign in with ChatGPT loopback attempt.
  A flow is started (and only started) by `EvoDash.ChatGPTLogin`, runs `:temporary` under `EvoDash.ChatGPTLogin.Supervisor`, is never registered under a name, and owns exactly one `127.0.0.1` callback listener for its whole lifetime.
  It mints the SIWC authorization attempt AFTER the socket is bound (so the redirect URI carries the REAL port, including an ephemeral one), validates the callback's `state`, runs the exchange plus the store installation and reports exactly ONE terminal result to the facade with a plain message before it stops — a plain send, never a call, so a flow can never deadlock the facade.
  Every exit path stops the listener: `terminate/2` for a graceful stop, and the link from this process to the Bandit supervisor for a crash or a kill.
  """

  use GenServer

  alias EvoDash.ChatGPTLogin.Callback
  alias EvoGit.Auth.ChatGPT

  @facade_call_timeout 10_000
  @listener_stop_timeout 5_000

  @doc false
  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @doc false
  def child_spec(arg) do
    %{
      id: {__MODULE__, arg.id},
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      shutdown: @listener_stop_timeout,
      type: :worker
    }
  end

  @doc """
  The flow's public identity: the id its facade knows it by, the authorization URL to open and the bound loopback port.
  """
  @spec info(pid()) :: {:ok, %{id: binary(), url: binary(), port: pos_integer()}}
  def info(pid), do: GenServer.call(pid, :info, @facade_call_timeout)

  @impl true
  def init(arg) do
    # Trapping exits is what keeps a FAILED bind from killing this process: a
    # ThousandIsland supervisor that cannot bind dies while linked to us, and an
    # untrapped exit signal would replace the honest
    # `:loopback_listener_unavailable` with Bandit's internal reason.
    Process.flag(:trap_exit, true)

    with {:ok, host_id} <- arg.store.host_id(),
         {:ok, registration} <- registration(arg.store, arg.account),
         {:ok, listener} <- start_listener(arg.port),
         {:ok, port} <- listener_port(listener),
         {:ok, url, attempt} <- authorization(host_id, port, registration) do
      # The facade's death orphans this attempt: stop instead of leaving a
      # listener nobody can report to. A plain pid monitor, so a restarted
      # facade (new pid) also ends the flows it inherited from.
      _monitor = Process.monitor(arg.facade)
      _timer = Process.send_after(self(), :authorization_timeout, arg.timeout_ms)

      {:ok,
       Map.merge(arg, %{
         listener: listener,
         port: port,
         url: url,
         attempt: attempt,
         terminal: nil
       })}
    else
      # A failed bind/authorization maps to one atom the caller can report; the
      # listener (when it exists) is already linked, so this non-normal exit
      # takes it down with the flow.
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, {:ok, %{id: state.id, url: state.url, port: state.port}}, state}
  end

  def handle_call({:callback, params}, _from, %{terminal: nil} = state) do
    if same_state?(params["state"], state.attempt.state) do
      complete(params, state)
    else
      {:reply, {:keep_open, {400, Callback.invalid_attempt_page()}}, state}
    end
  end

  def handle_call({:callback, _params}, _from, state) do
    {:reply, {:keep_open, {409, Callback.already_finished_page()}}, state}
  end

  @impl true
  def handle_cast(:responded, state), do: {:stop, :normal, state}

  @impl true
  def handle_info(:authorization_timeout, state) do
    state =
      if state.terminal == nil do
        notify_facade(state, {:error, :authorization_timeout})
        %{state | terminal: {:error, :authorization_timeout}}
      else
        state
      end

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _reference, :process, pid, _reason}, %{facade: facade} = state)
      when pid == facade do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, %{listener: listener} = state) when pid == listener do
    state =
      if state.terminal == nil do
        result = {:error, {:flow_crashed, reason}}
        notify_facade(state, result)
        %{state | terminal: result}
      else
        state
      end

    {:stop, :normal, %{state | listener: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{listener: listener}), do: stop_listener(listener)
  def terminate(_reason, _state), do: :ok

  # A state-matching callback may still be unusable (no `code`, an unexpected
  # `error`), which keeps the attempt PENDING rather than spending the user's
  # whole sign-in window on one stray request.
  defp complete(params, state) do
    cond do
      denial?(params) ->
        finish(
          state,
          {:error, :authorization_denied},
          400,
          Callback.failure_page(:authorization_denied)
        )

      code(params) ->
        exchange(params, state)

      true ->
        {:reply, {:keep_open, {400, Callback.invalid_attempt_page()}}, state}
    end
  end

  defp exchange(params, state) do
    case install(params, state) do
      {:ok, status} ->
        result = {:ok, %{account: state.account, status: status}}
        finish(state, result, 200, Callback.success_page())

      {:error, reason} ->
        finish(state, {:error, reason}, 400, Callback.failure_page(reason))
    end
  end

  defp install(params, state) do
    with {:ok, record} <- state.exchange.(state.attempt, params),
         {:ok, _installed} <- state.store.install(state.account, record) do
      {:ok, status_map(state)}
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_exchange_result, other}}
    end
  end

  # The store's own status map is the richest terminal payload (account label
  # plus its model list). A store that cannot answer right after installing is
  # not a failure of the sign-in itself, so the terminal result degrades to the
  # documented minimal map instead of failing.
  defp status_map(state) do
    case state.store.status(state.account) do
      {:ok, status} when is_map(status) -> status
      _other -> %{account_id: state.account}
    end
  end

  defp finish(state, result, status, body) do
    notify_facade(state, result)
    {:reply, {:terminal, {status, body}}, %{state | terminal: result}}
  end

  defp notify_facade(state, result), do: send(state.facade, {:flow_terminal, state.id, result})

  defp denial?(%{"error" => error}) when is_binary(error) and error != "", do: true
  defp denial?(_params), do: false

  defp code(%{"code" => value}) when is_binary(value) and value != "", do: value
  defp code(_params), do: nil

  defp same_state?(received, expected) when is_binary(received) and is_binary(expected) do
    :crypto.hash_equals(:crypto.hash(:sha256, received), :crypto.hash(:sha256, expected))
  end

  defp same_state?(_received, _expected), do: false

  defp registration(store, account) do
    case store.registration(account) do
      {:error, reason} when reason in [:no_credentials, :invalid_credentials] -> {:ok, nil}
      result -> result
    end
  end

  defp authorization(host_id, port, registration) do
    ChatGPT.authorization(host_id, redirect_uri(port), registration)
  end

  defp redirect_uri(port), do: "http://127.0.0.1:#{port}/auth/callback"

  defp start_listener(port) do
    with {:ok, _apps} <- Application.ensure_all_started(:bandit) do
      case Bandit.start_link(
             plug: {Callback, self()},
             ip: {127, 0, 0, 1},
             port: port,
             startup_log: false
           ) do
        {:ok, listener} -> {:ok, listener}
        {:error, _reason} -> {:error, :loopback_listener_unavailable}
      end
    else
      {:error, _reason} -> {:error, :loopback_listener_unavailable}
    end
  end

  defp listener_port(listener) do
    case ThousandIsland.listener_info(listener) do
      {:ok, {_address, port}} when is_integer(port) and port > 0 -> {:ok, port}
      _other -> {:error, :loopback_listener_unavailable}
    end
  end

  defp stop_listener(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        Supervisor.stop(pid, :normal, @listener_stop_timeout)
      catch
        # The listener is already shutting down (its parent exit signal reached
        # it first); nothing is left to stop and there is nothing to report.
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp stop_listener(_listener), do: :ok
end
