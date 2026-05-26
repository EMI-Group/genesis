defmodule ServerSentEvents.MixProject do
  use Mix.Project

  @version "1.0.0"

  @github_repo_url "https://github.com/benjreinhart/server_sent_events"

  @description "Lightweight, ultra-fast Server Sent Event parser"

  def project do
    [
      app: :server_sent_events,
      version: @version,
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      name: "Server Sent Events",
      description: @description,
      source_url: @github_repo_url,
      homepage_url: @github_repo_url,
      package: package(),
      deps: deps(),
      docs: docs(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [bench: :dev]
    ]
  end

  def description do
    @description
  end

  defp package do
    [
      maintainers: ["Ben Reinhart"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @github_repo_url
      }
    ]
  end

  defp deps do
    [
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      bench: "run bench/parse_bench.exs"
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @github_repo_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/usage.livemd"
      ],
      groups_for_extras: [Guides: ~r/^guides/]
    ]
  end
end
