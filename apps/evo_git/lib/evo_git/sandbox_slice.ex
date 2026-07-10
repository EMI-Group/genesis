defmodule EvoGit.SandboxSlice do
  @moduledoc """
  GenServer managing the lifecycle of the `evogit.slice` systemd user slice.

  All sandboxed commands run inside this shared slice, so resource limits
  (CPU, memory, tasks) apply to the aggregate of all processes rather than
  per-process. The slice is created lazily on first use and cleaned up on
  application shutdown.

  Resource limits can be configured via:
  1. TOML config: `[sandbox.resources]` section
  2. Runtime override: `AgentScheduler.update_config/1` with sandbox keys
  """

  use GenServer
  require Logger

  @slice_name "evogit"

  # Compile-time Mix env — safe in releases (Mix.env/0 is evaluated at compile
  # time; in prod releases it resolves to :prod). Used to skip systemd slice
  # creation entirely in the test environment.
  @mix_env Mix.env()

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures the slice exists and is running. Creates it lazily if needed.
  Called before each sandbox_run invocation.
  """
  @spec ensure_slice() :: :ok | {:error, term()}
  def ensure_slice do
    GenServer.call(__MODULE__, :ensure_slice, 10_000)
  end

  @doc """
  Updates resource limits on the running slice.
  Accepts a map with keys: cpu_weight, memory_max, tasks_max.
  """
  @spec update_resources(map()) :: :ok | {:error, term()}
  def update_resources(resources) when is_map(resources) do
    GenServer.call(__MODULE__, {:update_resources, resources}, 10_000)
  end

  @doc """
  Returns the current resource configuration.
  """
  @spec get_resources() :: map()
  def get_resources do
    GenServer.call(__MODULE__, :get_resources)
  end

  @doc """
  Stops and cleans up the slice. Called on application shutdown.
  """
  @spec stop_slice() :: :ok
  def stop_slice do
    GenServer.call(__MODULE__, :stop_slice, 10_000)
  end

  @doc """
  Registers a sandbox run for process-lifetime monitoring.

  Sets up a `Process.monitor` on `caller_pid` BEFORE the systemd-run command
  starts, so a caller crash mid-tool-call triggers immediate cleanup of the
  orphaned `.service` unit. The monitor is torn down via `unregister_run/1`
  when the command completes normally.
  """
  @spec register_run(String.t(), pid()) :: :ok
  def register_run(unit_name, caller_pid) do
    GenServer.call(__MODULE__, {:register_run, unit_name, caller_pid})
  end

  @doc """
  Unregisters a sandbox run after normal completion.

  Fire-and-forget cast: demonitors the caller and removes the run entry.
  """
  @spec unregister_run(String.t()) :: :ok
  def unregister_run(unit_name) do
    GenServer.cast(__MODULE__, {:unregister_run, unit_name})
    :ok
  end

  @doc """
  Stops a specific systemd unit by name.

  Used for timeout cleanup: when a sandboxed command exceeds its timeout,
  this kills the `.service` unit that survives `Task.shutdown/1`. The
  `unit_name` may or may not include the `.service` suffix.
  """
  @spec stop_run(String.t()) :: :ok
  def stop_run(unit_name) do
    GenServer.call(__MODULE__, {:stop_run, unit_name})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    # SandboxSlice is Linux/systemd-specific — no-op on other platforms
    if not EvoGit.Platform.linux?() do
      {:ok, %{slice_active: false, resources: %{}, runs: %{}}}
    else
      # Load initial resource config from TOML config
      resources = load_config_resources()

      state = %{
        slice_active: false,
        resources: resources,
        runs: %{}
      }

      # If sandbox is enabled, create the slice eagerly (fail fast)
      cleanup_stale_services()

      state =
        if sandbox_enabled?() do
          case do_create_slice(resources) do
            :ok ->
              %{state | slice_active: true}

            {:error, reason} ->
              Logger.warning("SandboxSlice: Failed to create slice on init: #{inspect(reason)}")
              state
          end
        else
          state
        end

      {:ok, state}
    end
  end

  @impl true
  def handle_call(:ensure_slice, _from, %{slice_active: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:ensure_slice, _from, state) do
    if sandbox_enabled?() do
      case do_create_slice(state.resources) do
        :ok ->
          {:reply, :ok, %{state | slice_active: true}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:update_resources, resources}, _from, state) do
    new_state = %{state | resources: resources}

    result =
      if state.slice_active do
        do_update_slice_properties(resources)
      else
        :ok
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:get_resources, _from, state) do
    {:reply, state.resources, state}
  end

  @impl true
  def handle_call(:stop_slice, _from, state) do
    if state.slice_active do
      do_stop_slice()
    end

    {:reply, :ok, %{state | slice_active: false}}
  end

  @impl true
  def handle_call({:register_run, unit_name, caller_pid}, _from, state) do
    ref = Process.monitor(caller_pid)
    new_runs = Map.put(state.runs, unit_name, %{pid: caller_pid, ref: ref})
    {:reply, :ok, %{state | runs: new_runs}}
  end

  @impl true
  def handle_call({:stop_run, unit_name}, _from, state) do
    do_stop_unit(unit_name)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:unregister_run, unit_name}, state) do
    new_runs =
      case Map.get(state.runs, unit_name) do
        %{ref: ref} ->
          Process.demonitor(ref, [:flush])
          Map.delete(state.runs, unit_name)

        nil ->
          state.runs
      end

    {:noreply, %{state | runs: new_runs}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # A monitored caller process died — find its unit and stop the orphaned service.
    case Enum.find(state.runs, fn {_unit, %{ref: r}} -> r == ref end) do
      {unit_name, _} ->
        do_stop_unit(unit_name)
        {:noreply, %{state | runs: Map.delete(state.runs, unit_name)}}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.slice_active do
      do_stop_slice()
    end

    :ok
  end

  # --- Private Implementation ---

  defp load_config_resources do
    EvoGit.Config.resolve([:sandbox, :resources])
  end

  defp cleanup_stale_services do
    # Stop the entire slice — kills any leftover services from a previous
    # BEAM VM crash. If the slice doesn't exist, systemctl returns non-zero
    # which we ignore (the error is harmless).
    _ = system_cmd("systemctl", ["--user", "stop", "#{@slice_name}.slice"])
    # Brief delay to let systemd actually clean up before we recreate the slice.
    :timer.sleep(100)
    :ok
  end

  defp do_stop_unit(unit_name) do
    unit =
      if String.ends_with?(unit_name, ".service"), do: unit_name, else: "#{unit_name}.service"

    case system_cmd("systemctl", ["--user", "stop", unit]) do
      {:ok, _} ->
        Logger.debug("SandboxSlice: Stopped orphaned unit '#{unit}'")

      {:error, output} ->
        Logger.warning("SandboxSlice: Failed to stop unit '#{unit}': #{String.trim(output)}")
    end
  end

  defp sandbox_enabled? do
    cond do
      # Tests never need systemd sandboxing, and the user bus is typically
      # unavailable in CI/local test environments. Skip slice creation.
      @mix_env == :test ->
        false

      true ->
        case EvoGit.Config.resolve([:sandbox, :mode]) do
          :enabled -> true
          :disabled -> false
          :auto -> EvoGit.Platform.systemd_available?()
        end
    end
  end

  defp do_create_slice(resources) do
    args =
      [
        "--user",
        "--slice=#{@slice_name}",
        "--scope",
        "--collect",
        "-q"
      ] ++ ["true"]

    case system_cmd("systemd-run", args) do
      {:ok, _output} ->
        # Now set the resource properties on the slice itself
        case do_update_slice_properties(resources) do
          :ok ->
            Logger.info("SandboxSlice: Created slice '#{@slice_name}' with resource limits")
            :ok

          {:error, reason} ->
            Logger.warning(
              "SandboxSlice: Slice created but failed to set properties: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, output} ->
        {:error, String.trim(output)}
    end
  end

  defp do_update_slice_properties(resources) do
    property_args = resource_properties(resources)

    # systemctl --user set-property evogit.slice CPUWeight=30 ...
    args = ["--user", "set-property", "#{@slice_name}.slice"] ++ property_args

    case system_cmd("systemctl", args) do
      {:ok, _output} ->
        Logger.info("SandboxSlice: Updated resource limits on slice '#{@slice_name}'")
        :ok

      {:error, output} ->
        Logger.warning("SandboxSlice: Failed to update slice properties: #{String.trim(output)}")
        {:error, String.trim(output)}
    end
  end

  defp do_stop_slice do
    # Stop the slice and all services/scopes within it.
    # This runs during application shutdown (terminate/2 callback), so
    # failures are logged and swallowed — we cannot meaningfully recover.
    args = ["--user", "stop", "#{@slice_name}.slice"]

    case system_cmd("systemctl", args) do
      {:ok, _output} ->
        Logger.info("SandboxSlice: Stopped and cleaned up slice '#{@slice_name}'")
        :ok

      {:error, output} ->
        Logger.warning("SandboxSlice: Failed to stop slice: #{String.trim(output)}")
        :ok
    end
  end

  defp resource_properties(resources) do
    props = []

    props =
      case Map.get(resources, :cpu_quota) do
        nil -> props
        v -> props ++ ["CPUQuota=#{v}"]
      end

    props =
      case Map.get(resources, :cpu_weight) do
        nil -> props
        v -> props ++ ["CPUWeight=#{v}"]
      end

    props =
      case Map.get(resources, :memory_max) do
        nil -> props
        v -> props ++ ["MemoryMax=#{v}"]
      end

    props =
      case Map.get(resources, :tasks_max) do
        nil -> props
        v -> props ++ ["TasksMax=#{v}"]
      end

    props
  end

  # Runs a System.cmd and normalizes the result into {:ok, output} | {:error, output}.
  # System.cmd raises ErlangError(:enoent) when the binary is missing;
  # we pre-check executability to avoid the exception.
  defp system_cmd(cmd, args) do
    if System.find_executable(cmd) do
      case System.cmd(cmd, args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _code} -> {:error, output}
      end
    else
      {:error, "command not found: #{cmd}"}
    end
  end
end
