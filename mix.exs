defmodule EvoGit.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
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
end
