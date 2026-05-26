defmodule Mix.Tasks.LlmDb.Snapshot.Fetch do
  use Mix.Task

  alias LLMDB.{Snapshot, Snapshot.ReleaseStore}

  @shortdoc "Fetch a published snapshot from GitHub Releases"

  @moduledoc """
  Fetches a published snapshot from GitHub Releases.

  ## Usage

      mix llm_db.snapshot.fetch
      mix llm_db.snapshot.fetch --ref latest --install
      mix llm_db.snapshot.fetch --ref <snapshot_id> --output-dir tmp/snapshots
  """

  @impl Mix.Task
  def run(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          ref: :string,
          install: :boolean,
          output_dir: :string,
          repo: :string,
          index_tag: :string,
          cache_dir: :string
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    ref =
      case opts[:ref] do
        nil -> :latest
        "latest" -> :latest
        snapshot_id -> snapshot_id
      end

    store_overrides =
      []
      |> maybe_put(:repo, opts[:repo])
      |> maybe_put(:index_tag, opts[:index_tag])
      |> maybe_put(:cache_dir, opts[:cache_dir])

    case ReleaseStore.fetch_snapshot(ref, store_overrides) do
      {:ok, %{snapshot: snapshot, snapshot_id: snapshot_id}} ->
        output_dir =
          opts[:output_dir]
          |> default_output_dir()

        snapshot_path = Path.join(output_dir, Snapshot.snapshot_filename())
        metadata_path = Path.join(output_dir, Snapshot.snapshot_meta_filename())
        metadata = Snapshot.metadata(snapshot)

        Snapshot.write!(snapshot_path, snapshot)
        Snapshot.write!(metadata_path, metadata)

        if opts[:install] do
          Snapshot.write!(Snapshot.packaged_path(), snapshot)

          if Snapshot.source_packaged_path() != Snapshot.packaged_path() do
            Snapshot.write!(Snapshot.source_packaged_path(), snapshot)
          end
        end

        Mix.shell().info("✓ Snapshot #{snapshot_id} fetched")
        Mix.shell().info("  snapshot: #{snapshot_path}")
        Mix.shell().info("  metadata: #{metadata_path}")

        if opts[:install] do
          Mix.shell().info("  installed: #{Snapshot.packaged_path()}")
          Mix.shell().info("  source:    #{Snapshot.source_packaged_path()}")
        end

      {:error, reason} ->
        Mix.raise("Snapshot fetch failed: #{inspect(reason)}")
    end
  end

  defp default_output_dir(nil), do: Snapshot.build_dir()

  defp default_output_dir(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
