defmodule EvoGit.Store.Types.ArchiveColumns do
  @moduledoc """
  Plain-JSON wire helpers for the `task_agent_archives` JSON TEXT columns.

  The per-agent archive table stores four JSON payloads (`usage`,
  `llm_settings`, `agent_settings`, `foreign_repos`). They are deliberately
  NOT routed through `EvoGit.Store.Codec` (which owns the legacy `tasks`
  wire format and its atom whitelists) and
  deliberately NOT modeled as domain structs:

    * **no compression, no magic prefixes** — an archive row is written ONCE
      and read per agent; the size win of compressing a per-agent `usage` map
      or settings blob does not pay for the read-path cost of decompressing
      every roster page, and it would make the columns unreadable to plain
      SQL (`json_extract`) tooling.
    * **no `%EvoGit.Agent.Usage{}` struct** — the archive `usage` is a plain
      map captured from the agent's run, not the live accounting struct. It
      must round-trip as data, so `Jason.encode!/1` / `Jason.decode/1` is the
      whole contract.
    * **`nil` is SQL NULL** — a missing JSON column stays absent (never the
      string `"null"`), so `WHERE usage IS NULL` keeps meaning "not recorded".

  `dump/1` accepts `nil`/map/list (the producer's shapes) and returns
  `:error` for anything else, exactly like every other `Ecto.Type` here.
  `load/1` is LENIENT: NULL → `nil`, valid JSON text → the decoded term, and
  corrupt text → `nil` (a single unreadable JSON column must not fail the
  whole archive page — the row is still useful).

  The JSON wire contract of `dump_json/1`:
  values are encoded as plain JSON TEXT with NO compression, NO prefix tag and
  NO atom whitelist.
  Pair-shaped containers — keyword lists, lists of 2-tuples and tuples — are
  normalized to string-keyed JSON objects BEFORE encoding, because Jason has no
  Tuple encoder and producers legitimately carry a keyword-list
  `provider_options`.
  The normalization is recursive, so a pair list nested in a map or another
  list is covered too.
  Structs are left for their own `Jason.Encoder` implementation.
  Genuinely unencodable terms (pids, refs, functions) still yield `:error`, so
  the caller sees the violation instead of a silently mangled payload.

  Pure module — no Repo, no GenServer, no I/O.
  """

  @doc """
  Encodes a JSON column value (`nil` | map | list) to its TEXT form.

  `nil` stays `nil` (SQL NULL). Pair-shaped containers are normalized to
  string-keyed maps first (see the module doc). Non-JSON-able values return
  `:error` so the caller sees the violation instead of silently storing a
  truncated payload.
  """
  @spec dump_json(nil | map() | list()) :: {:ok, String.t() | nil} | :error
  def dump_json(nil), do: {:ok, nil}

  def dump_json(value) when is_map(value) or is_list(value) do
    case Jason.encode(normalize_pairs(value)) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> :error
    end
  end

  def dump_json(_other), do: :error

  # A struct owns its own encoding (some implement `Jason.Encoder`, some are
  # genuinely unencodable) — never rebuild it from its fields.
  defp normalize_pairs(value) when is_struct(value), do: value

  defp normalize_pairs(%{} = map) do
    Map.new(map, fn {key, value} -> {key, normalize_pairs(value)} end)
  end

  defp normalize_pairs(list) when is_list(list) do
    if pairs?(list) do
      Map.new(list, fn {key, value} -> {key, normalize_pairs(value)} end)
    else
      Enum.map(list, &normalize_pairs/1)
    end
  end

  defp normalize_pairs(value), do: value

  defp pairs?([{_key, _value} | _rest] = list), do: Enum.all?(list, &pair?/1)
  defp pairs?(_list), do: false

  defp pair?({_key, _value}), do: true
  defp pair?(_other), do: false

  @doc """
  Decodes a stored JSON TEXT value back to a term.

  NULL → `nil`; corrupt or non-JSON text → `nil` (lenient by design — one bad
  column never fails the read); anything that is not a binary is `nil` too
  (the columns are TEXT, so this cannot occur in a well-formed database).
  """
  @spec load_json(nil | String.t()) :: term() | nil
  def load_json(nil), do: nil

  def load_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  def load_json(_other), do: nil
