# Redirect data directory to a temp location so tests don't pollute real user data
System.put_env("XDG_DATA_HOME", Path.join(System.tmp_dir!(), "evogit_test_data"))
File.mkdir_p!(Path.join(System.tmp_dir!(), "evogit_test_data"))

# Redirect the config directory (XDG_CONFIG_HOME) to a run-unique EMPTY dir,
# mirroring the XDG_DATA_HOME redirect above. EvoGit.Config.config_dir/0 derives
# the config path from XDG_CONFIG_HOME on Linux, so redirecting it here keeps the
# whole suite hermetic: no module reads (or writes) the developer's real
# ~/.config/genesis. The dir is UNIQUE PER BEAM (os pid + unique int) so two
# concurrently running `mix test` runs never share a config dir — the same
# cross-run isolation the data-dir guard provides.
#
# Suites that WRITE config still point XDG_CONFIG_HOME at their own per-test temp
# dir (System.put_env is process-global, which is exactly why those suites stay
# `async: false`) and restore the prior value in on_exit — System.get_env now
# returns this boot dir (never nil), so their restore lands back here.
#
# NOTE: on macOS EvoGit.Platform.base_dir/3 ignores XDG_CONFIG_HOME entirely
# (config is always ~/Library/Application Support); this redirect is therefore a
# no-op there, matching the pre-existing platform behaviour.
test_config_home =
  Path.join(
    System.tmp_dir!(),
    "evogit_test_config/genesis-#{System.pid()}-#{:erlang.unique_integer([:positive])}"
  )

File.mkdir_p!(test_config_home)
System.put_env("XDG_CONFIG_HOME", test_config_home)

# The wx-based directory picker must never pop a real native dialog during
# tests — a modal dialog would hang the suite on machines with a display.
# (wx is also pruned from the test code path, so the real picker would
# degrade to unavailable anyway; this flag is the explicit guarantee.)
# config/test.exs carries the same flag for a real `mix test` run; this line
# keeps the guarantee when the app is exercised through other entry points.
Application.put_env(:evo_dash, :directory_picker, enabled: false)

# Default nix integration OFF for the whole suite. EvoGit.Nix.enabled?/0 reads
# this app env first; when unset it falls back to the developer's REAL
# ~/.config/genesis config and shells out to real `nix print-dev-env` (which is
# slow, contends on the shared eval-cache SQLite DB, and spams the console with
# "waiting for another Nix process to finish fetching input ..." + eval-cache
# "database is busy" noise). Nix is only consulted LAZILY during tests
# (sandbox/None + system-check paths), so setting it here — after app boot but
# before any test runs — is effective and race-free for every async module.
# Tests that specifically need nix enable it explicitly.
Application.put_env(:evo_git, :nix_enabled, false)

# Resolve the config dir PER PROCESS during tests, exactly as `:evo_git`'s own
# helper does (same `{m, f, a}` shape, same process-dictionary key
# `:evogit_config_dir`, so a root `mix test` running both umbrella apps resolves
# identically whichever helper installed the fun last). Modules can then isolate
# the config directory for ONE test with
# `EvoDash.Test.ConfigDir.isolate!/1` instead of repointing the BEAM-global
# `XDG_CONFIG_HOME` env var (a process-wide write that forces `async: false`).
#
# The seam is DEFAULT-INERT: production never sets `:config_dir_fun`, so
# `EvoGit.Platform.config_dir/1` falls back to its unchanged XDG/platform
# resolution. The run-unique `XDG_CONFIG_HOME` boot redirect above therefore
# STAYS in place as the fallback — a test (or a process outside the test's
# `$callers` chain, e.g. a boot-time app-global singleton) that carries no
# override keeps resolving exactly as before, so nothing regresses if the seam
# is ever removed.
Application.put_env(:evo_git, :config_dir_fun, {EvoDash.Test.ConfigDir, :resolve, []})

# Test-only perf tuning. These five keys are all CALL-TIME seams — production
# code reads them at the call site via `Application.get_env(:evo_dash, key, <prod
# default>)`, so leaving them unset keeps the production timings intact; setting
# them here only shrinks the real-timer waits the suite otherwise burns on
# `Process.sleep`. Each value stays comfortably above 0 so no wait degenerates
# into a busy spin.
Application.put_env(:evo_dash, :agents_live_flush_ms, 10)
Application.put_env(:evo_dash, :agents_live_commit_graph_tick_ms, 10)
Application.put_env(:evo_dash, :system_samples_seed_retry_ms, 10)
Application.put_env(:evo_dash, :flush_loading_poll_ms, 1)
Application.put_env(:evo_dash, :node_aware_reload_debounce_ms, 10)

