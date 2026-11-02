defmodule Mix.Tasks.Bench.IoTest do
  @moduledoc """
  Tests for `Mix.Tasks.Bench.Io.parse_args/1` — the pure argument parser behind
  `mix bench.io`.

  `parse_args/1` never prints and never raises, so every case here is a plain
  function call: no Mix shell swap, no git, no filesystem, no app-env mutation.
  `async: true`.

  Only the DOCUMENTED contract is asserted: the applied defaults, both flag
  spellings, help precedence, and that an invalid setting is rejected with a
  message naming the offending option (never the exact wording).
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Bench.Io

  describe "parse_args/1 defaults" do
    test "an empty argv applies every EvoGit.Bench default" do
      assert {:ok, opts} = Io.parse_args([])

      assert opts[:iterations] == 5
      assert opts[:warmup] == 1
      assert opts[:files] == 200
      assert opts[:writes] == 20
      assert opts[:reads] == 20
      assert opts[:file_size] == 4096
      assert opts[:seed] == 42
      assert opts[:fsync] == false
      assert opts[:keep] == false
      assert opts[:dir] == System.tmp_dir!()
      assert opts[:label] == EvoGit.Bench.defaults()[:label]
    end

    test "defaults come from EvoGit.Bench.defaults/0 (the single source)" do
      assert {:ok, opts} = Io.parse_args([])
      defaults = EvoGit.Bench.defaults()

      Enum.each(
        [:iterations, :warmup, :files, :writes, :reads, :file_size, :seed, :dir, :label],
        fn key ->
          assert opts[key] == defaults[key], "default mismatch for #{key}"
        end
      )
    end
  end

  describe "parse_args/1 flags" do
    test "parses long flags over the defaults" do
      assert {:ok, opts} =
               Io.parse_args([
                 "--iterations",
                 "3",
                 "--warmup",
                 "2",
                 "--files",
                 "10",
                 "--writes",
                 "3",
                 "--reads",
                 "4",
                 "--file-size",
                 "128",
                 "--seed",
                 "7",
                 "--label",
                 "x",
                 "--dir",
                 "/tmp/x"
               ])

      assert opts[:iterations] == 3
      assert opts[:warmup] == 2
      assert opts[:files] == 10
      assert opts[:writes] == 3
      assert opts[:reads] == 4
      assert opts[:file_size] == 128
      assert opts[:seed] == 7
      assert opts[:label] == "x"
      assert opts[:dir] == "/tmp/x"
    end

    test "parses the -n alias for --iterations" do
      assert {:ok, opts} = Io.parse_args(["-n", "3"])

      assert opts[:iterations] == 3
      assert opts[:files] == 200
    end

    test "parses the boolean flags" do
      assert {:ok, opts} = Io.parse_args(["--fsync", "--keep"])

      assert opts[:fsync] == true
      assert opts[:keep] == true
    end

    test "carries --json through for run/1 to consume" do
      assert {:ok, opts} = Io.parse_args(["--json"])

      assert opts[:json] == true

      # An option the caller did not pass is simply absent.
      assert {:ok, plain} = Io.parse_args([])
      assert Keyword.get(plain, :json) == nil
    end
  end

  describe "parse_args/1 help" do
    test "--help returns {:help}" do
      assert Io.parse_args(["--help"]) == {:help}
    end

    test "-h returns {:help}" do
      assert Io.parse_args(["-h"]) == {:help}
    end

    test "help wins over every other token, including invalid ones" do
      assert Io.parse_args(["--iterations", "0", "--help"]) == {:help}
      assert Io.parse_args(["--help", "--iterations", "0"]) == {:help}
      assert Io.parse_args(["--bogus", "-h"]) == {:help}
      assert Io.parse_args(["-h", "positional"]) == {:help}
    end
  end

  describe "parse_args/1 rejections" do
    test "rejects settings below their minimum, naming the option" do
      for {argv, option} <- [
            {["--iterations", "0"], "iterations"},
            {["--warmup", "-1"], "warmup"},
            {["--files", "0"], "files"},
            {["--writes", "0"], "writes"},
            {["--reads", "0"], "reads"},
            {["--file-size", "0"], "file_size"}
          ] do
        assert {:error, message} = Io.parse_args(argv), "expected #{inspect(argv)} to be rejected"
        assert is_binary(message)
        assert message =~ option
      end
    end

    test "rejects a non-integer value for an integer option" do
      assert {:error, message} = Io.parse_args(["--iterations", "abc"])

      assert is_binary(message)
      assert message =~ "iterations"
    end

    test "rejects an unknown flag" do
      assert {:error, message} = Io.parse_args(["--bogus"])

      assert is_binary(message)
    end

    test "rejects positional arguments" do
      assert {:error, message} = Io.parse_args(["extra"])

      assert is_binary(message)
    end
  end
end
