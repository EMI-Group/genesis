defmodule EvoGit.TaskRegistry.StoreGuardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.TaskRegistry.StoreGuard

  test "reads and writes pass callback values through, including error tuples" do
    for value <- [
          nil,
          [],
          :ok,
          %{entries: [], total: 0},
          {:error, :disk_full},
          {:error, :store_unavailable}
        ] do
      assert StoreGuard.read("read_passthrough", :fallback, fn -> value end) === value
      assert StoreGuard.write("write_passthrough", fn -> value end) === value
    end

    assert StoreGuard.degraded_write_error() === {:error, :store_unavailable}
  end

  for mode <- [:read, :write] do
    @mode mode

    test "#{mode} contains raises, throws and exits in the caller with labelled error logs" do
      caller = self()
      op = "#{@mode}_fault_#{System.unique_integer([:positive])}"
      fallback = {make_ref(), %{entries: [], total: 0}}

      for {fault, detail} <- [
            {fn -> raise ArgumentError, "invalid store" end, "** (ArgumentError) invalid store"},
            {fn -> throw({:store_fault, op}) end, "(throw: #{inspect({:store_fault, op})})"},
            {fn -> exit({:noproc, op}) end, "(exit: #{inspect({:noproc, op})})"}
          ] do
        log =
          capture_log([level: :error], fn ->
            expected = if @mode == :read, do: fallback, else: {:error, :store_unavailable}
            assert invoke(@mode, op, fallback, fault) === expected
            assert self() == caller
            assert Process.alive?(caller)
          end)

        assert log =~ "TaskRegistry: store operation #{op} FAILED"
        assert log =~ detail
        assert log =~ "continuing with the degraded value (the registry stays alive"
      end
    end

    test "#{mode} formats the original exception stacktrace, limited to five frames" do
      op = "#{@mode}_stack_#{System.unique_integer([:positive])}"
      exception = %RuntimeError{message: op}

      stacktrace =
        for line <- 1..6 do
          {__MODULE__, :store_callback, 0, [file: "#{op}.ex", line: line]}
        end

      log =
        capture_log([level: :error], fn ->
          expected = if @mode == :read, do: nil, else: {:error, :store_unavailable}

          assert invoke(@mode, op, nil, fn -> reraise exception, stacktrace end) === expected
        end)

      assert log =~
               "TaskRegistry: store operation #{op} FAILED — continuing with the degraded value " <>
                 "(the registry stays alive; the store may be restarting): " <>
                 Exception.format(:error, exception, Enum.take(stacktrace, 5))

      refute log =~ "#{op}.ex:6:"
    end
  end

  defp invoke(:read, op, fallback, fun), do: StoreGuard.read(op, fallback, fun)
  defp invoke(:write, op, _fallback, fun), do: StoreGuard.write(op, fun)
end
