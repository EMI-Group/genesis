defmodule Mix.Tasks.LlmDb.History.MigrateGit do
  use Mix.Task
  @dialyzer {:nowarn_function, publish_history_bundle!: 4}

  alias LLMDB.{History.Bundle, History.Migrator, Snapshot, Snapshot.ReleaseStore}

  @shortdoc "One-time reachable Git migration into snapshot-store history artifacts"

  @moduledoc """
  Performs the one-time migration from legacy Git-tracked metadata commits into
  content-addressed snapshots plus snapshot-based history artifacts.

  By default this writes local artifacts only. With `--publish`, it also seeds
  GitHub Releases with all discovered immutable snapshots and uploads a rebuilt
  `history.tar.gz` bundle to the immutable history release for the latest
  migrated snapshot.
  """

  @impl Mix.Task
  def run(args) do
    ensure_llm_db_project!()

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          from: :string,
          to: :string,
          output_dir: :string,
          snapshots_dir: :string,
          snapshot_index_path: :string,
          latest_path: :string,
          publish: :boolean,
          repo: :string,
          index_tag: :string,
          cache_dir: :string,
          bundle_output_dir: :string
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    runtime_opts =
      []
      |> maybe_put(:from, opts[:from])
      |> maybe_put(:to, opts[:to])
      |> maybe_put(:output_dir, opts[:output_dir])
      |> maybe_put(:snapshots_dir, opts[:snapshots_dir])
      |> maybe_put(:snapshot_index_path, opts[:snapshot_index_path])
      |> maybe_put(:latest_path, opts[:latest_path])

    Mix.shell().info("Migrating reachable Git metadata into snapshot-based artifacts...")

    case Migrator.run(runtime_opts) do
      {:ok, summary} ->
        maybe_publish(summary, opts)

        Mix.shell().info("✓ Git history migration complete")
        Mix.shell().info("  commits scanned:          #{summary.commits_scanned}")
        Mix.shell().info("  commits processed:        #{summary.commits_processed}")
        Mix.shell().info("  observations written:     #{summary.snapshots_written}")
        Mix.shell().info("  unique snapshots written: #{summary.unique_snapshots_written}")
        Mix.shell().info("  events written:           #{summary.events_written}")
        Mix.shell().info("  output dir:               #{summary.output_dir}")
        Mix.shell().info("  snapshots dir:            #{summary.snapshots_dir}")

      {:error, reason} ->
        Mix.raise("History migration failed: #{inspect(reason)}")
    end
  end

  defp maybe_publish(summary, opts) do
    if opts[:publish] == true do
      store_overrides =
        []
        |> maybe_put(:repo, opts[:repo])
        |> maybe_put(:index_tag, opts[:index_tag])
        |> maybe_put(:cache_dir, opts[:cache_dir])

      observations = read_snapshot_index!(summary.snapshot_index_path)

      publish_snapshots!(observations, summary.snapshots_dir, store_overrides)

      publish_history_bundle!(
        summary.output_dir,
        observations,
        opts[:bundle_output_dir],
        store_overrides
      )
    end
  end

  defp publish_snapshots!(observations, snapshots_dir, store_overrides) do
    observations
    |> Enum.map(& &1["snapshot_id"])
    |> Enum.uniq()
    |> Enum.each(fn snapshot_id ->
      snapshot_path = Path.join([snapshots_dir, snapshot_id, Snapshot.snapshot_filename()])
      meta_path = Path.join([snapshots_dir, snapshot_id, Snapshot.snapshot_meta_filename()])

      case ReleaseStore.ensure_snapshot_release(
             snapshot_path,
             meta_path,
             snapshot_id,
             store_overrides
           ) do
        {:ok, _tag} ->
          :ok

        {:error, reason} ->
          Mix.raise("Failed publishing snapshot #{snapshot_id}: #{inspect(reason)}")
      end
    end)
  end

  defp publish_history_bundle!(history_dir, observations, bundle_output_dir, store_overrides) do
    bundle_opts =
      []
      |> Keyword.put(:history_dir, history_dir)
      |> Keyword.put(:snapshot_index, observations)
      |> maybe_put(:output_dir, bundle_output_dir)

    case Bundle.bundle(bundle_opts) do
      {:ok, bundle} ->
        latest_snapshot_id =
          observations
          |> List.last()
          |> case do
            %{"snapshot_id" => snapshot_id} -> snapshot_id
            _ -> Mix.raise("Failed publishing history bundle: missing latest snapshot_id")
          end

        case ReleaseStore.publish_history_release(
               [bundle.archive_path, bundle.metadata_path],
               latest_snapshot_id,
               store_overrides
             ) do
          {:ok, _tag} -> :ok
          {:error, reason} -> Mix.raise("Failed publishing history bundle: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("Failed bundling migrated history: #{inspect(reason)}")
    end
  end

  defp read_snapshot_index!(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{"snapshots" => snapshots}} <- Jason.decode(content) do
      snapshots
    else
      {:ok, other} ->
        Mix.raise("Invalid snapshot index at #{path}: #{inspect(other)}")

      {:error, reason} ->
        Mix.raise("Failed reading snapshot index at #{path}: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_llm_db_project! do
    app = Mix.Project.config()[:app]

    if app != :llm_db do
      Mix.raise("""
      mix llm_db.history.migrate_git can only be run inside the llm_db project itself.
      """)
    end
  end
end
