defmodule Mix.Tasks.Bump.Version do
  @moduledoc """
  Bump the project version and propagate it to every file that carries a
  version string.

  The single source of truth is the root `VERSION` file. This task updates it
  and then synchronizes every downstream file that embeds the version:

    * `desktop/src-tauri/tauri.conf.json`  (Tauri app manifest)
    * `desktop/src-tauri/Cargo.toml`       (Rust package metadata)
    * `desktop/src-tauri/Cargo.lock`       (Rust lockfile, if present)
    * `README.md`                          (shields.io version badge)

  The three umbrella `mix.exs` files do **not** need editing — they read the
  version dynamically from `VERSION`, so they pick up the new value on the next
  compile.

  After a successful bump the task interactively asks whether to commit the
  updated files. If confirmed, only the touched files are staged and committed
  (never `git add -A`). If declined, or if git fails (not a git repository,
  missing identity, ...), the bump itself still succeeded and the manual
  commit command is printed.

  Finally, the task asks whether to generate a changelog section for the new
  version (delegating to `mix changelog`). Declining skips changelog
  generation entirely; accepting summarizes the commits since the last tag
  with an LLM and updates `CHANGELOG.md`.

  ## Usage

      mix bump.version 0.2.0

  ## Examples

      # Bump to a specific version
      mix bump.version 1.0.0

      # Pre-release
      mix bump.version 2.0.0-rc.1

  The task validates the new version against a semver-style pattern before
  touching any files, so a typo (e.g. forgetting the number) fails loudly with
  no changes made.
  """

  use Mix.Task

  @shortdoc "Bump the project version across all files"

  # Files that embed the version as a literal string. Each entry is
  # {relative_path, {kind, key}} describing how the version appears.
  @version_file "VERSION"
  @tauri_conf "desktop/src-tauri/tauri.conf.json"
  @cargo_toml "desktop/src-tauri/Cargo.toml"
  @cargo_lock "desktop/src-tauri/Cargo.lock"
  @readme "README.md"

  @impl Mix.Task
  def run(args) do
    # Keyword-tuple entries (`root: path`, `shell: shell`, changelog seam
    # overrides) are extracted BEFORE any parsing — CLI argv is always plain
    # strings, so this pre-split is a no-op on the CLI path and keeps run/1's
    # public contract unchanged. An injected `root` anchors every file and git
    # operation instead of the process-wide CWD (`File.cd!`); an injected
    # `shell` replaces the VM-global `Mix.shell/1` swap.
    {injected, cli_args} = Enum.split_with(args, &match?({k, _} when is_atom(k), &1))
    opts = injected
    root = opts[:root] || File.cwd!()

    case cli_args do
      [] ->
        current = current_version(root)
        shell(opts).error("No version specified. Current version is #{current}.")
        shell(opts).error("\nUsage: mix bump.version <new-version>")
        Mix.raise("missing version argument")

      [version | _rest] ->
        validate!(version)
        current = current_version(root)

        if version == current do
          shell(opts).info("Version is already #{version} — nothing to do.")
        else
          shell(opts).info("Bumping version: #{current} → #{version}")

          touched_files =
            write_version_file(version, root, opts) ++
              sync_tauri(version, root, opts) ++
              sync_cargo(version, root, opts) ++
              sync_readme(version, root, opts)

          shell(opts).info("✓ Version bumped to #{version}")
          print_summary(version, opts)
          maybe_commit(touched_files, version, root, opts)
          maybe_generate_changelog(version, root, opts)
        end
    end
  end

  # --- Validation ---------------------------------------------------------

  defp validate!(version) do
    unless Regex.match?(~r/^\d+\.\d+\.\d+(?:[-+].+)?$/, version) do
      Mix.raise("""
      Invalid version: #{inspect(version)}

      Expected a semver-style version such as:
        1.0.0
        0.2.1
        2.0.0-rc.1
      """)
    end
  end

  # --- VERSION file -------------------------------------------------------

  defp current_version(root) do
    root
    |> Path.join(@version_file)
    |> File.read!()
    |> String.trim()
  end

  defp write_version_file(version, root, opts) do
    File.write!(Path.join(root, @version_file), "#{version}\n")
    shell(opts).info("  ✓ #{@version_file}")
    [@version_file]
  end

  # --- Tauri manifest -----------------------------------------------------

  defp sync_tauri(version, root, opts) do
    sync_file(
      @tauri_conf,
      ~r/^(\s*"version"\s*:\s*")[^"]+(")/m,
      fn _, prefix, suffix -> prefix <> version <> suffix end,
      root,
      opts
    )
  end

  # --- Cargo manifest + lockfile ------------------------------------------

  defp sync_cargo(version, root, opts) do
    case sync_file(
           @cargo_toml,
           ~r/^(version\s*=\s*")[^"]+(")/m,
           fn _, prefix, suffix -> prefix <> version <> suffix end,
           root,
           opts
         ) do
      # The lockfile mirrors the package version. Update it in place so the
      # bump doesn't require a `cargo build` to stay consistent. We only touch
      # the genesis-desktop entry, leaving all dependency entries untouched.
      [] -> []
      [path] -> [path | sync_cargo_lock(version, root, opts)]
    end
  end

  defp sync_cargo_lock(version, root, opts) do
    sync_file(
      @cargo_lock,
      ~r/(\[\[package\]\]\nname = "genesis-desktop"\nversion = ")[^"]+(")/,
      fn _, prefix, suffix -> prefix <> version <> suffix end,
      root,
      opts
    )
  end

  # --- README badge -------------------------------------------------------

  defp sync_readme(version, root, opts) do
    # shields.io badge URLs use `--` to escape dashes in the version
    # portion (e.g. 2.0.0-rc.1  →  version-2.0.0--rc.1-8b5cf6).
    escaped = String.replace(version, "-", "--")

    sync_file(
      @readme,
      ~r/(version-)(.+)(-8b5cf6)/,
      fn _, prefix, _old, suffix -> prefix <> escaped <> suffix end,
      root,
      opts
    )
  end

  # Shared sync: reads the file (resolved under `root`), rewrites the version
  # via the function form of Regex.replace — which avoids the classic
  # backreference-followed-by-digit pitfall: a replacement like "\\10.9.9\\2"
  # is parsed as backreference #10 (which does not exist → empty string)
  # instead of "\\1" followed by the literal "0.9.9", which corrupts the file
  # (e.g. `"version": "0.9.9"` becomes `.9.9`). The function form inserts the
  # value verbatim with no interpolation. Returns `[path]` (the relative path,
  # for the git add / manual-commit output) when the file exists, `[]` when it
  # does not.
  defp sync_file(path, regex, replace_fun, root, opts) do
    full = Path.join(root, path)

    if File.exists?(full) do
      contents = File.read!(full)
      updated = Regex.replace(regex, contents, replace_fun)
      File.write!(full, updated)
      shell(opts).info("  ✓ #{path}")
      [path]
    else
      []
    end
  end

  # --- Interactive commit -------------------------------------------------

  # Asks whether to commit the bumped files. Only ever stages the files that
  # were actually touched — never `git add -A`.
  defp maybe_commit(files, version, root, opts) do
    if shell(opts).yes?("Commit the version bump files now? [Yn]") do
      do_commit(files, version, root, opts)
    else
      print_manual_commit(files, version, opts)
    end
  end

  defp do_commit(files, version, root, opts) do
    case git(["add", "--" | files], root) do
      {:ok, _output} ->
        case git(["diff", "--cached", "--quiet"], root) do
          # Exit 0: nothing is staged (e.g. the content was already committed).
          {:ok, _output} ->
            shell(opts).info("No changes to commit")

          # Exit 1: staged changes exist — proceed with the commit.
          {:error, 1, _output} ->
            commit(files, version, root, opts)

          {:error, _code, output} ->
            warn_git_failure("git diff --cached --quiet", output, opts)
            print_manual_commit(files, version, opts)
        end

      {:error, _code, output} ->
        warn_git_failure("git add", output, opts)
        print_manual_commit(files, version, opts)
    end
  end

  defp commit(files, version, root, opts) do
    case git(["commit", "-m", "Bump version to #{version}"], root) do
      {:ok, output} ->
        shell(opts).info(String.trim(output))

        # A concise one-line summary of the new commit.
        case git(["log", "-1", "--oneline"], root) do
          {:ok, log} -> shell(opts).info(String.trim(log))
          {:error, _code, _output} -> :ok
        end

      {:error, _code, output} ->
        warn_git_failure("git commit", output, opts)
        print_manual_commit(files, version, opts)
    end
  end

  # Runs git anchored at `root`, capturing stderr into the output so failures
  # can be reported verbatim. Returns {:ok, output} or {:error, code, output}.
  # When `root` is the process CWD (the CLI default) this is identical to
  # running git with no `cd:`.
  defp git(args, root) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, code, output}
    end
  end

  defp warn_git_failure(step, output, opts) do
    shell(opts).error("⚠ #{step} failed (the version bump itself succeeded):")
    shell(opts).error(String.trim(output))
  end

  defp print_manual_commit(files, version, opts) do
    shell(opts).info("""
    Commit the bumped files manually:
      git add #{Enum.join(files, " ")} && git commit -m "Bump version to #{version}"
    """)
  end

  # --- Changelog generation ------------------------------------------------

  # Asks whether to generate an AI-powered changelog section for the new
  # version and, on yes, delegates to the changelog task. The changelog module
  # is invoked DIRECTLY (Mix.Tasks.Changelog.run/1) rather than via
  # Mix.Task.run("changelog", ...) because Mix.Task.run/2 refuses to re-run a
  # task already run in the current Mix invocation ("has already been run"
  # no-op) — a direct call lets tests trigger generation more than once.
  #
  # The nested call forwards `root` and `shell` (so it too runs without
  # VM-global CWD/shell state) plus any per-call summarizer seam overrides
  # present in `opts`; when none are present the changelog task falls back to
  # its `:changelog_*` application-env seams as before.
  defp maybe_generate_changelog(version, root, opts) do
    if shell(opts).yes?("Generate changelog for v#{version} now? [Yn]") do
      seams =
        Keyword.take(opts, [
          :changelog_summarizer,
          :changelog_pr_summarizer,
          :changelog_aggregator
        ])

      Mix.Tasks.Changelog.run([version, root: root, shell: shell(opts)] ++ seams)
    end
  end

  # --- Summary ------------------------------------------------------------

  defp print_summary(version, opts) do
    shell(opts).info("""

    Done. Files updated. The umbrella mix.exs files read VERSION dynamically and
    need no edits.

    Next steps:
      1. Run `mix compile` to confirm everything builds with version #{version}.
      2. If building the desktop app, run `cargo build` to refresh Cargo.lock.
      3. The task now asks whether to commit the bumped files. If you skip it,
         stage only the version files and commit them manually:
         git add VERSION desktop/src-tauri/tauri.conf.json desktop/src-tauri/Cargo.toml
           desktop/src-tauri/Cargo.lock README.md
         git commit -m "Bump version to #{version}"
      4. Tag the release: git tag v#{version}
    """)
  end

  # Call-time-resolved Mix shell: a per-call `opts[:shell]` override wins over
  # the `:mix_shell` application env, defaulting to the real `Mix.shell()`.
  # `Mix.shell/1` writes a VM-global ETS table, so an injected shell is what
  # lets concurrent (async) suites avoid swapping the global shell.
  defp shell(opts) do
    opts[:shell] || Application.get_env(:evo_git, :mix_shell, Mix.shell())
  end
end
