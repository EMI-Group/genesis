defmodule Mix.Tasks.LlmDb.Snapshot.Publish do
  use Mix.Task

  alias LLMDB.{Snapshot, Snapshot.Builder, Snapshot.ReleaseStore}

  @shortdoc "Publish a canonical snapshot to GitHub Releases"

  @moduledoc """
  Builds and publishes a canonical snapshot to GitHub Releases.

  This creates or repairs the immutable snapshot release for the current
  `snapshot_id`. Local `latest.json` and `snapshot-index.json` outputs are still
  written for inspection, but the canonical remote index is derived from the
  published snapshot releases themselves.
  """

  @impl Mix.Task
  def run(args) do
    ensure_llm_db_project!()

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          output_dir: :string,
          repo: :string,
          index_tag: :string,
          cache_dir: :string
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    Mix.Task.run("app.start")

    store_overrides =
      []
      |> maybe_put(:repo, opts[:repo])
      |> maybe_put(:index_tag, opts[:index_tag])
      |> maybe_put(:cache_dir, opts[:cache_dir])

    existing_snapshots =
      case ReleaseStore.fetch_snapshot_index(store_overrides) do
        {:ok, snapshots} -> snapshots
        _ -> []
      end

    latest_entry = List.last(existing_snapshots)
    latest_snapshot_id = latest_entry && latest_entry["snapshot_id"]

    build_opts =
      []
      |> maybe_put(:output_dir, opts[:output_dir])
      |> maybe_put(:parent_snapshot_id, latest_snapshot_id)

    with {:ok, artifact} <- Builder.build(build_opts) do
      artifact = Builder.write!(artifact)

      known_snapshot? =
        Enum.any?(existing_snapshots, fn snapshot ->
          snapshot["snapshot_id"] == artifact.snapshot_id
        end)

      if known_snapshot? do
        Mix.shell().info(
          "Snapshot #{artifact.snapshot_id} already published; verifying release..."
        )
      end

      {:ok, snapshot_tag} =
        ReleaseStore.ensure_snapshot_release(
          artifact.snapshot_path,
          artifact.metadata_path,
          artifact.snapshot_id,
          store_overrides
        )

      published_at = DateTime.utc_now() |> DateTime.to_iso8601()

      entry =
        artifact.metadata
        |> Map.put("published_at", published_at)
        |> Map.put("parent_snapshot_id", latest_snapshot_id)
        |> Map.put("tag", snapshot_tag)
        |> Map.put(
          "snapshot_url",
          ReleaseStore.asset_url(snapshot_tag, Snapshot.snapshot_filename(), store_overrides)
        )
        |> Map.put(
          "snapshot_meta_url",
          ReleaseStore.asset_url(snapshot_tag, Snapshot.snapshot_meta_filename(), store_overrides)
        )

      {latest_to_publish, snapshots} =
        if latest_snapshot_id == artifact.snapshot_id do
          {latest_entry || entry, existing_snapshots}
        else
          {entry, existing_snapshots ++ [entry]}
        end

      latest_path = Path.join(artifact.output_dir, Snapshot.latest_filename())
      index_path = Path.join(artifact.output_dir, Snapshot.snapshot_index_filename())

      Snapshot.write!(latest_path, latest_to_publish)

      Snapshot.write!(index_path, %{
        "schema_version" => Snapshot.schema_version(),
        "snapshots" => snapshots
      })

      Mix.shell().info("✓ Snapshot #{artifact.snapshot_id} published")
      Mix.shell().info("  snapshot release: #{snapshot_tag}")
      Mix.shell().info("  latest index:     #{latest_path}")
      Mix.shell().info("  snapshot index:   #{index_path}")
    else
      {:error, reason} ->
        Mix.raise("Snapshot publish failed: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_llm_db_project! do
    app = Mix.Project.config()[:app]

    if app != :llm_db do
      Mix.raise("""
      mix llm_db.snapshot.publish can only be run inside the llm_db project itself.
      """)
    end
  end
end
