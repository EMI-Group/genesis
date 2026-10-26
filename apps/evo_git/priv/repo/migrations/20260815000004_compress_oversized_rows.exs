defmodule EvoGit.Repo.Migrations.CompressOversizedRows do
  @moduledoc """
  Rewrites the PRE-EXISTING oversized task rows ONCE: compress the big text
  columns and drop the duplicated per-agent archive from `result`.

  ## ORDERING: this migration MUST run BEFORE `20260815000005_covering_indexes`

  The version numbers encode a hard requirement, not a chronology: this
  rewrite has to happen before the covering-index build. Both indexes are
  ordinary b-trees over scalar columns, so building them is pure index work —
  BUT SQLite can only do that by walking the table, and on a DB whose rows
  still carry multi-MB `result`/`archive_metadata` blobs the `updated_at`/`id`
  columns sit physically AFTER the blob overflow chains, so the walk crawls
  those pages. Measured on a 442 MiB live copy (one 103 MiB result + 103 MiB
  archive_metadata): the index build alone was **26.0 s** in that state and
  **57.8 ms** on the compressed + defragmented DB — the whole difference is
  this migration's rewrite (~1.1 s of UPDATE/SELECT work).

  Do NOT renumber the two migrations back (or insert a new index migration at
  a lower version). If a future index must be added, give it a version ABOVE
  `20260815000005`.

  ## Why this migration exists

  Two independent changes landed in the codec/runtime, and neither can heal a
  row that is already on disk:

    1. `EvoGit.Store.Codec` now zlib-compresses the three large text columns
       (`result`, `archive_metadata`, `logs`) when their JSON exceeds 4096
       bytes — but only values it ENCODES. Rows written before that change
       stay plain JSON (the decoder accepts both forms forever, so nothing
       breaks — they just keep their full size on disk).
    2. The per-agent archive was stored TWICE: the runtime result's
       `data.archive_records` was a verbatim duplicate of the
       `archive_metadata` column. `archive_metadata` is now the single stored
       copy (`EvoGit.TaskRegistry.ArchiveDedup` strips the key at every
       persistence boundary) — again, only for rows written since.

  On the live `tasks.sqlite` (442 MB, 953 tasks) ONE completed task held a
  108 MB `result` whose `data.archive_records` array was byte-for-byte its
  108 MB `archive_metadata` column; the table aggregates were 122 MB of
  `result` and 118 MB of `archive_metadata`. This migration visits every row
  that still needs it and leaves it in the state a current write would
  produce.

  ## Per row

    * `result` → `Codec.decode_result/1` (strict; the data-normalization
      migration already canonicalized every legacy shape), strip the
      `archive_records` key through `EvoGit.TaskRegistry.ArchiveDedup`, then
      `Codec.encode_result/1` — which compresses transparently.
    * `archive_metadata` → `Codec.decode_archive/1` then
      `Codec.encode_archive/1`.

  Rows are processed ONE AT A TIME and only the two text columns are read;
  the UPDATE targets exactly one column of exactly one row. NEVER
  `updated_at` (nor any other column): `updated_at` is the store's
  write-bookkeeping stamp and the dashboard's changed-since cursor — a
  maintenance rewrite of a value must not look like a task mutation.
  A single 108 MB JSON is fine to hold in memory (three times, briefly, while
  re-encoding); the whole table at once is not, hence no bulk `UPDATE`.

  ## Candidate SQL

      SELECT id FROM tasks
       WHERE <col> IS NOT NULL
         AND <col> NOT LIKE 'z1:%'
         AND length(<col>) > 4096

  (one pass per column, ids only). Every statement runs through
  `repo().query!/3` with an explicit `timeout: 600_000` — the repo's
  connection budget is 60 s by default and a 108 MB decode/compress statement
  legitimately runs past it — and `log: false` so a per-row statement never
  becomes a log line (the per-RUN summary below is the log output).

  ## Idempotent + failure behaviour

    * Already-compressed rows (`"z1:"` prefix — `Codec`'s marker) are skipped
      by the candidate predicate AND re-checked inside the UPDATE's own WHERE
      clause, so a second boot/migration run rewrites nothing.
    * Rows whose re-encoded value shrinks below the threshold (the archive strip
      can take a 108 MB `result` down to a few hundred bytes) are stored as
      plain JSON — `Codec` only compresses what is still > 4096 bytes, and the
      post-condition predicate is length-based, so that is a correct final
      state.
    * A row that cannot be decoded is NEVER fatal: the migration logs a
      `Logger.warning` naming the task id + column + reason and moves on. This
      should be rare — the data-normalization migration canonicalized every
      `result` on the same boot — and such a row is excluded from the
      post-condition so one corrupt blob cannot wedge an application upgrade.
    * A per-run SUMMARY is logged once per column (rows rewritten, bytes
      before/after, rows skipped), never one line per row.

  ## Post-condition

  For BOTH columns: no row may remain with

      length(<col>) > 4096 AND <col> NOT LIKE 'z1:%' AND json_valid(<col>) = 1

  (excluding the handful of undecodable ids logged above). That proves each
  surviving oversized plain-JSON row is one this migration deliberately left
  alone, not one it missed.

  ## No `down/0`

  Defined as `up/0` only, like its sibling migrations. The rewrite is
  destructive by design — it drops the duplicated `archive_records` copy from
  `result` and replaces the payload with a compressed stream — and the
  original plain JSON is not retained anywhere, so a rollback could only
  produce a semantically wrong (uncompressed-looking, archive-restored?) row.
  Rewriting user blobs cannot be reversed.
  """

  use Ecto.Migration

  require Logger

  alias EvoGit.Store.Codec
  alias EvoGit.TaskRegistry.ArchiveDedup

  @columns ~w(result archive_metadata)a

  # Mirrors `EvoGit.Store.Codec`'s compression threshold and marker. Kept as
  # literals here (a migration must not silently follow a future codec change:
  # it rewrites rows to a FINAL state, so its own predicate has to stay the
  # one this version of the codec produces).
  @compress_threshold 4096
  @compressed_prefix "z1:"

  # The repo's default connection budget is 60 s; a 108 MB decode + Level-1
  # deflate comfortably exceeds it.
  @statement_timeout 600_000

  def up do
    outcomes = Enum.map(@columns, &rewrite_column/1)
    assert_no_remaining_oversized!(Enum.flat_map(outcomes, & &1.skipped))
  end

  ## Per-column pass

  defp rewrite_column(column) do
    ids = oversized_ids(column)

    acc =
      Enum.reduce(ids, %{rewritten: 0, skipped: [], before: 0, after: 0}, fn id, acc ->
        case rewrite_row(column, id) do
          {:ok, before, after_} ->
            %{
              acc
              | rewritten: acc.rewritten + 1,
                before: acc.before + before,
                after: acc.after + after_
            }

          :skip ->
            %{acc | skipped: [id | acc.skipped]}
        end
      end)

    Logger.info(
      "[migration 20260815000004] #{column}: rewrote #{acc.rewritten} row(s) — " <>
        "#{format_bytes(acc.before)} -> #{format_bytes(acc.after)}; " <>
        "#{length(acc.skipped)} row(s) left untouched" <>
        if(acc.skipped == [],
          do: "",
          else: " (undecodable: #{acc.skipped |> Enum.reverse() |> Enum.join(", ")})"
        )
    )

    %{skipped: acc.skipped}
  end

  defp rewrite_row(column, id) do
    case fetch_column(column, id) do
      {:ok, value} when is_binary(value) ->
        if still_oversized_plain?(value) do
          reencode_and_write(column, id, value)
        else
          # Another process already compressed it (or the row changed since the
          # id sweep) — nothing to do.
          :skip
        end

      _ ->
        # Vanished / NULLed between the sweep and the read.
        :skip
    end
  end

  defp reencode_and_write(column, id, value) do
    case reencode(column, value) do
      {:ok, encoded} ->
        write_column(column, id, encoded)
        {:ok, byte_size(value), byte_size(encoded)}

      {:error, reason} ->
        Logger.warning(
          "[migration 20260815000004] skipping task #{id}: #{column} could not be " <>
            "decoded (#{format_reason(reason)}); the row is left exactly as it was"
        )

        :skip
    end
  end

  # `result` — strict decode (mirrors the Store's own read path), archive key
  # stripped, transparently compressed on encode.
  defp reencode(:result, value) do
    case decode(fn -> Codec.decode_result(value) end) do
      {:ok, nil} ->
        {:error, :empty_result}

      {:ok, result} ->
        encode(fn -> Codec.encode_result(ArchiveDedup.strip_archive_records(result)) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `archive_metadata` — lenient decode (a corrupt payload degrades to `nil`
  # rather than raising), so a nil on non-nil input is the undecodable signal;
  # writing that nil back would DESTROY the archive, so it is a skip.
  defp reencode(:archive_metadata, value) do
    case decode(fn -> Codec.decode_archive(value) end) do
      {:ok, nil} -> {:error, :undecodable_archive}
      {:ok, archive} -> encode(fn -> Codec.encode_archive(archive) end)
      {:error, reason} -> {:error, reason}
    end
  end

  # Justified try/rescue: a migration over arbitrary pre-existing user blobs
  # must never abort an application upgrade because one row is corrupt — the
  # caller logs the failure and leaves that row untouched. Nothing is
  # swallowed: the reason reaches the caller and the log.
  defp decode(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp encode(fun) do
    case fun.() do
      nil -> {:error, :encode_returned_nil}
      encoded when is_binary(encoded) -> {:ok, encoded}
      other -> {:error, {:unexpected_encoded_value, other}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  ## Statements

  defp oversized_ids(column) do
    """
    SELECT id FROM tasks
     WHERE #{column} IS NOT NULL
       AND #{column} NOT LIKE '#{@compressed_prefix}%'
       AND length(#{column}) > #{@compress_threshold}
    """
    |> select_ids([])
  end

  defp fetch_column(column, id) do
    case repo().query(
           "SELECT #{column} FROM tasks WHERE id = ?",
           [id],
           timeout: @statement_timeout,
           log: false
         ) do
      {:ok, %{rows: [[value]]}} -> {:ok, value}
      _other -> :error
    end
  end

  # The candidate predicate is REPEATED in the UPDATE's WHERE clause: if the
  # row changed between the sweep and this write (or a concurrent boot already
  # rewrote it), the update matches nothing instead of clobbering it.
  defp write_column(column, id, encoded) do
    sql(
      """
      UPDATE tasks
         SET #{column} = ?
       WHERE id = ?
         AND #{column} IS NOT NULL
         AND #{column} NOT LIKE '#{@compressed_prefix}%'
      """,
      # 108 MB payloads: params, never string interpolation.
      [encoded, id]
    )
  end

  defp select_ids(statement, params) do
    case repo().query(statement, params, timeout: @statement_timeout, log: false) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [id] -> id end)
      _other -> []
    end
  end

  defp sql(statement, params) do
    repo().query!(statement, params, timeout: @statement_timeout, log: false)
  end

  ## Guards / post-condition

  defp still_oversized_plain?(value) do
    not String.starts_with?(value, @compressed_prefix) and byte_size(value) > @compress_threshold
  end

  # Post-condition: every oversized plain-JSON value this migration COULD decode
  # is now compressed (or legitimately shrunk below the threshold). Ids the
  # rewrite logged as undecodable are excluded — a corrupt blob must not wedge
  # the upgrade; the run summary above names them.
  defp assert_no_remaining_oversized!(skipped) do
    Enum.each(@columns, fn column ->
      case remaining_oversized_ids(column, skipped) do
        [] ->
          :ok

        ids ->
          raise Ecto.MigrationError,
                "compress-oversized-rows did not converge: #{length(ids)} row(s) still hold " <>
                  "an oversized uncompressed JSON #{column} (e.g. #{Enum.take(ids, 5) |> Enum.join(", ")}); " <>
                  "the migration's UPDATE did not take effect"
      end
    end)

    :ok
  end

  defp remaining_oversized_ids(column, skipped) do
    {exclusion, params} = exclusion_clause(skipped)

    """
    SELECT id FROM tasks
     WHERE #{column} IS NOT NULL
       AND #{column} NOT LIKE '#{@compressed_prefix}%'
       AND length(#{column}) > #{@compress_threshold}
       AND json_valid(#{column}) = 1
       #{exclusion}
    """
    |> select_ids(params)
  end

  defp exclusion_clause([]), do: {"", []}

  defp exclusion_clause(skipped) do
    placeholders = skipped |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")
    {"AND id NOT IN (#{placeholders})", skipped}
  end

  # A codec decode error embeds the offending VALUE in its message, and that
  # value can be a 100 MB blob — truncate so a corrupt row cannot dump its blob
  # into the log.
  defp format_reason(reason) do
    text = inspect(reason)

    if String.length(text) > 300, do: String.slice(text, 0, 300) <> "…", else: text
  end

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"
  defp format_bytes(bytes), do: "#{bytes} B"
end
