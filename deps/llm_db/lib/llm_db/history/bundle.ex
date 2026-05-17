defmodule LLMDB.History.Bundle do
  @moduledoc """
  Snapshot-store helpers for local history bundles.
  """
  @dialyzer {:nowarn_function, create_archive: 2}

  alias LLMDB.Snapshot

  @spec history_dir(String.t() | nil) :: String.t()
  def history_dir(path \\ nil) do
    path
    |> Kernel.||(Application.get_env(:llm_db, :history_dir, "priv/llm_db/history"))
    |> expand_path()
  end

  @spec read_meta(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def read_meta(path \\ nil) do
    history_dir = history_dir(path)
    meta_path = Path.join(history_dir, "meta.json")

    with {:ok, content} <- File.read(meta_path),
         {:ok, meta} <- Jason.decode(content) do
      {:ok, meta}
    end
  end

  @spec bundle(keyword()) ::
          {:ok, %{archive_path: String.t(), metadata_path: String.t(), metadata: map()}}
          | {:error, term()}
  def bundle(opts \\ []) do
    history_dir = history_dir(Keyword.get(opts, :history_dir))
    output_dir = output_dir(opts)

    with :ok <- validate_history_dir(history_dir),
         :ok <- File.mkdir_p(output_dir),
         metadata <- build_metadata(history_dir, opts),
         archive_path = Path.join(output_dir, Snapshot.history_archive_filename()),
         metadata_path = Path.join(output_dir, Snapshot.history_meta_filename()),
         :ok <- create_archive(history_dir, archive_path) do
      Snapshot.write!(metadata_path, metadata)

      {:ok,
       %{
         archive_path: archive_path,
         metadata_path: metadata_path,
         metadata: metadata
       }}
    end
  end

  @spec install_archive(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def install_archive(archive_path, destination \\ nil) when is_binary(archive_path) do
    output_dir = history_dir(destination)
    File.mkdir_p!(output_dir)

    case :erl_tar.extract(String.to_charlist(archive_path), [
           :compressed,
           {:cwd, String.to_charlist(output_dir)}
         ]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_metadata(history_dir, opts) do
    local_meta =
      case read_meta(history_dir) do
        {:ok, meta} -> meta
        _ -> %{}
      end

    snapshot_index = Keyword.get(opts, :snapshot_index, [])
    latest_snapshot = List.last(snapshot_index)
    first_snapshot = List.first(snapshot_index)
    year_files = event_files(history_dir) |> Enum.map(&Path.basename/1)

    %{
      "schema_version" => Snapshot.schema_version(),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "from_snapshot_id" =>
        local_meta["from_snapshot_id"] ||
          local_meta["from_commit_snapshot_id"] ||
          first_snapshot_id(first_snapshot),
      "to_snapshot_id" =>
        local_meta["to_snapshot_id"] ||
          local_meta["snapshot_id"] ||
          latest_snapshot_id(latest_snapshot),
      "event_count" => count_events(history_dir),
      "year_files" => year_files
    }
  end

  defp create_archive(history_dir, archive_path) do
    case System.find_executable("tar") do
      nil ->
        {:error, :tar_unavailable}

      tar ->
        case System.cmd(tar, ["-czf", archive_path, "-C", history_dir, "."],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> :ok
          {output, _code} -> {:error, String.trim(output)}
        end
    end
  end

  defp validate_history_dir(history_dir) do
    if File.dir?(history_dir) do
      :ok
    else
      {:error, :history_dir_missing}
    end
  end

  defp count_events(history_dir) do
    history_dir
    |> event_files()
    |> Enum.reduce(0, fn path, acc ->
      acc + Enum.count(File.stream!(path))
    end)
  end

  defp event_files(history_dir) do
    history_dir
    |> Path.join("events/*.ndjson")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp output_dir(opts) do
    opts
    |> Keyword.get(:output_dir, Path.join(["_build", "llm_db", "history_bundle"]))
    |> expand_path()
  end

  defp first_snapshot_id(%{"snapshot_id" => snapshot_id}), do: snapshot_id
  defp first_snapshot_id(_), do: nil

  defp latest_snapshot_id(%{"snapshot_id" => snapshot_id}), do: snapshot_id
  defp latest_snapshot_id(_), do: nil

  defp expand_path(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path)
    end
  end
end
