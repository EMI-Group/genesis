defmodule EvoGit.Store.Types.OptsJson do
  @moduledoc """
  Ecto.Type for the `tasks.opts` column — a keyword list ↔ JSON TEXT object.

  This type is a THIN delegation to `EvoGit.Store.Codec` — the Codec is the
  single source of truth for the on-disk wire format and stays byte-compatible
  with existing user databases. No encoding logic is duplicated here.

  ## Wire format

  `keyword() | nil` ↔ a JSON OBJECT with string keys
  (`{"path": "...", "mode": "..."}`), chosen so values stay addressable via
  JSON paths (`json_extract(opts, '$.path')`) for SQL pushdowns.

    * **dump** (`Codec.encode_opts/1`) is TOTAL: nil → `nil`; a keyword list
      → the string-keyed JSON object. When Jason cannot serialize the full
      value map (tuples, pids, …) it logs a warning and falls back to the 4
      essential keys (`path`, `mode`, `prompt`, `objective`), and to `nil` if
      even those fail — encode never raises.
    * **load** (`Codec.decode_opts/1`) is STRICTLY CANONICAL: only JSON
      objects decode — into a keyword list whose KNOWN keys (the Codec's
      `@known_opt_keys` whitelist) are atomized; unknown keys stay strings.
      Non-object JSON (legacy positional pair-arrays, scalars, JSON null) and
      invalid JSON RAISE `ArgumentError` — exactly where the Codec raises.
      Legacy rows must be rewritten by `mix migrate.store` before they can be
      read; wave-2 Store code is expected to rescue/skip like the current
      safe-select helpers do.

  ## Glue (documented deviations from pure delegation)

    * `dump/1` returns `:error` (never raises) for a non-nil, non-list value —
      the Codec has no clause for those and would raise `FunctionClauseError`;
      the Ecto contract requires a non-raising `:error` instead.
    * `load/1` returns `:error` for a non-nil, non-binary stored value — the
      Codec has no clause for those (the column is TEXT, so this cannot occur
      in a well-formed database).

  Pure module — no Repo, no GenServer, no I/O.
  """

  use Ecto.Type

  alias EvoGit.Store.Codec

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}

  def cast(opts) when is_list(opts), do: {:ok, opts}

  def cast(_), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(opts) when is_list(opts), do: {:ok, Codec.encode_opts(opts)}

  def dump(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  # Deliberately lets ArgumentError propagate on non-canonical stored text —
  # the Codec is the oracle and raising is its documented contract.
  def load(str) when is_binary(str), do: {:ok, Codec.decode_opts(str)}

  def load(_), do: :error

  @impl Ecto.Type
  def embed_as(_format), do: :self
end

defmodule EvoGit.Store.Types.ResultJson do
  @moduledoc """
  Ecto.Type for the `tasks.result` column — the runtime return-tuple envelope.

  This type is a THIN delegation to `EvoGit.Store.Codec` — the Codec is the
  single source of truth for the on-disk wire format and stays byte-compatible
  with existing user databases. No encoding logic is duplicated here.

  ## Wire format

  `term() | nil` ↔ a JSON TEXT envelope tagged with `"__result_tag__"` so the
  tuple shape round-trips faithfully:

      {"__result_tag__":"ok","data":{...}}     {:ok, %{...}}
      {"__result_tag__":"error","reason":...}  {:error, reason}
      {"__result_tag__":"exit","reason":...}   {:exit, reason}
      {"__result_tag__":"string","value":...}  any other shape / plain string

    * **dump** (`Codec.encode_result/1`) is TOTAL over every term: atom keys
      of the success map are stringified and restored on load via the Codec's
      `@result_data_fields` whitelist; the embedded `%EvoGit.Agent.Usage{}`
      is serialized like the dedicated `usage` column; Jason failure falls
      back to a string-tagged `inspect/1` — encode never raises, and the
      column is uniformly valid JSON.
    * **load** (`Codec.decode_result/1`) is STRICTLY CANONICAL: only the 4
      tagged forms decode. Raw strings, untagged JSON, invalid JSON, and JSON
      null RAISE `ArgumentError` — exactly where the Codec raises. The
      `"repos"` per-repo map inside `data` deliberately STAYS STRING-KEYED
      (`Codec.decode_result_data/1` never atomizes it).

  Load returns `{:ok, decoded}` where `decoded` is the reconstructed
  `{:ok, map} | {:error, reason} | {:exit, reason} | String.t()` — the exact
  shape `%TaskInfo{}.result` holds.

  ## Glue (documented deviations from pure delegation)

    * `load/1` returns `:error` for a non-nil, non-binary stored value — the
      Codec has no clause for those (the column is TEXT, so this cannot occur
      in a well-formed database).

  Pure module — no Repo, no GenServer, no I/O.
  """

  use Ecto.Type

  alias EvoGit.Store.Codec

  @impl Ecto.Type
  def type, do: :string

  # The result column is a `term()` — every value is encodable (the Codec's
  # catch-all string-tags whatever Jason cannot serialize).
  @impl Ecto.Type
  def cast(value), do: {:ok, value}

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(value), do: {:ok, Codec.encode_result(value)}

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  # Deliberately lets ArgumentError propagate on non-canonical stored text —
  # the Codec is the oracle and raising is its documented contract.
  def load(str) when is_binary(str), do: {:ok, Codec.decode_result(str)}

  def load(_), do: :error

  @impl Ecto.Type
  def embed_as(_format), do: :self
end

defmodule EvoGit.Store.Types.LogsJson do
  @moduledoc """
  Ecto.Type for the `tasks.logs` column — a list of strings ↔ JSON TEXT array.

  This type is a THIN delegation to `EvoGit.Store.Codec` — the Codec is the
  single source of truth for the on-disk wire format and stays byte-compatible
  with existing user databases. No encoding logic is duplicated here.

  ## Wire format

    * **dump** (`Codec.encode_logs/1`) is TOTAL: nil → the JSON text `"[]"`
      (never a NULL column); a list → its JSON array; a Jason failure falls
      back to `"[]"` — encode never raises.
    * **load** (`Codec.decode_logs/1`) is LENIENT: nil → `[]`, a JSON array
      → the list, anything undecodable → `[]`. Never raises.

  ## Glue (documented deviations from pure delegation)

    * `dump/1` returns `:error` (never raises) for a non-nil, non-list value —
      the Codec has no clause for those and would raise `FunctionClauseError`.
    * `load/1` returns `:error` for a non-nil, non-binary stored value — the
      Codec has no clause for those (the column is TEXT, so this cannot occur
      in a well-formed database).

  Pure module — no Repo, no GenServer, no I/O.
  """

  use Ecto.Type

  alias EvoGit.Store.Codec

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}

  def cast(logs) when is_list(logs), do: {:ok, logs}

  def cast(_), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, Codec.encode_logs(nil)}

  def dump(logs) when is_list(logs), do: {:ok, Codec.encode_logs(logs)}

  def dump(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, Codec.decode_logs(nil)}

  def load(str) when is_binary(str), do: {:ok, Codec.decode_logs(str)}

  def load(_), do: :error

  @impl Ecto.Type
  def embed_as(_format), do: :self
