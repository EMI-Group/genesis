defmodule EvoGit.Store.Types.TaskTimestamp do
  @moduledoc """
  Ecto.Type for the fixed-millisecond ISO-8601 TEXT timestamps of the
  EvoGit task store (`tasks.started_at`, `tasks.finished_at`,
  `tasks.updated_at`, `projects.last_opened_at`).

  This type is a THIN delegation to `EvoGit.Store.Codec` — the Codec is the
  single source of truth for the on-disk wire format and stays byte-compatible
  with existing user databases. No encoding logic is duplicated here.

  ## Wire format

  `%DateTime{}` (or `nil`) ↔ ISO-8601 TEXT truncated to millisecond precision
  via `DateTime.truncate/2` + `DateTime.to_iso8601/1`. A value with a nonzero
  millisecond part encodes to exactly 24 chars (`2024-01-01T12:00:00.123Z`),
  which lexicographically sorts chronologically in SQLite — the property that
  makes SQL-side `ORDER BY started_at DESC` and `updated_at > ?` string
  comparisons correct. (A precision-0 `DateTime` — e.g. one built with
  `DateTime.new!/2` from whole-second parts — encodes without the fractional
  suffix, exactly like `Codec.encode_datetime/1`; all real writers use
  `DateTime.utc_now()`, which always carries microseconds and hence always
  emits the 24-char form.)

  ## Load-side return type

  `load/1` returns a `%DateTime{}` (or `nil`) — the same type
  `Codec.decode_datetime/1` returns, which is what `%TaskInfo{}` holds for
  `started_at`/`finished_at` (and `%RecentProject{}` for `last_opened_at`).

  > #### `updated_at` is special {: .warning}
  > The store-internal `updated_at` column is RAW — the summary/changed-since
  > reads return it as the raw ISO string and string-compare it in SQL, never
  > decoding it to a DateTime. Schema code that needs the raw-string semantics
  > for `updated_at` must NOT load it through this type; use
  > `EvoGit.Store.Types.TaskTimestampRaw` instead (dump encodes exactly the
  > same text; load passes the stored string through untouched). Both types
  > dump byte-identical values, so a schema may freely switch between them
  > without any data migration.

  Pure module — no Repo, no GenServer, no I/O.
  """

  use Ecto.Type

  alias EvoGit.Store.Codec

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}

  def cast(%DateTime{} = dt), do: {:ok, dt}

  # ISO strings are accepted so a round-tripped raw value (e.g. a raw
  # updated_at string) can be re-dumped without manual parsing.
  def cast(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> :error
    end
  end

  def cast(_), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(%DateTime{} = dt), do: {:ok, Codec.encode_datetime(dt)}

  def dump(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  # Lenient BY DESIGN — mirrors `Codec.decode_datetime/1` exactly: a corrupt
  # timestamp string decodes to nil (row still loads) rather than erroring.
  # The Store relies on this ("finished_at is decoded via the non-crashing
  # Codec.decode_datetime/1 (returns nil on bad data)"), and the type contract
  # here is "load returns the same type Codec.decode_datetime returns".
  def load(str) when is_binary(str), do: {:ok, Codec.decode_datetime(str)}

  def load(_), do: :error

  @impl Ecto.Type
  def embed_as(_format), do: :self

  @impl Ecto.Type
  def equal?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  def equal?(nil, nil), do: true
  def equal?(_, _), do: false
end

defmodule EvoGit.Store.Types.TaskTimestampRaw do
  @moduledoc """
  Ecto.Type for the store-internal `tasks.updated_at` column — the RAW
  variant of `EvoGit.Store.Types.TaskTimestamp`.

  `EvoGit.Store` treats `updated_at` as store-internal bookkeeping: it is
  written on every targeted column update (same `Codec.encode_datetime/1`
  encoding as every other timestamp column) but read back as the RAW ISO
  string and compared as text in SQL (`updated_at > ?` string comparison, the
  `idx_tasks_updated_at`-backed changed-since queries). This type preserves
  exactly that: `load/1` returns the stored string UNCHANGED (never decodes
  to a DateTime), while `dump/1` encodes via `Codec.encode_datetime/1` —
  byte-identical to `TaskTimestamp.dump/1`.

  This type is a THIN delegation to `EvoGit.Store.Codec` — no encoding logic
  is duplicated. Pure module — no Repo, no GenServer, no I/O.
  """

  use Ecto.Type

  alias EvoGit.Store.Codec

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}

  # Raw semantics: accept the already-encoded ISO string (round-trip safe),
  # or a DateTime (encoded on dump).
  def cast(str) when is_binary(str), do: {:ok, str}

  def cast(%DateTime{} = dt), do: {:ok, Codec.encode_datetime(dt)}

  def cast(_), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(str) when is_binary(str), do: {:ok, str}

  def dump(%DateTime{} = dt), do: {:ok, Codec.encode_datetime(dt)}

  def dump(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(str) when is_binary(str), do: {:ok, str}

  def load(_), do: :error

  @impl Ecto.Type
  def embed_as(_format), do: :self

  @impl Ecto.Type
  def equal?(a, b) when is_binary(a) and is_binary(b), do: a == b
  def equal?(nil, nil), do: true
  def equal?(_, _), do: false
end

defmodule EvoGit.Store.Types.UnixMs do
  @moduledoc """
  Ecto.Type for the `tasks.lease_expires_at` column — a plain unix-milliseconds
  INTEGER.

  The wire format is a bare INTEGER (no conversion at all); this type exists so
  the Ecto schema modules and wave-2 Store operation code share ONE casting
  surface for the column. Delegates nothing to the Codec because the Codec has
  no `lease`-specific function — the integer passes through untouched on both
  sides (this is the thinnest possible glue, noted per the task contract).

  Pure module — no Repo, no GenServer, no I/O.
  """

  use Ecto.Type

  @impl Ecto.Type
  def type, do: :integer

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}

  def cast(value) when is_integer(value), do: {:ok, value}

  # Lenient string→integer casting for CLI/JSON-shaped input.
  def cast(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  def cast(_), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(value) when is_integer(value), do: {:ok, value}

  def dump(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(value) when is_integer(value), do: {:ok, value}

  def load(_), do: :error

  @impl Ecto.Type
  def embed_as(_format), do: :self
end
