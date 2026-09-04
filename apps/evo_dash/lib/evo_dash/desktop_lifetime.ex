defmodule EvoDash.DesktopLifetime do
  @moduledoc """
  Desktop-mode Tauri-shell lifetime watcher (TCP pipe).

  In the Tauri desktop app the backend runs as a sidecar child of the Rust
  shell. If the shell dies abnormally (Force Quit, crash, `kill -9`) there is
  no PDEATHSIG / process-group protection in the Rust shell, so the backend
  survives as an orphaned zombie — still holding its HTTP port, so the next
  app launch crashes with "port already in use".

  This GenServer closes that gap with a **lifetime TCP connection**: at
  startup the Rust shell binds a `TcpListener` on `127.0.0.1:0`, accepts and
  holds one connection per backend instance, and passes the chosen port to
  the backend via the `EVOGIT_LIFETIME_PORT` env var (replacing the old
  `EVOGIT_PARENT_PID` pid-polling scheme). The shell never writes data on
  the pipe. When the shell dies the OS closes its end of the socket, the
  backend's `:gen_tcp.recv/3` returns an error (`:closed`, `:econnreset`,
  `:econnaborted`, ...), and this watcher logs a warning and stops the VM
  via `System.stop(0)`, freeing the port.

  ## Gating

  The watcher is appended to the supervision tree only when BOTH
  `EVOGIT_DESKTOP=1` and `EVOGIT_LIFETIME_PORT` are set (see
  `EvoDash.Application.start/2`) — only the Tauri sidecar sets both, so
  manually-launched releases and the `genesis_remote` daemon are unaffected.
  It lives in the frontend app by design: desktop-only lifecycle code must
  never ship in `genesis_remote`, the evo_git-only headless daemon. As
  belt-and-suspenders, `init/1` also disables itself when
  `EVOGIT_LIFETIME_PORT` is missing, empty, or not a valid port number,
  making a direct start a safe no-op.

  ## Test seams

  - `:parent_stop_fun` — `Application.get_env(:evo_dash, ...)`, read at
    `init/1`; a zero-arity fun replacing `default_stop/0` (tests inject a
    fake so the REAL `System.stop/0` never runs in the test VM).
  - `:connect_retries` / `:connect_retry_delay` — `start_link` opts bounding
    the initial connect retry loop (defaults 5 / 200ms; tests shrink both).
  """

  use GenServer

  require Logger

  @env_var "EVOGIT_LIFETIME_PORT"

  @default_connect_retries 5
  @default_connect_retry_delay 200
  @connect_timeout 1_000

  @type state :: %{
          enabled: boolean(),
          port: :inet.port_number() | nil,
          stop_fun: (-> any()) | nil,
          stopped: boolean(),
          connect_retries: non_neg_integer() | nil,
          connect_retry_delay: pos_integer() | nil
        }

  @doc """
  Starts the watcher.

  `opts` accepts:

  - `:connect_retries` — connect attempts before the shell is presumed dead
    (default 5; in practice the shell binds before spawning us, so the budget
    is purely defensive).
  - `:connect_retry_delay` — ms to sleep between attempts (default 200).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The default stop action — gracefully stops the BEAM VM with exit code 0.

  Overridable via the `:parent_stop_fun` application env (tests inject a
  fake so the REAL `System.stop/0` never runs in the test VM).
  """
  @spec default_stop() :: no_return()
  def default_stop, do: System.stop(0)

  @impl true
  def init(opts) do
    case System.get_env(@env_var) do
      port_str when port_str in [nil, ""] ->
        # Disabled: no socket, no timers, safe no-op (a manually-launched
        # release or a direct start without the sidecar's env var must never
        # misbehave).
        {:ok, disabled_state()}

      port_str ->
        case Integer.parse(port_str) do
          {port, ""} when port in 1..65_535 ->
            stop_fun =
              Application.get_env(:evo_dash, :parent_stop_fun, &__MODULE__.default_stop/0)

            state = %{
              enabled: true,
              port: port,
              stop_fun: stop_fun,
              stopped: false,
              connect_retries: Keyword.get(opts, :connect_retries, @default_connect_retries),
              connect_retry_delay:
                Keyword.get(opts, :connect_retry_delay, @default_connect_retry_delay)
            }

            # Return promptly — the (blocking) connect + recv loop runs in
            # handle_continue so start_link never blocks on the shell.
            {:ok, state, {:continue, :connect}}

          _ ->
            Logger.warning(
              "[desktop] invalid #{@env_var} value #{inspect(port_str)}; lifetime watcher disabled"
            )

            {:ok, disabled_state()}
        end
    end
  end

  @impl true
  def handle_continue(:connect, %{enabled: false} = state) do
    # Disabled — nothing scheduled, nothing to do.
    {:noreply, state}
  end

  def handle_continue(:connect, %{enabled: true, stopped: true} = state) do
    # Shutdown already initiated — never invoke the stop fun twice.
    {:noreply, state}
  end

  def handle_continue(:connect, %{enabled: true} = state) do
    case try_connect(state, state.connect_retries) do
      {:ok, sock} ->
        # Block on the lifetime pipe. When the shell dies the OS closes its
        # end of the socket → recv errors → stop the VM. Blocking the
        # GenServer here is fine — exit signals from the supervisor still
        # interrupt the receive on shutdown.
        {:noreply, wait_for_close(sock, state)}

      {:error, :exhausted} ->
        # The shell never accepted the connection within the retry budget and
        # is presumed dead. (No realistic race exists — the shell binds before
        # spawning us and the connect succeeds via the kernel backlog — the
        # budget is purely defensive.)
        Logger.warning(
          "[desktop] Tauri shell is gone (lifetime connection could not be established) — shutting down"
        )

        state.stop_fun.()
        # Mark stopped so nothing can ever invoke the stop fun twice.
        {:noreply, %{state | stopped: true}}
    end
  end

  defp disabled_state do
    %{
      enabled: false,
      port: nil,
      stop_fun: nil,
      stopped: false,
      connect_retries: nil,
      connect_retry_delay: nil
    }
  end

  defp try_connect(_state, 0), do: {:error, :exhausted}

  defp try_connect(state, attempts) do
    case :gen_tcp.connect({127, 0, 0, 1}, state.port, [:binary, active: false], @connect_timeout) do
      {:ok, sock} ->
        {:ok, sock}

      {:error, _reason} ->
        Process.sleep(state.connect_retry_delay)
        try_connect(state, attempts - 1)
    end
  end

  defp wait_for_close(sock, state) do
    case :gen_tcp.recv(sock, 0, :infinity) do
      {:ok, _data} ->
        # The shell must never send data, but be defensive: keep waiting.
        wait_for_close(sock, state)

      {:error, _reason} ->
        Logger.warning(
          "[desktop] Tauri shell is gone (lifetime connection closed) — shutting down"
        )

        state.stop_fun.()
        # The stop fun stops the VM; no reschedule needed. Mark stopped so a
        # straggler can never invoke it again.
        %{state | stopped: true}
    end
  end
end
