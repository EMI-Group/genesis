defmodule EvoGit.Agent.Clock do
  @moduledoc """
  The agent layer's ONE clock read, and the seam that makes it deterministic.

  Per-message `metadata[:timestamp]` (`EvoGit.Agent.ContextBuilder.tag_message_turn/2`
  and `tag_message_timestamp/1`) is stamped with `now_seconds/0` — Unix
  SECONDS, the granularity the dashboard reads (`EvoDashWeb.Helpers.format_history_timestamp/1`).

  ## Default-inert pin

  With no pin installed, `now_seconds/0` returns `System.system_time(:second)`
  — exactly the production value, byte-identical to reading the system clock
  directly. `with_now/2` (and its opts sugar `with_opts/2`) installs a pin for
  the DYNAMIC EXTENT of a 0-arity fun, restoring the previous pin (or deleting
  the key when there was none) in an `after` block.

  The pin lives in the PROCESS DICTIONARY only: it is per-process, so a
  concurrently running test module can never observe it, and there is
  deliberately NO app-env global. `with_now(nil, fun)` is a pure passthrough
  (it writes nothing at all), which is what makes an absent `opts[:now]` inert.

  ## Accepted pin values

    * an integer — Unix seconds;
    * a `%DateTime{}` — converted to Unix seconds;
    * a `%NaiveDateTime{}` — interpreted as UTC and converted to Unix seconds;
    * a 0-arity function returning one of the above — called once per stamp, so
      a test can advance the clock deliberately.

  Anything else raises a descriptive `ArgumentError` (at install time for a
  value, at call time for a function result).

  ## Where the pin comes from

  `EvoGit.Agent.Exchange.run/2` and `EvoGit.Agent.Turn.run/3` wrap their whole
  body in `with_opts(opts, fun)`, so an exchange started with `now: <value>`
  stamps EVERY message it appends with that value. Nested wraps restore
  correctly: the inner one reinstalls the same value and the outer `after`
  restores whatever was installed before the exchange.
  """

  @pin_key :__evogit_agent_clock_pin__

  @typedoc """
  A clock pin: an integer Unix second, a `DateTime`, a `NaiveDateTime`
  (interpreted as UTC), or a 0-arity function returning one of those.
  """
  @type pin :: integer() | DateTime.t() | NaiveDateTime.t() | (-> pin_value())
  @type pin_value :: integer() | DateTime.t() | NaiveDateTime.t()

  @doc """
  The current clock as Unix seconds.

  Returns the pinned value when a pin is installed in THIS process, else
  `System.system_time(:second)` (the production path).
  """
  @spec now_seconds() :: integer()
  def now_seconds do
    case Process.get(@pin_key) do
      nil -> System.system_time(:second)
      pin -> resolve(pin)
    end
  end

  @doc """
  Runs `fun` with `pin` installed as this process's clock pin.

  The previous pin (if any) is restored in an `after` block, so a raising
  `fun` cannot leak the pin. `pin` of `nil` is a pure passthrough: nothing is
  written to the process dictionary, so an outer pin stays in effect.

  The accepted shapes are those of `t:pin/0`; anything else (including a
  function of the wrong arity) raises a descriptive `ArgumentError`, hence the
  `term()` parameter spec.
  """
  @spec with_now(term(), (-> result)) :: result when result: var
  def with_now(nil, fun) when is_function(fun, 0), do: fun.()

  def with_now(pin, fun) when is_function(fun, 0) do
    pin = validate_pin!(pin)
    previous = Process.get(@pin_key, :no_pin)
    Process.put(@pin_key, pin)

    try do
      fun.()
    after
      case previous do
        :no_pin -> Process.delete(@pin_key)
        previous -> Process.put(@pin_key, previous)
      end
    end
  end

  @doc """
  `with_now(Keyword.get(opts, :now), fun)` — the exchange/turn opts sugar.

  An absent `:now` key (or an explicit `nil`) is the production path: no pin is
  installed and the real clock is read.
  """
  @spec with_opts(keyword(), (-> result)) :: result when result: var
  def with_opts(opts, fun) when is_list(opts) and is_function(fun, 0) do
    with_now(Keyword.get(opts, :now), fun)
  end

  # A value pin is normalized ONCE at install time; a function pin is kept as
  # the function and its result is normalized on every stamp.
  defp validate_pin!(pin) do
    case pin do
      %DateTime{} = dt -> DateTime.to_unix(dt)
      %NaiveDateTime{} = ndt -> naive_to_unix(ndt)
      seconds when is_integer(seconds) -> seconds
      fun when is_function(fun, 0) -> fun
      other -> raise_invalid!(other)
    end
  end

  defp resolve(pin) when is_integer(pin), do: pin

  defp resolve(fun) when is_function(fun, 0) do
    case fun.() do
      %DateTime{} = dt -> DateTime.to_unix(dt)
      %NaiveDateTime{} = ndt -> naive_to_unix(ndt)
      seconds when is_integer(seconds) -> seconds
      other -> raise_invalid!(other)
    end
  end

  # A NaiveDateTime carries no zone, so it is read as UTC — the same
  # interpretation the dashboard applies to the Unix second it renders.
  defp naive_to_unix(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
  end

  defp raise_invalid!(value) do
    raise ArgumentError,
          "EvoGit.Agent.Clock expects an integer Unix second, a DateTime, a " <>
            "NaiveDateTime (interpreted as UTC) or a 0-arity function returning one " <>
            "of those, got: #{inspect(value)}"
  end
end
