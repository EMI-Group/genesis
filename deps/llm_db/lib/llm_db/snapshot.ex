defmodule LLMDB.Snapshot do
  @moduledoc """
  Canonical snapshot artifact helpers.

  Snapshots are the immutable unit of metadata publication and runtime loading.
  They are stored as a single `snapshot.json` file, addressed by `snapshot_id`,
  and optionally mirrored to GitHub Releases.
  """

  @schema_version 1
  @default_packaged_path "priv/llm_db/snapshot.json"
  @default_build_dir Path.join(["_build", "llm_db", "snapshot"])
  @snapshot_filename "snapshot.json"
  @snapshot_meta_filename "snapshot-meta.json"
  @latest_filename "latest.json"
  @snapshot_index_filename "snapshot-index.json"
  @history_meta_filename "history-meta.json"
  @history_archive_filename "history.tar.gz"

  @hash_excluded_keys MapSet.new([
                        "snapshot_id",
                        "generated_at",
                        "captured_at",
                        "published_at",
                        "parent_snapshot_id",
                        "provider_count",
                        "model_count",
                        "tag",
                        "snapshot_url",
                        "snapshot_meta_url",
                        "history_url"
                      ])

  @provider_id_regex ~r/^[a-z0-9][a-z0-9_:-]{0,63}$/

  @doc """
  Returns the canonical snapshot schema version.
  """
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Returns the packaged snapshot file path.
  """
  @spec packaged_path() :: String.t()
  def packaged_path do
    case Application.get_env(:llm_db, :snapshot_path) do
      nil -> Application.app_dir(:llm_db, @default_packaged_path)
      path -> expand_path(path)
    end
  end

  @doc """
  Returns the source-tree packaged snapshot path used for release packaging.
  """
  @spec source_packaged_path() :: String.t()
  def source_packaged_path do
    Path.expand(@default_packaged_path)
  end

  @doc """
  Returns the local build output directory for snapshots.
  """
  @spec build_dir() :: String.t()
  def build_dir do
    Application.get_env(:llm_db, :snapshot_build_dir, @default_build_dir)
    |> expand_path()
  end

  @doc """
  Returns the default build artifact path for `snapshot.json`.
  """
  @spec build_path() :: String.t()
  def build_path, do: Path.join(build_dir(), @snapshot_filename)

  @doc """
  Returns the default build artifact path for `snapshot-meta.json`.
  """
  @spec build_meta_path() :: String.t()
  def build_meta_path, do: Path.join(build_dir(), @snapshot_meta_filename)

  @spec snapshot_filename() :: String.t()
  def snapshot_filename, do: @snapshot_filename

  @spec snapshot_meta_filename() :: String.t()
  def snapshot_meta_filename, do: @snapshot_meta_filename

  @spec latest_filename() :: String.t()
  def latest_filename, do: @latest_filename

  @spec snapshot_index_filename() :: String.t()
  def snapshot_index_filename, do: @snapshot_index_filename

  @spec history_meta_filename() :: String.t()
  def history_meta_filename, do: @history_meta_filename

  @spec history_archive_filename() :: String.t()
  def history_archive_filename, do: @history_archive_filename

  @doc """
  Builds a canonical snapshot document from an engine snapshot.
  """
  @spec from_engine_snapshot(map()) :: map()
  def from_engine_snapshot(%{version: version, generated_at: generated_at, providers: providers}) do
    snapshot = %{
      "schema_version" => @schema_version,
      "version" => version,
      "generated_at" => generated_at,
      "providers" => json_safe(providers)
    }

    Map.put(snapshot, "snapshot_id", snapshot_id(snapshot))
  end

  @doc """
  Computes the content-addressed snapshot ID for a snapshot document.
  """
  @spec snapshot_id(map()) :: String.t()
  def snapshot_id(snapshot) when is_map(snapshot) do
    snapshot
    |> hash_payload()
    |> canonical_digest_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Returns provider/model counts for a snapshot document.
  """
  @spec counts(map()) :: %{provider_count: non_neg_integer(), model_count: non_neg_integer()}
  def counts(snapshot) when is_map(snapshot) do
    providers = provider_map(snapshot)

    model_count =
      providers
      |> Map.values()
      |> Enum.map(fn provider ->
        provider
        |> Map.get("models", %{})
        |> map_size()
      end)
      |> Enum.sum()

    %{provider_count: map_size(providers), model_count: model_count}
  end

  @doc """
  Builds snapshot metadata suitable for `snapshot-index.json` and `latest.json`.
  """
  @spec metadata(map(), map()) :: map()
  def metadata(snapshot, attrs \\ %{}) when is_map(snapshot) and is_map(attrs) do
    %{provider_count: provider_count, model_count: model_count} = counts(snapshot)

    attrs
    |> Enum.into(%{
      "schema_version" => @schema_version,
      "snapshot_id" => snapshot["snapshot_id"] || snapshot_id(snapshot),
      "captured_at" => snapshot["generated_at"],
      "provider_count" => provider_count,
      "model_count" => model_count
    })
  end

  @doc """
  Encodes a snapshot or metadata document as pretty JSON.
  """
  @spec encode(map()) :: String.t()
  def encode(document) when is_map(document) do
    document
    |> json_safe()
    |> canonical_json_map()
    |> Jason.encode!(pretty: true)
  end

  @doc """
  Decodes and verifies a snapshot document from JSON.
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(content) when is_binary(content) do
    with {:ok, snapshot} <- Jason.decode(content),
         :ok <- verify(snapshot) do
      {:ok, snapshot}
    end
  end

  @doc """
  Reads and verifies a snapshot document from disk.
  """
  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, content} <- File.read(path) do
      decode(content)
    end
  end

  @doc """
  Writes a snapshot or metadata document to disk.
  """
  @spec write!(String.t(), map()) :: :ok
  def write!(path, document) when is_binary(path) and is_map(document) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, encode(document))
  end

  @doc """
  Verifies snapshot integrity and provider ID safety.
  """
  @spec verify(map()) :: :ok | {:error, term()}
  def verify(snapshot) when is_map(snapshot) do
    with :ok <- verify_snapshot_id(snapshot),
         :ok <- validate_provider_ids(snapshot) do
      :ok
    end
  end

  defp verify_snapshot_id(%{"snapshot_id" => embedded_id} = snapshot)
       when is_binary(embedded_id) do
    computed_id = snapshot_id(snapshot)

    if embedded_id == computed_id do
      :ok
    else
      {:error, {:snapshot_id_mismatch, expected: embedded_id, computed: computed_id}}
    end
  end

  defp verify_snapshot_id(_snapshot), do: {:error, :missing_snapshot_id}

  defp validate_provider_ids(snapshot) do
    providers = provider_map(snapshot)

    case Enum.find(providers, fn {provider_id, provider} ->
           provider_id_str = to_string(provider_id)
           provider_doc_id = provider["id"] || provider[:id]

           not String.match?(provider_id_str, @provider_id_regex) or
             not is_binary(provider_doc_id) or provider_doc_id != provider_id_str
         end) do
      nil -> :ok
      {provider_id, _provider} -> {:error, {:invalid_provider_id, provider_id}}
    end
  end

  defp provider_map(%{"providers" => providers}) when is_map(providers), do: providers
  defp provider_map(%{providers: providers}) when is_map(providers), do: providers
  defp provider_map(_snapshot), do: %{}

  defp hash_payload(snapshot) do
    snapshot
    |> json_safe()
    |> Enum.reject(fn {key, _value} -> MapSet.member?(@hash_excluded_keys, key) end)
    |> Map.new()
  end

  defp json_safe(%LLMDB.Provider{} = value) do
    value
    |> Map.from_struct()
    |> drop_empty_snapshot_fields(runtime: nil, catalog_only: false)
    |> json_safe()
  end

  defp json_safe(%LLMDB.Model{} = value) do
    value
    |> Map.from_struct()
    |> drop_empty_snapshot_fields(doc_url: nil, execution: nil, catalog_only: false)
    |> json_safe()
  end

  defp json_safe(%_{} = value) do
    value
    |> Map.from_struct()
    |> json_safe()
  end

  defp json_safe(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} -> {normalize_key(key), json_safe(nested_value)} end)
    |> Map.new()
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp json_safe(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp canonical_json_map(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _nested} -> key end)
    |> Enum.map(fn {key, nested} -> {key, canonical_json_map(nested)} end)
    |> Map.new()
  end

  defp canonical_json_map(value) when is_list(value), do: Enum.map(value, &canonical_json_map/1)
  defp canonical_json_map(value), do: value

  defp canonical_digest_term(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested} -> {key, canonical_digest_term(nested)} end)
      |> Enum.sort_by(fn {key, _nested} -> key end)

    {:map, entries}
  end

  defp canonical_digest_term(value) when is_list(value) do
    {:list, Enum.map(value, &canonical_digest_term/1)}
  end

  defp canonical_digest_term(value), do: value

  defp drop_empty_snapshot_fields(map, fields) when is_map(map) and is_list(fields) do
    Enum.reduce(fields, map, fn {key, empty_value}, acc ->
      if Map.get(acc, key) == empty_value do
        Map.delete(acc, key)
      else
        acc
      end
    end)
  end

  defp expand_path(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path)
    end
  end
end
