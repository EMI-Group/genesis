defmodule EvoGit.Config.ReloadEventTest.UnresponsiveWatcher do
  @moduledoc false
  # A wedged watcher: it accepts the call and never replies, so the bounded
  # `GenServer.call/3` inside `EvoGit.Config.Watcher.notify_change/2` times out
  # and the caller's guarded fallback has to perform the refresh instead.
  #
  # Defined ABOVE the async test modules: `mix test` starts the ExUnit async
  # runner before requiring the rest of the file, so a helper defined below
  # them could still be unloaded when a test calls it.
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(_request, _from, state), do: {:noreply, state}
end

defmodule EvoGit.Config.ReloadEventTest do
  @moduledoc """
  Pins the config-refresh EVENT path when no live watcher answers it.

  `EvoGit.Config.Watcher.notify_change/2` is the single "config changed →
  refresh the snapshot" entry point a save raises, and it is total and bounded:
  an absent, unregistered, dead or unresponsive target never fails, crashes or
  indefinitely blocks the calling process — the caller runs the SAME guarded
  `EvoGit.Config.Cache.reload_safely/1` the watcher's own debounced file event
  runs, synchronously, and exactly ONE generation bump results from ONE content
  change.

  The live-watcher half of that contract (a save's event with a watcher
  running, an explicit event routed through a watcher, and a watcher watching a
  different directory) lives in `EvoGit.Config.ReloadEventWatchTest`, which
  needs the native `file_system` backend. Nothing here does.

  `async: true` is safe because every test writes into its OWN unique config
  directory (`EvoGit.TestSupport.ConfigDir.isolate!/1`), so the
  `:persistent_term` keys `{EvoGit.Config.Cache, dir}` this module writes are
  never read by another module, and every watcher registration uses a unique
  name (the default `EvoGit.Config.Watcher` name is never registered here). The
  one shared resource is the `"config"` PubSub topic, and every assertion
  filters on this test's unique `dir`.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config
  alias EvoGit.Config.Cache
  alias EvoGit.Config.ReloadEventTest.UnresponsiveWatcher
  alias EvoGit.Config.Watcher
  alias EvoGit.TestSupport.ConfigDir

  @topic "config"

  setup do
    ConfigDir.isolate!("config_reload_event")
    dir = Config.config_dir()
    File.mkdir_p!(dir)
    on_exit(fn -> Cache.invalidate(dir) end)
    %{dir: dir}
  end

  test "an absent watcher falls back to a synchronous reload", %{dir: dir} do
    # The suite's own boot never starts the watcher, so the DEFAULT target of a
    # save or an explicit event is unregistered here.
    assert Process.whereis(Watcher) == nil
    assert Cache.get(dir).generation == 1

    :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, @topic)
    this_node = node()

    write_config!(dir, 5)
    assert :ok = Watcher.notify_change(dir)

    # Synchronous on return: no polling, no explicit reload call.
    assert depth(dir) == 5
    assert Config.resolve([:scheduler, :max_agent_depth]) == 5
    assert Cache.get(dir).generation == 2
    assert_receive {:config_reloaded, ^this_node, ^dir, 2}, 1_000

    # An explicitly requested target that was never registered takes the same
    # fallback.
    write_config!(dir, 6)
    assert :ok = Watcher.notify_change(dir, watcher: :config_reload_event_absent_watcher)

    assert depth(dir) == 6
    assert Cache.get(dir).generation == 3
  end

  test "a save with no watcher registered refreshes synchronously", %{dir: dir} do
    assert Process.whereis(Watcher) == nil
    assert Cache.get(dir).generation == 1

    updated = put_in(Config.defaults(), [:scheduler, :max_agent_depth], 4)
    assert :ok = Config.save_user_config(updated)

    assert Config.resolve([:scheduler, :max_agent_depth]) == 4
    assert Cache.get(dir).generation == 2
  end

  test "a dead watcher registration falls back to a synchronous reload", %{dir: dir} do
    name = :"config_reload_event_dead_#{System.unique_integer([:positive])}"

    # Starting a real watcher is what makes the registration DEAD rather than
    # merely absent; its init primes the snapshot from the empty directory.
    # `with_log/1` keeps a backend-less host's "cannot watch" warning off the
    # console without losing it on failure.
    {watcher, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        start_supervised!({Watcher, dir: dir, name: name})
      end)

    assert Cache.get(dir).generation == 1

    # `:shutdown` (not the `:normal` default) so the LINKED `file_system`
    # worker dies with the watcher instead of lingering as an orphan watcher of
    # a directory this test's teardown removes.
    :ok = GenServer.stop(watcher, :shutdown)
    assert Process.whereis(name) == nil

    write_config!(dir, 4)
    assert :ok = Watcher.notify_change(dir, watcher: name)

    assert depth(dir) == 4
    assert Cache.get(dir).generation == 2
  end

  test "an unresponsive watcher times out into the bounded fallback", %{dir: dir} do
    assert Cache.get(dir).generation == 1

    stub = :"config_reload_event_stub_#{System.unique_integer([:positive])}"
    start_supervised!({UnresponsiveWatcher, stub})

    write_config!(dir, 6)

    started = System.monotonic_time(:millisecond)
    assert :ok = Watcher.notify_change(dir, watcher: stub, timeout: 50)
    elapsed = System.monotonic_time(:millisecond) - started

    # Bounded: the wedged call is abandoned at its timeout, never waited out.
    assert elapsed < 2_000
    assert depth(dir) == 6
    assert Cache.get(dir).generation == 2
  end

  defp write_config!(dir, depth) do
    File.write!(Path.join(dir, "config.toml"), """
    [scheduler]
    max_agent_depth = #{depth}
    """)
  end

  defp depth(dir), do: get_in(Cache.get(dir).resolved, [:scheduler, :max_agent_depth])
end

defmodule EvoGit.Config.ReloadEventWatchTest do
  @moduledoc """
  Pins the config-refresh EVENT path with a LIVE watcher: the file-watch event
  and the save event share ONE reload, so exactly one generation bump follows
  one content change — a save's own file write, and an explicit event's own
  file write, are fingerprint no-ops by the time their ~150 ms debounce fires.

  ## Backend availability
  The watcher delegates to the vendored `file_system` worker, whose default
  backend is platform-specific: `:fs_inotify` on Linux (needs `inotifywait` on
  PATH) and `:fs_mac` on macOS (needs `fswatch`). `FileSystem.Backend.backend/1`
  is exactly the check `FileSystem.Worker.init/1` performs, so it is evaluated
  HERE once and an unavailable backend tags this module `:skip` instead of
  failing it; the fallback half of the contract stays untagged in
  `EvoGit.Config.ReloadEventTest`.

  `async: true` is safe because every test watches its OWN unique config
  directory under a unique registered name, so no shared watcher, config
  directory or `:persistent_term` key is touched, and every broadcast assertion
  filters on this test's unique `dir`.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config
  alias EvoGit.Config.Cache
  alias EvoGit.Config.Watcher
  alias EvoGit.TestSupport.ConfigDir

  @topic "config"

  @backend_available match?({:ok, _}, FileSystem.Backend.backend(nil))

  if not @backend_available do
    @moduletag skip: "file_system backend unavailable on this host (no native watcher)"
  end

  setup do
    ConfigDir.isolate!("config_reload_event_watch")
    dir = Config.config_dir()
    File.mkdir_p!(dir)
    name = :"config_reload_event_watcher_#{System.unique_integer([:positive])}"
    on_exit(fn -> Cache.invalidate(dir) end)
    %{dir: dir, name: name}
  end

  test "a save raises ONE event through a live watcher and its file write is a debounce no-op",
       %{dir: dir, name: name} do
    _watcher = start_supervised!({Watcher, dir: dir, name: name})
    # The watcher primes the snapshot at init: the empty dir is generation 1.
    assert Cache.get(dir).generation == 1

    :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, @topic)
    this_node = node()

    # The save's DEFAULT event target is the `EvoGit.Config.Watcher` name,
    # which `:test` never starts, so the guarded fallback performs the refresh
    # even while this uniquely-named watcher is alive.
    assert Process.whereis(Watcher) == nil

    updated = put_in(Config.defaults(), [:scheduler, :max_agent_depth], 6)
    assert :ok = Config.save_user_config(updated)

    # Synchronously after `:ok`, with no reload call of our own.
    assert Config.resolve([:scheduler, :max_agent_depth]) == 6
    assert Cache.get(dir).generation == 2
    assert_receive {:config_reloaded, ^this_node, ^dir, 2}, 1_000

    # The save's file write also reaches the live watcher, but by the time its
    # debounce fires the bytes are already in the snapshot: a fingerprint no-op.
    Process.sleep(400)
    assert Cache.get(dir).generation == 2
    refute_receive {:config_reloaded, _node, ^dir, _generation}, 200

    # The same shape for the credentials save (also a watched file).
    assert :ok = Config.save_credentials(%{"GENESIS_RELOAD_EVENT_TOKEN" => "reload-secret"})
    assert Config.credentials()["GENESIS_RELOAD_EVENT_TOKEN"] == "reload-secret"
    assert Cache.get(dir).generation == 3
    assert_receive {:config_reloaded, ^this_node, ^dir, 3}, 1_000

    Process.sleep(400)
    assert Cache.get(dir).generation == 3
    refute_receive {:config_reloaded, _node, ^dir, _generation}, 200
  end

  test "an explicit event through a live watcher refreshes synchronously",
       %{dir: dir, name: name} do
    _watcher = start_supervised!({Watcher, dir: dir, name: name})
    assert Cache.get(dir).generation == 1

    :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, @topic)
    this_node = node()

    write_config!(dir, 5)
    assert :ok = Watcher.notify_change(dir, watcher: name)

    # The routed `handle_call/3` refresh is synchronous on return: no polling.
    assert Config.resolve([:scheduler, :max_agent_depth]) == 5
    assert Cache.get(dir).generation == 2
    assert_receive {:config_reloaded, ^this_node, ^dir, 2}, 1_000

    # The write's own debounced file event lands on the same reload and, with
    # the bytes already in the snapshot, bumps nothing.
    Process.sleep(400)
    assert Cache.get(dir).generation == 2
    refute_receive {:config_reloaded, _node, ^dir, _generation}, 200
  end

  test "a watcher on another dir refreshes the explicitly requested dir",
       %{dir: dir_b, name: name} do
    _watcher = start_supervised!({Watcher, dir: dir_b, name: name})
    assert Cache.get(dir_b).generation == 1

    dir_a = Path.join(ConfigDir.isolate_module!("config_reload_event_other"), "genesis")
    File.mkdir_p!(dir_a)
    on_exit(fn -> Cache.invalidate(dir_a) end)
    assert Cache.get(dir_a).generation == 1

    write_config!(dir_a, 4)
    assert :ok = Watcher.notify_change(dir_a, watcher: name)

    assert depth(dir_a) == 4
    assert Cache.get(dir_a).generation == 2
    # The directory the watcher actually watches is untouched.
    assert Cache.get(dir_b).generation == 1
    assert depth(dir_b) == 8
  end

  defp write_config!(dir, depth) do
    File.write!(Path.join(dir, "config.toml"), """
    [scheduler]
    max_agent_depth = #{depth}
    """)
  end

  defp depth(dir), do: get_in(Cache.get(dir).resolved, [:scheduler, :max_agent_depth])
end
