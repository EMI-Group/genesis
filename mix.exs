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
        ]
      ]
    ]
  end

  defp deps do
    []
  end
end
