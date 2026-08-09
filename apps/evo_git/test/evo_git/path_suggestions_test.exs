defmodule EvoGit.PathSuggestionsTest do
  @moduledoc """
  Tests for `EvoGit.PathSuggestions.suggest/1`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.PathSuggestions

  describe "suggest/1" do
    test "returns [] for nil, empty, and blank values" do
      assert PathSuggestions.suggest(nil) == []
      assert PathSuggestions.suggest("") == []
      assert PathSuggestions.suggest("   ") == []
    end

    test "returns [] for relative input — never cwd-anchored" do
      cwd = File.cwd!()

      # Bare names are not expanded against File.cwd!() anymore.
      assert PathSuggestions.suggest("Test") == []
      assert PathSuggestions.suggest("test") == []

      # Relative paths with separators.
      assert PathSuggestions.suggest("foo/bar") == []
      assert PathSuggestions.suggest("foo\\bar") == []

      # Volume-relative (drive letter without a separator) → [].
      assert PathSuggestions.suggest("D:Test") == []

      # Root-relative (leading backslash without a share) → [].
      assert PathSuggestions.suggest("\\Test") == []

      # Bare tilde-username forms are NOT tilde paths → [].
      assert PathSuggestions.suggest("~bogus") == []

      # Nothing relative may ever produce cwd-anchored suggestions.
      refute Enum.any?(
               PathSuggestions.suggest("Test") ++
                 PathSuggestions.suggest("foo/bar") ++
                 PathSuggestions.suggest("D:Test") ++
                 PathSuggestions.suggest("\\Test") ++
                 PathSuggestions.suggest("~bogus"),
               &String.starts_with?(&1, cwd)
             )
    end

    test "lists entries from a temp dir: dirs first, then case-insensitive names" do
      base = tmp_dir()
      on_exit(fn -> File.rm_rf!(base) end)

      # Directories
      File.mkdir_p!(Path.join(base, "AlphaDir"))
      File.mkdir_p!(Path.join(base, "beta_dir"))
      # Files
      File.write!(Path.join(base, "alpha_file.txt"), "")
      File.write!(Path.join(base, "gamma.txt"), "")

      # Trailing separator: list the directory itself with no prefix filter.
      assert PathSuggestions.suggest(base <> "/") == [
               Path.join(base, "AlphaDir"),
               Path.join(base, "beta_dir"),
               Path.join(base, "alpha_file.txt"),
               Path.join(base, "gamma.txt")
             ]
    end

    test "prefix-filters case-insensitively via the dirname/basename split" do
      base = tmp_dir()
      on_exit(fn -> File.rm_rf!(base) end)

      File.mkdir_p!(Path.join(base, "AlphaDir"))
      File.mkdir_p!(Path.join(base, "beta_dir"))
      File.write!(Path.join(base, "alpha_file.txt"), "")
      File.write!(Path.join(base, "gamma.txt"), "")

      # Value contains a separator → dir = dirname, prefix = basename,
      # matched case-insensitively.
      assert PathSuggestions.suggest(base <> "/ALPHA") == [
               Path.join(base, "AlphaDir"),
               Path.join(base, "alpha_file.txt")
             ]

      assert PathSuggestions.suggest(base <> "/BETA") == [Path.join(base, "beta_dir")]

      # No match → [].
      assert PathSuggestions.suggest(base <> "/zzz") == []
    end

    test "absolute partial input lists from that base" do
      # "/tm" → dirname "/" filtered by "tm"; "/tmp" exists on POSIX hosts.
      assert PathSuggestions.suggest("/tm") == ["/tmp"]

      # Windows-style absolute partials never crash and never anchor to cwd.
      # On POSIX hosts the drive/UNC root does not exist, so the listing
      # fails and the result is [] (on Windows these resolve to the drive).
      for input <- ["D:\\Pro", "C:/Us", "\\\\server\\share"] do
        assert PathSuggestions.suggest(input) == []
      end
    end

    test "tilde input is home-anchored" do
      home = System.user_home!()

      # "~" alone lists the home directory itself.
      results = PathSuggestions.suggest("~")
      assert results != []
      assert Enum.all?(results, &String.starts_with?(&1, home))

      # "~/x" prefixes within the home directory (may be [] — no crash).
      tilde_x = PathSuggestions.suggest("~/x")
      assert is_list(tilde_x)
      assert Enum.all?(tilde_x, &String.starts_with?(&1, home))

      # Trailing-separator tilde forms list the home itself too.
      assert PathSuggestions.suggest("~/") == results
    end

    test "returns [] for a non-existent dir" do
      missing = Path.join(System.tmp_dir!(), "no_such_dir_#{System.unique_integer([:positive])}")

      assert PathSuggestions.suggest(missing <> "/") == []
      assert PathSuggestions.suggest(missing <> "/foo") == []
    end

    test "caps results at 15 suggestions" do
      base = tmp_dir()
      on_exit(fn -> File.rm_rf!(base) end)

      for i <- 1..20 do
        File.write!(Path.join(base, "file_#{String.pad_leading("#{i}", 2, "0")}.txt"), "")
      end

      assert length(PathSuggestions.suggest(base <> "/file")) == 15
    end
  end

  defp tmp_dir do
    base =
      Path.join(
        System.tmp_dir!(),
        "evogit_path_suggestions_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    base
  end
end
