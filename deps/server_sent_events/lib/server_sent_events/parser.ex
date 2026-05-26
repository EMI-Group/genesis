defmodule ServerSentEvents.Parser do
  @moduledoc false

  @type event :: %{
          required(:data) => binary(),
          optional(:event) => binary(),
          optional(:id) => binary(),
          optional(:retry) => non_neg_integer()
        }

  @type state :: %__MODULE__{
          phase: :start | :field | :key | :value_start | :value | :skip_line | :cr,
          key: nil | binary() | :event | :data | :id | :retry,
          value: nil | binary() | [binary()],
          event: nil | map()
        }

  defstruct [:phase, :key, :value, :event]

  def parse(input) when is_binary(input) do
    parse(%__MODULE__{phase: :start}, input)
  end

  def parse(%__MODULE__{phase: phase, key: key, value: value, event: event}, input)
      when is_binary(input) do
    parse(input, phase, key, value, event, [])
  end

  defp parse(<<>>, phase, key, value, event, events) do
    {Enum.reverse(events), %__MODULE__{phase: phase, key: key, value: value, event: event}}
  end

  # Event separator
  defp parse(<<byte, rest::binary>>, :field, nil, nil, event, events) when byte in ~c'\n\r' do
    case rest do
      <<?\n, rest::binary>> when byte == ?\r ->
        parse(rest, :field, nil, nil, nil, finalize(events, event))

      <<>> when byte == ?\r ->
        # Eagerly finalize the event if the stream ends with a CR. However, carry over
        # state about the CR so that if the next chunk starts with a LF, we know to skip it.
        events = finalize(events, event)
        {Enum.reverse(events), %__MODULE__{phase: :cr, event: nil, key: nil, value: nil}}

      rest ->
        parse(rest, :field, nil, nil, nil, finalize(events, event))
    end
  end

  # Parse a field
  defp parse(input, :field, nil, nil, event, events) do
    case input do
      <<"event:", rest::binary>> ->
        parse(rest, :value_start, :event, nil, event, events)

      <<"data:", rest::binary>> ->
        parse(rest, :value_start, :data, nil, event, events)

      <<"id:", rest::binary>> ->
        parse(rest, :value_start, :id, nil, event, events)

      <<"retry:", rest::binary>> ->
        parse(rest, :value_start, :retry, nil, event, events)

      # A comment line (starting with a colon) is to be ignored
      <<?:, rest::binary>> ->
        skip_line(rest, event, events)

      input ->
        do_key(input, input, 0, nil, event, events)
    end
  end

  # A single leading space (if present) is to be ignored when parsing the value
  defp parse(input, :value_start, key, nil, event, events) do
    case input do
      <<?\s, rest::binary>> ->
        do_value(rest, rest, 0, key, nil, event, events)

      input ->
        do_value(input, input, 0, key, nil, event, events)
    end
  end

  # Resume parsing a field's value that was split across chunks
  defp parse(input, :value, key, value, event, events) do
    do_value(input, input, 0, key, value, event, events)
  end

  # Resume parsing a field's key that was split across chunks
  defp parse(input, :key, key, nil, event, events) do
    do_key(input, input, 0, key, event, events)
  end

  # Skip a LF that immediately follows a CR from a previous chunk
  defp parse(input, :cr, nil, nil, event, events) do
    case input do
      <<?\n, rest::binary>> ->
        parse(rest, :field, nil, nil, event, events)

      input ->
        parse(input, :field, nil, nil, event, events)
    end
  end

  defp parse(input, :skip_line, nil, nil, event, events) do
    skip_line(input, event, events)
  end

  # A single leading BOM is to be ignored (if present) at the start of the stream
  defp parse(input, :start, nil, nil, nil, []) do
    case input do
      <<0xFEFF::utf8, rest::binary>> ->
        parse(rest, :field, nil, nil, nil, [])

      _ ->
        parse(input, :field, nil, nil, nil, [])
    end
  end

  defp do_key(<<?:, rest::binary>>, input, len, key, event, events) do
    case to_key(input, len, key) do
      :ignore -> skip_line(rest, event, events)
      key -> parse(rest, :value_start, key, nil, event, events)
    end
  end

  defp do_key(<<byte, rest::binary>>, input, len, key, event, events) when byte in ~c'\n\r' do
    event = put_field(event, to_key(input, len, key), "")

    case rest do
      <<?\n, rest::binary>> when byte == ?\r ->
        parse(rest, :field, nil, nil, event, events)

      <<>> when byte == ?\r ->
        {Enum.reverse(events), %__MODULE__{phase: :cr, event: event, key: nil, value: nil}}

      rest ->
        parse(rest, :field, nil, nil, event, events)
    end
  end

  defp do_key(<<_, rest::binary>>, input, len, key, event, events) do
    do_key(rest, input, len + 1, key, event, events)
  end

  defp do_key(<<>>, input, len, key, event, events) do
    part = binary_part(input, 0, len) |> :binary.copy()

    buffer =
      cond do
        is_nil(key) -> part
        is_binary(key) -> key <> part
      end

    {Enum.reverse(events), %__MODULE__{phase: :key, key: buffer, value: nil, event: event}}
  end

  defp do_value(<<byte, rest::binary>>, input, len, key, value, event, events)
       when byte in ~c'\n\r' do
    event = put_field(event, key, to_value(input, len, value))

    case rest do
      <<?\n, rest::binary>> when byte == ?\r ->
        parse(rest, :field, nil, nil, event, events)

      <<>> when byte == ?\r ->
        {Enum.reverse(events), %__MODULE__{phase: :cr, event: event, key: nil, value: nil}}

      rest ->
        parse(rest, :field, nil, nil, event, events)
    end
  end

  defp do_value(<<_, rest::binary>>, input, len, key, value, event, events) do
    do_value(rest, input, len + 1, key, value, event, events)
  end

  defp do_value(<<>>, input, len, key, value, event, events) do
    value = to_value(input, len, value)
    {Enum.reverse(events), %__MODULE__{phase: :value, key: key, value: value, event: event}}
  end

  defp skip_line(<<byte, rest::binary>>, event, events) when byte in ~c'\n\r' do
    case rest do
      <<?\n, rest::binary>> when byte == ?\r ->
        parse(rest, :field, nil, nil, event, events)

      <<>> when byte == ?\r ->
        {Enum.reverse(events), %__MODULE__{phase: :cr, event: event, key: nil, value: nil}}

      rest ->
        parse(rest, :field, nil, nil, event, events)
    end
  end

  defp skip_line(<<_, rest::binary>>, event, events) do
    skip_line(rest, event, events)
  end

  defp skip_line(<<>>, event, events) do
    {Enum.reverse(events), %__MODULE__{phase: :skip_line, key: nil, value: nil, event: event}}
  end

  defp copy_binary_part(input, start, len) do
    binary_part(input, start, len) |> :binary.copy()
  end

  defp to_key(input, len, nil) do
    copy_binary_part(input, 0, len) |> to_key()
  end

  defp to_key(_input, 0, key) when is_binary(key) do
    to_key(key)
  end

  defp to_key(input, len, key) when is_binary(key) and len > 0 do
    to_key(key <> binary_part(input, 0, len))
  end

  defp to_key("event"), do: :event
  defp to_key("data"), do: :data
  defp to_key("id"), do: :id
  defp to_key("retry"), do: :retry
  defp to_key(_key), do: :ignore

  defp to_value(input, len, nil), do: copy_binary_part(input, 0, len)
  defp to_value(input, len, buffer), do: [buffer | copy_binary_part(input, 0, len)]

  defp put_field(event, :data, value) do
    case event || %{} do
      %{data: data} ->
        # We keep data as an iolist until the event is finalized so that
        # we can efficiently append to it if there are multiple data lines
        %{event | data: [data | [?\n | value]]}

      event ->
        Map.put(event, :data, :erlang.iolist_to_binary(value))
    end
  end

  defp put_field(event, :event, value) do
    Map.put(event || %{}, :event, :erlang.iolist_to_binary(value))
  end

  defp put_field(event, :id, value) do
    value = :erlang.iolist_to_binary(value)

    case :binary.match(value, <<0>>) do
      :nomatch -> Map.put(event || %{}, :id, value)
      {_position, _length} -> event
    end
  end

  defp put_field(event, :retry, value) do
    value = :erlang.iolist_to_binary(value)

    case parse_int(value) do
      :error -> event
      integer -> Map.put(event || %{}, :retry, integer)
    end
  end

  defp put_field(event, :ignore, _value), do: event

  defp parse_int(<<>>), do: :error
  defp parse_int(input) when is_binary(input), do: parse_int(input, 0)

  defp parse_int(<<>>, int), do: int
  defp parse_int(<<c, r::binary>>, int) when c in ?0..?9, do: parse_int(r, int * 10 + (c - ?0))
  defp parse_int(_, _), do: :error

  defp finalize(events, %{data: data} = event) do
    event =
      if is_list(data) do
        %{event | data: :erlang.iolist_to_binary(data)}
      else
        event
      end

    [event | events]
  end

  defp finalize(events, _), do: events
end
