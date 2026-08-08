defmodule EvoGit.PathSuggestionsTest do
  @moduledoc """
  Tests for `EvoGit.PathSuggestions.suggest/1`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.PathSuggestions

  describe "suggest/1" do
    test "returns [] for nil and empty values" do
      assert PathSuggestions.suggest(nil) == []
      assert PathSuggestions.suggest("") == []
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
