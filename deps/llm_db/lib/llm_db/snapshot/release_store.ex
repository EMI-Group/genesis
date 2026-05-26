defmodule LLMDB.Snapshot.ReleaseStore do
  @moduledoc """
  GitHub Releases-backed snapshot artifact store.

  Runtime fetching resolves immutable snapshot and history releases via the
  GitHub Releases API and downloads public assets via Req. Publishing is
  handled with the `gh` CLI, intended for local maintainer workflows and
  GitHub Actions.
  """

  alias LLMDB.Snapshot

  @default_repo "agentjido/llm_db"
  @default_index_tag "catalog-index"
  @default_cache_dir Path.join(["tmp", "llm_db", "snapshot_cache"])
  @github_api_version "2022-11-28"
  @release_page_size 100
  @max_release_pages 10

  @type config :: %{
          repo: String.t(),
          index_tag: String.t(),
          cache_dir: String.t()
        }

  @spec config(keyword() | map()) :: config()
  def config(overrides \\ []) do
    app_config =
      Application.get_env(:llm_db, :snapshot_store, [])
      |> Enum.into(%{})

    override_map =
      cond do
        is_map(overrides) -> overrides
        Keyword.keyword?(overrides) -> Enum.into(overrides, %{})
        true -> %{}
      end

    merged = Map.merge(app_config, override_map)

    %{
      repo: Map.get(merged, :repo, Map.get(merged, "repo", @default_repo)),
      index_tag: Map.get(merged, :index_tag, Map.get(merged, "index_tag", @default_index_tag)),
      cache_dir:
        Map.get(merged, :cache_dir, Map.get(merged, "cache_dir", @default_cache_dir))
        |> expand_path()
    }
  end

  @spec snapshot_tag(String.t()) :: String.t()
  def snapshot_tag(snapshot_id), do: release_tag("snapshot", snapshot_id)

  @spec history_tag(String.t()) :: String.t()
  def history_tag(snapshot_id), do: release_tag("history", snapshot_id)

  @spec asset_url(String.t(), String.t(), keyword() | map()) :: String.t()
  def asset_url(tag, filename, overrides \\ %{}) do
    cfg = config(overrides)
    release_asset_url(cfg.repo, tag, filename)
  end

  @spec snapshot_asset_url(String.t(), keyword() | map()) :: String.t() | nil
  def snapshot_asset_url(snapshot_id, overrides \\ %{}) do
    case find_snapshot_entry(snapshot_id, overrides) do
      {:ok, entry} -> entry["snapshot_url"]
      _ -> nil
    end
  end

  @spec snapshot_meta_asset_url(String.t(), keyword() | map()) :: String.t() | nil
  def snapshot_meta_asset_url(snapshot_id, overrides \\ %{}) do
    case find_snapshot_entry(snapshot_id, overrides) do
      {:ok, entry} -> entry["snapshot_meta_url"]
      _ -> nil
    end
  end

  @spec history_archive_asset_url(String.t(), keyword() | map()) :: String.t() | nil
  def history_archive_asset_url(snapshot_id, overrides \\ %{}) do
    case find_history_entry(snapshot_id, overrides) do
      {:ok, entry} -> entry["history_url"]
      _ -> nil
    end
  end

  @spec history_meta_asset_url(String.t(), keyword() | map()) :: String.t() | nil
  def history_meta_asset_url(snapshot_id, overrides \\ %{}) do
    case find_history_entry(snapshot_id, overrides) do
      {:ok, entry} -> entry["history_meta_url"]
      _ -> nil
    end
  end

  @spec fetch_latest(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def fetch_latest(overrides \\ %{}) do
    with {:ok, snapshots} <- fetch_snapshot_index(overrides),
         latest when is_map(latest) <- List.last(snapshots) do
      {:ok, latest}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @spec fetch_snapshot_index(keyword() | map()) :: {:ok, [map()]} | {:error, term()}
  def fetch_snapshot_index(overrides \\ %{}) do
    with {:ok, releases} <- list_releases(config(overrides).repo) do
      releases
      |> Enum.filter(&snapshot_release?/1)
      |> build_entries(&snapshot_entry_from_release/1)
      |> case do
        {:ok, entries} ->
          sorted =
            entries
            |> sort_by_identity(&snapshot_identity/1)
            |> dedupe_by(& &1["snapshot_id"])
            |> sort_by_identity(&snapshot_identity/1)

          {:ok, sorted}

        error ->
          error
      end
    end
  end

  @spec fetch_history_meta(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def fetch_history_meta(overrides \\ %{}) do
    with {:ok, latest} <- fetch_latest(overrides),
         snapshot_id when is_binary(snapshot_id) <- latest["snapshot_id"],
         {:ok, entry} <- find_history_entry(snapshot_id, overrides),
         meta_url when is_binary(meta_url) <- entry["history_meta_url"] do
      fetch_json(meta_url)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @spec fetch_snapshot(:latest | String.t(), keyword() | map()) ::
          {:ok, %{snapshot: map(), snapshot_id: String.t(), path: String.t()}} | {:error, term()}
  def fetch_snapshot(ref, overrides \\ %{})

  def fetch_snapshot(:latest, overrides) do
    with {:ok, latest} <- fetch_latest(overrides),
         snapshot_id when is_binary(snapshot_id) <- latest["snapshot_id"] do
      fetch_snapshot(snapshot_id, overrides)
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_latest_snapshot}
    end
  end

  def fetch_snapshot(snapshot_id, overrides) when is_binary(snapshot_id) do
    cfg = config(overrides)
    path = cached_snapshot_path(snapshot_id, cfg)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, snapshot} <- maybe_read_cached_snapshot(path, snapshot_id) do
      {:ok, %{snapshot: snapshot, snapshot_id: snapshot_id, path: path}}
    else
      {:error, :cache_miss} ->
        with {:ok, entry} <- find_snapshot_entry(snapshot_id, overrides),
             snapshot_url when is_binary(snapshot_url) <- entry["snapshot_url"],
             {:ok, content} <- download(snapshot_url),
             {:ok, snapshot} <- Snapshot.decode(content),
             ^snapshot_id <- snapshot["snapshot_id"] do
          File.write!(path, Snapshot.encode(snapshot))
          {:ok, %{snapshot: snapshot, snapshot_id: snapshot_id, path: path}}
        else
          nil ->
            {:error, :not_found}

          mismatch when is_binary(mismatch) ->
            {:error, {:snapshot_id_mismatch, expected: snapshot_id, got: mismatch}}

          error ->
            error
        end

      error ->
        error
    end
  end

  @spec download_history_archive(String.t(), keyword() | map()) :: :ok | {:error, term()}
  def download_history_archive(destination, overrides \\ %{}) when is_binary(destination) do
    with {:ok, latest} <- fetch_latest(overrides),
         snapshot_id when is_binary(snapshot_id) <- latest["snapshot_id"],
         {:ok, entry} <- find_history_entry(snapshot_id, overrides),
         history_url when is_binary(history_url) <- entry["history_url"],
         {:ok, content} <- download(history_url) do
      destination
      |> Path.dirname()
      |> File.mkdir_p!()

      File.write!(destination, content)
      :ok
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @spec ensure_snapshot_release(String.t(), String.t(), String.t(), keyword() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_snapshot_release(snapshot_path, meta_path, snapshot_id, overrides \\ %{}) do
    with :ok <- ensure_gh_available(),
         {:ok, asset_paths} <- validate_asset_paths([snapshot_path, meta_path]) do
      case find_snapshot_entry(snapshot_id, overrides) do
        {:ok, entry} ->
          {:ok, entry["tag"]}

        {:error, :not_found} ->
          create_release(
            snapshot_tag(snapshot_id),
            config(overrides).repo,
            "Snapshot #{snapshot_id}",
            asset_paths
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec publish_history_release([String.t()], String.t(), keyword() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def publish_history_release(asset_paths, snapshot_id, overrides \\ %{})
      when is_list(asset_paths) and is_binary(snapshot_id) do
    with :ok <- ensure_gh_available(),
         {:ok, asset_paths} <- validate_asset_paths(asset_paths) do
      case find_history_entry(snapshot_id, overrides) do
        {:ok, entry} ->
          {:ok, entry["tag"]}

        {:error, :not_found} ->
          create_release(
            history_tag(snapshot_id),
            config(overrides).repo,
            "History #{snapshot_id}",
            asset_paths
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_read_cached_snapshot(path, expected_snapshot_id) do
    case Snapshot.read(path) do
      {:ok, %{"snapshot_id" => ^expected_snapshot_id} = snapshot} -> {:ok, snapshot}
      _ -> {:error, :cache_miss}
    end
  end

  defp cached_snapshot_path(snapshot_id, %{cache_dir: cache_dir}) do
    Path.join([cache_dir, "snapshots", "#{snapshot_id}.json"])
  end

  defp find_snapshot_entry(snapshot_id, overrides) do
    with {:ok, entries} <- snapshot_entries(overrides),
         %{} = entry <- Enum.find(entries, &(&1["snapshot_id"] == snapshot_id)) do
      {:ok, entry}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp snapshot_entries(overrides) do
    case override_entries(overrides, :snapshot_index) do
      {:ok, entries} -> {:ok, entries}
      :none -> fetch_snapshot_index(overrides)
    end
  end

  defp find_history_entry(snapshot_id, overrides) do
    with {:ok, entries} <- history_entries(overrides),
         %{} = entry <- Enum.find(entries, &(&1["to_snapshot_id"] == snapshot_id)) do
      {:ok, entry}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp history_entries(overrides) do
    case override_entries(overrides, :history_entries) do
      {:ok, entries} ->
        {:ok, entries}

      :none ->
        with {:ok, releases} <- list_releases(config(overrides).repo) do
          releases
          |> Enum.filter(&history_release?/1)
          |> build_entries(&history_entry_from_release/1)
          |> case do
            {:ok, entries} ->
              sorted =
                entries
                |> sort_by_identity(&history_identity/1)
                |> dedupe_by(& &1["to_snapshot_id"])
                |> sort_by_identity(&history_identity/1)

              {:ok, sorted}

            error ->
              error
          end
        end
    end
  end

  defp override_entries(overrides, key) do
    override_map =
      cond do
        is_map(overrides) -> overrides
        Keyword.keyword?(overrides) -> Enum.into(overrides, %{})
        true -> %{}
      end

    case Map.fetch(override_map, key) do
      {:ok, entries} when is_list(entries) -> {:ok, entries}
      :error -> :none
      {:ok, _other} -> {:error, {:invalid_override_entries, key}}
    end
  end

  defp build_entries(releases, loader) do
    Enum.reduce_while(releases, {:ok, []}, fn release, {:ok, acc} ->
      case loader.(release) do
        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, entry} ->
          {:cont, {:ok, [entry | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp sort_by_identity(entries, identity_fun) do
    Enum.sort_by(entries, identity_fun)
  end

  defp dedupe_by(entries, key_fun) do
    entries
    |> Enum.reduce(%{}, fn entry, acc ->
      Map.put(acc, key_fun.(entry), entry)
    end)
    |> Map.values()
  end

  defp snapshot_identity(entry) do
    {
      entry["captured_at"] || "",
      entry["published_at"] || "",
      entry["snapshot_id"] || "",
      entry["tag"] || ""
    }
  end

  defp history_identity(entry) do
    {
      entry["generated_at"] || "",
      entry["published_at"] || "",
      entry["to_snapshot_id"] || "",
      entry["tag"] || ""
    }
  end

  defp snapshot_release?(%{"tag_name" => "snapshot-" <> _rest}), do: true
  defp snapshot_release?(%{tag_name: "snapshot-" <> _rest}), do: true
  defp snapshot_release?(_release), do: false

  defp history_release?(%{"tag_name" => "history-" <> _rest}), do: true
  defp history_release?(%{tag_name: "history-" <> _rest}), do: true
  defp history_release?(_release), do: false

  defp snapshot_entry_from_release(release) do
    snapshot_url = release_asset_download_url(release, Snapshot.snapshot_filename())
    meta_url = release_asset_download_url(release, Snapshot.snapshot_meta_filename())

    cond do
      is_nil(snapshot_url) or is_nil(meta_url) ->
        {:ok, nil}

      true ->
        with {:ok, meta} <- fetch_json(meta_url),
             snapshot_id when is_binary(snapshot_id) <- meta["snapshot_id"] do
          entry =
            meta
            |> Map.put_new("published_at", release_published_at(release))
            |> Map.put("snapshot_url", snapshot_url)
            |> Map.put("snapshot_meta_url", meta_url)
            |> Map.put("tag", release_tag_name(release))

          {:ok, entry}
        else
          _ -> {:error, {:invalid_snapshot_release, release_tag_name(release)}}
        end
    end
  end

  defp history_entry_from_release(release) do
    archive_url = release_asset_download_url(release, Snapshot.history_archive_filename())
    meta_url = release_asset_download_url(release, Snapshot.history_meta_filename())

    cond do
      is_nil(archive_url) or is_nil(meta_url) ->
        {:ok, nil}

      true ->
        with {:ok, meta} <- fetch_json(meta_url),
             snapshot_id when is_binary(snapshot_id) <- meta["to_snapshot_id"] do
          entry =
            meta
            |> Map.put_new("published_at", release_published_at(release))
            |> Map.put("history_url", archive_url)
            |> Map.put("history_meta_url", meta_url)
            |> Map.put("tag", release_tag_name(release))

          {:ok, entry}
        else
          _ -> {:error, {:invalid_history_release, release_tag_name(release)}}
        end
    end
  end

  defp release_asset_download_url(%{"assets" => assets}, filename) when is_list(assets) do
    Enum.find_value(assets, fn asset ->
      case asset do
        %{"name" => ^filename, "browser_download_url" => url} -> url
        %{"name" => ^filename, "url" => url} -> url
        _ -> nil
      end
    end)
  end

  defp release_asset_download_url(_release, _filename), do: nil

  defp release_tag_name(%{"tag_name" => tag}), do: tag
  defp release_tag_name(%{tag_name: tag}), do: tag

  defp release_published_at(%{"published_at" => published_at}), do: published_at
  defp release_published_at(%{published_at: published_at}), do: published_at
  defp release_published_at(_release), do: nil

  @spec fetch_json(String.t()) :: {:ok, term()} | {:error, term()}
  defp fetch_json(url) do
    with {:ok, content} <- download(url),
         {:ok, decoded} <- Jason.decode(content) do
      {:ok, decoded}
    end
  end

  @spec download(String.t()) :: {:ok, binary()} | {:error, term()}
  defp download(url) do
    :ok = ensure_http_started()

    case Req.get(url) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_gh_available do
    case System.find_executable("gh") do
      nil -> {:error, "gh CLI is required to publish snapshot artifacts"}
      _ -> :ok
    end
  end

  defp validate_asset_paths(paths) do
    case Enum.filter(paths, &File.exists?/1) do
      [] -> {:error, :no_release_assets}
      existing_paths -> {:ok, existing_paths}
    end
  end

  defp create_release(tag, repo, title, asset_paths) do
    args =
      ["release", "create", tag]
      |> Kernel.++(asset_paths)
      |> Kernel.++(["--repo", repo, "--title", title, "--notes", ""])

    case run_gh(args) do
      {:ok, _output} -> {:ok, tag}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_releases(repo) do
    do_list_releases(repo, 1, [])
  end

  defp do_list_releases(repo, page, acc) when page <= @max_release_pages do
    url = "https://api.github.com/repos/#{repo}/releases"

    case api_get_json(url, params: [per_page: @release_page_size, page: page]) do
      {:ok, releases} when is_list(releases) ->
        next_acc = acc ++ releases

        if length(releases) < @release_page_size do
          {:ok, next_acc}
        else
          do_list_releases(repo, page + 1, next_acc)
        end

      {:ok, other} ->
        {:error, {:invalid_release_list, other}}

      error ->
        error
    end
  end

  defp do_list_releases(_repo, _page, acc), do: {:ok, acc}

  defp api_get_json(url, opts) do
    :ok = ensure_http_started()

    req_opts = api_request_options(opts)

    case Req.get(url, req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp api_request_options(opts) do
    headers =
      [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", @github_api_version},
        {"user-agent", "llm_db"}
      ]
      |> maybe_add_auth_header()

    opts
    |> Keyword.put(:headers, headers)
    |> Keyword.put_new(:decode_body, true)
  end

  defp maybe_add_auth_header(headers) do
    case System.get_env("GH_TOKEN") || System.get_env("GITHUB_TOKEN") do
      nil -> headers
      token -> [{"authorization", "Bearer #{token}"} | headers]
    end
  end

  defp run_gh(args) do
    case System.cmd("gh", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @spec ensure_http_started() :: :ok
  defp ensure_http_started do
    case Application.ensure_all_started(:req) do
      {:ok, _apps} -> :ok
      {:error, {:already_started, _app}} -> :ok
      {:error, reason} -> raise "failed to start req application: #{inspect(reason)}"
    end
  end

  defp release_asset_url(repo, tag, filename) do
    "https://github.com/#{repo}/releases/download/#{tag}/#{filename}"
  end

  defp release_tag(kind, snapshot_id) do
    short_id = snapshot_id |> String.slice(0, 12)
    suffix = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    "#{kind}-#{short_id}-#{suffix}"
  end

  defp expand_path(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path)
    end
  end
end
