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

  ## Uniqueness invariant — unique across BEAMs, not merely within one

  A directory name is `<prefix>-<os pid>-<unique int>-<random>`. The OS pid and
  the random component are LOAD-BEARING, not decoration:
  `System.unique_integer/1` is unique only WITHIN one BEAM — every VM restarts
  that monotonic counter at the same offset — so two identical `mix test` runs
  sharing one `TMPDIR` (every Genesis worker task has ONE per-task `TMPDIR`, and
  an orchestrator runs suites concurrently) generate the SAME
  `<prefix>-<int>` path. Each run's `on_exit` then removes the OTHER run's LIVE
  config directory mid-test, which surfaces as
  `** (File.Error) could not read ".../genesis/config.toml"` in a test that has
  done nothing wrong. This is the same hazard the vendored-git temp-file naming
  documents (`apps/evo_git/lib/evo_git/adapters/CONTEXT.md`: "Temp-file names
  MUST carry the OS pid"), and `test/test_helper.exs`'s boot fallback config dir
  (`genesis-<os pid>-<unique int>`) already carries it for exactly this reason.
  The random component additionally covers OS-pid reuse across a long-lived run
  and a stale leftover directory from an interrupted run.

  ## Cleanup invariant — drain supervised writers, then remove

  `File.rm_rf/1` on an isolated directory is safe only while no LIVE process can
  (re)create an entry under it. `EvoDash.TaskSupervisor` is app-global and never
  stops children per test, so an async load task spawned by a mounted view
  outlives its test process and, when it resolves `<override>/genesis` and
  writes a skeleton file, it `File.mkdir_p/1`s the whole tree back — which is
  what makes a bare `on_exit` removal fail with `{:error, :eexist, _}` (the
  listing is complete, the `rmdir` is not). Cleanup therefore runs in ONE order:
  wait for every live `EvoDash.TaskSupervisor` child that is a writer FOR THIS
  DIRECTORY, and only then remove it.

  This module is the directory's ONLY cleanup owner: `isolate!/1` and
  `isolate_module!/1` register the drain-backed removal, so a suite must NOT
  register its own second `File.rm_rf!/1` (an earlier LIFO callback with no
  drain is exactly the race this contract exists to prevent).

  A child is a writer for `dir` when ANY of these holds:

    * it still carries the REGISTRAR pid in its `:"$callers"` chain (the pid is
      readable after the test process died, because it lives in the child's
      dictionary) — the per-test `isolate!/1` case; or
    * its own dictionary / caller chain RESOLVES `dir` as its config-dir
      override (every pid in that chain must still be ALIVE for a dictionary
      read to answer); or
    * its `:"$callers"` chain names a pid that ever ACTIVATED `dir` through
      `activate/1` — the owner marker. A pid VALUE stays readable in the child's
      dictionary after its process died, so this is the case that makes a
      `setup_all`-created directory exactly as safe as a per-test one: the
      `setup_all` registrar appears in no child's chain, but every test that
      used the directory does appear there (through its view / load task) and is
      remembered on disk instead of in a dictionary that dies with it.

  The removal itself is `EvoDash.Test.FsCleanup.rm_rf!/2` — a bounded DEADLINE
  that re-drains (with the remaining window) before every attempt and retries
  both transient races (`:eexist`, `:enotempty`) instead of re-raising on a
  fixed attempt count. That is the honest backstop for a re-creator whose caller
  chain identifies no registrar AND resolves no override (a raw `spawn/1`), and
  for a matched writer that is merely starved for longer than one drain. A tree
  that genuinely cannot be removed still raises `File.Error` (logged with its
  residual entries), so a real failure never gets swallowed.
  """

  alias EvoDash.Test.FsCleanup

  # Default budget of ONE drain (the public `await_*_writers` helpers use it).
  # The teardown removal passes its own REMAINING window instead, so a matched
  # writer that is merely starved is not abandoned at this mark.
  @cleanup_writer_budget_ms 5_000
  # Overall teardown window for draining the directory's writers AND removing
  # the tree. It is a DEADLINE, not an attempt count: a re-creator that is slow
  # but alive (a starved page-load child) is waited for rather than re-raced,
  # and the window is paid only when a writer actually loses the race — the
  # healthy path is one drain that finds nobody plus one `File.rm_rf/1`.
  @cleanup_budget_ms 10_000
  # Cadence between removal attempts (the writer needs to be scheduled, not
  # waited out); see `EvoDash.Test.FsCleanup`.
  @cleanup_retry_delay_ms 20
  # A drain that had to WAIT longer than this is a defect, not a slow machine:
  # the test left a supervised child that only ended by TIMING OUT (a stub's own
  # safety `after`, a `GenServer.call`'s timeout, a wedged app-global server), so
  # its cost is paid serially in `on_exit` and is INVISIBLE to ExUnit's per-test
  # times. The healthy suite's largest drain is a first-load `code_server` call
  # of ~100 ms, so this stays silent unless something regressed; two monotonic
  # clock reads per drain are the whole hot-path cost.
  @drain_alarm_ms 1_000

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

  It ALSO records the calling pid as an OWNER of `dir` (one marker file under
  `<dir>/.evodash-owners/`, see `await_dir_writers/3`). That is what lets a
  `setup_all`-created directory (`isolate_module!/1` + `activate/1` per test) be
  drained as safely as a per-test one: a marker file outlives the pid, while a
  dead pid's process dictionary does not.
  """
  @spec activate(String.t()) :: String.t()
  def activate(dir) when is_binary(dir) do
    Process.put(:evogit_config_dir, dir)
    record_owner(dir, self())
    dir
  end

  @doc """
  Creates a unique temporary config directory for a whole test module.

  Intended for `setup_all`: registers the ONLY `on_exit` cleanup that removes
  the directory (drain-backed, deadline-bounded — a caller must NOT register a
  second `File.rm_rf!/1`). It does NOT touch the process dictionary, because
  `setup_all` runs in a different process than the tests — call `activate/1`
  from `setup` instead (or use `isolate!/1`).
  """
  @spec isolate_module!(String.t()) :: String.t()
  def isolate_module!(prefix \\ "evogit_config") when is_binary(prefix) do
    dir = Path.join(System.tmp_dir!(), unique_dir_name(prefix))

    File.mkdir_p!(dir)
    # The REGISTRAR is the process that owns this directory for cleanup
    # purposes: `isolate!/1` (the per-test path) registers it from the TEST
    # process, which is the pid every supervised load task of that test keeps in
    # its `:"$callers"` chain (see `await_supervised_writers/2`). For a
    # `setup_all`-created module-level directory the registrar appears in no
    # child's chain, so the removal ALSO drains by DESTINATION — a child that
    # resolves the directory as its override, or names a pid that activated it
    # through `activate/1` (see `await_dir_writers/3`).
    registrar = self()
    ExUnit.Callbacks.on_exit(fn -> remove_isolated_dir!(dir, registrar) end)
    dir
  end

  # A directory name that is unique across every BEAM on the host, not merely
  # within this one. `System.unique_integer/1` alone is NOT enough: each VM
  # restarts that counter at the same offset, so two identical `mix test` runs
  # sharing one `TMPDIR` (every Genesis worker task owns ONE per-task TMPDIR and
  # an orchestrator runs suites concurrently) compute the SAME
  # `<prefix>-<int>` path, and each run's cleanup removes the other run's LIVE
  # directory — the `File.Error` on `config.toml` this module must never cause.
  # The OS pid separates concurrent VMs (the same fix the vendored-git temp-file
  # naming already documents), and the random component also covers OS-pid reuse
  # and a stale directory left by an interrupted run. `:rand` is per-process
  # seeded by the VM, needs no application start and costs nanoseconds.
  defp unique_dir_name(prefix) do
    random = String.downcase(Integer.to_string(:rand.uniform(4_294_967_296) - 1, 16))
    "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}-#{random}"
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
    drain_supervised_writers(
      fn pid -> held_by?(pid, registrar) end,
      System.monotonic_time(:millisecond) + budget_ms
    )
  end

  @doc """
  Waits (bounded, monitor-based) for every live `EvoDash.TaskSupervisor` child
  that could write into `dir`, then returns.

  A writer is a child that carries `registrar` in its `:"$callers"` chain
  (`await_supervised_writers/2`'s per-test contract), OR resolves `dir` as its
  config-dir override, OR names a pid that `activate/1` recorded as an owner of
  `dir` — the last two are the DESTINATION-based predicates that cover a
  directory created by a `setup_all` process, whose registrar appears in no
  child's chain. This is what the `on_exit` cleanup uses, so a module-level
  `isolate_module!/1` directory is exactly as safe as a per-test `isolate!/1`
  one: no live child can be writing into `<dir>/genesis` when the removal
  starts.
  """
  @spec await_dir_writers(pid(), String.t(), non_neg_integer()) :: :ok | :timeout
  def await_dir_writers(registrar, dir, budget_ms \\ @cleanup_writer_budget_ms)
      when is_pid(registrar) and is_binary(dir) and is_integer(budget_ms) and
             budget_ms >= 0 do
    owners = owner_pids(dir)

    drain_supervised_writers(
      fn pid -> writer_for?(pid, registrar, dir, owners) end,
      System.monotonic_time(:millisecond) + budget_ms
    )
  end

  @doc """
  Creates a unique temporary config directory AND activates it for the current
  (per-test) process. Returns the directory.

  Convenience for a plain `setup` block: `EvoDash.Test.ConfigDir.isolate!/1`.

  It deliberately does NOT go through `activate/1`'s owner registry: here the
  registrar IS the calling (test) process, whose pid every child of the test
  keeps in its `:"$callers"` chain, so the ownership predicate already covers
  every writer this directory can have. Skipping the marker keeps the per-test
  hot path free of file I/O.
  `isolate_module!/1` registers the directory's ONLY `on_exit` cleanup (the
  drain-backed, deadline-bounded removal), so calling this from a `setup` block
  needs no `on_exit` of its own — and adding one would reintroduce the very
  race the drain prevents.
  """
  @spec isolate!(String.t()) :: String.t()
  def isolate!(prefix \\ "evogit_config") when is_binary(prefix) do
    dir = isolate_module!(prefix)
    Process.put(:evogit_config_dir, dir)
    dir
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

  # ── cleanup: drain the directory's supervised writers, then remove ───────
  #
  # The loop: wait for the writers `match?` accepts, then RE-SCAN, because a
  # still-live view can spawn another load task while the previous one exits.
  # Total time is bounded by the caller's budget.
  defp drain_supervised_writers(match?, deadline) do
    case supervised_writer_pids(match?) do
      [] ->
        :ok

      pids ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          :timeout
        else
          await_down(pids, remaining)
          drain_supervised_writers(match?, deadline)
        end
    end
  end

  # The LIVE `EvoDash.TaskSupervisor` children that `match?` accepts. Total: a
  # missing supervisor yields no writers, and a child whose dictionary is already
  # gone (exited between the listing and this read) is simply not a writer any
  # more.
  defp supervised_writer_pids(match?) do
    case Process.whereis(EvoDash.TaskSupervisor) do
      nil ->
        []

      _supervisor ->
        EvoDash.TaskSupervisor
        |> Task.Supervisor.children()
        |> Enum.filter(match?)
    end
  end

  defp held_by?(pid, registrar) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> registrar in Keyword.get(dictionary, :"$callers", [])
      nil -> false
    end
  end

  defp held_by?(_pid, _registrar), do: false

  # A writer FOR THIS DIRECTORY: the per-test ownership predicate (the registrar
  # is in the child's `$callers`), the destination predicate (the child resolves
  # `dir` as its override, so any write it performs lands inside
  # `<dir>/genesis`), or an OWNER pid in its chain (a pid that activated `dir`
  # and is remembered by a marker file, so it still counts after it died). One
  # dictionary read per child covers all three.
  defp writer_for?(pid, registrar, dir, owners) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        callers = Keyword.get(dictionary, :"$callers", [])

        registrar in callers or override_from(dictionary, callers) == dir or
          Enum.any?(callers, &(&1 in owners))

      nil ->
        false
    end
  end

  defp writer_for?(_pid, _registrar, _dir, _owners), do: false

  # The override a child would resolve: its OWN dictionary entry first, then the
  # first override in its `$callers` chain — byte-identical to `resolve/0`, but
  # evaluated for an arbitrary pid instead of the calling process.
  defp override_from(dictionary, callers) do
    case Keyword.get(dictionary, :evogit_config_dir) do
      dir when is_binary(dir) -> dir
      _ -> Enum.find_value(callers, fn pid -> caller_override(pid) end)
    end
  end

  # ── owner registry: which pids ever ACTIVATED this directory ─────────────
  #
  # The ownership predicate above matches the REGISTRAR pid inside a child's
  # `:"$callers"` chain, and a pid VALUE stays readable there after its process
  # died. A module-level directory created by `setup_all` has no such pid — its
  # registrar appears in no child's chain — so the pids that ACTIVATE it (one
  # per test, through `activate/1`) are remembered ON DISK instead: one empty
  # marker file per pid, under `<dir>/.evodash-owners/`.
  #
  # On disk rather than in ETS/persistent_term on purpose: a marker file has no
  # owning process (a table created by the first test process would die with it),
  # needs no supervised keeper, and lives INSIDE the directory it describes, so
  # it is removed by the same `File.rm_rf/1` and can never outlive it. It is also
  # scoped to ONE unique directory name, so concurrent modules never see each
  # other's entries, and it sits beside `<dir>/genesis` (the only path the app
  # resolves), never inside it.
  #
  # The registry costs nothing on the per-test path (`isolate!/1` never writes a
  # marker); a per-test cleanup pays ONE `File.ls` of a directory that does not
  # exist.
  #
  # The file NAME is the pid's textual form without the `#PID<…>` decoration
  # (`"0.123.0"`). `:erlang.list_to_pid/1` turns it back into the pid VALUE — no
  # process needs to exist, which is exactly the point.
  @owner_name ~r/\A\d+\.\d+\.\d+\z/

  defp owners_dir(dir), do: Path.join(dir, ".evodash-owners")

  defp record_owner(dir, pid) do
    path = Path.join(owners_dir(dir), owner_name(pid))

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end

  defp owner_name(pid) do
    pid |> inspect() |> String.replace(~r/[^0-9.]/, "")
  end

  # The pids that activated `dir`, or `[]` when no marker was ever written (the
  # per-test path). Total: an unreadable/missing registry is simply empty.
  defp owner_pids(dir) do
    case File.ls(owners_dir(dir)) do
      {:ok, names} ->
        for name <- names, Regex.match?(@owner_name, name) do
          :erlang.list_to_pid(String.to_charlist("<" <> name <> ">"))
        end

      {:error, _reason} ->
        []
    end
  end

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

  # Drains the directory's writers (once per removal attempt, with that
  # attempt's REMAINING window) and, when the drain actually had to WAIT past
  # `@drain_alarm_ms`, says so — a child that only finished by timing out is
  # billed to the SERIAL `on_exit` phase, where ExUnit's per-test timing cannot
  # see it. Silent on the healthy path (two clock reads).
  defp drain_and_alarm(registrar, dir, budget_ms) do
    started = System.monotonic_time(:millisecond)
    result = await_dir_writers(registrar, dir, budget_ms)
    elapsed = System.monotonic_time(:millisecond) - started

    if elapsed >= @drain_alarm_ms do
      require Logger

      Logger.warning(
        "EvoDash.Test.ConfigDir: the teardown drain for #{inspect(registrar)} " <>
          "blocked #{elapsed} ms waiting for EvoDash.TaskSupervisor children " <>
          "writing into #{dir} (#{inspect(result)}). A child that only ends by " <>
          "timing out is paid SERIALLY here, invisible to ExUnit's per-test " <>
          "times — release the stub/worker the test started and await the " <>
          "applied state instead of leaving it to time out."
      )
    end

    :ok
  end

  # The registered `on_exit` cleanup — the ONE owner of this directory's
  # removal. Drain first (the invariant the moduledoc states), then remove
  # through the shared deadline-bounded primitive: a writer that recreates an
  # entry between the enumeration and the final `rmdir` is retried (re-draining
  # with the REMAINING budget each time, so a matched writer that is merely
  # starved gets the whole window to finish), and a tree that genuinely cannot
  # be removed still raises through `File.Error` instead of being swallowed.
  defp remove_isolated_dir!(dir, registrar) do
    FsCleanup.rm_rf!(dir,
      budget_ms: @cleanup_budget_ms,
      retry_delay_ms: @cleanup_retry_delay_ms,
      before_attempt: fn remaining_ms -> drain_and_alarm(registrar, dir, remaining_ms) end
    )
  end
end
