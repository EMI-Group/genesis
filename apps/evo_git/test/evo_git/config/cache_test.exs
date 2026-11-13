defmodule EvoGit.Config.CacheTest do
  @moduledoc """
  Pins the RAM-resident config snapshot contract (`EvoGit.Config.Cache`): one
  snapshot per config directory in `:persistent_term`, ZERO file I/O on a read,
  generation bumps only on an actual content change, synchronous refresh after a
  save, per-directory isolation, `invalidate/1` rebuilds, and the `"config"`
  broadcast on a changed reload.

  `async: true` is safe because every test writes into its OWN unique config
  directory (`EvoGit.TestSupport.ConfigDir.isolate!/1`), so the
  `:persistent_term` keys `{EvoGit.Config.Cache, dir}` this module writes are
  never read by another module — the same property that makes the per-process
  `:config_dir_fun` seam safe. The one shared resource is the `"config"` PubSub
  topic, and every assertion here filters on this test's unique `dir`.
  """
  use ExUnit.Case, async: true

  alias EvoGit.Config
  alias EvoGit.Config.Cache
  alias EvoGit.TestSupport.ConfigDir

  @topic "config"

  setup do
    ConfigDir.isolate!("config_cache")
    # `isolate!/1` activates the base dir; the config dir itself is its
    # `genesis` child, exactly what `EvoGit.Config.config_dir/0` resolves.
    dir = Config.config_dir()
    File.mkdir_p!(dir)
    on_exit(fn -> Cache.invalidate(dir) end)
    %{dir: dir}
  end

  test "a cold read builds one snapshot and serves every reader from it", %{dir: dir} do
    write_config!(dir, 3)

    assert :missing == :persistent_term.get({Cache, dir}, :missing)

    snapshot = Cache.get()

    assert snapshot.dir == dir
    assert snapshot.generation == 1
    assert snapshot.validation_errors == []
    assert Config.resolve([:scheduler, :max_agent_depth]) == 3
    assert Config.user_config()["scheduler"]["max_agent_depth"] == 3
    assert Config.resolve() == snapshot.resolved
  end

  test "reads never touch the filesystem after the first build", %{dir: dir} do
    write_config!(dir, 3)
    assert Config.resolve([:scheduler, :max_agent_depth]) == 3

    # An external edit is invisible until an event refreshes the snapshot.
    write_config!(dir, 7)
    assert Config.resolve([:scheduler, :max_agent_depth]) == 3
    assert Config.user_config()["scheduler"]["max_agent_depth"] == 3

    # Even deleting the file changes nothing: the read path is RAM-only.
    File.rm!(Path.join(dir, "config.toml"))
    assert Config.resolve([:scheduler, :max_agent_depth]) == 3
    assert Cache.get().generation == 1
  end

  test "reload picks up a changed file and keeps the snapshot on unchanged bytes", %{dir: dir} do
    write_config!(dir, 3)
    assert Cache.get().generation == 1

    write_config!(dir, 7)
    reloaded = Cache.reload()

    assert reloaded.generation == 2
    assert Config.resolve([:scheduler, :max_agent_depth]) == 7

    # Identical bytes are NOT a change: no new snapshot, no generation bump.
    assert Cache.reload(dir: dir) == reloaded
    assert Cache.get().generation == 2
  end

  test "save_user_config/1 refreshes the snapshot synchronously", %{dir: dir} do
    write_config!(dir, 3)
    assert Config.resolve([:scheduler, :max_agent_depth]) == 3

    updated = put_in(Config.defaults(), [:scheduler, :max_agent_depth], 6)
    assert :ok = Config.save_user_config(updated)

    # No explicit reload call: the save itself refreshed the snapshot.
    assert Config.resolve([:scheduler, :max_agent_depth]) == 6
    assert Config.user_config()["scheduler"]["max_agent_depth"] == 6
    assert Cache.get(dir).generation == 2
  end

  test "save_credentials/1 refreshes credentials/0 synchronously", %{dir: dir} do
    assert Config.credentials() == %{}

    assert :ok = Config.save_credentials(%{"GENESIS_CACHE_TEST_TOKEN" => "cache-secret"})

    assert Config.credentials()["GENESIS_CACHE_TEST_TOKEN"] == "cache-secret"

    assert File.read!(Path.join(dir, "credentials.toml")) =~
             ~s(GENESIS_CACHE_TEST_TOKEN = "cache-secret")
  end

  test "two config directories keep separate snapshots and generations", %{dir: dir} do
    other = Path.join(ConfigDir.isolate_module!("config_cache_other"), "genesis")
    File.mkdir_p!(other)
    write_config!(dir, 3)
    write_config!(other, 9)

    assert Cache.get(dir).generation == 1
    assert Cache.get(other).generation == 1
    assert Cache.get(other).dir == other
    assert depth(Cache.get(dir).resolved) == 3
    assert depth(Cache.get(other).resolved) == 9

    write_config!(dir, 4)
    assert Cache.reload(dir: dir).generation == 2

    assert depth(Cache.get(dir).resolved) == 4
    assert Cache.get(other).generation == 1
    assert depth(Cache.get(other).resolved) == 9

    write_config!(other, 11)
    assert Cache.reload(dir: other).generation == 2

    assert depth(Cache.get(other).resolved) == 11
    assert depth(Cache.get(dir).resolved) == 4
  end

  test "invalidate/1 forces a rebuild from disk", %{dir: dir} do
    write_config!(dir, 3)
    assert Cache.get().generation == 1

    write_config!(dir, 5)
    assert Cache.get().generation == 1

    assert :ok = Cache.invalidate(dir)
    assert :missing == :persistent_term.get({Cache, dir}, :missing)

    snapshot = Cache.get()
    assert snapshot.generation == 1
    assert depth(snapshot.resolved) == 5
  end

  test "a changed reload broadcasts on the config topic for its own dir", %{dir: dir} do
    write_config!(dir, 3)
    :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, @topic)
    this_node = node()

    # A cold build is silent.
    assert Cache.get().generation == 1
    refute_receive {:config_reloaded, _node, ^dir, _generation}, 50

    write_config!(dir, 8)
    assert Cache.reload(dir: dir).generation == 2
    assert_receive {:config_reloaded, ^this_node, ^dir, 2}, 1_000

    # Unchanged bytes never broadcast either.
    assert Cache.reload(dir: dir).generation == 2
    refute_receive {:config_reloaded, _node, ^dir, _generation}, 100
  end

  test "a wrong value type is reported as validation errors without raising", %{dir: dir} do
    File.write!(Path.join(dir, "config.toml"), """
    [scheduler]
    max_agent_depth = "oops"
    """)

    snapshot = Cache.get()

    assert snapshot.validation_errors != []

    assert Enum.any?(
             snapshot.validation_errors,
             &(&1.key_path == [:scheduler, :max_agent_depth])
           )

    assert is_map(Config.resolve())
    assert Config.resolve([:scheduler, :max_agent_depth]) == "oops"
    assert Config.config_status().ok? == false
  end

  test "a bogus enum value is reported as validation errors without raising", %{dir: dir} do
    File.write!(Path.join(dir, "config.toml"), """
    [sandbox]
    mode = "bogus"
    """)

    snapshot = Cache.get()

    assert snapshot.validation_errors != []
    assert Enum.any?(snapshot.validation_errors, &(&1.key_path == [:sandbox, :mode]))
    assert is_map(Config.resolve())
    assert Config.config_status().ok? == false
  end

  test "a scalar section stays a total read and keeps the map default", %{dir: dir} do
    # A scalar where a table is expected is swallowed by the defensive
    # `deep_merge` (the map default survives), so the snapshot stays usable and
    # `validation_errors` stays empty — the behavior the read path relies on.
    File.write!(Path.join(dir, "config.toml"), ~s(llm = "string"\n))

    snapshot = Cache.get()

    assert is_map(Config.resolve())
    assert is_map(snapshot.resolved.llm)
    assert is_map(Config.user_config())
    assert snapshot.validation_errors == []
  end

  defp write_config!(dir, depth) do
    File.write!(Path.join(dir, "config.toml"), """
    [scheduler]
    max_agent_depth = #{depth}
    """)
  end

  defp depth(resolved), do: get_in(resolved, [:scheduler, :max_agent_depth])
end
