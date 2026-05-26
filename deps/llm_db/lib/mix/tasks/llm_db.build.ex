defmodule Mix.Tasks.LlmDb.Build do
  use Mix.Task
  @dialyzer {:nowarn_function, run: 1}

  alias LLMDB.Snapshot.Builder

  @shortdoc "Build a canonical snapshot artifact from configured sources"

  @moduledoc """
  Builds a canonical `snapshot.json` from configured sources.

  The snapshot is always written to a local build output directory. Use
  `--install` to also copy it into `priv/llm_db/snapshot.json` for local runtime
  loading or packaging.

  ## Usage

      mix llm_db.build
      mix llm_db.build --install
      mix llm_db.build --check
      mix llm_db.build --output-dir tmp/llm_db/build

  ## Options

    * `--check` - Verify the generated snapshot artifacts already match the
      expected output.
    * `--install` - Also install the built snapshot into
      `priv/llm_db/snapshot.json`.
    * `--output-dir` - Directory for local snapshot build artifacts.
  """

  @impl Mix.Task
  def run(args) do
    ensure_llm_db_project!()

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          check: :boolean,
          install: :boolean,
          output_dir: :string
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    Mix.Task.run("app.start")

    build_opts =
      []
      |> maybe_put(:output_dir, opts[:output_dir])

    Mix.shell().info("Building canonical snapshot from configured sources...\n")

    case Builder.build(build_opts) do
      {:ok, artifact} ->
        maybe_check_or_write(artifact, opts)

      {:error, reason} ->
        Mix.raise("Snapshot build failed: #{inspect(reason)}")
    end
  end

  defp maybe_check_or_write(artifact, opts) do
    if opts[:check] do
      if Builder.up_to_date?(artifact, install: opts[:install] == true) do
        Mix.shell().info("✓ Snapshot artifacts are up to date.")
      else
        expected_paths =
          if opts[:install] do
            [LLMDB.Snapshot.source_packaged_path()]
          else
            [
              artifact.snapshot_path,
              artifact.metadata_path
            ]
          end

        Mix.raise("""
        Snapshot artifacts are out of date.

        Expected:
        #{Enum.map_join(expected_paths, "\n", &"  - #{&1}")}

        To fix this:
          mix llm_db.build#{if opts[:install], do: " --install", else: ""}
        """)
      end
    else
      artifact = Builder.write!(artifact, install: opts[:install] == true)
      print_summary(artifact, opts)
    end
  end

  defp print_summary(artifact, opts) do
    counts = LLMDB.Snapshot.counts(artifact.snapshot)

    Mix.shell().info("✓ Snapshot written to #{artifact.snapshot_path}")
    Mix.shell().info("✓ Metadata written to #{artifact.metadata_path}")

    if opts[:install] do
      Mix.shell().info("✓ Packaged snapshot installed to #{LLMDB.Snapshot.packaged_path()}")
    end

    Mix.shell().info("")
    Mix.shell().info("Summary:")
    Mix.shell().info("  Snapshot ID: #{artifact.snapshot_id}")
    Mix.shell().info("  Providers:   #{counts.provider_count}")
    Mix.shell().info("  Models:      #{counts.model_count}")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_llm_db_project! do
    app = Mix.Project.config()[:app]

    if app != :llm_db do
      Mix.raise("""
      mix llm_db.build can only be run inside the llm_db project itself.
      """)
    end
  end
end
