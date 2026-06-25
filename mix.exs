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
        evogit: [
          applications: [
            evo_git: :permanent,
            evo_dash: :permanent
          ]
        ],
        evogit_desktop: [
          applications: [
            evo_git: :permanent,
            evo_dash: :permanent
          ],
          # Bake a compile-time desktop flag into sys.config so that the
          # backend reliably detects desktop mode even if the Burrito Zig
          # wrapper does not forward the EVOGIT_DESKTOP env var to the VM.
          config: [evo_dash: [desktop_release: true]],
          steps: [:assemble, &Burrito.wrap/1],
          burrito: [
            targets: [
              darwin_arm64: [os: :darwin, cpu: :aarch64],
              darwin_amd64: [os: :darwin, cpu: :x86_64],
              windows_x64: [os: :windows, cpu: :x86_64],
              linux_x64: [os: :linux, cpu: :x86_64],
              linux_arm64: [os: :linux, cpu: :aarch64]
            ]
          ]
        ]
      ]
    ]
  end

  defp deps do
    [
      {:burrito, "~> 1.0"}
    ]
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
