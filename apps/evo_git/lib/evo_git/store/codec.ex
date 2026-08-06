defmodule EvoGit.Store.Codec do
  @moduledoc """
  Pure serialization functions for the EvoDash SQLite store.

  This module has NO GenServer and NO I/O.

  ## Encode philosophy

  Encode functions are TOTAL — they never raise. All JSON encoding uses the
  non-crashing `Jason.encode/1` (returns `{:ok, json} | {:error, exception}`)
  with `case`/`with` to choose fallbacks. There are NO `try/rescue` blocks in
  the encode functions.

  ## Decode philosophy

  Decode functions raise on bad data — the Store's safe-select helpers
  (`safe_select_all_tasks/1`, `safe_select_all_projects/1`,
  `safe_select_paginated_tasks/2`) and the summary reads
  (`select_tasks_summary/3`, `select_tasks_summary_by_path/4`,
  `select_tasks_changed_since/2`) skip undecodable rows and log a warning
  instead of crashing.

  Decode is STRICTLY canonical: only values written by the current encoders
  decode successfully. `decode_result/1` accepts just the 4 tagged forms and
  `decode_opts/1` just JSON objects; legacy shapes (raw strings, untagged
  JSON, pair-array opts, invalid JSON) raise `ArgumentError`. Old databases
  must be upgraded with `mix migrate.store` before they can be read.

  One justified `try/rescue` pattern remains on the decode side:

    * `decode_reason/1` — best-effort atom recovery. `String.to_existing_atom/1`
      has no non-crashing variant; an unknown reason string legitimately stays
      a string (it's a valid alternative representation, not "bad data").
  """

  require Logger

  alias EvoGit.TaskInfo
  alias EvoGit.RecentProject

  @task_columns ~w(id type status opts started_at finished_at logs result review_status usage agent_count base_sha commit_sha archive_metadata lease_expires_at model_id project_path branch_name)
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

  # Precomputed string versions of @usage_fields for zero-allocation lookups
  # in decode_usage_map/1 — avoids calling Atom.to_string/1 on every decode.
  @usage_field_pairs Enum.map(@usage_fields, &{&1, Atom.to_string(&1)})

  # Known keys inside the {:ok, data} result map. Used for safe atomization
  # during decode (these are application-controlled, not user input).
  @result_data_fields ~w(commit_sha result tag branch_name pr_url pr_title no_changes usage agent_count archive_records)a

  # Precomputed string set for O(1) membership checks in decode_result_data/1.
  @result_data_field_strings MapSet.new(@result_data_fields, &Atom.to_string/1)

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
      encode_datetime(task.started_at),
      encode_datetime(task.finished_at),
      encode_logs(task.logs),
      encode_result(task.result),
      encode_atom(task.review_status),
      encode_usage(task.usage),
      task.agent_count,
      task.base_sha,
      task.commit_sha,
      encode_archive(task.archive_metadata),
      task.lease_expires_at,
      task.model_id,
      task.project_path || extract_project_path(task.opts),
      task.branch_name || extract_branch_name(task.result)
    ]
  end

  # Extracts the :path value from opts for denormalization into the project_path
  # column. Returns nil if opts is nil or doesn't contain a :path key.
  defp extract_project_path(nil), do: nil

  defp extract_project_path(opts) when is_list(opts) do
    Keyword.get(opts, :path)
  end

  # Extracts the :branch_name from a {:ok, %{branch_name: name}} result tuple
  # for denormalization into the branch_name column. Returns nil for all other
  # result shapes.
  defp extract_branch_name(nil), do: nil

  defp extract_branch_name({:ok, data}) when is_map(data) do
    Map.get(data, :branch_name)
  end

  defp extract_branch_name(_other), do: nil

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
      started_at,
      finished_at,
      logs,
      result,
      review_status,
      usage,
      agent_count,
      base_sha,
      commit_sha,
      archive_metadata,
      lease_expires_at,
      model_id,
      project_path,
      branch_name
    ] = row

    %TaskInfo{
      id: id,
      type: decode_atom(type),
      status: decode_atom(status) || :pending,
      opts: decode_opts(opts),
      ref: nil,
      started_at: decode_datetime(started_at),
      finished_at: decode_datetime(finished_at),
      logs: decode_logs(logs),
      result: decode_result(result),
      review_status: decode_atom(review_status),
      usage: decode_usage(usage),
      agent_count: agent_count,
      base_sha: base_sha,
      commit_sha: commit_sha,
      archive_metadata: decode_archive(archive_metadata),
      lease_expires_at: lease_expires_at,
      model_id: model_id,
      project_path: project_path,
      branch_name: branch_name
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
  @doc """
  Encodes a `%DateTime{}` to a fixed-precision ISO-8601 string.

  Truncates to `:millisecond` precision (`DateTime.truncate/2`) so
  `DateTime.to_iso8601/1` always emits exactly 3 fractional digits
  (`2024-01-01T12:00:00.123Z`, and `.000Z` even for whole seconds). The
  default `:auto` precision emits a variable number of fractional digits (none
  for whole seconds, up to 6 with microseconds), which breaks lexicographic
  ordering of the TEXT timestamps in SQLite (`'Z'` (0x5A) > `'.'` (0x2E), so
  `"…00Z"` sorts before `"…00.5Z"` while being chronologically after). The
  constant 24-char `:millisecond` format sorts correctly, which is required
  for SQL-side `ORDER BY started_at DESC` and datetime comparisons. All
  writers use `DateTime.utc_now()` (UTC); existing rows are migrated by
  `EvoGit.Store.Schema.normalize_timestamps/1`.
  """
  def encode_datetime(nil), do: nil

  def encode_datetime(%DateTime{} = dt) do
    dt |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  def decode_datetime(nil), do: nil

  def decode_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  # --- opts (keyword list) ---
  # Encode as a JSON OBJECT with string keys (`{"path": "...", "mode": "..."}`)
  # — unlike the legacy positional array encoding, values are addressable via
  # JSON paths (e.g. `json_extract(opts, '$.path')`) for future SQL pushdowns.
  # Duplicate keys are impossible in a map, so if a keyword list ever repeated
  # a key, the last occurrence wins on decode (not used in practice).
  # If Jason can't serialize the values (tuples, pids, etc.), fall back to
  # encoding just the essential keys (path, mode, prompt, objective), or nil.
  #
  # Known opt keys that the application accesses — atomized safely on decode
  # via the @known_opt_keys whitelist. Unknown keys remain as strings to avoid
  # blind atomization.
  @known_opt_keys ~w(path mode prompt objective foreign_repos node_path starting_commit archive task_id repo_path concurrency tool_concurrency resume_from)a
  @known_opt_key_strings MapSet.new(@known_opt_keys, &Atom.to_string/1)

  def encode_opts(nil), do: nil

  def encode_opts(opts) when is_list(opts) do
    map =
      Map.new(opts, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        {key, value} -> {to_string(key), value}
      end)

    case Jason.encode(map) do
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
          |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

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
    # Strictly canonical: only JSON objects decode. Non-object JSON (legacy
    # pair-array rows, scalars, JSON null) and invalid JSON raise
    # ArgumentError — legacy rows must be rewritten by `mix migrate.store`
    # before they can be read.
    case Jason.decode(str) do
      {:ok, map} when is_map(map) and not is_struct(map) ->
        Enum.map(map, fn {key_str, value} -> {decode_opt_key(key_str), value} end)

      {:ok, other} ->
        raise ArgumentError,
              "Codec: undecodable opts value in DB (expected JSON object): " <> inspect(other)

      {:error, _} ->
        raise ArgumentError,
              "Codec: undecodable opts value in DB (expected JSON object): " <> inspect(str)
    end
  end

  # Known opt keys are atomized for caller convenience (Keyword.get/2 with atom
  # keys). Unknown keys stay as strings — they are never pattern-matched by key.
  def decode_opt_key(key) when is_atom(key), do: key

  def decode_opt_key(key) when is_binary(key) do
    if MapSet.member?(@known_opt_key_strings, key) do
      String.to_atom(key)
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
  # Plain strings (crash fallbacks) are ALWAYS JSON-wrapped with a `"string"`
  # tag (`{"__result_tag__":"string","value":<str>}`), so every value in the
  # result column is valid JSON — this enables future `json_valid`-guarded
  # `json_extract` SQL filters. Decode is strictly canonical: only the tagged
  # forms decode; legacy raw strings/untagged JSON raise (see decode_result/1).
  def encode_result(nil), do: nil

  # Plain strings (crash fallbacks) are JSON-wrapped with a "string" tag so the
  # column is uniformly valid JSON. Jason.encode!/1 of a binary can never fail.
  def encode_result(result) when is_binary(result) do
    Jason.encode!(%{"__result_tag__" => "string", "value" => result})
  end

  def encode_result({:ok, data}) when is_map(data) do
    json_data = encode_result_data(data)

    case Jason.encode(%{"__result_tag__" => "ok", "data" => json_data}) do
      {:ok, json} ->
        json

      {:error, e} ->
        Logger.warning("Codec: failed to encode ok-result: #{Exception.message(e)}")

        # Fall back to a string-tagged inspect so the column stays uniformly
        # valid JSON (Jason.encode!/1 of a binary can never fail).
        Jason.encode!(%{"__result_tag__" => "string", "value" => inspect({:ok, data})})
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
    # Any other shape — fall back to a string-tagged inspect so we never crash
    # on encode and never write raw (untagged) strings.
    Jason.encode!(%{"__result_tag__" => "string", "value" => inspect(other)})
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
    # Strictly canonical: only the 4 tagged forms decode. Raw strings, untagged
    # JSON, invalid JSON, and JSON null raise ArgumentError — legacy rows must
    # be rewritten by `mix migrate.store` before they can be read.
    case Jason.decode(str) do
      {:ok, %{"__result_tag__" => "ok", "data" => data}} when is_map(data) ->
        {:ok, decode_result_data(data)}

      {:ok, %{"__result_tag__" => "error", "reason" => reason}} ->
        {:error, decode_reason(reason)}

      {:ok, %{"__result_tag__" => "exit", "reason" => reason}} ->
        {:exit, decode_reason(reason)}

      {:ok, %{"__result_tag__" => "string", "value" => value}} when is_binary(value) ->
        # Canonical string encoding — return the raw string.
        value

      {:ok, other} ->
        # Untagged JSON (objects/arrays/scalars) or JSON null — non-canonical.
        raise ArgumentError,
              "Codec: undecodable result value in DB (missing canonical __result_tag__): " <>
                inspect(other)

      {:error, _} ->
        # Raw non-JSON string (legacy crash fallback) — non-canonical.
        raise ArgumentError,
              "Codec: undecodable result value in DB (missing canonical __result_tag__): " <>
                inspect(str)
    end
  end

  # Reconstructs atom keys for known result-data fields and rebuilds the
  # embedded %EvoGit.Agent.Usage{} struct (same pattern as decode_usage/1).
  # Only the known keys in `@result_data_fields` are atomized — unknown keys
  # are kept as strings to avoid blind atomization of arbitrary data.
  def decode_result_data(data) when is_map(data) do
    Enum.reduce(data, %{}, fn {key, value}, acc ->
      atom_key =
        case key do
          key when is_atom(key) ->
            key

          key when is_binary(key) ->
            if MapSet.member?(@result_data_field_strings, key), do: String.to_atom(key), else: nil

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

      _ ->
        nil
    end
  end

  # Shared helper: builds a %EvoGit.Agent.Usage{} struct from a string-keyed or
  # atom-keyed map, only extracting the known usage fields.
  def decode_usage_map(map) when is_map(map) do
    atom_usage =
      Enum.reduce(@usage_field_pairs, %{}, fn {field, str}, acc ->
        value = Map.get(map, str) || Map.get(map, field)
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
end
