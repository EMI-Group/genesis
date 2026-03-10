defmodule EvoGit.MixProject do
  use Mix.Project

  def project do
    [
      app: :evo_git,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {EvoGit.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req_llm, "~> 1.6"}
    ]
  end
end
