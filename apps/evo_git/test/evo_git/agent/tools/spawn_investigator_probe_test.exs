defmodule EvoGit.Agent.Tools.SpawnInvestigatorProbeTest do
  @moduledoc """
  Unit tests for `EvoGit.Agent.Tools.SpawnInvestigatorProbe.investigate/2` —
  the deterministic bounded read-only codebase probe behind the
  `SpawnInvestigator.spawn_investigator` command.

  Pure filesystem tests over real tmp git fixtures; no LLM, no store, no
  TaskRegistry.

  `async: true` — each test builds its own fixture in the ExUnit `:tmp_dir`;
  the probe is read-only and touches no BEAM-global state.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias EvoGit.Agent.Tools.SpawnInvestigatorProbe

  describe "investigate/2 over a git repo fixture" do
    test "reports repo facts: absolute path, git confirmation, and checked-out ref",
         %{tmp_dir: tmp_dir} do
      repo = create_git_fixture!(tmp_dir)

      report = SpawnInvestigatorProbe.investigate(repo, "frobnicator module")

      assert is_binary(report)
      assert report =~ "## Repository"
      assert report =~ "Path: #{Path.expand(repo)}"
      assert report =~ "Git repository: yes"
      assert report =~ "refs/heads/"
    end

    test "includes the CONTEXT.md chain with root and nested excerpts", %{tmp_dir: tmp_dir} do
      repo = create_git_fixture!(tmp_dir, nested_context?: true)

      report = SpawnInvestigatorProbe.investigate(repo, "frobnicator module")

      assert report =~ "## CONTEXT.md chain (2 found, capped at 30)"
      assert report =~ "CONTEXT.md"
      assert report =~ "lib/CONTEXT.md"
      assert report =~ "Intent:"
    end

    test "includes the top-level inventory with counts", %{tmp_dir: tmp_dir} do
      repo = create_git_fixture!(tmp_dir)

      report = SpawnInvestigatorProbe.investigate(repo, "frobnicator module")

      assert report =~ "## Top-level inventory (2 entries: 1 directories, 1 files"
      assert report =~ "dir  lib"
      assert report =~ "file CONTEXT.md"
    end

    test "finds objective-keyword hits with the file, line number, and excerpt",
         %{tmp_dir: tmp_dir} do
      repo = create_git_fixture!(tmp_dir)

      report = SpawnInvestigatorProbe.investigate(repo, "frobnicator module")

      assert report =~ "lib/frobnicator.ex:1"
      assert report =~ "defmodule Frobnicator"
      assert report =~ "[frobnicator, module]"
    end

    test "reports no keyword matches gracefully", %{tmp_dir: tmp_dir} do
      repo = create_git_fixture!(tmp_dir)

      report = SpawnInvestigatorProbe.investigate(repo, "zzzqqq")

      assert report =~ "No files matched the objective keywords."
    end
  end

  describe "investigate/2 never raises on odd inputs" do
    test "an objective with only stopwords yields no keywords", %{tmp_dir: tmp_dir} do
      repo = create_git_fixture!(tmp_dir)

      report = SpawnInvestigatorProbe.investigate(repo, "the and of it")

      assert is_binary(report)
      assert report =~ "Keywords: (none)"
    end

    test "an empty non-git directory returns a report without raising", %{tmp_dir: tmp_dir} do
      empty = Path.join(tmp_dir, "empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)

      report = SpawnInvestigatorProbe.investigate(empty, "anything at all")

      assert is_binary(report)
      assert report =~ "Git repository: no"
    end

    test "a directory holding only ignored noise dirs returns a report", %{tmp_dir: tmp_dir} do
      noisy = Path.join(tmp_dir, "noisy_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(noisy, "node_modules"))
      File.mkdir_p!(Path.join(noisy, "_build"))
      File.write!(Path.join([noisy, "node_modules", "dep.js"]), "module.exports = 1;\n")

      report = SpawnInvestigatorProbe.investigate(noisy, "dep")

      assert is_binary(report)
      assert report =~ "Git repository: no"
    end

    test "a path pointing at a regular file returns a report without raising", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "a_regular_file_#{System.unique_integer([:positive])}.txt")
      File.write!(file, "not a directory\n")

      report = SpawnInvestigatorProbe.investigate(file, "anything")

      assert is_binary(report)
      assert report =~ "Git repository: no"
    end

    test "a non-existent path returns a report without raising" do
      missing = "/definitely/not/a/real/repo/path_#{System.unique_integer([:positive])}"

      report = SpawnInvestigatorProbe.investigate(missing, "x")

      assert is_binary(report)
      assert report =~ "Git repository: no"
    end

    test "non-string path/objective arguments are skipped gracefully" do
      report = SpawnInvestigatorProbe.investigate(nil, "x")

      assert is_binary(report)
      assert report =~ "Investigation skipped"
    end
  end

  # --- Helpers -------------------------------------------------------------

  # Creates a real git repo fixture under tmp_root with an initial commit, a
  # root CONTEXT.md, and a `lib/frobnicator.ex` source file whose content
  # matches the "frobnicator module" objective keywords. `nested_context?:`
  # also adds a `lib/CONTEXT.md`. Returns the repo path.
  defp create_git_fixture!(tmp_root, opts \\ []) do
    repo = Path.join(tmp_root, "repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: repo)

    File.write!(Path.join(repo, "CONTEXT.md"), """
    # Fixture Repo

    Intent: a tiny fixture repository used by spawn-investigator probe tests.
    """)

    File.mkdir_p!(Path.join(repo, "lib"))

    if Keyword.get(opts, :nested_context?, false) do
      File.write!(Path.join([repo, "lib", "CONTEXT.md"]), """
      # Lib Context

      Intent: nested documentation for the lib directory.
      """)
    end

    File.write!(
      Path.join([repo, "lib", "frobnicator.ex"]),
      "defmodule Frobnicator do\n  def run, do: :ok\nend\n"
    )

    {_, 0} = System.cmd("git", ["add", "."], cd: repo)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "initial commit"], cd: repo)
    repo
  end
end
