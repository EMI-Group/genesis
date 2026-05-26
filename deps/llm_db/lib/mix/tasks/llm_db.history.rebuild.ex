defmodule Mix.Tasks.LlmDb.History.Rebuild do
  use Mix.Task
  @dialyzer {:nowarn_function, run: 1}

  alias LLMDB.{History.Bundle, History.Rebuilder, Snapshot.ReleaseStore}

  @shortdoc "Rebuild snapshot-based history artifacts from the published snapshot store"

  @moduledoc """
  Rebuilds local history artifacts from the published snapshot observation chain,
  then bundles the result and optionally republishes `history.tar.gz` plus
  `history-meta.json` to an immutable `history-<snapshot_id>` release for the
  latest snapshot in the chain.
  """

  @impl Mix.Task
  def run(args) do
    ensure_llm_db_project!()

    {opts, _, invalid} =
      OptionParser.parse(args,
        strict: [
          history_dir: :string,
          output_dir: :string,
          publish: :boolean,
          repo: :string,
          index_tag: :string,
          cache_dir: :string
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    store_overrides =
      []
      |> maybe_put(:repo, opts[:repo])
      |> maybe_put(:index_tag, opts[:index_tag])
      |> maybe_put(:cache_dir, opts[:cache_dir])

    history_dir = Bundle.history_dir(opts[:history_dir])

    observations =
      case ReleaseStore.fetch_snapshot_index(store_overrides) do
        {:ok, snapshots} ->
          snapshots

        {:error, :not_found} ->
          Mix.raise("""
          History rebuild failed: no published snapshot index was found.

          Publish a snapshot first with:

              mix llm_db.snapshot.publish

          For an initial historical seed, use:

              mix llm_db.history.migrate_git --publish
          """)

        {:error, reason} ->
          Mix.raise("History rebuild failed: #{inspect(reason)}")
      end

    snapshot_loader = fn snapshot_id ->
      case ReleaseStore.fetch_snapshot(snapshot_id, store_overrides) do
        {:ok, %{snapshot: snapshot}} -> {:ok, snapshot}
        {:error, reason} -> {:error, reason}
      end
    end

    with {:ok, summary} <-
           Rebuilder.rebuild(
             observations: observations,
             output_dir: history_dir,
             source: "github_releases",
             snapshot_loader: snapshot_loader
           ) do
      bundle_opts =
        []
        |> Keyword.put(:history_dir, history_dir)
        |> Keyword.put(:snapshot_index, observations)
        |> maybe_put(:output_dir, opts[:output_dir])

      case Bundle.bundle(bundle_opts) do
        {:ok, bundle} ->
          history_release_tag =
            if opts[:publish] do
              to_snapshot_id =
                summary.to_snapshot_id ||
                  raise "History rebuild failed: missing to_snapshot_id for publish"

              case ReleaseStore.publish_history_release(
                     [bundle.archive_path, bundle.metadata_path],
                     to_snapshot_id,
                     store_overrides
                   ) do
                {:ok, tag} -> tag
                {:error, reason} -> Mix.raise("History rebuild failed: #{inspect(reason)}")
              end
            end

          Mix.shell().info("✓ History rebuilt")
          Mix.shell().info("  history dir: #{summary.output_dir}")
          Mix.shell().info("  archive:     #{bundle.archive_path}")
          Mix.shell().info("  metadata:    #{bundle.metadata_path}")
          Mix.shell().info("  snapshots:   #{summary.snapshots_written}")
          Mix.shell().info("  events:      #{summary.events_written}")

          if opts[:publish] do
            Mix.shell().info("  published history release: #{history_release_tag}")
          end

        {:error, reason} ->
          Mix.raise("History rebuild failed: #{inspect(reason)}")
      end
    else
      {:error, reason} ->
        Mix.raise("History rebuild failed: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_llm_db_project! do
    app = Mix.Project.config()[:app]

    if app != :llm_db do
      Mix.raise("""
      mix llm_db.history.rebuild can only be run inside the llm_db project itself.
      """)
    end
  end
end
