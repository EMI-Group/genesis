defmodule EvoGit.Store.Errors do
  @moduledoc """
  Classification of xqlite/SQLite errors for the `EvoGit.Store` write
  boundary — TWO shape families, both mapping to the same semantic
  disk-full class.

  ## Shape family 1 — xqlite NIF error TUPLES (legacy raw-SQL store)

  xqlite NIFs (`XqliteNIF.query/3`, `XqliteNIF.execute/3`) RETURN error
  tuples — they never raise. This module maps those tuples so the raw-SQL
  Store can handle disk-full writes gracefully instead of crashing
  (`disk_full_error?/1`).

  ## Shape family 2 — RAISED `%XqliteEcto3.Error{}` exceptions (Ecto adapter)

  The `XqliteEcto3` adapter RAISES `%XqliteEcto3.Error{message: _, statement:
  _, type: _, details: _}` (a `defexception`) on every failure.
  `disk_full_exception?/1` matches the disk-full shapes:

    * `type: :sqlite_failure` with `details` a
      `%XqliteEcto3.Error.SqliteFailure{code, extended_code, message}` whose
      primary `code` is 8/10/13
    * `type: :read_only_database` with `details: %{extended_code: n}`
    * message-text fallback — `details.message` or the top-level `message`,
      downcased, containing "database or disk is full"

  ## Disk-full class

  SQLite reports a full disk on write paths as one of three primary result
  codes (see https://www.sqlite.org/rescode.html):

    * `SQLITE_FULL` (13) — "database or disk is full" — INSERT/UPDATE that
      cannot extend the database or WAL file.
    * `SQLITE_IOERR` (10) — I/O error writing pages (WAL commit, checkpoint).
    * `SQLITE_READONLY` (8) — write attempted on a read-only database (e.g.
      the WAL cannot be created because the directory is read-only).

  xqlite's own classification (`deps/xqlite/native/xqlitenif/src/error.rs`)
  special-cases `SQLITE_READONLY` as `{:read_only_database, extended_code,
  message}`; `SQLITE_FULL` and `SQLITE_IOERR` fall through to the generic
  `{:sqlite_failure, code, extended_code, message | nil}` arm. Both shapes
  are matched here, plus a message-text fallback for the canonical
  SQLITE_FULL message ("database or disk is full"). The fallback catches
  errors whose code is not 8/10/13 but whose message is the canonical
  SQLITE_FULL text — rare in practice: trigger RAISEs do NOT reach it,
  because SQLite reports them as `SQLITE_CONSTRAINT_TRIGGER` (code 19),
  which xqlite classifies as `{:error, {:constraint_violation,
  :constraint_trigger, %{message: ...}}}`, a shape the classifier
  deliberately does not match.
  """

  @doc """
  Returns `true` when the given xqlite NIF return value represents a
  disk-full-class error.

  Accepts the FULL return value (`{:ok, _} | {:error, reason}`) so callers can
  pass the NIF result directly. Any non-error value returns `false`.
  """
  def disk_full_error?({:error, reason}), do: disk_full_reason?(reason)
  def disk_full_error?(_), do: false

  @doc """
  Returns `true` when the given value is a RAISED `%XqliteEcto3.Error{}` (or a
  tuple `{:error, exception}` wrapping one) representing a disk-full-class
  error.

  Matches the adapter's exception shapes (see the moduledoc): code-based
  (`details.code` in 8/10/13 or `type: :read_only_database`) and the
  message-text fallback. Any other value — including NIF tuples, which belong
  to `disk_full_error?/1` — returns `false`.
  """
  def disk_full_exception?({:error, %XqliteEcto3.Error{} = exception}),
    do: disk_full_exception?(exception)

  # SQLITE_FAILURE with a disk-full primary code — details carries the codes.
  def disk_full_exception?(%XqliteEcto3.Error{
        type: :sqlite_failure,
        details: %XqliteEcto3.Error.SqliteFailure{code: code}
      })
      when code in [8, 10, 13],
      do: true

  # SQLITE_READONLY — the adapter classifies this into its own type.
  def disk_full_exception?(%XqliteEcto3.Error{type: :read_only_database}), do: true

  # Message-text fallback: SQLite's canonical SQLITE_FULL message is
  # "database or disk is full". Prefers details.message (the raw SQLite
  # text) over the adapter's rebuilt top-level message; checks both so an
  # exception with only one populated still matches. Case-insensitive,
  # substring — graceful on reword/localization (returns false, never
  # misclassifies).
  def disk_full_exception?(%XqliteEcto3.Error{} = exception) do
    details_message = message_from_details(exception.details)

    disk_full_message?(details_message) or
      (is_binary(exception.message) and disk_full_message?(exception.message))
  end

  def disk_full_exception?(_), do: false

  defp message_from_details(%XqliteEcto3.Error.SqliteFailure{message: message})
       when is_binary(message),
       do: message

  defp message_from_details(_), do: nil

  defp disk_full_message?(message) when is_binary(message),
    do: String.contains?(String.downcase(message), "database or disk is full")

  defp disk_full_message?(_), do: false

  # -- xqlite NIF tuple clauses --

  # SQLITE_READONLY — xqlite classifies this into its own variant.
  defp disk_full_reason?({:read_only_database, _extended_code, _message}), do: true

  # SQLITE_READONLY (8) / SQLITE_IOERR (10) / SQLITE_FULL (13) — generic
  # sqlite_failure arm (code = primary result code, `extended_code & 0xFF`).
  defp disk_full_reason?({:sqlite_failure, code, _extended_code, _message})
       when code in [8, 10, 13],
       do: true

  # Message-text fallback: SQLite's canonical SQLITE_FULL message is
  # "database or disk is full". This catches errors whose code is not 8/10/13
  # but whose message is the canonical text (rare; trigger RAISEs do NOT reach
  # it — SQLite reports them as SQLITE_CONSTRAINT_TRIGGER code 19, which
  # xqlite classifies as `{:error, {:constraint_violation, :constraint_trigger,
  # %{message: ...}}}` and which the classifier deliberately does not match).
  # Message reword/localization downgrades to `false` — graceful (the error
  # crashes the GenServer as before), never a misclassification into :disk_full.
  defp disk_full_reason?({:sqlite_failure, _code, _extended_code, message})
       when is_binary(message) do
    String.contains?(String.downcase(message), "database or disk is full")
  end

  defp disk_full_reason?(_), do: false
end