end

defmodule EvoGit.Store.Types.ArchiveUsageJson do
  @moduledoc """
  `Ecto.Type` for `task_agent_archives.usage` — a plain JSON object holding the
  archived agent's token/cost accounting.

  Deliberately a PLAIN MAP, not `%EvoGit.Agent.Usage{}`: the archive records
  what the agent reported, verbatim. See `EvoGit.Store.Types.ArchiveColumns`
  for the wire contract (plain Jason, no compression, `nil` ⇔ SQL NULL,
  corrupt text loads as `nil`).
  """

  use Ecto.Type

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_map(value) or is_list(value), do: {:ok, value}
  def cast(_other), do: :error

  @impl Ecto.Type
  def dump(value), do: EvoGit.Store.Types.ArchiveColumns.dump_json(value)

  @impl Ecto.Type
  def load(value), do: {:ok, EvoGit.Store.Types.ArchiveColumns.load_json(value)}

  @impl Ecto.Type
  def embed_as(_format), do: :self
end

defmodule EvoGit.Store.Types.ArchiveLlmSettingsJson do
  @moduledoc """
  `Ecto.Type` for `task_agent_archives.llm_settings` — the LLM settings the
  archived agent ran with, as a plain JSON object.

  See `EvoGit.Store.Types.ArchiveColumns` for the wire contract.
  """

  use Ecto.Type

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_map(value) or is_list(value), do: {:ok, value}
  def cast(_other), do: :error

  @impl Ecto.Type
  def dump(value), do: EvoGit.Store.Types.ArchiveColumns.dump_json(value)

  @impl Ecto.Type
  def load(value), do: {:ok, EvoGit.Store.Types.ArchiveColumns.load_json(value)}

  @impl Ecto.Type
  def embed_as(_format), do: :self
end

defmodule EvoGit.Store.Types.ArchiveAgentSettingsJson do
  @moduledoc """
  `Ecto.Type` for `task_agent_archives.agent_settings` — the agent settings
  (type, delegation level, turn cap, …) the archived agent ran with, as a
  plain JSON object.

  See `EvoGit.Store.Types.ArchiveColumns` for the wire contract.
  """

  use Ecto.Type

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_map(value) or is_list(value), do: {:ok, value}
  def cast(_other), do: :error

  @impl Ecto.Type
  def dump(value), do: EvoGit.Store.Types.ArchiveColumns.dump_json(value)

  @impl Ecto.Type
  def load(value), do: {:ok, EvoGit.Store.Types.ArchiveColumns.load_json(value)}

  @impl Ecto.Type
  def embed_as(_format), do: :self
end

defmodule EvoGit.Store.Types.ArchiveForeignReposJson do
  @moduledoc """
  `Ecto.Type` for `task_agent_archives.foreign_repos` — the foreign repos the
  archived agent worked with, as a plain JSON ARRAY of objects (never a list
  of `%EvoGit.Core.ForeignRepo{}` structs: the archive records the data, not
  the domain value).

  See `EvoGit.Store.Types.ArchiveColumns` for the wire contract.
  """

  use Ecto.Type

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_list(value) or is_map(value), do: {:ok, value}
  def cast(_other), do: :error

  @impl Ecto.Type
  def dump(value), do: EvoGit.Store.Types.ArchiveColumns.dump_json(value)

  @impl Ecto.Type
  def load(value), do: {:ok, EvoGit.Store.Types.ArchiveColumns.load_json(value)}

  @impl Ecto.Type
  def embed_as(_format), do: :self
end
