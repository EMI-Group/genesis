defmodule Mix.Tasks.LlmDb.History.Sync do
  use Mix.Task

  alias LLMDB.{History.Bundle, Snapshot.ReleaseStore}

  @shortdoc "Installs the published history bundle into priv/llm_db/history"

  @moduledoc """
  Downloads the published history bundle from the snapshot store and extracts it
  into the local history directory.

  ## Usage

      mix llm_db.history.sync
      mix llm_db.history.sync --output-dir priv/llm_db/history
      mix llm_db.history.sync --repo agentjido/llm_db

  ## Options

  - `--output-dir` - Directory for generated history files (default: `priv/llm_db/history`)
  - `--repo` - GitHub repository slug (default: `agentjido/llm_db`)
  - `--index-tag` - Deprecated compatibility option; ignored for immutable release lookup
  - `--cache-dir` - Local snapshot cache directory
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

    output_dir = Bundle.history_dir(opts[:output_dir])
    archive_path = Path.join(System.tmp_dir!(), "llm_db-history.tar.gz")

    store_overrides =
      []
      |> maybe_put(:repo, opts[:repo])
      |> maybe_put(:index_tag, opts[:index_tag])
      |> maybe_put(:cache_dir, opts[:cache_dir])

    Mix.shell().info("Syncing published history bundle...")

    case ReleaseStore.download_history_archive(archive_path, store_overrides) do
      :ok ->
        case Bundle.install_archive(archive_path, output_dir) do
          :ok ->
            meta =
              case ReleaseStore.fetch_history_meta(store_overrides) do
                {:ok, meta} -> meta
                _ -> %{}
              end

            Mix.shell().info("✓ History sync complete")
            Mix.shell().info("  output dir:      #{output_dir}")
            Mix.shell().info("  to snapshot:     #{meta["to_snapshot_id"] || "unknown"}")
            Mix.shell().info("  generated at:    #{meta["generated_at"] || "unknown"}")

          {:error, reason} ->
            Mix.raise("History sync failed while extracting archive: #{inspect(reason)}")
        end

      {:error, :not_found} ->
        Mix.raise("""
        History sync failed: no published history bundle was found.

        Seed the snapshot store first with:

            mix llm_db.history.migrate_git --publish
        """)

      {:error, reason} ->
        Mix.raise("History sync failed: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_llm_db_project! do
    app = Mix.Project.config()[:app]

    if app != :llm_db do
      Mix.raise("""
      mix llm_db.history.sync can only be run inside the llm_db project itself.
      """)
    end
  end
end
