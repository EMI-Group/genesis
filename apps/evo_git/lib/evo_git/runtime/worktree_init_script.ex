defmodule EvoGit.Runtime.WorktreeInitScript do
  @moduledoc """
  Predefined catalog of Worktree Init Scripts for common build systems.

  Each script runs immediately after a new git worktree is created, copying
  dependencies and build artifacts from the source repository into the new
  worktree so builds start with a warm cache (avoiding re-download/recompile).

  The selected scripts are written into `genesis.toml` under `[worktree]` as
  OS-specific variants (`script.linux`, `script.macos`, `script.windows`) so the
  existing per-worktree init-script infrastructure
  (`EvoGit.ProjectConfig.worktree_script/2` →
  `EvoGit.AgentScheduler.Worktrees.run_init_script/3`) picks them up.

  ## Platform Variants

  Three platform-specific scripts are provided per build system:

    - **Linux** — uses GNU `cp -R --reflink=auto` (copy-on-write: fast on
      btrfs/xfs, falls back to a full copy otherwise).
    - **macOS** — uses BSD `cp -cR` (`-c` = `clonefile`, APFS copy-on-write).
    - **Windows** — uses PowerShell `Copy-Item -Recurse -Force`.

  ## Environment Variables

  All scripts receive three environment variables:

    - `SOURCE_REPO_PATH` — the main repository checkout where `genesis.toml` lives.
    - `SOURCE_WORKTREE_PATH` — the parent agent's worktree path.
    - `TARGET_WORKTREE_PATH` — the newly created worktree (copy destination).
  """

  @build_systems [
    %{
      id: :elixir,
      name: "Elixir / Erlang (Mix)",
      dirs: ["deps", "_build"],
      linux_script: """
      #!/bin/bash
      # Copy Elixir dependencies and build artifacts
      if [ -d "$SOURCE_REPO_PATH/deps" ]; then
        cp -R --reflink=auto "$SOURCE_REPO_PATH/deps" "$TARGET_WORKTREE_PATH/"
      fi
      if [ -d "$SOURCE_REPO_PATH/_build" ]; then
        cp -R --reflink=auto "$SOURCE_REPO_PATH/_build" "$TARGET_WORKTREE_PATH/"
      fi
      """,
      macos_script: """
      #!/bin/bash
      # Copy Elixir dependencies and build artifacts
      if [ -d "$SOURCE_REPO_PATH/deps" ]; then
        cp -cR "$SOURCE_REPO_PATH/deps" "$TARGET_WORKTREE_PATH/"
      fi
      if [ -d "$SOURCE_REPO_PATH/_build" ]; then
        cp -cR "$SOURCE_REPO_PATH/_build" "$TARGET_WORKTREE_PATH/"
      fi
      """,
      windows_script: """
      # Copy Elixir dependencies and build artifacts
      if (Test-Path "$env:SOURCE_REPO_PATH/deps") {
          Copy-Item -Recurse -Force "$env:SOURCE_REPO_PATH/deps" "$env:TARGET_WORKTREE_PATH/"
      }
      if (Test-Path "$env:SOURCE_REPO_PATH/_build") {
          Copy-Item -Recurse -Force "$env:SOURCE_REPO_PATH/_build" "$env:TARGET_WORKTREE_PATH/"
      }
      """
    },
    %{
      id: :node,
      name: "Node.js (npm/yarn)",
      dirs: ["node_modules"],
      linux_script: """
      #!/bin/bash
      # Copy Node.js dependencies
      if [ -d "$SOURCE_REPO_PATH/node_modules" ]; then
        cp -R --reflink=auto "$SOURCE_REPO_PATH/node_modules" "$TARGET_WORKTREE_PATH/"
      fi
      """,
      macos_script: """
      #!/bin/bash
      # Copy Node.js dependencies
      if [ -d "$SOURCE_REPO_PATH/node_modules" ]; then
        cp -cR "$SOURCE_REPO_PATH/node_modules" "$TARGET_WORKTREE_PATH/"
      fi
      """,
      windows_script: """
      # Copy Node.js dependencies
      if (Test-Path "$env:SOURCE_REPO_PATH/node_modules") {
          Copy-Item -Recurse -Force "$env:SOURCE_REPO_PATH/node_modules" "$env:TARGET_WORKTREE_PATH/"
      }
      """
    },
    %{
      id: :python,
      name: "Python (venv)",
      dirs: [".venv"],
      linux_script: """
      #!/bin/bash
      # Copy Python virtual environment
      if [ -d "$SOURCE_REPO_PATH/.venv" ]; then
        cp -R --reflink=auto "$SOURCE_REPO_PATH/.venv" "$TARGET_WORKTREE_PATH/"
      fi
      """,
      macos_script: """
      #!/bin/bash
      # Copy Python virtual environment
      if [ -d "$SOURCE_REPO_PATH/.venv" ]; then
        cp -cR "$SOURCE_REPO_PATH/.venv" "$TARGET_WORKTREE_PATH/"
      fi
      """,
      windows_script: """
      # Copy Python virtual environment
      if (Test-Path "$env:SOURCE_REPO_PATH/.venv") {
          Copy-Item -Recurse -Force "$env:SOURCE_REPO_PATH/.venv" "$env:TARGET_WORKTREE_PATH/"
      }
      """
    },
    %{
      id: :rust,
      name: "Rust (Cargo)",
      dirs: ["target"],
      linux_script: """
      #!/bin/bash
      # Copy Rust build artifacts
      if [ -d "$SOURCE_REPO_PATH/target" ]; then
        cp -R --reflink=auto "$SOURCE_REPO_PATH/target" "$TARGET_WORKTREE_PATH/"
      fi
      """,
      macos_script: """
      #!/bin/bash
      # Copy Rust build artifacts
      if [ -d "$SOURCE_REPO_PATH/target" ]; then
        cp -cR "$SOURCE_REPO_PATH/target" "$TARGET_WORKTREE_PATH/"
      fi
      """,
      windows_script: """
      # Copy Rust build artifacts
      if (Test-Path "$env:SOURCE_REPO_PATH/target") {
          Copy-Item -Recurse -Force "$env:SOURCE_REPO_PATH/target" "$env:TARGET_WORKTREE_PATH/"
      }
      """
    },
    %{
      id: :go,
      name: "Go (modules)",
      dirs: ["vendor"],
      linux_script: """
      #!/bin/bash
      # Copy Go vendored dependencies
      if [ -d "$SOURCE_REPO_PATH/vendor" ]; then
        cp -R --reflink=auto "$SOURCE_REPO_PATH/vendor" "$TARGET_WORKTREE_PATH/"
      fi
      """,
      macos_script: """
      #!/bin/bash
      # Copy Go vendored dependencies
      if [ -d "$SOURCE_REPO_PATH/vendor" ]; then
        cp -cR "$SOURCE_REPO_PATH/vendor" "$TARGET_WORKTREE_PATH/"
      fi
      """,
      windows_script: """
      # Copy Go vendored dependencies
      if (Test-Path "$env:SOURCE_REPO_PATH/vendor") {
          Copy-Item -Recurse -Force "$env:SOURCE_REPO_PATH/vendor" "$env:TARGET_WORKTREE_PATH/"
      }
      """
    },
    %{
      id: :none,
      name: "None / Generic",
      dirs: [],
      linux_script: "# No build artifacts to copy\n",
      macos_script: "# No build artifacts to copy\n",
      windows_script: "# No build artifacts to copy\n"
    }
  ]

  @doc """
  Returns the list of build system maps.

  Each map contains:
    - `:id` — atom identifier (`:elixir`, `:node`, `:python`, `:rust`, `:go`, `:none`)
    - `:name` — display name for CLI menus
    - `:dirs` — list of directories the script copies
    - `:linux_script` — shell script for Linux (GNU `cp --reflink=auto`)
    - `:macos_script` — shell script for macOS (BSD `cp -c`)
    - `:windows_script` — PowerShell script for Windows
  """
  @spec build_systems() :: [map()]
  def build_systems, do: @build_systems

  @doc """
  Returns the build system map for the given atom id, or `nil` if not found.
  """
  @spec get_build_system(atom()) :: map() | nil
  def get_build_system(id) when is_atom(id) do
    Enum.find(@build_systems, fn bs -> bs.id == id end)
  end

  @doc """
  Returns the linux, macos, and windows scripts for the given build system.

  Accepts either a build system map or an atom id.

  Returns `%{linux: script_string, macos: script_string, windows: script_string}`.
  """
  @spec scripts_for(atom() | map()) ::
          %{linux: String.t(), macos: String.t(), windows: String.t()} | nil
  def scripts_for(%{linux_script: linux, macos_script: macos, windows_script: windows}) do
    %{linux: linux, macos: macos, windows: windows}
  end

  def scripts_for(id) when is_atom(id) do
    case get_build_system(id) do
      nil -> nil
      bs -> scripts_for(bs)
    end
  end
end
