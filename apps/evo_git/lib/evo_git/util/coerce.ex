defmodule EvoGit.Util.Coerce do
  @moduledoc """
  Total coercions for values that arrive from TOML, JSON or tool arguments.

  Both functions normalize instead of raising: a value that cannot be coerced
  answers the caller's default (or `nil`), so a bad config key or tool
  argument degrades to the documented default rather than crashing a task.
  """

  @doc """
  Returns `value` when it is an integer greater than zero, else `default`
  when THAT is an integer greater than zero, else `nil`.

  ONE contract: a non-positive value (zero, a negative number, `nil` or a
  non-integer) is treated as ABSENT, never as `0` — so a `0` read from a
  config file or a tool argument can never silently disable a limit or a
  window.
  """
  @spec positive_integer(term(), pos_integer() | nil) :: pos_integer() | nil
  def positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  def positive_integer(_value, default) when is_integer(default) and default > 0, do: default

  def positive_integer(_value, _default), do: nil

  @doc """
  Normalizes an optional string-like value to a trimmed non-empty binary.

  - `nil` → `nil`;
  - a binary → its trimmed form, or `nil` when the trim is empty;
  - any term implementing `String.Chars` (atom, number, charlist) → its
    stringified form trimmed, or `nil` when that trim is empty;
  - any other term (a map, tuple or struct without a `String.Chars`
    implementation) → `nil`.

  Never raises: a value with no printable form is simply absent.
  """
  @spec to_non_empty_string(term()) :: String.t() | nil
  def to_non_empty_string(nil), do: nil

  def to_non_empty_string(value) when is_binary(value) do
    trim_to_nil(value)
  end

  def to_non_empty_string(value) do
    # `String.Chars.impl_for/1` is the non-raising way to ask "can this term be
    # stringified?" — calling `to_string/1` blindly would raise for maps,
    # tuples and structs without the protocol.
    if String.Chars.impl_for(value) do
      value |> to_string() |> trim_to_nil()
    else
      nil
    end
  end

  defp trim_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
