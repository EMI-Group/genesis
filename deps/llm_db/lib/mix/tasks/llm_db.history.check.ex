defmodule Mix.Tasks.LlmDb.History.Check do
  use Mix.Task

  alias LLMDB.{History.Bundle, Snapshot.ReleaseStore}

  @shortdoc "Checks whether local history matches the published history bundle"

  @moduledoc """
  Checks whether the local installed history bundle matches the published
  history metadata in the snapshot store.

  ## Usage

      mix llm_db.history.check
      mix llm_db.history.check --allow-missing
      mix llm_db.history.check --allow-outdated
      mix llm_db.history.check --output-dir priv/llm_db/history

  ## Options

  - `--allow-missing` - Treat missing history output as success (default: `false`)
  - `--allow-outdated` - Treat an older local history bundle as success (default: `false`)
  - `--output-dir` - History directory (default: `priv/llm_db/history`)
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
          allow_missing: :boolean,
          allow_outdated: :boolean,
          output_dir: :string,
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

    allow_missing? = opts[:allow_missing] == true
    allow_outdated? = opts[:allow_outdated] == true
    output_dir = Bundle.history_dir(opts[:output_dir])

    with {:ok, remote_meta} <- ReleaseStore.fetch_history_meta(store_overrides) do
      case Bundle.read_meta(output_dir) do
        {:ok, local_meta} ->
          local_event_count = local_meta["event_count"] || local_meta["events_written"]
          remote_event_count = remote_meta["event_count"] || remote_meta["events_written"]

          if local_meta["to_snapshot_id"] == remote_meta["to_snapshot_id"] and
               local_event_count == remote_event_count do
            Mix.shell().info("✓ History is up to date")
          else
            message = """
            Local to_snapshot_id:  #{local_meta["to_snapshot_id"] || "missing"}
            Remote to_snapshot_id: #{remote_meta["to_snapshot_id"] || "missing"}
            Local event_count:     #{local_event_count || "missing"}
            Remote event_count:    #{remote_event_count || "missing"}
            """

            if allow_outdated? do
              Mix.shell().info("""
              ✓ History output is older than the published bundle (allowed).

              #{message}
              """)
            else
              Mix.raise("""
              History check failed: local history bundle is outdated.

              #{message}

              Run: mix llm_db.history.sync
              """)
            end
          end

        {:error, _reason} when allow_missing? ->
          Mix.shell().info("✓ History output unavailable (allowed)")

        {:error, _reason} ->
          Mix.raise(
            "History check failed: history output is unavailable. Run mix llm_db.history.sync"
          )
      end
    else
      {:error, :not_found} when allow_missing? ->
        Mix.shell().info("✓ Published history metadata unavailable (allowed)")

      {:error, :not_found} ->
        Mix.raise("""
        History check failed: no published history metadata was found.

        Seed the snapshot store first with:

            mix llm_db.history.migrate_git --publish
        """)

      {:error, _reason} when allow_missing? ->
        Mix.shell().info("✓ Published history metadata unavailable (allowed)")

      {:error, reason} ->
        Mix.raise("History check failed: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_llm_db_project! do
    app = Mix.Project.config()[:app]

    if app != :llm_db do
      Mix.raise("""
      mix llm_db.history.check can only be run inside the llm_db project itself.
      """)
    end
  end
end
