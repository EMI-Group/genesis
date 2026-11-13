defmodule EvoGit.Config.Watcher do
  @moduledoc """
  Owns "config changed → refresh `EvoGit.Config.Cache`".

  Config is read from RAM (see `EvoGit.Config.Cache`), so an external edit —
  a hand-edited `~/.config/genesis/config.toml`, a remote-node write, an
  editor save — needs an event to become visible. This GenServer subscribes to
  the vendored `file_system` worker for the config directory and, on a
  `config.toml`/`credentials.toml` event, schedules ONE debounced reload
  (~150 ms, coalesced) of the directory snapshot; an `agents.toml` event
  refreshes the custom-agent cache (`EvoGit.CustomAgents.reload/0`).

  The debounced file-event reload and the save event `notify_change/2` — which
  `EvoGit.Config.save_user_config/1` and `save_credentials/1` raise — converge
  on ONE handler, so both paths share a single snapshot-reload implementation.
  `notify_change/2` is total and bounded: it falls back to that same reload
  when no watcher is registered, and a dead, slow or absent watcher never
  fails or indefinitely blocks a save.

  The watcher is a convenience, never a requirement: when the backend is
  unavailable (no `inotify-tools`, watch limit, a missing directory) it logs
  ONE warning and keeps running with no watcher, and saves/explicit reloads
  still refresh the snapshot. It never crashes the application.
  """

  use GenServer

  require Logger

  @debounce_ms 150
  @call_timeout 5_000
  @config_filename "config.toml"
  @credentials_filename "credentials.toml"
  @agents_filename "agents.toml"

  @doc """
  Starts the watcher.

  Options:
    * `:dir` — the config directory to watch (default `EvoGit.Config.config_dir/0`)
    * `:name` — the registered name (default `EvoGit.Config.Watcher`); pass
      `nil` for an unnamed instance (used by isolated tests)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    dir = Keyword.get(opts, :dir) || EvoGit.Config.config_dir()
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []

    GenServer.start_link(__MODULE__, dir, gen_opts)
  end

  @doc """
  Raises the config-changed event for a save: synchronous and TOTAL.

  `dir` is resolved IN THE CALLER (never inside the watcher) and is always the
  explicitly requested directory, even when a running watcher watches a
  different one. A running watcher refreshes that directory through its own
  `handle_call/3` handler; when the target is `nil`, unregistered or the call
  exits (`:noproc`, `:timeout`, `:shutdown`, …) this returns `:ok` after
  running the SAME total reload the watcher's own event would run — so a dead,
  slow or absent watcher never fails, crashes or indefinitely blocks a save.

  Options:
    * `:watcher` — the registration to route through (default
      `EvoGit.Config.Watcher`); `nil` or an unregistered name falls back
    * `:timeout` — the bounded `GenServer.call/3` timeout (default 5_000 ms)
  """
  @spec notify_change(String.t() | nil, keyword()) :: :ok
  def notify_change(dir \\ nil, opts \\ []) do
    dir = dir || EvoGit.Config.config_dir()
    opts = if is_list(opts), do: opts, else: []
    watcher = Keyword.get(opts, :watcher, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @call_timeout)

    case resolve_target(watcher) do
      nil ->
        refresh(dir)
        :ok

      target ->
        case call_refresh(target, dir, timeout) do
          :ok ->
            :ok

          _other ->
            refresh(dir)
            :ok
        end
    end
  end

  @impl true
  def init(dir) do
    File.mkdir_p(dir)

    # Prime the snapshot once so the very first reader (the scheduler, the
    # dashboard) never pays the build on its own stack.
    EvoGit.Config.Cache.reload(dir: dir)

    case start_watcher(dir) do
      {:ok, pid} ->
        {:ok, %{dir: dir, worker: pid, timer: nil}}

      {:error, reason} ->
        Logger.warning(
          "Cannot watch config directory #{dir} (#{inspect(reason)}); " <>
            "config changes now require a save or explicit reload"
        )

        {:ok, %{dir: dir, worker: nil, timer: nil}}
    end
  end

  # The save event (`notify_change/2`) — the same refresh a file event runs.
  @impl true
  def handle_call({:config_changed, dir}, _from, state) do
    refresh(dir)
    {:reply, :ok, state}
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :unknown_request}, state}

  @impl true
  def handle_info({:file_event, pid, {path, _events}}, %{worker: pid} = state) do
    on_change(state, path)
  end

  def handle_info({:file_event, pid, :stop}, %{worker: pid} = state) do
    Logger.warning(
      "Config file watching stopped for #{state.dir}; " <>
        "config changes now require a save or explicit reload"
    )

    {:noreply, %{state | worker: nil, timer: nil}}
  end

  # A stale/unknown worker pid is ignored.
  def handle_info({:file_event, _pid, _event}, state), do: {:noreply, state}

  def handle_info(:reload, state) do
    refresh(state.dir)
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp on_change(state, path) when is_binary(path) do
    case Path.basename(path) do
      name when name in [@config_filename, @credentials_filename] ->
        {:noreply, schedule_reload(state)}

      @agents_filename ->
        reload_custom_agents()
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  defp on_change(state, _path), do: {:noreply, state}

  # Coalesced: one pending reload at a time, restarted by every event.
  defp schedule_reload(%{timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    %{state | timer: Process.send_after(self(), :reload, @debounce_ms)}
  end

  # The ONE snapshot reload: the debounced file event, the save event's
  # `handle_call/3` and `notify_change/2`'s fallback all converge here.
  defp refresh(dir), do: EvoGit.Config.Cache.reload_safely(dir: dir)

  defp resolve_target(nil), do: nil
  defp resolve_target(pid) when is_pid(pid), do: pid
  defp resolve_target(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_target(_other), do: nil

  # Any failure of the bounded call — a dead/restarting watcher (`:noproc`,
  # `:shutdown`), a slow one (`:timeout`) or an unexpected reply — is answered
  # by the caller's fallback, never propagated into the saving process.
  defp call_refresh(target, dir, timeout) do
    GenServer.call(target, {:config_changed, dir}, timeout)
  rescue
    error ->
      Logger.debug("Config watcher call failed for #{dir}: #{inspect(error)}; reloading directly")

      :error
  catch
    kind, reason ->
      Logger.debug(
        "Config watcher call failed for #{dir}: #{inspect({kind, reason})}; reloading directly"
      )

      :error
  end

  defp reload_custom_agents do
    EvoGit.CustomAgents.reload()
  rescue
    error ->
      Logger.warning("Failed to reload custom agents: #{inspect(error)}")
  catch
    kind, reason ->
      Logger.warning("Failed to reload custom agents: #{inspect({kind, reason})}")
  end

  # The file_system worker is LINKED, so a backend that dies later takes this
  # GenServer down with it and the supervisor restarts the watcher (re-priming
  # the snapshot and re-arm the watch).
  defp start_watcher(dir) do
    attempts = if macOS?(), do: [[dirs: [dir], latency: 0], [dirs: [dir]]], else: [[dirs: [dir]]]

    Enum.reduce_while(attempts, {:error, :no_attempt}, fn opts, _acc ->
      case try_start(opts) do
        {:ok, pid} -> {:halt, {:ok, pid}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp try_start(opts) do
    case FileSystem.start_link(opts) do
      {:ok, pid} ->
        case FileSystem.subscribe(pid) do
          :ok ->
            {:ok, pid}

          other ->
            # Don't leak a worker we cannot subscribe to.
            Process.unlink(pid)
            Process.exit(pid, :shutdown)
            {:error, other}
        end

      # `FileSystem.Worker.init/1` answers `:ignore` when the backend refuses
      # to start (e.g. `inotify-tools` missing).
      other ->
        {:error, other}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # `latency` is a macOS-only backend option; other backends log an error for
  # unknown options, so only macOS gets it.
  defp macOS?, do: :os.type() == {:unix, :darwin}
end
