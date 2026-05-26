defmodule LLMDB.Snapshot.Builder do
  @moduledoc """
  Builds canonical snapshot artifacts from configured sources.
  """

  alias LLMDB.{Config, Engine, Snapshot}

  @type artifact :: %{
          snapshot: map(),
          snapshot_id: String.t(),
          metadata: map(),
          output_dir: String.t(),
          snapshot_path: String.t(),
          metadata_path: String.t()
        }

  @spec build(keyword()) :: {:ok, artifact()} | {:error, term()}
  def build(opts \\ []) do
    config = Config.get()

    with {:ok, engine_snapshot} <-
           Engine.run(
             sources: Keyword.get(opts, :sources, Config.sources!()),
             allow: config.allow,
             deny: config.deny,
             prefer: config.prefer
           ) do
      output_dir = output_dir(opts)
      snapshot = Snapshot.from_engine_snapshot(engine_snapshot)
      snapshot_id = snapshot["snapshot_id"]

      metadata =
        snapshot
        |> Snapshot.metadata(%{
          "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })
        |> maybe_put_parent_snapshot_id(opts)

      {:ok,
       %{
         snapshot: snapshot,
         snapshot_id: snapshot_id,
         metadata: metadata,
         output_dir: output_dir,
         snapshot_path: Path.join(output_dir, Snapshot.snapshot_filename()),
         metadata_path: Path.join(output_dir, Snapshot.snapshot_meta_filename())
       }}
    end
  end

  @spec write!(artifact(), keyword()) :: artifact()
  def write!(artifact, opts \\ []) do
    Snapshot.write!(artifact.snapshot_path, artifact.snapshot)
    Snapshot.write!(artifact.metadata_path, artifact.metadata)

    if Keyword.get(opts, :install, false) do
      Snapshot.write!(Snapshot.packaged_path(), artifact.snapshot)

      if Snapshot.source_packaged_path() != Snapshot.packaged_path() do
        Snapshot.write!(Snapshot.source_packaged_path(), artifact.snapshot)
      end
    end

    artifact
  end

  @spec up_to_date?(artifact(), keyword()) :: boolean()
  def up_to_date?(artifact, opts \\ []) do
    if Keyword.get(opts, :install, false) do
      compare_file(Snapshot.source_packaged_path(), artifact.snapshot)
    else
      compare_file(artifact.snapshot_path, artifact.snapshot) and
        compare_file(artifact.metadata_path, artifact.metadata)
    end
  end

  defp compare_file(path, expected) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, actual} -> same_document?(actual, expected)
          {:error, _reason} -> false
        end

      {:error, _reason} ->
        false
    end
  end

  defp same_document?(%{"snapshot_id" => actual_id}, %{"snapshot_id" => expected_id})
       when is_binary(actual_id) and is_binary(expected_id) do
    actual_id == expected_id
  end

  defp same_document?(actual, expected) when is_map(actual) and is_map(expected) do
    comparable = fn document ->
      document
      |> Map.drop([
        "generated_at",
        "published_at",
        "snapshot_url",
        "snapshot_meta_url",
        "history_url"
      ])
    end

    comparable.(actual) == comparable.(expected)
  end

  defp output_dir(opts) do
    opts
    |> Keyword.get(:output_dir, Snapshot.build_dir())
    |> expand_path()
  end

  defp maybe_put_parent_snapshot_id(metadata, opts) do
    case Keyword.get(opts, :parent_snapshot_id) do
      nil -> metadata
      parent_snapshot_id -> Map.put(metadata, "parent_snapshot_id", parent_snapshot_id)
    end
  end

  defp expand_path(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path)
    end
  end
end
