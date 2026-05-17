defmodule LLMDB.History.Migrator do
  @moduledoc """
  One-time migration from Git-tracked metadata history into snapshot-store artifacts.

  The migrator walks reachable metadata commits, reconstructs canonical snapshots,
  materializes immutable snapshot artifacts by content hash, deduplicates adjacent
  identical states, and then rebuilds local history artifacts from the resulting
  snapshot observation chain.
  """

  alias LLMDB.{History.Rebuilder, Snapshot}

  @providers_dir "priv/llm_db/providers"
  @manifest_path "priv/llm_db/manifest.json"
  @sortable_list_keys MapSet.new(["aliases", "tags", "input", "output"])

  @type summary :: %{
          commits_scanned: non_neg_integer(),
          commits_processed: non_neg_integer(),
          snapshots_written: non_neg_integer(),
          unique_snapshots_written: non_neg_integer(),
          events_written: non_neg_integer(),
          output_dir: String.t(),
          snapshots_dir: String.t(),
          snapshot_index_path: String.t(),
          latest_path: String.t(),
          from_snapshot_id: String.t() | nil,
          to_snapshot_id: String.t() | nil
        }

  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) do
    output_dir = history_dir(opts)
    snapshots_dir = snapshots_dir(opts)
    snapshot_index_path = snapshot_index_path(opts, output_dir)
    latest_path = latest_path(opts, output_dir)

    with {:ok, commits} <-
           metadata_commits(Keyword.get(opts, :from), Keyword.get(opts, :to, "HEAD")),
         {:ok, migration} <- build_snapshot_migration(commits, snapshots_dir),
         {:ok, rebuild_summary} <-
           Rebuilder.rebuild(
             observations: migration.observations,
             output_dir: output_dir,
             snapshot_index_path: snapshot_index_path,
             latest_path: latest_path,
             source: source_repo(),
             snapshot_loader: fn snapshot_id ->
               Snapshot.read(snapshot_path(snapshots_dir, snapshot_id))
             end
           ) do
      {:ok,
       %{
         commits_scanned: length(commits),
         commits_processed: migration.observation_count,
         snapshots_written: rebuild_summary.snapshots_written,
         unique_snapshots_written: rebuild_summary.unique_snapshots_written,
         events_written: rebuild_summary.events_written,
         output_dir: output_dir,
         snapshots_dir: snapshots_dir,
         snapshot_index_path: rebuild_summary.snapshot_index_path,
         latest_path: rebuild_summary.latest_path,
         from_snapshot_id: rebuild_summary.from_snapshot_id,
         to_snapshot_id: rebuild_summary.to_snapshot_id
       }}
    end
  end

  defp build_snapshot_migration(commits, snapshots_dir) do
    File.mkdir_p!(snapshots_dir)

    final =
      Enum.reduce(
        commits,
        %{previous_snapshot_id: nil, observations: [], unique_snapshot_ids: MapSet.new()},
        fn sha, acc ->
          case load_commit_snapshot(sha) do
            {:ok, nil} ->
              acc

            {:ok, %{snapshot: snapshot, metadata: metadata}} ->
              snapshot_id = snapshot["snapshot_id"]

              if snapshot_id == acc.previous_snapshot_id do
                acc
              else
                observation =
                  metadata
                  |> Map.put("parent_snapshot_id", acc.previous_snapshot_id)
                  |> Map.put("published_at", nil)
                  |> Map.put("snapshot_path", snapshot_path(snapshots_dir, snapshot_id))
                  |> Map.put("snapshot_meta_path", snapshot_meta_path(snapshots_dir, snapshot_id))

                write_snapshot_artifacts(snapshots_dir, snapshot, observation)

                %{
                  previous_snapshot_id: snapshot_id,
                  observations: acc.observations ++ [observation],
                  unique_snapshot_ids: MapSet.put(acc.unique_snapshot_ids, snapshot_id)
                }
              end

            {:error, reason} ->
              raise "failed to reconstruct commit #{sha}: #{inspect(reason)}"
          end
        end
      )

    {:ok,
     %{
       observations:
         Enum.map(final.observations, fn observation ->
           Map.drop(observation, ["snapshot_path", "snapshot_meta_path"])
         end),
       observation_count: length(final.observations),
       unique_snapshot_count: MapSet.size(final.unique_snapshot_ids)
     }}
  end

  defp load_commit_snapshot(sha) do
    with {:ok, providers} <- load_provider_documents(sha) do
      if map_size(providers) == 0 do
        {:ok, nil}
      else
        commit_date = commit_date_iso8601(sha)
        manifest = manifest_for_commit(sha)

        snapshot =
          %{
            "schema_version" => Snapshot.schema_version(),
            "version" => manifest["version"] || 2,
            "generated_at" => manifest["generated_at"] || commit_date,
            "providers" => providers
          }
          |> Map.put("snapshot_id", nil)
          |> then(fn document ->
            Map.put(document, "snapshot_id", Snapshot.snapshot_id(document))
          end)

        metadata =
          snapshot
          |> Snapshot.metadata(%{
            "captured_at" => commit_date,
            "manifest_generated_at" => manifest["generated_at"],
            "source_commit" => sha,
            "version" => snapshot["version"]
          })
          |> Map.put("snapshot_id", snapshot["snapshot_id"])

        {:ok, %{snapshot: snapshot, metadata: metadata}}
      end
    end
  end

  defp load_provider_documents(sha) do
    with {:ok, files_output} <- git(["ls-tree", "-r", "--name-only", sha, "--", @providers_dir]) do
      providers =
        files_output
        |> parse_lines()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.reduce(%{}, fn path, acc ->
          case git(["show", "#{sha}:#{path}"]) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, provider_data} ->
                  provider_id = Map.get(provider_data, "id")

                  if is_binary(provider_id) do
                    Map.put(acc, provider_id, normalize_provider_document(provider_data))
                  else
                    acc
                  end

                _ ->
                  acc
              end

            _ ->
              acc
          end
        end)

      {:ok, providers}
    end
  end

  defp normalize_provider_document(provider_data) do
    models =
      provider_data
      |> Map.get("models", %{})
      |> Enum.sort_by(fn {model_id, _model} -> model_id end)
      |> Map.new(fn {model_id, model_data} ->
        normalized =
          model_data
          |> Map.put_new("id", model_id)
          |> Map.put_new("provider", provider_data["id"])
          |> normalize_value([])

        {model_id, normalized}
      end)

    provider_data
    |> Map.put("models", models)
    |> normalize_value([])
  end

  defp manifest_for_commit(sha) do
    case git(["show", "#{sha}:#{@manifest_path}"]) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, manifest} when is_map(manifest) -> manifest
          _ -> %{}
        end

      {:error, _reason} ->
        %{}
    end
  end

  defp write_snapshot_artifacts(snapshots_dir, snapshot, observation) do
    snapshot_path = snapshot_path(snapshots_dir, observation["snapshot_id"])
    snapshot_meta_path = snapshot_meta_path(snapshots_dir, observation["snapshot_id"])

    if not File.exists?(snapshot_path) do
      Snapshot.write!(snapshot_path, snapshot)
    end

    if not File.exists?(snapshot_meta_path) do
      Snapshot.write!(
        snapshot_meta_path,
        observation
        |> Map.drop(["snapshot_path", "snapshot_meta_path", "parent_snapshot_id"])
      )
    end
  end

  defp snapshot_path(snapshots_dir, snapshot_id) do
    Path.join([snapshots_dir, snapshot_id, Snapshot.snapshot_filename()])
  end

  defp snapshot_meta_path(snapshots_dir, snapshot_id) do
    Path.join([snapshots_dir, snapshot_id, Snapshot.snapshot_meta_filename()])
  end

  defp history_dir(opts) do
    opts
    |> Keyword.get(:output_dir, "priv/llm_db/history")
    |> expand_path()
  end

  defp snapshots_dir(opts) do
    opts
    |> Keyword.get(:snapshots_dir, Path.join(["_build", "llm_db", "snapshot_store", "snapshots"]))
    |> expand_path()
  end

  defp snapshot_index_path(opts, output_dir) do
    opts
    |> Keyword.get(
      :snapshot_index_path,
      Path.join(output_dir, Snapshot.snapshot_index_filename())
    )
    |> expand_path()
  end

  defp latest_path(opts, output_dir) do
    opts
    |> Keyword.get(:latest_path, Path.join(output_dir, Snapshot.latest_filename()))
    |> expand_path()
  end

  defp metadata_commits(from_ref, to_ref) do
    with {:ok, commits_output} <-
           git([
             "rev-list",
             "--reverse",
             "--topo-order",
             to_ref,
             "--",
             @providers_dir,
             @manifest_path
           ]) do
      commits =
        commits_output
        |> parse_lines()
        |> Enum.reject(&commit_empty_state?/1)

      maybe_apply_from(commits, from_ref)
    end
  end

  defp maybe_apply_from(commits, nil), do: {:ok, commits}

  defp maybe_apply_from(commits, from_ref) do
    with {:ok, from_sha} <- git(["rev-parse", "--verify", from_ref]),
         from_sha <- String.trim(from_sha),
         true <- from_sha in commits do
      {:ok, Enum.drop_while(commits, &(&1 != from_sha))}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, "commit #{from_ref} is not reachable in the metadata history range"}
    end
  end

  defp commit_empty_state?(sha) do
    case load_provider_documents(sha) do
      {:ok, providers} -> map_size(providers) == 0
      _ -> true
    end
  end

  defp normalize_value(value, path)

  defp normalize_value(value, path) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {k, normalize_value(v, [to_string(k) | path])} end)
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Map.new()
  end

  defp normalize_value(value, path) when is_list(value) do
    normalized = Enum.map(value, &normalize_value(&1, path))

    case path do
      [key | _] ->
        if key in @sortable_list_keys and Enum.all?(normalized, &scalar?/1) do
          Enum.sort(normalized)
        else
          normalized
        end

      _ ->
        normalized
    end
  end

  defp normalize_value(value, _path), do: value

  defp scalar?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp commit_date_iso8601(sha) do
    case git(["show", "-s", "--format=%cI", sha]) do
      {:ok, out} -> String.trim(out)
      {:error, _reason} -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp parse_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  defp source_repo do
    case git(["config", "--get", "remote.origin.url"]) do
      {:ok, output} -> String.trim(output)
      {:error, _reason} -> nil
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
