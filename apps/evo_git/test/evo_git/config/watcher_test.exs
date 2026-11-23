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

  # Poll cadence while awaiting a refresh: `Cache.get/1` is a `:persistent_term`
  # lookup, so a tight-ish poll costs nothing and returns as soon as the reload
  # lands instead of up to one whole tick late.
  @poll_ms 10
  # The race-retry cadence and bound (see `poll_depth/6`): the retry spacing is
  # longer than the watcher's ~150 ms debounce so each re-write's event lets the
  # coalesced reload fire instead of restarting its timer, and the bound keeps a
  # load-delayed reload from being starved of that gap forever.
  @nudge_ms 200
  @max_nudges 6

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
    # Comfortably longer than the watcher's ~150 ms debounce, so a (wrong)
    # reload provoked by the unrelated file would have landed by now.
    Process.sleep(250)

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

    # The agents.toml event runs `EvoGit.CustomAgents.reload/0` in the watcher
    # (no debounce at all); a bounded window past the config debounce before
    # asserting liveness is still ample.
    Process.sleep(250)

    assert Process.alive?(watcher)
    # An agents.toml edit must never be mistaken for a config change.
    assert depth(dir) == 3
  end

  test "a SIWC registration write under chatgpt/ refreshes the snapshot", %{dir: dir, name: name} do
    File.mkdir_p!(Path.join(dir, "chatgpt"))
    watcher = start_supervised!({EvoGit.Config.Watcher, dir: dir, name: name})

    # The init prime sees an empty chatgpt signature: generation 1.
    assert Cache.get(dir).generation == 1

    path = Path.join([dir, "chatgpt", "account-work.json"])
    File.write!(path, ~s({"client_id":"oaiapp_test"}))

    assert await_generation(dir, 2, fn -> File.write!(path, ~s({"client_id":"oaiapp_test"})) end) ==
             2

    assert Process.alive?(watcher)
  end

  test "the registrations lock database is not a config change", %{dir: dir, name: name} do
    chatgpt = Path.join(dir, "chatgpt")
    File.mkdir_p!(chatgpt)
    _watcher = start_supervised!({EvoGit.Config.Watcher, dir: dir, name: name})
    assert Cache.get(dir).generation == 1

    # Lock churn is excluded from the fingerprint AND ignored by the event
    # filter, so neither a reload nor a generation bump can result.
    lock = Path.join(chatgpt, "registrations.sqlite3")
    File.write!(lock, "lock")
    File.write!(lock, "lock-churn")
    Process.sleep(250)

    assert Cache.get(dir).generation == 1
  end

  test "the watcher starts without a chatgpt directory", %{dir: dir, name: name} do
    # Before the first sign-in there is no `chatgpt/` dir at all: only existing
    # directories are watched, and the config watch must behave exactly as
    # before.
    refute File.exists?(Path.join(dir, "chatgpt"))
    watcher = start_supervised!({EvoGit.Config.Watcher, dir: dir, name: name})
    assert Process.alive?(watcher)

    write_config!(dir, 4)
    assert await_depth(dir, 4, fn -> write_config!(dir, 4) end) == 4
    assert Process.alive?(watcher)
  end

  defp await_generation(dir, expected, nudge, timeout \\ 5_000) do
    now = System.monotonic_time(:millisecond)
    poll_generation(dir, expected, now + timeout, now + @nudge_ms, nudge, @max_nudges)
  end

  defp poll_generation(dir, expected, deadline, nudge_at, nudge, nudges_left) do
    now = System.monotonic_time(:millisecond)
    generation = Cache.get(dir).generation

    cond do
      generation == expected ->
        expected

      now >= deadline ->
        flunk("""
        the watcher never bumped #{dir} to generation #{expected}
        (saw #{inspect(generation)})
        """)

      true ->
        {nudge_at, nudges_left} = maybe_nudge(now, nudge_at, nudge, nudges_left)
        Process.sleep(@poll_ms)
        poll_generation(dir, expected, deadline, nudge_at, nudge, nudges_left)
    end
  end

  defp await_depth(dir, expected, nudge, timeout \\ 5_000) do
    now = System.monotonic_time(:millisecond)
    poll_depth(dir, expected, now + timeout, now + @nudge_ms, nudge, @max_nudges)
  end

  defp poll_depth(dir, expected, deadline, nudge_at, nudge, nudges_left) do
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
        {nudge_at, nudges_left} = maybe_nudge(now, nudge_at, nudge, nudges_left)
        Process.sleep(@poll_ms)
        poll_depth(dir, expected, deadline, nudge_at, nudge, nudges_left)
    end
  end

  # The native watch is armed asynchronously inside the port process, so a write
  # issued in the first moments can be missed. Re-writing the SAME bytes is a
  # genuine change event (and a no-op reload otherwise), so the poll re-writes a
  # few times on a fixed cadence until the event lands — one debounce later
  # rather than after a quarter of the whole budget. THE ASSERTION IS UNCHANGED:
  # only the retry cadence moved.
  defp maybe_nudge(now, nudge_at, nudge, nudges_left) do
    cond do
      nudges_left <= 0 ->
        {:infinity, 0}

      now < nudge_at ->
        {nudge_at, nudges_left}

      true ->
        nudge.()
        {now + @nudge_ms, nudges_left - 1}
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
