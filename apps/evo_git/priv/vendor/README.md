# priv/vendor/

Platform-specific git and ripgrep binaries are placed here by CI during release builds.

Directory layout:
- `macos-arm64/` - Apple Silicon (M1/M2/M3)
- `macos-x86_64/` - Intel Mac
- `windows-x64/` - Windows x86_64

On Windows, MinGit is extracted to `windows-x64/mingit/` with the git
executable at `mingit/cmd/git.exe`. The resolver handles this automatically.

At runtime, `EvoGit.Executable.resolve/1` searches the system PATH first.
If the binary is not found on PATH, it falls back to the appropriate bundled
version in this directory.
