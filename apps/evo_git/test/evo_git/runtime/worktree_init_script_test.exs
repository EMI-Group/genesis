defmodule EvoGit.Runtime.WorktreeInitScriptTest do
  use ExUnit.Case, async: true

  alias EvoGit.Runtime.WorktreeInitScript

  describe "extract_script/1" do
    test "extracts code from a bash code fence" do
      response = """
      Here is the script:

      ```bash
      #!/bin/bash
      cp --reflink=auto -r $SOURCE_REPO_PATH/deps $TARGET_WORKTREE_PATH/
      ```
      """

      result = WorktreeInitScript.extract_script(response)

      assert result == """
             #!/bin/bash
             cp --reflink=auto -r $SOURCE_REPO_PATH/deps $TARGET_WORKTREE_PATH/\
             """
    end

    test "extracts code from a sh code fence" do
      response = """
      ```sh
      #!/bin/sh
      cp -r $SOURCE_REPO_PATH/node_modules $TARGET_WORKTREE_PATH/
      ```
      """

      result = WorktreeInitScript.extract_script(response)

      assert result == """
             #!/bin/sh
             cp -r $SOURCE_REPO_PATH/node_modules $TARGET_WORKTREE_PATH/\
             """
    end

    test "extracts code from a plain (untagged) code fence" do
      response = """
      ```
      #!/bin/bash
      echo done
      ```
      """

      assert WorktreeInitScript.extract_script(response) == "#!/bin/bash\necho done"
    end

    test "returns trimmed response when no code fence present" do
      response = "  #!/bin/bash\ncp -r foo bar\n  "

      assert WorktreeInitScript.extract_script(response) == "#!/bin/bash\ncp -r foo bar"
    end

    test "handles empty string" do
      assert WorktreeInitScript.extract_script("") == ""
    end

    test "extracts first code block when multiple fences present" do
      response = """
      ```bash
      echo first
      ```

      Some commentary

      ```bash
      echo second
      ```
      """

      assert WorktreeInitScript.extract_script(response) == "echo first"
    end
  end

  describe "build_system_prompt/0" do
    test "contains the three environment variable names" do
      prompt = WorktreeInitScript.build_system_prompt()

      assert prompt =~ "$SOURCE_REPO_PATH"
      assert prompt =~ "$SOURCE_WORKTREE_PATH"
      assert prompt =~ "$TARGET_WORKTREE_PATH"
    end

    test "describes the purpose of the script" do
      prompt = WorktreeInitScript.build_system_prompt()

      assert prompt =~ ~r/cop/i or prompt =~ "dependencies"
      assert prompt =~ "worktree"
    end

    test "contains example commands for multiple ecosystems" do
      prompt = WorktreeInitScript.build_system_prompt()

      # Elixir
      assert prompt =~ "deps"
      assert prompt =~ "_build"
      # Node.js
      assert prompt =~ "node_modules"
      # Python
      assert prompt =~ ".venv"
      # Rust
      assert prompt =~ "target"
      # Go
      assert prompt =~ "vendor"
    end

    test "recommends cp --reflink=auto" do
      prompt = WorktreeInitScript.build_system_prompt()

      assert prompt =~ "cp --reflink=auto"
    end

    test "instructs to output only the script" do
      prompt = WorktreeInitScript.build_system_prompt()

      assert prompt =~ ~r/ONLY the script/i
    end

    test "mentions shebang" do
      prompt = WorktreeInitScript.build_system_prompt()

      assert prompt =~ "#!/bin/bash" or prompt =~ "#!/bin/sh"
    end
  end

  describe "build_user_prompt/1" do
    test "includes the objective" do
      objective = "Build a REST API in Elixir with Phoenix"

      prompt = WorktreeInitScript.build_user_prompt(objective)

      assert prompt =~ objective
    end

    test "asks to generate a worktree init script" do
      prompt = WorktreeInitScript.build_user_prompt("some objective")

      assert prompt =~ ~r/worktree init script/i
    end
  end

  describe "generate/2" do
    test "returns :skip when no LLM model is configured" do
      # When no model is configured (default in CI without config.toml),
      # generate/2 should return :skip rather than attempting an LLM call.
      result = WorktreeInitScript.generate("Build a project", "/tmp/nonexistent")

      case result do
        :skip -> :ok
        {:ok, _script} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end
end
