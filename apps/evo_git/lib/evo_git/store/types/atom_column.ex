defmodule EvoGit.Store.Types.AtomColumn do
  @moduledoc """
  Ecto.Type for the atom↔TEXT columns of the EvoGit task store
  (`tasks.type`, `tasks.status`, `tasks.review_status`).

  This type is a THIN delegation to `EvoGit.Store.Codec` — the Codec is the
  single source of truth for the on-disk wire format and stays byte-compatible
  with existing user databases. No encoding logic is duplicated here.

  ## Wire format

  `atom() | String.t() | nil` ↔ TEXT. `Codec.encode_atom/1` accepts nil, atoms,
  and strings (a decoded value can always be re-encoded without crashing —
  round-trip safety). `Codec.decode_atom/1` is DECODE-STRICT over the closed
  atom set (`@known_atoms` in the Codec — the union of the `type`, `status`,
  and `review_status` values): a known string becomes its atom, anything else
  logs a warning and decodes to `nil`.

  The three columns share this ONE closed set inside the Codec (there is no
  per-column decode function to delegate to), so this type validates against
  the union. The named wrappers `EvoGit.Store.Types.Status`,
  `EvoGit.Store.Types.TaskType`, and `EvoGit.Store.Types.ReviewStatus` all
  delegate here unchanged — they exist for schema readability and carry each
  column's documented value set; they are NOT narrower validators (narrowing
  would deviate from the Codec's wire behavior).

  > #### Unknown values decode to nil {: .warning}
  > `load/1` returns `{:ok, nil}` for an unknown/corrupt TEXT value — exactly
  > like `Codec.decode_atom/1`. Use `EvoGit.Store.Codec.decode_atom/1`
  > directly when you need the warning log; the behavior (the decoded value)
  > is identical.

  Pure module — no Repo, no GenServer, no I/O.
  """

  use Ecto.Type

  alias EvoGit.Store.Codec

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}

  # Atoms and the equivalent strings are interchangeable on cast — mirrors
  # Codec.encode_atom/1's acceptance of both.
  def cast(value) when is_atom(value), do: {:ok, value}

  def cast(value) when is_binary(value), do: {:ok, value}

  def cast(_), do: :error

  @impl Ecto.Type
  def dump(value), do: {:ok, Codec.encode_atom(value)}

  @impl Ecto.Type
  def load(value), do: {:ok, Codec.decode_atom(value)}

  @impl Ecto.Type
  def embed_as(_format), do: :self
end

defmodule EvoGit.Store.Types.Status do
  @moduledoc """
  Ecto.Type for the `tasks.status` column — delegates entirely to
  `EvoGit.Store.Types.AtomColumn` (and through it to
  `EvoGit.Store.Codec.encode_atom/1` / `decode_atom/1`).

  Documented value set (`%TaskInfo{}` status):

    `:pending` · `:running` · `:finalizing` · `:completed` · `:failed` ·
    `:cancelled` · `:cancelling`

  Pure module — no Repo, no GenServer, no I/O.
  """

  alias EvoGit.Store.Types.AtomColumn

  defdelegate type, to: AtomColumn
  defdelegate cast(value), to: AtomColumn
  defdelegate dump(value), to: AtomColumn
  defdelegate load(value), to: AtomColumn
  defdelegate embed_as(format), to: AtomColumn
end

defmodule EvoGit.Store.Types.TaskType do
  @moduledoc """
  Ecto.Type for the `tasks.type` column — delegates entirely to
  `EvoGit.Store.Types.AtomColumn` (and through it to
  `EvoGit.Store.Codec.encode_atom/1` / `decode_atom/1`).

  Documented value set (`TaskRegistry` task types):

    `:genesis` · `:evolve` · `:extract_skills` · `:reflect`

  Pure module — no Repo, no GenServer, no I/O.
  """

  alias EvoGit.Store.Types.AtomColumn

  defdelegate type, to: AtomColumn
  defdelegate cast(value), to: AtomColumn
  defdelegate dump(value), to: AtomColumn
  defdelegate load(value), to: AtomColumn
  defdelegate embed_as(format), to: AtomColumn
end

defmodule EvoGit.Store.Types.ReviewStatus do
  @moduledoc """
  Ecto.Type for the `tasks.review_status` column — delegates entirely to
  `EvoGit.Store.Types.AtomColumn` (and through it to
  `EvoGit.Store.Codec.encode_atom/1` / `decode_atom/1`).

  Documented value set:

    `:open` · `:merged` · `:rejected` · `:continued` · `:ignored` · `:no_changes`

  Pure module — no Repo, no GenServer, no I/O.
  """

  alias EvoGit.Store.Types.AtomColumn

  defdelegate type, to: AtomColumn
  defdelegate cast(value), to: AtomColumn
  defdelegate dump(value), to: AtomColumn
  defdelegate load(value), to: AtomColumn
  defdelegate embed_as(format), to: AtomColumn
end
