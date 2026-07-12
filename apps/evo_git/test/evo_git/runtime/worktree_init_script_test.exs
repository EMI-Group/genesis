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
        assert Map.has_key?(bs, :linux_script)
        assert Map.has_key?(bs, :macos_script)
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
    test "returns linux, macos, and windows scripts for a build system map" do
      bs = WorktreeInitScript.get_build_system(:elixir)
      scripts = WorktreeInitScript.scripts_for(bs)

      assert Map.has_key?(scripts, :linux)
      assert Map.has_key?(scripts, :macos)
      assert Map.has_key?(scripts, :windows)
      assert is_binary(scripts.linux)
      assert is_binary(scripts.macos)
      assert is_binary(scripts.windows)
    end

    test "returns linux, macos, and windows scripts for an atom id" do
      scripts = WorktreeInitScript.scripts_for(:elixir)

      assert Map.has_key?(scripts, :linux)
      assert Map.has_key?(scripts, :macos)
      assert Map.has_key?(scripts, :windows)
    end

    test "returns nil for unknown atom id" do
      assert WorktreeInitScript.scripts_for(:unknown) == nil
    end

    test "elixir linux script has bash shebang and copies deps and _build" do
      scripts = WorktreeInitScript.scripts_for(:elixir)

      assert String.starts_with?(scripts.linux, "#!/usr/bin/env bash")
      assert scripts.linux =~ "deps"
      assert scripts.linux =~ "_build"
      assert scripts.linux =~ "$SOURCE_REPO_PATH"
      assert scripts.linux =~ "$TARGET_WORKTREE_PATH"
    end

    test "elixir linux script uses GNU cp reflink" do
      scripts = WorktreeInitScript.scripts_for(:elixir)

      assert scripts.linux =~ ~r/cp -R --reflink=auto/
    end

    test "elixir macos script has bash shebang and copies deps and _build" do
      scripts = WorktreeInitScript.scripts_for(:elixir)

      assert String.starts_with?(scripts.macos, "#!/usr/bin/env bash")
      assert scripts.macos =~ "deps"
      assert scripts.macos =~ "_build"
      assert scripts.macos =~ "$SOURCE_REPO_PATH"
      assert scripts.macos =~ "$TARGET_WORKTREE_PATH"
    end

    test "elixir macos script uses BSD cp clonefile" do
      scripts = WorktreeInitScript.scripts_for(:elixir)

      assert scripts.macos =~ ~r/cp -cR/
    end

    test "elixir windows script uses PowerShell syntax" do
      scripts = WorktreeInitScript.scripts_for(:elixir)

      assert scripts.windows =~ "$env:SOURCE_REPO_PATH"
      assert scripts.windows =~ "$env:TARGET_WORKTREE_PATH"
      assert scripts.windows =~ "deps"
      assert scripts.windows =~ "_build"
    end

    test "node linux script has bash shebang and copies node_modules" do
      scripts = WorktreeInitScript.scripts_for(:node)

      assert String.starts_with?(scripts.linux, "#!/usr/bin/env bash")
      assert scripts.linux =~ "node_modules"
      assert scripts.linux =~ "$SOURCE_REPO_PATH"
      assert scripts.linux =~ "$TARGET_WORKTREE_PATH"
    end

    test "node linux script uses GNU cp reflink" do
      scripts = WorktreeInitScript.scripts_for(:node)

      assert scripts.linux =~ ~r/cp -R --reflink=auto/
    end

    test "node macos script has bash shebang and copies node_modules" do
      scripts = WorktreeInitScript.scripts_for(:node)

      assert String.starts_with?(scripts.macos, "#!/usr/bin/env bash")
      assert scripts.macos =~ "node_modules"
      assert scripts.macos =~ "$SOURCE_REPO_PATH"
      assert scripts.macos =~ "$TARGET_WORKTREE_PATH"
    end

    test "node macos script uses BSD cp clonefile" do
      scripts = WorktreeInitScript.scripts_for(:node)

      assert scripts.macos =~ ~r/cp -cR/
    end

    test "node windows script uses PowerShell syntax" do
      scripts = WorktreeInitScript.scripts_for(:node)

      assert scripts.windows =~ "$env:SOURCE_REPO_PATH"
      assert scripts.windows =~ "$env:TARGET_WORKTREE_PATH"
      assert scripts.windows =~ "node_modules"
    end

    test "python linux script has bash shebang and copies .venv" do
      scripts = WorktreeInitScript.scripts_for(:python)

      assert String.starts_with?(scripts.linux, "#!/usr/bin/env bash")
      assert scripts.linux =~ ".venv"
      assert scripts.linux =~ "$SOURCE_REPO_PATH"
      assert scripts.linux =~ "$TARGET_WORKTREE_PATH"
    end

    test "python linux script uses GNU cp reflink" do
      scripts = WorktreeInitScript.scripts_for(:python)

      assert scripts.linux =~ ~r/cp -R --reflink=auto/
    end

    test "python macos script has bash shebang and copies .venv" do
      scripts = WorktreeInitScript.scripts_for(:python)

      assert String.starts_with?(scripts.macos, "#!/usr/bin/env bash")
      assert scripts.macos =~ ".venv"
      assert scripts.macos =~ "$SOURCE_REPO_PATH"
      assert scripts.macos =~ "$TARGET_WORKTREE_PATH"
    end

    test "python macos script uses BSD cp clonefile" do
      scripts = WorktreeInitScript.scripts_for(:python)

      assert scripts.macos =~ ~r/cp -cR/
    end

    test "python windows script uses PowerShell syntax" do
      scripts = WorktreeInitScript.scripts_for(:python)

      assert scripts.windows =~ "$env:SOURCE_REPO_PATH"
      assert scripts.windows =~ "$env:TARGET_WORKTREE_PATH"
      assert scripts.windows =~ ".venv"
    end

    test "rust linux script has bash shebang and copies target" do
      scripts = WorktreeInitScript.scripts_for(:rust)

      assert String.starts_with?(scripts.linux, "#!/usr/bin/env bash")
      assert scripts.linux =~ "target"
      assert scripts.linux =~ "$SOURCE_REPO_PATH"
      assert scripts.linux =~ "$TARGET_WORKTREE_PATH"
    end

    test "rust linux script uses GNU cp reflink" do
      scripts = WorktreeInitScript.scripts_for(:rust)

      assert scripts.linux =~ ~r/cp -R --reflink=auto/
    end

    test "rust macos script has bash shebang and copies target" do
      scripts = WorktreeInitScript.scripts_for(:rust)

      assert String.starts_with?(scripts.macos, "#!/usr/bin/env bash")
      assert scripts.macos =~ "target"
      assert scripts.macos =~ "$SOURCE_REPO_PATH"
      assert scripts.macos =~ "$TARGET_WORKTREE_PATH"
    end

    test "rust macos script uses BSD cp clonefile" do
      scripts = WorktreeInitScript.scripts_for(:rust)

      assert scripts.macos =~ ~r/cp -cR/
    end

    test "rust windows script uses PowerShell syntax" do
      scripts = WorktreeInitScript.scripts_for(:rust)

      assert scripts.windows =~ "$env:SOURCE_REPO_PATH"
      assert scripts.windows =~ "$env:TARGET_WORKTREE_PATH"
      assert scripts.windows =~ "target"
    end

    test "go linux script has bash shebang and copies vendor" do
      scripts = WorktreeInitScript.scripts_for(:go)

      assert String.starts_with?(scripts.linux, "#!/usr/bin/env bash")
      assert scripts.linux =~ "vendor"
      assert scripts.linux =~ "$SOURCE_REPO_PATH"
      assert scripts.linux =~ "$TARGET_WORKTREE_PATH"
    end

    test "go linux script uses GNU cp reflink" do
      scripts = WorktreeInitScript.scripts_for(:go)

      assert scripts.linux =~ ~r/cp -R --reflink=auto/
    end

    test "go macos script has bash shebang and copies vendor" do
      scripts = WorktreeInitScript.scripts_for(:go)

      assert String.starts_with?(scripts.macos, "#!/usr/bin/env bash")
      assert scripts.macos =~ "vendor"
      assert scripts.macos =~ "$SOURCE_REPO_PATH"
      assert scripts.macos =~ "$TARGET_WORKTREE_PATH"
    end

    test "go macos script uses BSD cp clonefile" do
      scripts = WorktreeInitScript.scripts_for(:go)

      assert scripts.macos =~ ~r/cp -cR/
    end

    test "go windows script uses PowerShell syntax" do
      scripts = WorktreeInitScript.scripts_for(:go)

      assert scripts.windows =~ "$env:SOURCE_REPO_PATH"
      assert scripts.windows =~ "$env:TARGET_WORKTREE_PATH"
      assert scripts.windows =~ "vendor"
    end

    test "none entry returns a no-op linux script" do
      scripts = WorktreeInitScript.scripts_for(:none)

      assert scripts.linux =~ ~r/No build artifacts to copy/
    end

    test "none entry returns a no-op macos script" do
      scripts = WorktreeInitScript.scripts_for(:none)

      assert scripts.macos =~ ~r/No build artifacts to copy/
    end

    test "none entry returns a no-op windows script" do
      scripts = WorktreeInitScript.scripts_for(:none)

      assert scripts.windows =~ ~r/No build artifacts to copy/
    end
  end
end
