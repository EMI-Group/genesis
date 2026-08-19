defmodule Mix.Tasks.ChangelogTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Changelog

  # The task runs `System.cmd("git", ...)` in the VM's current directory and
  # uses Mix.shell/0, both of which are process-global — hence async: false.
  @new_version "0.2.0"

  # Deterministic entries returned by the summarizer stub.
  @stub_entries [
    %{category: "Added", text: "Adds a new dashboard widget"},
    %{category: "Fixed", text: "Fixes a crash on empty results"}
  ]

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "evo_git_changelog_test_" <> to_string(System.unique_integer())
      )

    File.mkdir_p!(tmp_dir)

    git(tmp_dir, ["init", "-q"])
    git(tmp_dir, ["config", "user.email", "test@example.com"])
    git(tmp_dir, ["config", "user.name", "Test"])

    # Baseline commit, tagged v0.1.0 — must be excluded by the default tag range.
    File.write!(Path.join(tmp_dir, "file.txt"), "v1\n")
    git(tmp_dir, ["add", "--all"])
    git(tmp_dir, ["commit", "-q", "-m", "initial commit"])
    git(tmp_dir, ["tag", "v0.1.0"])

    # Feature commits after the tag.
    File.write!(Path.join(tmp_dir, "file.txt"), "v2\n")
    git(tmp_dir, ["add", "--all"])
    git(tmp_dir, ["commit", "-q", "-m", "add feature A"])

    File.write!(Path.join(tmp_dir, "file.txt"), "v3\n")
    git(tmp_dir, ["add", "--all"])
    git(tmp_dir, ["commit", "-q", "-m", "fix bug B"])

    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  # Installs a deterministic summarizer stub via the :changelog_summarizer
  # application-env seam, restoring the previous value (or removing it) on exit.
  defp with_summarizer(fun) do
    previous = Application.get_env(:evo_git, :changelog_summarizer)
    Application.put_env(:evo_git, :changelog_summarizer, fun)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:evo_git, :changelog_summarizer)
      else
        Application.put_env(:evo_git, :changelog_summarizer, previous)
      end
    end)
  end

  test "creates CHANGELOG.md when missing and commits it when confirmed", %{tmp_dir: tmp_dir} do
    with_summarizer(fn _model, _version, _commits -> {:ok, @stub_entries} end)
    send(self(), {:mix_shell_input, :yes?, true})

    File.cd!(tmp_dir, fn ->
      Changelog.run([@new_version])
    end)

    changelog = Path.join(tmp_dir, "CHANGELOG.md")
    assert File.exists?(changelog)

    content = File.read!(changelog)
    assert content =~ "# Changelog"
    assert content =~ "## [Unreleased]"
    assert content =~ ~r/## \[0\.2\.0\] - \d{4}-\d{2}-\d{2}/
    assert content =~ "### Added"
    assert content =~ "- Adds a new dashboard widget"
    assert content =~ "### Fixed"
    assert content =~ "- Fixes a crash on empty results"

    assert_received {:mix_shell, :yes?, ["Commit the changelog file now? [Yn]"]}

    # A commit was created staging exactly CHANGELOG.md and nothing else.
    {out, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: tmp_dir)
    assert out == "Add changelog for v0.2.0\n"

    {out, 0} =
      System.cmd("git", ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"], cd: tmp_dir)

    assert out |> String.split("\n", trim: true) == ["CHANGELOG.md"]
  end

  test "prepends the new version section to an existing CHANGELOG.md", %{tmp_dir: tmp_dir} do
    existing = """
    # Changelog

    All notable changes to this project will be documented in this file.

    ## [0.1.0] - 2026-01-15

    ### Added

    - Initial release
    """

    File.write!(Path.join(tmp_dir, "CHANGELOG.md"), existing)
    with_summarizer(fn _model, _version, _commits -> {:ok, @stub_entries} end)
    send(self(), {:mix_shell_input, :yes?, false})

    File.cd!(tmp_dir, fn ->
      Changelog.run([@new_version])
    end)

    content = File.read!(Path.join(tmp_dir, "CHANGELOG.md"))
    assert content =~ ~r/## \[0\.2\.0\] - \d{4}-\d{2}-\d{2}/

    # The older section is preserved below the new one.
    assert content =~ "## [0.1.0] - 2026-01-15"
    assert content =~ "- Initial release"

    # The new section appears before the old one.
    [before_old, _rest] = String.split(content, "## [0.1.0]", parts: 2)
    assert before_old =~ "## [0.2.0]"
  end

  test "replaces an existing same-version section (no duplicates on re-run)", %{
    tmp_dir: tmp_dir
  } do
    with_summarizer(fn _model, _version, _commits -> {:ok, @stub_entries} end)
    send(self(), {:mix_shell_input, :yes?, false})
    send(self(), {:mix_shell_input, :yes?, false})

    File.cd!(tmp_dir, fn ->
      Changelog.run([@new_version])
      Changelog.run([@new_version])
    end)

    content = File.read!(Path.join(tmp_dir, "CHANGELOG.md"))
    assert length(Regex.scan(~r/^## \[0\.2\.0\]/m, content)) == 1
  end

  test "defaults the range to the last tag (commits before it are excluded)", %{
    tmp_dir: tmp_dir
  } do
    with_summarizer(fn _model, _version, commits ->
      send(self(), {:summarized_commits, commits})
      {:ok, []}
    end)

    send(self(), {:mix_shell_input, :yes?, false})

    File.cd!(tmp_dir, fn ->
      Changelog.run([@new_version])
    end)

    assert_received {:summarized_commits, commits}

    subjects = Enum.map(commits, & &1.subject)
    refute "initial commit" in subjects
    assert "add feature A" in subjects
    assert "fix bug B" in subjects
  end

  test "prints a usage error when the version argument is missing", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      Changelog.run([])
    end)

    assert_received {:mix_shell, :error,
                     [
                       "Usage: mix changelog <version> [--from <ref>] [--to <ref>] [--model <id>] [--file <path>]"
                     ]}

    refute File.exists?(Path.join(tmp_dir, "CHANGELOG.md"))
  end

  test "writes the file but does not commit when the commit prompt is declined", %{
    tmp_dir: tmp_dir
  } do
    with_summarizer(fn _model, _version, _commits -> {:ok, @stub_entries} end)
    send(self(), {:mix_shell_input, :yes?, false})

    File.cd!(tmp_dir, fn ->
      Changelog.run([@new_version])
    end)

    changelog = Path.join(tmp_dir, "CHANGELOG.md")
    assert File.exists?(changelog)
    assert File.read!(changelog) =~ ~r/## \[0\.2\.0\] - \d{4}-\d{2}-\d{2}/

    # HEAD is still the last feature commit — nothing was committed.
    {out, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: tmp_dir)
    assert out == "fix bug B\n"

    # Manual instructions were printed as a fallback.
    infos = collect_infos()
    assert Enum.any?(infos, &String.contains?(&1, "git add CHANGELOG.md"))
  end

  # Runs git in the given directory, raising on failure (test setup only).
  defp git(cd, args) do
    {output, code} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} failed: #{output}"
    :ok
  end

  # Drains all {:mix_shell, :info, [msg]} messages left in the test process mailbox.
  defp collect_infos(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> collect_infos([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
