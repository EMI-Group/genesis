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

  alias EvoGit.Sandbox.Helpers

  @slice_name "evogit"

  # Compile-time Mix env — safe in releases (Mix.env/0 is evaluated at compile
  # time; in prod releases it resolves to :prod). Used to skip systemd slice
  # creation entirely in the test environment.
  @mix_env Mix.env()

  # Hard bound for systemctl property-update subprocesses. A wedged systemd
  # user bus must never block the SandboxSlice GenServer (and thus every
  # ensure_slice/update_resources caller) indefinitely. Overridable at runtime
  # via the app-env seam :sandbox_slice_systemctl_timeout_ms (read per call).
  @systemctl_timeout_ms 5_000

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
  Fire-and-forget update of resource limits on the running slice.

  Like `update_resources/1` but non-blocking: the update is enqueued as a cast
  and applied asynchronously by the SandboxSlice GenServer (which logs its own
  successes/failures, so errors remain visible). Intended for callers that must
  never block on slice work — notably the `AgentScheduler` config-update path.

  Never raises: when the SandboxSlice GenServer is not running the update is
  silently dropped and `:ok` is returned. Property updates are idempotent
  last-write-wins, so an async update converges even if a later update
  overwrites it before the slice applies this one.
  """
  @spec update_resources_async(map()) :: :ok
  def update_resources_async(resources) when is_map(resources) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        GenServer.cast(pid, {:update_resources, resources})
        :ok
    end
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

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    # SandboxSlice is Linux/systemd-specific — no-op on other platforms
    if not EvoGit.Platform.linux?() do
      {:ok, %{slice_active: false, resources: %{}}}
    else
      # Load initial resource config from TOML config
      resources = load_config_resources()

      state = %{
        slice_active: false,
        resources: resources
      }

      state =
        if sandbox_enabled?() do
          # Clean up any stale services from a previous BEVM VM crash before
          # recreating the slice. Only meaningful when we're about to create one.
          cleanup_stale_services()

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
  def handle_cast({:update_resources, resources}, state) do
    new_state = %{state | resources: resources}

    # Fire-and-forget property update. do_update_slice_properties/1 logs its
    # own success/failure (bounded — it can never block this GenServer past
    # the systemctl timeout), so no result is surfaced to the caller.
    if state.slice_active do
      do_update_slice_properties(resources)
    end

    {:noreply, new_state}
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
    _ = Helpers.system_cmd("systemctl", ["--user", "stop", "#{@slice_name}.slice"])
    # Brief delay to let systemd actually clean up before we recreate the slice.
    :timer.sleep(100)
    :ok
  end

  defp sandbox_enabled? do
    cond do
      # Tests never need systemd sandboxing, and the user bus is typically
      # unavailable in CI/local test environments. Skip slice creation.
      @mix_env == :test ->
        false

      # Only the systemd backend manages the slice — a bwrap backend on a
      # systemd host must never create `evogit.slice`.
      EvoGit.Sandbox.backend() != EvoGit.Sandbox.Linux ->
        false

      true ->
        Helpers.sandbox_mode_enabled?(&EvoGit.Platform.systemd_available?/0)
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

    case Helpers.system_cmd("systemd-run", args) do
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

    # Bounded execution: a wedged systemd user bus must never block the
    # SandboxSlice GenServer (and thus every ensure_slice/update_resources
    # caller) indefinitely. On timeout the client-side systemctl is killed —
    # safe: set-property is a single DBus invocation, last-write-wins, no
    # partial-limit corruption.
    case run_systemctl_bounded("systemctl", args, systemctl_timeout_ms()) do
      {:ok, _output} ->
        Logger.info("SandboxSlice: Updated resource limits on slice '#{@slice_name}'")
        :ok

      {:error, :timeout} ->
        Logger.warning(
          "SandboxSlice: Timed out after #{systemctl_timeout_ms()}ms updating slice properties; " <>
            "systemctl may be unresponsive"
        )

        {:error, :timeout}

      {:error, output} when is_binary(output) ->
        Logger.warning("SandboxSlice: Failed to update slice properties: #{String.trim(output)}")
        {:error, String.trim(output)}

      {:error, other} ->
        Logger.warning("SandboxSlice: Failed to update slice properties: #{inspect(other)}")
        {:error, other}
    end
  end

  # Runs a `systemctl`-style command through `runner` with a hard time bound.
  #
  # The runner executes in a separate (unlinked, monitored) process so a wedged
  # systemd user bus can never block the SandboxSlice GenServer — or any
  # caller — indefinitely. When `timeout_ms` elapses without a result, the
  # runner process is killed; killing it closes its OS ports, terminating the
  # client-side subprocess.
  #
  # The default runner is `EvoGit.Sandbox.Helpers.system_cmd/2`, overridable
  # per call via `runner` (tests inject slow/failing fns) or via the app-env
  # seam `:sandbox_slice_systemctl_fun` (read at call time by the default).
  #
  # Returns whatever `runner` returns (`{:ok, output}` | `{:error, output}`),
  # `{:error, :timeout}` when the bound elapses, or
  # `{:error, {:runner_crashed, reason}}` when the runner process dies.
  #
  # `@doc false`: public only so tests can drive the bounded-runner behavior
  # directly with tiny timeouts; an implementation detail of the slice
  # lifecycle.
  @doc false
  @spec run_systemctl_bounded(
          String.t(),
          [String.t()],
          non_neg_integer(),
          (String.t(), [String.t()] -> {:ok, String.t()} | {:error, String.t()})
        ) :: {:ok, String.t()} | {:error, term()}
  def run_systemctl_bounded(cmd, args, timeout_ms, runner \\ default_systemctl_runner()) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        # Rescue/catch inside the runner process: a raised exception becomes a
        # normal `{:error, {:runner_crashed, e}}` result (delivered as a
        # message) instead of a noisy uncaught-exception crash report. The
        # monitor below still catches uncatchable exits (e.g. a runner calling
        # `Process.exit(self(), :kill)`).
        result =
          try do
            runner.(cmd, args)
          rescue
            e -> {:error, {:runner_crashed, e}}
          catch
            kind, reason -> {:error, {:runner_crashed, {kind, reason}}}
          end

        send(parent, {ref, result})
      end)

    mon_ref = Process.monitor(pid)

    receive do
      {^ref, result} ->
        Process.demonitor(mon_ref, [:flush])
        result

      {:DOWN, ^mon_ref, :process, ^pid, reason} ->
        {:error, {:runner_crashed, reason}}
    after
      timeout_ms ->
        Process.demonitor(mon_ref, [:flush])
        Process.exit(pid, :kill)

        # The runner may have completed just as the deadline fired — drain any
        # straggler reply so the caller's mailbox stays clean and a genuine
        # result wins over a spurious timeout.
        receive do
          {^ref, result} -> result
        after
          0 -> {:error, :timeout}
        end
    end
  end

  defp default_systemctl_runner do
    Application.get_env(:evo_git, :sandbox_slice_systemctl_fun, &Helpers.system_cmd/2)
  end

  defp systemctl_timeout_ms do
    Application.get_env(:evo_git, :sandbox_slice_systemctl_timeout_ms, @systemctl_timeout_ms)
  end

  defp do_stop_slice do
    # Stop the slice and all services/scopes within it.
    # This runs during application shutdown (terminate/2 callback), so
    # failures are logged and swallowed — we cannot meaningfully recover.
    args = ["--user", "stop", "#{@slice_name}.slice"]

    case Helpers.system_cmd("systemctl", args) do
      {:ok, _output} ->
        Logger.info("SandboxSlice: Stopped and cleaned up slice '#{@slice_name}'")
        :ok

      {:error, output} ->
        Logger.warning("SandboxSlice: Failed to stop slice: #{String.trim(output)}")
        :ok
    end
  end

  defp resource_properties(resources) do
    for {key, prop} <- [
          {:cpu_quota, "CPUQuota"},
          {:cpu_weight, "CPUWeight"},
          {:memory_max, "MemoryMax"},
          {:tasks_max, "TasksMax"}
        ],
        value = Map.get(resources, key),
        not is_nil(value),
        do: "#{prop}=#{value}"
  end
end
