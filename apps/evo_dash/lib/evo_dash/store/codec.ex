defmodule EvoDash.Store.Codec do
  @moduledoc """
  Pure serialization functions for the EvoDash SQLite store.

  This module has NO GenServer and NO I/O.

  ## Encode philosophy

  Encode functions are TOTAL — they never raise. All JSON encoding uses the
  non-crashing `Jason.encode/1` (returns `{:ok, json} | {:error, exception}`)
  with `case`/`with` to choose fallbacks. There are NO `try/rescue` blocks in
  the encode functions.

  ## Decode philosophy

  Decode functions raise on bad data — the Store's quarantine logic handles
  crash recovery by moving undecodable rows to a quarantine table.

  Two justified `try/rescue` patterns remain on the decode side:

    * `decode_reason/1` — best-effort atom recovery. `String.to_existing_atom/1`
      has no non-crashing variant; an unknown reason string legitimately stays
      a string (it's a valid alternative representation, not "bad data").
    * `decode_pid/1` — untrusted DB-stored pid strings. `:erlang.list_to_pid/1`
      has no non-crashing variant; pid strings are always stale after a VM
      restart, and returning `nil` is the correct semantic.
  """

  require Logger

  alias EvoDash.TaskInfo
  alias EvoDash.RecentProject

  @task_columns ~w(id type status opts pid started_at finished_at logs result review_status usage agent_count base_sha commit_sha archive_metadata)
  @project_columns ~w(path name last_opened_at)

  @usage_fields [
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :input_cost,
    :output_cost,
    :total_cost,
    :cached_tokens,
    :cache_creation_tokens
  ]

  # Known keys inside the {:ok, data} result map. Used for safe atomization
  # during decode (these are application-controlled, not user input).
  @result_data_fields ~w(commit_sha result tag branch_name pr_url pr_title no_changes usage agent_count archive_records)a

  ## Public — column lists

  @doc "Returns the ordered list of task column names."
  def task_columns, do: @task_columns

  @doc "Returns the ordered list of project column names."
  def project_columns, do: @project_columns

  ## Public — Encode (struct → column values)

  def encode_task(%TaskInfo{} = task) do
    [
      task.id,
      encode_atom(task.type),
      encode_atom(task.status),
      encode_opts(task.opts),
      encode_pid(task.pid),
      encode_datetime(task.started_at),
      encode_datetime(task.finished_at),
      encode_logs(task.logs),
      encode_result(task.result),
      encode_atom(task.review_status),
      encode_usage(task.usage),
      Map.get(task, :agent_count),
      Map.get(task, :base_sha),
      Map.get(task, :commit_sha),
      encode_archive(Map.get(task, :archive_metadata))
    ]
  end

  def encode_project(%RecentProject{} = project) do
    [
      project.path,
      project.name,
      encode_datetime(project.last_opened_at)
    ]
  end

  ## Public — Decode (column values → struct)

  def decode_task(row) do
    [
      id,
      type,
      status,
      opts,
      pid,
      started_at,
      finished_at,
      logs,
      result,
      review_status,
      usage,
      agent_count,
      base_sha,
      commit_sha,
      archive_metadata
    ] = row

    %TaskInfo{
      id: id,
      type: decode_atom(type),
      status: decode_atom(status) || :pending,
      opts: decode_opts(opts),
      ref: nil,
      pid: decode_pid(pid),
      started_at: decode_datetime(started_at),
      finished_at: decode_datetime(finished_at),
      logs: decode_logs(logs),
      result: decode_result(result),
      review_status: decode_atom(review_status),
      usage: decode_usage(usage),
      agent_count: agent_count,
      base_sha: base_sha,
      commit_sha: commit_sha,
      archive_metadata: decode_archive(archive_metadata)
    }
  end

  def decode_project([path, name, last_opened_at]) do
    %RecentProject{
      path: path,
      name: name,
      last_opened_at: decode_datetime(last_opened_at)
    }
  end

  ## Public — Validation

  def validate_task(%TaskInfo{id: id, status: status})
      when is_binary(id) and not is_nil(status),
      do: :ok

  def validate_task(%TaskInfo{id: nil}), do: {:error, :missing_task_id}
  def validate_task(%TaskInfo{status: nil}), do: {:error, :missing_task_status}
  def validate_task(%TaskInfo{}), do: {:error, :missing_task_id}

  def validate_project(%RecentProject{path: path}) when is_binary(path), do: :ok
  def validate_project(%RecentProject{path: nil}), do: {:error, :missing_project_path}
  def validate_project(%RecentProject{}), do: {:error, :missing_project_path}

  ## Field encoders/decoders

  # --- Atoms ---
  # Stored as TEXT in SQLite. Accepts nil, atoms, and strings so that a decoded
  # value (which may be a string) can always be re-encoded without crashing —
  # this guarantees round-trip safety.
  def encode_atom(nil), do: nil
  def encode_atom(atom) when is_atom(atom), do: Atom.to_string(atom)
  def encode_atom(str) when is_binary(str), do: str

  # The complete set of known atom values across the three atom fields:
  #   * type — :genesis, :evolve, :extract_skills
  #   * status — :pending, :running, :finalizing, :completed, :failed, :cancelled
  #   * review_status — :open, :merged, :rejected, :continued, :ignored, :no_changes
  #
  # Using String.to_atom/1 is SAFE here because the set is closed, bounded, and
  # application-controlled — not user input. This avoids the lazy-code-loading
  # bug where String.to_existing_atom/1 fails for atoms whose defining modules
  # haven't loaded yet (e.g. :merged/:rejected/:continued/:ignored before any
  # code path that references them has run). Truly unknown/corrupt values fall
  # outside the whitelist and decode to nil.
  @known_atoms ~w(
    genesis evolve extract_skills
    pending running finalizing completed failed cancelled
    open merged rejected continued ignored no_changes
  )a
  @known_atom_strings MapSet.new(@known_atoms, &Atom.to_string/1)

  def decode_atom(nil), do: nil

  def decode_atom(str) when is_binary(str) do
    if MapSet.member?(@known_atom_strings, str) do
      String.to_atom(str)
    else
      Logger.warning("Codec: unknown atom value in DB: #{inspect(str)}, returning nil")
      nil
    end
  end

  # --- DateTime ---
  def encode_datetime(nil), do: nil
  def encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  def decode_datetime(nil), do: nil

  def decode_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  # --- opts (keyword list) ---
  # Encode as a JSON array of [key_string, value] pairs to preserve keyword
  # list semantics. If Jason can't serialize the values (tuples, pids, etc.),
  # fall back to encoding just the essential keys (path, mode, prompt,
  # objective), or nil.
  #
  # Known opt keys that the application accesses — atomized safely on decode
  # via to_existing_atom/1 (these are all defined as literals in the codebase).
  # Unknown keys remain as strings to avoid blind atomization.
  @known_opt_keys ~w(path mode prompt objective foreign_repos node_path seed_content starting_commit archive task_id repo_path concurrency tool_concurrency concepts resume_from)a
  @known_opt_key_strings MapSet.new(@known_opt_keys, &Atom.to_string/1)

  def encode_opts(nil), do: nil

  def encode_opts(opts) when is_list(opts) do
    pairs =
      Enum.map(opts, fn
        {key, value} when is_atom(key) -> [Atom.to_string(key), value]
        {key, value} -> [to_string(key), value]
      end)

    case Jason.encode(pairs) do
      {:ok, json} ->
        json

      {:error, e} ->
        Logger.warning(
          "Codec: failed to encode opts fully, trying essential keys: " <>
            "#{Exception.message(e)}"
        )

        essential =
          opts
          |> Keyword.take([:path, :mode, :prompt, :objective])
          |> Enum.map(fn {key, value} -> [Atom.to_string(key), value] end)

        case Jason.encode(essential) do
          {:ok, json} ->
            json

          {:error, e2} ->
            Logger.warning(
              "Codec: failed to encode essential opts, storing nil: " <>
                "#{Exception.message(e2)}"
            )

            nil
        end
    end
  end

  def decode_opts(nil), do: nil

  def decode_opts(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, pairs} when is_list(pairs) ->
        Enum.map(pairs, fn [key_str, value] ->
          {decode_opt_key(key_str), value}
        end)

      _ ->
        nil
    end
  end

  # Known opt keys are atomized for caller convenience (Keyword.get/2 with atom
  # keys). Unknown keys stay as strings — they are never pattern-matched by key.
  def decode_opt_key(key) when is_atom(key), do: key

  def decode_opt_key(key) when is_binary(key) do
    if MapSet.member?(@known_opt_key_strings, key) do
      String.to_existing_atom(key)
    else
      key
    end
  end

  # --- logs (list of strings) ---
  def encode_logs(nil), do: "[]"

  def encode_logs(logs) when is_list(logs) do
    case Jason.encode(logs) do
      {:ok, json} -> json
      {:error, _} -> "[]"
    end
  end

  def decode_logs(nil), do: []

  def decode_logs(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, logs} when is_list(logs) -> logs
      _ -> []
    end
  end

  # --- result (runtime return tuples) ---
  # The `result` field contains runtime return values like
  # `{:ok, %{commit_sha: ..., branch_name: ..., usage: %EvoGit.Agent.Usage{}}}`
  # that the web layer pattern-matches on (tuples + atom keys).
  #
  # We encode these as JSON with a `"__result_tag__"` discriminator field so the
  # tuple shape (`{:ok, _}`, `{:error, _}`, `{:exit, _}`) can be faithfully
  # reconstructed on decode. Atom keys in the success data map are converted to
  # strings for JSON and restored to atoms on decode using the known whitelist
  # `@result_data_fields`; the embedded `%EvoGit.Agent.Usage{}` struct is
  # serialized the same way the dedicated `usage` column is.
  #
  # Plain strings (crash fallbacks) are stored as-is — they are NOT JSON-wrapped
  # — so they round-trip without any decoding.
  def encode_result(nil), do: nil

  # Plain strings (crash fallbacks) are stored as-is, not JSON-wrapped.
  def encode_result(result) when is_binary(result) do
    result
  end

  def encode_result({:ok, data}) when is_map(data) do
    json_data = encode_result_data(data)

    case Jason.encode(%{"__result_tag__" => "ok", "data" => json_data}) do
      {:ok, json} ->
        json

      {:error, e} ->
        Logger.warning("Codec: failed to encode ok-result: #{Exception.message(e)}")
        inspect({:ok, data})
    end
  end

  def encode_result({:error, reason}) do
    case Jason.encode(%{"__result_tag__" => "error", "reason" => reason}) do
      {:ok, json} ->
        json

      {:error, _} ->
        # reason may contain non-JSON-safe terms (tuples, pids, etc.).
        # inspect(reason) always produces a JSON-safe string, so encode!/1
        # can never fail here.
        Jason.encode!(%{"__result_tag__" => "error", "reason" => inspect(reason)})
    end
  end

  def encode_result({:exit, reason}) do
    case Jason.encode(%{"__result_tag__" => "exit", "reason" => reason}) do
      {:ok, json} ->
        json

      {:error, _} ->
        Jason.encode!(%{"__result_tag__" => "exit", "reason" => inspect(reason)})
    end
  end

  def encode_result(other) do
    # Any other shape — fall back to inspect so we never crash on encode.
    inspect(other)
  end

  # Converts the success data map into a string-keyed, JSON-safe map.
  # The embedded `%EvoGit.Agent.Usage{}` is serialized via Map.from_struct/1
  # (same pattern as encode_usage/1).
  def encode_result_data(data) do
    data
    |> Enum.reduce(%{}, fn
      {:usage, %EvoGit.Agent.Usage{} = usage}, acc ->
        Map.put(acc, "usage", Map.from_struct(usage))

      {key, value}, acc ->
        Map.put(acc, to_string(key), value)
    end)
  end

  def decode_result(nil), do: nil

  def decode_result(str) when is_binary(str) do
    # JSON-encoded values start with `{` or `[`. Plain strings (crash
    # fallbacks) are stored verbatim and round-trip as-is.
    if String.starts_with?(str, ["{", "["]) do
      case Jason.decode(str) do
        {:ok, %{"__result_tag__" => "ok", "data" => data}} when is_map(data) ->
          {:ok, decode_result_data(data)}

        {:ok, %{"__result_tag__" => "error", "reason" => reason}} ->
          {:error, decode_reason(reason)}

        {:ok, %{"__result_tag__" => "exit", "reason" => reason}} ->
          {:exit, decode_reason(reason)}

        {:ok, value} ->
          # JSON without a discriminator — return the decoded value as-is.
          value

        {:error, _} ->
          # Looked like JSON but failed to decode — return the raw string so
          # it round-trips untouched.
          str
      end
    else
      str
    end
  end

  # Reconstructs atom keys for known result-data fields and rebuilds the
  # embedded %EvoGit.Agent.Usage{} struct (same pattern as decode_usage/1).
  # Only the known keys in `@result_data_fields` are atomized — unknown keys
  # are kept as strings to avoid blind atomization of arbitrary data.
  def decode_result_data(data) when is_map(data) do
    known_field_strings = MapSet.new(@result_data_fields, &Atom.to_string/1)

    Enum.reduce(data, %{}, fn {key, value}, acc ->
      atom_key =
        case key do
          key when is_atom(key) ->
            key

          key when is_binary(key) ->
            if MapSet.member?(known_field_strings, key), do: String.to_atom(key), else: nil

          _ ->
            nil
        end

      reconstructed =
        case {atom_key, value} do
          {:usage, usage_map} when is_map(usage_map) and not is_struct(usage_map) ->
            decode_usage_map(usage_map)

          _ ->
            value
        end

      final_key = if atom_key != nil, do: atom_key, else: key
      Map.put(acc, final_key, reconstructed)
    end)
  end

  # Reason values for {:error, _} / {:exit, _} are usually strings but may
  # originally have been atoms. Try to restore a pre-existing atom (safe,
  # never creates new atoms) so values like {:exit, :killed} round-trip.
  #
  # Justified try/rescue: (1) Do we expect this error? Yes — reason strings from
  # the DB may not correspond to existing atoms (e.g. {:error, "custom message"}
  # or strings written by older code versions). (2) Is try/rescue cleanest? Yes
  # — String.to_existing_atom/1 has no non-crashing variant. The fallback (keep
  # the string) is the correct semantic: an unknown reason is still valid as a
  # string, not "bad data".
  def decode_reason(str) when is_binary(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError -> str
    end
  end

  def decode_reason(other), do: other

  # --- usage (EvoGit.Agent.Usage struct) ---
  def encode_usage(nil), do: nil

  def encode_usage(%EvoGit.Agent.Usage{} = usage) do
    case Jason.encode(Map.from_struct(usage)) do
      {:ok, json} ->
        json

      {:error, e} ->
        Logger.warning("Codec: failed to encode usage: #{Exception.message(e)}")
        nil
    end
  end

  def decode_usage(nil), do: nil

  def decode_usage(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, map} when is_map(map) and not is_struct(map) ->
        decode_usage_map(map)

      {:ok, %EvoGit.Agent.Usage{} = usage} ->
        usage

      _ ->
        nil
    end
  end

  # Shared helper: builds a %EvoGit.Agent.Usage{} struct from a string-keyed or
  # atom-keyed map, only extracting the known usage fields.
  def decode_usage_map(map) when is_map(map) do
    atom_usage =
      Enum.reduce(@usage_fields, %{}, fn field, acc ->
        value = Map.get(map, Atom.to_string(field)) || Map.get(map, field)
        Map.put(acc, field, value)
      end)

    struct(EvoGit.Agent.Usage, atom_usage)
  end

  # --- archive_metadata (list of maps) ---
  def encode_archive(nil), do: nil

  def encode_archive(archive) when is_list(archive) do
    case Jason.encode(archive) do
      {:ok, json} ->
        json

      {:error, e} ->
        Logger.warning("Codec: failed to encode archive_metadata: #{Exception.message(e)}")
        nil
    end
  end

  def decode_archive(nil), do: nil

  def decode_archive(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, value} when is_list(value) -> value
      _ -> nil
    end
  end

  # --- pid ---
  def encode_pid(nil), do: nil

  def encode_pid(pid) when is_pid(pid) do
    pid |> :erlang.pid_to_list() |> List.to_string()
  end

  def decode_pid(nil), do: nil

  # Justified try/rescue: (1) Do we expect this error? Yes — pid strings from a
  # previous VM run are always stale/invalid after a restart; the DB persists
  # them across restarts. (2) Is try/rescue cleanest? Yes —
  # :erlang.list_to_pid/1 has no non-crashing variant; it raises on malformed
  # input. Returning nil is the correct semantic (no live pid = nil). This is a
  # legitimate boundary with untrusted persisted data.
  def decode_pid(str) when is_binary(str) do
    try do
      str |> String.to_charlist() |> :erlang.list_to_pid()
    rescue
      _ -> nil
    end
  end
end
