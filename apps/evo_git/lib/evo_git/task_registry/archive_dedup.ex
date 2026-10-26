defmodule EvoGit.TaskRegistry.ArchiveDedup do
  @moduledoc """
  The SINGLE persistence-boundary choke point that stops the per-agent archive
  from being stored TWICE in one task row.

  ## What is duplicated

  The task report produced by the runtime ( `EvoGit.Runtime.Helpers.merge_and_report/3,4`
  → `EvoGit.AgentScheduler.Lifecycle.handle_task_result/3` ) carries the
  per-agent archive list under `archive_records` in its `{:ok, data}` map. The
  scheduler also parses the SAME list out of that result and hands it to
  `EvoGit.TaskRegistry` as the `archive_records` opt, which is persisted into
  the dedicated `archive_metadata` column. Persisting the result map verbatim
  therefore writes the identical list twice — on the live database one
  completed task held a 108 MB `result` whose `data.archive_records` array was
  byte-for-byte the same list as its 108 MB `archive_metadata` column.

  ## The rule

  `archive_metadata` is the ONE stored copy. Every persistence write of a
  `result` strips the `archive_records` key from the result's data map FIRST,
  through this module — never ad hoc at the call site.

  ## Invariants

    * IN-FLIGHT result values are untouched. The `{:ok, data}` map keeps
      `archive_records` for the whole runtime — parents, the scheduler and the
      final-report builder all read it in memory. Every function here returns a
      PERSISTENCE COPY; callers must not overwrite their in-memory value with
      it.
    * `EvoGit.Store.Codec.encode_result/1` semantics are unchanged: it is still
      happy to encode a result carrying `archive_records` when called directly
      (the byte-identity oracle tests in `store/types_test.exs` rely on that).
      The stripping happens here, one layer above the codec.
    * Total functions — no I/O, no raises. Non-`{:ok, map}` result shapes
      (plain crash strings, `{:error, _}`, `{:exit, _}`, `nil`) and results
      without the key are returned unchanged, so a caller can apply this
      unconditionally.

  Used by `EvoGit.TaskRegistry` (`handle_update_status/6`,
  `resolve_recheck_task/3` and the two full-struct `put_task` sites) and by the
  `20260815000004_compress_oversized_rows` migration, which rewrites the rows
  written before this boundary existed.
  """

  alias EvoGit.TaskInfo

  # `archive_records` is a KNOWN result-data field (`Codec`'s
  # `@result_data_fields`), so a decoded result carries the ATOM key. The
  # string spelling is deleted too: it can only appear on a result that has
  # not been through the codec's atomizing decode (a hand-built map, or a
  # result re-read before the codec treated the key as known).
  @archive_keys [:archive_records, "archive_records"]

  @doc """
  Returns a persistence copy of a task `result` tuple with `archive_records`
  removed from its `{:ok, data}` map.

  Struct data maps (`%EvoGit.Agent.Result{}`) are converted to a plain map
  (the codec stores them as plain string-keyed JSON either way) so the key can
  be dropped instead of exposing an invalid struct. Anything else — a plain
  string crash fallback, `{:error, reason}`, `{:exit, reason}`, `nil`, or an
  `{:ok, non-map}` — is returned unchanged.
  """
  @spec strip_archive_records(term()) :: term()
  def strip_archive_records({:ok, %{__struct__: _} = data}) do
    {:ok, data |> Map.from_struct() |> drop_archive_keys()}
  end

  def strip_archive_records({:ok, data}) when is_map(data) do
    {:ok, drop_archive_keys(data)}
  end

  def strip_archive_records(other), do: other

  @doc """
  Applies `strip_archive_records/1` to a `%TaskInfo{}`'s `result` — the form
  the full-struct `EvoGit.Store.put_task/2` write sites need.
  """
  @spec strip_task_archive_records(TaskInfo.t()) :: TaskInfo.t()
  def strip_task_archive_records(%TaskInfo{result: result} = task) do
    %{task | result: strip_archive_records(result)}
  end

  defp drop_archive_keys(data), do: Map.drop(data, @archive_keys)
end
