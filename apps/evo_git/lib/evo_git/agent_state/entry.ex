defmodule EvoGit.AgentState.Entry do
  @moduledoc """
  PURE checkpoint entries: validation and queue folding.

  An entry is the SMALL map `EvoGit.AgentState.checkpoint/4` casts — never a
  whole `%EvoGit.Agent.State{}`:

      %{kind: :append | :rewrite,
        base_seq: non_neg_integer() | nil,
        messages: [ReqLLM.Message.t()],
        fields: %{atom => term()},
        owner: pid()}

  `normalize/1` is the ONE validation gate (an unknown kind, a non-message list
  element, a negative `base_seq` or a non-map `fields` is `:error`), and
  `fold/1` turns a QUEUE of entries that all belong to the SAME
  `(task_id, agent_id)` into the minimal ordered list of store operations still
  needed to represent them.

  Nothing here touches a process, the database or the log: the writer
  (`EvoGit.AgentState.Server`) owns I/O, `EvoGit.AgentState.Store` owns SQL and
  `EvoGit.AgentState.Entry` owns the arithmetic, so the folding rules are
  unit-testable without a store.

  ## Fold rules

  Entries are processed in arrival order into GROUPS; a group becomes one store
  operation (`EvoGit.AgentState.Store.checkpoint_batch/4` then runs every group
  of the fold inside ONE transaction, in order).

    * A later `:rewrite` SUPERSEDES everything queued before it: the fold keeps
      no earlier operation, because a rewrite replaces the whole stored
      conversation anyway.
    * Consecutive `:append`s that CHAIN fold into ONE append — an append chains
      when its `base_seq` equals the accumulated end of the open group
      (`base_seq + length(messages)` of what it would store, so after a rewrite
      of N messages an append with `base_seq == N` chains). The folded append
      carries the FIRST entry's `base_seq` and the concatenated messages.
    * An append that does NOT chain (a GAP) closes the open group and starts a
      new one, so the operation the store sees keeps its own `base_seq` and the
      continuity rule still answers `:resync` for a genuine divergence.
    * `fields` merge LAST-WINS: a later entry's supplied keys overwrite, an
      absent key keeps the value supplied earlier. Each operation carries the
      merge accumulated through its own group, and operations are applied in
      order, so the row ends up with the last-wins value of every key — even
      for keys that were supplied only by a SUPERSEDED entry (dropping those
      would silently lose a scalar).
    * `owner` is carried through as the last non-nil owner (the writer notifies
      it on a `:resync`).
    * A `nil` `base_seq` means `0`, exactly like the store.
    * An empty queue folds to `[]` (the writer then writes nothing at all).
  """

  @typedoc """
  A normalized checkpoint entry. `owner` is `nil` when the caller supplied
  none (the writer then notifies nobody).
  """
  @type t :: %{
          kind: :append | :rewrite,
          base_seq: non_neg_integer() | nil,
          messages: [ReqLLM.Message.t()],
          fields: %{atom() => term()},
          owner: pid() | nil
        }

  @doc """
  Validates one checkpoint entry.

  Answers `{:ok, entry}` — atom-keyed, with `fields`/`owner` defaulted — or
  `:error`. Accepts the documented atom-keyed shape ONLY (both are internal
  callers: the session and the writer).
  """
  @spec normalize(term()) :: {:ok, t()} | :error
  def normalize(%{kind: kind, messages: messages} = entry)
      when kind in [:append, :rewrite] and is_list(messages) do
    fields = Map.get(entry, :fields, %{})
    base_seq = Map.get(entry, :base_seq)

    if valid_base_seq?(kind, base_seq) and is_map(fields) and valid_messages?(messages) do
      {:ok,
       %{
         kind: kind,
         base_seq: base_seq,
         messages: messages,
         fields: fields,
         owner: Map.get(entry, :owner)
       }}
    else
      :error
    end
  end

  def normalize(_entry), do: :error

  @doc """
  Folds an arrival-ordered queue of entries for ONE run into the minimal
  ordered list of store operations (see the module doc for the rules).

  Total: an entry `normalize/1` rejects is IGNORED (the writer decides what to
  log), and a non-list argument folds to `[]`.
  """
  @spec fold([t()]) :: [t()]
  def fold(entries) when is_list(entries) do
    entries
    |> Enum.reduce(%{ops: [], open: nil, fields: %{}, owner: nil}, &fold_entry/2)
    |> close()
    |> Map.fetch!(:ops)
    |> Enum.reverse()
  end

  def fold(_entries), do: []

  ## Folding

  defp fold_entry(entry, acc) do
    case normalize(entry) do
      {:ok, entry} -> put_entry(acc, entry)
      :error -> acc
    end
  end

  defp put_entry(acc, entry) do
    # The group is opened/closed FIRST: a group carries the fields supplied up
    # to its own entry, and every key a later (possibly superseded) entry adds
    # reaches the row through the operations that follow it.
    acc =
      case entry.kind do
        :rewrite ->
          # A rewrite REPLACES the stored conversation, so nothing queued
          # before it can still matter: drop the collected operations and
          # start over (the accumulated fields/owner survive — they are row
          # scalars, and an UPSERT only touches the keys it supplies).
          open(%{acc | ops: [], open: nil}, :rewrite, nil, entry.messages)

        :append ->
          chain(acc, entry)
      end

    %{
      acc
      | fields: Map.merge(acc.fields, entry.fields),
        owner: entry.owner || acc.owner
    }
  end

  defp chain(%{open: %{end_seq: end_seq} = open} = acc, entry) do
    base = entry.base_seq || 0

    if base == end_seq do
      messages = open.messages ++ entry.messages
      %{acc | open: %{open | messages: messages, end_seq: base + length(entry.messages)}}
    else
      open(acc, :append, entry.base_seq, entry.messages)
    end
  end

  defp chain(acc, entry), do: open(acc, :append, entry.base_seq, entry.messages)

  defp open(acc, kind, base_seq, messages) do
    acc = close(acc)
    end_seq = (base_seq || 0) + length(messages)
    %{acc | open: %{kind: kind, base_seq: base_seq, messages: messages, end_seq: end_seq}}
  end

  defp close(%{open: nil} = acc), do: acc

  defp close(%{open: open} = acc) do
    op = %{
      kind: open.kind,
      base_seq: open.base_seq,
      messages: open.messages,
      fields: acc.fields,
      owner: acc.owner
    }

    %{acc | ops: [op | acc.ops], open: nil}
  end

  ## Validation

  defp valid_base_seq?(:append, nil), do: true
  defp valid_base_seq?(:append, base_seq), do: is_integer(base_seq) and base_seq >= 0
  defp valid_base_seq?(:rewrite, _base_seq), do: true

  defp valid_messages?(messages) do
    Enum.all?(messages, fn message -> is_struct(message, ReqLLM.Message) end)
  end
end
