defmodule EvoGit.Agent.Tools.SharedTest do
  @moduledoc """
  `async: true` — pure `EvoGit.Agent.Tools.Shared` functions plus process-local
  `:foreign_repos` state (set and cleared within each test); no BEAM-global
  state or shared ETS.

  The `with_file_lock/2` / `perform_string_replace/5` concurrency tests use
  unique per-test temp files (and thus a unique `:global` lock key, since the
  lock key derives from `Path.expand/1` of the path), so they never contend
  with any concurrently running module.
  """

  use ExUnit.Case, async: true
  alias EvoGit.Agent.Tools.Shared

  # Bounded wait for cross-process coordination messages — generous enough to
  # absorb the async cohort's scheduling jitter, short enough to fail fast.
  @recv_timeout 2_000

  describe "normalize_relpath/1" do
    test "normalizes bare path to ./ prefix" do
      assert Shared.normalize_relpath("foo/bar") == "./foo/bar"
    end

    test "keeps ./-prefixed path as-is" do
      assert Shared.normalize_relpath("./foo/bar") == "./foo/bar"
    end

    test "normalizes empty string to ./" do
      assert Shared.normalize_relpath("") == "./"
    end

    test "normalizes dot to ./" do
      assert Shared.normalize_relpath(".") == "./"
    end

    test "returns error tuple on absolute paths (does not raise)" do
      assert {:error, message} = Shared.normalize_relpath("/etc/passwd")
      assert message =~ "absolute"
      assert message =~ "relative to the repository root"
    end

    test "returns error tuple on Windows absolute paths" do
      assert {:error, message} = Shared.normalize_relpath("C:\\Users\\file.txt")
      assert message =~ "absolute"
      assert message =~ "relative to the repository root"
    end

    test "returns error tuple on forward-slash UNC absolute paths" do
      assert {:error, message} = Shared.normalize_relpath("//wsl.localhost/Ubuntu-22.04/x")
      assert message =~ "absolute"
      assert message =~ "//wsl.localhost/Ubuntu-22.04/x"
      assert message =~ "relative to the repository root"
    end

    test "returns error tuple on backslash UNC absolute paths" do
      path = "\\\\wsl.localhost\\Ubuntu-22.04\\x"
      assert {:error, message} = Shared.normalize_relpath(path)
      assert message =~ "absolute"
      # The message embeds the inspect-ed path (backslashes doubled).
      assert message =~ inspect(path)
      assert message =~ "relative to the repository root"
    end

    test "strips trailing slashes" do
      assert Shared.normalize_relpath("foo/") == "./foo"
    end

    test "trims backslash separators in relative paths" do
      assert Shared.normalize_relpath("foo\\bar") == "./foo/bar"
    end

    test "trims leading and trailing backslashes" do
      assert Shared.normalize_relpath("\\foo\\bar\\") == "./foo/bar"
    end

    test "handles single segment" do
      assert Shared.normalize_relpath("lib") == "./lib"
    end

    test "handles root path ./" do
      assert Shared.normalize_relpath("./") == "./"
    end
  end

  describe "is_child_or_same_node?/2" do
    test "root encompasses everything" do
      assert Shared.is_child_or_same_node?("./", "./foo/bar") == true
    end

    test "same path matches" do
      assert Shared.is_child_or_same_node?("./foo", "./foo") == true
    end

    test "child matches parent" do
      assert Shared.is_child_or_same_node?("./foo", "./foo/bar") == true
    end

    test "sibling does not match" do
      assert Shared.is_child_or_same_node?("./foo", "./bar") == false
    end

    test "parent does not match child" do
      assert Shared.is_child_or_same_node?("./foo/bar", "./foo") == false
    end

    test "root matches root" do
      assert Shared.is_child_or_same_node?("./", "./") == true
    end
  end

  describe "validate_file_scope/3" do
    test "allows file within node" do
      repo_path = "/home/user/repo"
      expanded = "/home/user/repo/lib/app.ex"
      assert Shared.validate_file_scope(expanded, "./lib", repo_path) == :ok
    end

    test "allows file at node root" do
      repo_path = "/home/user/repo"
      expanded = "/home/user/repo/lib/app.ex"
      assert Shared.validate_file_scope(expanded, "./lib", repo_path) == :ok
    end

    test "rejects file outside node" do
      repo_path = "/home/user/repo"
      expanded = "/home/user/repo/test/app_test.exs"
      result = Shared.validate_file_scope(expanded, "./lib", repo_path)
      assert {:error, _msg} = result
    end

    test "returns error (not a crash) for absolute path outside the repo" do
      repo_path = "/home/user/repo"
      expanded = "/tmp/test_simple.c"
      result = Shared.validate_file_scope(expanded, "./lib", repo_path)
      assert {:error, message} = result
      assert message =~ "outside the repository root"
      assert message =~ "relative to the repository root"
      assert message =~ "/tmp/test_simple.c"
    end

    test "returns error for absolute path even when node is root" do
      repo_path = "/home/user/repo"
      expanded = "/etc/passwd"
      result = Shared.validate_file_scope(expanded, "./", repo_path)
      assert {:error, message} = result
      assert message =~ "outside the repository root"
    end

    test "allows any file when node_path is nil" do
      repo_path = "/home/user/repo"
      expanded = "/home/user/repo/any/path.ex"
      assert Shared.validate_file_scope(expanded, nil, repo_path) == :ok
    end

    test "rejects write path inside a read-only foreign repository" do
      Process.put(:foreign_repos, [
        %EvoGit.Core.ForeignRepo{id: "orig", root: "/home/user/orig", writable: false}
      ])

      on_exit(fn -> Process.delete(:foreign_repos) end)

      result =
        Shared.validate_file_scope("/home/user/orig/lib/app.ex", "./lib", "/home/user/repo")

      assert {:error, message} = result
      refute result == :ok
      assert message =~ "read-only foreign repository"
      assert message =~ "/home/user/orig"
    end

    test "rejects write path nested deep inside a read-only foreign repository" do
      Process.put(:foreign_repos, [
        %EvoGit.Core.ForeignRepo{id: "orig", root: "/home/user/orig", writable: false}
      ])

      on_exit(fn -> Process.delete(:foreign_repos) end)

      result =
        Shared.validate_file_scope(
          "/home/user/orig/deep/nested/file.ex",
          "./lib",
          "/home/user/repo"
        )

      assert {:error, message} = result
      assert message =~ "read-only foreign repository"
      assert message =~ "/home/user/orig"
    end

    test "allows write path inside a writable foreign repository" do
      Process.put(:foreign_repos, [
        %EvoGit.Core.ForeignRepo{id: "orig", root: "/home/user/orig", writable: true}
      ])

      on_exit(fn -> Process.delete(:foreign_repos) end)

      assert Shared.validate_file_scope("/home/user/orig/lib/app.ex", "./lib", "/home/user/orig") ==
               :ok
    end

    test "allows file in primary repo even when a read-only foreign repo is registered" do
      Process.put(:foreign_repos, [
        %EvoGit.Core.ForeignRepo{id: "orig", root: "/home/user/orig", writable: false}
      ])

      on_exit(fn -> Process.delete(:foreign_repos) end)

      assert Shared.validate_file_scope("/home/user/repo/lib/app.ex", "./lib", "/home/user/repo") ==
               :ok
    end

    test "allows file when no foreign repos are registered" do
      Process.put(:foreign_repos, [])
      on_exit(fn -> Process.delete(:foreign_repos) end)

      assert Shared.validate_file_scope("/home/user/repo/lib/app.ex", "./lib", "/home/user/repo") ==
               :ok
    end
  end

  describe "fetch_array_arg/2" do
    test "returns a real list unchanged" do
      assert Shared.fetch_array_arg(%{"args" => ["-n", "foo", "."]}, "args") ==
               {:ok, ["-n", "foo", "."]}
    end

    test "recovers a JSON-encoded string array transparently" do
      encoded = Jason.encode!(["-n", "foo", "."])
      assert Shared.fetch_array_arg(%{"args" => encoded}, "args") == {:ok, ["-n", "foo", "."]}
    end

    test "recovers a JSON-encoded array containing integers (coerced to strings)" do
      encoded = Jason.encode!(["-n", 123, "."])
      assert Shared.fetch_array_arg(%{"args" => encoded}, "args") == {:ok, ["-n", "123", "."]}
    end

    test "returns error for a non-JSON string" do
      result = Shared.fetch_array_arg(%{"args" => "not-json"}, "args")
      assert {:error, message} = result
      assert message =~ "must be an array"
    end

    test "returns error for a JSON string that decodes to a map, not a list" do
      encoded = Jason.encode!(%{"key" => 1})
      result = Shared.fetch_array_arg(%{"args" => encoded}, "args")
      assert {:error, message} = result
      assert message =~ "must be an array"
    end

    test "error message explains the double-encoding problem and is actionable" do
      encoded = Jason.encode!(["-n", "foo", "."])
      result = Shared.fetch_array_arg(%{"args" => encoded <> "}"}, "args")
      assert {:error, message} = result
      assert message =~ "must be an array"
      assert message =~ "JSON-encoded string"
      assert message =~ "Pass a real JSON array"
    end

    test "returns error for a non-binary, non-list value" do
      result = Shared.fetch_array_arg(%{"args" => 42}, "args")
      assert {:error, message} = result
      assert message =~ "must be an array"
    end

    test "returns error for a missing key" do
      result = Shared.fetch_array_arg(%{}, "args")
      assert {:error, message} = result
      assert message =~ "Missing required argument"
    end
  end

  describe "fetch_optional_boolean_arg/3" do
    test "returns the value when it is a boolean" do
      assert Shared.fetch_optional_boolean_arg(%{"commit" => false}, "commit", true) ==
               {:ok, false}

      assert Shared.fetch_optional_boolean_arg(%{"commit" => true}, "commit", false) ==
               {:ok, true}
    end

    test "returns the default when the key is absent" do
      assert Shared.fetch_optional_boolean_arg(%{}, "commit", true) == {:ok, true}
      assert Shared.fetch_optional_boolean_arg(%{}, "parents", true) == {:ok, true}
    end

    test "returns an error when the value is not a boolean" do
      assert {:error, message} =
               Shared.fetch_optional_boolean_arg(%{"commit" => "yes"}, "commit", true)

      assert message =~ "commit must be a boolean"
    end
  end

  describe "get_optional_string/3" do
    test "returns the value directly when it is a binary" do
      assert Shared.get_optional_string(%{"path" => "lib"}, "path", "./") == "lib"
    end

    test "returns the default when the key is absent" do
      assert Shared.get_optional_string(%{}, "path", "./") == "./"
    end

    test "coerces non-binary values to string via to_string/1" do
      assert Shared.get_optional_string(%{"path" => 42}, "path", "./") == "42"
    end
  end

  describe "get_optional_integer/3" do
    test "returns the value directly when it is an integer" do
      assert Shared.get_optional_integer(%{"context" => 5}, "context", 3) == 5
    end

    test "returns the default when the key is absent" do
      assert Shared.get_optional_integer(%{}, "context", 3) == 3
    end

    test "parses a valid integer binary" do
      assert Shared.get_optional_integer(%{"context" => "5"}, "context", 3) == 5
    end

    test "falls back to default on an unparseable binary (does not crash)" do
      assert Shared.get_optional_integer(%{"context" => "abc"}, "context", 3) == 3
    end

    test "falls back to default on a non-integer, non-binary value" do
      assert Shared.get_optional_integer(%{"context" => true}, "context", 3) == 3
    end
  end

  describe "get_optional_boolean/3" do
    test "returns the value directly when it is a boolean" do
      assert Shared.get_optional_boolean(%{"search_notes" => true}, "search_notes", true) == true

      assert Shared.get_optional_boolean(%{"search_notes" => false}, "search_notes", true) ==
               false
    end

    test "returns the default when the key is absent" do
      assert Shared.get_optional_boolean(%{}, "search_notes", true) == true
    end

    test "interprets truthy string variants as true" do
      for val <- ["true", "True", "TRUE", "1"] do
        assert Shared.get_optional_boolean(%{"search_notes" => val}, "search_notes", false) ==
                 true
      end
    end

    test "treats other strings as false (falls back to default)" do
      assert Shared.get_optional_boolean(%{"search_notes" => "yes"}, "search_notes", false) ==
               false
    end
  end

  describe "perform_string_replace/5 — same-path parallel safety" do
    test "N concurrent edits to the SAME file all land (no lost update)" do
      # Regression test for the same-path parallel file-mutation race. Parallel
      # tool calls run in SEPARATE processes; before the `with_file_lock/2` fix
      # in `perform_string_replace/5`, each call did a non-atomic
      # read-modify-write, so every concurrent call read the ORIGINAL bytes and
      # the last writer won — silently dropping every edit but one.
      n = 8
      path = unique_path("shared_race") <> ".txt"
      on_exit(fn -> File.rm_rf(path) end)

      File.write!(path, Enum.map_join(1..n, "\n", fn i -> "TOKEN_#{i}_ORIGINAL" end))

      results =
        1..n
        |> Task.async_stream(
          fn i ->
            Shared.perform_string_replace(
              path,
              path,
              "TOKEN_#{i}_ORIGINAL",
              "TOKEN_#{i}_EDITED",
              false
            )
          end,
          max_concurrency: n,
          ordered: false,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # Every one of the N edits must report success...
      success = "The file #{path} has been updated successfully."
      assert Enum.all?(results, &(&1 == success))

      # ...and every edit's bytes must survive to the final file.
      final = File.read!(path)

      for i <- 1..n do
        assert final =~ "TOKEN_#{i}_EDITED"
        refute final =~ "TOKEN_#{i}_ORIGINAL"
      end
    end
  end

  describe "with_file_lock/2" do
    test "mutual exclusion across DISTINCT processes for the SAME path" do
      path = unique_path("lock_exclusion")
      test_pid = self()

      # Each worker signals its intent, enters the critical section, reports its
      # arrival, then blocks until the test releases it — so the holder is
      # provably still inside while the peer attempts the same lock. `spawn_link`
      # guarantees a flunk kills the workers (and `:global` releases a dead
      # holder's lock), so neither a lock nor a process can leak.
      worker = fn id ->
        spawn_link(fn ->
          send(test_pid, {:attempting, id})

          Shared.with_file_lock(path, fn ->
            send(test_pid, {:entered, id})

            receive do
              :release -> :ok
            end

            send(test_pid, {:exiting, id})
          end)

          send(test_pid, {:done, id})
        end)
      end

      first = worker.(1)
      assert_receive {:attempting, 1}, @recv_timeout
      assert_receive {:entered, 1}, @recv_timeout

      second = worker.(2)
      assert_receive {:attempting, 2}, @recv_timeout

      # Worker 1 holds the lock, so worker 2 must NOT be inside. This bounded
      # negative window is the proof, not a sleep standing in for one.
      refute_receive {:entered, 2}, 300

      send(first, :release)
      assert_receive {:entered, 2}, @recv_timeout
      assert_receive {:exiting, 1}, @recv_timeout

      send(second, :release)
      assert_receive {:exiting, 2}, @recv_timeout
      assert_receive {:done, 1}, @recv_timeout
      assert_receive {:done, 2}, @recv_timeout
    end

    test "canonicalization — ./x and x resolve to ONE lock" do
      name = "shared_canon_#{System.unique_integer([:positive])}.ex"
      test_pid = self()

      # Both spellings expand to the SAME absolute path, which is the lock key.
      assert Path.expand("./" <> name) == Path.expand(name)

      holder =
        spawn_link(fn ->
          Shared.with_file_lock("./" <> name, fn ->
            send(test_pid, :canon_relative_entered)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :canon_relative_entered, @recv_timeout

      # A peer using the BARE spelling (no "./") must share the same lock — no
      # real file is needed, the lock is keyed purely on the expanded path.
      spawn_link(fn ->
        Shared.with_file_lock(name, fn ->
          send(test_pid, :canon_bare_entered)
        end)

        send(test_pid, :canon_bare_done)
      end)

      refute_receive :canon_bare_entered, 300

      send(holder, :release)
      assert_receive :canon_bare_entered, @recv_timeout
      assert_receive :canon_bare_done, @recv_timeout
    end

    test "a raising fun still releases the lock (release-on-raise)" do
      path = unique_path("lock_raise")

      assert_raise RuntimeError, "boom", fn ->
        Shared.with_file_lock(path, fn -> raise "boom" end)
      end

      # A DIFFERENT process must be able to take the same lock promptly, proving
      # it was released even though the guarded fun raised. A same-process
      # re-acquire would succeed regardless and so could not prove this.
      task = Task.async(fn -> Shared.with_file_lock(path, fn -> :acquired end) end)

      assert Task.await(task, @recv_timeout) == :acquired
    end

    test "same-process re-entry is granted immediately (never deadlocks)" do
      path = unique_path("lock_reentry")

      task =
        Task.async(fn ->
          Shared.with_file_lock(path, fn ->
            Shared.with_file_lock(path, fn -> :inner end)
          end)
        end)

      assert Task.await(task, @recv_timeout) == :inner
    end
  end

  # Unique per-test path under the system temp dir. The lock key derives from
  # `Path.expand/1`, so a unique path keeps these tests from ever contending
  # with another concurrently running module's lock.
  defp unique_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
  end
end
