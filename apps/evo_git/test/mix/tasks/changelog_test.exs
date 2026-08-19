defmodule Mix.Tasks.ChangelogTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Changelog

  # The task runs `System.cmd("git", ...)` in the VM's current directory and
  # uses Mix.shell/0, both of which are process-global — hence async: false.
  @new_version "0.2.0"

  # Deterministic entries returned by the summarizer stubs.
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

  # Installs a deterministic whole-pipeline stub via the :changelog_summarizer
  # application-env seam, restoring the previous value (or removing it) on exit.
  # Contract: (model, version, prs) -> {:ok, entries} | {:error, reason}.
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

  # Installs a deterministic stage-1 (per-PR) stub via the
  # :changelog_pr_summarizer application-env seam. Contract:
  # (model, version, pr) -> {:ok, summary :: String.t()} | {:error, reason}.
  defp with_pr_summarizer(fun) do
    previous = Application.get_env(:evo_git, :changelog_pr_summarizer)
    Application.put_env(:evo_git, :changelog_pr_summarizer, fun)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:evo_git, :changelog_pr_summarizer)
      else
        Application.put_env(:evo_git, :changelog_pr_summarizer, previous)
      end
    end)
  end

  # Installs a deterministic stage-2 (aggregator) stub via the
  # :changelog_aggregator application-env seam. Contract:
  # (model, version, summaries) -> {:ok, entries} | {:error, reason}.
  defp with_aggregator(fun) do
    previous = Application.get_env(:evo_git, :changelog_aggregator)
    Application.put_env(:evo_git, :changelog_aggregator, fun)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:evo_git, :changelog_aggregator)
      else
        Application.put_env(:evo_git, :changelog_aggregator, previous)
      end
    end)
  end

  # Builds a REAL merge on top of the current history: branches off HEAD, adds
  # one commit per message, then merges back with --no-ff so the merge commit
  # has two parents (not a fast-forward). Returns the branch commit subjects in
  # the order `git log --no-merges <merge>^1..<merge>` reports them (newest
  # first).
  defp build_merge(tmp_dir, branch_name, commit_msgs) do
    base_branch = git_out(tmp_dir, ["rev-parse", "--abbrev-ref", "HEAD"])

    git(tmp_dir, ["checkout", "-q", "-b", branch_name])

    Enum.with_index(commit_msgs)
    |> Enum.each(fn {msg, i} ->
      File.write!(Path.join(tmp_dir, "feature_#{branch_name}.txt"), "#{i}\n")
      git(tmp_dir, ["add", "--all"])
      git(tmp_dir, ["commit", "-q", "-m", msg])
    end)

    git(tmp_dir, ["checkout", "-q", base_branch])
    git(tmp_dir, ["merge", "-q", "--no-ff", "-m", "Merge #{branch_name}", branch_name])

    Enum.reverse(commit_msgs)
  end

  # Runs the pipeline with the two stage seams stubbed (PR-grouping tests):
  # stage 1 records each PR and returns its newest commit's subject as the
  # summary; stage 2 records the summaries and returns the deterministic stub
  # entries.
  defp install_stage_seams do
    with_pr_summarizer(fn _model, _version, pr ->
      send(self(), {:pr_summarized, pr})
      {:ok, hd(pr.commits).subject}
    end)

    with_aggregator(fn _model, _version, summaries ->
      send(self(), {:aggregated_summaries, summaries})
      {:ok, @stub_entries}
    end)
  end

  # Drains all {:pr_summarized, pr} messages left in the test process mailbox.
  defp collect_pr_summaries(acc \\ []) do
    receive do
      {:pr_summarized, pr} -> collect_pr_summaries([pr | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "creates CHANGELOG.md when missing and commits it when confirmed", %{tmp_dir: tmp_dir} do
    with_summarizer(fn _model, _version, _prs -> {:ok, @stub_entries} end)
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
    with_summarizer(fn _model, _version, _prs -> {:ok, @stub_entries} end)
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
    with_summarizer(fn _model, _version, _prs -> {:ok, @stub_entries} end)
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
    with_summarizer(fn _model, _version, prs ->
      send(self(), {:summarized_prs, prs})
      {:ok, []}
    end)

    send(self(), {:mix_shell_input, :yes?, false})

    File.cd!(tmp_dir, fn ->
      Changelog.run([@new_version])
    end)

    assert_received {:summarized_prs, prs}

    subjects = prs |> Enum.flat_map(& &1.commits) |> Enum.map(& &1.subject)
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
    with_summarizer(fn _model, _version, _prs -> {:ok, @stub_entries} end)
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

  test "each merge is one PR whose stage-1 input is exactly its branch commits", %{
    tmp_dir: tmp_dir
  } do
    branch_subjects =
      build_merge(tmp_dir, "feature-x", ["add feature X part 1", "add feature X part 2"])

    install_stage_seams()
    send(self(), {:mix_shell_input, :yes?, false})

    File.cd!(tmp_dir, fn ->
      Changelog.run([@new_version])
    end)

    prs = collect_pr_summaries()

    # The merge PR carries EXACTLY the branch commits it brought in — not the
    # whole history.
    merge_pr = Enum.find(prs, fn pr -> length(pr.commits) == 2 end)
    assert merge_pr != nil
    assert merge_pr.head_sha != nil
    assert Enum.map(merge_pr.commits, & &1.subject) == branch_subjects

    merge_subjects = Enum.map(merge_pr.commits, & &1.subject)
    refute "add feature A" in merge_subjects
    refute "fix bug B" in merge_subjects
    refute "initial commit" in merge_subjects

    # Direct first-parent commits appear as single-commit PRs.
    single = Enum.filter(prs, fn pr -> length(pr.commits) == 1 end)
    assert length(single) == 2

    assert Enum.map(single, fn pr -> hd(pr.commits).subject end) |> Enum.sort() ==
             ["add feature A", "fix bug B"]

    # Stage 2 received one summary line per PR, in first-parent order.
    assert_received {:aggregated_summaries, summaries}
    assert length(summaries) == 3
    assert hd(summaries) == "add feature X part 2"
  end

  test "excludes version-bump and mechanical commits from every PR", %{tmp_dir: tmp_dir} do
    # A direct version-bump commit on the first-parent line — must produce no PR.
    File.write!(Path.join(tmp_dir, "file.txt"), "v4\n")
    git(tmp_dir, ["add", "--all"])
    git(tmp_dir, ["commit", "-q", "-m", "Bump version to 0.2.0"])

    # A merge whose branch mixes a real change with version-bump/mechanical noise.
    build_merge(tmp_dir, "feature-z", [
      "add feature Z",
      "Bump version to 0.3.0",
      "Update mix hash"
    ])

    install_stage_seams()
    send(self(), {:mix_shell_input, :yes?, false})

    File.cd!(tmp_dir, fn ->
      Changelog.run([@new_version])
    end)

    prs = collect_pr_summaries()
    all_subjects = prs |> Enum.flat_map(& &1.commits) |> Enum.map(& &1.subject)

    refute Enum.any?(all_subjects, &String.starts_with?(&1, "Bump version to"))
    refute Enum.any?(all_subjects, &String.starts_with?(&1, "Update mix hash"))

    assert "add feature Z" in all_subjects

    # The direct version-bump commit did not produce its own PR.
    refute Enum.any?(prs, fn pr -> hd(pr.commits).subject == "Bump version to 0.2.0" end)
  end

  test "works with a range containing only non-merge commits", %{tmp_dir: tmp_dir} do
    install_stage_seams()
    send(self(), {:mix_shell_input, :yes?, false})

    File.cd!(tmp_dir, fn ->
      Changelog.run([@new_version])
    end)

    prs = collect_pr_summaries()
    assert length(prs) == 2
    assert Enum.all?(prs, fn pr -> length(pr.commits) == 1 end)

    subjects = prs |> Enum.flat_map(& &1.commits) |> Enum.map(& &1.subject)
    assert "add feature A" in subjects
    assert "fix bug B" in subjects

    assert_received {:aggregated_summaries, summaries}
    assert length(summaries) == 2
  end

  # Runs git in the given directory, raising on failure (test setup only).
  defp git(cd, args) do
    {output, code} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} failed: #{output}"
    :ok
  end

  # Runs git in the given directory, returning trimmed stdout (test setup only).
  defp git_out(cd, args) do
    {output, code} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} failed: #{output}"
    String.trim(output)
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
