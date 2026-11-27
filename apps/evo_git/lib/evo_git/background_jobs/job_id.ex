defmodule EvoGit.BackgroundJobs.JobId do
  # Declared before the moduledoc so the doc text can interpolate them.
  @prefix "bash-"
  @alphabet "0123456789abcdefghijklmnopqrstuvwxyz"
  @payload_max 8
  # 36^8 — one id per base36 payload of at most `@payload_max` characters.
  @space 2_821_109_907_456

  @moduledoc """
  Pure id minting for the background-job registry.
  An id is the short random base36 token `#{@prefix}<payload>`, where the payload is 1..#{@payload_max} characters of `[0-9a-z]` — e.g. `bash-7f3k2`.
  An agent repeats an id in `job_output` / `job_kill` and reads it in notices, so it stays short instead of becoming a long hex GUID.
  The randomness is what makes the ID ITSELF globally unique: two registries (another BEAM, or a `mix test` VM) may share one scratch dir, so the id is also the job's log-file address (`genesis_job_<id>.log`) and stays unique across every registry writing there.
  `mint/2` draws a random integer, normalizes it into the `0..#{@space - 1}` payload space, encodes it in base36 and linearly advances by one on a collision.
  The scan is bounded to ONE full pass of the payload space: a registry that cannot find a free id answers `{:error, :id_space_exhausted}` instead of looping.
  Nothing here reads app env, the process dictionary or any process state: the caller passes the taken ids in.
  """

  # DERIVED from `@prefix` + the alphabet char class + `@payload_max`, so the
  # pattern and the encoder can never drift apart.
  @id_pattern Regex.compile!("\\A#{Regex.escape(@prefix)}[0-9a-z]{1,#{@payload_max}}\\z")

  # The production candidate source: 64 random bits folded into the payload
  # space by `encode/1`.
  defp default_source, do: :crypto.strong_rand_bytes(8) |> :binary.decode_unsigned()

  @doc "The fixed id prefix every job id starts with."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc "The base36 digits a payload is drawn from (lowercase, ascending by value)."
  @spec alphabet() :: String.t()
  def alphabet, do: @alphabet

  @doc "Maximum payload length in characters (`#{@payload_max}`), i.e. the widest base36 encoding used."
  @spec payload_max() :: pos_integer()
  def payload_max, do: @payload_max

  @doc "Total number of distinct ids in the payload space (`36^#{@payload_max}`)."
  @spec space() :: pos_integer()
  def space, do: @space

  @doc """
  True only for a string matching exactly `#{@prefix}` plus 1..#{@payload_max} characters of `[0-9a-z]`.
  """
  @spec valid?(term()) :: boolean()
  def valid?(id) when is_binary(id), do: Regex.match?(@id_pattern, id)
  def valid?(_id), do: false

  @doc """
  Mints an id no `taken` id holds.

  `taken` is a map keyed by id, a `MapSet` of ids, or a 1-arity fun `(id -> boolean)`; all three become ONE predicate. Anything else raises `ArgumentError`.

  Options: `:candidate_source`, a 0-arity fun returning a non-negative integer (test seam only) used instead of the crypto default.

  On a collision the candidate advances deterministically by one in payload space, so an id held by a live job OR a tombstone is never reissued while any answer for it exists. After one full pass of the space with every candidate taken the answer is `{:error, :id_space_exhausted}`.
  """
  @spec mint(map() | MapSet.t() | (String.t() -> boolean()), keyword()) ::
          String.t() | {:error, :id_space_exhausted}
  def mint(taken, opts \\ []) do
    taken? = taken_predicate(taken)
    source = candidate_source(opts)

    case scan(source.(), taken?) do
      {:ok, id} -> id
      {:error, :id_space_exhausted} -> {:error, :id_space_exhausted}
    end
  end

  ## Encoding

  # Accepts any integer (negative, huge, …) by folding it into the payload
  # space, so an encoded payload never exceeds `@payload_max` characters.
  defp encode(int) do
    @prefix <> (Integer.mod(int, @space) |> Integer.to_string(36) |> String.downcase())
  end

  # The candidate walks +1 in payload space on every collision, so an id held by
  # a live job or a tombstone is skipped deterministically rather than
  # re-drawn.
  # The walk is bounded to ONE full pass of the payload space (`@space`
  # candidates): when every one of them is taken the answer is
  # `{:error, :id_space_exhausted}` — never an unbounded loop.
  defp scan(int, taken?) do
    Enum.reduce_while(1..@space, {:error, :id_space_exhausted}, fn attempt, error ->
      candidate = encode(Integer.mod(int + attempt - 1, @space))

      if taken?.(candidate), do: {:cont, error}, else: {:halt, {:ok, candidate}}
    end)
  end

  ## Input normalization

  defp taken_predicate(%MapSet{} = taken), do: fn id -> MapSet.member?(taken, id) end
  defp taken_predicate(taken) when is_function(taken, 1), do: taken

  defp taken_predicate(taken) when is_map(taken) and not is_struct(taken),
    do: fn id -> is_map_key(taken, id) end

  defp taken_predicate(other) do
    raise ArgumentError,
          "expected the taken ids as a map, a MapSet or a 1-arity fun, got: #{inspect(other)}"
  end

  defp candidate_source(opts) do
    case Keyword.fetch(opts, :candidate_source) do
      {:ok, source} when is_function(source, 0) ->
        source

      {:ok, other} ->
        raise ArgumentError,
              "expected :candidate_source to be a 0-arity fun, got: #{inspect(other)}"

      :error ->
        &default_source/0
    end
  end
end
