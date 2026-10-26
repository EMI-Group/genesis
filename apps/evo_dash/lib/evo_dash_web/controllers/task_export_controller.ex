defmodule EvoDashWeb.TaskExportController do
  use EvoDashWeb, :controller
  use Gettext, backend: EvoDashWeb.Gettext

  require Logger

  alias EvoDash.SafeCall

  # One archive page per read. The core clamps `:limit` to 1..1000; 200 keeps
  # each RPC response small while still covering a big task in a few round trips.
  @page_limit 200

  @doc """
  Streams a task's agent archive as a JSON attachment (`GET /tasks/:task_id/export`).

  Node-aware (`?node=<id>`), paged and memory-bounded: the task itself is read
  through the LITE projection (no archive column) and the archive is paged
  through `NodeContext.list_task_archives/3`, then written record by record to a
  temp file that is sent with `send_download/3`. Nothing ever holds the whole
  archive in memory.
  """
  @spec export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def export(conn, %{"task_id" => task_id}) do
    case resolve_node(conn) do
      {:ok, node} -> export_task(conn, node, task_id)
      :error -> not_found(conn, gettext("Task not found"))
    end
  end

  defp export_task(conn, node, task_id) do
    case fetch_task(node, task_id) do
      nil -> not_found(conn, gettext("Task not found"))
      task -> stream_archive(conn, node, task, task_id)
    end
  end

  # Writes the archive to a temp file, then streams it out. `{:ok, path, 0}`
  # covers BOTH a genuinely empty archive and a first page that could not be
  # read (see `write_pages/6`): an unreadable archive degrades to "stop paging",
  # which with nothing accumulated is indistinguishable from an empty archive.
  defp stream_archive(conn, node, task, task_id) do
    case write_archive_file(node, task, task_id) do
      {:ok, path, 0} ->
        File.rm(path)
        not_found(conn, gettext("No archive data available for this task"))

      {:ok, path, record_count} ->
        Logger.debug(fn ->
          "Task archive export: streaming #{record_count} records for task #{task_id}"
        end)

        send_archive(conn, path, task_id)

      {:error, reason} ->
        Logger.warning("Task archive export failed for task #{task_id}: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> send_resp(500, gettext("Archive export failed"))
        |> halt()
    end
  end

  defp not_found(conn, message) do
    conn
    |> put_status(:not_found)
    |> send_resp(404, message)
    |> halt()
  end

  # ── Sending the temp file ──────────────────────────────────────────

  # `send_download/3` returns only AFTER the adapter has written the response
  # body: Bandit hands the file to `Bandit.HTTPTransport.sendfile/4`, which
  # completes the socket write before returning, and the test adapter reads the
  # file eagerly; either way `conn.state` is `:sent` when we get the conn back.
  # The file is therefore consumed, so deleting it in `after` cannot truncate a
  # response — and `after` also covers the raise paths (e.g. an already-sent
  # conn), so no temp file leaks.
  defp send_archive(conn, path, task_id) do
    try do
      send_download(conn, {:file, path},
        filename: "archive-#{task_id}.json",
        content_type: "application/json"
      )
    after
      File.rm(path)
    end
  end

  # ── Node resolution ────────────────────────────────────────────────

  # Resolves the node the client is viewing. Without a `?node=` param (or with
  # `?node=local`) the export reads the LOCAL runtime — the historical behavior.
  # With a `?node=<id>` param for a connected target, both reads run on the
  # remote daemon via RPC. Unknown targets, targets that are not `:connected`,
  # and unavailable connection subsystems all resolve to `:error` → 404, exactly
  # like the local not-found path.
  defp resolve_node(conn) do
    case conn.query_params["node"] do
      nil -> {:ok, node()}
      "local" -> {:ok, node()}
      node_id -> resolve_remote_node(node_id)
    end
  end

  # Mirrors `EvoDashWeb.LiveHooks.NodeAware.resolve_node_context/1`
  # (node_aware.ex): the node name comes from the connection manager's status
  # map and is converted to an atom the same way.
  defp resolve_remote_node(node_id) do
    with {:ok, target} <- EvoDash.NodeContext.get_target(node_id),
         %{phase: :connected, node: remote_node} when is_binary(remote_node) <-
           EvoDash.NodeContext.connection_status(target.id) do
      {:ok, String.to_atom(remote_node)}
    else
      _ -> :error
    end
  end

  # ── Reads (test-seamable) ──────────────────────────────────────────

  # A dead store / RPC cannot kill the controller: `SafeCall.run/1` turns an
  # exit (GenServer.call timeout) or exception into an error value. A failed
  # task read degrades to `nil` → the historical 404 "Task not found".
  defp fetch_task(node, task_id) do
    runner =
      Application.get_env(
        :evo_dash,
        :task_export_task_runner,
        &EvoDash.NodeContext.get_task_lite/2
      )

    case SafeCall.run(fn -> runner.(node, task_id) end) do
      {:ok, nil} -> nil
      {:ok, task} -> task
      {:error, _reason} -> nil
    end
  end

  # Same boundary for one archive page. A failed page is degraded to "stop
  # paging" by `write_pages/6` — the export still produces a valid (possibly
  # truncated, or empty → 404) document instead of a 500.
  defp fetch_page(node, task_id, offset) do
    runner =
      Application.get_env(
        :evo_dash,
        :task_export_archive_runner,
        &EvoDash.NodeContext.list_task_archives/3
      )

    opts = [offset: offset, limit: @page_limit, include_results: true]

    case SafeCall.run(fn -> runner.(node, task_id, opts) end) do
      {:ok, %{entries: entries, total: total}} when is_list(entries) ->
        {:ok, entries, total}

      {:ok, other} ->
        {:error, {:invalid_page, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Writing the JSON document ──────────────────────────────────────

  defp write_archive_file(node, task, task_id) do
    path =
      Path.join(
        System.tmp_dir!(),
        "archive-#{task_id}-#{System.unique_integer([:positive])}.json"
      )

    # The callback form closes the device on every path, including a raise.
    case File.open(path, [:write, :binary], fn io -> write_document(io, node, task, task_id) end) do
      {:ok, {:ok, record_count}} ->
        {:ok, path, record_count}

      {:ok, {:error, reason}} ->
        File.rm(path)
        {:error, reason}

      {:error, reason} ->
        {:error, {:temp_file, reason}}
    end
  end

  # Fixed head fields → `,"archive_records":[` → one encoded record at a time →
  # `]}`. Only ONE record (and one page) is in memory at any moment.
  defp write_document(io, node, task, task_id) do
    with {:ok, head} <- head_json(task),
         :ok <- IO.binwrite(io, head),
         {:ok, record_count} <- write_pages(io, node, task_id, 0, 0, nil),
         :ok <- IO.binwrite(io, "]}\n") do
      {:ok, record_count}
    end
  end

  # The envelope head — the SAME flat keys as before, just without
  # `archive_records` (streamed afterwards). Jason encodes the object in one go,
  # so its single closing brace is dropped here and re-emitted by the final
  # `]}` write (the head is a few hundred bytes, never the archive). The
  # non-bang encoder keeps an unencodable head a VALUE, so the temp file is
  # cleaned up and the client gets a 500 instead of a raise escaping the
  # controller.
  defp head_json(task) do
    head = %{
      task_id: task.id,
      task_type: task.type,
      repo_path: task.opts[:path],
      status: task.status,
      started_at: task.started_at,
      finished_at: task.finished_at,
      agent_count: task.agent_count,
      usage: task.usage
    }

    with {:ok, json} <- Jason.encode_to_iodata(normalize_for_json(head)) do
      head_json =
        json
        |> IO.iodata_to_binary()
        |> String.replace_suffix("}", "")

      {:ok, [head_json, ~s(,"archive_records":[)]}
    end
  end

  # Paged until the accumulated count reaches `total` or a page comes back
  # empty (hard stop — the loop can never spin forever). `total` is nil until
  # the first page reports it.
  defp write_pages(_io, _node, _task_id, _offset, written, total)
       when is_integer(total) and written >= total do
    {:ok, written}
  end

  defp write_pages(io, node, task_id, offset, written, _total) do
    case fetch_page(node, task_id, offset) do
      {:ok, [], _page_total} ->
        {:ok, written}

      {:ok, entries, page_total} ->
        entries = take_remaining(entries, written, page_total)

        with {:ok, written} <- write_records(io, entries, written) do
          write_pages(io, node, task_id, offset + length(entries), written, page_total)
        end

      {:error, reason} ->
        # Degradation: a failed page STOPS the paging loop and keeps whatever was
        # already written — a mid-export RPC failure still yields a valid JSON
        # document. With nothing accumulated the caller answers the empty-archive
        # 404 (see `stream_archive/4`).
        Logger.warning(
          "Task archive export: page at offset #{offset} failed for task #{task_id} " <>
            "(#{inspect(reason)}); stopping at #{written} records"
        )

        {:ok, written}
    end
  end

  # Never emit more records than the archive reports having. A `total` of 0 with
  # a non-empty page means a degraded total (the core falls back to 0), so the
  # whole page is kept in that case.
  defp take_remaining(entries, written, total) when is_integer(total) and total > written do
    Enum.take(entries, total - written)
  end

  defp take_remaining(entries, _written, _total), do: entries

  # Records are encoded and written ONE AT A TIME. `Jason.encode_to_iodata/1`
  # (non-bang) is used so an unencodable record becomes a `{:error, reason}`
  # value — the temp file is then deleted and the client gets a 500 — instead of
  # a raise escaping the controller.
  defp write_records(io, entries, written) do
    leading_separator = if written == 0, do: "", else: ","

    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, written}, fn {entry, index}, {:ok, count} ->
      separator = if index == 0, do: leading_separator, else: ","

      with {:ok, json} <- Jason.encode_to_iodata(normalize_for_json(entry)),
           :ok <- IO.binwrite(io, [separator, json]) do
        {:cont, {:ok, count + 1}}
      else
        {:error, reason} -> {:halt, {:error, {:record_encode_or_write, reason}}}
      end
    end)
  end

  # ── JSON normalization ─────────────────────────────────────────────

  # Recursively normalize a structure into plain maps/lists/strings/numbers
  # so Jason can encode it. Handles structs (via Map.from_struct/1),
  # DateTimes (via DateTime.to_iso8601/1), and nested maps/lists.
  defp normalize_for_json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_for_json(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)

  defp normalize_for_json(%{__struct__: _} = struct) do
    struct |> Map.from_struct() |> normalize_for_json()
  end

  defp normalize_for_json(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_for_json(v)} end)
  end

  defp normalize_for_json(list) when is_list(list) do
    Enum.map(list, &normalize_for_json/1)
  end

  # Tuples -> list (Jason cannot encode tuples directly)
  defp normalize_for_json(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> normalize_for_json()
  end

  # Un-serializable terms (PIDs, references, ports, functions) -> string fallback
  defp normalize_for_json(value)
       when is_pid(value) or is_reference(value) or is_port(value) or is_function(value) do
    inspect(value)
  end

  defp normalize_for_json(value), do: value
end
