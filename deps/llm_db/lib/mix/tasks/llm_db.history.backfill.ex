defmodule Mix.Tasks.LlmDb.History.Backfill do
  use Mix.Task
  @dialyzer {:nowarn_function, run: 1}

  @shortdoc "Backfill model history from git commits into priv/llm_db/history NDJSON"

  @moduledoc """
  Backfills model history from committed provider snapshots.

  The task walks git history for `priv/llm_db/providers/*.json`, computes model
  deltas per commit, and writes append-only history artifacts:

  - `priv/llm_db/history/events/YYYY.ndjson`
  - `priv/llm_db/history/snapshots.ndjson`
  - `priv/llm_db/history/meta.json`

  ## Usage

      mix llm_db.history.backfill
      mix llm_db.history.backfill --force
      mix llm_db.history.backfill --from <sha>
      mix llm_db.history.backfill --to <ref>
      mix llm_db.history.backfill --output-dir priv/llm_db/history

  ## Options

  - `--force` - Remove existing generated history files first
  - `--from` - Start commit SHA/ref (inclusive)
  - `--to` - End commit SHA/ref (default: `HEAD`)
  - `--output-dir` - Directory for generated history files (default: `priv/llm_db/history`)
  """

  @impl Mix.Task
  def run(args) do
    ensure_llm_db_project!()

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          force: :boolean,
          from: :string,
          to: :string,
          output_dir: :string
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    runtime_opts =
      []
      |> maybe_put(:force, opts[:force] == true)
      |> maybe_put(:from, opts[:from])
      |> maybe_put(:to, opts[:to])
      |> maybe_put(:output_dir, opts[:output_dir])

    Mix.shell().info("Backfilling model history from git...")

    case LLMDB.History.Backfill.run(runtime_opts) do
      {:ok, summary} ->
        Mix.shell().info("✓ History backfill complete")
        Mix.shell().info("  commits scanned:   #{summary.commits_scanned}")
        Mix.shell().info("  commits processed: #{summary.commits_processed}")
        Mix.shell().info("  snapshots written: #{summary.snapshots_written}")
        Mix.shell().info("  events written:    #{summary.events_written}")
        Mix.shell().info("  output dir:        #{summary.output_dir}")
        Mix.shell().info("  from commit:       #{summary.from_commit}")
        Mix.shell().info("  to commit:         #{summary.to_commit}")

      {:error, reason} ->
        Mix.raise("History backfill failed: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, false), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_llm_db_project! do
    app = Mix.Project.config()[:app]

    if app != :llm_db do
      Mix.raise("""
      mix llm_db.history.backfill can only be run inside the llm_db project itself.
      """)
    end
  end
end
