defmodule EvoGit.Adapters.GitHubTest do
  @moduledoc """
  Tests pinning the `EvoGit.Adapters.GitHub` contract (the `gh`-CLI adapter).

  Covers origin-URL parsing (https/ssh, `.git` suffix), `gh` argv forwarding
  (defaults and opts), JSON normalization, error shapes, the exact markdown
  composition, and the `EvoGit.AgentScheduler.RemoteAPI` delegation.

  `async: false` because these tests mutate BEAM-global state visible to all
  processes: `PATH` + `GH_FAKE_MODE`/`GH_FAKE_LOG` (via `EvoGit.FakeGh`, which
  saves and restores them) and a direct `System.put_env("PATH", …)` in the
  gh-missing test.

  The fake `gh` is a POSIX shell script on `PATH` and cannot emulate `gh.exe`
  on Windows, so the gh-dependent tests are wrapped in
  `if not match?({:win32, _}, :os.type())`.

  Fixture repositories are `File.cp_r!` copies of two per-module git TEMPLATES
  built in `setup_all` — one bare `git init` and one that already carries the
  common `origin` remote — instead of a fresh `git init` + `git remote add` per
  test. `EvoGit.GitEnv`'s per-path identity memo is primed for every copy (the
  template config holds exactly that identity), which removes the two
  `git config` subprocesses the first git call in a new directory would spawn.
  No assertion depends on any of it.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.Adapters.GitHub
  alias EvoGit.FakeGh

  @default_origin "https://github.com/octocat/hello-world.git"

  # Identity pinned in the fixture template's repo-local config (also primed
  # into GitEnv's per-path memo — byte-identical to a `git config` read).
  @identity_name "Test User"
  @identity_email "test@example.com"

  # The per-module templates are published here by `setup_all` so the setup
  # block can copy one without re-deriving the paths.
  @templates_key {__MODULE__, :repo_templates}

  setup_all do
    plain =
      git_template!([])

    with_origin =
      git_template!([["remote", "add", "origin", @default_origin]])

    :persistent_term.put(@templates_key, %{plain: plain, with_origin: with_origin})

    on_exit(fn -> :persistent_term.erase(@templates_key) end)

    :ok
  end

  setup context do
    # `@tag :no_origin` selects the template WITHOUT an `origin` remote —
    # `github_upstream/1`'s "no origin" contract.
    template =
      if Map.get(context, :no_origin),
        do: templates!().plain,
        else: templates!().with_origin

    tmp_dir = new_repo!(template)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  # Resets the fixture repo's `origin` URL. The template shipped by `setup`
  # already carries `@default_origin`, so asking for exactly that URL is a
  # no-op (a `git config` write would cost a subprocess for nothing); any other
  # URL overwrites the template's `[remote "origin"]` url key in place.
  defp add_origin(_tmp_dir, @default_origin), do: :ok

  defp add_origin(tmp_dir, url) do
    {:ok, _} = Git.run(["config", "remote.origin.url", url], tmp_dir)
    :ok
  end

  # -------------------------------------------------------------------------
  # Fixtures
  # -------------------------------------------------------------------------

  defp templates! do
    case :persistent_term.get(@templates_key, nil) do
      nil -> raise "#{inspect(__MODULE__)}: fixture templates missing (setup_all has not run)"
      templates -> templates
    end
  end

  # Builds ONE repository template (`setup_all`): a bare `git init` (EMPTY
  # template dir → no hook samples), a repo-local identity, `commit.gpgsign`
  # neutralized and full-length abbreviations, plus any `extra_args` commands
  # (e.g. adding the common `origin` remote).
  defp git_template!(extra_args) do
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit-test-github-tpl-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    empty_template = Path.join(root, "empty_template")
    File.mkdir_p!(empty_template)
    seed = Path.join(root, "seed")

    git!(["init", "-q", "--template=#{empty_template}", "-b", "main", seed], root)

    for {key, value} <- [
          {"user.name", @identity_name},
          {"user.email", @identity_email},
          {"commit.gpgsign", "false"},
          {"core.abbrev", "40"}
        ] do
      git!(["config", key, value], seed)
    end

    Enum.each(extra_args, &git!(&1, seed))

    on_exit(fn -> File.rm_rf!(root) end)
    seed
  end

  defp git!(args, cd) do
    case System.cmd(EvoGit.Executable.resolve("git"), args, cd: cd, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, code} ->
        raise "git #{Enum.join(args, " ")} failed with exit #{code} in #{cd}: #{output}"
    end
  end

  # Copies the template into a fresh, uniquely-named directory — an isolated
  # repository whose remote config and identity are exactly the template's.
  defp new_repo!(template) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "evogit-test-github-" <> to_string(System.unique_integer([:positive]))
      )

    File.cp_r!(template, tmp_dir)
    EvoGit.GitEnv.prime_config_identity_cache(tmp_dir, @identity_name, @identity_email)
    tmp_dir
  end

  # Ungated: upstream parsing needs no `gh` binary and works on all platforms.
  describe "github_upstream/1" do
    test "parses an https origin with a .git suffix", %{tmp_dir: tmp_dir} do
      add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

      assert {:ok, upstream} = GitHub.github_upstream(tmp_dir)
      assert upstream.owner == "octocat"
      assert upstream.repo == "hello-world"

      # Assumed contract: url is the verbatim origin URL.
      assert upstream.url == "https://github.com/octocat/hello-world.git"
      assert is_boolean(upstream.gh_available)
    end

    test "parses an https origin without a .git suffix", %{tmp_dir: tmp_dir} do
      add_origin(tmp_dir, "https://github.com/octocat/hello-world")

      assert {:ok, upstream} = GitHub.github_upstream(tmp_dir)
      assert upstream.owner == "octocat"
      assert upstream.repo == "hello-world"
    end

    test "parses an ssh origin (git@github.com:owner/repo.git)", %{tmp_dir: tmp_dir} do
      add_origin(tmp_dir, "git@github.com:octocat/hello-world.git")

      assert {:ok, upstream} = GitHub.github_upstream(tmp_dir)
      assert upstream.owner == "octocat"
      assert upstream.repo == "hello-world"
    end

    test "parses an ssh origin without a .git suffix", %{tmp_dir: tmp_dir} do
      add_origin(tmp_dir, "git@github.com:octocat/hello-world")

      assert {:ok, upstream} = GitHub.github_upstream(tmp_dir)
      assert upstream.owner == "octocat"
      assert upstream.repo == "hello-world"
    end

    test "rejects a non-GitHub https origin (https://gitlab.com/x/y.git)", %{tmp_dir: tmp_dir} do
      add_origin(tmp_dir, "https://gitlab.com/x/y.git")

      assert GitHub.github_upstream(tmp_dir) == {:error, :no_github_upstream}
    end

    test "rejects a non-GitHub ssh origin (git@gitlab.com:x/y.git)", %{tmp_dir: tmp_dir} do
      add_origin(tmp_dir, "git@gitlab.com:x/y.git")

      assert GitHub.github_upstream(tmp_dir) == {:error, :no_github_upstream}
    end

    # `:no_origin` copies the template WITHOUT the common `origin` remote the
    # other tests rely on.
    @tag :no_origin
    test "rejects a repo with no origin remote", %{tmp_dir: tmp_dir} do
      assert GitHub.github_upstream(tmp_dir) == {:error, :no_github_upstream}
    end

    test "rejects a nonexistent repo path" do
      missing =
        Path.join(
          System.tmp_dir!(),
          "evogit-test-github-missing-" <> to_string(System.unique_integer([:positive]))
        )

      assert {:error, {:enoent, _}} = GitHub.github_upstream(missing)
    end
  end

  # The fake gh is a POSIX shell script on PATH, which cannot emulate gh.exe
  # on Windows — the gh-dependent tests run on POSIX platforms only.
  if not match?({:win32, _}, :os.type()) do
    describe "list_github_issues/2" do
      test "returns {:error, :gh_not_available} when gh is missing (checked before any git call)",
           %{tmp_dir: tmp_dir} do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        empty_dir =
          Path.join(
            System.tmp_dir!(),
            "evogit-test-empty-" <> to_string(System.unique_integer([:positive]))
          )

        File.mkdir_p!(empty_dir)

        original_path = System.get_env("PATH")

        on_exit(fn ->
          if original_path do
            System.put_env("PATH", original_path)
          else
            System.delete_env("PATH")
          end
        end)

        System.put_env("PATH", empty_dir)

        # PATH now contains neither `gh` nor `git`: if the adapter ran git
        # before the gh-availability check, the return value would differ (or
        # the call would crash on a missing git binary), so the exact
        # assertion proves the check order (repo dir → gh_available →
        # upstream → gh run).
        assert GitHub.list_github_issues(tmp_dir) == {:error, :gh_not_available}
      end

      test "parses gh issue list JSON into normalized maps", %{tmp_dir: tmp_dir} do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        FakeGh.with_fake_gh(fn _ctx ->
          assert {:ok, issues} = GitHub.list_github_issues(tmp_dir)

          assert issues == [
                   %{
                     number: 1,
                     title: "Fix login bug",
                     state: "open",
                     labels: ["bug", "frontend"],
                     url: "https://github.com/octocat/hello-world/issues/1",
                     author: "alice",
                     created_at: "2024-01-15T10:00:00Z"
                   },
                   # Entry 2 pins the missing-author → "" normalization.
                   %{
                     number: 2,
                     title: "Add dark mode",
                     state: "closed",
                     labels: [],
                     url: "https://github.com/octocat/hello-world/issues/2",
                     author: "",
                     created_at: "2024-02-20T12:30:00Z"
                   },
                   %{
                     number: 3,
                     title: "Fix docs typo",
                     state: "open",
                     labels: ["docs"],
                     url: "https://github.com/octocat/hello-world/issues/3",
                     author: "bob",
                     created_at: "2024-03-01T08:00:00Z"
                   }
                 ]
        end)
      end

      test "passes default --state open and --limit 100", %{tmp_dir: tmp_dir} do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        FakeGh.with_fake_gh(fn %{log_path: log_path} ->
          assert {:ok, _issues} = GitHub.list_github_issues(tmp_dir)

          # The fake gh logs its argv one element per line; the --json value
          # is a single argv element.
          argv = FakeGh.read_argv_log(log_path)
          assert "--repo" in argv
          assert "octocat/hello-world" in argv
          assert "--state" in argv
          assert "open" in argv
          assert "--limit" in argv
          assert "100" in argv
          assert "--json" in argv
          assert "number,title,state,labels,url,author,createdAt" in argv
        end)
      end

      test "reflects opts state: \"closed\", limit: 5 in the gh argv", %{tmp_dir: tmp_dir} do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        FakeGh.with_fake_gh(fn %{log_path: log_path} ->
          assert {:ok, _issues} = GitHub.list_github_issues(tmp_dir, state: "closed", limit: 5)

          argv = FakeGh.read_argv_log(log_path)
          assert "closed" in argv
          assert "5" in argv
        end)
      end

      test "maps a non-zero gh exit to {:error, {:gh, 7, output}} with trimmed stderr", %{
        tmp_dir: tmp_dir
      } do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        FakeGh.with_fake_gh(fn _ctx ->
          # FakeGh restores GH_FAKE_MODE on exit.
          System.put_env("GH_FAKE_MODE", "fail")

          assert {:error, {:gh, 7, "gh: simulated failure (stderr)"}} =
                   GitHub.list_github_issues(tmp_dir)
        end)
      end

      test "maps invalid JSON to {:error, {:invalid_json, _}}", %{tmp_dir: tmp_dir} do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        FakeGh.with_fake_gh(fn _ctx ->
          System.put_env("GH_FAKE_MODE", "badjson")

          assert {:error, {:invalid_json, _}} = GitHub.list_github_issues(tmp_dir)
        end)
      end
    end

    describe "github_issue_markdown/2" do
      test "composes the exact markdown for an issue with labels", %{tmp_dir: tmp_dir} do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        FakeGh.with_fake_gh(fn _ctx ->
          assert {:ok, markdown} = GitHub.github_issue_markdown(tmp_dir, 42)

          # The contract says the markdown has no trailing newline, so the
          # heredoc's own trailing newline is trimmed.
          expected =
            """
            # GitHub Issue #42: Refactor scheduler core
            URL: https://github.com/octocat/hello-world/issues/42 | State: open | Labels: core, refactor

            First line.

            Second paragraph.
            """
            |> String.trim_trailing("\n")

          assert markdown == expected
        end)
      end

      test "omits the labels segment when the issue has no labels", %{tmp_dir: tmp_dir} do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        FakeGh.with_fake_gh(fn _ctx ->
          assert {:ok, markdown} = GitHub.github_issue_markdown(tmp_dir, 43)

          expected =
            """
            # GitHub Issue #43: Nothing to see here
            URL: https://github.com/octocat/hello-world/issues/43 | State: closed

            No labels on this one.
            """
            |> String.trim_trailing("\n")

          assert markdown == expected
        end)
      end

      test "maps a non-zero gh exit to {:error, {:gh, 7, _}}", %{tmp_dir: tmp_dir} do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        FakeGh.with_fake_gh(fn _ctx ->
          assert {:error, {:gh, 7, output}} = GitHub.github_issue_markdown(tmp_dir, 999)
          assert output == "gh: issue not found (stderr)"
        end)
      end
    end

    describe "RemoteAPI delegates (gh-dependent)" do
      test "list_github_issues/2 delegates to the adapter", %{tmp_dir: tmp_dir} do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        FakeGh.with_fake_gh(fn _ctx ->
          assert {:ok, issues} = EvoGit.AgentScheduler.RemoteAPI.list_github_issues(tmp_dir)
          assert length(issues) == 3
        end)
      end

      test "github_issue_markdown/2 delegates to the adapter", %{tmp_dir: tmp_dir} do
        add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

        FakeGh.with_fake_gh(fn _ctx ->
          assert {:ok, markdown} =
                   EvoGit.AgentScheduler.RemoteAPI.github_issue_markdown(tmp_dir, 42)

          assert markdown =~ "# GitHub Issue #42: Refactor scheduler core"
        end)
      end
    end
  end

  describe "RemoteAPI delegates" do
    test "github_upstream/1 on a repo with an origin", %{tmp_dir: tmp_dir} do
      # RemoteAPI is a plain function module; the app auto-starts in tests.
      add_origin(tmp_dir, "https://github.com/octocat/hello-world.git")

      assert {:ok, upstream} = EvoGit.AgentScheduler.RemoteAPI.github_upstream(tmp_dir)
      assert upstream.owner == "octocat"
      assert upstream.repo == "hello-world"
      assert upstream.url == "https://github.com/octocat/hello-world.git"
    end
  end
end
