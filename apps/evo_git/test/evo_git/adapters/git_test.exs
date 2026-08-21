defmodule EvoGit.Adapters.GitTest do
  use ExUnit.Case, async: true

  alias EvoGit.Adapters.Git

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evo_git_test_repo_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)
    Git.init(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  test "commit returns ok when there are no changes", %{tmp_dir: tmp_dir} do
    # Make an initial commit
    File.write!(Path.join(tmp_dir, "test.txt"), "initial content")
    {:ok, _} = Git.add(tmp_dir, "test.txt")
    {:ok, _} = Git.commit(tmp_dir, "Initial commit")

    # Attempt to commit again with no changes
    assert {:ok, _} = Git.commit(tmp_dir, "Commit with no changes")
  end

  test "commit returns ok when there are changes", %{tmp_dir: tmp_dir} do
    # Make an initial commit
    File.write!(Path.join(tmp_dir, "test_with_changes.txt"), "initial content")
    {:ok, _} = Git.add(tmp_dir, "test_with_changes.txt")
    {:ok, _} = Git.commit(tmp_dir, "Initial commit for changes")

    # Make changes and commit again
    File.write!(Path.join(tmp_dir, "test_with_changes.txt"), "updated content")
    {:ok, _} = Git.add(tmp_dir, "test_with_changes.txt")
    assert {:ok, _} = Git.commit(tmp_dir, "Second commit with changes")
  end

  test "check_ignore returns ignored files", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, ".gitignore"), "ignored.txt\n*.log")

    files = ["normal.txt", "ignored.txt", "some.log", "subdir/another.log"]
    {:ok, ignored} = Git.check_ignore(tmp_dir, files)

    assert "ignored.txt" in ignored
    assert "some.log" in ignored
    assert "subdir/another.log" in ignored
    assert length(ignored) == 3

    # Test with no ignored files
    {:ok, ignored} = Git.check_ignore(tmp_dir, ["normal.txt", "other.txt"])
    assert ignored == []
  end

  test "log and file_history", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "test.txt"), "initial content")
    Git.add(tmp_dir, "test.txt")
    Git.commit(tmp_dir, "Initial commit")

    File.write!(Path.join(tmp_dir, "test.txt"), "updated content")
    Git.add(tmp_dir, "test.txt")
    Git.commit(tmp_dir, "Updated commit")

    assert {:ok, log_output} = Git.log(tmp_dir, ["--oneline"])
    assert String.contains?(log_output, "Updated commit")
    assert String.contains?(log_output, "Initial commit")

    assert {:ok, history} = Git.file_history(tmp_dir, "test.txt", ["--oneline"])
    assert String.contains?(history, "Updated commit")
    assert String.contains?(history, "Initial commit")
  end

  test "show object", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "test.txt"), "initial content")
    Git.add(tmp_dir, "test.txt")
    Git.commit(tmp_dir, "Initial commit")

    assert {:ok, show_output} = Git.show(tmp_dir, "HEAD:test.txt")
    assert show_output == "initial content"
  end

  test "diff and file_diff", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
    Git.add(tmp_dir, "test.txt")
    Git.commit(tmp_dir, "Initial commit")

    {:ok, commit_a} = Git.rev_parse(tmp_dir, "HEAD")

    File.write!(Path.join(tmp_dir, "test.txt"), "updated content\n")
    Git.add(tmp_dir, "test.txt")
    Git.commit(tmp_dir, "Updated commit")

    {:ok, commit_b} = Git.rev_parse(tmp_dir, "HEAD")

    assert {:ok, diff_output} = Git.diff(tmp_dir, commit_a, commit_b)
    assert String.contains?(diff_output, "-initial content")
    assert String.contains?(diff_output, "+updated content")

    assert {:ok, file_diff_output} = Git.file_diff(tmp_dir, "test.txt", commit_a, commit_b)
    assert String.contains?(file_diff_output, "-initial content")
    assert String.contains?(file_diff_output, "+updated content")
  end

  test "git notes", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
    Git.add(tmp_dir, "test.txt")
    Git.commit(tmp_dir, "Initial commit")

    {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

    # Add note
    assert {:ok, _} = Git.add_note(tmp_dir, commit_sha, "My test note")

    # Show note
    assert {:ok, note_content} = Git.show_note(tmp_dir, commit_sha)
    assert String.trim(note_content) == "My test note"

    # List notes
    assert {:ok, notes_list} = Git.list_notes(tmp_dir)
    assert String.contains?(notes_list, commit_sha)

    # Remove note
    assert {:ok, _} = Git.remove_note(tmp_dir, commit_sha)

    # Show note again, should fail because note doesn't exist
    assert {:error, {:conflict, _}} = Git.show_note(tmp_dir, commit_sha)
  end

  describe "get_note/3" do
    test "returns parsed JSON map for valid note", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")

      {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

      assert {:ok, _} =
               Git.add_note(tmp_dir, commit_sha, ~s({"key": "value", "num": 42}))

      assert {:ok, %{"key" => "value", "num" => 42}} = Git.get_note(tmp_dir, commit_sha)
    end

    test "returns parsed JSON map with --ref=evogit", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")

      {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

      # add_note/4 and get_note/3 now correctly place --ref between "notes" and subcommand
      assert {:ok, _} =
               Git.add_note(tmp_dir, commit_sha, ~s({"agent_id": "test123"}), ["--ref=evogit"])

      assert {:ok, %{"agent_id" => "test123"}} =
               Git.get_note(tmp_dir, commit_sha, ["--ref=evogit"])
    end

    test "returns error when note is not valid JSON", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")

      {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

      assert {:ok, _} = Git.add_note(tmp_dir, commit_sha, "plain text note")

      assert {:error, {:invalid_json, _}} = Git.get_note(tmp_dir, commit_sha)
    end

    test "returns error when no note exists", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")

      {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

      assert {:error, {:no_note, _}} = Git.get_note(tmp_dir, commit_sha)
    end

    test "hostile content round-trips exactly through add_note/get_note", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")

      {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

      # Realistic mini-JSON metadata blob: double quotes, newlines, and `>`
      # characters — all of which break Windows command-line tokenization when
      # passed via `git notes add -m <message>` (quoted args get split into
      # "unknown switch `>'" / "too many arguments").
      hostile_json =
        ~S({"agent_id": "a1", "objective": "Fix '>' redirect handling",
"result": "line one\nline two > done",
"note": "contains \"quotes\""})

      assert {:ok, _} = Git.add_note(tmp_dir, commit_sha, hostile_json)

      assert {:ok, decoded_map} = Git.get_note(tmp_dir, commit_sha)
      assert decoded_map == Jason.decode!(hostile_json)

      # show_note returns raw content; be tolerant of a possible trailing
      # newline (the -F file path may preserve file content as-is).
      assert {:ok, note_content} = Git.show_note(tmp_dir, commit_sha)
      assert String.trim(note_content) == String.trim(hostile_json)
    end

    test "force overwrite with different hostile content", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")

      {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

      hostile_json_1 =
        ~S({"agent_id": "a1", "objective": "Fix '>' redirect handling",
"result": "line one\nline two > done",
"note": "contains \"quotes\""})

      hostile_json_2 =
        ~S({"agent_id": "a2", "objective": "Handle \"nested\" > redirects",
"result": "second result\n> done",
"note": "other \"quotes\""})

      assert {:ok, _} = Git.add_note(tmp_dir, commit_sha, hostile_json_1)
      assert {:ok, _} = Git.add_note(tmp_dir, commit_sha, hostile_json_2, [], true)

      assert {:ok, decoded_map} = Git.get_note(tmp_dir, commit_sha)
      assert decoded_map == Jason.decode!(hostile_json_2)
    end
  end

  describe "update_ref/3 and delete_ref/2" do
    test "creates a ref pointing to a specific commit", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")

      {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

      ref_name = "refs/genesis/archive/test-create"

      assert {:ok, _} = Git.update_ref(tmp_dir, ref_name, commit_sha)

      # Verify the ref resolves to the right SHA
      assert {:ok, ^commit_sha} = Git.rev_parse(tmp_dir, ref_name)
    end

    test "deletes an existing ref", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")

      {:ok, commit_sha} = Git.rev_parse(tmp_dir, "HEAD")

      ref_name = "refs/genesis/archive/test-delete"

      assert {:ok, _} = Git.update_ref(tmp_dir, ref_name, commit_sha)
      assert {:ok, ^commit_sha} = Git.rev_parse(tmp_dir, ref_name)

      # Delete the ref
      assert {:ok, _} = Git.delete_ref(tmp_dir, ref_name)

      # Verify it no longer resolves
      assert {:error, {_, _}} = Git.rev_parse(tmp_dir, ref_name)
    end

    test "updates an existing ref to a new SHA", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "first\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "First commit")

      {:ok, first_sha} = Git.rev_parse(tmp_dir, "HEAD")

      ref_name = "refs/genesis/archive/test-update"

      # Create ref at first commit
      assert {:ok, _} = Git.update_ref(tmp_dir, ref_name, first_sha)
      assert {:ok, ^first_sha} = Git.rev_parse(tmp_dir, ref_name)

      # Make a new commit
      File.write!(Path.join(tmp_dir, "test.txt"), "second\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Second commit")

      {:ok, second_sha} = Git.rev_parse(tmp_dir, "HEAD")

      # Update ref to the new commit
      assert {:ok, _} = Git.update_ref(tmp_dir, ref_name, second_sha)
      assert {:ok, ^second_sha} = Git.rev_parse(tmp_dir, ref_name)
    end
  end

  describe "GIT_EDITOR configuration" do
    test "true executable is resolved to a non-nil path ending in 'true'", %{tmp_dir: tmp_dir} do
      # The resolved `true` path is memoized via :persistent_term; clear the cache
      # so we exercise the real resolution path regardless of test ordering.
      :persistent_term.erase({EvoGit.GitEnv, :true_path})

      # Trigger git_env() resolution by invoking run/2, which populates the cache.
      {:ok, _} = Git.run(["status", "--porcelain"], tmp_dir)

      resolved = :persistent_term.get({EvoGit.GitEnv, :true_path}, nil)
      assert is_binary(resolved)
      assert String.ends_with?(resolved, "true")
    end

    test "run/2 wires GIT_EDITOR so git reports a no-op editor", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "initial content\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")

      # `git var GIT_EDITOR` prints the editor git would launch. With GIT_EDITOR
      # set to the `true` executable, this resolves to a path/name ending in
      # "true" (a no-op), proving the env is passed through to the git subprocess.
      assert {:ok, editor} = Git.run(["var", "GIT_EDITOR"], tmp_dir)
      assert String.ends_with?(editor, "true")
    end

    test "merge does not block on an interactive editor", %{tmp_dir: tmp_dir} do
      # Two divergent branches that would both modify the same file. A merge that
      # completes without conflict should NOT open an editor. This exercises the
      # merge path with GIT_EDITOR wired in.
      File.write!(Path.join(tmp_dir, "a.txt"), "initial\n")
      Git.add(tmp_dir, "a.txt")
      Git.commit(tmp_dir, "Initial commit")

      {:ok, base} = Git.rev_parse(tmp_dir, "HEAD")

      # Create a second branch with a non-conflicting change.
      Git.create_branch(tmp_dir, "feature", base)
      File.write!(Path.join(tmp_dir, "b.txt"), "feature\n")
      Git.add(tmp_dir, "b.txt")
      Git.commit(tmp_dir, "Feature commit")

      # Back to main, merge the feature branch (fast-forward not possible due
      # to being on the branch — create a divergent commit on main first).
      Git.checkout(tmp_dir, "master")
      File.write!(Path.join(tmp_dir, "c.txt"), "main\n")
      Git.add(tmp_dir, "c.txt")
      Git.commit(tmp_dir, "Main commit")

      # Resolve the feature branch SHA and merge it.
      {:ok, feature_sha} = Git.rev_parse(tmp_dir, "feature")
      assert {:ok, _} = Git.merge(tmp_dir, feature_sha)
    end
  end

  describe "clone, fetch, merge_ff_only, rev_parse_short, remote_url" do
    test "clone/3 shallow-clones a repository and clone/2 works with defaults", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "test.txt"), "hello\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")
      {:ok, branch} = Git.current_branch(tmp_dir)

      origin = tmp_dir <> "-origin"
      File.mkdir_p!(origin)
      {:ok, _} = Git.run(["init", "--bare"], origin)
      {:ok, _} = Git.run(["symbolic-ref", "HEAD", "refs/heads/#{branch}"], origin)
      {:ok, _} = Git.run(["remote", "add", "origin", origin], tmp_dir)
      {:ok, _} = Git.push_branch(tmp_dir, branch)

      clone_dir = tmp_dir <> "-clone"
      on_exit(fn -> File.rm_rf!(clone_dir) end)
      assert {:ok, _} = Git.clone(origin, clone_dir, ["--depth", "1"])
      assert File.read!(Path.join(clone_dir, "test.txt")) == "hello\n"

      # Default-args variant (clone/2) works too.
      clone2 = tmp_dir <> "-clone2"
      on_exit(fn -> File.rm_rf!(clone2) end)
      assert {:ok, _} = Git.clone(origin, clone2)
      assert File.read!(Path.join(clone2, "test.txt")) == "hello\n"
    end

    test "fetch/2 and merge_ff_only/2 fast-forward a full clone", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "hello\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")
      {:ok, branch} = Git.current_branch(tmp_dir)

      origin = tmp_dir <> "-origin"
      File.mkdir_p!(origin)
      {:ok, _} = Git.run(["init", "--bare"], origin)
      {:ok, _} = Git.run(["symbolic-ref", "HEAD", "refs/heads/#{branch}"], origin)
      {:ok, _} = Git.run(["remote", "add", "origin", origin], tmp_dir)
      {:ok, _} = Git.push_branch(tmp_dir, branch)

      # A FULL clone (merge --ff-only needs connected ancestry; a depth-1
      # shallow clone severs it on re-fetch).
      clone_dir = tmp_dir <> "-clone"
      on_exit(fn -> File.rm_rf!(clone_dir) end)
      assert {:ok, _} = Git.clone(origin, clone_dir)

      # New commit pushed to origin, then fetch + ff-only merge.
      File.write!(Path.join(tmp_dir, "test.txt"), "hello v2\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Second commit")
      {:ok, _} = Git.push_branch(tmp_dir, branch)

      assert {:ok, _} = Git.fetch(clone_dir)
      assert {:ok, _} = Git.merge_ff_only(clone_dir, "origin/#{branch}")

      {:ok, clone_head} = Git.rev_parse(clone_dir, "HEAD")
      {:ok, source_head} = Git.rev_parse(tmp_dir, "HEAD")
      assert clone_head == source_head
      assert File.read!(Path.join(clone_dir, "test.txt")) == "hello v2\n"
    end

    test "rev_parse_short/2 returns the abbreviated HEAD sha", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test.txt"), "hello\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")

      {:ok, full} = Git.rev_parse(tmp_dir, "HEAD")
      {:ok, short} = Git.rev_parse_short(tmp_dir)
      assert String.starts_with?(full, short)
      assert String.length(short) >= 7

      # Explicit rev argument variant.
      {:ok, short_head} = Git.rev_parse_short(tmp_dir, "HEAD")
      assert short_head == short
    end

    test "remote_url/1,2 returns the origin URL and errors without a remote", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "test.txt"), "hello\n")
      Git.add(tmp_dir, "test.txt")
      Git.commit(tmp_dir, "Initial commit")

      origin = tmp_dir <> "-origin"
      File.mkdir_p!(origin)
      {:ok, _} = Git.run(["init", "--bare"], origin)
      {:ok, _} = Git.run(["remote", "add", "origin", origin], tmp_dir)

      assert {:ok, url} = Git.remote_url(tmp_dir)
      assert url == origin

      # Explicit remote-name variant.
      assert {:ok, ^origin} = Git.remote_url(tmp_dir, "origin")

      # A repo with no origin → error tuple.
      other = tmp_dir <> "-noremote"
      File.mkdir_p!(other)
      on_exit(fn -> File.rm_rf!(other) end)
      Git.init(other)
      assert {:error, _} = Git.remote_url(other)
    end
  end
end
