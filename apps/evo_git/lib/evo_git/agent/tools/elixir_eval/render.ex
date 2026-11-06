defmodule EvoGit.Agent.Tools.ElixirEval.Render do
  @moduledoc false

  @doc false
  def term(value, cap) do
    value
    |> inspect(
      limit: 100,
      printable_limit: min(cap, 2_048),
      width: 80,
      pretty: true,
      structs: false,
      charlists: :as_lists
    )
    |> text(cap)
  end

  @doc false
  def text(binary, cap) when is_binary(binary) and is_integer(cap) and cap >= 0 do
    # Copy slices so a short reply never retains a huge reference-counted binary.
    prefix = binary_part(binary, 0, min(byte_size(binary), cap))

    valid =
      case :unicode.characters_to_binary(prefix, :utf8, :utf8) do
        result when is_binary(result) -> result
        {_, result, _} -> result
      end

    marker = "\n[output truncated]"

    if byte_size(binary) > cap and cap >= byte_size(marker) do
      String.byte_slice(valid, 0, cap - byte_size(marker)) <> marker
    else
      :binary.copy(valid)
    end
  end
end

defmodule EvoGit.Agent.Tools.ElixirEval.IOShim do
  @moduledoc false
  import Kernel, except: [inspect: 1, inspect: 2]
  alias EvoGit.Agent.Tools.ElixirEval.{Broker, Render}
  @per_call_cap 16_384

  # Dune shims receive an extra leading %Dune.Eval.Env{} argument.
  def puts(env, item), do: puts(env, :stdio, item)

  def puts(env, :stdio, item) do
    binary = Dune.Shims.Kernel.safe_to_string(env, item)
    emit(Render.text(binary, @per_call_cap) <> "\n")
    :ok
  end

  def puts(_env, _device, _item), do: restricted(:puts, 2)

  def inspect(env, item), do: inspect(env, :stdio, item, [])
  def inspect(env, item, opts), do: inspect(env, :stdio, item, opts)

  def inspect(env, :stdio, item, opts) when is_list(opts) do
    # Never honour user-supplied :infinity / custom inspect options.
    inspected =
      Dune.Shims.Kernel.safe_inspect(env, item,
        limit: 100,
        printable_limit: 2_048,
        structs: false,
        charlists: :as_lists
      )

    label =
      case Keyword.get(opts, :label) do
        nil -> ""
        value -> Render.text(Dune.Shims.Kernel.safe_to_string(env, value), 256) <> ": "
      end

    emit(Render.text(label <> inspected, @per_call_cap) <> "\n")
    item
  end

  def inspect(_env, _device, _item, _opts), do: restricted(:inspect, 3)

  defp emit(binary) do
    case Broker.call(:stdio, [binary]) do
      :ok -> :ok
      {:ok, _} -> :ok
      _ -> throw(%Dune.Failure{type: :stdio, message: "Captured output limit exceeded"})
    end
  end

  defp restricted(name, arity), do: throw(Dune.Failure.restricted_function(IO, name, arity))
end
