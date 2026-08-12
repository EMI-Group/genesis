defmodule EvoGit.Store.Errors do
  @moduledoc """
  Classification of xqlite/SQLite error returns for the `EvoGit.Store` write
  boundary.

  xqlite NIFs (`XqliteNIF.query/3`, `XqliteNIF.execute/3`) RETURN error tuples
  — they never raise. This module maps those tuples to semantic classes so the
  Store can handle disk-full writes gracefully instead of crashing.

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
  `{:sqlite_failure, code, extended_code, message | nil}` arm. Both shapes are
  matched here, plus a message-text fallback for the canonical SQLITE_FULL
  message ("database or disk is full") so synthetic/triggered errors with
  primary code 1 (e.g. a `RAISE(FAIL, 'database or disk is full')` test
  trigger) classify correctly.
  """

  @doc """
  Returns `true` when the given xqlite NIF return value represents a
  disk-full-class error.

  Accepts the FULL return value (`{:ok, _} | {:error, reason}`) so callers can
  pass the NIF result directly. Any non-error value returns `false`.
  """
  def disk_full_error?({:error, reason}), do: disk_full_reason?(reason)
  def disk_full_error?(_), do: false

  # SQLITE_READONLY — xqlite classifies this into its own variant.
  defp disk_full_reason?({:read_only_database, _extended_code, _message}), do: true

  # SQLITE_READONLY (8) / SQLITE_IOERR (10) / SQLITE_FULL (13) — generic
  # sqlite_failure arm (code = primary result code, `extended_code & 0xFF`).
  defp disk_full_reason?({:sqlite_failure, code, _extended_code, _message})
       when code in [8, 10, 13],
       do: true

  # Message-text fallback: SQLite's canonical SQLITE_FULL message is
  # "database or disk is full". This also covers synthetic errors raised with
  # primary code 1 (e.g. a test trigger `RAISE(FAIL, 'database or disk is
  # full')`), which carry no distinguishing result code. Message reword/
  # localization downgrades to `false` — graceful (the error crashes the
  # GenServer as before), never a misclassification into :disk_full.
  defp disk_full_reason?({:sqlite_failure, _code, _extended_code, message})
       when is_binary(message) do
    String.contains?(String.downcase(message), "database or disk is full")
  end

  defp disk_full_reason?(_), do: false
end
