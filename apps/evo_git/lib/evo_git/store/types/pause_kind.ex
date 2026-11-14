defmodule EvoGit.Store.Types.PauseKind do
  @moduledoc """
  Ecto.Type for the `tasks.pause_kind` column — a THIN delegation to
  `EvoGit.Store.Codec` (the wire oracle), like every other store type.

  ## Value set

  `"clean"` · `"dirty"` · `NULL` — declared once by
  `EvoGit.Store.Codec.pause_kinds/0`.

  The column is a PERSISTED TASK FACT recording HOW a paused task is paused,
  and it is `nil` whenever the task is NOT paused — there is deliberately no
  default value (unlike `Type.SessionMode`, whose NULL means `"oneshot"`): a
  running, completed or cancelled task simply has no pause kind, and only a
  `:pausing`/`:paused` task row carries one.

  Mapping: `"clean"` ↔ `:clean`, `"dirty"` ↔ `:dirty`, `nil` ↔ `nil`.

  Both directions are TOTAL: `load/1` maps an unknown/garbage stored value to
  `nil` (logged, never raised), and `dump/1` maps anything it does not
  recognize to `nil`, so neither a read nor a write can crash on this column —
  and an unreadable value can never make a task claim to be paused.

  Pure module — no Repo, no GenServer, no I/O.
  """

  use Ecto.Type

  alias EvoGit.Store.Codec

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}

  # Atoms are accepted for round-trip safety of a value that has already been
  # decoded; only the two canonical kinds are valid.
  def cast(kind) when is_atom(kind) do
    if Atom.to_string(kind) in Codec.pause_kinds(), do: {:ok, kind}, else: :error
  end

  def cast(kind) when is_binary(kind) do
    case Codec.decode_pause_kind(kind) do
      nil -> :error
      decoded -> {:ok, decoded}
    end
  end

  def cast(_other), do: :error

  @impl Ecto.Type
  def dump(value), do: {:ok, Codec.encode_pause_kind(value)}

  @impl Ecto.Type
  def load(value), do: {:ok, Codec.decode_pause_kind(value)}

  @impl Ecto.Type
  def embed_as(_format), do: :self
end
