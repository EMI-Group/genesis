defmodule EvoDash.VCTScopeTest do
  # `async: true` — every assertion is about THIS test process and the children
  # it spawns; no BEAM-global env, table or singleton is touched.
  use ExUnit.Case, async: true
  alias EvoDash.VCTScope
  # A token no real VCT instance ever answers to: `EvoGit.VCT` would only reach
  # it through the designation under test.
  @instance :evogit_vct_scope_test_instance
  # A tiny probe GenServer: it reports what every layer answers in ITS process,
  # which is the only place the `$ancestors` inheritance can be observed. The
  # middle value is the load-bearing contrast: the RAW core read sees nothing in
  # a child (its lookup is process-local), while the chain walk resolves the
  # designation and `scoped/1` routes the core through it.
  defmodule Probe do
    use GenServer
    def start_link(report_to), do: GenServer.start_link(__MODULE__, report_to)
    @impl true
    def init(report_to) do
      resolved = {
        EvoDash.VCTScope.server(),
        EvoGit.VCT.server(),
        EvoDash.VCTScope.scoped(fn -> EvoGit.VCT.server() end)
      }

      send(report_to, {:probe_resolved, resolved})
      {:ok, report_to}
    end
  end

  # Puts a process-dictionary key back to what it was (nil = absent), so a test
  # that rewrites `$callers` leaves the test process as it found it.
  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, value), do: Process.put(key, value)

  describe "with nothing designated anywhere in the chain" do
    test "server/0 is nil and scoped/1 is a plain call that writes nothing" do
      assert Process.get(:evogit_vct_server) == nil
      assert VCTScope.server() == nil
      assert VCTScope.scoped(fn -> {:value, self()} end) == {:value, self()}
      # The inert path is ALLOCATION-free: no key is written, so nothing is left
      # for an `after` to restore.
      assert Process.get(:evogit_vct_server) == nil
      # The core still answers its registered singleton.
      assert EvoGit.VCT.server() == EvoGit.VCT
    end
  end

  describe "with an own-process designation" do
    test "server/0 answers it and scoped/1 routes EvoGit.VCT inside the fun" do
      Process.put(:evogit_vct_server, @instance)
      on_exit(fn -> Process.delete(:evogit_vct_server) end)
      assert VCTScope.server() == @instance
      assert VCTScope.scoped(fn -> EvoGit.VCT.server() end) == @instance
      # Restored to the designation that was already there, not dropped.
      assert Process.get(:evogit_vct_server) == @instance
      assert EvoGit.VCT.server() == @instance
    end

    test "scoped/1 restores nil after routing a designation it resolved itself" do
      # The designation is carried by the CHAIN, not by this process: resolve it
      # inside a `Task` child (which writes `$callers`), then assert the child
      # leaves no key behind.
      Process.put(:evogit_vct_server, @instance)
      on_exit(fn -> Process.delete(:evogit_vct_server) end)
      parent = self()

      task =
        Task.async(fn ->
          inside = VCTScope.scoped(fn -> EvoGit.VCT.server() end)
          send(parent, {:inside_task, inside, Process.get(:evogit_vct_server)})
          :done
        end)

      assert Task.await(task) == :done
      assert_received {:inside_task, @instance, nil}
    end

    test "scoped/1 nests: the outer designation survives an inner scoped call" do
      Process.put(:evogit_vct_server, @instance)
      on_exit(fn -> Process.delete(:evogit_vct_server) end)

      assert VCTScope.scoped(fn -> VCTScope.scoped(fn -> EvoGit.VCT.server() end) end) ==
               @instance

      assert Process.get(:evogit_vct_server) == @instance
    end
  end

  describe "spawn-chain inheritance" do
    test "a Task.async child ($callers) resolves the parent's designation" do
      Process.put(:evogit_vct_server, @instance)
      on_exit(fn -> Process.delete(:evogit_vct_server) end)
      parent = self()

      task =
        Task.async(fn ->
          send(
            parent,
            {:callers_resolved, VCTScope.server(), VCTScope.scoped(fn -> EvoGit.VCT.server() end)}
          )

          :ok
        end)

      assert Task.await(task) == :ok
      assert_received {:callers_resolved, @instance, @instance}
    end

    test "a GenServer child ($ancestors) resolves the parent's designation" do
      Process.put(:evogit_vct_server, @instance)
      on_exit(fn -> Process.delete(:evogit_vct_server) end)
      # A `GenServer.start_link/3` child started by THIS process has this pid in
      # its `$ancestors` — the `proc_lib` chain `server/0` walks.
      assert {:ok, pid} = Probe.start_link(self())
      assert_receive {:probe_resolved, {@instance, EvoGit.VCT, @instance}}, 5_000
      assert Process.alive?(pid)
      GenServer.stop(pid)
      # The child's designation never leaked back into this process.
      assert Process.get(:evogit_vct_server) == @instance
    end

    test "a dead or non-pid chain entry falls through instead of crashing" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 5_000
      # A live caller that designates the instance and holds it until told to
      # stop, so the walk has a real entry to reach past the dead ones.
      test_pid = self()

      designating =
        spawn(fn ->
          Process.put(:evogit_vct_server, @instance)
          send(test_pid, :designation_ready)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :designation_ready, 5_000
      on_exit(fn -> send(designating, :stop) end)
      # `Process.info/2` answers nil for the dead pid and a non-pid entry is
      # skipped, so the walk reaches the LIVE designation behind them.
      original_callers = Process.get(:"$callers")
      Process.put(:"$callers", [dead, :not_a_pid, designating])
      on_exit(fn -> restore(:"$callers", original_callers) end)
      assert VCTScope.server() == @instance
      assert VCTScope.scoped(fn -> EvoGit.VCT.server() end) == @instance
      # The inert path stays a plain call even with a dead entry in the chain.
      Process.put(:"$callers", [dead, :not_a_pid])
      assert VCTScope.server() == nil
      assert VCTScope.scoped(fn -> :still_runs end) == :still_runs
    end
  end
end
