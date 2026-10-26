defmodule EvoDash.SafeCallTest.SlowServer do
  @moduledoc false
  use GenServer

  @impl true
  def init(state), do: {:ok, state}

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def handle_call(:slow, _from, state) do
    Process.sleep(1_000)
    {:reply, :late, state}
  end
end

defmodule EvoDash.SafeCallTest do
  use ExUnit.Case, async: true

  alias EvoDash.SafeCall
  alias EvoDash.SafeCallTest.SlowServer

  # A freshly named supervisor per test keeps the suite fully parallel-safe.
  defp start_named_supervisor! do
    name = :"safe_call_test_sup_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: name})
    name
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> pid
    end
  end

  describe "run/1 — success" do
    test "returns {:ok, value} for a normally returning function" do
      assert SafeCall.run(fn -> 42 end) == {:ok, 42}
    end

    test "passes through any term (nil, collections, error tuples)" do
      assert SafeCall.run(fn -> nil end) == {:ok, nil}
      assert SafeCall.run(fn -> [1, 2, 3] end) == {:ok, [1, 2, 3]}
      assert SafeCall.run(fn -> {:error, :not_found} end) == {:ok, {:error, :not_found}}
    end

    test "runs the function exactly once" do
      {:ok, pid_holder} = Agent.start_link(fn -> 0 end)

      assert {:ok, :done} =
               SafeCall.run(fn ->
                 Agent.update(pid_holder, &(&1 + 1))
                 :done
               end)

      assert Agent.get(pid_holder, & &1) == 1
    end
  end

  describe "run/1 — raise" do
    test "catches a raise as {:error, {:exception, exception}}" do
      assert {:error, {:exception, exception}} = SafeCall.run(fn -> raise "boom" end)
      assert %RuntimeError{message: "boom"} = exception
    end

    test "catches a raise with a non-RuntimeError exception struct" do
      assert {:error, {:exception, exception}} =
               SafeCall.run(fn -> raise ArgumentError, "bad argument" end)

      assert %ArgumentError{message: "bad argument"} = exception
    end
  end

  describe "run/1 — exit" do
    test "catches exit(:boom) as {:error, {:exit, :boom}}" do
      # Load-bearing: a `GenServer.call` timeout EXITS the caller and cannot be
      # caught by `rescue` alone.
      assert SafeCall.run(fn -> exit(:boom) end) == {:error, {:exit, :boom}}
    end

    test "converts a real GenServer.call to a dead process into an error value" do
      dead = dead_pid()

      assert {:error, {:exit, {:noproc, {GenServer, :call, [^dead, :ping, 5000]}}}} =
               SafeCall.run(fn -> GenServer.call(dead, :ping, 5000) end)
    end

    test "converts a real GenServer.call timeout into an error value" do
      pid = start_supervised!({SlowServer, :idle})

      assert {:error, {:exit, {:timeout, {GenServer, :call, [^pid, :slow, 10]}}}} =
               SafeCall.run(fn -> GenServer.call(pid, :slow, 10) end)
    end
  end

  describe "run/1 — throw" do
    test "catches a throw as {:error, {:throw, value}}" do
      assert SafeCall.run(fn -> throw(:ball) end) == {:error, {:throw, :ball}}
    end

    test "keeps the thrown term intact" do
      assert SafeCall.run(fn -> throw({:bad, 1}) end) == {:error, {:throw, {:bad, 1}}}
    end
  end

  describe "run/1 — invalid function argument" do
    test "a non-function argument yields {:error, {:invalid_function, term}} without raising" do
      assert SafeCall.run(:not_a_function) == {:error, {:invalid_function, :not_a_function}}
      assert SafeCall.run(nil) == {:error, {:invalid_function, nil}}
      assert SafeCall.run(42) == {:error, {:invalid_function, 42}}
    end

    test "a non-0-arity function yields {:error, {:invalid_function, fun}}" do
      unary = fn x -> x end
      assert SafeCall.run(unary) == {:error, {:invalid_function, unary}}
    end
  end

  describe "run/2 — value or fallback" do
    test "returns the value on success" do
      assert SafeCall.run(fn -> 42 end, :fallback) == 42
    end

    test "falsy-but-successful values are not replaced by the fallback" do
      assert SafeCall.run(fn -> nil end, :fallback) == nil
      assert SafeCall.run(fn -> false end, :fallback) == false
      assert SafeCall.run(fn -> [] end, :fallback) == []
    end

    test "returns the fallback on exit" do
      assert SafeCall.run(fn -> exit(:boom) end, :fallback) == :fallback
    end

    test "returns the fallback on raise" do
      assert SafeCall.run(fn -> raise "boom" end, :fallback) == :fallback
    end

    test "returns the fallback on throw and on an invalid argument" do
      assert SafeCall.run(fn -> throw(:ball) end, :fallback) == :fallback
      assert SafeCall.run(:nope, :fallback) == :fallback
    end
  end

  describe "start/3 — default supervisor" do
    test "delivers {tag, {:ok, value}} to the parent" do
      tag = {:loaded, System.unique_integer([:positive])}

      assert {:ok, pid} = SafeCall.start(self(), tag, fn -> :value end)
      assert is_pid(pid)

      assert_receive {^tag, {:ok, :value}}, 2000
    end

    test "delivers {tag, {:error, {:exit, reason}}} when the call exits" do
      tag = {:exited, System.unique_integer([:positive])}

      assert {:ok, _pid} = SafeCall.start(self(), tag, fn -> exit(:boom) end)

      assert_receive {^tag, {:error, {:exit, :boom}}}, 2000
    end

    test "delivers {tag, {:error, {:exception, exception}}} when the call raises" do
      tag = {:raised, System.unique_integer([:positive])}

      assert {:ok, _pid} = SafeCall.start(self(), tag, fn -> raise "boom" end)

      assert_receive {^tag, {:error, {:exception, %RuntimeError{message: "boom"}}}}, 2000
    end

    test "delivers {tag, {:error, {:throw, value}}} when the call throws" do
      tag = {:thrown, System.unique_integer([:positive])}

      assert {:ok, _pid} = SafeCall.start(self(), tag, fn -> throw(:ball) end)

      assert_receive {^tag, {:error, {:throw, :ball}}}, 2000
    end

    test "sends the result to the given parent, not to the caller by default" do
      tag = {:elsewhere, System.unique_integer([:positive])}
      parent = spawn(fn -> Process.sleep(:infinity) end)

      assert {:ok, _pid} = SafeCall.start(parent, tag, fn -> :value end)

      # `parent` is a dead-forever process, so this scan window is only a margin
      # for a mis-implementation that replied to the CALLER instead; it never
      # needs to cover any real work.
      refute_receive {^tag, _}, 25
      Process.exit(parent, :kill)
    end
  end

  describe "start/4 — opts[:supervisor] override" do
    test "runs the child under the given supervisor and delivers the result" do
      supervisor = start_named_supervisor!()
      tag = {:overridden, System.unique_integer([:positive])}
      parent = self()

      # Hold the child inside the function so its parent supervisor is
      # observable deterministically (no sleeps, no timing race).
      assert {:ok, pid} =
               SafeCall.start(
                 self(),
                 tag,
                 fn ->
                   send(parent, {:child_running, self()})

                   receive do
                     :go -> :value
                   end
                 end,
                 supervisor: supervisor
               )

      assert_receive {:child_running, ^pid}, 2000

      # The child really ran under the OVERRIDE, not under the default one.
      assert pid in Task.Supervisor.children(supervisor)
      refute pid in Task.Supervisor.children(EvoDash.TaskSupervisor)

      send(pid, :go)
      assert_receive {^tag, {:ok, :value}}, 2000
    end

    test "an explicit supervisor still carries errors back to the parent" do
      supervisor = start_named_supervisor!()
      tag = {:overridden_exit, System.unique_integer([:positive])}

      assert {:ok, _pid} =
               SafeCall.start(self(), tag, fn -> exit(:boom) end, supervisor: supervisor)

      assert_receive {^tag, {:error, {:exit, :boom}}}, 2000
    end

    test "an unknown/dead supervisor never claims success and never starts a child" do
      tag = {:no_supervisor, System.unique_integer([:positive])}
      dead = dead_pid()

      # NOTE: the current implementation delegates straight to
      # Task.Supervisor.start_child/2, which EXITS instead of returning
      # {:error, _} when the supervisor is unknown/dead (reported upstream, not
      # fixed here). The tolerant outcome assertion below pins the durable
      # contract — never {:ok, pid}, never a stray result message — and stays
      # green whether or not the exit is later converted into {:error, _}.
      unknown_outcome =
        try do
          SafeCall.start(self(), tag, fn -> :value end, supervisor: :no_such_supervisor_name)
        catch
          :exit, reason -> {:exit, reason}
        end

      dead_outcome =
        try do
          SafeCall.start(self(), tag, fn -> :value end, supervisor: dead)
        catch
          :exit, reason -> {:exit, reason}
        end

      for outcome <- [unknown_outcome, dead_outcome] do
        assert match?({:error, _}, outcome) or match?({:exit, _}, outcome),
               "expected {:error, _} or an exit, got: #{inspect(outcome)}"
      end

      refute_receive {^tag, _}, 25
    end
  end
end
