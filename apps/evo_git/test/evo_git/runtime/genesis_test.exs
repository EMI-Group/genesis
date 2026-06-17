defmodule EvoGit.Runtime.GenesisTest do
  use ExUnit.Case, async: true

  alias EvoGit.Runtime.Helpers

  describe "new_codebase?/1 auto-detection" do
    test "returns true for a repo with only .gitignore and .evogit" do
      tmp_dir = System.tmp_dir!() |> Path.join("evogit-genesis-new-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, ".gitignore"), "/.evogit\n")
      File.mkdir_p!(Path.join(tmp_dir, ".evogit"))

      assert Helpers.new_codebase?(tmp_dir) == true

      File.rm_rf!(tmp_dir)
    end

    test "returns true for a completely empty directory" do
      tmp_dir = System.tmp_dir!() |> Path.join("evogit-genesis-empty-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)

      assert Helpers.new_codebase?(tmp_dir) == true

      File.rm_rf!(tmp_dir)
    end

    test "returns false when real source files are present" do
      tmp_dir = System.tmp_dir!() |> Path.join("evogit-genesis-files-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, ".gitignore"), "/.evogit\n")
      File.write!(Path.join(tmp_dir, "main.py"), "print('hello')")

      assert Helpers.new_codebase?(tmp_dir) == false

      File.rm_rf!(tmp_dir)
    end

    test "returns true for a repo with .gitignore, .evogit, and README.md" do
      tmp_dir = System.tmp_dir!() |> Path.join("evogit-genesis-readme-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      File.write!(Path.join(tmp_dir, ".gitignore"), "/.evogit\n")
      File.mkdir_p!(Path.join(tmp_dir, ".evogit"))
      File.write!(Path.join(tmp_dir, "README.md"), "# Project")

      assert Helpers.new_codebase?(tmp_dir) == true

      File.rm_rf!(tmp_dir)
    end
  end
end
