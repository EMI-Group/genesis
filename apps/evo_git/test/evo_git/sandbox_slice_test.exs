defmodule EvoGit.SandboxSliceTest do
  use ExUnit.Case, async: false

  alias EvoGit.SandboxSlice

  setup do
    # Ensure the GenServer is running (Application may not have started it on non-Linux CI)
    case GenServer.whereis(SandboxSlice) do
      nil ->
        {:ok, _pid} = SandboxSlice.start_link([])
        on_exit(fn -> GenServer.stop(SandboxSlice, :normal) end)

      pid when is_pid(pid) ->
        :ok
    end

    :ok
  end

  describe "ensure_slice/0" do
    test "returns :ok in test environment (sandbox disabled)" do
      assert SandboxSlice.ensure_slice() == :ok
    end
  end
end
