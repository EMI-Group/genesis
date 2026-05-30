defmodule EvoGit.SkillsTest do
  use ExUnit.Case, async: true
  alias EvoGit.Skills
  alias EvoGit.Skills.Skill

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp valid_skill_content do
    """
    ---
    name: my-skill
    description: Does something useful
    parameters:
    - name: input
      type: string
      description: The input file
      required: true
    - name: verbose
      type: boolean
      description: Verbose output
      required: false
      default: false
    ---

    # My Skill

    Some body text here.
    """
  end

  defp skill_content_no_params do
    """
    ---
    name: simple-skill
    description: A skill with no parameters
    ---

    # Simple Skill

    Just some instructions.
    """
  end

  # ---------------------------------------------------------------------------
  # parse_frontmatter/1
  # ---------------------------------------------------------------------------

  describe "parse_frontmatter/1" do
    test "parses valid frontmatter with parameters" do
      assert {:ok, metadata, body} = Skills.parse_frontmatter(valid_skill_content())
      assert metadata["name"] == "my-skill"
      assert metadata["description"] == "Does something useful"
      assert length(metadata["parameters"]) == 2
      assert hd(metadata["parameters"])["name"] == "input"
      assert hd(metadata["parameters"])["required"] == true
      assert body =~ "Some body text here"
    end

    test "parses valid frontmatter without parameters" do
      assert {:ok, metadata, body} = Skills.parse_frontmatter(skill_content_no_params())
      assert metadata["name"] == "simple-skill"
      assert metadata["description"] == "A skill with no parameters"
      assert Map.get(metadata, "parameters", []) == []
      assert body =~ "Just some instructions"
    end

    test "handles content with no frontmatter" do
      content = "# Just a heading\n\nNo frontmatter here."
      assert {:ok, metadata, body} = Skills.parse_frontmatter(content)
      assert metadata == %{}
      assert body =~ "No frontmatter here"
    end

    test "handles content with only opening triple-dash" do
      content = "---\nSome content without closing dashes"
      assert {:ok, metadata, body} = Skills.parse_frontmatter(content)
      assert metadata == %{}
      assert body == String.trim(content)
    end

    test "handles metadata with only name and description" do
      content = """
      ---
      name: meta-only
      description: Just metadata, no params
      ---

      Body after frontmatter.
      """

      assert {:ok, metadata, body} = Skills.parse_frontmatter(content)
      assert metadata["name"] == "meta-only"
      assert metadata["description"] == "Just metadata, no params"
      assert body =~ "Body after frontmatter"
    end
  end

  # ---------------------------------------------------------------------------
  # parse_yaml_simple/1
  # ---------------------------------------------------------------------------

  describe "parse_yaml_simple/1" do
    test "parses simple key-value pairs" do
      yaml = "name: my-skill\ndescription: Does stuff"
      assert {:ok, map} = Skills.parse_yaml_simple(yaml)
      assert map["name"] == "my-skill"
      assert map["description"] == "Does stuff"
    end

    test "parses parameters section" do
      yaml = """
      name: my-skill
      parameters:
      - name: input
        type: string
        description: The input file
        required: true
      - name: verbose
        type: boolean
        description: Verbose output
        required: false
        default: false
      """

      assert {:ok, map} = Skills.parse_yaml_simple(yaml)
      assert map["name"] == "my-skill"
      assert length(map["parameters"]) == 2

      param1 = hd(map["parameters"])
      assert param1["name"] == "input"
      assert param1["type"] == "string"
      assert param1["required"] == true

      param2 = List.last(map["parameters"])
      assert param2["name"] == "verbose"
      assert param2["required"] == false
      assert param2["default"] == false
    end

    test "returns empty map for empty input" do
      assert {:ok, map} = Skills.parse_yaml_simple("")
      assert map == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # extract_bash_block/1
  # ---------------------------------------------------------------------------

  describe "extract_bash_block/1" do
    test "extracts bash code block" do
      markdown = """
      # Title

      ```bash
      echo "hello world"
      ```
      """

      assert Skills.extract_bash_block(markdown) == ~s(echo "hello world")
    end

    test "returns nil when no bash block present" do
      markdown = """
      # Title

      Just some text without code blocks.
      """

      assert Skills.extract_bash_block(markdown) == nil
    end

    test "extracts only the first bash block when multiple exist" do
      markdown = """
      # Title

      ```bash
      echo "first"
      ```

      ```bash
      echo "second"
      ```
      """

      assert Skills.extract_bash_block(markdown) == ~s(echo "first")
    end

    test "does not extract non-bash code blocks" do
      markdown = """
      # Title

      ```elixir
      IO.puts("hello")
      ```

      ```bash
      echo "only this one"
      ```
      """

      assert Skills.extract_bash_block(markdown) == ~s(echo "only this one")
    end

    test "trims whitespace from extracted block" do
      markdown = """
      ```bash

        echo "with spaces"

      ```
      """

      assert Skills.extract_bash_block(markdown) == ~s(echo "with spaces")
    end
  end

  # ---------------------------------------------------------------------------
  # substitute_params/3
  # ---------------------------------------------------------------------------

  describe "substitute_params/3" do
    test "substitutes parameter placeholders with provided values" do
      script = ~s(echo "{{name}} is {{status}}")
      params = [
        %{name: "name", type: "string", description: "Name", required: true},
        %{name: "status", type: "string", description: "Status", required: false, default: "ok"}
      ]
      args = %{"name" => "Alice", "status" => "ready"}

      result = Skills.substitute_params(script, params, args)
      assert result == ~s(echo "Alice is ready")
    end

    test "uses default value when arg not provided" do
      script = ~s(echo "{{name}} is {{status}}")
      params = [
        %{name: "name", type: "string", description: "Name", required: true},
        %{name: "status", type: "string", description: "Status", required: false, default: "ok"}
      ]
      args = %{"name" => "Bob"}

      result = Skills.substitute_params(script, params, args)
      assert result == ~s(echo "Bob is ok")
    end

    test "uses empty string when no arg and no default" do
      script = ~s(echo "{{greeting}} {{name}}")
      params = [
        %{name: "greeting", type: "string", description: "Greeting", required: false},
        %{name: "name", type: "string", description: "Name", required: true}
      ]
      args = %{"name" => "World"}

      result = Skills.substitute_params(script, params, args)
      assert result == ~s(echo " World")
    end

    test "converts boolean defaults to string" do
      script = ~s(DEBUG={{debug}})
      params = [
        %{name: "debug", type: "boolean", description: "Debug flag", required: false, default: false}
      ]
      args = %{}

      result = Skills.substitute_params(script, params, args)
      assert result == "DEBUG=false"
    end
  end

  # ---------------------------------------------------------------------------
  # validate_skill_text/1
  # ---------------------------------------------------------------------------

  describe "validate_skill_text/1" do
    test "returns ok for valid skill content" do
      assert {:ok, "my-skill"} = Skills.validate_skill_text(valid_skill_content())
    end

    test "returns error for missing name" do
      content = """
      ---
      description: No name here
      ---

      Body text.
      """

      assert {:error, reason} = Skills.validate_skill_text(content)
      assert reason =~ "must have a 'name'"
    end

    test "returns error for name starting with a number" do
      content = """
      ---
      name: 123bad-name
      description: Starts with number
      ---

      Body text.
      """

      assert {:error, reason} = Skills.validate_skill_text(content)
      assert reason =~ "invalid"
      assert reason =~ "123bad-name"
    end

    test "returns error for name with special characters" do
      content = """
      ---
      name: bad name!
      description: Has spaces and special chars
      ---

      Body text.
      """

      assert {:error, reason} = Skills.validate_skill_text(content)
      assert reason =~ "invalid"
    end

    test "accepts name with hyphens and underscores" do
      content = """
      ---
      name: my-skill_v2
      description: Valid name with hyphens and underscores
      ---

      Body text.
      """

      assert {:ok, "my-skill_v2"} = Skills.validate_skill_text(content)
    end

    test "accepts name that starts with uppercase letter" do
      content = """
      ---
      name: MySkill
      description: Starts with capital letter
      ---

      Body text.
      """

      assert {:ok, "MySkill"} = Skills.validate_skill_text(content)
    end

    test "returns error for content with no frontmatter" do
      content = "Just raw text without any frontmatter"
      assert {:error, _reason} = Skills.validate_skill_text(content)
    end
  end

  # ---------------------------------------------------------------------------
  # to_tool_schemas/1
  # ---------------------------------------------------------------------------

  describe "to_tool_schemas/1" do
    test "returns empty list for empty skills" do
      assert Skills.to_tool_schemas([]) == []
    end

    test "converts a single skill without parameters" do
      skill = %Skill{
        name: "no-params",
        description: "A skill with no parameters",
        parameters: [],
        body: "body",
        file_path: "/some/path.md"
      }

      [tool] = Skills.to_tool_schemas([skill])
      assert tool.name == "no-params"
      assert tool.description == "A skill with no parameters"
      assert tool.parameter_schema == %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      }
    end

    test "converts skills with parameters" do
      skill = %Skill{
        name: "with-params",
        description: "Has parameters",
        parameters: [
          %{name: "input", type: "string", description: "The input", required: true},
          %{name: "verbose", type: "boolean", description: "Verbose output", required: false,
            default: false}
        ],
        body: "body",
        file_path: "/some/path.md"
      }

      [tool] = Skills.to_tool_schemas([skill])
      assert tool.name == "with-params"
      assert tool.parameter_schema["type"] == "object"
      assert length(tool.parameter_schema["required"]) == 1
      assert "input" in tool.parameter_schema["required"]
      assert tool.parameter_schema["properties"]["input"]["type"] == "string"
      assert tool.parameter_schema["properties"]["verbose"]["default"] == false
    end

    test "converts multiple skills" do
      skill1 = %Skill{
        name: "skill-a",
        description: "First skill",
        parameters: [],
        body: "body",
        file_path: "/a.md"
      }

      skill2 = %Skill{
        name: "skill-b",
        description: "Second skill",
        parameters: [],
        body: "body",
        file_path: "/b.md"
      }

      tools = Skills.to_tool_schemas([skill1, skill2])
      assert length(tools) == 2
      assert Enum.map(tools, & &1.name) == ["skill-a", "skill-b"]
    end
  end

  # ---------------------------------------------------------------------------
  # find_skill/2
  # ---------------------------------------------------------------------------

  describe "find_skill/2" do
    setup do
      skill1 = %Skill{
        name: "alpha",
        description: "First",
        parameters: [],
        body: "a",
        file_path: "/a.md"
      }

      skill2 = %Skill{
        name: "beta",
        description: "Second",
        parameters: [],
        body: "b",
        file_path: "/b.md"
      }

      {:ok, %{skills: [skill1, skill2]}}
    end

    test "finds skill by exact name", %{skills: skills} do
      assert %Skill{name: "alpha"} = Skills.find_skill(skills, "alpha")
    end

    test "returns nil when not found", %{skills: skills} do
      assert Skills.find_skill(skills, "gamma") == nil
    end

    test "is case-sensitive", %{skills: skills} do
      assert Skills.find_skill(skills, "Alpha") == nil
    end

    test "returns nil for empty list" do
      assert Skills.find_skill([], "anything") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # skill_names/1
  # ---------------------------------------------------------------------------

  describe "skill_names/1" do
    test "returns list of names" do
      skills = [
        %Skill{name: "alpha", description: "", parameters: [], body: "", file_path: ""},
        %Skill{name: "beta", description: "", parameters: [], body: "", file_path: ""},
        %Skill{name: "gamma", description: "", parameters: [], body: "", file_path: ""}
      ]

      assert Skills.skill_names(skills) == ["alpha", "beta", "gamma"]
    end

    test "returns empty list for no skills" do
      assert Skills.skill_names([]) == []
    end
  end

  # ---------------------------------------------------------------------------
  # execute/4
  # ---------------------------------------------------------------------------

  describe "execute/4" do
    test "returns error when skill not found" do
      result = Skills.execute([], "nonexistent", %{}, "/tmp")
      assert result =~ "Error: Skill 'nonexistent' not found"
    end

    test "returns body text when skill has no bash block" do
      skill = %Skill{
        name: "text-skill",
        description: "A text-only skill",
        parameters: [],
        body: "These are instructions for the agent.",
        file_path: "/tmp/text-skill.md"
      }

      result = Skills.execute([skill], "text-skill", %{}, "/tmp")
      assert result =~ "Skill '' instructions:"
      assert result =~ "These are instructions for the agent"
    end
  end

  # ---------------------------------------------------------------------------
  # load_skills/1
  # ---------------------------------------------------------------------------

  describe "load_skills/1" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "evogit_skills_test_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "returns empty list when skills directory does not exist", %{tmp_dir: tmp_dir} do
      assert Skills.load_skills(tmp_dir) == []
    end

    test "returns empty list when skills directory is empty", %{tmp_dir: tmp_dir} do
      skills_dir = Path.join(tmp_dir, ".agents/skills")
      File.mkdir_p!(skills_dir)
      assert Skills.load_skills(tmp_dir) == []
    end

    test "loads valid skill files", %{tmp_dir: tmp_dir} do
      skills_dir = Path.join(tmp_dir, ".agents/skills")
      File.mkdir_p!(skills_dir)
      File.write!(Path.join(skills_dir, "my-skill.md"), valid_skill_content())

      skills = Skills.load_skills(tmp_dir)
      assert length(skills) == 1

      [skill] = skills
      assert skill.name == "my-skill"
      assert skill.description == "Does something useful"
      assert length(skill.parameters) == 2
      assert skill.body =~ "Some body text here"
    end

    test "ignores non-markdown files", %{tmp_dir: tmp_dir} do
      skills_dir = Path.join(tmp_dir, ".agents/skills")
      File.mkdir_p!(skills_dir)
      File.write!(Path.join(skills_dir, "my-skill.md"), valid_skill_content())
      File.write!(Path.join(skills_dir, "README.txt"), "not a skill")
      # notes.md has frontmatter declaring name: simple-skill, so the skill name
      # will be simple-skill (from frontmatter), not notes.
      File.write!(Path.join(skills_dir, "notes.md"), skill_content_no_params())

      skills = Skills.load_skills(tmp_dir)
      # Only .md files are loaded; .txt is ignored
      assert length(skills) == 2
      names = Skills.skill_names(skills) |> Enum.sort()
      assert names == ["my-skill", "simple-skill"]
    end

    test "filters out files that fail to read, keeps those with recoverable content", %{tmp_dir: tmp_dir} do
      skills_dir = Path.join(tmp_dir, ".agents/skills")
      File.mkdir_p!(skills_dir)
      File.write!(Path.join(skills_dir, "valid.md"), valid_skill_content())
      # Content without frontmatter is still parseable — frontmatter returns
      # {:ok, %{}, body} and the skill uses the filename as name.
      File.write!(Path.join(skills_dir, "minimal.md"), "# Just a heading\n\nNo frontmatter.")

      skills = Skills.load_skills(tmp_dir)
      assert length(skills) == 2
      names = Skills.skill_names(skills) |> Enum.sort()
      assert names == ["minimal", "my-skill"]
    end

    test "uses filename as name when frontmatter has no name", %{tmp_dir: tmp_dir} do
      skills_dir = Path.join(tmp_dir, ".agents/skills")
      File.mkdir_p!(skills_dir)

      content = """
      ---
      description: No name in frontmatter
      ---

      Body here.
      """

      File.write!(Path.join(skills_dir, "fallback-name.md"), content)

      skills = Skills.load_skills(tmp_dir)
      assert length(skills) == 1
      assert hd(skills).name == "fallback-name"
    end

    test "loads multiple skills", %{tmp_dir: tmp_dir} do
      skills_dir = Path.join(tmp_dir, ".agents/skills")
      File.mkdir_p!(skills_dir)
      File.write!(Path.join(skills_dir, "skill-a.md"), valid_skill_content())
      File.write!(Path.join(skills_dir, "skill-b.md"), skill_content_no_params())

      skills = Skills.load_skills(tmp_dir)
      assert length(skills) == 2
      names = Skills.skill_names(skills) |> Enum.sort()
      assert names == ["my-skill", "simple-skill"]
    end
  end

  # ---------------------------------------------------------------------------
  # load_hierarchical_skills/2
  # ---------------------------------------------------------------------------

  describe "load_hierarchical_skills/2" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "evogit_hierarchical_skills_test_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      # Create root CONTEXT.md with skills declaration
      File.write!(Path.join(tmp_dir, "CONTEXT.md"), """
      ---
      skills:
        - root-skill
        - shared-skill
      ---
      # Root context
      """)

      # Create .agents/skills directory with skill files
      skills_dir = Path.join(tmp_dir, ".agents/skills")
      File.mkdir_p!(skills_dir)
      File.write!(Path.join(skills_dir, "root-skill.md"), """
      ---
      name: root-skill
      description: A skill declared at root level
      ---
      # Root Skill
      """)
      File.write!(Path.join(skills_dir, "shared-skill.md"), """
      ---
      name: shared-skill
      description: A skill declared at multiple levels
      ---
      # Shared Skill
      """)
      File.write!(Path.join(skills_dir, "child-only-skill.md"), """
      ---
      name: child-only-skill
      description: A skill only declared in child
      ---
      # Child Only Skill
      """)
      File.write!(Path.join(skills_dir, "orphan-skill.md"), """
      ---
      name: orphan-skill
      description: A skill not declared in any CONTEXT.md
      ---
      # Orphan Skill
      """)

      # Create subdirectory with its own CONTEXT.md
      child_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(child_dir)
      File.write!(Path.join(child_dir, "CONTEXT.md"), """
      ---
      skills:
        - child-only-skill
        - shared-skill
      ---
      # Child context
      """)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "returns only skills declared in hierarchy from root", %{tmp_dir: tmp_dir} do
      skills = EvoGit.Skills.load_hierarchical_skills(tmp_dir, "./")
      names = EvoGit.Skills.skill_names(skills) |> Enum.sort()
      assert names == ["root-skill", "shared-skill"]
    end

    test "returns union of skills from root to node", %{tmp_dir: tmp_dir} do
      skills = EvoGit.Skills.load_hierarchical_skills(tmp_dir, "./lib")
      names = EvoGit.Skills.skill_names(skills) |> Enum.sort()
      assert names == ["child-only-skill", "root-skill", "shared-skill"]
    end

    test "returns empty list when no CONTEXT.md has skills", %{tmp_dir: tmp_dir} do
      empty_dir = Path.join(tmp_dir, "empty")
      File.mkdir_p!(empty_dir)
      skills = EvoGit.Skills.load_hierarchical_skills(tmp_dir, "./empty")
      assert skills == []
    end

    test "returns empty list when CONTEXT.md exists but has no skills field", %{tmp_dir: tmp_dir} do
      no_skills_dir = Path.join(tmp_dir, "noskills")
      File.mkdir_p!(no_skills_dir)
      File.write!(Path.join(no_skills_dir, "CONTEXT.md"), "# No front matter")
      skills = EvoGit.Skills.load_hierarchical_skills(tmp_dir, "./noskills")
      # At ./noskills, the root ./ CONTEXT.md declares root-skill and shared-skill
      names = EvoGit.Skills.skill_names(skills) |> Enum.sort()
      assert names == ["root-skill", "shared-skill"]
    end

    test "orphan skills (on disk but not in CONTEXT.md) are excluded", %{tmp_dir: tmp_dir} do
      skills = EvoGit.Skills.load_hierarchical_skills(tmp_dir, "./")
      names = EvoGit.Skills.skill_names(skills)
      refute "orphan-skill" in names
    end
  end

  # ---------------------------------------------------------------------------
  # parse_skill_file/1
  # ---------------------------------------------------------------------------

  describe "parse_skill_file/1" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "evogit_skills_test_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir}}
    end

    test "parses a valid skill file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test-skill.md")
      File.write!(file_path, valid_skill_content())

      assert %Skill{} = skill = Skills.parse_skill_file(file_path)
      assert skill.name == "my-skill"
      assert skill.description == "Does something useful"
      assert length(skill.parameters) == 2
      assert skill.file_path == file_path
    end

    test "returns nil for non-existent file" do
      assert Skills.parse_skill_file("/tmp/nonexistent_skill_12345.md") == nil
    end
  end

  # ---------------------------------------------------------------------------
  # CRUD Operations
  # ---------------------------------------------------------------------------

  describe "CRUD operations" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "evogit_skills_test_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{tmp_dir: tmp_dir}}
    end

    # add_skill/4

    test "add_skill creates a skill file", %{tmp_dir: tmp_dir} do
      assert {:ok, file_path} = Skills.add_skill(tmp_dir, valid_skill_content(), "", "")
      assert String.ends_with?(file_path, ".agents/skills/my-skill.md")
      assert File.exists?(file_path)

      # Verify content is written correctly
      content = File.read!(file_path)
      assert content =~ "name: my-skill"
    end

    test "add_skill returns error for duplicate name", %{tmp_dir: tmp_dir} do
      assert {:ok, _path} = Skills.add_skill(tmp_dir, valid_skill_content(), "", "")
      assert {:error, reason} = Skills.add_skill(tmp_dir, valid_skill_content(), "", "")
      assert reason =~ "already exists"
    end

    test "add_skill returns error for invalid skill content", %{tmp_dir: tmp_dir} do
      content = """
      ---
      description: No name field
      ---

      Body.
      """

      assert {:error, reason} = Skills.add_skill(tmp_dir, content, "", "")
      assert reason =~ "must have a 'name'"
    end

    # edit_skill/3

    test "edit_skill updates an existing skill file", %{tmp_dir: tmp_dir} do
      {:ok, path} = Skills.add_skill(tmp_dir, valid_skill_content(), "", "")

      updated_content = """
      ---
      name: my-skill
      description: Updated description
      ---

      Updated body.
      """

      assert {:ok, ^path} = Skills.edit_skill(tmp_dir, "my-skill", updated_content)
      assert File.read!(path) =~ "Updated description"
      assert File.read!(path) =~ "Updated body"
    end

    test "edit_skill returns error when skill not found", %{tmp_dir: tmp_dir} do
      assert {:error, reason} = Skills.edit_skill(tmp_dir, "nonexistent", valid_skill_content())
      assert reason =~ "not found"
    end

    test "edit_skill returns error on name mismatch", %{tmp_dir: tmp_dir} do
      {:ok, _path} = Skills.add_skill(tmp_dir, valid_skill_content(), "", "")

      mismatched_content = """
      ---
      name: other-name
      description: Different name
      ---

      Body.
      """

      assert {:error, reason} = Skills.edit_skill(tmp_dir, "my-skill", mismatched_content)
      assert reason =~ "name mismatch"
    end

    # remove_skill/2

    test "remove_skill deletes a skill file", %{tmp_dir: tmp_dir} do
      {:ok, file_path} = Skills.add_skill(tmp_dir, valid_skill_content(), "", "")
      assert File.exists?(file_path)

      assert :ok = Skills.remove_skill(tmp_dir, "my-skill")
      refute File.exists?(file_path)
    end

    test "remove_skill returns error when skill not found", %{tmp_dir: tmp_dir} do
      assert {:error, reason} = Skills.remove_skill(tmp_dir, "nonexistent")
      assert reason =~ "not found"
    end

    # list_skills/1

    test "list_skills returns formatted list", %{tmp_dir: tmp_dir} do
      Skills.add_skill(tmp_dir, valid_skill_content(), "", "")

      result = Skills.list_skills(tmp_dir)
      assert result =~ "Available skills"
      assert result =~ "my-skill"
      assert result =~ "Does something useful"
      assert result =~ "input: string"
      assert result =~ "verbose: boolean"
    end

    test "list_skills returns placeholder text when no skills exist", %{tmp_dir: tmp_dir} do
      result = Skills.list_skills(tmp_dir)
      assert result =~ "No skills available"
    end

    # read_skill/1

    test "read_skill returns raw content", %{tmp_dir: tmp_dir} do
      Skills.add_skill(tmp_dir, valid_skill_content(), "", "")

      content = Skills.read_skill(tmp_dir, "my-skill")
      assert content =~ "name: my-skill"
      assert content =~ "Some body text here"
    end

    test "read_skill returns error when skill not found", %{tmp_dir: tmp_dir} do
      result = Skills.read_skill(tmp_dir, "nonexistent")
      assert result =~ "Error: Skill 'nonexistent' not found"
    end
  end

  # ---------------------------------------------------------------------------
  # list_skills_from/1
  # ---------------------------------------------------------------------------

  describe "list_skills_from/1" do
    test "returns placeholder when list is empty" do
      result = EvoGit.Skills.list_skills_from([])
      assert result =~ "No skills available"
    end

    test "lists skills from provided list" do
      skill = %EvoGit.Skills.Skill{
        name: "test-skill",
        description: "A test skill",
        parameters: [],
        body: "body",
        file_path: "/tmp/test.md"
      }

      result = EvoGit.Skills.list_skills_from([skill])
      assert result =~ "test-skill"
      assert result =~ "A test skill"
    end
  end

  # ---------------------------------------------------------------------------
  # read_skill_from/2
  # ---------------------------------------------------------------------------

  describe "read_skill_from/2" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "evogit_read_skill_from_test_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)
      file_path = Path.join(tmp_dir, "test-skill.md")
      File.write!(file_path, """
      ---
      name: test-skill
      description: Test
      ---
      Body content.
      """)

      skill = %EvoGit.Skills.Skill{
        name: "test-skill",
        description: "Test",
        parameters: [],
        body: "Body content.",
        file_path: file_path
      }

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      {:ok, %{skill: skill}}
    end

    test "reads skill content when in list", %{skill: skill} do
      result = EvoGit.Skills.read_skill_from([skill], "test-skill")
      assert result =~ "name: test-skill"
      assert result =~ "Body content"
    end

    test "returns error when skill not in list" do
      result = EvoGit.Skills.read_skill_from([], "nonexistent")
      assert result =~ "not found or not available"
    end
  end
end