# --- TEMPORARY node() sampler (throwaway instrumentation) --------------------
defmodule NodeSampler do
  @moduledoc false
  @log_path Path.join(System.tmp_dir!(), "node_sampler_#{System.pid()}.log")

  def path, do: @log_path

  def start do
    pid = spawn(fn -> init() end)
    Process.register(pid, __MODULE__)
    pid
  end

  def record(kind, payload) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, {:fmt, kind, payload})
    end
  end

  defp init do
    write("# node sampler start #{ts()} node=#{inspect(node())}")
    loop(node(), %{})
  end

  defp ts, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp write(line), do: File.write!(@log_path, line <> "\n", [:append])

  defp loop(current, running) do
    receive do
      {:fmt, :started, key} ->
        loop(current, Map.update(running, key, 1, &(&1 + 1)))

      {:fmt, :finished, key} ->
        running =
          case Map.get(running, key) do
            nil -> running
            n when n <= 1 -> Map.delete(running, key)
            n -> Map.put(running, key, n - 1)
          end

        loop(current, running)

      {:fmt, :stop} ->
        write("# node sampler stop #{ts()} node=#{inspect(node())}")
    after
      50 ->
        now = node()

        if now != current do
          write(
            "#{ts()} [TRANSITION] #{inspect(current)} -> #{inspect(now)} " <>
              "running=#{inspect(Map.keys(running))} procs=#{inspect(interesting_procs(), limit: 20)}"
          )

          loop(now, running)
        else
          loop(now, running)
        end
    end
  end

  defp interesting_procs do
    for pid <- Process.list(),
        info = Process.info(pid, [:current_stacktrace, :initial_call, :registered_name]),
        info != nil,
        text = inspect(info),
        String.contains?(text, "EvoGit.Distribution") or String.contains?(text, "net_kernel") or
          String.contains?(text, "RemoteConnection") do
      {pid, info[:registered_name], Enum.take(info[:current_stacktrace] || [], 4)}
    end
  end
end

defmodule NodeSamplerFmt do
  @moduledoc false
  use GenServer

  def init(opts), do: {:ok, opts}

  def handle_event(event, config) do
    track(event)
    config
  end

  def handle_cast(event, config) do
    track(event)
    {:noreply, config}
  end

  def handle_info(_msg, config), do: {:noreply, config}

  defp track({:test_started, test}), do: NodeSampler.record(:started, describe(test))
  defp track({:test_finished, test}), do: NodeSampler.record(:finished, describe(test))
  defp track(_other), do: :ok

  defp describe(%{module: module, name: name} = test) do
    {module, name, Map.get(test, :file), Map.get(test, :line)}
  end
end

NodeSampler.start()

ExUnit.after_suite(fn _ ->
  Process.sleep(200)

  case Process.whereis(NodeSampler) do
    nil -> :ok
    pid -> send(pid, {:fmt, :stop})
  end

  Process.sleep(100)
  IO.puts("\n===== NODE SAMPLER #{NodeSampler.path() || "(nil path)"} =====")

  case File.read(NodeSampler.path()) do
    {:ok, body} -> IO.puts(body)
    other -> IO.puts("unreadable: #{inspect(other)}")
  end

  IO.puts("===== END NODE SAMPLER =====\n")
end)

# --- END TEMPORARY node() sampler -------------------------------------------

ExUnit.start(capture_log: true, formatters: [ExUnit.CLIFormatter, NodeSamplerFmt])

# Warm the LLMDB model catalog ONCE, before the parallel phase starts.
#
# `LLMDB.Catalog.ensure_loaded!/0` guards its one-time packaged-catalog load
# with a BEAM-GLOBAL `:global.trans({LLMDB.Catalog, :load}, ...)` lock, and the
# load itself (deserialize + Zoi-parse of every provider/model entry) takes
# hundreds of milliseconds to seconds on a loaded host. Whichever process first
# resolves a catalog model pays that load WHILE HOLDING the lock, so every other
# model-resolving process in the parallel cohort — a Settings/Welcome render, a
# Projects model reconciliation, and the app-global `EvoGit.AgentScheduler`,
# whose `handle_call` computes generation params from the catalog — blocks in
# `:global.random_sleep` retries for the whole duration. That contention lands
# as arbitrary multi-second latency in unrelated tests (and, measured, as
# multi-second `EvoDash.Test.ConfigDir` `on_exit` drains, because a page child
# left in flight is stuck in a 5 s `GenServer.call` to the wedged scheduler).
#
# Loading it here serializes that ONE-TIME cost before any test runs, so the
# parallel phase only ever reads the already-loaded snapshot.
LLMDB.Catalog.ensure_loaded!()

ExUnit.after_suite(fn _ ->
  # Remove ONLY this run's unique data dir (from the app env). Never remove the
  # shared parent `System.tmp_dir!()/evogit_test_data`: a concurrently running
  # `mix test` owns a sibling unique dir under it, so deleting the parent would
  # nuke that run's SQLite database mid-flight.
  test_data_dir = Application.get_env(:evo_git, :data_dir)
  if is_binary(test_data_dir), do: File.rm_rf(test_data_dir)

  # Same for the run-unique config dir seeded above — remove only this run's
  # own dir, never the shared `System.tmp_dir!()/evogit_test_config` parent.
  File.rm_rf(test_config_home)
end)
