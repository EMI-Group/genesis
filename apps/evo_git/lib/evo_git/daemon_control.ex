defmodule EvoGit.DaemonControl do
  @moduledoc """
  File-driven runtime control plane for the `genesis_server` daemon.

  The release CLI never talks to the BEAM over distribution: it writes a
  request file into `<data_dir>/remote/` and pings the daemon with SIGHUP
  (or the daemon's own boot path calls `publish_state/0`). This GenServer owns
  NO timers and no polling — it acts only when signalled — and lets ONE
  `genesis_server` instance keep serving HTTP while distribution is toggled at
  runtime, instead of running a second, distribution-only daemon unit per host.

  ## File protocol (`<data_dir>/remote/`)

  `control.request` — written by the CLI, atomically, `KEY=VALUE` lines:

      ACTION=enable|disable
      NODE=<node name>          (enable only)
      COOKIE=<cookie>           (enable only)
      DIST_PORT=<digits>        (enable only)
      SEQ=<digits>              (echoed back to the caller)

  `dist.env` — written by the DAEMON, the authoritative ACTUAL state:

      GENESIS_DIST_ENABLED=1|0
      GENESIS_NODE=<actual node>
      GENESIS_DIST_PORT=<port|unknown>
      GENESIS_CONTROL_SEQ=<echoed SEQ or empty>
      GENESIS_CONTROL_RESULT=ok|error
      GENESIS_CONTROL_MESSAGE=<one line, newlines stripped>

  `desired.env` — the durable intent, written only after a SUCCESSFUL action:

      ENABLED=1 + NODE/COOKIE/DIST_PORT, or ENABLED=0 (no secret kept)

  Both state files are written atomically (tmp file in the same directory +
  `File.rename/2`) with mode 0600. The result is written BEFORE the request is
  deleted, so a caller that sees its request gone always has a result to read;
  `dist.env` is NEVER deleted — it is the daemon's published state, not a
  mailbox.

  ## Seams (read at CALL time, default-inert)

  - `:daemon_control_dist` — module implementing `enable_runtime/3`,
    `disable_runtime/0`, `active/0` (default `EvoGit.Distribution`).
  - `:daemon_control_signal_install` — 0-arity fun replacing the real SIGHUP
    installer.
  - `init/1` opts win over both: `dir:`, `dist:`, `signal_install:`, `name:`.
  """

  use GenServer

  require Logger

  @request_file "control.request"
  @dist_file "dist.env"
  @desired_file "desired.env"

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Asks the control plane to process a pending `control.request` (async).

  This is what the SIGHUP handler calls, and what a CLI write is followed by.
  A reload with no pending request is a true no-op — `dist.env` is not
  rewritten.
  """
  @spec reload(GenServer.server()) :: :ok
  def reload(server \\ __MODULE__) do
    GenServer.cast(server, :reload)
  end

  @doc false
  # Deterministic barrier for tests: casts and calls are handled in arrival
  # order, so a `:sync` reply proves every earlier `reload/1` already ran.
  @spec sync(GenServer.server()) :: :ok
  def sync(server \\ __MODULE__) do
    GenServer.call(server, :sync)
  end

  @doc false
  # `<data_dir>/remote`, resolved exactly like `EvoGit.TaskRegistry` resolves
  # its data dir (the app-env override is what test isolation pins).
  @spec remote_dir() :: String.t()
  def remote_dir do
    Path.join(Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir()), "remote")
  end

  ## Functional core (no process required — drives the file protocol)

  @doc false
  # Processes ONE pending `control.request` against `dir`, then deletes it.
  # Returns `:ok` in every case (a malformed request is reported through
  # `dist.env`, never raised to the caller).
  @spec handle_control_request(String.t(), module()) :: :ok
  def handle_control_request(dir \\ remote_dir(), dist \\ dist_module()) do
    case File.read(Path.join(dir, @request_file)) do
      {:ok, contents} ->
        do_handle_control_request(dir, dist, contents)
        delete_request(dir)
        :ok

      {:error, _reason} ->
        # No request pending: a true no-op. dist.env is NOT rewritten (its
        # content and mtime stay exactly as the last real action left them).
        :ok
    end
  end

  @doc false
  # Publishes the ACTUAL distribution state to `dist.env` — used at boot (also
  # covering a node booted distributed via `RELEASE_DISTRIBUTION=name`, whose
  # real node/port are read from `active/0`) and by tests.
  @spec publish_state(String.t(), module()) :: :ok | {:error, term()}
  def publish_state(dir \\ remote_dir(), dist \\ dist_module()) do
    state = safe_active(dist)

    publish(
      dir,
      %{enabled: state.enabled, node: state.node, dist_port: state.dist_port},
      "",
      :ok,
      boot_message(state)
    )
  end

  ## GenServer

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, remote_dir())
    dist = Keyword.get(opts, :dist, dist_module())

    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("DaemonControl: cannot create #{dir}: #{inspect(reason)}")
    end

    adopt_desired(dir, dist)
    publish_state(dir, dist)
    install_signal_hook(Keyword.get(opts, :signal_install, signal_install_seam()))

    {:ok, %{dir: dir, dist: dist}}
  end

  @impl true
  def handle_cast(:reload, state) do
    handle_control_request(state.dir, state.dist)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end

  ## Request processing

  defp do_handle_control_request(dir, dist, contents) do
    seq = raw_seq(contents)

    # Centralised boundary: the request file is EXTERNAL input that drives
    # VM-global distribution state, and this process is the only way the CLI
    # can reach the daemon — an unexpected raise/exit must be reported through
    # dist.env, never crash the control plane.
    try do
      contents
      |> parse_kv()
      |> run_action(dist)
      |> apply_outcome(dir, dist, seq)
    rescue
      error ->
        failure =
          "unexpected failure: #{Exception.message(error)}"

        Logger.warning("DaemonControl: request failed: #{failure}")
        apply_outcome({:error, failure}, dir, dist, seq)
    catch
      kind, reason ->
        failure = "unexpected failure: #{inspect({kind, reason})}"
        Logger.warning("DaemonControl: request failed: #{failure}")
        apply_outcome({:error, failure}, dir, dist, seq)
    end
  end

  defp run_action(request, dist) do
    case request["ACTION"] do
      "enable" ->
        run_enable(request, dist)

      "disable" ->
        run_disable(dist)

      action when action in [nil, ""] ->
        {:error, "missing ACTION"}

      action ->
        {:error, "unknown ACTION #{inspect(action)}"}
    end
  end

  defp run_enable(request, dist) do
    with {:ok, node_name} <- required(request["NODE"], "NODE"),
         {:ok, port} <- parse_port(request["DIST_PORT"]) do
      cookie = request["COOKIE"] || ""

      case dist.enable_runtime(node_name, cookie, port) do
        {:ok, %{node: actual, dist_port: actual_port}} ->
          # BOTH nodes are carried: `actual` goes into dist.env (the published
          # truth), `requested` into desired.env (the identity to re-adopt at
          # boot — an echoed/host-normalized `actual` is not necessarily a name
          # the VM accepts back as input).
          {:ok, :enable,
           %{node: actual, requested: node_name, dist_port: actual_port, cookie: cookie}}

        {:error, reason} ->
          {:error, "distribution enable failed: #{format_reason(reason)}"}

        other ->
          {:error, "distribution enable returned an unexpected result: #{inspect(other)}"}
      end
    end
  end

  defp run_disable(dist) do
    case dist.disable_runtime() do
      :ok ->
        {:ok, :disable, nil}

      {:error, reason} ->
        {:error, "distribution disable failed: #{format_reason(reason)}"}

      other ->
        {:error, "distribution disable returned an unexpected result: #{inspect(other)}"}
    end
  end

  defp apply_outcome(
         {:ok, :enable, %{node: node, requested: requested, dist_port: port, cookie: cookie}},
         dir,
         _dist,
         seq
       ) do
    publish(
      dir,
      %{enabled: true, node: node, dist_port: port},
      seq,
      :ok,
      "distribution enabled on #{node}:#{port_value(port)}"
    )

    write_desired(dir, [
      "ENABLED=1",
      "NODE=#{single_line(requested)}",
      "COOKIE=#{single_line(cookie)}",
      "DIST_PORT=#{port_value(port)}"
    ])
  end

  defp apply_outcome({:ok, :disable, _info}, dir, dist, seq) do
    state = safe_active(dist)

    # Explicitly 0: the action was a successful disable, so the reported
    # enabled flag is the OUTCOME, not whatever a stale active/0 might say.
    publish(
      dir,
      %{enabled: false, node: state.node, dist_port: state.dist_port},
      seq,
      :ok,
      "distribution disabled"
    )

    write_desired(dir, ["ENABLED=0"])
  end

  defp apply_outcome({:error, message}, dir, dist, seq) do
    state = safe_active(dist)

    # The durable intent is left untouched — it still describes what the
    # caller last successfully asked for.
    publish(
      dir,
      %{enabled: state.enabled, node: state.node, dist_port: state.dist_port},
      seq,
      :error,
      message
    )
  end

  ## Boot adoption

  defp adopt_desired(dir, dist) do
    with {:ok, contents} <- File.read(Path.join(dir, @desired_file)),
         %{"ENABLED" => "1"} = desired <- parse_kv(contents),
         {:ok, node_name} <- required(desired["NODE"], "NODE"),
         {:ok, port} <- parse_port(desired["DIST_PORT"]) do
      case dist.enable_runtime(node_name, desired["COOKIE"] || "", port) do
        {:ok, _state} ->
          :ok

        {:error, reason} ->
          # Best effort by design: the daemon must boot (and serve HTTP) even
          # when its host cannot run distribution — the CLI can retry.
          Logger.warning(
            "DaemonControl: cannot re-adopt distribution for #{node_name}: #{format_reason(reason)}"
          )
      end
    else
      _ -> :ok
    end
  end

  ## Signal hook

  defp install_signal_hook(install) do
    cond do
      System.get_env("EVOGIT_NO_SIGNAL_HOOK") == "1" -> :ok
      EvoGit.Platform.windows?() -> :ok
      is_function(install, 0) -> install.()
      true -> do_install_signal_hook()
    end
  end

  defp do_install_signal_hook do
    # :os.set_signal/2 raises ArgumentError (badarg) on ERTS builds/platforms
    # that do not know SIGHUP, and :gen_event.add_handler/3 EXITS when
    # :erl_signal_server is not running — neither has a non-raising variant, and
    # a daemon without the hook is still fully functional (the CLI re-writes the
    # request and retries). Hence one boundary around both.
    try do
      :os.set_signal(:sighup, :handle)

      case :gen_event.add_handler(:erl_signal_server, __MODULE__.SignalHandler, []) do
        :ok ->
          :ok

        {:error, :already_present} ->
          :ok

        {:error, {:already_present, _handlers}} ->
          :ok

        other ->
          Logger.warning("DaemonControl: cannot attach the SIGHUP handler: #{inspect(other)}")
          :error
      end
    rescue
      error ->
        Logger.warning("DaemonControl: cannot handle SIGHUP: #{Exception.message(error)}")
        :error
    catch
      kind, reason ->
        Logger.warning("DaemonControl: cannot handle SIGHUP: #{inspect({kind, reason})}")
        :error
    end
  end

  ## File helpers

  defp delete_request(dir) do
    case File.rm(Path.join(dir, @request_file)) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("DaemonControl: cannot delete the control request: #{inspect(reason)}")
        :error
    end
  end

  defp publish(dir, state, seq, result, message) do
    contents =
      [
        "GENESIS_DIST_ENABLED=#{if state.enabled, do: "1", else: "0"}",
        "GENESIS_NODE=#{single_line(state.node)}",
        "GENESIS_DIST_PORT=#{port_value(state.dist_port)}",
        "GENESIS_CONTROL_SEQ=#{single_line(seq)}",
        "GENESIS_CONTROL_RESULT=#{result}",
        "GENESIS_CONTROL_MESSAGE=#{single_line(message)}"
      ]
      |> Enum.join("\n")

    write_atomic(Path.join(dir, @dist_file), contents <> "\n")
  end

  defp write_desired(dir, lines) do
    write_atomic(Path.join(dir, @desired_file), Enum.join(lines, "\n") <> "\n")
  end

  # Atomic + 0600: the tmp file lives in the SAME directory (a rename across
  # filesystems is not atomic), is chmod-ed BEFORE the rename so the published
  # file never appears with a looser mode, and is removed when any step fails.
  defp write_atomic(path, contents) do
    tmp =
      Path.join(
        Path.dirname(path),
        "." <>
          Path.basename(path) <> ".tmp-#{System.unique_integer([:positive])}"
      )

    with :ok <- File.write(tmp, contents, [:binary]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("DaemonControl: cannot write #{path}: #{inspect(reason)}")
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  # A distribution module (a fake, or a VM mid-stop) can raise out of active/0;
  # the report file must still be written, so this read degrades to an empty
  # state instead of losing the outcome message.
  defp safe_active(dist) do
    dist.active()
  rescue
    _error -> %{enabled: false, node: to_string(node()), dist_port: nil}
  end

  # SEQ straight out of the raw request bytes, with byte-level operations only,
  # so the caller's SEQ is echoed even when the rest of the file is malformed
  # (that is exactly when a caller most needs to correlate the answer).
  defp raw_seq(contents) do
    contents
    |> :binary.split("\n", [:global])
    |> Enum.find_value("", fn line ->
      case :binary.split(String.trim_trailing(line, "\r"), "=") do
        ["SEQ", value] -> value
        _other -> nil
      end
    end)
  end

  defp parse_kv(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(String.trim(line), "=", parts: 2) do
        [key, value] when key != "" -> Map.put(acc, String.trim(key), String.trim(value))
        _other -> acc
      end
    end)
  end

  defp required(value, label) do
    case is_binary(value) && String.trim(value) do
      "" -> {:error, "missing #{label}"}
      false -> {:error, "missing #{label}"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port > 0 ->
        {:ok, port}

      _other ->
        {:error, "invalid DIST_PORT #{inspect(value)}: expected a positive integer"}
    end
  end

  defp parse_port(_value), do: {:error, "missing DIST_PORT"}

  defp port_value(nil), do: "unknown"
  defp port_value(port) when is_integer(port), do: Integer.to_string(port)
  defp port_value(other), do: single_line(other)

  # `dist.env` is a line-oriented file: a multi-line message (an exception with
  # a stacktrace-ish body) is folded into ONE line.
  defp single_line(value) do
    value
    |> to_string()
    |> String.replace(~r/\r\n|\r|\n/, " ")
    |> String.trim()
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp boot_message(%{enabled: true, node: node, dist_port: port}),
    do: "distribution already active on #{node}:#{port_value(port)}"

  defp boot_message(_state), do: "not distributed"

  ## Configuration seams (read at CALL time; default-inert)

  defp dist_module, do: Application.get_env(:evo_git, :daemon_control_dist, EvoGit.Distribution)

  defp signal_install_seam,
    do: Application.get_env(:evo_git, :daemon_control_signal_install, nil)
end

defmodule EvoGit.DaemonControl.SignalHandler do
  @moduledoc """
  `:gen_event` handler for `:erl_signal_server`: forwards SIGHUP to
  `EvoGit.DaemonControl.reload/0`.

  It must NEVER do the file work inline — the signal server is a shared,
  VM-wide event manager, and the control plane owns the (possibly slow) file
  I/O and distribution calls.
  """

  @behaviour :gen_event

  @impl true
  def init(_args), do: {:ok, %{}}

  @impl true
  def handle_event(:sighup, state) do
    EvoGit.DaemonControl.reload()
    {:ok, state}
  end

  def handle_event(_event, state), do: {:ok, state}

  @impl true
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl true
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}
end
