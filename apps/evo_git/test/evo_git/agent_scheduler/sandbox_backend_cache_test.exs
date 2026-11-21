defmodule EvoGit.AgentScheduler.SandboxBackendCacheTest do
  # async: false — this module pins the BEAM-global `EvoGit.AgentScheduler`
  # singleton state and mutates the BEAM-global app-env seam
  # `:evo_git, :sandbox_backend_probe_fun`; both are observable by any
  # concurrently running module. PeakHourEngine is suspended (as in the other
  # app-global scheduler tests) so its asynchronous model-concurrency wakeups
  # cannot apply a config update — which would legitimately re-arm the probe —
  # in the middle of the count assertions.
  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler

  setup do
    engine = Process.whereis(EvoGit.PeakHourEngine)
    :ok = :sys.suspend(engine)
    original = :sys.get_state(AgentScheduler)

    on_exit(fn ->
      try do
        Application.delete_env(:evo_git, :sandbox_backend_probe_fun)
        :sys.replace_state(AgentScheduler, fn _ -> original end)
        # Drop any stubbed memo and re-probe for real, so a later module never
        # inherits a value produced by this test's seam.
        :ok = AgentScheduler.update_config([])
        assert AgentScheduler.get_config(:sandbox_backend) == EvoGit.Platform.sandbox_backend()
      after
        :ok = :sys.resume(engine)
      end
    end)

    %{counter: install_probe(self())}
  end

  # Function-object API so production never sets the seam: the probe site reads
  # `Application.get_env(:evo_git, :sandbox_backend_probe_fun)` at CALL time.
  # The stub reports its call count to the test process and answers a
  # distinctive atom, so the cache and the invalidation are both observable.
  defp install_probe(test_pid) do
    counter = :atomics.new(1, signed: false)

    Application.put_env(:evo_git, :sandbox_backend_probe_fun, fn ->
      :atomics.add(counter, 1, 1)
      send(test_pid, {:sandbox_backend_probe, self(), :atomics.get(counter, 1)})
      :stub_backend
    end)

    counter
  end

  test "the sandbox backend is probed ONCE per config identity, then re-probed after a config refresh" do
    # `update_config/1` is the apply-config handler every refresh route funnels
    # into (`RemoteAPI.reload_config/0`, save_user_config, dashboard pushes) and
    # is itself the memo's invalidation boundary. It is used directly instead of
    # `RemoteAPI.reload_config/0` because a scheduler-side config read does not
    # inherit the per-test ConfigDir seam: a disk reload would apply the
    # operator's real config instead of the test's.
    :ok = AgentScheduler.update_config([])

    # Three reads, one cached probe — single-key and map form alike.
    assert AgentScheduler.get_config(:sandbox_backend) == :stub_backend
    assert AgentScheduler.get_config(:sandbox_backend) == :stub_backend
    assert AgentScheduler.get_config()[:sandbox_backend] == :stub_backend

    # The probe runs inside the scheduler GenServer, so it is exactly one call
    # and it happened in the scheduler process, not the caller.
    assert_receive {:sandbox_backend_probe, pid, 1}
    assert pid == Process.whereis(AgentScheduler)
    refute_received {:sandbox_backend_probe, _pid, _count}

    # `:sandbox_capabilities` shares the memo lifecycle: a map-form read returns
    # a stable, already-computed value rather than re-resolving the backend.
    capabilities = AgentScheduler.get_config()[:sandbox_capabilities]
    assert is_map(capabilities)
    assert capabilities == AgentScheduler.get_config()[:sandbox_capabilities]
    refute_received {:sandbox_backend_probe, _pid, _count}

    # A config refresh INVALIDATES the memo: the next read probes again and
    # still answers the seam's value (not a stale symbol, not the real probe).
    assert :ok = AgentScheduler.update_config(max_turns: 55)
    assert AgentScheduler.get_config(:sandbox_backend) == :stub_backend
    assert_receive {:sandbox_backend_probe, _pid, 2}
    assert AgentScheduler.get_config()[:sandbox_backend] == :stub_backend
    refute_received {:sandbox_backend_probe, _pid, _count}
  end
end
