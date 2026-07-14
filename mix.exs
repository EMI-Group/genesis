defmodule EvoGit.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: version(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      releases: [
        genesis: [
          applications: [
            evo_git: :permanent,
            evo_dash: :permanent
          ]
        ],
        genesis_desktop: [
          applications: [
            evo_git: :permanent,
            evo_dash: :permanent
          ],
          # Bake a compile-time desktop flag into sys.config so that the
          # backend reliably detects desktop mode at runtime.
          config: [evo_dash: [desktop_release: true]]
        ],
        genesis_remote: [
          # Headless evo_git-only release for SSH remote development. It runs as
          # a lightweight daemon on a remote server (no Phoenix/Tauri dashboard).
          applications: [
            evo_git: :permanent
          ],
          # Bake a compile-time flag into sys.config so the runtime can detect
          # that it is running as a remote daemon.
          config: [evo_git: [remote_release: true]]
        ]
      ]
    ]
  end

  defp deps do
    []
  end

  # Single source of truth for the project version. All mix.exs files in this
  # umbrella read from the root VERSION file so the version only needs to be
  # bumped in one place (run `mix bump.version <new-version>` to propagate it
  # everywhere, including the Tauri/Cargo desktop manifests).
  @version_file Path.expand("VERSION", __DIR__)

  defp version do
    @version_file
    |> File.read!()
    |> String.trim()
  end
end
