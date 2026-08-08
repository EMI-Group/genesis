defmodule EvoGit.AgentScheduler.PubSubTest do
  @moduledoc """
  Tests for the supervised broadcast throttle `EvoGit.AgentScheduler.PubSub.Throttle`.

  The throttle coalesces rapid `:schedule` casts into ONE `{:agents_updated}`
  broadcast on the `"agents"` topic at most 200ms after the last cast. It runs
  under a named one_for_one Supervisor (`ThrottleSupervisor`) started by
  `EvoGit.AgentScheduler.PubSub.start_throttle/0` (also called at app boot).

  Uses `async: false` because the throttle process and the `EvoGit.PubSub`
  topic are global — shared with the running application and other test
  modules. Mailbox drains before each measurement window keep the assertions
  deterministic even if other (serialized) tests broadcast to the same topic.
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler.PubSub
  alias EvoGit.AgentScheduler.PubSub.Throttle

  @topic PubSub.agent_topic()

  setup do
    Phoenix.PubSub.subscribe(EvoGit.PubSub, @topic)
    # Idempotent — ensures the throttle is up even if the app was not started
    :ok = PubSub.start_throttle()
    # Flush any messages broadcast before this test subscribed
    drain_mailbox()

    on_exit(fn ->
      Phoenix.PubSub.unsubscribe(EvoGit.PubSub, @topic)
    end)

    :ok
  end

  defp drain_mailbox do
    receive do
      _msg -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  test "rapid broadcasts collapse into a single {:agents_updated} message" do
    PubSub.broadcast_agents_updated()
    PubSub.broadcast_agents_updated()
    PubSub.broadcast_agents_updated()

    # The throttle flushes at most 200ms after the last cast — wait past it.
    assert_receive {:agents_updated}, 700

    # The three back-to-back casts must not produce a second flush.
    refute_receive {:agents_updated}, 300
  end

  test "throttle process is restarted by its supervisor and broadcasts resume" do
    old_pid = Process.whereis(Throttle)
    assert is_pid(old_pid)

    Process.exit(old_pid, :kill)

    # The supervisor restarts the child (:permanent restart strategy)
    new_pid = wait_for_restart(old_pid, 100)
    assert is_pid(new_pid)
    assert new_pid != old_pid

    # The restarted throttle must serve broadcasts again
    drain_mailbox()
    PubSub.broadcast_agents_updated()
    assert_receive {:agents_updated}, 600
  end

  test "start_throttle/0 is idempotent" do
    assert :ok = PubSub.start_throttle()
    assert :ok = PubSub.start_throttle()
    assert is_pid(Process.whereis(Throttle))
  end

  defp wait_for_restart(old_pid, attempts) do
    case Process.whereis(Throttle) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_for_restart(old_pid, attempts - 1)

      _ ->
        nil
    end
  end
end
