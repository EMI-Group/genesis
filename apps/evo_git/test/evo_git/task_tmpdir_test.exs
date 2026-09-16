defmodule EvoGit.TaskTmpdirTest do
  # async: false — several tests mutate the process-wide XDG_CONFIG_HOME, which
  # EvoGit.Config.config_path/0 → EvoGit.Platform.config_dir/1 reads LIVE via
  # System.get_env/1 (there is no app-env seam for [:tmp, :mode] / [:tmp, :path]).
  # Redirecting it serializes this module against every other config reader.
  use ExUnit.Case, async: false

  alias EvoGit.TaskTmpdir

  describe "mode/0" do
    setup do
      isolate_xdg!()
      :ok
    end

    test "returns :system for the \"system\" config value" do
      write_tmp_config!("system")
      assert TaskTmpdir.mode() == :system
    end

    test "returns :custom for the \"custom\" config value" do
      write_tmp_config!("custom", scratch_dir!())
      assert TaskTmpdir.mode() == :custom
    end

    test "returns :per_repo for the \"per_repo\" config value" do
      write_tmp_config!("per_repo")
      assert TaskTmpdir.mode() == :per_repo
    end

    test "falls back to :system for an unknown config value" do
      write_tmp_config!("bogus")
      assert TaskTmpdir.mode() == :system
    end

    test "defaults to :system when no config.toml exists" do
      # isolate_xdg! created an EMPTY XDG config dir — no config.toml at all.
      refute File.exists?(EvoGit.Config.config_path())
      assert TaskTmpdir.mode() == :system
    end
  end

  describe "path_for/2 and managed_root/1" do
    # Pure path math only: none of these call ensure/2, reclaim/2 or
    # reclaim_stale/1, so nothing is created/removed. The :system assertions
    # target the hardcoded "/tmp/genesis" root; every scratch path is
    # test-owned.

    setup do
      isolate_xdg!()
      :ok
    end

    test ":system mode resolves under the system tmp dir" do
      write_tmp_config!("system")
      assert TaskTmpdir.managed_root(nil) == "/tmp/genesis"
      assert TaskTmpdir.path_for(42, nil) == "/tmp/genesis/task_42"
    end

    test ":custom mode resolves under the configured [tmp] path" do
      base = scratch_dir!()
      write_tmp_config!("custom", base)
      assert TaskTmpdir.managed_root(nil) == Path.join(base, "genesis")
      assert TaskTmpdir.path_for(42, nil) == Path.join([base, "genesis", "task_42"])
    end

    test ":custom mode with a relative [tmp] path falls back to the system root" do
      write_tmp_config!("custom", "rel/path")
      assert TaskTmpdir.managed_root(nil) == "/tmp/genesis"
      assert TaskTmpdir.path_for(42, nil) == "/tmp/genesis/task_42"
    end

    test ":custom mode without a [tmp] path falls back to the system root" do
      write_tmp_config!("custom")
      assert TaskTmpdir.managed_root(nil) == "/tmp/genesis"
      assert TaskTmpdir.path_for(42, nil) == "/tmp/genesis/task_42"
    end

    test ":per_repo mode resolves under the primary repo's .genesis/tmp" do
      write_tmp_config!("per_repo")
      repo = scratch_dir!()
      assert TaskTmpdir.managed_root(repo) == Path.join([repo, ".genesis", "tmp"])
      assert TaskTmpdir.path_for(42, repo) == Path.join([repo, ".genesis", "tmp", "task_42"])
    end

    test ":per_repo mode without a repo path falls back to the system root" do
      write_tmp_config!("per_repo")
      assert TaskTmpdir.managed_root(nil) == "/tmp/genesis"
      assert TaskTmpdir.path_for(42, nil) == "/tmp/genesis/task_42"
    end

    test "path_for/2 stringifies integer task ids" do
      write_tmp_config!("system")
      assert TaskTmpdir.path_for(42, nil) == "/tmp/genesis/task_42"
      assert TaskTmpdir.path_for("abc", nil) == "/tmp/genesis/task_abc"
    end

    test "path_for/2 performs no filesystem creation" do
      base = scratch_dir!()
      write_tmp_config!("custom", base)
      dir = TaskTmpdir.path_for(42, nil)
      refute File.exists?(dir)
      refute File.exists?(Path.dirname(dir))
    end
  end

  describe "ensure/2" do
    setup do
      isolate_xdg!()
      :ok
    end

    test "creates the per-task directory and returns its path" do
      base = scratch_dir!()
      write_tmp_config!("custom", base)

      dir = TaskTmpdir.ensure(7, nil)
      assert dir == Path.join([base, "genesis", "task_7"])
      assert File.dir?(dir)
    end

    test "is idempotent" do
      base = scratch_dir!()
      write_tmp_config!("custom", base)

      first = TaskTmpdir.ensure(7, nil)
      second = TaskTmpdir.ensure(7, nil)
      assert first == second
      assert File.dir?(first)
    end

    test "never raises when the directory cannot be created" do
      base = scratch_dir!()
      write_tmp_config!("custom", base)

      # A regular file where the managed root should be makes File.mkdir_p/1
      # fail; ensure/2 must still return the intended path and not raise.
      File.write!(Path.join(base, "genesis"), "not a directory")

      assert TaskTmpdir.ensure(42, nil) == Path.join([base, "genesis", "task_42"])
    end
  end

  describe "put_current/1 + current/0" do
    # No config seam needed — this is a pure process-dictionary round-trip.

    test "round-trips a path string" do
      assert :ok = TaskTmpdir.put_current("/some/dir/task_1")
      assert TaskTmpdir.current() == "/some/dir/task_1"
    end

    test "put_current(nil) clears the current value" do
      TaskTmpdir.put_current("/some/dir/task_1")
      assert :ok = TaskTmpdir.put_current(nil)
      assert TaskTmpdir.current() == nil
    end

    test "current/0 returns nil for a non-binary stored value" do
      # :evogit_task_tmpdir is the module's documented process-dictionary seam.
      Process.put(:evogit_task_tmpdir, 123)
      assert TaskTmpdir.current() == nil
    end

    test "current/0 is nil when unset in this test process" do
      assert TaskTmpdir.current() == nil
    end
  end

  describe "reclaim/2" do
    # :custom mode with a test-owned base — reclaim/2 must never enumerate or
    # delete anything under the real /tmp/genesis.
    setup do
      isolate_xdg!()
      :ok
    end

    test "removes the per-task dir, returns :ok and keeps the managed root" do
      base = scratch_dir!()
      write_tmp_config!("custom", base)
      root = Path.join(base, "genesis")

      dir = TaskTmpdir.ensure(7, nil)
      assert File.dir?(dir)

      assert :ok = TaskTmpdir.reclaim(7, nil)
      refute File.exists?(dir)
      assert File.dir?(root)
    end

    test "is idempotent for a non-existent directory" do
      base = scratch_dir!()
      write_tmp_config!("custom", base)

      assert :ok = TaskTmpdir.reclaim(42, nil)
      assert :ok = TaskTmpdir.reclaim(42, nil)
    end

    test "refuses a crafted task_id that escapes the managed root" do
      base = scratch_dir!()
      write_tmp_config!("custom", base)
      root = Path.join(base, "genesis")

      # "task_" <> "../evil" == "task_../evil": the literal component is not ".."
      # (it is "task_.."), so the resolved dir is <root>/task_../evil whose parent
      # is <root>/task_.. — not the managed root — so the containment guard refuses.
      evil = Path.join(root, "task_../evil")
      File.mkdir_p!(evil)
      File.write!(Path.join(evil, "keep.txt"), "keep")

      outside = Path.join(base, "outside.txt")
      File.write!(outside, "keep")

      assert :ok = TaskTmpdir.reclaim("../evil", nil)
      assert File.exists?(Path.join(evil, "keep.txt"))
      assert File.exists?(outside)
    end

    test "never touches anything outside the managed root" do
      base = scratch_dir!()
      write_tmp_config!("custom", base)

      outside_dir = Path.join(base, "outside_dir")
      File.mkdir_p!(outside_dir)
      File.write!(Path.join(outside_dir, "keep.txt"), "keep")

      assert :ok = TaskTmpdir.reclaim(1, nil)
      assert File.exists?(Path.join(outside_dir, "keep.txt"))
    end

    test "refuses a task_id that resolves to the managed root itself" do
      base = scratch_dir!()
      write_tmp_config!("custom", base)
      root = Path.join(base, "genesis")

      # task_id "/.." → dir_name "task_/.." → <root>/task_/.. , which Path.expand
      # collapses to <root> itself. The `expanded_dir == expanded_root` branch
      # (together with the sibling container/basename checks) is what keeps
      # reclaim/2 from File.rm_rf-ing the managed root and everything in it.
      # <root>/task_ is created because the UN-expanded <root>/task_/.. is what
      # File.rm_rf would resolve — a real intermediate component is required for
      # the deletion to reach the root, so the test proves the GUARD, not ENOENT.
      File.mkdir_p!(root)
      File.write!(Path.join(root, "marker.txt"), "keep")
      File.mkdir_p!(Path.join(root, "task_"))

      # A legitimate live task dir under the same root must survive untouched.
      File.mkdir_p!(Path.join(root, "task_5"))
      File.write!(Path.join(root, "task_5/keep.txt"), "keep")

      assert :ok = TaskTmpdir.reclaim("/..", nil)
      assert File.dir?(root)
      assert File.exists?(Path.join(root, "marker.txt"))
      assert File.exists?(Path.join(root, "task_5/keep.txt"))
    end

    test "refuses a task_id whose resolved basename is not task_-prefixed" do
      base = scratch_dir!()
      write_tmp_config!("custom", base)
      root = Path.join(base, "genesis")

      # task_id "/../victim" → dir_name "task_/../victim" → <root>/task_/../victim ,
      # which Path.expand collapses to <root>/victim. Its parent IS the managed
      # root, so only the `basename starts_with "task_"` guard stops reclaim/2
      # from deleting the unrelated <root>/victim directory.
      # <root>/task_ is created so the UN-expanded <root>/task_/../victim path is
      # OS-resolvable — proving the GUARD refuses, not merely that a
      # nonexistent path makes File.rm_rf fail with ENOENT.
      File.mkdir_p!(root)
      File.mkdir_p!(Path.join(root, "task_"))
      File.mkdir_p!(Path.join(root, "victim"))
      File.write!(Path.join(root, "victim/keep.txt"), "keep")

      assert :ok = TaskTmpdir.reclaim("/../victim", nil)
      assert File.exists?(Path.join(root, "victim/keep.txt"))
      assert File.dir?(root)
    end
  end

  describe "reclaim_stale/1" do
    # :custom mode with a test-owned base so the sweep enumerates a
    # test-owned root, never the real /tmp/genesis.
    setup do
      isolate_xdg!()
      :ok
    end

    test "removes stale task_* dirs and keeps live, non-task and outside entries (integer id)" do
      %{base: base, root: root} = seed_root!()

      assert :ok = TaskTmpdir.reclaim_stale([2])

      assert File.dir?(Path.join(root, "task_2"))
      refute File.exists?(Path.join(root, "task_1"))
      assert File.dir?(Path.join(root, "other_dir"))
      assert File.exists?(Path.join(root, "notes.txt"))
      assert File.exists?(Path.join([base, "outside_dir", "keep.txt"]))
    end

    test "protects the matching dir for a string live id" do
      %{base: base, root: root} = seed_root!()

      assert :ok = TaskTmpdir.reclaim_stale(["1"])

      assert File.dir?(Path.join(root, "task_1"))
      refute File.exists?(Path.join(root, "task_2"))
      assert File.dir?(Path.join(root, "other_dir"))
      assert File.exists?(Path.join(root, "notes.txt"))
      assert File.exists?(Path.join([base, "outside_dir", "keep.txt"]))
    end

    test "is a no-op in :per_repo mode" do
      repo = scratch_dir!()
      write_tmp_config!("per_repo")

      dir = Path.join([repo, ".genesis", "tmp", "task_999"])
      File.mkdir_p!(dir)

      assert :ok = TaskTmpdir.reclaim_stale([])
      assert File.dir?(dir)
    end

    test "returns :ok when the managed root does not exist" do
      base = scratch_dir!()
      write_tmp_config!("custom", base)
      # <base>/genesis is deliberately never created.
      refute File.exists?(Path.join(base, "genesis"))

      assert :ok = TaskTmpdir.reclaim_stale([])
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Isolates XDG_CONFIG_HOME (read LIVE by EvoGit.Config via
  # EvoGit.Platform.config_dir/1) into a unique temp dir and restores it on
  # exit, mirroring config_test.exs's `[data] dir` setup.
  defp isolate_xdg! do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-task-tmpdir-xdg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    tmp_xdg
  end

  # Writes a minimal config.toml under the isolated XDG dir. `mode` is the raw
  # TOML string ("system" | "custom" | "per_repo" | anything else);
  # EvoGit.Config.atomize_enum_values/1 converts the valid ones to atoms.
  defp write_tmp_config!(mode, path \\ nil) do
    File.mkdir_p!(EvoGit.Config.config_dir())

    body =
      ["[tmp]\n", "mode = \"#{mode}\"\n"] ++
        if(path, do: ["path = \"#{path}\"\n"], else: [])

    File.write!(EvoGit.Config.config_path(), IO.iodata_to_binary(body))
  end

  # A test-owned scratch directory under the system tmp dir, cleaned up on exit.
  defp scratch_dir! do
    dir =
      Path.join(System.tmp_dir!(), "evogit-task-tmpdir-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Builds the reclaim_stale/1 fixture in :custom mode: a test-owned managed
  # root carrying task_1/task_2/other_dir/notes.txt plus a sibling outside_dir.
  defp seed_root! do
    base = scratch_dir!()
    write_tmp_config!("custom", base)
    root = Path.join(base, "genesis")

    File.mkdir_p!(Path.join(root, "task_1"))
    File.mkdir_p!(Path.join(root, "task_2"))
    File.mkdir_p!(Path.join(root, "other_dir"))
    File.write!(Path.join(root, "notes.txt"), "notes")

    outside = Path.join(base, "outside_dir")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "keep.txt"), "keep")

    %{base: base, root: root}
  end
end
