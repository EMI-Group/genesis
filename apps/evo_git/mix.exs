defmodule EvoGit.MixProject do
  use Mix.Project

  def project do
    [
      app: :evo_git,
      version: version(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EvoGit.Application, []}
    ]
  end

  defp deps do
    [
      {:req_llm, "~> 1.17.0"},
      {:retry, "~> 0.19"},
      {:req, "~> 0.6.0"},
      {:phoenix_pubsub, "~> 2.2"},
      # TomlElixir
      {:toml_elixir, "~> 3.1"},
      {:yaml_elixir, "~> 2.11"}
    ]
  end

  # Read the version from the root VERSION file so all umbrella apps and the
  # Tauri desktop shell share a single source of truth.
  @version_file Path.expand("../../VERSION", __DIR__)

  defp version do
    @version_file
    |> File.read!()
    |> String.trim()
  end
end
