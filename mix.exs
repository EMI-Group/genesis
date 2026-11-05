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
            evo_dash: :permanent,
            # wx is bundled with OTP but is not a dependency of any app — it
            # must be listed explicitly so the dashboard's native directory
            # picker (EvoDash.DirectoryPicker, wxDirDialog) works in releases.
            wx: :load
          ]
        ],
        genesis_desktop: [
          applications: [
            evo_git: :permanent,
            evo_dash: :permanent,
            # wx for the native directory picker (EvoDash.DirectoryPicker) —
            # see the `genesis` release note above.
            wx: :load
          ],
          # Bake a compile-time desktop flag into sys.config so that the
          # backend reliably detects desktop mode at runtime.
          config: [evo_dash: [desktop_release: true]]
        ],
        genesis_server: [
          # The ONLY headless distribution: the full dashboard served over HTTP
          # on a remote box, plus the `genesis` lifecycle CLI from rel/overlays.
          # ONE instance per host also serves as the SSH remote-dev target:
          # `genesis remote start` toggles Erlang distribution on the RUNNING
          # instance at runtime (control file + SIGHUP), so HTTP and remote SSH
          # access are selective, coexisting roles of the same BEAM.
          # Deliberately NO `wx` — headless hosts lack wxWidgets, and the
          # dashboard's directory picker falls back to manual path entry when
          # wx is unavailable.
          applications: [
            evo_git: :permanent,
            evo_dash: :permanent
          ],
          # Bundle ERTS so the tarball runs on hosts without Erlang installed.
          include_erts: true,
          overlays: ["rel/overlays"],
          # Intended compile-time server flag. NOTE: the `config:` release option
          # does not reach the generated sys.config in this umbrella project, so
          # runtime.exs detects server mode from `RELEASE_NAME=genesis_server`
          # (the signal the release launcher always exports). Kept for forward
          # compatibility with Mix releases that merge it.
          config: [evo_dash: [server_release: true]]
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
