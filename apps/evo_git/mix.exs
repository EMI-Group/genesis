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
      elixirc_paths: elixirc_paths(Mix.env()),
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
      {:req_llm, git: "https://github.com/agentjido/req_llm.git", branch: "main"},
      {:retry, "~> 0.19"},
      {:req, "~> 0.6.0"},
      {:phoenix_pubsub, "~> 2.2"},
      # TomlElixir
      {:toml_elixir, "~> 3.1"},
      {:yaml_elixir, "~> 2.11"},
      {:xqlite, "~> 0.10"},
      # Needed only when building the xqlite NIF from source (XQLITE_BUILD=1),
      # e.g. on Windows machines where app-control policy blocks the
      # precompiled NIF DLL.
      {:rustler, "~> 0.38.0", optional: true},
      {:jason, "~> 1.2"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Read the version from the root VERSION file so all umbrella apps and the
  # Tauri desktop shell share a single source of truth.
  @version_file Path.expand("../../VERSION", __DIR__)

  defp version do
    @version_file
    |> File.read!()
    |> String.trim()
  end
end
