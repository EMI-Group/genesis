defmodule EvoDashWeb.AgentsLive.StreamLimits do
  @moduledoc """
  Inspector live-excerpt retention policy, independent of checkpoint history.

  Text keeps a UTF-8-safe prefix, copied so a small excerpt cannot pin a large
  incoming binary. Omission counts are bytes, not graphemes. Each discarded
  incoming byte is counted, including content supplied by replacement snapshots
  or yield events; counters are cumulative within a projection until resync.
  Identity and capture coverage are never synthesized from truncated content.
  """

  @doc "Maximum retained live projections (newest kept)."
  def max_projections, do: 12

  @doc "Maximum retained bytes per response AND per thinking excerpt, independently."
  def max_text_bytes, do: 48_000

  @doc "Maximum retained tool descriptors per projection (first announcements kept)."
  def max_tools, do: 20

  @doc "Maximum retained bytes per tool name."
  def max_tool_name_bytes, do: 1_024

  @doc "Returns a copied UTF-8 prefix and the exact number of bytes not retained."
  def preview(value, limit) when is_binary(value) and is_integer(limit) and limit >= 0 do
    prefix = binary_part(value, 0, min(byte_size(value), limit))

    retained =
      case :unicode.characters_to_binary(prefix) do
        binary when is_binary(binary) -> binary
        {_kind, valid, _rest} -> valid
      end
      |> :binary.copy()

    {retained, byte_size(value) - byte_size(retained)}
  end

  @doc "Appends only bytes that fit, without first concatenating an unbounded chunk."
  def append(previous, chunk) do
    {suffix, omitted} = preview(chunk, max(max_text_bytes() - byte_size(previous), 0))
    {previous <> suffix, omitted}
  end
end
