defmodule EvoGit.ProjectConfigTest do
  use ExUnit.Case, async: true

  alias EvoGit.ProjectConfig

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "evo_git_project_config_" <> to_string(System.unique_integer())
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  describe "read/1" do
    test "returns nil when no config file exists", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.read(tmp_dir) == nil
    end

    test "returns parsed map for valid genesis.toml", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup_worktree.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert %{"worktree" => %{"script" => "scripts/setup_worktree.sh"}} =
               ProjectConfig.read(tmp_dir)
    end

    test "returns empty map for empty genesis.toml", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "genesis.toml"), "")

      assert ProjectConfig.read(tmp_dir) == %{}
    end

    test "returns nil and logs warning for invalid TOML", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "genesis.toml"), "[invalid = missing_value")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ProjectConfig.read(tmp_dir) == nil
        end)

      assert log =~ "Failed to parse"
    end

    test "falls back to legacy evogit.toml when genesis.toml is absent", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup_worktree.sh"
      """

      File.write!(Path.join(tmp_dir, "evogit.toml"), toml_content)

      assert %{"worktree" => %{"script" => "scripts/setup_worktree.sh"}} =
               ProjectConfig.read(tmp_dir)
    end

    test "prefers genesis.toml over legacy evogit.toml when both exist", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "genesis.toml"), "[commands]\ndev = \"mix test\"\n")
      File.write!(Path.join(tmp_dir, "evogit.toml"), "[commands]\ndev = \"npm run dev\"\n")

      config = ProjectConfig.read(tmp_dir)
      assert config["commands"]["dev"] == "mix test"
    end
  end

  describe "worktree_script/1" do
    test "returns nil when no config file exists", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.worktree_script(tmp_dir) == nil
    end

    test "returns script path when worktree.script is configured", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup_worktree.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir) == "scripts/setup_worktree.sh"
    end

    test "returns nil when worktree section exists but no script key", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      timeout = 30
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir) == nil
    end

    test "returns nil when config has no worktree section", %{tmp_dir: tmp_dir} do
      toml_content = """
      [other]
      key = "value"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir) == nil
    end
  end

  describe "foreign_repos/1" do
    test "returns empty list when no config file exists", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.foreign_repos(tmp_dir) == []
    end

    test "returns empty list when no foreign_repos section exists", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup_worktree.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.foreign_repos(tmp_dir) == []
    end

    test "parses multiple foreign repo entries", %{tmp_dir: tmp_dir} do
      toml_content = """
      [foreign_repos.original]
      path = "/Source/original-proj"

      [foreign_repos.reference]
      path = "/Source/rust-rewrite-proj"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      repos = ProjectConfig.foreign_repos(tmp_dir)

      assert length(repos) == 2

      ids = Enum.map(repos, & &1.id) |> Enum.sort()
      assert ids == ["original", "reference"]

      roots = Enum.map(repos, & &1.root) |> Enum.sort()
      assert roots == ["/Source/original-proj", "/Source/rust-rewrite-proj"]
    end

    test "handles optional description field", %{tmp_dir: tmp_dir} do
      toml_content = """
      [foreign_repos.original]
      path = "/Source/original-proj"
      description = "Legacy Project"

      [foreign_repos.reference]
      path = "/Source/rust-rewrite-proj"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      repos = ProjectConfig.foreign_repos(tmp_dir)

      original = Enum.find(repos, &(&1.id == "original"))
      reference = Enum.find(repos, &(&1.id == "reference"))

      # Explicit description is used when provided
      assert original.description == "Legacy Project"
      # Defaults to nil when description is omitted
      assert reference.description == nil
    end

    test "returns empty list and logs warning for invalid foreign_repos config", %{
      tmp_dir: tmp_dir
    } do
      toml_content = """
      [foreign_repos.broken]
      missing_path = "oops"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ProjectConfig.foreign_repos(tmp_dir) == []
        end)

      assert log =~ "Failed to parse foreign_repos"
    end
  end

  describe "worktree_script/2 (OS variants)" do
    test "returns OS-specific script when matching variant exists", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script.linux = "scripts/setup_linux.sh"
      script.macos = "scripts/setup_macos.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir, :linux) == "scripts/setup_linux.sh"
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == "scripts/setup_macos.sh"
    end

    test "returns nil when OS-specific variant does not exist", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script.linux = "scripts/setup_linux.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir, :macos) == nil
      assert ProjectConfig.worktree_script(tmp_dir, :windows) == nil
    end

    test "returns fallback string script when no OS-specific variants", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      # String script is returned regardless of OS queried
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == "scripts/setup.sh"
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == "scripts/setup.sh"
      assert ProjectConfig.worktree_script(tmp_dir, :windows) == "scripts/setup.sh"
    end

    test "returns nil when no config file exists", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == nil
    end

    test "returns nil when worktree section exists but no script", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      timeout = 30
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.worktree_script(tmp_dir, :linux) == nil
    end

    test "OS-specific map does not fall back to string (TOML parses as map or string, not both)" do
      # This test documents the behavior: when script is a map (OS variants),
      # a non-matching OS returns nil — it does NOT fall back to a separate
      # string script because TOML doesn't allow both forms simultaneously.
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "evo_git_project_config_" <> to_string(System.unique_integer())
        )

      File.mkdir_p!(tmp_dir)

      toml_content = """
      [worktree]
      script.linux = "scripts/setup_linux.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      # No macos variant in the map → nil
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == nil

      File.rm_rf!(tmp_dir)
    end
  end

  describe "commands/1" do
    test "parses commands correctly", %{tmp_dir: tmp_dir} do
      toml_content = """
      [commands]
      dev = "npm run dev"
      test = "mix test"
      build = "mix compile"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      commands = ProjectConfig.commands(tmp_dir)

      assert commands == %{
               "dev" => "npm run dev",
               "test" => "mix test",
               "build" => "mix compile"
             }
    end

    test "returns empty map when no commands section", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script = "scripts/setup.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert ProjectConfig.commands(tmp_dir) == %{}
    end

    test "returns empty map when no config file exists", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.commands(tmp_dir) == %{}
    end
  end

  describe "write_worktree_script/2" do
    @scripts %{
      linux: "#!/bin/bash\ncp -R \"$SOURCE_REPO_PATH/deps\" \"$TARGET_WORKTREE_PATH/\"\n",
      macos: "#!/bin/bash\ncp -cR \"$SOURCE_REPO_PATH/deps\" \"$TARGET_WORKTREE_PATH/\"\n",
      windows:
        "# Copy deps\nCopy-Item -Recurse \"$env:SOURCE_REPO_PATH/deps\" \"$env:TARGET_WORKTREE_PATH/\"\n"
    }

    test "creates genesis.toml when it does not exist", %{tmp_dir: tmp_dir} do
      assert ProjectConfig.read(tmp_dir) == nil

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      assert File.exists?(Path.join(tmp_dir, "genesis.toml"))
    end

    test "writes top-level comment when creating new genesis.toml", %{tmp_dir: tmp_dir} do
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      contents = File.read!(Path.join(tmp_dir, "genesis.toml"))

      assert contents =~ "genesis.toml — EvoGit project configuration file."
      assert contents =~ "EvoGit agents read this file automatically"
    end

    test "writes worktree section comment block", %{tmp_dir: tmp_dir} do
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      contents = File.read!(Path.join(tmp_dir, "genesis.toml"))

      assert contents =~ "Worktree Init Script"
      assert contents =~ "SOURCE_REPO_PATH"
      assert contents =~ "TARGET_WORKTREE_PATH"
      assert contents =~ "WARNING"
    end

    test "round-trips: written scripts are readable via worktree_script/2", %{tmp_dir: tmp_dir} do
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      assert ProjectConfig.worktree_script(tmp_dir, :linux) == @scripts.linux
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == @scripts.macos
      assert ProjectConfig.worktree_script(tmp_dir, :windows) == @scripts.windows
    end

    test "merges into existing genesis.toml preserving other sections", %{tmp_dir: tmp_dir} do
      toml_content = """
      [commands]
      dev = "mix test"

      [foreign_repos.original]
      path = "/Source/original-proj"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      # The script is readable
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == @scripts.linux

      # Other sections preserved
      config = ProjectConfig.read(tmp_dir)
      assert config["commands"]["dev"] == "mix test"
      assert config["foreign_repos"]["original"]["path"] == "/Source/original-proj"
    end

    test "preserves existing non-script keys in [worktree] section", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      timeout = 30
      verbose = true
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      config = ProjectConfig.read(tmp_dir)
      assert config["worktree"]["timeout"] == 30
      assert config["worktree"]["verbose"] == true
      assert config["worktree"]["script"]["linux"] == @scripts.linux
    end

    test "updates existing script values", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "genesis.toml"), "[worktree]\nscript = \"old.sh\"\n")

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      assert ProjectConfig.worktree_script(tmp_dir, :linux) == @scripts.linux
    end

    test "replaces existing single-string script with OS-variant form", %{tmp_dir: tmp_dir} do
      toml_content = """
      [worktree]
      script.linux = "scripts/setup_linux.sh"
      script.macos = "scripts/setup_macos.sh"
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), toml_content)

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      # The OS-variant form now takes precedence
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == @scripts.linux
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == @scripts.macos
    end

    test "handles script content containing triple single quotes", %{tmp_dir: tmp_dir} do
      # Content with ''' — the encoder must fall back to escaped form
      tricky_scripts = %{
        linux: "echo hi\n'''\necho there\n",
        macos: "echo hi\n'''\necho there\n",
        windows: "echo hi\n'''\necho there\n"
      }

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, tricky_scripts)

      assert ProjectConfig.worktree_script(tmp_dir, :linux) == tricky_scripts.linux
    end

    test "does not duplicate top-level comment when updating existing file", %{tmp_dir: tmp_dir} do
      # First write creates the file with top-level comment
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      # Second write should not duplicate the top-level comment
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      contents = File.read!(Path.join(tmp_dir, "genesis.toml"))

      # Count occurrences of the top-level comment first line
      first_line = "# genesis.toml — EvoGit project configuration file."
      count = contents |> String.split("\n") |> Enum.count(&(&1 == first_line))

      assert count == 1
    end

    test "does not duplicate worktree comment block when updating existing file", %{
      tmp_dir: tmp_dir
    } do
      # First write creates the file with worktree comment block
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      # Second write should not duplicate the worktree comment block
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, @scripts)

      contents = File.read!(Path.join(tmp_dir, "genesis.toml"))

      # Count occurrences of the comment block header
      count = contents |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "# ───"))

      assert count == 1
    end

    test "handles updating genesis.toml with multi-line literal string scripts without corruption",
         %{tmp_dir: tmp_dir} do
      # Use realistic multi-line scripts similar to Rust build system scripts
      multi_line_scripts = %{
        linux: """
        #!/bin/bash
        set -euo pipefail

        # Copy Rust build artifacts for warm cache
        if [ -d "$SOURCE_REPO_PATH/target" ]; then
          cp -R --reflink=auto "$SOURCE_REPO_PATH/target" "$TARGET_WORKTREE_PATH/"
        fi

        # Copy deps
        if [ -d "$SOURCE_REPO_PATH/deps" ]; then
          cp -R --reflink=auto "$SOURCE_REPO_PATH/deps" "$TARGET_WORKTREE_PATH/"
        fi
        """,
        macos: """
        #!/bin/bash
        set -euo pipefail

        if [ -d "$SOURCE_REPO_PATH/target" ]; then
          cp -cR "$SOURCE_REPO_PATH/target" "$TARGET_WORKTREE_PATH/"
        fi

        if [ -d "$SOURCE_REPO_PATH/deps" ]; then
          cp -cR "$SOURCE_REPO_PATH/deps" "$TARGET_WORKTREE_PATH/"
        fi
        """,
        windows: """
        # Copy Rust build artifacts
        if (Test-Path "$env:SOURCE_REPO_PATH/target") {
          Copy-Item -Recurse "$env:SOURCE_REPO_PATH/target" "$env:TARGET_WORKTREE_PATH/"
        }
        if (Test-Path "$env:SOURCE_REPO_PATH/deps") {
          Copy-Item -Recurse "$env:SOURCE_REPO_PATH/deps" "$env:TARGET_WORKTREE_PATH/"
        }
        """
      }

      # First write: creates genesis.toml with multi-line literal string scripts
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, multi_line_scripts)

      # Verify first write is valid TOML and readable
      config1 = ProjectConfig.read(tmp_dir)
      assert config1 != nil
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == multi_line_scripts.linux

      # Second write with DIFFERENT scripts: this is where the corruption bug manifests
      updated_scripts = %{
        linux: "#!/bin/bash\necho 'updated linux script'\n",
        macos: "#!/bin/bash\necho 'updated macos script'\n",
        windows: "# PowerShell\necho 'updated windows script'\n"
      }

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, updated_scripts)

      # CRITICAL: The output must be valid TOML (not corrupted with raw content)
      config2 = ProjectConfig.read(tmp_dir)
      assert config2 != nil, "genesis.toml should be valid TOML after update"

      # Updated scripts should be readable
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == updated_scripts.linux
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == updated_scripts.macos
      assert ProjectConfig.worktree_script(tmp_dir, :windows) == updated_scripts.windows

      # Verify no raw script content appears outside of proper entries
      contents = File.read!(Path.join(tmp_dir, "genesis.toml"))

      # Count lines that are EXACTLY "'''" — there should be exactly one closing
      # delimiter per OS script (3 total).
      closing_delim_count =
        contents
        |> String.split("\n")
        |> Enum.count(&(String.trim(&1) == "'''"))

      assert closing_delim_count == 3,
             "Expected exactly 3 closing ''' delimiters (one per OS script), got #{closing_delim_count}"
    end

    test "idempotent: writing same multi-line scripts twice produces valid TOML", %{
      tmp_dir: tmp_dir
    } do
      multi_line_scripts = %{
        linux:
          "#!/bin/bash\nif [ -d \"$SOURCE_REPO_PATH/deps\" ]; then\n  cp -R --reflink=auto \"$SOURCE_REPO_PATH/deps\" \"$TARGET_WORKTREE_PATH/\"\nfi\n",
        macos:
          "#!/bin/bash\nif [ -d \"$SOURCE_REPO_PATH/deps\" ]; then\n  cp -cR \"$SOURCE_REPO_PATH/deps\" \"$TARGET_WORKTREE_PATH/\"\nfi\n",
        windows:
          "if (Test-Path \"$env:SOURCE_REPO_PATH/deps\") {\n  Copy-Item -Recurse \"$env:SOURCE_REPO_PATH/deps\" \"$env:TARGET_WORKTREE_PATH/\"\n}\n"
      }

      # First write
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, multi_line_scripts)
      assert ProjectConfig.read(tmp_dir) != nil

      # Second write with same scripts
      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, multi_line_scripts)

      # Must still be valid TOML
      config = ProjectConfig.read(tmp_dir)
      assert config != nil, "genesis.toml should be valid TOML after second write"
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == multi_line_scripts.linux
    end

    test "cleans up corrupted genesis.toml with raw script fragments and stray delimiters",
         %{tmp_dir: tmp_dir} do
      # This simulates a corrupted [worktree] section: raw script body fragments
      # and stray ''' delimiters BEFORE the proper script entries. The classic
      # corruption pattern where the old multi-line content was not fully stripped.
      corrupted_toml = """
      [commands]
      dev = "mix test"

      [worktree]
      # Copy Rust build artifacts
      if [ -d "$SOURCE_REPO_PATH/target" ]; then
        cp -R --reflink=auto "$SOURCE_REPO_PATH/target" "$TARGET_WORKTREE_PATH/"
      fi
      '''
      # Copy Rust build artifacts
      if [ -d "$SOURCE_REPO_PATH/target" ]; then
        cp -cR "$SOURCE_REPO_PATH/target" "$TARGET_WORKTREE_PATH/"
      fi
      '''
      if (Test-Path "$env:SOURCE_REPO_PATH/target") {
          Copy-Item -Recurse -Force "$env:SOURCE_REPO_PATH/target" "$env:TARGET_WORKTREE_PATH/"
      }
      '''
      script.linux = '''#!/usr/bin/env bash
      echo hello
      '''
      script.macos = '''#!/usr/bin/env bash
      echo hello
      '''
      script.windows = '''# PowerShell
      echo hello
      '''
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), corrupted_toml)

      new_scripts = %{
        linux: "#!/bin/bash\necho 'clean linux'\n",
        macos: "#!/bin/bash\necho 'clean macos'\n",
        windows: "# PowerShell\necho 'clean windows'\n"
      }

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, new_scripts)

      # Output must be valid TOML
      config = ProjectConfig.read(tmp_dir)
      assert config != nil, "genesis.toml should be valid TOML after cleanup"

      # Other sections preserved
      assert config["commands"]["dev"] == "mix test"

      # New scripts are readable
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == new_scripts.linux
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == new_scripts.macos
      assert ProjectConfig.worktree_script(tmp_dir, :windows) == new_scripts.windows

      # Verify exactly 6 triple-quote delimiters (2 per OS script: open + close)
      contents = File.read!(Path.join(tmp_dir, "genesis.toml"))

      # Count ''' occurrences: split on the delimiter, subtract 1 for the parts count
      delim_count = max(0, length(String.split(contents, "'''")) - 1)

      assert delim_count == 6,
             "Expected exactly 6 ''' delimiters (open+close per 3 OS scripts), got #{delim_count}"

      # No raw script body fragments should appear outside proper entries
      refute contents =~ "cp -R --reflink=auto",
             "Raw script body should have been cleaned up"
      refute contents =~ "cp -cR",
             "Raw script body should have been cleaned up"
      refute contents =~ "Copy-Item -Recurse -Force",
             "Raw script body should have been cleaned up"
    end

    test "cleans up corrupted genesis.toml with only raw fragments (no proper script entries)",
         %{tmp_dir: tmp_dir} do
      # Only raw script bodies and stray ''' — no script.* entries at all.
      corrupted_toml = """
      [commands]
      test = "mix test"

      [worktree]
      if [ -d "$SOURCE_REPO_PATH/target" ]; then
        cp -R --reflink=auto "$SOURCE_REPO_PATH/target" "$TARGET_WORKTREE_PATH/"
      fi
      '''
      if (Test-Path "$env:SOURCE_REPO_PATH/target") {
          Copy-Item -Recurse -Force "$env:SOURCE_REPO_PATH/target" "$env:TARGET_WORKTREE_PATH/"
      }
      '''
      """

      File.write!(Path.join(tmp_dir, "genesis.toml"), corrupted_toml)

      new_scripts = %{
        linux: "#!/bin/bash\necho 'clean linux'\n",
        macos: "#!/bin/bash\necho 'clean macos'\n",
        windows: "# PowerShell\necho 'clean windows'\n"
      }

      assert :ok == ProjectConfig.write_worktree_script(tmp_dir, new_scripts)

      # Output must be valid TOML
      config = ProjectConfig.read(tmp_dir)
      assert config != nil, "genesis.toml should be valid TOML after cleanup"

      # Other sections preserved
      assert config["commands"]["test"] == "mix test"

      # New scripts are readable
      assert ProjectConfig.worktree_script(tmp_dir, :linux) == new_scripts.linux
      assert ProjectConfig.worktree_script(tmp_dir, :macos) == new_scripts.macos
      assert ProjectConfig.worktree_script(tmp_dir, :windows) == new_scripts.windows

      # No raw fragments
      contents = File.read!(Path.join(tmp_dir, "genesis.toml"))
      refute contents =~ "cp -R --reflink=auto"
      refute contents =~ "Copy-Item -Recurse -Force"

      # Exactly 6 triple-quote delimiters
      delim_count = max(0, length(String.split(contents, "'''")) - 1)

      assert delim_count == 6,
             "Expected exactly 6 ''' delimiters, got #{delim_count}"
    end
  end
end
