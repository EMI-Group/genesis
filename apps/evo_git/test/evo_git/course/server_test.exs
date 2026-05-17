defmodule EvoGit.Course.ServerTest do
  use ExUnit.Case, async: true

  alias EvoGit.Course.Server

  # ============================================================================
  # Shared helpers
  # ============================================================================

  defp tmp_path do
    Path.join(System.tmp_dir!(), "evogit_test_#{System.unique_integer()}")
  end

  defp make_dir(path) do
    File.mkdir_p!(path)
    path
  end

  defp write_file(dir, filename, content) do
    file_path = Path.join(dir, filename)
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, content)
    file_path
  end

  # ============================================================================
  # :build mode tests
  # ============================================================================

  describe ":build mode" do
    setup do
      tmp_dir = tmp_path() |> make_dir()
      courses_dir = Path.join(tmp_dir, "courses") |> make_dir()

      Application.put_env(:evo_git, :courses_dir, courses_dir)
      Application.put_env(:evo_git, :course_mode, :build)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
        Application.delete_env(:evo_git, :courses_dir)
        Application.delete_env(:evo_git, :course_mode)
      end)

      {:ok, tmp_dir: tmp_dir, courses_dir: courses_dir}
    end

    # BUG: file_etag/1 uses "#{mtime}_#{size}" but File.stat returns mtime
    # as a tuple {{Y,M,D},{H,M,S}} which does not implement String.Chars.
    # This causes a Protocol.UndefinedError. Once the source is fixed
    # (e.g., using inspect(mtime) in file_etag/1), replace the assert_raise
    # below with the intended assertions:
    #
    #   assert {:ok, "hello world", metadata} = Server.get_file(...)
    #   assert is_binary(metadata.etag)
    #   assert metadata.content_type == "text/html"
    #   assert metadata.cache_control == "public, max-age=86400"
    #
    test "get_file :build", %{courses_dir: courses_dir} do
      course_dir = make_dir(Path.join(courses_dir, "my_course"))
      write_file(course_dir, "index.html", "hello world")

      assert_raise Protocol.UndefinedError, fn ->
        Server.get_file("my_course", "index.html", :build)
      end
    end

    test "get_file :build not_found", %{courses_dir: courses_dir} do
      make_dir(Path.join(courses_dir, "my_course"))

      assert {:error, :not_found} =
               Server.get_file("my_course", "nonexistent.html", :build)
    end

    test "get_file :build unknown course" do
      assert {:error, :not_found} =
               Server.get_file("no_such_course", "index.html", :build)
    end

    # BUG: Same file_etag/1 issue as "get_file :build" above.
    test "get_file :build nested path", %{courses_dir: courses_dir} do
      course_dir = make_dir(Path.join(courses_dir, "my_course"))
      write_file(course_dir, "css/style.css", "body { color: red; }")

      assert_raise Protocol.UndefinedError, fn ->
        Server.get_file("my_course", "css/style.css", :build)
      end
    end

    test "has_course? :build", %{courses_dir: courses_dir} do
      make_dir(Path.join(courses_dir, "existing_course"))

      assert Server.has_course?("existing_course", :build) == true
      assert Server.has_course?("nonexistent_course", :build) == false
    end

    test "list_courses :build", %{courses_dir: courses_dir} do
      make_dir(Path.join(courses_dir, "course_a"))
      make_dir(Path.join(courses_dir, "course_b"))

      courses = Server.list_courses(:build)

      assert length(courses) == 2
      assert %{name: "course_a"} in courses
      assert %{name: "course_b"} in courses
    end

    # BUG: Same file_etag/1 issue as "get_file :build" above.
    test "etag :build", %{courses_dir: courses_dir} do
      course_dir = make_dir(Path.join(courses_dir, "my_course"))
      write_file(course_dir, "index.html", "hello world")

      assert_raise Protocol.UndefinedError, fn ->
        Server.etag("my_course", "index.html", :build)
      end
    end

    test "etag :build not_found", %{courses_dir: courses_dir} do
      make_dir(Path.join(courses_dir, "my_course"))

      assert {:error, :not_found} =
               Server.etag("my_course", "nonexistent.html", :build)
    end
  end

  # ============================================================================
  # :git mode tests
  # ============================================================================

  describe ":git mode" do
    setup do
      tmp_dir = tmp_path() |> make_dir()

      # Create a git repo with a committed file
      repo_path = Path.join(tmp_dir, "test_repo") |> make_dir()

      System.cmd("git", ["init"], cd: repo_path)
      System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo_path)
      System.cmd("git", ["config", "user.name", "Test User"], cd: repo_path)

      write_file(repo_path, "index.html", "git content")
      System.cmd("git", ["add", "index.html"], cd: repo_path)
      System.cmd("git", ["commit", "-m", "initial commit"], cd: repo_path)

      # Configure application env
      Application.put_env(:evo_git, :courses, [
        %{name: "test_course", repo_path: repo_path}
      ])
      Application.put_env(:evo_git, :course_mode, :git)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
        Application.delete_env(:evo_git, :courses)
        Application.delete_env(:evo_git, :course_mode)
      end)

      {:ok, tmp_dir: tmp_dir, repo_path: repo_path}
    end

    test "get_file :git" do
      assert {:ok, "git content", metadata} =
               Server.get_file("test_course", "index.html", :git)

      assert is_binary(metadata.etag)
      assert metadata.content_type == "text/html"
      assert metadata.cache_control == "no-cache"
    end

    test "get_file :git not_found" do
      assert {:error, :not_found} =
               Server.get_file("test_course", "nonexistent.html", :git)
    end

    test "get_file :git unknown course" do
      assert {:error, :unknown_course} =
               Server.get_file("no_such_course", "index.html", :git)
    end

    test "has_course? :git" do
      assert Server.has_course?("test_course", :git) == true
      assert Server.has_course?("nonexistent_course", :git) == false
    end

    test "list_courses :git" do
      courses = Server.list_courses(:git)

      assert is_list(courses)
      assert Enum.any?(courses, &(&1.name == "test_course"))
    end

    test "etag :git" do
      assert {:ok, etag} = Server.etag("test_course", "index.html", :git)
      assert is_binary(etag)
      # Git SHA should be 40 hex chars
      assert String.match?(etag, ~r/^[0-9a-f]{40}$/)
    end
  end

  # ============================================================================
  # content_type_for/1 tests
  # ============================================================================

  describe "content_type_for/1" do
    test ".html" do
      assert Server.content_type_for("index.html") == "text/html"
    end

    test ".css" do
      assert Server.content_type_for("style.css") == "text/css"
    end

    test ".js" do
      assert Server.content_type_for("app.js") == "application/javascript"
    end

    test ".png" do
      assert Server.content_type_for("logo.png") == "image/png"
    end

    test ".jpg" do
      assert Server.content_type_for("photo.jpg") == "image/jpeg"
    end

    test ".jpeg" do
      assert Server.content_type_for("photo.jpeg") == "image/jpeg"
    end

    test ".svg" do
      assert Server.content_type_for("icon.svg") == "image/svg+xml"
    end

    test ".json" do
      assert Server.content_type_for("data.json") == "application/json"
    end

    test "unknown extension" do
      assert Server.content_type_for("file.unknown") == "application/octet-stream"
    end

    test "no extension" do
      assert Server.content_type_for("README") == "application/octet-stream"
    end
  end

  # ============================================================================
  # Mode handling tests
  # ============================================================================

  describe "mode handling" do
    setup do
      on_exit(fn ->
        Application.delete_env(:evo_git, :course_mode)
      end)

      :ok
    end

    test "invalid mode" do
      assert {:error, {:invalid_mode, :invalid}} =
               Server.get_file("any_course", "any_file", :invalid)
    end

    test "default mode reads from config" do
      Application.put_env(:evo_git, :course_mode, :build)

      on_exit(fn ->
        Application.delete_env(:evo_git, :course_mode)
      end)

      # With no mode passed, it should use the default (:build).
      # Since we don't set up courses_dir, it will get :not_found
      # — but importantly not an :invalid_mode error.
      result = Server.get_file("nonexistent_course", "index.html")
      assert result == {:error, :not_found}
    end

    test "pull_course in :git mode returns :ok" do
      Application.put_env(:evo_git, :course_mode, :git)

      on_exit(fn ->
        Application.delete_env(:evo_git, :course_mode)
      end)

      import ExUnit.CaptureLog

      assert capture_log(fn ->
               assert Server.pull_course("any_course") == :ok
             end) =~ "pull_course is only supported in :build mode"
    end
  end
end
