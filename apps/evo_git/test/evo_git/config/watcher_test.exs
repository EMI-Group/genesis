defmodule EvoGit.Config.WatcherTest do
  @moduledoc """
  Pins `EvoGit.Config.Watcher`: a real directory watch turns a `config.toml`
  edit into a snapshot refresh with NO explicit `EvoGit.Config.Cache.reload/1`
  call, unrelated file writes are ignored, and an `agents.toml` write never
  takes the watcher down.

  ## Backend availability
  The watcher delegates to the vendored `file_system` worker, whose default
  backend is platform-specific: `:fs_inotify` on Linux (needs `inotifywait` on
  PATH) and `:fs_mac` on macOS (needs `fswatch`). `FileSystem.Backend.backend/1`
  is exactly the check `FileSystem.Worker.init/1` performs, including the
  backend's own `bootstrap/0`, so it is evaluated HERE once (at compile time)
  and an unavailable backend tags the whole module `:skip` — a host without the
  native watcher reports skips instead of failures.

  `async: true` is safe because each test watches its OWN unique temp directory
  and starts the watcher under a unique registered name, so nothing here touches
  a shared watcher, config directory or `:persistent_term` key.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config.Cache
  alias EvoGit.TestSupport.ConfigDir

  @backend_available match?({:ok, _}, FileSystem.Backend.backend(nil))

  if not @backend_available do
    @moduletag skip: "file_system backend unavailable on this host (no native watcher)"
  end

  setup do
    ConfigDir.isolate!("config_watcher")
    dir = EvoGit.Config.config_dir()
    name = :"config_watcher_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> Cache.invalidate(dir) end)
    %{dir: dir, name: name}
  end

  test "a config.toml edit refreshes the snapshot without an explicit reload",
       %{dir: dir, name: name} do
    watcher = start_supervised!({EvoGit.Config.Watcher, dir: dir, name: name})

    # The watcher primes the snapshot at init, so the empty dir is the defaults.
    assert depth(dir) == 8
    assert Cache.get(dir).generation == 1

    write_config!(dir, 3)
    assert await_depth(dir, 3, fn -> write_config!(dir, 3) end) == 3

    assert Process.alive?(watcher)
    assert Cache.get(dir).generation == 2
  end

  test "an unrelated file write does not change the snapshot", %{dir: dir, name: name} do
    _watcher = start_supervised!({EvoGit.Config.Watcher, dir: dir, name: name})

    write_config!(dir, 3)
    assert await_depth(dir, 3, fn -> write_config!(dir, 3) end) == 3
    generation = Cache.get(dir).generation

    File.write!(Path.join(dir, "notes.txt"), "unrelated\n")
    # Longer than the watcher's ~150 ms debounce, so a (wrong) reload provoked
    # by the unrelated file would have landed by now.
    Process.sleep(400)

    assert depth(dir) == 3
    assert Cache.get(dir).generation == generation
  end

  test "writing agents.toml leaves the watcher alive", %{dir: dir, name: name} do
    watcher = start_supervised!({EvoGit.Config.Watcher, dir: dir, name: name})

    write_config!(dir, 3)
    assert await_depth(dir, 3, fn -> write_config!(dir, 3) end) == 3

    File.write!(Path.join(dir, "agents.toml"), """
    [[agents]]
    name = "Watcher Test Agent"
    prompt = "You are a test agent."
    """)

    # The agents.toml event runs `EvoGit.CustomAgents.reload/0` in the watcher;
    # give that handler a bounded window before asserting liveness.
    Process.sleep(400)

    assert Process.alive?(watcher)
    # An agents.toml edit must never be mistaken for a config change.
    assert depth(dir) == 3
  end

  defp await_depth(dir, expected, nudge, timeout \\ 5_000) do
    now = System.monotonic_time(:millisecond)
    poll_depth(dir, expected, now + timeout, now + div(timeout, 4), nudge)
  end

  defp poll_depth(dir, expected, deadline, nudge_at, nudge) do
    now = System.monotonic_time(:millisecond)

    cond do
      depth(dir) == expected ->
        expected

      now >= deadline ->
        flunk("""
        the watcher never refreshed #{dir} to max_agent_depth = #{expected}
        (saw #{inspect(depth(dir))}, generation #{inspect(Cache.get(dir).generation)})
        """)

      true ->
        # The native watch is armed asynchronously inside the port process, so a
        # write issued in the first moments can be missed. Re-writing the SAME
        # bytes is a genuine change event (and a no-op reload otherwise), so ONE
        # retry recovers the race without weakening the assertion.
        nudge_at =
          if now >= nudge_at do
            nudge.()
            :infinity
          else
            nudge_at
          end

        Process.sleep(25)
        poll_depth(dir, expected, deadline, nudge_at, nudge)
    end
  end

  defp write_config!(dir, depth) do
    File.write!(Path.join(dir, "config.toml"), """
    [scheduler]
    max_agent_depth = #{depth}
    """)
  end

  defp depth(dir), do: get_in(Cache.get(dir).resolved, [:scheduler, :max_agent_depth])
end
