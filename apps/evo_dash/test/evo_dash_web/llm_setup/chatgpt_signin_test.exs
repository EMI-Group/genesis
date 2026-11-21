defmodule EvoDashWeb.LLMSetup.ChatGPTSignInTest do
  @moduledoc """
  Pins the dashboard's Sign in with ChatGPT state/vocabulary boundary.

  Every flow module here is a STUB injected through the call-time resolver
  seam (`Process.put(:chatgpt_login_module, …)`), so no test touches the real
  sign-in flow, the network, a config dir or a credential file — and the module
  stays `async: true` because nothing writes BEAM-global state (the poll
  interval/cap seams are also per-process).
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.LLMSetup.ChatGPTSignIn

  # Load-tolerant budget for waits on ASYNC work on a shared host whose
  # scheduling swings 10-30x (test/CONTEXT.md); also injected as the product's
  # call budget so a starved host can never kill a stub call.
  @async_wait_budget_ms 30_000

  # A "generous" per-call budget for the seam-behaviour tests: far above the
  # slow stub's 5 ms sleep (so a loaded host cannot turn the positive case into
  # a flake) and far below the 15 s production default (so the test stays fast).
  @generous_call_budget_ms 2_000

  @reasons [
    :authorization_denied,
    :plan_not_authorized,
    :reauthorization_required,
    :authorization_timeout,
    :cancelled,
    :superseded,
    :loopback_listener_unavailable,
    :sign_in_unavailable,
    :unreachable,
    :chatgpt_account_alias_in_use,
    :chatgpt_registration_already_installed
  ]

  # ── Stub flow modules ──────────────────────────────────────────────────────

  defmodule OkStub do
    # Only the documented arity/opts shape succeeds; anything else is an error.
    def begin(nil, []), do: {:ok, %{id: "flow-default", url: "https://example.test/authorize"}}
    def begin(account, []), do: {:ok, %{id: "flow-" <> account, url: "https://example.test/a"}}
    def begin(_account, opts), do: {:error, {:unexpected_opts, opts}}

    def cancel("flow-default"), do: :ok
    def cancel(other), do: {:error, {:unknown_flow, other}}

    def status("flow-default"), do: {:ok, %{account_id: "work@example.test"}}
    def status(_flow), do: :pending
  end

  defmodule StringKeyStub do
    def begin(_account, []), do: {:ok, %{"id" => "flow-2", "url" => "https://example.test/b"}}
    def cancel(_flow), do: :ok
    def status(_flow), do: :pending
  end

  defmodule UnexpectedStub do
    def begin(_account, _opts), do: :nope
    def cancel(_flow), do: :nope
    def status(_flow), do: :nope
  end

  defmodule RaisingStub do
    def begin(_account, _opts), do: raise("boom")
    def cancel(_flow), do: raise(ArgumentError, "boom")
    def status(_flow), do: throw(:boom)
  end

  defmodule ErrorStub do
    def begin(_account, _opts), do: {:error, :loopback_listener_unavailable}
    def cancel(_flow), do: {:error, :superseded}
    def status(_flow), do: {:error, :unreachable}
  end

  defmodule PendingStub do
    def begin(_account, _opts), do: {:ok, %{id: "flow-pending", url: "https://example.test/p"}}
    def cancel(_flow), do: :ok
    def status(_flow), do: :pending
  end

  # Answers only AFTER a short real sleep, so the product's per-call budget is
  # what decides whether the call is seen to finish. The 5 ms sleep is far below
  # every budget used here, so the outcome is never a scheduling guess.
  defmodule SlowStub do
    def begin(_account, _opts) do
      Process.sleep(5)
      {:ok, %{id: "flow-slow", url: "https://example.test/slow"}}
    end

    def cancel(_flow), do: :ok
    def status(_flow), do: :pending
  end

  # Answers the next status from a per-test sequence held in an Agent that the
  # POLL TASK finds through the `$callers` chain (so no global state is used).
  defmodule SequenceStub do
    def begin(_account, _opts), do: {:ok, %{id: "flow-seq", url: "https://example.test/s"}}
    def cancel(_flow), do: :ok

    def status(_flow) do
      Agent.get_and_update(state(), fn
        [next | rest] -> {next, rest}
        [] -> {:pending, []}
      end)
    end

    defp state do
      Enum.find_value(List.wrap(Process.get(:"$callers")), fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dictionary} -> Keyword.get(dictionary, :chatgpt_signin_test_state)
          _ -> nil
        end
      end)
    end
  end

  defp inject(module) do
    Process.put(:chatgpt_login_module, module)
    Process.put(:chatgpt_signin_poll_interval_ms, 5)
    # The stub notifies from INSIDE the boundary's `Task.async` call, so the
    # product's call budget also bounds a stub notification: on a starved host
    # the task can be killed before it runs and the notification is lost
    # forever. Inject the suite's load-tolerant budget so the product can never
    # kill a stub call (production keeps its own 15 s default).
    Process.put(:chatgpt_signin_call_timeout_ms, @async_wait_budget_ms)
    module
  end

  # ── Deterministic barrier for the ASYNC poll task ──────────────────────────
  #
  # `start_poll/2` runs the poll as a `EvoDash.TaskSupervisor` child, so "the
  # poll has stopped" is a SET QUERY — a `:"$callers"` match against the process
  # that started it — never a wall-clock window. Once no poll child started by
  # `owner` is alive, the poll's ONE result message has already been delivered
  # and no second one can ever be produced, which is what makes the following
  # `refute_receive …, 0` conclusive (the suite's 0 ms rule: a zero window is
  # sound only after a completed fence).
  defp await_poll_stopped(owner) do
    await_poll_stopped(owner, System.monotonic_time(:millisecond) + @async_wait_budget_ms)
  end

  defp await_poll_stopped(owner, deadline) do
    if poll_children(owner) == [] do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("the sign-in poll started by #{inspect(owner)} never stopped")
      end

      Process.sleep(1)
      await_poll_stopped(owner, deadline)
    end
  end

  defp poll_children(owner) do
    EvoDash.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.filter(&(owner in callers(&1)))
  end

  defp callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, :"$callers", [])
      _ -> []
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Resolver seam
  # ═══════════════════════════════════════════════════════════════════════════

  describe "login_module/0 — call-time resolver" do
    test "defaults to the bare atom (never resolved at compile time)" do
      assert ChatGPTSignIn.login_module() == EvoDash.ChatGPTLogin
    end

    test "a per-process override wins" do
      inject(OkStub)
      assert ChatGPTSignIn.login_module() == OkStub
    end

    test "the seam reaches a spawned task through the $callers chain" do
      inject(OkStub)

      resolved = Task.async(fn -> ChatGPTSignIn.login_module() end) |> Task.await()
      assert resolved == OkStub
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # call_timeout_ms/0 — the documented production budget
  # ═══════════════════════════════════════════════════════════════════════════

  describe "call_timeout_ms/0" do
    test "the production default stays 15 s when nothing is seeded" do
      assert ChatGPTSignIn.call_timeout_ms() == 15_000
    end

    test "an injected generous budget lets a slow flow call finish" do
      inject(SlowStub)
      # Well under the 15 s production default, well over the stub's 5 ms sleep:
      # the call only answers within budget because the seam moved the cut-off.
      Process.put(:chatgpt_signin_call_timeout_ms, @generous_call_budget_ms)

      assert ChatGPTSignIn.call_timeout_ms() == @generous_call_budget_ms

      assert {:ok, %{id: "flow-slow", url: "https://example.test/slow"}} =
               ChatGPTSignIn.begin(nil)
    end

    test "an injected tiny budget cuts the SAME call off as unavailable" do
      inject(SlowStub)
      # The identical 5 ms call the test above sees finish: at 1 ms the spawned
      # call cannot complete, so the boundary answers its documented failure.
      Process.put(:chatgpt_signin_call_timeout_ms, 1)

      assert {:error, :sign_in_unavailable} = ChatGPTSignIn.begin(nil)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # begin/1, cancel/1, status/1
  # ═══════════════════════════════════════════════════════════════════════════

  describe "begin/1" do
    test "normalizes the flow id and url into atom keys and passes [] as opts" do
      inject(OkStub)

      assert {:ok, %{id: "flow-default", url: "https://example.test/authorize"}} =
               ChatGPTSignIn.begin(nil)

      assert {:ok, %{id: "flow-work", url: "https://example.test/a"}} =
               ChatGPTSignIn.begin("work")
    end

    test "accepts a string-keyed flow answer" do
      inject(StringKeyStub)

      assert {:ok, %{id: "flow-2", url: "https://example.test/b"}} = ChatGPTSignIn.begin("work")
    end

    test "an unexpected shape degrades to :sign_in_unavailable" do
      inject(UnexpectedStub)
      assert {:error, :sign_in_unavailable} = ChatGPTSignIn.begin("work")
    end

    test "a raising flow module degrades instead of crashing the caller" do
      inject(RaisingStub)
      assert {:error, :sign_in_unavailable} = ChatGPTSignIn.begin("work")
    end

    test "a missing/unknown module degrades instead of crashing the caller" do
      inject(:no_such_sign_in_module)
      assert {:error, :sign_in_unavailable} = ChatGPTSignIn.begin("work")
    end

    test "the flow module's own error is preserved" do
      inject(ErrorStub)
      assert {:error, :loopback_listener_unavailable} = ChatGPTSignIn.begin("work")
    end
  end

  describe "cancel/1" do
    test "forwards :ok and error values" do
      inject(OkStub)

      assert :ok = ChatGPTSignIn.cancel("flow-default")
      assert {:error, {:unknown_flow, "other"}} = ChatGPTSignIn.cancel("other")
    end

    test "a raising / unexpected module degrades to :sign_in_unavailable" do
      inject(RaisingStub)
      assert {:error, :sign_in_unavailable} = ChatGPTSignIn.cancel("flow")

      inject(UnexpectedStub)
      assert {:error, :sign_in_unavailable} = ChatGPTSignIn.cancel("flow")
    end

    test "the flow module's own error is preserved" do
      inject(ErrorStub)
      assert {:error, :superseded} = ChatGPTSignIn.cancel("flow")
    end
  end

  describe "status/1" do
    test "answers :pending, a terminal ok map, or an error" do
      inject(OkStub)

      assert :pending = ChatGPTSignIn.status("flow-work")
      assert {:ok, %{account_id: "work@example.test"}} = ChatGPTSignIn.status("flow-default")

      inject(ErrorStub)
      assert {:error, :unreachable} = ChatGPTSignIn.status("flow")
    end

    test "a raising / unexpected module degrades to :sign_in_unavailable" do
      inject(RaisingStub)
      assert {:error, :sign_in_unavailable} = ChatGPTSignIn.status("flow")

      inject(UnexpectedStub)
      assert {:error, :sign_in_unavailable} = ChatGPTSignIn.status("flow")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # start_poll/2 — exactly one result, bounded, owner-aware
  # ═══════════════════════════════════════════════════════════════════════════

  describe "start_poll/2" do
    test "a pending → ok sequence sends exactly ONE result and stops" do
      inject(SequenceStub)

      agent =
        start_supervised!(
          {Agent, fn -> [:pending, :pending, {:ok, %{account_id: "work@example.test"}}] end}
        )

      Process.put(:chatgpt_signin_test_state, agent)

      assert :ok = ChatGPTSignIn.start_poll("flow-seq", self())

      assert_receive {:chatgpt_signin_result, "flow-seq",
                      {:ok, %{account_id: "work@example.test"}}},
                     1_000

      # The poll sends ONE result and exits; the supervisor fence proves it
      # stopped, so a 0 ms scan cannot miss a second (impossible) send.
      await_poll_stopped(self())
      refute_receive {:chatgpt_signin_result, _, _}, 0
    end

    test "a raising status/1 degrades to an error result instead of crashing" do
      inject(RaisingStub)

      assert :ok = ChatGPTSignIn.start_poll("flow", self())

      assert_receive {:chatgpt_signin_result, "flow", {:error, :sign_in_unavailable}}, 1_000
      await_poll_stopped(self())
      refute_receive {:chatgpt_signin_result, _, _}, 0
    end

    test "the hard cap answers {:error, :authorization_timeout} exactly once" do
      inject(PendingStub)
      Process.put(:chatgpt_signin_poll_timeout_ms, 30)

      assert :ok = ChatGPTSignIn.start_poll("flow-pending", self())

      assert_receive {:chatgpt_signin_result, "flow-pending", {:error, :authorization_timeout}},
                     1_000

      await_poll_stopped(self())
      refute_receive {:chatgpt_signin_result, _, _}, 0
    end

    test "a poll never messages a dead owner" do
      inject(PendingStub)
      Process.put(:chatgpt_signin_poll_timeout_ms, 20)

      owner =
        spawn(fn ->
          Process.put(:chatgpt_login_module, PendingStub)
          Process.put(:chatgpt_signin_poll_interval_ms, 5)
          Process.put(:chatgpt_signin_poll_timeout_ms, 20)
          ChatGPTSignIn.start_poll("flow-pending", self())
        end)

      Process.monitor(owner)
      assert_receive {:DOWN, _, :process, ^owner, _reason}, 1_000

      # Nothing was delivered anywhere: the poll (started BY the dead owner)
      # has stopped, and its only send target was that dead pid.
      await_poll_stopped(owner)
      refute_receive {:chatgpt_signin_result, _, _}, 0
    end

    test "a non-pid owner is refused without crashing" do
      inject(OkStub)
      assert :ok = ChatGPTSignIn.start_poll("flow-default", nil)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # message/1 and phase/1 — total vocabulary
  # ═══════════════════════════════════════════════════════════════════════════

  describe "message/1" do
    test "every documented reason maps to a friendly, localized message" do
      for reason <- @reasons do
        assert %{kind: kind, text: text} = message = ChatGPTSignIn.message(reason)
        assert kind in [:error, :info, :success], "bad kind for #{inspect(reason)}"
        assert is_binary(text) and text != "", "empty text for #{inspect(reason)}"

        refute text =~ inspect(reason),
               "#{inspect(message)} leaks the raw atom #{inspect(reason)}"
      end
    end

    test "the documented failures read as sentences, not codes" do
      assert ChatGPTSignIn.message(:authorization_denied) == %{
               kind: :error,
               text: "Sign-in was cancelled in the browser."
             }

      assert ChatGPTSignIn.message(:plan_not_authorized).text ==
               "Genesis was not granted permission to use this ChatGPT plan."

      assert ChatGPTSignIn.message(:reauthorization_required).text ==
               "This ChatGPT account must be signed in again."

      assert ChatGPTSignIn.message(:authorization_timeout).text ==
               "The sign-in request timed out. Start again."

      assert ChatGPTSignIn.message(:cancelled) == %{kind: :info, text: "Sign-in cancelled."}

      assert ChatGPTSignIn.message(:superseded) == %{
               kind: :info,
               text: "A newer sign-in request replaced this one."
             }
    end

    test "the local-sign-in failures point at the CLI alternative" do
      for reason <- [:loopback_listener_unavailable, :sign_in_unavailable, :unreachable] do
        assert %{kind: :error, text: text} = ChatGPTSignIn.message(reason)
        assert text =~ "genesis chatgpt login"
        assert text =~ "execution node"
      end
    end

    test "a duplicate registration explains the account-name collision" do
      for reason <- [:chatgpt_account_alias_in_use, :chatgpt_registration_already_installed] do
        assert %{kind: :error, text: text} = ChatGPTSignIn.message(reason)
        assert text =~ "already connected under another account name"
      end
    end

    test "success is a success message" do
      assert ChatGPTSignIn.message(:ok) == %{kind: :success, text: "ChatGPT connected"}
      assert ChatGPTSignIn.message({:ok, %{account_id: "work"}}).kind == :success
    end

    test "tuples, nil and unknown atoms fall back to generic text (never inspect)" do
      for input <- [nil, :unknown_reason_xyz, {:error, :another_unknown}, {:weird, :shape}] do
        assert %{kind: :error, text: text} = ChatGPTSignIn.message(input)
        assert text == "Sign-in could not be completed. Start again."
        refute text =~ "%"
      end
    end

    test "an explicit error tuple keeps its mapped message" do
      assert ChatGPTSignIn.message({:error, :cancelled}) == %{
               kind: :info,
               text: "Sign-in cancelled."
             }
    end
  end

  describe "phase/1" do
    test "is total" do
      assert ChatGPTSignIn.phase(:ok) == :ok
      assert ChatGPTSignIn.phase({:ok, %{}}) == :ok
      assert ChatGPTSignIn.phase(:pending) == :pending
      assert ChatGPTSignIn.phase(nil) == :pending
      assert ChatGPTSignIn.phase({:error, :cancelled}) == :error
      assert ChatGPTSignIn.phase(:whatever) == :error
    end
  end
end
