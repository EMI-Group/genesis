defmodule Mix.Tasks.Bump.Version do
  @moduledoc """
  Bump the project version and propagate it to every file that carries a
  version string.

  The single source of truth is the root `VERSION` file. This task updates it
  and then synchronizes every downstream file that embeds the version:

    * `desktop/src-tauri/tauri.conf.json`  (Tauri app manifest)
    * `desktop/src-tauri/Cargo.toml`       (Rust package metadata)
    * `desktop/src-tauri/Cargo.lock`       (Rust lockfile, if present)

  The three umbrella `mix.exs` files do **not** need editing — they read the
  version dynamically from `VERSION`, so they pick up the new value on the next
  compile.

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

  @impl Mix.Task
  def run([]) do
    current = current_version()
    Mix.shell().error("No version specified. Current version is #{current}.")
    Mix.shell().error("\nUsage: mix bump.version <new-version>")
    Mix.raise("missing version argument")
  end

  def run([version | _rest]) do
    validate!(version)
    current = current_version()

    if version == current do
      Mix.shell().info("Version is already #{version} — nothing to do.")
    else
      Mix.shell().info("Bumping version: #{current} → #{version}")
      write_version_file(version)
      sync_tauri(version)
      sync_cargo(version)
      Mix.shell().info("✓ Version bumped to #{version}")
      print_summary(version)
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

  defp current_version do
    @version_file
    |> File.read!()
    |> String.trim()
  end

  defp write_version_file(version) do
    File.write!(@version_file, "#{version}\n")
    Mix.shell().info("  ✓ #{@version_file}")
  end

  # --- Tauri manifest -----------------------------------------------------

  defp sync_tauri(version) do
    if File.exists?(@tauri_conf) do
      contents = File.read!(@tauri_conf)

      updated =
        Regex.replace(
          ~r/^(\s*"version"\s*:\s*")[^"]+(")/m,
          contents,
          "\\1#{version}\\2"
        )

      File.write!(@tauri_conf, updated)
      Mix.shell().info("  ✓ #{@tauri_conf}")
    end
  end

  # --- Cargo manifest + lockfile ------------------------------------------

  defp sync_cargo(version) do
    if File.exists?(@cargo_toml) do
      contents = File.read!(@cargo_toml)

      updated =
        Regex.replace(
          ~r/^(version\s*=\s*")[^"]+(")/m,
          contents,
          "\\1#{version}\\2"
        )

      File.write!(@cargo_toml, updated)
      Mix.shell().info("  ✓ #{@cargo_toml}")

      # The lockfile mirrors the package version. Update it in place so the
      # bump doesn't require a `cargo build` to stay consistent. We only touch
      # the evogit-desktop entry, leaving all dependency entries untouched.
      sync_cargo_lock(version)
    end
  end

  defp sync_cargo_lock(version) do
    if File.exists?(@cargo_lock) do
      contents = File.read!(@cargo_lock)

      updated =
        contents
        # Match the evogit-desktop package block and replace its version line.
        |> String.replace(
          ~r/(\[\[package\]\]\nname = "evogit-desktop"\nversion = ")[^"]+(")/,
          "\\1#{version}\\2"
        )

      File.write!(@cargo_lock, updated)
      Mix.shell().info("  ✓ #{@cargo_lock}")
    end
  end

  # --- Summary ------------------------------------------------------------

  defp print_summary(version) do
    Mix.shell().info("""

    Done. Files updated. The umbrella mix.exs files read VERSION dynamically and
    need no edits.

    Next steps:
      1. Run `mix compile` to confirm everything builds with version #{version}.
      2. If building the desktop app, run `cargo build` to refresh Cargo.lock.
      3. Commit the changes: git add -A && git commit -m "Bump version to #{version}"
      4. Tag the release: git tag v#{version}
    """)
  end
end
