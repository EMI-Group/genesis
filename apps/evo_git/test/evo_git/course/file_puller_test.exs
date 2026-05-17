defmodule EvoGit.Course.FilePullerTest do
  use ExUnit.Case, async: true

  alias EvoGit.Course.FilePuller

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "evo_git_file_puller_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    # Save original env so we don't leak between async tests
    original_builder = Application.get_env(:evo_git, :builder_node, :__unset__)
    original_remote_dir = Application.get_env(:evo_git, :builder_remote_dir, :__unset__)

    on_exit(fn ->
      if original_builder == :__unset__ do
        Application.delete_env(:evo_git, :builder_node)
      else
        Application.put_env(:evo_git, :builder_node, original_builder)
      end

      if original_remote_dir == :__unset__ do
        Application.delete_env(:evo_git, :builder_remote_dir)
      else
        Application.put_env(:evo_git, :builder_remote_dir, original_remote_dir)
      end
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  describe "pull/3 — error paths" do
    test "returns :no_builder_configured when builder_node is nil", %{tmp_dir: tmp_dir} do
      Application.put_env(:evo_git, :builder_node, nil)

      courses_dir = Path.join(tmp_dir, "courses")
      File.mkdir_p!(courses_dir)

      assert {:error, :no_builder_configured} =
               FilePuller.pull("test_course", courses_dir)
    end

    @tag :skip
    test "returns error when builder node is not reachable", %{tmp_dir: tmp_dir} do
      # This test requires Erlang distribution to be available.
      # When run with `--sname test` or `--name test@host`, the erpc call
      # to a non-existent node will fail relatively quickly with :erpc_failure.
      # Without distribution, :erpc.call may hang or produce unpredictable results.
      Application.put_env(:evo_git, :builder_node, :nonexistent@localhost)

      courses_dir = Path.join(tmp_dir, "courses")
      File.mkdir_p!(courses_dir)

      result = FilePuller.pull("test_course", courses_dir)

      # Should be an error tuple — exact shape depends on erpc failure mode
      assert {:error, _reason} = result
    end

    @tag :skip
    test "extracts .tar.zst after successful pull (indirect extraction test)", %{tmp_dir: tmp_dir} do
      # This test requires a real Erlang cluster with a builder node that
      # serves the tar.zst artifact. It demonstrates the full happy path:
      #   1. builder_node is configured
      #   2. A .tar.zst exists at the remote path
      #   3. pull_artifact transfers it via erpc
      #   4. extract unpacks it to the local courses dir
      #   5. cleanup_temp_tar removes the temp tar file
      #
      # When a builder node is available, remove @tag :skip and set up:
      #   - builder_node pointing to the real builder
      #   - A course tar.zst at the remote path expected by remote_tar_path/1

      courses_dir = Path.join(tmp_dir, "courses")
      File.mkdir_p!(courses_dir)

      # Simulate the tar.zst creation that would happen on the builder node.
      # The tar is placed directly in courses_dir to mimic what ensure_temp_tar
      # would produce, allowing extract to find it after pull_artifact succeeds.
      course_name = "test_course"
      tar_name = "#{course_name}.tar.zst"
      tar_path = Path.join(courses_dir, tar_name)

      # Create a minimal tar.zst archive with a known file
      content_dir = Path.join(tmp_dir, "content")
      File.mkdir_p!(content_dir)
      File.write!(Path.join(content_dir, "index.html"), "<h1>Hello</h1>")

      {_output, 0} =
        System.cmd("tar", ["--zstd", "-cf", tar_path, "-C", content_dir, "."])

      assert File.exists?(tar_path)

      # NOTE: When builder_node is set to a real, reachable node,
      # this pull call will transfer the tar, extract it, and clean up.
      # The assertions below verify the expected extraction behavior.
      # result = FilePuller.pull(course_name, courses_dir)
      # assert {:ok, extracted_dir} = result
      # assert File.dir?(extracted_dir)
      # assert File.exists?(Path.join(extracted_dir, "index.html"))
      # refute File.exists?(tar_path)  # temp tar should be cleaned up
    end
  end

  describe "pull/3 — temp directory handling" do
    test "creates local_courses_dir if it does not exist", %{tmp_dir: tmp_dir} do
      Application.put_env(:evo_git, :builder_node, nil)

      courses_dir = Path.join(tmp_dir, "nonexistent_courses")

      # courses_dir does not exist yet
      refute File.dir?(courses_dir)

      # pull fails due to no builder, but ensure_temp_tar creates the dir first
      assert {:error, :no_builder_configured} =
               FilePuller.pull("test_course", courses_dir)

      # The dir should have been created by ensure_temp_tar -> File.mkdir_p
      assert File.dir?(courses_dir)
    end
  end
end
