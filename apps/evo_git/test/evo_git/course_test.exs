defmodule EvoGit.CourseTest do
  use ExUnit.Case, async: true

  alias EvoGit.Course

  setup do
    # Clean any pre-existing config for the keys we test
    old_mode = Application.get_env(:evo_git, :course_mode)
    old_builder_node = Application.get_env(:evo_git, :builder_node)
    old_courses_dir = Application.get_env(:evo_git, :courses_dir)
    old_course_builds_dir = Application.get_env(:evo_git, :course_builds_dir)
    old_courses = Application.get_env(:evo_git, :courses)

    Application.delete_env(:evo_git, :course_mode)
    Application.delete_env(:evo_git, :builder_node)
    Application.delete_env(:evo_git, :courses_dir)
    Application.delete_env(:evo_git, :course_builds_dir)
    Application.delete_env(:evo_git, :courses)

    on_exit(fn ->
      restore_env(:evo_git, :course_mode, old_mode)
      restore_env(:evo_git, :builder_node, old_builder_node)
      restore_env(:evo_git, :courses_dir, old_courses_dir)
      restore_env(:evo_git, :course_builds_dir, old_course_builds_dir)
      restore_env(:evo_git, :courses, old_courses)
    end)

    :ok
  end

  defp restore_env(_app, _key, nil), do: :ok

  defp restore_env(app, key, value) do
    Application.put_env(app, key, value)
  end

  describe "struct" do
    test "creates with all fields" do
      course = %Course{
        name: "elixir-basics",
        repo_path: "/var/evogit/courses/elixir-basics",
        branches: ["main", "exercise-1"],
        output_dir: "/tmp/evogit_builds/elixir-basics"
      }

      assert course.name == "elixir-basics"
      assert course.repo_path == "/var/evogit/courses/elixir-basics"
      assert course.branches == ["main", "exercise-1"]
      assert course.output_dir == "/tmp/evogit_builds/elixir-basics"
    end

    test "creates with nil output_dir" do
      course = %Course{
        name: "no-output-course",
        repo_path: "/var/evogit/courses/no-output",
        branches: [],
        output_dir: nil
      }

      assert course.name == "no-output-course"
      assert course.repo_path == "/var/evogit/courses/no-output"
      assert course.branches == []
      assert course.output_dir == nil
    end

    test "enforces required fields at compile time" do
      # Missing :name should raise a KeyError at compile time
      assert_raise ArgumentError, ~r/name/, fn ->
        Code.eval_string("""
        defmodule StructTest do
          alias EvoGit.Course
          %Course{repo_path: "/tmp", branches: [], output_dir: nil}
        end
        """)
      end
    end
  end

  describe "mode/0" do
    test "returns :build when no config is set" do
      assert Course.mode() == :build
    end

    test "returns :git when configured" do
      Application.put_env(:evo_git, :course_mode, :git)
      assert Course.mode() == :git
    end

    test "returns configured value when set to :build explicitly" do
      Application.put_env(:evo_git, :course_mode, :build)
      assert Course.mode() == :build
    end
  end

  describe "builder_node/0" do
    test "returns nil when not configured" do
      assert Course.builder_node() == nil
    end

    test "returns the configured node" do
      Application.put_env(:evo_git, :builder_node, "node-xyz-123")
      assert Course.builder_node() == "node-xyz-123"
    end

    test "returns configured atom node" do
      Application.put_env(:evo_git, :builder_node, :primary_builder)
      assert Course.builder_node() == :primary_builder
    end
  end

  describe "courses_dir/0" do
    test "returns default when not configured" do
      assert Course.courses_dir() == "/var/evogit/courses"
    end

    test "returns the configured value" do
      Application.put_env(:evo_git, :courses_dir, "/custom/courses/path")
      assert Course.courses_dir() == "/custom/courses/path"
    end

    test "returns configured value when set to a different path" do
      Application.put_env(:evo_git, :courses_dir, "/opt/evogit_data/courses")
      assert Course.courses_dir() == "/opt/evogit_data/courses"
    end
  end

  describe "builds_dir/0" do
    test "returns default when not configured" do
      assert Course.builds_dir() == "/tmp/evogit_builds"
    end

    test "returns the configured value" do
      Application.put_env(:evo_git, :course_builds_dir, "/custom/builds/path")
      assert Course.builds_dir() == "/custom/builds/path"
    end

    test "returns configured value when set to a different path" do
      Application.put_env(:evo_git, :course_builds_dir, "/opt/evogit_data/builds")
      assert Course.builds_dir() == "/opt/evogit_data/builds"
    end
  end

  describe "list/0" do
    test "returns empty list when not configured" do
      assert Course.list() == []
    end

    test "returns configured courses" do
      courses = [
        %Course{
          name: "elixir-101",
          repo_path: "/var/evogit/courses/elixir-101",
          branches: ["main"],
          output_dir: nil
        },
        %Course{
          name: "advanced-otp",
          repo_path: "/var/evogit/courses/advanced-otp",
          branches: ["main", "exercises"],
          output_dir: "/tmp/evogit_builds/advanced-otp"
        }
      ]

      Application.put_env(:evo_git, :courses, courses)
      assert Course.list() == courses
    end

    test "returns single course list" do
      course = [
        %Course{
          name: "single-course",
          repo_path: "/var/evogit/courses/single",
          branches: ["main"],
          output_dir: "/tmp/builds/single"
        }
      ]

      Application.put_env(:evo_git, :courses, course)
      assert Course.list() == course
      assert length(Course.list()) == 1
    end
  end
end
