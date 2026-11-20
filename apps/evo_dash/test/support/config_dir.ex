defmodule EvoDash.Test.ConfigDir do
  @moduledoc """
  Per-process isolation of the `~/.config/genesis` config directory for tests.

  This module is the `:evo_dash` MIRROR of `EvoGit.TestSupport.ConfigDir` (that
  file lives in `:evo_git`'s test-support dir, which is NOT on this app's
  compile path). It is the resolver behind the DEFAULT-INERT
  `:config_dir_fun` app-env seam of `EvoGit.Platform.config_dir/1`:
  `test/test_helper.exs` installs `{EvoDash.Test.ConfigDir, :resolve, []}` as
  `:config_dir_fun`, so every `EvoGit.Config.config_dir/0` call consults the
  CURRENT process (or one of its `$callers`) instead of the BEAM-global
  `XDG_CONFIG_HOME` env var. Production never sets `:config_dir_fun`, so
  production resolution stays byte-identical to the XDG/platform-directory
  behaviour.

  Both helpers use the SAME process-dictionary key (`:evogit_config_dir`), so an
  umbrella `mix test` that loads both apps' test helpers resolves identically
  whichever helper installed the fun last, and a module in either app can
  activate the override through either helper.

  ## `$callers` rule — what inherits the override

  `Process.get(:evogit_config_dir)` covers the process that called
  `activate/1`; every other process is resolved by walking the `:"$callers"`
  chain, which OTP 24+ `proc_lib` propagates from parent to child for
  `GenServer`/`Task`/`Supervisor` children started FROM the test process —
  including `Task.Supervisor.start_child/2` (the `EvoDash.SafeCall` async-load
  path). `Phoenix.LiveViewTest` additionally sets the mounted view's
  `:"$callers"` to the TEST pid explicitly
  (`deps/phoenix_live_view/lib/phoenix_live_view/channel.ex:1297`), so a mounted
  LiveView resolves the test's override AND so does every supervised load task
  the view spawns (the chain is view -> load task -> test pid).

  It does NOT cover:

    * processes with no caller chain back to the test — e.g. a raw `spawn/1`
      or `:proc_lib.spawn/1` (nothing propagates `$callers`), or a process
      started by a child that itself did not inherit one;
    * the app-global singletons started at BOOT — `EvoGit.AgentScheduler`,
      `EvoGit.TaskRegistry`, `EvoGit.Store`, `EvoGit.PeakHourEngine`. A module
      whose config reads happen INSIDE one of those (e.g. a `TaskRegistry` read
      worker, which the registry starts itself) must stay `async: false`,
      because there is no test-process ancestry to walk.

  The per-path `:persistent_term` config caches (`config.toml`,
  `version_state.toml`) are keyed by FILE PATH, so a unique directory per test
  is cache-safe.

  ## Cleanup invariant — drain supervised writers, then remove

  `File.rm_rf/1` on an isolated directory is safe only while no LIVE process can
  (re)create an entry under it. `EvoDash.TaskSupervisor` is app-global and never
  stops children per test, so an async load task spawned by a mounted view
  outlives its test process and, when it resolves `<override>/genesis` and
  writes a skeleton file, it `File.mkdir_p/1`s the whole tree back — which is
  what made the `on_exit` removal fail with `{:error, :eexist, _}` once every
  few thousand tests. Cleanup therefore runs in ONE order: wait for every live
  `EvoDash.TaskSupervisor` child that still carries the REGISTRAR pid in its
  `:"$callers"` chain (the pid is readable after the test process died, because
  it lives in the child's dictionary), and only then remove the directory.
  A `{:error, :eexist, _}` that survives that drain is retried a bounded number
  of times — the honest backstop for a re-creator whose caller chain identifies
  no registrar (a raw `spawn/1`, or a module-level `isolate_module!` directory
  whose registrar is the `setup_all` process, which appears in no child's
  chain) — and every OTHER error is raised through `File.rm_rf!/1`, exactly as
  before. Per-test `isolate!/1` is the fully covered path and the only one the
  suite uses.
  """

  # How long the `on_exit` drain may wait for the test's own supervised writers
  # before removing the directory anyway (the removal then still has the
  # bounded `@cleanup_attempts` retry below as its backstop).
  @cleanup_writer_budget_ms 5_000
  # Total directory-removal attempts, i.e. the first try plus two retries; each
  # retry re-drains first, so a writer that lands in between is awaited rather
  # than merely re-raced.
  @cleanup_attempts 3

  @doc """
  The seam function installed as `:config_dir_fun` by `test/test_helper.exs`.

  Returns the override directory for the current execution context, or `nil`.
  Order: this process' own override, then the first override found in a
  `$callers` process dictionary (local node pids only).
  """
  @spec resolve() :: String.t() | nil
  def resolve do
    case Process.get(:evogit_config_dir) do
      dir when is_binary(dir) ->
        dir

      _ ->
        Process.get(:"$callers", [])
        |> Enum.find_value(fn pid -> caller_override(pid) end)
    end
  end

  @doc """
  Puts the config directory override into the CURRENT process dictionary.

  Call this from a `setup` block so the TEST process carries the override
  (children started by the test inherit it through OTP's `$callers`
  propagation).
  """
  @spec activate(String.t()) :: String.t()
  def activate(dir) when is_binary(dir) do
    Process.put(:evogit_config_dir, dir)
    dir
  end

  @doc """
  Creates a unique temporary config directory for a whole test module.

  Intended for `setup_all`: registers an `on_exit` cleanup that removes the
  directory. It does NOT touch the process dictionary, because `setup_all` runs
  in a different process than the tests — call `activate/1` from `setup`
  instead (or use `isolate!/1`).
  """
  @spec isolate_module!(String.t()) :: String.t()
  def isolate_module!(prefix \\ "evogit_config") when is_binary(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    # The REGISTRAR is the process that owns this directory for cleanup
    # purposes: `isolate!/1` (the per-test path) registers it from the TEST
    # process, which is the pid every supervised load task of that test keeps in
    # its `:"$callers"` chain (see `await_supervised_writers/2`).
    registrar = self()
    ExUnit.Callbacks.on_exit(fn -> remove_isolated_dir!(dir, registrar) end)
    dir
  end

  @doc """
  Waits (bounded, monitor-based) for every live `EvoDash.TaskSupervisor` child
  whose `:"$callers"` chain still contains `registrar`, then returns.

  This is the ordering guarantee behind the `on_exit` cleanup. ExUnit ends the
  test process BEFORE any `on_exit` callback runs, but
  `Task.Supervisor.start_child/2` records the spawning process' whole caller
  chain in the CHILD's process dictionary, so the already-dead test pid stays
  readable there. A child that outlives its test — the shared
  `EvoDash.TaskSupervisor` never stops children per test — can still resolve
  `<override>/genesis` and recreate it (`File.mkdir_p/1` plus a write, e.g. an
  async page load's `EvoGit.RemoteConnections.list/0` skeleton), so removing the
  directory while that child is in flight races the recreation and fails with
  `{:error, :eexist, _}`.

  Returns `:ok` once no matching child is alive, or `:timeout` when the budget
  elapses first. The re-scan after every wait is deliberate: a still-live view
  may spawn another load task while the first one drains.
  """
  @spec await_supervised_writers(pid(), non_neg_integer()) :: :ok | :timeout
  def await_supervised_writers(registrar, budget_ms \\ @cleanup_writer_budget_ms)
      when is_pid(registrar) and is_integer(budget_ms) and budget_ms >= 0 do
    drain_supervised_writers(registrar, System.monotonic_time(:millisecond) + budget_ms)
  end

  @doc """
  Creates a unique temporary config directory AND activates it for the current
  (per-test) process. Returns the directory.

  Convenience for a plain `setup` block: `EvoDash.Test.ConfigDir.isolate!/1`.
  """
  @spec isolate!(String.t()) :: String.t()
  def isolate!(prefix \\ "evogit_config") when is_binary(prefix) do
    prefix |> isolate_module!() |> activate()
  end

  @doc """
  Resolves the concrete config directory the CALLING process would use.

  Convenience for assertions that need the real path rather than the override
  root: with an override active this is `<override>/genesis` (via
  `EvoGit.Platform.config_dir/0`), otherwise the platform/XDG directory.
  """
  @spec config_dir() :: String.t()
  def config_dir, do: EvoGit.Platform.config_dir()

  # Looks up a single caller's process dictionary. `Process.info/2` returns
  # `nil` for a dead pid, so that case falls through to the next caller.
  defp caller_override(pid) when is_pid(pid) do
    if node(pid) == node() do
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> Keyword.get(dict, :evogit_config_dir)
        nil -> nil
      end
    end
  end

  defp caller_override(_), do: nil

  # ── cleanup: drain the test's supervised writers, then remove ────────────
  #
  # `await_supervised_writers/2`'s loop: wait for the matching writers, then
  # RE-SCAN, because a still-live view can spawn another load task while the
  # previous one exits. Total time is bounded by the caller's budget.
  defp drain_supervised_writers(registrar, deadline) do
    case supervised_writer_pids(registrar) do
      [] ->
        :ok

      pids ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          :timeout
        else
          await_down(pids, remaining)
          drain_supervised_writers(registrar, deadline)
        end
    end
  end

  # The LIVE `EvoDash.TaskSupervisor` children that still list `registrar` in
  # their `:"$callers"` chain. Total: a missing supervisor yields no writers, and
  # a child whose dictionary is already gone (exited between the listing and this
  # read) is simply not a writer any more.
  defp supervised_writer_pids(registrar) do
    case Process.whereis(EvoDash.TaskSupervisor) do
      nil ->
        []

      _supervisor ->
        EvoDash.TaskSupervisor
        |> Task.Supervisor.children()
        |> Enum.filter(&held_by?(&1, registrar))
    end
  end

  defp held_by?(pid, registrar) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> registrar in Keyword.get(dictionary, :"$callers", [])
      nil -> false
    end
  end

  defp held_by?(_pid, _registrar), do: false

  # Monitors every pid and waits for its DOWN signal, sharing ONE deadline so a
  # long-lived first writer cannot extend the budget of the rest. A pid that is
  # already dead delivers `:DOWN` immediately.
  defp await_down(pids, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    monitors = Enum.map(pids, fn pid -> {Process.monitor(pid), pid} end)
    Enum.each(monitors, fn {ref, _pid} -> await_down_message(ref, deadline) end)
    Enum.each(monitors, fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)
    :ok
  end

  defp await_down_message(ref, deadline) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> :ok
    end
  end

  # The registered `on_exit` cleanup. Drain FIRST (the invariant the moduledoc
  # states), then remove; a racing re-creation that survives the drain
  # (`{:error, :eexist, _}`) is retried a bounded number of times, and every
  # other error is raised by `File.rm_rf!/1` so a real failure still fails the
  # test loudly instead of being swallowed.
  defp remove_isolated_dir!(dir, registrar, attempts \\ @cleanup_attempts)

  defp remove_isolated_dir!(dir, registrar, attempts) do
    _ = await_supervised_writers(registrar)

    case File.rm_rf(dir) do
      {:ok, _removed} ->
        :ok

      {:error, :eexist, _path} when attempts > 1 ->
        remove_isolated_dir!(dir, registrar, attempts - 1)

      {:error, _reason, _path} ->
        File.rm_rf!(dir)
    end
  end
end
