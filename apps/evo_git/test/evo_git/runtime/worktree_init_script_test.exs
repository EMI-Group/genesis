defmodule EvoGit.Runtime.WorktreeInitScriptTest do
  use ExUnit.Case, async: true

  alias EvoGit.Runtime.WorktreeInitScript

  describe "build_systems/0" do
    test "returns a list of build system maps" do
      systems = WorktreeInitScript.build_systems()

      assert is_list(systems)
      assert length(systems) == 6
    end

    test "each entry has the required keys" do
      for bs <- WorktreeInitScript.build_systems() do
        assert Map.has_key?(bs, :id)
        assert Map.has_key?(bs, :name)
        assert Map.has_key?(bs, :unix_script)
        assert Map.has_key?(bs, :windows_script)
      end
    end

    test "contains all expected ecosystem ids" do
      ids = WorktreeInitScript.build_systems() |> Enum.map(& &1.id)

      assert ids == [:elixir, :node, :python, :rust, :go, :none]
    end

    test "each entry has a display name" do
      names = WorktreeInitScript.build_systems() |> Enum.map(& &1.name)

      assert "Elixir / Erlang (Mix)" in names
      assert "Node.js (npm/yarn)" in names
      assert "Python (venv)" in names
      assert "Rust (Cargo)" in names
      assert "Go (modules)" in names
      assert "None / Generic" in names
    end
  end

  describe "get_build_system/1" do
    test "returns the correct map for :elixir" do
      bs = WorktreeInitScript.get_build_system(:elixir)

      assert bs.id == :elixir
      assert bs.name == "Elixir / Erlang (Mix)"
    end

    test "returns the correct map for :node" do
      bs = WorktreeInitScript.get_build_system(:node)

      assert bs.id == :node
      assert bs.name == "Node.js (npm/yarn)"
    end

    test "returns the correct map for :python" do
      bs = WorktreeInitScript.get_build_system(:python)

      assert bs.id == :python
      assert bs.name == "Python (venv)"
    end

    test "returns the correct map for :rust" do
      bs = WorktreeInitScript.get_build_system(:rust)

      assert bs.id == :rust
      assert bs.name == "Rust (Cargo)"
    end

    test "returns the correct map for :go" do
      bs = WorktreeInitScript.get_build_system(:go)

      assert bs.id == :go
      assert bs.name == "Go (modules)"
    end

    test "returns the correct map for :none" do
      bs = WorktreeInitScript.get_build_system(:none)

      assert bs.id == :none
      assert bs.name == "None / Generic"
    end

    test "returns nil for unknown id" do
      assert WorktreeInitScript.get_build_system(:unknown) == nil
    end
  end

  describe "scripts_for/1" do
    test "returns unix and windows scripts for a build system map" do
      bs = WorktreeInitScript.get_build_system(:elixir)
      scripts = WorktreeInitScript.scripts_for(bs)

      assert Map.has_key?(scripts, :unix)
      assert Map.has_key?(scripts, :windows)
      assert is_binary(scripts.unix)
      assert is_binary(scripts.windows)
    end

    test "returns unix and windows scripts for an atom id" do
      scripts = WorktreeInitScript.scripts_for(:elixir)

      assert Map.has_key?(scripts, :unix)
      assert Map.has_key?(scripts, :windows)
    end

    test "returns nil for unknown atom id" do
      assert WorktreeInitScript.scripts_for(:unknown) == nil
    end

    test "elixir unix script has bash shebang and copies deps and _build" do
      scripts = WorktreeInitScript.scripts_for(:elixir)

      assert String.starts_with?(scripts.unix, "#!/bin/bash")
      assert scripts.unix =~ "deps"
      assert scripts.unix =~ "_build"
      assert scripts.unix =~ "$SOURCE_REPO_PATH"
      assert scripts.unix =~ "$TARGET_WORKTREE_PATH"
    end

    test "elixir windows script uses PowerShell syntax" do
      scripts = WorktreeInitScript.scripts_for(:elixir)

      assert scripts.windows =~ "$env:SOURCE_REPO_PATH"
      assert scripts.windows =~ "$env:TARGET_WORKTREE_PATH"
      assert scripts.windows =~ "deps"
      assert scripts.windows =~ "_build"
    end

    test "node unix script has bash shebang and copies node_modules" do
      scripts = WorktreeInitScript.scripts_for(:node)

      assert String.starts_with?(scripts.unix, "#!/bin/bash")
      assert scripts.unix =~ "node_modules"
      assert scripts.unix =~ "$SOURCE_REPO_PATH"
      assert scripts.unix =~ "$TARGET_WORKTREE_PATH"
    end

    test "node windows script uses PowerShell syntax" do
      scripts = WorktreeInitScript.scripts_for(:node)

      assert scripts.windows =~ "$env:SOURCE_REPO_PATH"
      assert scripts.windows =~ "$env:TARGET_WORKTREE_PATH"
      assert scripts.windows =~ "node_modules"
    end

    test "python unix script has bash shebang and copies .venv" do
      scripts = WorktreeInitScript.scripts_for(:python)

      assert String.starts_with?(scripts.unix, "#!/bin/bash")
      assert scripts.unix =~ ".venv"
      assert scripts.unix =~ "$SOURCE_REPO_PATH"
      assert scripts.unix =~ "$TARGET_WORKTREE_PATH"
    end

    test "python windows script uses PowerShell syntax" do
      scripts = WorktreeInitScript.scripts_for(:python)

      assert scripts.windows =~ "$env:SOURCE_REPO_PATH"
      assert scripts.windows =~ "$env:TARGET_WORKTREE_PATH"
      assert scripts.windows =~ ".venv"
    end

    test "rust unix script has bash shebang and copies target" do
      scripts = WorktreeInitScript.scripts_for(:rust)

      assert String.starts_with?(scripts.unix, "#!/bin/bash")
      assert scripts.unix =~ "target"
      assert scripts.unix =~ "$SOURCE_REPO_PATH"
      assert scripts.unix =~ "$TARGET_WORKTREE_PATH"
    end

    test "rust windows script uses PowerShell syntax" do
      scripts = WorktreeInitScript.scripts_for(:rust)

      assert scripts.windows =~ "$env:SOURCE_REPO_PATH"
      assert scripts.windows =~ "$env:TARGET_WORKTREE_PATH"
      assert scripts.windows =~ "target"
    end

    test "go unix script has bash shebang and copies vendor" do
      scripts = WorktreeInitScript.scripts_for(:go)

      assert String.starts_with?(scripts.unix, "#!/bin/bash")
      assert scripts.unix =~ "vendor"
      assert scripts.unix =~ "$SOURCE_REPO_PATH"
      assert scripts.unix =~ "$TARGET_WORKTREE_PATH"
    end

    test "go windows script uses PowerShell syntax" do
      scripts = WorktreeInitScript.scripts_for(:go)

      assert scripts.windows =~ "$env:SOURCE_REPO_PATH"
      assert scripts.windows =~ "$env:TARGET_WORKTREE_PATH"
      assert scripts.windows =~ "vendor"
    end

    test "none entry returns a no-op unix script" do
      scripts = WorktreeInitScript.scripts_for(:none)

      assert scripts.unix =~ ~r/No build artifacts to copy/
    end

    test "none entry returns a no-op windows script" do
      scripts = WorktreeInitScript.scripts_for(:none)

      assert scripts.windows =~ ~r/No build artifacts to copy/
    end
  end
end
