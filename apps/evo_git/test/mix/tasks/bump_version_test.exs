defmodule Mix.Tasks.Bump.VersionTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Bump.Version

  # The task runs `System.cmd("git", ...)` in the VM's current directory and
  # uses Mix.shell/0, both of which are process-global — hence async: false.
  @new_version "0.2.0"

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "evo_git_bump_version_test_" <> to_string(System.unique_integer())
      )

    File.mkdir_p!(Path.join(tmp_dir, "desktop/src-tauri"))

    File.write!(Path.join(tmp_dir, "VERSION"), "0.1.0\n")

    File.write!(
      Path.join(tmp_dir, "desktop/src-tauri/tauri.conf.json"),
      """
      {
        "version": "0.1.0",
        "productName": "Genesis"
      }
      """
    )

    File.write!(
      Path.join(tmp_dir, "desktop/src-tauri/Cargo.toml"),
      """
      [package]
      name = "genesis-desktop"
      version = "0.1.0"
      """
    )

    File.write!(
      Path.join(tmp_dir, "desktop/src-tauri/Cargo.lock"),
      """
      [[package]]
      name = "genesis-desktop"
      version = "0.1.0"
      """
    )

    File.write!(
      Path.join(tmp_dir, "README.md"),
      "# Genesis\n\n![version](https://img.shields.io/badge/version-0.1.0-8b5cf6)\n"
    )

    System.cmd("git", ["init", "-q"], cd: tmp_dir)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)
    System.cmd("git", ["add", "--all"], cd: tmp_dir)
    System.cmd("git", ["commit", "-q", "-m", "baseline"], cd: tmp_dir)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  test "bumps the files and commits exactly the touched files when confirmed", %{
    tmp_dir: tmp_dir
  } do
    Mix.shell(Mix.Shell.Process)
    send(self(), {:mix_shell_input, :yes?, true})
    # Decline the changelog prompt — no LLM call, no CHANGELOG.md.
    send(self(), {:mix_shell_input, :yes?, false})

    File.cd!(tmp_dir, fn ->
      Version.run([@new_version])
    end)

    # All version-bearing files were updated.
    assert File.read!(Path.join(tmp_dir, "VERSION")) == "0.2.0\n"
    assert File.read!(Path.join(tmp_dir, "README.md")) =~ "version-0.2.0-8b5cf6"

    assert File.read!(Path.join(tmp_dir, "desktop/src-tauri/tauri.conf.json")) =~
             "\"version\": \"0.2.0\""

    assert File.read!(Path.join(tmp_dir, "desktop/src-tauri/Cargo.toml")) =~
             "version = \"0.2.0\""

    assert File.read!(Path.join(tmp_dir, "desktop/src-tauri/Cargo.lock")) =~
             "version = \"0.2.0\""

    # A commit was created containing exactly the touched files and nothing else.
    {out, 0} =
      System.cmd("git", ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"], cd: tmp_dir)

    assert out |> String.split("\n", trim: true) |> Enum.sort() ==
             [
               "README.md",
               "VERSION",
               "desktop/src-tauri/Cargo.lock",
               "desktop/src-tauri/Cargo.toml",
               "desktop/src-tauri/tauri.conf.json"
             ]

    {out, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: tmp_dir)
    assert out == "Bump version to 0.2.0\n"

    # The interactive prompt was asked and the summary no longer suggests `git add -A`.
    assert_received {:mix_shell, :yes?, ["Commit the version bump files now? [Yn]"]}
    assert_received {:mix_shell, :yes?, ["Generate changelog for v0.2.0 now? [Yn]"]}
    refute File.exists?(Path.join(tmp_dir, "CHANGELOG.md"))
    infos = collect_infos()
    refute Enum.any?(infos, &String.contains?(&1, "git add -A"))
  end

  test "does not commit when the prompt is declined but files are still updated", %{
    tmp_dir: tmp_dir
  } do
    Mix.shell(Mix.Shell.Process)
    send(self(), {:mix_shell_input, :yes?, false})
    # Decline the changelog prompt — no LLM call, no CHANGELOG.md.
    send(self(), {:mix_shell_input, :yes?, false})

    File.cd!(tmp_dir, fn ->
      Version.run([@new_version])
    end)

    # Files are still bumped…
    assert File.read!(Path.join(tmp_dir, "VERSION")) == "0.2.0\n"
    assert File.read!(Path.join(tmp_dir, "README.md")) =~ "version-0.2.0-8b5cf6"

    # …but HEAD is still the baseline commit — nothing was committed.
    {out, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: tmp_dir)
    assert out == "baseline\n"

    # The changelog prompt was asked and declined — no changelog was generated.
    assert_received {:mix_shell, :yes?, ["Generate changelog for v0.2.0 now? [Yn]"]}
    refute File.exists?(Path.join(tmp_dir, "CHANGELOG.md"))

    # Manual instructions listing only the touched files were printed.
    infos = collect_infos()

    assert Enum.any?(infos, fn msg ->
             msg =~
               "git add VERSION desktop/src-tauri/tauri.conf.json desktop/src-tauri/Cargo.toml desktop/src-tauri/Cargo.lock README.md && git commit -m \"Bump version to 0.2.0\""
           end)
  end

  test "warns and does not crash when git commit fails (missing identity)", %{tmp_dir: tmp_dir} do
    Mix.shell(Mix.Shell.Process)
    send(self(), {:mix_shell_input, :yes?, true})
    # Decline the changelog prompt — no LLM call, no CHANGELOG.md.
    send(self(), {:mix_shell_input, :yes?, false})

    # Blank the repo-local identity so `git commit` fails — the bump itself
    # must still succeed and the task must not crash.
    System.cmd("git", ["config", "user.email", ""], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", ""], cd: tmp_dir)

    File.cd!(tmp_dir, fn ->
      Version.run([@new_version])
    end)

    assert File.read!(Path.join(tmp_dir, "VERSION")) == "0.2.0\n"

    errors = collect_errors()
    assert Enum.any?(errors, &String.contains?(&1, "git commit failed"))
    assert Enum.any?(errors, &String.contains?(&1, "Please tell me who you are"))

    # Manual instructions are printed as a fallback.
    infos = collect_infos()
    assert Enum.any?(infos, &String.contains?(&1, "git add VERSION"))

    # The changelog prompt was asked and declined — no changelog was generated.
    assert_received {:mix_shell, :yes?, ["Generate changelog for v0.2.0 now? [Yn]"]}
    refute File.exists?(Path.join(tmp_dir, "CHANGELOG.md"))
  end

  test "does not prompt or change anything when the version is already current", %{
    tmp_dir: tmp_dir
  } do
    Mix.shell(Mix.Shell.Process)
    # No yes? input is queued — the task must not ask.

    File.cd!(tmp_dir, fn ->
      Version.run(["0.1.0"])
    end)

    assert_received {:mix_shell, :info, ["Version is already 0.1.0 — nothing to do."]}
    refute_received {:mix_shell, :yes?, _}

    {out, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: tmp_dir)
    assert out == "baseline\n"
  end

  test "generates and commits a changelog when the changelog prompt is confirmed", %{
    tmp_dir: tmp_dir
  } do
    Mix.shell(Mix.Shell.Process)
    # true: commit the bumped files; true: generate the changelog; true: commit
    # the changelog file.
    send(self(), {:mix_shell_input, :yes?, true})
    send(self(), {:mix_shell_input, :yes?, true})
    send(self(), {:mix_shell_input, :yes?, true})

    previous = Application.get_env(:evo_git, :changelog_summarizer)

    Application.put_env(:evo_git, :changelog_summarizer, fn _model, _version, _commits ->
      {:ok,
       [
         %{category: "Added", text: "A shiny new feature"},
         %{category: "Fixed", text: "A nasty bug"}
       ]}
    end)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:evo_git, :changelog_summarizer)
      else
        Application.put_env(:evo_git, :changelog_summarizer, previous)
      end
    end)

    File.cd!(tmp_dir, fn ->
      Version.run([@new_version])
    end)

    # The changelog was generated with the version section and categorized bullets.
    changelog = Path.join(tmp_dir, "CHANGELOG.md")
    assert File.exists?(changelog)

    content = File.read!(changelog)
    assert content =~ ~r/## \[0\.2\.0\] - \d{4}-\d{2}-\d{2}/
    assert content =~ "### Added"
    assert content =~ "- A shiny new feature"
    assert content =~ "### Fixed"
    assert content =~ "- A nasty bug"

    assert_received {:mix_shell, :yes?, ["Generate changelog for v0.2.0 now? [Yn]"]}
    assert_received {:mix_shell, :yes?, ["Commit the changelog file now? [Yn]"]}

    # The changelog commit is a SECOND commit (after the bump commit), staging
    # exactly CHANGELOG.md and nothing else.
    {out, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: tmp_dir)
    assert out == "Add changelog for v0.2.0\n"

    {out, 0} =
      System.cmd("git", ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"], cd: tmp_dir)

    assert out |> String.split("\n", trim: true) == ["CHANGELOG.md"]
  end

  # Drains all {:mix_shell, :info, [msg]} messages left in the test process mailbox.
  defp collect_infos(acc \\ []) do
    receive do
      {:mix_shell, :info, [msg]} -> collect_infos([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Drains all {:mix_shell, :error, [msg]} messages left in the test process mailbox.
  defp collect_errors(acc \\ []) do
    receive do
      {:mix_shell, :error, [msg]} -> collect_errors([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
