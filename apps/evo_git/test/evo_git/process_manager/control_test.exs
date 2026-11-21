defmodule EvoGit.ProcessManager.ControlTest do
  # Pure decision/containment helpers: no OS call and no shared state, so this
  # module is safe alongside every other module.
  use ExUnit.Case, async: true

  alias EvoGit.ProcessManager.{Control, Handle}
  alias EvoGit.ProcessManager.Control.Posix

  describe "kill_outcome/3" do
    test "a gone handle is :ok even when a signal already reported a failure" do
      assert Control.kill_outcome(false, :ok, :ok) == :ok
      assert Control.kill_outcome(false, {:error, {:kill_failed, 1, "eperm"}}, :ok) == :ok
      assert Control.kill_outcome(false, :ok, {:error, {:kill_failed, 1, "eperm"}}) == :ok
    end

    test "a REAL backend reason outranks the generic :still_alive" do
      eperm = {:error, {:kill_failed, 1, "Operation not permitted"}}

      # The hard (KILL) signal's reason is the most specific one…
      assert Control.kill_outcome(true, eperm, :ok) == eperm
      # …then the soft (TERM) signal's, when the hard one was merely delivered.
      assert Control.kill_outcome(true, :ok, eperm) == eperm
      # Hard wins over soft when BOTH failed.
      assert Control.kill_outcome(true, {:error, :hard}, {:error, :soft}) == {:error, :hard}
    end

    test ":still_alive means both signals were delivered and it is still there" do
      assert Control.kill_outcome(true, :ok, :ok) == {:error, :still_alive}
    end
  end

  describe "guarded/2" do
    test "passes a successful backend answer through unchanged" do
      assert Control.guarded(fn -> {:ok, :stats} end, :stats) == {:ok, :stats}
      assert Control.guarded(fn -> :ok end, :kill) == :ok
    end

    test "tags a crash by the OPERATION that failed" do
      assert {:error, {:kill_failed, "boom"}} = Control.guarded(fn -> raise "boom" end, :kill)
      assert {:error, {:probe_failed, "boom"}} = Control.guarded(fn -> raise "boom" end, :stats)
      assert {:error, {:signal_failed, "boom"}} = Control.guarded(fn -> raise "boom" end, :signal)
    end

    test "keeps the catch detail shape for a throw/exit" do
      assert {:error, {:kill_failed, {:throw, :nope}}} =
               Control.guarded(fn -> throw(:nope) end, :kill)

      assert {:error, {:probe_failed, {:exit, :boom}}} =
               Control.guarded(fn -> exit(:boom) end, :stats)
    end
  end

  describe "total dispatch answers" do
    test "an unusable handle is :no_handle for stats/kill/signal and false for alive?" do
      assert Control.stats(nil) == {:error, :no_handle}
      assert Control.kill(nil) == {:error, :no_handle}
      assert Control.signal(nil, :term) == {:error, :no_handle}
      refute Control.alive?(nil)

      assert Control.stats(%Handle{kind: :unmapped}) == {:error, :no_handle}
      assert Control.kill(%Handle{kind: :unmapped}) == {:error, :no_handle}
      refute Control.alive?(%Handle{kind: :unmapped})
    end

    test "Control.signal/2 normalizes the signal ONCE, before any backend call" do
      assert Control.signal(Handle.posix(1), :not_a_signal) == {:error, :invalid_signal}
      assert Control.signal(Handle.posix(1), "") == {:error, :invalid_signal}
      assert Control.signal(Handle.posix(1), 42) == {:error, :invalid_signal}
    end
  end

  describe "kill_grace_ms/0" do
    test "the per-process override wins, is read at CALL time and falls through when invalid" do
      Process.delete(:process_kill_grace_ms)
      ambient = Control.kill_grace_ms()
      assert is_integer(ambient) and ambient >= 0

      # A process-dictionary entry is the async-safe shrink: it belongs to THIS
      # process only and dies with it, so no BEAM-global state is touched.
      Process.put(:process_kill_grace_ms, 0)
      assert Control.kill_grace_ms() == 0

      Process.put(:process_kill_grace_ms, 25)
      assert Control.kill_grace_ms() == 25

      # An unusable value is not "no grace": it falls through to the ambient
      # (app env, else the production default), never to a fabricated 0.
      Process.put(:process_kill_grace_ms, :bogus)
      assert Control.kill_grace_ms() == ambient
      Process.put(:process_kill_grace_ms, -5)
      assert Control.kill_grace_ms() == ambient
      Process.delete(:process_kill_grace_ms)
      assert Control.kill_grace_ms() == ambient
    end
  end

  describe "POSIX backend signal names are authoritative" do
    test "an unnormalized atom is refused instead of being re-normalized" do
      # Normalization belongs to `Control.signal/2`; the backend must never see
      # (or silently accept) the atom vocabulary.
      assert Posix.signal(Handle.posix(1), :term) == {:error, :invalid_signal}
    end

    test "a handle with no pid answers :no_pid without touching the OS" do
      assert Posix.signal(Handle.posix(nil), "TERM") == {:error, :no_pid}
      assert Posix.kill(Handle.posix(nil)) == {:error, :no_pid}
    end
  end
end
