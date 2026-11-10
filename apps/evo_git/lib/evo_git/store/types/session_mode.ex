defmodule EvoGit.Store.Types.SessionMode do
  @moduledoc """
  Ecto.Type for the `tasks.session_mode` column — a THIN delegation to
  `EvoGit.Store.Codec` (the wire oracle), like every other store type.

  ## Value set

  `"oneshot"` (default) · `"interactive"` — declared once by
  `EvoGit.Store.Codec.session_modes/0`.

  The column is the task's DRIVER mode: `"oneshot"` is today's one-shot agent
  (a tool-free reply finishes the run), `"interactive"` is a session that
  yields to the non-terminal `:awaiting_input` status and waits for the next
  message. It exists so the dashboard can filter sessions out of the ordinary
  task list.

  Both directions are TOTAL: `load/1` normalizes a NULL (a row written before
  the column existed) and an unknown spelling to `"oneshot"`, and `dump/1`
  normalizes anything it does not recognize the same way, so neither a read
  nor a write can crash on this column.

  Pure module — no Repo, no GenServer, no I/O.
  """

  use Ecto.Type

  alias EvoGit.Store.Codec

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, Codec.default_session_mode()}

  # Atoms are accepted (and normalized to their string) only for round-trip
  # safety of a value that has already been decoded; the DATA PLANE carries
  # the mode as a string.
  def cast(mode) when is_atom(mode), do: {:ok, Codec.encode_session_mode(mode)}

  def cast(mode) when is_binary(mode) do
    if mode in Codec.session_modes(), do: {:ok, mode}, else: :error
  end

  def cast(_other), do: :error

  @impl Ecto.Type
  def dump(value), do: {:ok, Codec.encode_session_mode(value)}

  @impl Ecto.Type
  def load(value), do: {:ok, Codec.decode_session_mode(value)}

  @impl Ecto.Type
  def embed_as(_format), do: :self
end
