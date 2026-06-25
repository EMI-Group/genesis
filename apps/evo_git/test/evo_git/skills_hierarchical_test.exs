defmodule EvoGit.SkillsHierarchicalTest do
  use ExUnit.Case, async: true

  alias EvoGit.Skills
  alias EvoGit.Skills.Skill

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_skill(name) do
    %Skill{
      name: name,
      description: "desc for #{name}",
      parameters: [],
      body: "b",
      file_path: "/tmp/#{name}.md"
    }
  end

  defp context_with_skills(skills) when is_list(skills) do
    skill_block = Enum.map_join(skills, "\n", fn s -> "  - #{s}" end)
    "---\nskill:\n#{skill_block}\n---\n\n# Body\n"
  end

  defp write_context(dir, content) do
    File.write!(Path.join(dir, "CONTEXT.md"), content)
  end

  defp new_tmp_repo do
    Path.join(System.tmp_dir!(), "evogit_skills_hier_" <> to_string(System.unique_integer()))
  end

  # ---------------------------------------------------------------------------
  # extract_context_skill_names/1
  # ---------------------------------------------------------------------------

  describe "extract_context_skill_names/1" do
    test "extracts a single skill from frontmatter" do
      content = "---\nskill:\n  - my-skill\n---\n\n# Body\n"

      assert Skills.extract_context_skill_names(content) == ["my-skill"]
    end

    test "extracts multiple skills from frontmatter" do
      content = """
      ---
      skill:
        - my-skill
        - other-skill
      ---

      # Body
      """

      assert Skills.extract_context_skill_names(content) == ["my-skill", "other-skill"]
    end

    test "returns empty list when there is no skill field" do
      content = """
      ---
      name: something
      description: no skills here
      ---

      # Body
      """

      assert Skills.extract_context_skill_names(content) == []
    end

    test "returns empty list when there is no frontmatter at all" do
      content = "# Just a heading\n\nNo frontmatter here."

      assert Skills.extract_context_skill_names(content) == []
    end
  end

  # ---------------------------------------------------------------------------
  # strip_front_matter/1
  # ---------------------------------------------------------------------------

  describe "strip_front_matter/1" do
    test "removes frontmatter and returns only the body" do
      content = """
      ---
      skill:
        - my-skill
      ---

      # Title

      Some body text.
      """

      body = Skills.strip_front_matter(content)

      assert body =~ "# Title"
      assert body =~ "Some body text."
      refute body =~ "skill:"
      refute body =~ "---"
    end

    test "returns content unchanged when there is no frontmatter" do
      content = "# Just a heading\n\nNo frontmatter here."

      assert Skills.strip_front_matter(content) == String.trim(content)
    end
  end

  # ---------------------------------------------------------------------------
  # filter_skills/2
  # ---------------------------------------------------------------------------

  describe "filter_skills/2" do
    test "returns empty list when names is empty" do
      skills = [make_skill("a"), make_skill("b")]

      assert Skills.filter_skills(skills, []) == []
    end

    test "returns only skills matching the given names" do
      a = make_skill("a")
      b = make_skill("b")
      c = make_skill("c")
      skills = [a, b, c]

      assert Skills.filter_skills(skills, ["a", "c"]) == [a, c]
    end

    test "returns empty list when no names match" do
      skills = [make_skill("a"), make_skill("b")]

      assert Skills.filter_skills(skills, ["x", "y"]) == []
    end
  end

  # ---------------------------------------------------------------------------
  # skill_names_at_dir/1
  # ---------------------------------------------------------------------------

  describe "skill_names_at_dir/1" do
    setup do
      tmp_dir = new_tmp_repo()
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "returns skill names from CONTEXT.md in the directory", %{tmp_dir: dir} do
      write_context(dir, context_with_skills(["alpha", "beta"]))

      assert Skills.skill_names_at_dir(dir) == ["alpha", "beta"]
    end

    test "returns empty list when directory has no CONTEXT.md", %{tmp_dir: dir} do
      assert Skills.skill_names_at_dir(dir) == []
    end
  end

  # ---------------------------------------------------------------------------
  # where_enabled/2
  # ---------------------------------------------------------------------------

  describe "where_enabled/2" do
    setup do
      tmp_dir = new_tmp_repo()
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, %{repo: tmp_dir}}
    end

    test "returns relative paths of nodes that have the skill enabled", %{repo: repo} do
      write_context(repo, context_with_skills(["deploy"]))

      # For root-level CONTEXT.md, Path.relative_to(repo, repo) returns "."
      # which the source formats as "./."
      assert Skills.where_enabled("deploy", repo) == ["./."]
    end

    test "returns empty list when no node has the skill enabled", %{repo: repo} do
      write_context(repo, context_with_skills(["other"]))

      assert Skills.where_enabled("deploy", repo) == []
    end

    test "finds skill enabled in nested directories", %{repo: repo} do
      write_context(repo, context_with_skills(["root-skill"]))

      lib_dir = Path.join(repo, "lib")
      File.mkdir_p!(lib_dir)
      write_context(lib_dir, context_with_skills(["nested-skill"]))

      assert Skills.where_enabled("nested-skill", repo) == ["./lib"]
    end
  end

  # ---------------------------------------------------------------------------
  # enable_skill/3
  # ---------------------------------------------------------------------------

  describe "enable_skill/3" do
    setup do
      tmp_dir = new_tmp_repo()
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, %{repo: tmp_dir}}
    end

    test "returns error for non-existent directory", %{repo: repo} do
      assert {:error, reason} = Skills.enable_skill("my-skill", "./nonexistent", repo)
      assert reason =~ "does not exist"
    end

    test "enables a skill at root when CONTEXT.md exists", %{repo: repo} do
      write_context(repo, "# Existing root\n\nSome content.\n")

      assert {:ok, :enabled, "./"} = Skills.enable_skill("my-skill", "./", repo)
      assert "my-skill" in Skills.skill_names_at_dir(repo)
    end

    test "returns already_enabled_here when skill is already at this node", %{repo: repo} do
      write_context(repo, context_with_skills(["my-skill"]))

      assert {:ok, :already_enabled_here} = Skills.enable_skill("my-skill", "./", repo)
    end

    test "creates CONTEXT.md when none exists", %{repo: repo} do
      assert {:ok, :enabled, "./"} = Skills.enable_skill("brand-new", "./", repo)

      assert File.exists?(Path.join(repo, "CONTEXT.md"))
      assert "brand-new" in Skills.skill_names_at_dir(repo)
    end

    test "returns already_enabled_above when skill is enabled at a higher node", %{repo: repo} do
      write_context(repo, context_with_skills(["shared"]))

      lib_dir = Path.join(repo, "lib")
      File.mkdir_p!(lib_dir)

      assert {:ok, :already_enabled_above, "./"} =
               Skills.enable_skill("shared", "./lib", repo)
    end
  end

  # ---------------------------------------------------------------------------
  # disable_skill/3
  # ---------------------------------------------------------------------------

  describe "disable_skill/3" do
    setup do
      tmp_dir = new_tmp_repo()
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, %{repo: tmp_dir}}
    end

    test "returns error for non-existent directory", %{repo: repo} do
      assert {:error, reason} = Skills.disable_skill("my-skill", "./nonexistent", repo)
      assert reason =~ "does not exist"
    end

    test "returns not_enabled when skill is not enabled at this node", %{repo: repo} do
      write_context(repo, context_with_skills(["other"]))

      assert {:ok, :not_enabled} = Skills.disable_skill("my-skill", "./", repo)
    end

    test "disables skill and removes it from CONTEXT.md", %{repo: repo} do
      write_context(repo, context_with_skills(["my-skill", "keep-me"]))

      assert {:ok, :disabled, "./"} = Skills.disable_skill("my-skill", "./", repo)

      names = Skills.skill_names_at_dir(repo)
      refute "my-skill" in names
      assert "keep-me" in names
    end
  end

  # ---------------------------------------------------------------------------
  # remove_skill_from_all_contexts/2
  # ---------------------------------------------------------------------------

  describe "remove_skill_from_all_contexts/2" do
    setup do
      tmp_dir = new_tmp_repo()
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, %{repo: tmp_dir}}
    end

    test "removes skill from all CONTEXT.md files and returns count", %{repo: repo} do
      write_context(repo, context_with_skills(["target", "other"]))

      lib_dir = Path.join(repo, "lib")
      File.mkdir_p!(lib_dir)
      write_context(lib_dir, context_with_skills(["target"]))

      assert {:ok, 2} = Skills.remove_skill_from_all_contexts("target", repo)

      refute "target" in Skills.skill_names_at_dir(repo)
      refute "target" in Skills.skill_names_at_dir(lib_dir)
    end

    test "returns zero when skill is not in any CONTEXT.md", %{repo: repo} do
      write_context(repo, context_with_skills(["unrelated"]))

      assert {:ok, 0} = Skills.remove_skill_from_all_contexts("target", repo)
    end
  end

  # ---------------------------------------------------------------------------
  # hierarchical_skill_names/2
  # ---------------------------------------------------------------------------

  describe "hierarchical_skill_names/2" do
    setup do
      tmp_dir = new_tmp_repo()
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, %{repo: tmp_dir}}
    end

    test "collects skills from root to a nested node", %{repo: repo} do
      write_context(repo, context_with_skills(["root-skill"]))

      lib_dir = Path.join(repo, "lib")
      File.mkdir_p!(lib_dir)
      write_context(lib_dir, context_with_skills(["lib-skill"]))

      names = Skills.hierarchical_skill_names("./lib", repo)

      assert "root-skill" in names
      assert "lib-skill" in names
    end

    test "returns root skills when node is root", %{repo: repo} do
      write_context(repo, context_with_skills(["root-skill"]))

      assert Skills.hierarchical_skill_names("./", repo) == ["root-skill"]
    end

    test "returns empty list when no skills are enabled", %{repo: repo} do
      write_context(repo, "# No skills\n\nBody.\n")

      assert Skills.hierarchical_skill_names("./", repo) == []
    end
  end
end
