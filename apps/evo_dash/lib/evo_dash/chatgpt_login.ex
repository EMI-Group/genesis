defmodule EvoDash.ChatGPTLogin do
  @moduledoc """
  The ONE Sign in with ChatGPT (SIWC) loopback login flow, shared by the terminal CLI (`EvoDash.ChatGPTCLI`) and the dashboard LiveViews.
  Each attempt is ONE `EvoDash.ChatGPTLogin.Flow` process: it binds `127.0.0.1:<port>`, mints the authorization URL against the REAL bound port, waits for the browser callback, exchanges the code through `EvoGit.Auth.ChatGPT.exchange/2` and installs the registration through `EvoGit.Auth.ChatGPT.Store`, then stops — every exit path closes its listener.
  This module is the registry on top of those flows: it issues an opaque id per attempt, keeps ONE live flow per account (a second `begin/2` SUPERSEDES the first), records exactly ONE terminal result per id for a bounded retention window, and is the ONLY party that notifies a registered `:caller`.
  A flow whose loopback listener cannot be bound degrades to `mode: :manual` instead of failing, and `submit_callback/2` hands a pasted redirect URL (or query string, or bare code) back to the SAME attempt — the manual (remote-host) path of the same PKCE verifier, `state` and install.
  The flow's dependencies are call-time seams — `:exchange`/`:store` options, else the app env keys `:chatgpt_login_exchange` and `:chatgpt_login_store` (defaults `EvoGit.Auth.ChatGPT.exchange/2` and `EvoGit.Auth.ChatGPT.Store`) — so the whole flow is drivable without a network or a credential file.
  Nothing here raises on a bad id: an unknown id is `{:error, :unknown_flow}` everywhere.
  """

  use GenServer

  alias EvoDash.ChatGPTLogin.Flow

  @supervisor EvoDash.ChatGPTLogin.Supervisor
  @default_account "default"
  @default_timeout_ms 600_000
  @default_retention_ms 300_000
  @call_timeout 10_000
  @info_timeout 10_000
  @stop_timeout 5_000

  @typedoc "The identity a caller needs to open the browser and to ask for the outcome."
  @type flow :: %{
          id: binary(),
          url: binary(),
          port: pos_integer(),
          mode: :loopback | :manual
        }

  @doc """
  Starts ONE sign-in attempt and returns its id, authorization URL, redirect port and mode.

  `mode` is `:loopback` while the attempt owns a `127.0.0.1` callback listener, and `:manual` when that listener could not be bound — the attempt is then completed by pasting the redirect URL back through `submit_callback/2`.

  Options: `:port` (`0` picks a free ephemeral port), `:timeout_ms` (the sign-in window, default ten minutes), `:retention_ms` (how long the terminal result stays readable, default five minutes), `:caller` (a pid that receives `{:chatgpt_login, id, result}` once the attempt reaches a terminal state), `:exchange` (a `fun/2` replacing the core exchange) and `:store` (a module replacing the core credential store).

  A second `begin/2` for the same account supersedes the live flow (its terminal result becomes `{:error, :superseded}` and its caller is notified).
  """
  @spec begin(binary() | nil, keyword()) :: {:ok, flow()} | {:error, term()}
  def begin(account, opts \\ [])

  def begin(account, opts) when (is_binary(account) or is_nil(account)) and is_list(opts) do
    with :ok <- ensure_started() do
      case Process.whereis(__MODULE__) do
        nil -> {:error, :login_unavailable}
        pid -> GenServer.call(pid, {:begin, account, opts}, @call_timeout + @info_timeout)
      end
    end
  end

  def begin(_account, _opts), do: {:error, :invalid_account}

  @doc """
  The state of one attempt: `:pending` while it waits, the terminal result afterwards (for the retention window), `{:error, :unknown_flow}` for an id that never existed or has expired.
  """
  @spec status(binary()) ::
          :pending | {:ok, %{account: binary(), status: map()}} | {:error, term()}
  def status(id) do
    call({:status, id}, {:error, :unknown_flow})
  end

  @doc """
  Hands a pasted redirect back to ONE pending attempt and acknowledges it.

  Accepted shapes: a full redirect URL (any scheme or host), a `?`-prefixed query string, a bare query string (`code=…&state=…`) or a bare authorization code — see `EvoDash.ChatGPTLogin.Paste.parse/1`.

  The paste completes the SAME attempt `begin/2` started (same PKCE verifier, same `state`, same install), so a browser on another machine — or a host where no listener could be bound — can still finish the sign-in. Validation is synchronous and cheap while the token exchange runs off the attempt's call path, so this call only acks: the terminal outcome always arrives through `status/1` and the `:caller` notification `{:chatgpt_login, id, result}`.

  A paste with a foreign `state` (`{:error, :invalid_callback}`) or with no code (`{:error, :no_code}`) leaves the attempt PENDING, so the user can paste again.
  """
  @spec submit_callback(binary(), term()) ::
          {:ok, %{id: binary()}}
          | {:error,
             :unknown_flow | :already_finished | :invalid_callback | :no_code | :login_unavailable}
  def submit_callback(id, input) do
    call({:submit_callback, id, input}, {:error, :login_unavailable})
  end

  @doc """
  Cancels a live attempt: its listener and flow stop and its terminal result becomes `{:error, :cancelled}`.
  """
  @spec cancel(binary()) :: :ok | {:error, :unknown_flow}
  def cancel(id) do
    call({:cancel, id}, {:error, :unknown_flow})
  end

  @doc """
  The id of the flow currently waiting for the given account, else `nil`.
  """
  @spec active_for(binary()) :: binary() | nil
  def active_for(account) when is_binary(account) or is_nil(account) do
    call({:active_for, account}, nil)
  end

  def active_for(_account), do: nil

  @doc """
  Whether any attempt is still waiting for its browser callback.
  """
  @spec pending?() :: boolean()
  def pending? do
    call(:pending?, false)
  end

  @doc false
  # Starts the supervisor and the facade when nothing has started them yet: the
  # dashboard's own supervision tree always has them, but a standalone
  # `mix genesis.chatgpt login` (from a source checkout) boots no application.
  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started do
    with :ok <- ensure_supervisor(), do: ensure_facade()
  end

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{flows: %{}, terminals: %{}}}
  end

  @impl true
  def handle_call({:begin, account, opts}, _from, state) do
    account = normalize_account(account)
    state = supersede(state, account)

    case start_flow(account, opts) do
      {:ok, id, pid, info, config} ->
        flow = Map.merge(config, %{account: account, pid: pid})
        _monitor = Process.monitor(pid)
        {:reply, {:ok, info}, %{state | flows: Map.put(state.flows, id, flow)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:status, id}, _from, state) do
    cond do
      Map.has_key?(state.flows, id) -> {:reply, :pending, state}
      is_nil(state.terminals[id]) -> {:reply, {:error, :unknown_flow}, state}
      true -> {:reply, state.terminals[id], state}
    end
  end

  def handle_call({:submit_callback, id, input}, _from, state) do
    case Map.fetch(state.flows, id) do
      {:ok, flow} -> {:reply, submit_to_flow(flow.pid, input), state}
      :error -> {:reply, missing_flow_answer(state, id), state}
    end
  end

  def handle_call({:cancel, id}, _from, state) do
    case Map.fetch(state.flows, id) do
      {:ok, flow} -> {:reply, :ok, retire(state, id, flow, {:error, :cancelled}, true)}
      :error -> {:reply, {:error, :unknown_flow}, state}
    end
  end

  def handle_call({:active_for, account}, _from, state) do
    account = normalize_account(account)

    active =
      Enum.find_value(state.flows, fn {id, flow} ->
        if flow.account == account, do: id
      end)

    {:reply, active, state}
  end

  def handle_call(:pending?, _from, state) do
    {:reply, map_size(state.flows) > 0, state}
  end

  @impl true
  def handle_info({:flow_terminal, id, result}, state) do
    case Map.fetch(state.flows, id) do
      {:ok, flow} ->
        # The flow reported its own result, so it stops itself once the browser
        # response is written — stopping it here would cut that response short.
        {:noreply, retire(state, id, flow, result, false)}

      :error ->
        # A terminal for an id that already retired (cancel/supersede raced the
        # callback). The FIRST terminal wins; this one is stale.
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _reference, :process, pid, reason}, state) do
    case flow_id_for_pid(state, pid) do
      nil ->
        # A flow that reported its own terminal (`{:flow_terminal, …}`) already
        # left `flows` when its `:DOWN` arrives — Erlang preserves signal order
        # between one sender/receiver pair, so the terminal message is always
        # first — and retire/5 therefore never runs twice for one id.
        {:noreply, state}

      id ->
        flow = Map.fetch!(state.flows, id)
        {:noreply, retire(state, id, flow, {:error, {:flow_crashed, reason}}, false)}
    end
  end

  def handle_info({:expire, id}, state) do
    {:noreply, %{state | terminals: Map.delete(state.terminals, id)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp call(message, fallback) do
    case Process.whereis(__MODULE__) do
      nil -> fallback
      pid -> GenServer.call(pid, message, @call_timeout)
    end
  end

  # The flow answers a submit synchronously (parse, validate, spawn the
  # exchange) and only acks, so this call can never block on the token exchange.
  defp submit_to_flow(pid, input) do
    GenServer.call(pid, {:submit, input}, @call_timeout)
  catch
    # The flow is gone (crashed, cancelled or already stopped); its own `:DOWN`
    # retires it and notifies the caller, so the paste is simply too late.
    :exit, _reason -> {:error, :already_finished}
  end

  # An id that is not live either finished within the retention window
  # (`:already_finished`) or never existed (`:unknown_flow`).
  defp missing_flow_answer(state, id) do
    if Map.has_key?(state.terminals, id),
      do: {:error, :already_finished},
      else: {:error, :unknown_flow}
  end

  defp start_flow(account, opts) do
    arg = flow_arg(account, opts)

    with supervisor when is_pid(supervisor) <- Process.whereis(@supervisor),
         {:ok, pid} <- DynamicSupervisor.start_child(supervisor, Flow.child_spec(arg)),
         {:ok, info} <- flow_info(pid) do
      config = %{
        id: info.id,
        caller: arg.caller,
        retention_ms: arg.retention_ms
      }

      {:ok, info.id, pid, info, config}
    else
      nil -> {:error, :login_unavailable}
      {:error, reason} -> {:error, normalize_start_error(reason)}
    end
  end

  defp flow_arg(account, opts) do
    %{
      id: new_id(),
      account: account,
      port: Keyword.get(opts, :port) || 0,
      timeout_ms: Keyword.get(opts, :timeout_ms) || @default_timeout_ms,
      retention_ms: Keyword.get(opts, :retention_ms) || @default_retention_ms,
      caller: Keyword.get(opts, :caller),
      exchange: Keyword.get(opts, :exchange) || exchange_fun(),
      store: Keyword.get(opts, :store) || store_fun(),
      facade: self()
    }
  end

  # A flow reports its identity through ONE call right after it starts; a dead
  # or silent flow there is unavailable, never a hang.
  defp flow_info(pid) do
    Flow.info(pid)
  catch
    :exit, _reason -> {:error, :login_unavailable}
  end

  defp normalize_start_error({:shutdown, reason}), do: reason
  defp normalize_start_error(reason), do: reason

  defp supersede(state, account) do
    case Enum.find(state.flows, fn {_id, flow} -> flow.account == account end) do
      nil -> state
      {id, flow} -> retire(state, id, flow, {:error, :superseded}, true)
    end
  end

  # Records ONE terminal result for `id`: the caller is notified exactly once
  # (from here — flows never message a caller directly), the flow leaves the
  # live registry, and the result expires `retention_ms` later.
  defp retire(state, id, flow, result, stop?) do
    if stop?, do: stop_flow(flow.pid)
    if is_pid(flow.caller), do: send(flow.caller, {:chatgpt_login, id, result})
    _timer = Process.send_after(self(), {:expire, id}, flow.retention_ms)

    %{
      state
      | flows: Map.delete(state.flows, id),
        terminals: Map.put(state.terminals, id, result)
    }
  end

  defp stop_flow(pid) do
    try do
      GenServer.stop(pid, :normal, @stop_timeout)
    catch
      # A flow stuck in a callback (or already gone) is killed instead of
      # blocking the facade; its linked listener dies with it.
      :exit, _reason -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp flow_id_for_pid(state, pid) do
    Enum.find_value(state.flows, fn {id, flow} ->
      if flow.pid == pid, do: id
    end)
  end

  defp normalize_account(nil), do: @default_account
  defp normalize_account(""), do: @default_account
  defp normalize_account(account) when is_binary(account), do: account

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp exchange_fun do
    Application.get_env(:evo_dash, :chatgpt_login_exchange, &EvoGit.Auth.ChatGPT.exchange/2)
  end

  defp store_fun do
    Application.get_env(:evo_dash, :chatgpt_login_store, EvoGit.Auth.ChatGPT.Store)
  end

  defp ensure_supervisor do
    case Process.whereis(@supervisor) do
      nil ->
        case DynamicSupervisor.start_link(strategy: :one_for_one, name: @supervisor) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  defp ensure_facade do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end
end
