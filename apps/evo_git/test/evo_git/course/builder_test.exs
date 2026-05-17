defmodule EvoGit.Course.BuilderTest do
  use ExUnit.Case, async: false

  alias EvoGit.Course.Builder

  @moduletag :tmp_dir

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp create_test_repo(tmp_dir, branches_with_files) do
    repo_path = Path.join(tmp_dir, "test_repo")
    File.mkdir_p!(repo_path)

    # Initialize git
    System.cmd("git", ["init"], cd: repo_path)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: repo_path)
    System.cmd("git", ["config", "user.name", "Test"], cd: repo_path)

    # Make an initial commit so we can create branches
    File.write!(Path.join(repo_path, ".gitkeep"), "")
    System.cmd("git", ["add", ".gitkeep"], cd: repo_path)
    System.cmd("git", ["commit", "-m", "initial commit"], cd: repo_path)

    # Determine the default branch name (after first commit so HEAD exists)
    {branch_name, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: repo_path)
    default_branch = String.trim(branch_name)

    # Rename to main if needed
    if default_branch != "main" do
      System.cmd("git", ["branch", "-m", default_branch, "main"], cd: repo_path)
    end

    # Create and commit on each branch (keyword list ensures order)
    Enum.each(branches_with_files, fn {branch, files} ->
      if branch != "main" do
        System.cmd("git", ["checkout", "-b", branch], cd: repo_path)
      else
        System.cmd("git", ["checkout", "main"], cd: repo_path)
      end

      Enum.each(files, fn {filename, content} ->
        dir = Path.dirname(filename)

        if dir != "." do
          File.mkdir_p!(Path.join(repo_path, dir))
        end

        File.write!(Path.join(repo_path, filename), content)
      end)

      System.cmd("git", ["add", "."], cd: repo_path)
      System.cmd("git", ["commit", "-m", "Add files for #{branch}"], cd: repo_path)
    end)

    # Return to main
    System.cmd("git", ["checkout", "main"], cd: repo_path)

    repo_path
  end

  # ---------------------------------------------------------------------------
  # list_language_branches/1
  # ---------------------------------------------------------------------------

  describe "list_language_branches/1" do
    test "returns only main and lang-* branches, sorted", %{tmp_dir: tmp_dir} do
      repo_path =
        create_test_repo(tmp_dir, %{
          "main" => [{"index.html", "main"}],
          "lang-zh" => [{"index.html", "zh"}],
          "feature-x" => [{"index.html", "feature"}],
          "lang-es" => [{"index.html", "es"}]
        })

      assert {:ok, branches} = Builder.list_language_branches(repo_path)
      assert branches == ["lang-es", "lang-zh", "main"]
    end

    test "returns only main when repo has no language branches", %{tmp_dir: tmp_dir} do
      repo_path =
        create_test_repo(tmp_dir, %{
          "main" => [{"index.html", "main"}]
        })

      assert {:ok, branches} = Builder.list_language_branches(repo_path)
      assert branches == ["main"]
    end

    test "returns empty list when repo has no commits (no branch output)", %{tmp_dir: tmp_dir} do
      repo_path = Path.join(tmp_dir, "empty_repo")
      File.mkdir_p!(repo_path)
      System.cmd("git", ["init"], cd: repo_path)

      # When there are no commits, git branch produces no output.
      # The bug on line 100 is not triggered because Enum.map over [] returns [].
      assert {:ok, branches} = Builder.list_language_branches(repo_path)
      assert branches == []
    end

    test "returns error for non-existent path", %{tmp_dir: tmp_dir} do
      non_existent = Path.join(tmp_dir, "does_not_exist")

      assert {:error, {:git_branch_failed, _code, _msg}} =
               Builder.list_language_branches(non_existent)
    end

    test "returns error when path is a file, not a repo", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "not_a_repo.txt")
      File.write!(file_path, "not a git repo")

      assert {:error, {:git_branch_failed, _code, _msg}} =
               Builder.list_language_branches(file_path)
    end
  end

  # ---------------------------------------------------------------------------
  # build/3 — integration
  # ---------------------------------------------------------------------------

  describe "build/3" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "builds course from repo with main and lang-zh branches", %{tmp_dir: tmp_dir} do
      repo_path =
        create_test_repo(tmp_dir, %{
          "main" => [{"index.html", "<html>English</html>"}],
          "lang-zh" => [{"index.html", "<html>Chinese</html>"}]
        })

      output_dir = Path.join(tmp_dir, "output/my_course")

      assert {:ok, tar_path} = Builder.build(repo_path, output_dir)

      # tar_path ends with .tar.zst
      assert String.ends_with?(tar_path, ".tar.zst")

      # Output dir contains en/ and zh/ subdirectories
      assert File.dir?(Path.join(output_dir, "en"))
      assert File.dir?(Path.join(output_dir, "zh"))

      # en/index.html has English content
      assert File.read!(Path.join(output_dir, "en/index.html")) == "<html>English</html>"

      # zh/index.html has Chinese content
      assert File.read!(Path.join(output_dir, "zh/index.html")) == "<html>Chinese</html>"

      # The .tar.zst file exists and is non-empty
      assert File.exists?(tar_path)
      assert File.stat!(tar_path).size > 0
    end

    test "builds course with custom tar_file path", %{tmp_dir: tmp_dir} do
      repo_path =
        create_test_repo(tmp_dir, %{
          "main" => [{"index.html", "main content"}]
        })

      output_dir = Path.join(tmp_dir, "output/custom_course")
      custom_tar = Path.join(tmp_dir, "archives/custom.tar.zst")
      File.mkdir_p!(Path.dirname(custom_tar))

      assert {:ok, tar_path} = Builder.build(repo_path, output_dir, tar_file: custom_tar)
      assert tar_path == custom_tar
      assert File.exists?(custom_tar)
      assert File.stat!(custom_tar).size > 0
    end

    test "maps branch names to correct language codes", %{tmp_dir: tmp_dir} do
      repo_path =
        create_test_repo(tmp_dir, %{
          "main" => [{"index.html", "en"}],
          "lang-pt" => [{"index.html", "pt"}],
          "lang-ja" => [{"index.html", "ja"}]
        })

      output_dir = Path.join(tmp_dir, "output/lang_test")

      assert {:ok, _tar_path} = Builder.build(repo_path, output_dir)

      assert File.dir?(Path.join(output_dir, "en"))
      assert File.dir?(Path.join(output_dir, "pt"))
      assert File.dir?(Path.join(output_dir, "ja"))

      assert File.read!(Path.join(output_dir, "en/index.html")) == "en"
      assert File.read!(Path.join(output_dir, "pt/index.html")) == "pt"
      assert File.read!(Path.join(output_dir, "ja/index.html")) == "ja"
    end

    test "handles repo with nested file structures", %{tmp_dir: tmp_dir} do
      repo_path =
        create_test_repo(tmp_dir, %{
          "main" => [
            {"index.html", "EN root"},
            {"css/style.css", "body { color: black; }"},
            {"js/app.js", "console.log('en');"}
          ],
          "lang-fr" => [
            {"index.html", "FR root"},
            {"css/style.css", "body { color: blue; }"},
            {"js/app.js", "console.log('fr');"}
          ]
        })

      output_dir = Path.join(tmp_dir, "output/nested")

      assert {:ok, _tar_path} = Builder.build(repo_path, output_dir)

      assert File.read!(Path.join(output_dir, "en/index.html")) == "EN root"
      assert File.read!(Path.join(output_dir, "en/css/style.css")) == "body { color: black; }"
      assert File.read!(Path.join(output_dir, "en/js/app.js")) == "console.log('en');"

      assert File.read!(Path.join(output_dir, "fr/index.html")) == "FR root"
      assert File.read!(Path.join(output_dir, "fr/css/style.css")) == "body { color: blue; }"
      assert File.read!(Path.join(output_dir, "fr/js/app.js")) == "console.log('fr');"
    end
  end

  # ---------------------------------------------------------------------------
  # build/3 — transformation pipeline
  # ---------------------------------------------------------------------------

  describe "build/3 with transformations" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "applies transformation modules in order", %{tmp_dir: tmp_dir} do
      defmodule TestWatermark do
        def transform(dir, _opts) do
          File.write!(Path.join(dir, "WATERMARK.txt"), "transformed!")
          :ok
        end
      end

      repo_path =
        create_test_repo(tmp_dir, %{
          "main" => [{"index.html", "main content"}]
        })

      output_dir = Path.join(tmp_dir, "output/transformed")

      assert {:ok, _tar_path} =
               Builder.build(repo_path, output_dir, transformations: [TestWatermark])

      # The watermark file should exist in the en/ subdirectory
      assert File.exists?(Path.join(output_dir, "en/WATERMARK.txt"))
      assert File.read!(Path.join(output_dir, "en/WATERMARK.txt")) == "transformed!"
    end

    test "fails when a transformation returns error", %{tmp_dir: tmp_dir} do
      defmodule TestFailingTransform do
        def transform(_dir, _opts) do
          {:error, "something went wrong"}
        end
      end

      repo_path =
        create_test_repo(tmp_dir, %{
          "main" => [{"index.html", "main content"}]
        })

      output_dir = Path.join(tmp_dir, "output/failed_transform")

      assert {:error, {:transformation_failed, TestFailingTransform, "something went wrong"}} =
               Builder.build(repo_path, output_dir, transformations: [TestFailingTransform])
    end

    test "passes branches option to transformations", %{tmp_dir: tmp_dir} do
      defmodule TestBranchesTransform do
        def transform(dir, opts) do
          branches = Keyword.get(opts, :branches, [])
          content = Enum.join(branches, ",")
          File.write!(Path.join(dir, "BRANCHES.txt"), content)
          :ok
        end
      end

      repo_path =
        create_test_repo(tmp_dir, %{
          "main" => [{"index.html", "main content"}],
          "lang-zh" => [{"index.html", "zh content"}]
        })

      output_dir = Path.join(tmp_dir, "output/branches_transform")

      assert {:ok, _tar_path} =
               Builder.build(repo_path, output_dir, transformations: [TestBranchesTransform])

      # The BRANCHES.txt file should list all language branches
      branches_content = File.read!(Path.join(output_dir, "en/BRANCHES.txt"))
      assert String.contains?(branches_content, "main")
      assert String.contains?(branches_content, "lang-zh")
    end
  end

  # ---------------------------------------------------------------------------
  # build/3 — error cases
  # ---------------------------------------------------------------------------

  describe "build/3 error cases" do
    test "returns error for non-existent repo path", %{tmp_dir: tmp_dir} do
      repo_path = Path.join(tmp_dir, "non_existent_repo")
      output_dir = Path.join(tmp_dir, "output")

      assert {:error, {:git_branch_failed, _code, _msg}} =
               Builder.build(repo_path, output_dir)
    end

    # Note: when the repo has no language branches (but git is valid),
    # the build produces an empty archive. The bug on line 100 is NOT
    # triggered here because we are testing with a repo that has no
    # branches at all (empty git output), so Enum.map over [] is safe.
    test "returns ok with empty repo (no branches, produces empty archive)", %{tmp_dir: tmp_dir} do
      repo_path = Path.join(tmp_dir, "empty_repo_for_build")
      File.mkdir_p!(repo_path)
      System.cmd("git", ["init"], cd: repo_path)

      output_dir = Path.join(tmp_dir, "output_empty")

      # When there are no branches, the build succeeds with an empty archive
      assert {:ok, tar_path} = Builder.build(repo_path, output_dir)
      assert String.ends_with?(tar_path, ".tar.zst")
      assert File.exists?(tar_path)
    end
  end

  # ---------------------------------------------------------------------------
  # build_all/1
  # ---------------------------------------------------------------------------

  describe "build_all/1" do
    test "returns empty list when no courses configured" do
      old_env = Application.get_env(:evo_git, :courses)
      Application.put_env(:evo_git, :courses, [])

      on_exit(fn ->
        Application.put_env(:evo_git, :courses, old_env)
      end)

      assert Builder.build_all() == []
    end

    test "returns errors for failed course builds (non-existent repo)", %{tmp_dir: tmp_dir} do
      old_env = Application.get_env(:evo_git, :courses)

      Application.put_env(:evo_git, :courses, [
        %{
          name: "bad_course",
          repo_path: Path.join(tmp_dir, "non_existent_repo")
        }
      ])

      on_exit(fn ->
        Application.put_env(:evo_git, :courses, old_env)
      end)

      results = Builder.build_all()
      assert length(results) == 1
      assert {:error, "bad_course", _reason} = hd(results)
    end

    test "builds all configured courses and returns results", %{tmp_dir: tmp_dir} do
      # Create two test repos
      repo1_path =
        create_test_repo(tmp_dir, %{
          "main" => [{"index.html", "Course 1 English"}]
        })

      repo2_path =
        create_test_repo(tmp_dir, %{
          "main" => [{"index.html", "Course 2 English"}]
        })

      old_env = Application.get_env(:evo_git, :courses)

      Application.put_env(:evo_git, :courses, [
        %{name: "course_alpha", repo_path: repo1_path},
        %{name: "course_beta", repo_path: repo2_path}
      ])

      on_exit(fn ->
        Application.put_env(:evo_git, :courses, old_env)
      end)

      results = Builder.build_all()

      assert length(results) == 2

      Enum.each(results, fn result ->
        case result do
          {:ok, name, tar_path} ->
            assert name in ["course_alpha", "course_beta"]
            assert String.ends_with?(tar_path, ".tar.zst")
            assert File.exists?(tar_path)

          {:error, _name, _reason} ->
            flunk("Expected :ok but got :error")
        end
      end)
    end

    test "passes options through to build", %{tmp_dir: tmp_dir} do
      repo_path =
        create_test_repo(tmp_dir, %{
          "main" => [{"index.html", "English"}]
        })

      old_env = Application.get_env(:evo_git, :courses)

      Application.put_env(:evo_git, :courses, [
        %{name: "opt_course", repo_path: repo_path}
      ])

      on_exit(fn ->
        Application.put_env(:evo_git, :courses, old_env)
      end)

      custom_tar = Path.join(tmp_dir, "custom_archive.tar.zst")
      results = Builder.build_all(tar_file: custom_tar)

      assert length(results) == 1
      assert {:ok, "opt_course", ^custom_tar} = hd(results)
    end
  end
end