end

defmodule EvoGit.Store.Types.UsageJson do
  @moduledoc """
  Ecto.Type for the `tasks.usage` column — an `%EvoGit.Agent.Usage{}` ↔ JSON TEXT object.

  This type is a THIN delegation to `EvoGit.Store.Codec` — the Codec is the
  single source of truth for the on-disk wire format and stays byte-compatible
  with existing user databases. No encoding logic is duplicated here.

  ## Wire format

    * **dump** (`Codec.encode_usage/1`) is TOTAL: nil → `nil`;
      `%EvoGit.Agent.Usage{}` → `Map.from_struct/1` JSON-encoded; a Jason
      failure logs a warning and stores `nil` — encode never raises.
    * **load** (`Codec.decode_usage/1`) is LENIENT: nil → `nil`, a JSON
      object → a `%EvoGit.Agent.Usage{}` rebuilt from the known usage fields
      only (missing fields default via `struct/2`), anything undecodable →
      `nil`. Never raises.

  ## Glue (documented deviations from pure delegation)

    * `dump/1` returns `:error` for a non-nil, non-`%Usage{}` value — the
      Codec has no clause for those.
    * `load/1` returns `:error` for a non-nil, non-binary stored value — the
      Codec has no clause for those (the column is TEXT, so this cannot occur
      in a well-formed database).

  Pure module — no Repo, no GenServer, no I/O.
  """

  use Ecto.Type

  alias EvoGit.Agent.Usage
  alias EvoGit.Store.Codec

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}

  def cast(%Usage{} = usage), do: {:ok, usage}

  def cast(_), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(%Usage{} = usage), do: {:ok, Codec.encode_usage(usage)}

  def dump(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(str) when is_binary(str), do: {:ok, Codec.decode_usage(str)}

  def load(_), do: :error

  @impl Ecto.Type
  def embed_as(_format), do: :self
end

defmodule EvoGit.Store.Types.ArchiveJson do
  @moduledoc """
  Ecto.Type for the `tasks.archive_metadata` column — a list of maps ↔ JSON TEXT array.

  This type is a THIN delegation to `EvoGit.Store.Codec` — the Codec is the
  single source of truth for the on-disk wire format and stays byte-compatible
  with existing user databases. No encoding logic is duplicated here.

  ## Wire format

    * **dump** (`Codec.encode_archive/1`) is TOTAL: nil → `nil`; a list → its
      JSON array; a Jason failure logs a warning and stores `nil` — encode
      never raises.
    * **load** (`Codec.decode_archive/1`) is LENIENT: nil → `nil`, a JSON
      array → the list, anything undecodable → `nil`. Never raises.

  ## Glue (documented deviations from pure delegation)

    * `dump/1` returns `:error` (never raises) for a non-nil, non-list value —
      the Codec has no clause for those and would raise `FunctionClauseError`.
    * `load/1` returns `:error` for a non-nil, non-binary stored value — the
      Codec has no clause for those (the column is TEXT, so this cannot occur
      in a well-formed database).

  Pure module — no Repo, no GenServer, no I/O.
  """

  use Ecto.Type

  alias EvoGit.Store.Codec

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}

  def cast(archive) when is_list(archive), do: {:ok, archive}

  def cast(_), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(archive) when is_list(archive), do: {:ok, Codec.encode_archive(archive)}

  def dump(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(str) when is_binary(str), do: {:ok, Codec.decode_archive(str)}

  def load(_), do: :error

  @impl Ecto.Type
  def embed_as(_format), do: :self
end

defmodule EvoGit.Store.Types.ErrorJson do
  @moduledoc """
  Ecto.Type for the `tasks.error` column — the canonical failed-task error
  payload, a map ↔ JSON TEXT object.

  This type is a THIN delegation to `EvoGit.Store.Codec` — the Codec is the
  single source of truth for the on-disk wire format and stays byte-compatible
  with existing user databases. No encoding logic is duplicated here.

  ## Wire format

  A JSON OBJECT with string keys and a FIXED key set — `kind` (closed atom
  set: `:error | :exit | :down | :force_kill | :timeout | :restart |
  :lease_expired | :recheck`), `source` (closed atom set: `:result_handler |
  :down_handler | :force_kill_task | :finalizing_watchdog |
  :startup_reconcile | :lease_sweep | :recheck_resolve`), `message`
  (always present) and `stacktrace` (`[String.t()] | nil`).

    * **dump** (`Codec.encode_error/1`) is TOTAL: nil → `nil`; a map → the
      string-keyed object with the `kind`/`source` atoms stringified; a Jason
      failure logs a warning and stores `nil` — encode never raises.
    * **load** (`Codec.decode_error/1`) is LENIENT (NOT the strict
      decode_result style — this informational column must never break row
      decode): nil and non-object JSON → `nil`; the four known keys are
      atomized via the whitelist; `kind`/`source` string values are restored
      to their closed-set atoms; unknown keys keep string keys; all other
      values pass through unchanged. Never raises.

  ## Glue (documented deviations from pure delegation)

    * `dump/1` returns `:error` for a non-nil, non-map value — the Codec has
      no clause for those.
    * `load/1` returns `:error` for a non-nil, non-binary stored value — the
      Codec has no clause for those (the column is TEXT, so this cannot occur
      in a well-formed database).

  Pure module — no Repo, no GenServer, no I/O.
  """

  use Ecto.Type

  alias EvoGit.Store.Codec

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}

  def cast(error) when is_map(error), do: {:ok, error}

  def cast(_), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(error) when is_map(error), do: {:ok, Codec.encode_error(error)}

  def dump(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(str) when is_binary(str), do: {:ok, Codec.decode_error(str)}

  def load(_), do: :error

  @impl Ecto.Type
  def embed_as(_format), do: :self
end
