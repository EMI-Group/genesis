defmodule EvoGit.SandboxProcessRegistry do
  @moduledoc """
  Dedicated GenServer that monitors caller processes for sandboxed systemd-run
  commands. When a caller process dies (crash, kill, timeout), the orphaned
  `.service` unit is stopped asynchronously via systemctl.
  """

  use GenServer
  require Logger

  @mix_env Mix.env()

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generates a unique unit name and sets up a `Process.monitor` on the calling
  process. Returns the unit name string.

  Synchronous call — the caller is guaranteed to be registered before the
  systemd-run command starts.
  """
  @spec register() :: String.t()
  def register do
    GenServer.call(__MODULE__, :register)
  end

  @doc """
  Unregisters a unit after normal completion.

  Fire-and-forget cast: demonitors the caller and removes the entry.
  Safe no-op for non-existent units.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(unit_name) do
    GenServer.cast(__MODULE__, {:unregister, unit_name})
    :ok
  end

  @doc """
  Unregisters a unit and spawns an async Task to stop the orphaned service.

  Used for timeout/abandon scenarios: the `.service` unit survives
  `Task.shutdown/1`, so it must be explicitly stopped via systemctl. The stop
  runs in a spawned Task so the registry is never blocked.

  Fire-and-forget cast. Safe no-op for non-existent units.
  """
  @spec release(String.t()) :: :ok
  def release(unit_name) do
    GenServer.cast(__MODULE__, {:release, unit_name})
    :ok
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call(:register, {caller_pid, _tag}, state) do
    unit_name = generate_unit_name()
    ref = Process.monitor(caller_pid)
    new_state = Map.put(state, unit_name, %{pid: caller_pid, ref: ref})
    {:reply, unit_name, new_state}
  end

  @impl true
  def handle_cast({:unregister, unit_name}, state) do
    new_state = demonitor_and_delete(state, unit_name)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:release, unit_name}, state) do
    new_state = demonitor_and_delete(state, unit_name)

    # Non-blocking cleanup of the orphaned service
    if sandbox_enabled?(), do: Task.start(fn -> stop_unit(unit_name) end)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state, fn {_unit, %{ref: r}} -> r == ref end) do
      {unit_name, _} ->
        # Spawn a Task so the registry is never blocked by systemctl
        if sandbox_enabled?(), do: Task.start(fn -> stop_unit(unit_name) end)
        {:noreply, Map.delete(state, unit_name)}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if sandbox_enabled?() do
      # Defense-in-depth: stop each registered unit individually.
      # The primary cleanup is SandboxSlice's terminate (stops the entire slice),
      # but individual stops provide belt-and-suspenders coverage.
      Enum.each(state, fn {unit_name, _} -> stop_unit(unit_name) end)
    end

    :ok
  end

  # --- Private helpers ---

  defp demonitor_and_delete(state, unit_name) do
    case Map.get(state, unit_name) do
      %{ref: ref} ->
        Process.demonitor(ref, [:flush])
        Map.delete(state, unit_name)

      nil ->
        state
    end
  end

  defp generate_unit_name do
    ts = System.system_time(:millisecond) |> Integer.to_string()
    unique = System.unique_integer([:positive]) |> Integer.to_string()
    "evogit-run-#{ts}-#{unique}"
  end

  defp stop_unit(unit_name) do
    unit =
      if String.ends_with?(unit_name, ".service"), do: unit_name, else: "#{unit_name}.service"

    case system_cmd("systemctl", ["--user", "stop", unit]) do
      {:ok, _} ->
        Logger.debug("SandboxProcessRegistry: Stopped orphaned unit '#{unit}'")

      {:error, output} ->
        Logger.warning(
          "SandboxProcessRegistry: Failed to stop unit '#{unit}': #{String.trim(output)}"
        )
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
