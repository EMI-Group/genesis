defmodule EvoDash.Test.IsolatedVCT do
  @moduledoc """
  A PRIVATE Virtual Context Tree instance per test, so no test observes — or
  damages — another test's project registry.
  It isolates the mount TABLE: every `isolate!/1` call boots its own
  uniquely-named `EvoGit.VCT` over its own uniquely-named `EvoGit.Store` on a
  private temp sqlite file, so mounts, workspaces, members and the project cap
  are per-test state.
  It deliberately SHARES `EvoGit.PubSub`, so a mutation of the private instance
  still broadcasts `{:vct_updated, node()}` on the same `"vct"` topic and a
  mounted page's broadcast-driven refresh keeps working exactly as in
  production; sharing the topic is harmless because every page READ is
  instance-scoped too.
  It exists because `EvoGit.VCT` is a run-wide, store-backed SINGLETON: without
  this, every mount any concurrently running test makes is visible here (a bare
  `/projects` mount then auto-activates a stranger's project) and a
  `clear_projects/0` sweep destroys other tests' fixtures mid-run.
  The designation is inherited through the spawn CHAIN — `isolate!/1` puts the
  instance name into the CALLING process' dictionary under the core's own
  `:evogit_vct_server` key and `EvoDash.VCTScope` resolves that key through
  `$callers`/`$ancestors` — so a mounted page, the load tasks it supervises and
  `EvoGit.PubSub`-driven reloads all resolve this instance instead of the
  singleton.
  `EvoDash.NodeContext`'s project-registry functions run through
  `EvoDash.VCTScope.scoped/1`; nothing in `lib/` needs to know a test exists.
  """

  # The IDENTICAL key the core resolves (`EvoGit.VCT.server/0`) and
  # `EvoDash.VCTScope` walks the spawn chain for — there is no second key to
  # keep in sync.
  @server_key :evogit_vct_server

  @doc """
  Start a private VCT + store stack, designate it for this test, and register
  its ordered teardown. Returns the instance's registered name.

  ## Options

    * `:prefix` — the temp directory name's prefix (default `"evogit_vct"`);
      keep it stable per suite so a crashed run's artifacts stay identifiable.

  ## Teardown order

  ONE `on_exit` STOPS the stack (`Supervisor.stop/1`, a `:noproc` exit ignored)
  and only THEN removes the temp tree, so no in-flight page-load child can still
  be writing into a half-removed sqlite file.

  The supervisor is UNLINKED from the test process, deliberately (the same
  reasoning `EvoDash.Test.IsolatedTaskStore` documents): ExUnit ends the test
  process with `exit(:shutdown)` BEFORE any `on_exit` callback runs, so a linked
  stack would be torn down by the test's death — at a point where nothing can be
  ordered — instead of by this helper's own teardown.
  """
  @spec isolate!(keyword()) :: atom()
  def isolate!(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "evogit_vct")
    root = Path.join(System.tmp_dir!(), unique_dir_name(prefix))

    File.mkdir_p!(root)

    # Seeded from the run-scoped migrated template (built ONCE per run by
    # `EvoDash.Test.IsolatedTaskStore`), so this store's boot migrator is a
    # verified no-op instead of re-running the migration DDL per test; with no
    # template available the file is simply absent and the boot migrates it.
    sqlite_path = Path.join(root, "tasks.sqlite")
    EvoDash.Test.IsolatedTaskStore.seed_store!(sqlite_path)

    unique = System.unique_integer([:positive])
    store = :"evogit_vct_test_store_#{unique}"
    vct = :"evogit_vct_test_#{unique}"

    children = [
      # `id:` is the unique NAME: `EvoGit.Store.child_spec/1` uses the module
      # as the id, which a second child in the same supervisor would collide
      # with. `pool_size: 1` is enough for one test's registry reads and makes
      # the instance's file handle story trivially private.
      Supervisor.child_spec(
        {EvoGit.Store, data_dir: sqlite_path, name: store, pool_size: 1},
        id: store
      ),
      Supervisor.child_spec(
        {EvoGit.VCT, name: vct, data_dir: root, store: store, pubsub: EvoGit.PubSub},
        id: vct
      )
    ]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

    ExUnit.Callbacks.on_exit(fn ->
      stop_quietly(supervisor)
      EvoDash.Test.FsCleanup.rm_rf!(root)
    end)

    # AFTER `on_exit` is registered (see the doc above): a test process that
    # dies inside this call leaves a still-LINKED stack, which dies with it
    # rather than orphaning a stack nobody stops.
    Process.unlink(supervisor)

    # Starting this store resolves this test's config through
    # `EvoGit.Config.Cache`, which settles a snapshot for the config directory
    # WHILE `config.toml` is still empty (a test writes it directly, bypassing
    # `save_user_config/1`'s reload event, so a settled snapshot would hide the
    # write forever and the page would report "no model configured"). Erasing
    # it here makes every later read rebuild from disk.
    EvoGit.Config.Cache.invalidate()

    Process.put(@server_key, vct)
    vct
  end

  # Ordered, explicit, and tolerant of an already-dead stack (a test process
  # that died first takes its linked stack with it).
  defp stop_quietly(supervisor) do
    Supervisor.stop(supervisor)
  catch
    :exit, _reason -> :ok
  end

  # A directory name unique across every BEAM on the host, not merely within
  # this one — the reasoning `EvoDash.Test.ConfigDir.unique_dir_name/1`
  # documents: `System.unique_integer/1` alone restarts at the same offset in
  # each VM, so two `mix test` runs sharing one `TMPDIR` would compute the SAME
  # path and each run's teardown would remove the OTHER run's live database.
  # The OS pid separates concurrent VMs and the random suffix also covers OS-pid
  # reuse plus a stale directory left by an interrupted run.
  defp unique_dir_name(prefix) do
    random = String.downcase(Integer.to_string(:rand.uniform(4_294_967_296) - 1, 16))
    "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}-#{random}"
  end
end
