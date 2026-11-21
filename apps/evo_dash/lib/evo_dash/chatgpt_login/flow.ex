defmodule EvoDash.ChatGPTLogin.Flow do
  @moduledoc """
  ONE short-lived Sign in with ChatGPT attempt.
  A flow is started (and only started) by `EvoDash.ChatGPTLogin`, runs `:temporary` under `EvoDash.ChatGPTLogin.Supervisor`, is never registered under a name, and owns at most one `127.0.0.1` callback listener for its whole lifetime.
  It mints the SIWC authorization attempt AFTER the socket is bound (so the redirect URI carries the REAL port, including an ephemeral one), validates the callback's `state`, runs the exchange plus the store installation and reports exactly ONE terminal result to the facade with a plain message before it stops — a plain send, never a call, so a flow can never deadlock the facade.
  A listener that cannot be bound is not a failure: the attempt degrades to `mode: :manual`, where the redirect URI still names a concrete port (`1455` when the caller asked for an ephemeral one) and the user hands the callback back through `submit/2` instead of the browser.
  That pasted path completes the SAME attempt — same PKCE verifier, same `state`, same install — and runs the exchange in a monitored task, so `info/1` and a racing HTTP callback stay answerable while it installs.
  Every exit path stops the listener: `terminate/2` for a graceful stop, and the link from this process to the Bandit supervisor for a crash or a kill.
  """

  use GenServer

  alias EvoDash.ChatGPTLogin.Callback
  alias EvoDash.ChatGPTLogin.Paste
  alias EvoGit.Auth.ChatGPT

  @facade_call_timeout 10_000
  @listener_stop_timeout 5_000
  @default_manual_port 1455
  # A paste already produced a code, so the exchange is bounded on its own (the
  # same budget the HTTP callback waits with) instead of relying on the
  # ten-minute sign-in window.
  @exchange_timeout 150_000

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
  The flow's public identity: the id its facade knows it by, the authorization URL to open, the redirect port and the attempt's `:loopback | :manual` mode.
  """
  @spec info(pid()) ::
          {:ok, %{id: binary(), url: binary(), port: pos_integer(), mode: :loopback | :manual}}
  def info(pid), do: GenServer.call(pid, :info, @facade_call_timeout)

  @doc """
  Accepts a pasted redirect back for this attempt: a callback URL, a query string or a bare code.

  The reply is only an ack (`{:ok, %{id: id}}`) or a refusal that leaves the attempt pending; the terminal outcome reaches the caller through `EvoDash.ChatGPTLogin.status/1` and the `{:chatgpt_login, id, result}` notification, never through this call.
  """
  @spec submit(pid(), term()) ::
          {:ok, %{id: binary()}}
          | {:error, :already_finished | :invalid_callback | :no_code}
  def submit(pid, input), do: GenServer.call(pid, {:submit, input}, @facade_call_timeout)

  @impl true
  def init(arg) do
    # Trapping exits is what keeps a FAILED bind from killing this process: a
    # ThousandIsland supervisor that cannot bind dies while linked to us, and an
    # untrapped exit signal would replace the honest
    # `:loopback_listener_unavailable` with Bandit's internal reason.
    Process.flag(:trap_exit, true)

    with {:ok, host_id} <- arg.store.host_id(),
         {:ok, registration} <- registration(arg.store, arg.account),
         {:ok, listener, port, mode} <- bind(arg.port),
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
         mode: mode,
         url: url,
         attempt: attempt,
         exchange_task: nil,
         terminal: nil
       })}
    else
      # Only the store or the authorization can fail an attempt now: a listener
      # that cannot be bound degrades to `:manual` instead.
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, {:ok, %{id: state.id, url: state.url, port: state.port, mode: state.mode}}, state}
  end

  def handle_call({:callback, params}, _from, %{terminal: nil, exchange_task: nil} = state) do
    if same_state?(params["state"], state.attempt.state) do
      complete(params, state)
    else
      {:reply, {:keep_open, {400, Callback.invalid_attempt_page()}}, state}
    end
  end

  # A finished attempt — including one whose exchange is still in flight — never
  # accepts a second callback: one attempt installs at most once.
  def handle_call({:callback, _params}, _from, state) do
    {:reply, {:keep_open, {409, Callback.already_finished_page()}}, state}
  end

  def handle_call({:submit, input}, _from, %{terminal: nil, exchange_task: nil} = state) do
    case Paste.parse(input) do
      {:ok, params} ->
        if paste_state_ok?(params, state) do
          {:reply, {:ok, %{id: state.id}}, start_exchange(params, state)}
        else
          # A foreign `state` is refused and the attempt stays PENDING, so the
          # user can paste the right URL again.
          {:reply, {:error, :invalid_callback}, state}
        end

      # An `error` parameter is the user's browser reporting a denial: accept the
      # ack and end the attempt exactly like the HTTP callback does.
      {:error, :authorization_denied} ->
        result = {:error, :authorization_denied}
        notify_facade(state, result)
        {:stop, :normal, {:ok, %{id: state.id}}, %{state | terminal: result}}

      {:error, :no_code} ->
        {:reply, {:error, :no_code}, state}
    end
  end

  def handle_call({:submit, _input}, _from, state) do
    {:reply, {:error, :already_finished}, state}
  end

  @impl true
  def handle_cast(:responded, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({:flow_exchange_result, pid, result}, %{exchange_task: %{pid: pid}} = state) do
    state = drop_exchange(state, :demonitor)
    finish_without_response(state, terminal_result(result, state))
  end

  def handle_info({:exchange_timeout, reference}, %{exchange_task: %{ref: reference}} = state) do
    state = drop_exchange(state, :demonitor)
    finish_without_response(state, {:error, :exchange_timeout})
  end

  # The exchange task died before reporting (a raising `:exchange` or `:store`
  # fun), so nothing was installed and the attempt is over instead of waiting
  # out its whole sign-in window.
  def handle_info(
        {:DOWN, reference, :process, pid, reason},
        %{exchange_task: %{pid: pid, ref: reference}} = state
      ) do
    state = drop_exchange(state, :monitor_consumed)
    finish_without_response(state, {:error, {:flow_crashed, reason}})
  end

  # A paste already consumed this attempt; the exchange has its own bound, so the
  # sign-in window must not cut the installation short.
  def handle_info(:authorization_timeout, %{exchange_task: %{}} = state), do: {:noreply, state}

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
  def terminate(_reason, state) do
    kill_exchange(state)
    stop_listener(Map.get(state, :listener))
  end

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
    case exchange_and_install(
           state.exchange,
           state.store,
           state.attempt,
           params,
           state.account
         ) do
      {:ok, status} ->
        result = {:ok, %{account: state.account, status: status}}
        finish(state, result, 200, Callback.success_page())

      {:error, reason} ->
        finish(state, {:error, reason}, 400, Callback.failure_page(reason))
    end
  end

  # Once a paste started the exchange, the terminal result goes straight to the
  # facade: there is no HTTP response to write, so the flow stops at once and
  # frees its (already useless) listener.
  defp finish_without_response(state, result) do
    notify_facade(state, result)
    {:stop, :normal, %{state | terminal: result}}
  end

  # The pasted path reports the same payload shape as the HTTP callback: the
  # account label plus the store's status map.
  defp terminal_result({:ok, status}, state), do: {:ok, %{account: state.account, status: status}}
  defp terminal_result({:error, _reason} = error, _state), do: error

  defp start_exchange(params, state) do
    # A bare code carries no `state` of its own; it is bound to THIS attempt
    # through the PKCE verifier, so the exchange sees the attempt's state.
    params = Map.put_new(params, "state", state.attempt.state)
    flow = self()
    exchange = state.exchange
    store = state.store
    attempt = state.attempt
    account = state.account

    {pid, reference} =
      spawn_monitor(fn ->
        result = exchange_and_install(exchange, store, attempt, params, account)
        send(flow, {:flow_exchange_result, self(), result})
      end)

    timer = Process.send_after(self(), {:exchange_timeout, reference}, @exchange_timeout)
    %{state | exchange_task: %{pid: pid, ref: reference, timer: timer}}
  end

  # The exchange runs OFF this process's call path, so its dictionary, its links
  # and its timers are all the flow's own: one monitored task, one bound.
  defp exchange_and_install(exchange, store, attempt, params, account) do
    with {:ok, record} <- exchange.(attempt, params),
         {:ok, _installed} <- store.install(account, record) do
      {:ok, status_map(store, account)}
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_exchange_result, other}}
    end
  end

  # Every caller matches an in-flight exchange first, so this only ever runs with
  # a task present; `:monitor_consumed` is the `:DOWN` path, whose monitor is
  # already spent.
  defp drop_exchange(%{exchange_task: task} = state, monitor) do
    if monitor == :demonitor, do: Process.demonitor(task.ref, [:flush])
    _timer = Process.cancel_timer(task.timer)
    %{state | exchange_task: nil}
  end

  defp kill_exchange(%{exchange_task: nil}), do: :ok

  defp kill_exchange(%{exchange_task: task}) do
    Process.demonitor(task.ref, [:flush])
    _timer = Process.cancel_timer(task.timer)
    Process.exit(task.pid, :kill)
    :ok
  end

  # The store's own status map is the richest terminal payload (account label
  # plus its model list). A store that cannot answer right after installing is
  # not a failure of the sign-in itself, so the terminal result degrades to the
  # documented minimal map instead of failing.
  defp status_map(store, account) do
    case store.status(account) do
      {:ok, status} when is_map(status) -> status
      _other -> %{account_id: account}
    end
  end

  defp finish(state, result, status, body) do
    notify_facade(state, result)
    {:reply, {:terminal, {status, body}}, %{state | terminal: result}}
  end

  defp notify_facade(state, result), do: send(state.facade, {:flow_terminal, state.id, result})

  defp denial?(%{"error" => error}) when is_binary(error) and error != "", do: true
  defp denial?(_params), do: false

  defp code(%{"code" => value}) when is_binary(value) and value != "", do: true
  defp code(_params), do: false

  # A pasted redirect URL carries the `state` it was minted with; a bare code has
  # none (see `start_exchange/2`). A PRESENT state is compared constant-time,
  # exactly like the HTTP callback.
  defp paste_state_ok?(%{"state" => received}, state),
    do: same_state?(received, state.attempt.state)

  defp paste_state_ok?(_params, _state), do: true

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

  # The loopback listener is a LOCAL convenience, never a precondition: a remote
  # Genesis (or a machine where the port is taken) still gets a usable attempt,
  # completed by pasting the redirect URL back into `submit/2`.
  defp bind(requested_port) do
    case start_listener(requested_port) do
      {:ok, listener} ->
        case listener_port(listener) do
          {:ok, port} ->
            {:ok, listener, port, :loopback}

          {:error, _reason} ->
            # A bound-but-unreadable listener is as useless as a failed bind: drop
            # it (so its link cannot linger) and go manual.
            stop_listener(listener)
            {:ok, nil, manual_port(requested_port), :manual}
        end

      {:error, _reason} ->
        {:ok, nil, manual_port(requested_port), :manual}
    end
  end

  # The redirect URI needs a CONCRETE port even when no listener exists: the
  # caller's requested port when it named one, else the documented default.
  defp manual_port(port) when is_integer(port) and port > 0, do: port
  defp manual_port(_port), do: @default_manual_port

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
