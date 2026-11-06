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
      {:req_llm, "~> 1.30"},
      {:dune, "~> 0.3.18"},
      # Security floor for the transitive jsv dependency: pin the patched
      # release explicitly (EEF-CVE-2026-117680 / CVE-2026-117680). req_llm
      # 1.30 itself requires ">= 0.26.2 and < 1.0.0-0"; this range keeps the
      # floor visible without narrowing resolution below req_llm's own
      # constraint.
      {:jsv, ">= 0.26.2 and < 1.0.0"},
      # llm_db is the pricing/model catalog; declared explicitly because
      # EvoGit reads pricing from it directly (it was previously
      # transitive-only via req_llm). Range mirrored from req_llm's
      # declared constraint so this explicit dep does not narrow resolution.
      {:llm_db, ">= 2026.9.3 and < 2027.0.0"},
      {:retry, "~> 0.19"},
      {:req, "~> 0.7.0"},
      {:phoenix_pubsub, "~> 2.2"},
      # TomlElixir
      {:toml_elixir, "~> 3.1"},
      # IANA time zone database (Tz.TimeZoneDatabase) for per-profile
      # peak-hour timezone support; tz pre-compiles the IANA data at build
      # time — no runtime updater
      {:tz, "~> 0.28"},
      {:yaml_elixir, "~> 2.11"},
      {:xqlite, "~> 0.12"},
      {:jason, "~> 1.2"},
      # Ecto — schema-less config validation/casting/defaults (no ecto_sql,
      # no database adapter; plain :ecto only)
      {:ecto, "~> 3.14"},
      # Ecto 3.x adapter for xqlite (GitHub-only, pre-0.1; this revision pins
      # xqlite ~> 0.12; brings ecto_sql + db_connection transitively).
      # The `ref:` pin is deliberate: it is the only thing holding the adapter
      # to the xqlite 0.12 series. Without it a bulk `mix deps.update --all`
      # silently advances to an adapter revision that requires xqlite
      # ~> 0.16.0, and xqlite 0.12 -> 0.16 is a breaking migration (the busy
      # error became a map, calls now wait for locks in the calling process
      # instead of holding a VM thread). Bump the adapter and xqlite together,
      # with code changes, when taking that migration.
      {:xqlite_ecto3,
       github: "dimitarvp/xqlite_ecto3", ref: "1767a5d3e3683a27555476d4edfd520082dda8ff"}
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
